//! Retry and provider-failover policy.
//!
//! Ports the deterministic core of `RetryProvider` from the Swift layer:
//! the failover candidate ordering and the error classification that
//! decides whether failover may proceed. Async transcription itself stays
//! native; the engine only answers "in which order" and "is this error
//! retryable by another provider".

/// Transcribe-layer error classes. Only [`TranscribeKind::Transcribe`]
/// errors (network/server/response) may trigger provider failover;
/// anything else (microphone errors, cancellations) is rethrown at once.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscribeKind {
    Transcribe,
    Other,
}

/// Orders failover candidates. With auto-failover on, the last-failed
/// provider moves to the end of the queue so it is retried only after
/// every other candidate. With auto-failover off the order is untouched
/// (the caller tries only the first candidate).
pub fn failover_order(
    order: &[String],
    last_failed_provider_id: Option<&str>,
    auto_failover: bool,
) -> Vec<String> {
    let mut attempts = order.to_vec();
    if auto_failover {
        if let Some(failed) = last_failed_provider_id {
            if let Some(index) = attempts.iter().position(|id| id == failed) {
                let provider = attempts.remove(index);
                attempts.push(provider);
            }
        }
    }
    attempts
}

/// Number of candidates the caller may attempt: all with auto-failover,
/// exactly one without.
pub fn candidate_count(order_len: usize, auto_failover: bool) -> usize {
    if auto_failover {
        order_len
    } else {
        order_len.min(1)
    }
}

/// Whether a failed attempt of `kind` may fall over to the next provider.
pub fn should_failover(kind: TranscribeKind) -> bool {
    kind == TranscribeKind::Transcribe
}

/// Exponential backoff delay in milliseconds for `attempt` (0-based),
/// doubling from `base_ms` and capped at `cap_ms`. Deterministic (no
/// jitter): the native layer adds jitter if a deployment needs it.
pub fn backoff_delay_ms(attempt: u32, base_ms: u64, cap_ms: u64) -> u64 {
    let shift = attempt.min(16);
    base_ms.saturating_mul(1u64 << shift).min(cap_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn failed_provider_moves_to_end_with_auto_failover() {
        let order = ids(&["a", "b", "c"]);
        assert_eq!(
            failover_order(&order, Some("a"), true),
            ids(&["b", "c", "a"])
        );
        assert_eq!(
            failover_order(&order, Some("b"), true),
            ids(&["a", "c", "b"])
        );
    }

    #[test]
    fn order_untouched_without_auto_failover() {
        let order = ids(&["a", "b", "c"]);
        assert_eq!(failover_order(&order, Some("a"), false), order);
        assert_eq!(failover_order(&order, None, true), order);
        assert_eq!(failover_order(&order, Some("zzz"), true), order);
    }

    #[test]
    fn candidate_count_vectors() {
        assert_eq!(candidate_count(3, true), 3);
        assert_eq!(candidate_count(3, false), 1);
        assert_eq!(candidate_count(0, true), 0);
        assert_eq!(candidate_count(0, false), 0);
    }

    #[test]
    fn only_transcribe_errors_fail_over() {
        assert!(should_failover(TranscribeKind::Transcribe));
        assert!(!should_failover(TranscribeKind::Other));
    }

    #[test]
    fn backoff_doubles_and_caps() {
        assert_eq!(backoff_delay_ms(0, 500, 8000), 500);
        assert_eq!(backoff_delay_ms(1, 500, 8000), 1000);
        assert_eq!(backoff_delay_ms(4, 500, 8000), 8000);
        assert_eq!(backoff_delay_ms(100, 500, 8000), 8000);
    }
}
