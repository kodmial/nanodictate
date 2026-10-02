//! Chunk-text stitching with boundary-overlap deduplication.
//!
//! Ports `BatchTextJoiner` from the Swift layer. Consecutive chunk texts
//! overlap by design (each chunk carries the tail of the previous body as
//! context), so the same words may be recognized twice. The join drops the
//! largest duplicated boundary run: the longest `k` such that the last `k`
//! words of the previous text equal the first `k` words of the next text
//! (case-insensitive). Skipped-chunk placeholders join verbatim and never
//! participate in dedup.

/// Placeholder emitted for a skipped chunk. Joined verbatim on both sides.
pub const PLACEHOLDER: &str = "[…]";

/// Split into non-whitespace runs (same definition as `word_diff::words`).
pub fn words(text: &str) -> Vec<&str> {
    text.split_whitespace().collect()
}

/// Trims and collapses all whitespace runs (including newlines) to single spaces.
pub fn collapse(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Number of leading words of `next` that duplicate trailing words of
/// `previous`. Comparison is case-insensitive, punctuation verbatim.
pub fn boundary_drop_count(previous: &str, next: &str) -> usize {
    let prev = words(previous);
    let next_w = words(next);
    if prev.is_empty() || next_w.is_empty() {
        return 0;
    }
    let max_k = prev.len().min(next_w.len());
    for k in (1..=max_k).rev() {
        let suffix = &prev[prev.len() - k..];
        let prefix = &next_w[..k];
        if suffix
            .iter()
            .map(|w| w.to_lowercase())
            .eq(prefix.iter().map(|w| w.to_lowercase()))
        {
            return k;
        }
    }
    0
}

/// Joins chunk texts with boundary dedup. Empty (post-collapse) texts are
/// skipped. Placeholder chunks join verbatim without dedup.
pub fn join(texts: &[&str]) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut previous = String::new();
    for raw in texts {
        let text = collapse(raw);
        if text.is_empty() {
            continue;
        }
        let drop = if previous == PLACEHOLDER || text == PLACEHOLDER {
            0
        } else {
            boundary_drop_count(&previous, &text)
        };
        let tail = if drop > 0 {
            words(&text)[drop..].join(" ")
        } else {
            text.clone()
        };
        if !tail.is_empty() {
            parts.push(tail);
        }
        previous = text;
    }
    parts.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_overlap_joins_with_space() {
        assert_eq!(join(&["hello world", "foo bar"]), "hello world foo bar");
    }

    #[test]
    fn boundary_dup_dropped_once() {
        assert_eq!(
            join(&["hello brave world", "brave world again"]),
            "hello brave world again"
        );
    }

    #[test]
    fn dedup_is_case_insensitive() {
        assert_eq!(
            join(&["Hello World", "hello world again"]),
            "Hello World again"
        );
    }

    #[test]
    fn largest_k_wins() {
        assert_eq!(join(&["a b a b", "a b c"]), "a b a b c");
    }

    #[test]
    fn placeholder_joins_verbatim() {
        assert_eq!(
            join(&["first part", PLACEHOLDER, "last part"]),
            "first part […] last part"
        );
        assert_eq!(join(&[PLACEHOLDER, PLACEHOLDER]), "[…] […]");
    }

    #[test]
    fn empties_and_whitespace_skipped() {
        assert_eq!(join(&["", "  ", "hello"]), "hello");
        assert_eq!(join(&["a\nb", "c"]), "a b c");
        assert_eq!(join(&[] as &[&str]), "");
    }
}
