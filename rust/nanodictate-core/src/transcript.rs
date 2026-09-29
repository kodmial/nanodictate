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
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            bytes: text.as_bytes(),
            pos: 0,
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
            Some(b'{') => self.parse_object(),
            Some(b'[') => self.parse_array(),
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
                            self.pos += 1;
                            if self.pos + 4 > self.bytes.len() {
                                return Err(self.error("bad unicode escape"));
                            }
                            let hex = std::str::from_utf8(&self.bytes[self.pos..self.pos + 4])
                                .map_err(|_| self.error("bad unicode escape"))?;
                            let code = u32::from_str_radix(hex, 16)
                                .map_err(|_| self.error("bad unicode escape"))?;
                            out.push(
                                char::from_u32(code)
                                    .ok_or_else(|| self.error("bad unicode escape"))?,
                            );
                            self.pos += 3; // +1 from the common increment below
                        }
                        _ => return Err(self.error("bad escape")),
                    }
                    self.pos += 1;
                }
                Some(_) => {
                    // Copy the full UTF-8 sequence starting here.
                    let rest = std::str::from_utf8(&self.bytes[self.pos..])
                        .map_err(|_| self.error("bad string bytes"))?;
                    let ch = rest
                        .chars()
                        .next()
                        .ok_or_else(|| self.error("bad string bytes"))?;
                    out.push(ch);
                    self.pos += ch.len_utf8();
                }
            }
        }
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
pub fn extract_text(root: &JsonValue, path: Option<&[String]>) -> Result<String, ParseError> {
    let mut node = root;
    if let Some(segments) = path {
        for segment in segments {
            node = node.get(segment).ok_or_else(|| ParseError {
                message: format!("missing transcript field '{segment}'"),
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

/// Extracts word-level timestamps from a `verbose_json` response
/// (`words: [{word, start, end}]`). Missing or malformed word entries
/// degrade to an empty list, never to an error.
pub fn extract_words(root: &JsonValue) -> Vec<TimedWord> {
    let mut out = Vec::new();
    let words = root.get("words").and_then(|v| match v {
        JsonValue::Array(items) => Some(items),
        _ => None,
    });
    let items = match words {
        Some(items) => items,
        None => return out,
    };
    for item in items {
        let (Some(word), Some(start), Some(end)) = (
            item.get("word").and_then(JsonValue::as_str),
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
    let words = extract_words(&root);
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
    fn empty_text_is_empty_result_not_error() {
        let t = parse_transcript(r#"{"text": "   "}"#, None).unwrap();
        assert!(t.text.trim().is_empty());
    }
}
