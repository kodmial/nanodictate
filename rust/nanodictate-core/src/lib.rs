//! Shared portable dictation engine for NanoDictate.
//!
//! This crate owns behavior whose meaning does not depend on the operating
//! system: audio-domain math over already captured samples, voice activity
//! detection, segmentation, WAV codec, transcript models, STT provider policy,
//! retry/failover policy, and the dictation session state machine.
//!
//! The crate must never depend on Apple-only (or Windows-only) APIs. All
//! platform integration (microphone acquisition, permissions, event taps,
//! text injection, packaging) stays in the native layer and talks to this
//! engine through the stable C ABI in [`abi`]. The engine is linked into the
//! macOS build while production call-site activation remains an explicit,
//! parity-gated migration step.

pub mod abi;
pub mod audio_metrics;
pub mod autostop;
pub mod error;
pub mod input_gain;
pub mod retry;
pub mod segmenter;
pub mod session;
pub mod stt;
pub mod text_joiner;
pub mod transcript;
pub mod vad;
pub mod wav;
pub mod word_diff;
