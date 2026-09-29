//! Word-level diff between inserted chunk text and the final full-pass text.
//!
//! Ports `WordDiff` from the Swift layer. The diff emits one contiguous
//! change range (common prefix/suffix over words) so the native insertion
//! layer performs a single backspace-and-retype action at the end of the
//! inserted text, keeping the user's undo history intact.
//!
//! Offsets are counted in Unicode scalar values (`char`s). For plain
//! Latin/Cyrillic text this coincides with Swift `String` character
//! offsets; text with multi-scalar grapheme clusters (emoji with joiners,
//! combining marks) may differ by cluster boundaries and is covered by the
//! native layer, which owns Unicode text insertion.

/// One contiguous change between the inserted and the final text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WordChange {
    pub old_text: String,
    pub new_text: String,
    /// Changed words of the old text (single-spaced). Empty on pure insertion.
    pub span_old: String,
    /// Changed words of the new text. Empty on pure deletion.
    pub span_new: String,
    /// Scalar offset of the divergence start in `old_text`.
    pub span_start_old: usize,
    /// Scalar offset of the divergence start in `new_text`.
    pub span_start_new: usize,
}

impl WordChange {
    /// Old-text tail from the divergence start: exactly what backspace removes.
    pub fn tail_old(&self) -> String {
        tail_from_offset(&self.old_text, self.span_start_old)
    }

    /// New-text tail from the divergence start: what to print.
    pub fn tail_new(&self) -> String {
        tail_from_offset(&self.new_text, self.span_start_new)
    }
}

/// Splits text into non-whitespace runs.
pub fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(|w| w.to_string()).collect()
}

fn tail_from_offset(text: &str, offset: usize) -> String {
    text.chars().skip(offset).collect()
}

/// Scalar offset right after the end of the n-th word (`n == 0` yields 0).
fn offset_after_words(word_count: usize, text: &str) -> usize {
    if word_count == 0 {
        return 0;
    }
    let chars: Vec<char> = text.chars().collect();
    let mut seen = 0usize;
    let mut i = 0usize;
    while i < chars.len() {
        if !chars[i].is_whitespace() {
            let mut end = i;
            while end < chars.len() && !chars[end].is_whitespace() {
                end += 1;
            }
            seen += 1;
            if seen == word_count {
                return end;
            }
            i = end;
        } else {
            i += 1;
        }
    }
    chars.len()
}

/// Word-level diff between inserted (`old`) and final (`new`) text.
/// Returns `None` when there is nothing to change (texts match word-wise,
/// including whitespace-only differences outside words).
pub fn change(old: &str, new: &str) -> Option<WordChange> {
    if old == new {
        return None;
    }
    let old_words = words(old);
    let new_words = words(new);

    let mut prefix = 0usize;
    while prefix < old_words.len()
        && prefix < new_words.len()
        && old_words[prefix] == new_words[prefix]
    {
        prefix += 1;
    }
    let mut suffix = 0usize;
    while suffix < old_words.len() - prefix
        && suffix < new_words.len() - prefix
        && old_words[old_words.len() - 1 - suffix] == new_words[new_words.len() - 1 - suffix]
    {
        suffix += 1;
    }

    if prefix == old_words.len() && prefix == new_words.len() {
        return None;
    }

    let span_old = old_words[prefix..old_words.len() - suffix].join(" ");
    let span_new = new_words[prefix..new_words.len() - suffix].join(" ");
    Some(WordChange {
        old_text: old.to_string(),
        new_text: new.to_string(),
        span_old,
        span_new,
        span_start_old: offset_after_words(prefix, old),
        span_start_new: offset_after_words(prefix, new),
    })
}

/// Text tail after the first `word_count` words. Returns an empty string
/// when `word_count` covers all words.
pub fn tail_after_words(word_count: usize, text: &str) -> String {
    tail_from_offset(text, offset_after_words(word_count, text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_returns_none() {
        assert_eq!(change("One two three.", "One two three."), None);
    }

    #[test]
    fn whitespace_only_diff_returns_none() {
        assert_eq!(change("One  two.", "One two."), None);
    }

    #[test]
    fn add_word_in_middle() {
        let c = change("One three.", "One two three.").expect("must differ");
        assert_eq!(c.span_old, "");
        assert_eq!(c.span_new, "two");
        assert_eq!(c.tail_old(), " three.");
        assert_eq!(c.tail_new(), " two three.");
        assert_eq!(c.span_start_old, 3);
        assert_eq!(c.span_start_new, 3);
    }

    #[test]
    fn cyrillic_vectors_match_swift_tests() {
        // Mirrors Tests/NanoDictateCoreTests/WordDiffTests.swift.
        let c = change("Один три.", "Один два три.").expect("must differ");
        assert_eq!(c.span_old, "");
        assert_eq!(c.span_new, "два");
        assert_eq!(c.tail_old(), " три.");
        assert_eq!(c.tail_new(), " два три.");
        assert_eq!(c.span_start_old, 4);
        assert_eq!(c.span_start_new, 4);

        let c = change("А Б В.", "А В.").expect("must differ");
        assert_eq!(c.span_old, "Б");
        assert_eq!(c.span_new, "");
        assert_eq!(c.tail_old(), " Б В.");
        assert_eq!(c.tail_new(), " В.");

        let c = change("Было слово.", "Стало слово.").expect("must differ");
        assert_eq!(c.span_old, "Было");
        assert_eq!(c.span_new, "Стало");
        assert_eq!(c.tail_old(), "Было слово.");
        assert_eq!(c.tail_new(), "Стало слово.");

        let c = change("Один два", "Один два три").expect("must differ");
        assert_eq!(c.span_old, "");
        assert_eq!(c.span_new, "три");
        assert_eq!(c.span_start_old, 8);
        assert_eq!(c.span_start_new, 8);
        assert_eq!(c.tail_old(), "");
        assert_eq!(c.tail_new(), " три");

        let c = change("Один два три.", "").expect("must differ");
        assert_eq!(c.span_old, "Один два три.");
        assert_eq!(c.span_new, "");
        assert_eq!(c.span_start_old, 0);

        let c = change("", "Привет мир.").expect("must differ");
        assert_eq!(c.span_old, "");
        assert_eq!(c.span_new, "Привет мир.");
        assert_eq!(c.span_start_old, 0);

        let c = change("Привет мир.", "привет мир.").expect("must differ");
        assert_eq!(c.span_old, "Привет");
        assert_eq!(c.span_new, "привет");
    }

    #[test]
    fn tail_after_words_vectors() {
        assert_eq!(tail_after_words(0, "a b"), "a b");
        assert_eq!(tail_after_words(1, "a b c"), " b c");
        assert_eq!(tail_after_words(3, "a b c"), "");
        assert_eq!(tail_after_words(9, "a b c"), "");
    }
}
