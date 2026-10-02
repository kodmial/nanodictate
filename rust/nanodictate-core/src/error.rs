//! Stable error codes for the C ABI.
//!
//! Every fallible `extern "C"` entry point returns one of these codes (or a
//! null pointer on string-returning functions) and records a diagnostic in
//! the thread-local last-error slot. Numeric codes are part of the ABI
//! contract and must never be renumbered.

/// Success.
pub const ND_OK: i32 = 0;
/// A required pointer argument was null.
pub const ND_ERR_NULL: i32 = 1;
/// Input bytes were not valid UTF-8 where UTF-8 was required.
pub const ND_ERR_UTF8: i32 = 2;
/// An argument was out of range (negative length, bad rate, ...).
pub const ND_ERR_ARG: i32 = 3;
/// The caller-provided output buffer is too small.
pub const ND_ERR_SMALL_BUFFER: i32 = 4;
/// The input could not be decoded (malformed WAV/JSON, ...).
pub const ND_ERR_DECODE: i32 = 5;
/// Internal error (allocation failure, poisoned lock, ...).
pub const ND_ERR_INTERNAL: i32 = 6;
/// A Rust panic was caught at the ABI boundary.
pub const ND_ERR_PANIC: i32 = 100;

use std::cell::RefCell;

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Records the thread-local last-error diagnostic text.
pub fn set_last_error(message: String) {
    LAST_ERROR.with(|slot| {
        let mut guard = slot.borrow_mut();
        guard.clear();
        guard.push_str(&message);
    });
}

/// Returns a copy of the thread-local last-error diagnostic text.
pub fn last_error() -> String {
    LAST_ERROR.with(|slot| slot.borrow().clone())
}

/// Maps an internal failure to an ABI code and records the diagnostic.
pub fn fail(code: i32, message: String) -> i32 {
    set_last_error(message);
    code
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes_are_stable() {
        assert_eq!(ND_OK, 0);
        assert_eq!(ND_ERR_NULL, 1);
        assert_eq!(ND_ERR_UTF8, 2);
        assert_eq!(ND_ERR_ARG, 3);
        assert_eq!(ND_ERR_SMALL_BUFFER, 4);
        assert_eq!(ND_ERR_DECODE, 5);
        assert_eq!(ND_ERR_INTERNAL, 6);
        assert_eq!(ND_ERR_PANIC, 100);
    }

    #[test]
    fn last_error_roundtrip() {
        set_last_error("boom".to_string());
        assert_eq!(last_error(), "boom");
        set_last_error(String::new());
        assert_eq!(last_error(), "");
    }
}
