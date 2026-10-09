//! STT response parsing into transcript models.
//!
//! Ports the response-extraction policy from the Swift layer: a transcript
//! is read either from the flat `text` field (OpenAI-compatible) or from a
//! model-specific nested path (for example `result.text`), and word-level
//! timestamps are taken from `verbose_json` responses where present.
//! Transport stays native; the engine consumes normalized responses.
//!
//! The parser is a deliberately small JSON subset reader (objects, arrays,
//! strings with escapes, numbers, literals) with no external dependencies
//! so the core stays portable and auditable.

/// A word with relative timestamps in seconds.
#[derive(Debug, Clone, PartialEq)]
pub struct TimedWord {
    pub word: String,
    pub start: f64,
    pub end: f64,
}

/// Normalized transcription result.
#[derive(Debug, Clone, PartialEq)]
pub struct Transcript {
    pub text: String,
    pub words: Vec<TimedWord>,
}

/// Minimal JSON value model for response extraction.
#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    fn get(&self, key: &str) -> Option<&JsonValue> {
        match self {
            Self::Object(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s),
            _ => None,
        }
    }

    fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Number(n) => Some(*n),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    pub message: String,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ParseError {}

struct Parser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    pos: usize,
    depth: usize,
}

const MAX_DEPTH: usize = 64;

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            bytes: text.as_bytes(),
            pos: 0,
            depth: 0,
        }
    }

    fn error(&self, what: &str) -> ParseError {
        ParseError {
            message: format!("invalid JSON at byte {}: {what}", self.pos),
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), ParseError> {
        if self.peek() == Some(byte) {
            self.pos += 1;
            Ok(())
        } else {
            Err(self.error("unexpected character"))
        }
    }

    fn parse_value(&mut self) -> Result<JsonValue, ParseError> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') | Some(b'[') => {
                if self.depth >= MAX_DEPTH {
                    return Err(self.error("nesting too deep"));
                }
                self.depth += 1;
                let result = if self.peek() == Some(b'{') {
                    self.parse_object()
                } else {
                    self.parse_array()
                };
                self.depth -= 1;
                result
            }
            Some(b'"') => Ok(JsonValue::String(self.parse_string()?)),
            Some(b't') => self.parse_literal("true", JsonValue::Bool(true)),
            Some(b'f') => self.parse_literal("false", JsonValue::Bool(false)),
            Some(b'n') => self.parse_literal("null", JsonValue::Null),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.parse_number(),
            _ => Err(self.error("unexpected character")),
        }
    }

    fn parse_literal(&mut self, word: &str, value: JsonValue) -> Result<JsonValue, ParseError> {
        if self.bytes[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(value)
        } else {
            Err(self.error("bad literal"))
        }
    }

    fn parse_number(&mut self) -> Result<JsonValue, ParseError> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.pos += 1;
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| self.error("bad number"))?;
        text.parse::<f64>()
            .map(JsonValue::Number)
            .map_err(|_| self.error("bad number"))
    }

    fn parse_string(&mut self) -> Result<String, ParseError> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            match self.peek() {
                None => return Err(self.error("unterminated string")),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    match self.peek() {
                        Some(b'"') => out.push('"'),
                        Some(b'\\') => out.push('\\'),
                        Some(b'/') => out.push('/'),
                        Some(b'b') => out.push('\u{0008}'),
                        Some(b'f') => out.push('\u{000C}'),
                        Some(b'n') => out.push('\n'),
                        Some(b'r') => out.push('\r'),
                        Some(b't') => out.push('\t'),
                        Some(b'u') => {
                            self.pos += 1; // consume 'u'
                            let mut code = self.read_hex4()?;
                            if (0xD800..0xDC00).contains(&code) {
                                if self.bytes.get(self.pos..self.pos + 2) != Some(b"\\u".as_slice())
                                {
                                    return Err(self.error("unpaired surrogate"));
                                }
                                self.pos += 2;
                                let low = self.read_hex4()?;
                                if !(0xDC00..0xE000).contains(&low) {
                                    return Err(self.error("unpaired surrogate"));
                                }
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                            } else if (0xDC00..0xE000).contains(&code) {
                                return Err(self.error("unpaired surrogate"));
                            }
                            out.push(
                                char::from_u32(code)
                                    .ok_or_else(|| self.error("bad unicode escape"))?,
                            );
                            self.pos -= 1; // +1 from the common increment below
                        }
                        _ => return Err(self.error("bad escape")),
                    }
                    self.pos += 1;
                }
                Some(_) => {
                    // `pos` always sits on a char boundary: it advances only
                    // over ASCII bytes or whole multi-byte characters.
                    let text = self.text;
                    let ch = text
                        .get(self.pos..)
                        .and_then(|rest| rest.chars().next())
                        .ok_or_else(|| self.error("bad string bytes"))?;
                    out.push(ch);
                    self.pos += ch.len_utf8();
                }
            }
        }
    }

    /// Reads four hex digits at `pos` and advances past them.
    fn read_hex4(&mut self) -> Result<u32, ParseError> {
        let slice = self
            .bytes
            .get(self.pos..self.pos + 4)
            .filter(|s| s.iter().all(u8::is_ascii_hexdigit))
            .ok_or_else(|| self.error("bad unicode escape"))?;
        // SAFETY: filtered to ASCII hex digits above, so always valid UTF-8.
        let code = u32::from_str_radix(std::str::from_utf8(slice).unwrap(), 16)
            .map_err(|_| self.error("bad unicode escape"))?;
        self.pos += 4;
        Ok(code)
    }

    fn parse_array(&mut self) -> Result<JsonValue, ParseError> {
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(JsonValue::Array(items));
        }
        loop {
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    return Ok(JsonValue::Array(items));
                }
                _ => return Err(self.error("expected ',' or ']'")),
            }
        }
    }

    fn parse_object(&mut self) -> Result<JsonValue, ParseError> {
        self.expect(b'{')?;
        let mut entries = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(JsonValue::Object(entries));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(self.error("expected string key"));
            }
            let key = self.parse_string()?;
            self.skip_ws();
            self.expect(b':')?;
            let value = self.parse_value()?;
            entries.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(JsonValue::Object(entries));
                }
                _ => return Err(self.error("expected ',' or '}'")),
            }
        }
    }
}

/// Parses a JSON document into a [`JsonValue`].
pub fn parse_json(text: &str) -> Result<JsonValue, ParseError> {
    let mut parser = Parser::new(text);
    let value = parser.parse_value()?;
    parser.skip_ws();
    if parser.pos != parser.bytes.len() {
        return Err(parser.error("trailing data"));
    }
    Ok(value)
}

/// Extracts the transcript text following `path` (`None` means the flat
/// `text` field). Empty or whitespace-only text counts as an empty result.
/// Path segments may address object keys or array indices (mirrors the
/// Swift `ProviderRequestBuilder.extractText` walk).
pub fn extract_text(root: &JsonValue, path: Option<&[String]>) -> Result<String, ParseError> {
    let mut node = root;
    if let Some(segments) = path {
        for segment in segments {
            node = descend(node, segment).ok_or_else(|| ParseError {
                message: format!("missing transcript field '{}'", segments.join(".")),
            })?;
        }
    } else {
        node = node.get("text").ok_or_else(|| ParseError {
            message: "missing transcript field 'text'".to_string(),
        })?;
    }
    node.as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| ParseError {
            message: "transcript field is not a string".to_string(),
        })
}

/// Descends one path segment into an object key or an array index.
fn descend<'a>(node: &'a JsonValue, segment: &str) -> Option<&'a JsonValue> {
    if let Some(next) = node.get(segment) {
        return Some(next);
    }
    if let JsonValue::Array(items) = node {
        if let Ok(index) = segment.parse::<usize>() {
            return items.get(index);
        }
    }
    None
}

/// Extracts word-level timestamps from a `verbose_json` response
/// (`words: [{word, start, end}]`). Missing or malformed word entries
/// degrade to an empty list, never to an error. With a transcript `path`
/// (for example Cloudflare `result.text`), words are read from the sibling
/// `words` array under the path parent (mirrors the Swift
/// `ProviderRequestBuilder.extractWords` walk); a short path degrades to
/// an empty list. Both `word` and `punctuated_word` keys are accepted.
pub fn extract_words(root: &JsonValue) -> Vec<TimedWord> {
    extract_words_with_path(root, None)
}

/// Path-aware word extraction (see [`extract_words`]).
pub fn extract_words_with_path(root: &JsonValue, path: Option<&[String]>) -> Vec<TimedWord> {
    let mut out = Vec::new();
    let container: &JsonValue = match path {
        None => root,
        Some(segments) => {
            if segments.len() <= 1 {
                return out;
            }
            let mut node = root;
            let mut valid = true;
            for segment in &segments[..segments.len() - 1] {
                match descend(node, segment) {
                    Some(next) => node = next,
                    None => {
                        valid = false;
                        break;
                    }
                }
            }
            if !valid {
                return out;
            }
            node
        }
    };
    let words = container.get("words").and_then(|v| match v {
        JsonValue::Array(items) => Some(items),
        _ => None,
    });
    let items = match words {
        Some(items) => items,
        None => return out,
    };
    for item in items {
        let word = item
            .get("word")
            .and_then(JsonValue::as_str)
            .or_else(|| item.get("punctuated_word").and_then(JsonValue::as_str));
        let (Some(word), Some(start), Some(end)) = (
            word,
            item.get("start").and_then(JsonValue::as_f64),
            item.get("end").and_then(JsonValue::as_f64),
        ) else {
            continue;
        };
        if start.is_finite() && end.is_finite() {
            out.push(TimedWord {
                word: word.to_string(),
                start,
                end,
            });
        }
    }
    out
}

/// Parses an STT response body into a [`Transcript`].
pub fn parse_transcript(body: &str, path: Option<&[String]>) -> Result<Transcript, ParseError> {
    let root = parse_json(body)?;
    let text = extract_text(&root, path)?;
    let words = extract_words_with_path(&root, path);
    Ok(Transcript { text, words })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flat_text_response() {
        let t = parse_transcript(r#"{"text": "hello world"}"#, None).unwrap();
        assert_eq!(t.text, "hello world");
        assert!(t.words.is_empty());
    }

    #[test]
    fn nested_transcript_path() {
        let path = ["result".to_string(), "text".to_string()];
        let t = parse_transcript(r#"{"result": {"text": "nested ok"}}"#, Some(&path)).unwrap();
        assert_eq!(t.text, "nested ok");
    }

    #[test]
    fn missing_text_field_is_an_error() {
        assert!(parse_transcript(r#"{"nope": 1}"#, None).is_err());
        assert!(parse_transcript(r#"not json"#, None).is_err());
        assert!(parse_transcript(r#"{"text": 42}"#, None).is_err());
    }

    #[test]
    fn verbose_words_extracted_with_timestamps() {
        let body = r#"{
            "text": "hi there",
            "words": [
                {"word": "hi", "start": 0.0, "end": 0.2},
                {"word": "there", "start": 0.2, "end": 0.5},
                {"word": "broken"}
            ]
        }"#;
        let t = parse_transcript(body, None).unwrap();
        assert_eq!(t.text, "hi there");
        assert_eq!(t.words.len(), 2);
        assert_eq!(
            t.words[0],
            TimedWord {
                word: "hi".to_string(),
                start: 0.0,
                end: 0.2,
            }
        );
    }

    #[test]
    fn string_escapes_and_unicode() {
        let t = parse_transcript(r#"{"text": "a\"b\\c\n\u0041"}"#, None).unwrap();
        assert_eq!(t.text, "a\"b\\c\nA");
    }

    #[test]
    fn surrogate_pair_decodes_to_non_bmp_character() {
        let t = parse_transcript(r#"{"text": "\ud83d\ude00"}"#, None).unwrap();
        assert_eq!(t.text, "😀");
    }

    #[test]
    fn unpaired_surrogate_is_an_error() {
        assert!(parse_transcript(r#"{"text": "\ud83d"}"#, None).is_err());
        assert!(parse_transcript(r#"{"text": "\ude00"}"#, None).is_err());
        assert!(parse_transcript(r#"{"text": "\ud83d\u0041"}"#, None).is_err());
    }

    #[test]
    fn deeply_nested_input_is_rejected() {
        let deep = format!("{}{}", "[".repeat(128), "]".repeat(128));
        assert!(parse_json(&deep).is_err());
        assert!(parse_json("[[[[1]]]]").is_ok());
    }

    #[test]
    fn empty_text_is_empty_result_not_error() {
        let t = parse_transcript(r#"{"text": "   "}"#, None).unwrap();
        assert!(t.text.trim().is_empty());
    }

    #[test]
    fn punctuated_word_fallback_matches_swift() {
        let t = parse_transcript(
            r#"{"text": "hi", "words": [{"punctuated_word": "Hi,", "start": 0.0, "end": 0.3}]}"#,
            None,
        )
        .unwrap();
        assert_eq!(t.words.len(), 1);
        assert_eq!(t.words[0].word, "Hi,");
    }

    #[test]
    fn nested_path_reads_sibling_words_like_swift() {
        // Cloudflare-style: words live under the path parent (result.words).
        let path = ["result".to_string(), "text".to_string()];
        let t = parse_transcript(
            r#"{"result": {"text": "nested ok", "words": [{"word": "nested", "start": 0.0, "end": 0.4}]}}"#,
            Some(&path),
        )
        .unwrap();
        assert_eq!(t.text, "nested ok");
        assert_eq!(t.words.len(), 1);
        // Top-level words are NOT read when a path selects a nested text.
        let top = parse_transcript(
            r#"{"result": {"text": "nested ok"}, "words": [{"word": "top", "start": 0.0, "end": 0.1}]}"#,
            Some(&path),
        )
        .unwrap();
        assert!(top.words.is_empty());
        // A single-segment path degrades to an empty word list, never an error.
        let short = ["text".to_string()];
        let t = parse_transcript(r#"{"text": "hi"}"#, Some(&short)).unwrap();
        assert!(t.words.is_empty());
    }

    #[test]
    fn array_index_path_segments() {
        let path = ["items".to_string(), "1".to_string(), "text".to_string()];
        let t = parse_transcript(
            r#"{"items": [{"text": "first"}, {"text": "second"}]}"#,
            Some(&path),
        )
        .unwrap();
        assert_eq!(t.text, "second");
        assert!(parse_transcript(r#"{"items": [{"text": "first"}]}"#, Some(&path)).is_err());
    }
}
