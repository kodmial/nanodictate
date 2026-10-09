//! Stable C ABI of the shared engine.
//!
//! Contract (also documented in `docs/architecture-rust-engine.md`):
//!
//! - Only C-compatible representations cross the boundary: integers,
//!   floats, pointers, `#[repr(C)]` structs, NUL-terminated UTF-8 strings,
//!   and opaque handles (`NdVad`, `NdGain`, `NdAutoStop`, `NdSession`,
//!   `NdCooldown`, `NdLatch`).
//! - Strings and buffers use explicit pointer + length contracts on input.
//!   Output strings are freshly allocated NUL-terminated UTF-8 owned by
//!   the caller and released with [`nd_string_free`]. Output byte buffers
//!   are [`NdByteBuffer`] values released with [`nd_bytes_free`].
//! - Every fallible entry point returns a stable code from [`crate::error`]
//!   (`0` is success) and records a diagnostic retrievable with
//!   [`nd_last_error_text`]. String-returning functions return NULL on
//!   error. Rust panics never unwind across the boundary: every entry
//!   point catches panics and maps them to `ND_ERR_PANIC` (or NULL).
//! - Handles are opaque, heap-allocated, and must be released with their
//!   matching `*_free` function. Handles are movable across threads but
//!   not thread-safe: external synchronization is required, exactly like
//!   the Swift objects they mirror. Realtime audio entry points perform
//!   O(n) math with no allocation, no locks, no I/O, and no synchronous
//!   network work.
//! - [`ND_ABI_VERSION`] is bumped on any incompatible ABI change.
//!
//! Note on `clippy::not_unsafe_ptr_arg_deref`: `extern "C"` entry points
//! cannot be declared `unsafe` without breaking foreign callers, so raw
//! pointer contracts are validated at runtime (null checks, UTF-8 checks,
//! capacity checks) instead. Every dereference site documents its
//! contract in a `SAFETY` comment.

// C ABI entry points take raw pointers by design; contracts are enforced
// at runtime (see the module docs above).
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use crate::autostop::SilenceAutoStopDetector;
use crate::error::{
    fail, last_error, set_last_error, ND_ERR_ARG, ND_ERR_DECODE, ND_ERR_NULL, ND_ERR_PANIC,
    ND_ERR_SMALL_BUFFER, ND_ERR_UTF8, ND_OK,
};
use crate::input_gain::{InputGain, InputGainConfig};
use crate::retry::{backoff_delay_ms, candidate_count, failover_order, TranscribeKind};
use crate::segmenter::SegmenterConfig;
use crate::session::{
    mic_request_allowed, overlay_should_hide, review_decide, should_drop_retry, DictationSession,
    DictationState, EnterSendLatch, MicErrorCooldown, ReviewDecision, SessionEvent,
};
use crate::stt::TransportKind as EngineTransport;
use crate::vad::AdaptiveVadConfig;
use crate::{audio_metrics, stt, transcript, vad, wav, word_diff};
use std::ffi::CString;
use std::os::raw::{c_char, c_double, c_float};
use std::panic::{catch_unwind, AssertUnwindSafe};

/// ABI version. Bumped on any incompatible change to this module.
pub const ND_ABI_VERSION: u32 = 1;

/// Dictation cycle state codes (see [`DictationState`]).
pub const ND_STATE_IDLE: u32 = 0;
pub const ND_STATE_RECORDING: u32 = 1;
pub const ND_STATE_TRANSCRIBING: u32 = 2;

/// Session event codes (see [`SessionEvent`]).
pub const ND_EVENT_ENGINE_STARTED: u32 = 0;
pub const ND_EVENT_FIRST_BUFFER: u32 = 1;
pub const ND_EVENT_ENGINE_FAILED: u32 = 2;
pub const ND_EVENT_CANCELLED: u32 = 3;
pub const ND_EVENT_STOP_REQUESTED: u32 = 4;
pub const ND_EVENT_TRANSCRIPTION_DONE: u32 = 5;

/// Byte buffer owned by the caller. Release with [`nd_bytes_free`].
#[repr(C)]
pub struct NdByteBuffer {
    pub data: *mut u8,
    pub len: usize,
    pub cap: usize,
}

/// Opaque adaptive VAD handle.
pub struct NdVad {
    inner: vad::AdaptiveVad,
}

/// Opaque input-gain handle.
pub struct NdGain {
    inner: InputGain,
}

/// Opaque silence auto-stop handle.
pub struct NdAutoStop {
    inner: SilenceAutoStopDetector,
}

/// Opaque dictation session handle.
pub struct NdSession {
    inner: DictationSession,
}

/// Opaque mic-error cooldown handle.
pub struct NdCooldown {
    inner: MicErrorCooldown,
}

/// Opaque enter-send latch handle.
pub struct NdLatch {
    inner: EnterSendLatch,
}

// Handles must be movable across threads for host dispatch queues.
#[cfg(test)]
#[test]
fn handles_are_send() {
    fn is_send<T: Send>() {}
    is_send::<NdVad>();
    is_send::<NdGain>();
    is_send::<NdAutoStop>();
    is_send::<NdSession>();
    is_send::<NdCooldown>();
    is_send::<NdLatch>();
}

fn slice_from<'a, T>(ptr: *const T, len: usize) -> Result<&'a [T], i32> {
    if ptr.is_null() {
        if len == 0 {
            return Ok(&[]);
        }
        set_last_error("null pointer argument".to_string());
        return Err(ND_ERR_NULL);
    }
    if len > isize::MAX as usize {
        set_last_error("length out of range".to_string());
        return Err(ND_ERR_ARG);
    }
    // SAFETY: the caller guarantees a valid readable region of `len`
    // elements for the duration of the call (ABI contract).
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn slice_mut_from<'a, T>(ptr: *mut T, len: usize) -> Result<&'a mut [T], i32> {
    if ptr.is_null() {
        if len == 0 {
            return Ok(&mut []);
        }
        set_last_error("null pointer argument".to_string());
        return Err(ND_ERR_NULL);
    }
    if len > isize::MAX as usize {
        set_last_error("length out of range".to_string());
        return Err(ND_ERR_ARG);
    }
    // SAFETY: same contract as `slice_from`, with exclusive access.
    Ok(unsafe { std::slice::from_raw_parts_mut(ptr, len) })
}

fn str_from(ptr: *const c_char, len: usize) -> Result<&'static str, i32> {
    // The returned borrow is tied to the caller's buffer, which outlives
    // the call; the 'static bound only keeps call sites simple because
    // every use is consumed before returning.
    let bytes = slice_from(ptr as *const u8, len)?;
    std::str::from_utf8(bytes).map_err(|_| {
        set_last_error("input is not valid UTF-8".to_string());
        ND_ERR_UTF8
    })
}

fn alloc_string(text: &str) -> *mut c_char {
    match CString::new(text) {
        Ok(owned) => owned.into_raw(),
        Err(_) => {
            set_last_error("output contains an interior NUL byte".to_string());
            std::ptr::null_mut()
        }
    }
}

fn escape_json(text: &str, out: &mut String) {
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
}

fn json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    escape_json(text, &mut out);
    out.push('"');
    out
}

fn decode_state(code: u32) -> Result<DictationState, i32> {
    match code {
        ND_STATE_IDLE => Ok(DictationState::Idle),
        ND_STATE_RECORDING => Ok(DictationState::Recording),
        ND_STATE_TRANSCRIBING => Ok(DictationState::Transcribing),
        _ => {
            set_last_error(format!("unknown state code {code}"));
            Err(ND_ERR_ARG)
        }
    }
}

fn decode_event(code: u32) -> Result<SessionEvent, i32> {
    match code {
        ND_EVENT_ENGINE_STARTED => Ok(SessionEvent::EngineStarted),
        ND_EVENT_FIRST_BUFFER => Ok(SessionEvent::FirstBuffer),
        ND_EVENT_ENGINE_FAILED => Ok(SessionEvent::EngineFailed),
        ND_EVENT_CANCELLED => Ok(SessionEvent::Cancelled),
        ND_EVENT_STOP_REQUESTED => Ok(SessionEvent::StopRequested),
        ND_EVENT_TRANSCRIPTION_DONE => Ok(SessionEvent::TranscriptionDone),
        _ => {
            set_last_error(format!("unknown event code {code}"));
            Err(ND_ERR_ARG)
        }
    }
}

fn with_handle<T>(ptr: *mut T, name: &str) -> Result<&'static mut T, i32> {
    if ptr.is_null() {
        set_last_error(format!("null {name} handle"));
        return Err(ND_ERR_NULL);
    }
    // SAFETY: the caller guarantees a live handle from the matching
    // constructor, used with external synchronization (ABI contract).
    Ok(unsafe { &mut *ptr })
}

// ---------------------------------------------------------------------------
// Version, errors, ownership.
// ---------------------------------------------------------------------------

/// Returns the ABI version ([`ND_ABI_VERSION`]).
#[no_mangle]
pub extern "C" fn nd_abi_version() -> u32 {
    ND_ABI_VERSION
}

/// Returns the thread-local last-error diagnostic as NUL-terminated UTF-8.
/// Valid until the next fallible call on the same thread. Never NULL.
#[no_mangle]
pub extern "C" fn nd_last_error_text() -> *const c_char {
    use std::cell::RefCell;
    thread_local! {
        static SLOT: RefCell<CString> = RefCell::new(CString::new("").unwrap_or_default());
    }
    SLOT.with(|slot| {
        let mut guard = slot.borrow_mut();
        *guard = CString::new(last_error()).unwrap_or_default();
        guard.as_ptr()
    })
}

/// Releases a string returned by this ABI. NULL is accepted and ignored.
#[no_mangle]
pub extern "C" fn nd_string_free(text: *mut c_char) {
    if text.is_null() {
        return;
    }
    // SAFETY: `text` came from `alloc_string` (CString::into_raw).
    let _ = unsafe { CString::from_raw(text) };
}

/// Releases an [`NdByteBuffer`] returned by this ABI.
#[no_mangle]
pub extern "C" fn nd_bytes_free(buffer: NdByteBuffer) {
    if buffer.data.is_null() {
        return;
    }
    // SAFETY: reconstructed from parts produced below; capacity is exact.
    let _ = unsafe { Vec::from_raw_parts(buffer.data, buffer.len, buffer.cap) };
}

fn bytes_out(data: Vec<u8>) -> NdByteBuffer {
    let mut data = data;
    let buffer = NdByteBuffer {
        data: data.as_mut_ptr(),
        len: data.len(),
        cap: data.capacity(),
    };
    std::mem::forget(data);
    buffer
}

// ---------------------------------------------------------------------------
// Audio metrics.
// ---------------------------------------------------------------------------

/// Linear amplitude (0..1) to dBFS. Never fails.
#[no_mangle]
pub extern "C" fn nd_dbfs(linear: c_float) -> c_float {
    audio_metrics::dbfs(linear)
}

/// RMS over Int16 samples (0..1). Returns -1.0 and records an error when
/// `samples` is NULL with a nonzero count.
#[no_mangle]
pub extern "C" fn nd_rms_i16(samples: *const i16, count: usize) -> c_float {
    match catch_unwind(AssertUnwindSafe(|| {
        slice_from(samples, count).map(audio_metrics::rms_i16)
    })) {
        Ok(Ok(value)) => value,
        Ok(Err(_)) => -1.0,
        Err(_) => {
            set_last_error("panic in nd_rms_i16".to_string());
            -1.0
        }
    }
}

/// RMS over Float32 samples (0..1). Same error convention as [`nd_rms_i16`].
#[no_mangle]
pub extern "C" fn nd_rms_f32(samples: *const c_float, count: usize) -> c_float {
    match catch_unwind(AssertUnwindSafe(|| {
        slice_from(samples, count).map(|s| {
            if s.is_empty() {
                return 0.0;
            }
            let mut sum = 0.0f32;
            for &v in s {
                sum += v * v;
            }
            (sum / s.len() as f32).sqrt()
        })
    })) {
        Ok(Ok(value)) => value,
        Ok(Err(_)) => -1.0,
        Err(_) => {
            set_last_error("panic in nd_rms_f32".to_string());
            -1.0
        }
    }
}

/// Bounded soft-limiter for one sample. Never fails.
#[no_mangle]
pub extern "C" fn nd_soft_limit(x: c_float) -> c_float {
    vad::SoftLimiter::process(x)
}

// ---------------------------------------------------------------------------
// WAV codec.
// ---------------------------------------------------------------------------

/// Encodes Int16 samples as 16-bit PCM WAV into `out`. Byte-identical to
/// the native encoder for the same inputs.
#[no_mangle]
pub extern "C" fn nd_wav_encode(
    samples: *const i16,
    count: usize,
    sample_rate: u32,
    channels: u16,
    out: *mut NdByteBuffer,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let samples = slice_from(samples, count)?;
        if out.is_null() {
            set_last_error("null output buffer".to_string());
            return Err(ND_ERR_NULL);
        }
        if sample_rate == 0 || channels == 0 {
            set_last_error("sample rate and channels must be nonzero".to_string());
            return Err(ND_ERR_ARG);
        }
        let bytes = wav::encode(samples, sample_rate, channels).ok_or_else(|| {
            set_last_error(
                "WAV header fields cannot represent inputs (byte_rate, block_align, or RIFF size overflow)".to_string(),
            );
            ND_ERR_ARG
        })?;
        // SAFETY: `out` is a valid caller-owned slot (ABI contract).
        unsafe {
            *out = bytes_out(bytes);
        }
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_wav_encode".to_string()),
    }
}

/// Reads WAV header metadata without copying samples. Only the window up
/// to the `data` chunk header must be present.
#[no_mangle]
pub extern "C" fn nd_wav_decode_info(
    data: *const u8,
    len: usize,
    out_sample_rate: *mut u32,
    out_channels: *mut u16,
    out_sample_count: *mut usize,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let data = slice_from(data, len)?;
        let header = wav::pcm_header(data).ok_or_else(|| {
            set_last_error("not a decodable PCM16 WAV".to_string());
            ND_ERR_DECODE
        })?;
        if out_sample_rate.is_null() || out_channels.is_null() || out_sample_count.is_null() {
            set_last_error("null output pointer".to_string());
            return Err(ND_ERR_NULL);
        }
        // SAFETY: caller-owned output slots (ABI contract).
        unsafe {
            *out_sample_rate = header.sample_rate;
            *out_channels = header.channels;
            *out_sample_count = header.sample_count();
        }
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_wav_decode_info".to_string()),
    }
}

/// Full WAV header metadata without copying samples: sample rate,
/// channels, bits per sample, PCM payload offset/size, and sample count.
/// Only the window up to the `data` chunk header must be present. This is
/// the file-backed batch source contract (the streaming capture path never
/// parses headers). Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_wav_header_full(
    data: *const u8,
    len: usize,
    out_sample_rate: *mut u32,
    out_channels: *mut u16,
    out_bits_per_sample: *mut u16,
    out_data_offset: *mut usize,
    out_data_size: *mut usize,
    out_sample_count: *mut usize,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let data = slice_from(data, len)?;
        let header = wav::pcm_header(data).ok_or_else(|| {
            set_last_error("not a decodable PCM16 WAV".to_string());
            ND_ERR_DECODE
        })?;
        if out_sample_rate.is_null()
            || out_channels.is_null()
            || out_bits_per_sample.is_null()
            || out_data_offset.is_null()
            || out_data_size.is_null()
            || out_sample_count.is_null()
        {
            set_last_error("null output pointer".to_string());
            return Err(ND_ERR_NULL);
        }
        // SAFETY: caller-owned output slots (ABI contract).
        unsafe {
            *out_sample_rate = header.sample_rate;
            *out_channels = header.channels;
            *out_bits_per_sample = header.bits_per_sample;
            *out_data_offset = header.data_offset;
            *out_data_size = header.data_size;
            *out_sample_count = header.sample_count();
        }
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_wav_header_full".to_string()),
    }
}

/// Decodes WAV samples into the caller-provided buffer. Query the required
/// capacity with [`nd_wav_decode_info`]; `ND_ERR_SMALL_BUFFER` is returned
/// when `capacity` is too small.
#[no_mangle]
pub extern "C" fn nd_wav_decode_samples(
    data: *const u8,
    len: usize,
    out_samples: *mut i16,
    capacity: usize,
    out_written: *mut usize,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let data = slice_from(data, len)?;
        let info = wav::decode_pcm16(data).ok_or_else(|| {
            set_last_error("not a decodable PCM16 WAV".to_string());
            ND_ERR_DECODE
        })?;
        if out_samples.is_null() || out_written.is_null() {
            set_last_error("null output pointer".to_string());
            return Err(ND_ERR_NULL);
        }
        if capacity < info.samples.len() {
            set_last_error(format!(
                "buffer too small: need {}, have {capacity}",
                info.samples.len()
            ));
            return Err(ND_ERR_SMALL_BUFFER);
        }
        // SAFETY: caller guarantees room for `capacity` samples.
        unsafe {
            std::ptr::copy_nonoverlapping(info.samples.as_ptr(), out_samples, info.samples.len());
            *out_written = info.samples.len();
        }
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_wav_decode_samples".to_string()),
    }
}

// ---------------------------------------------------------------------------
// Word diff and text stitching.
// ---------------------------------------------------------------------------

/// Word-level diff as JSON: `{"change":false}` when texts match word-wise,
/// else `{"change":true,"span_old":...,"span_new":...,"span_start_old":N,
/// "span_start_new":N}`. NULL is returned only on error.
#[no_mangle]
pub extern "C" fn nd_word_diff(
    old_ptr: *const c_char,
    old_len: usize,
    new_ptr: *const c_char,
    new_len: usize,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let old = str_from(old_ptr, old_len)?;
        let new = str_from(new_ptr, new_len)?;
        let json = match word_diff::change(old, new) {
            None => r#"{"change":false}"#.to_string(),
            Some(c) => format!(
                "{{\"change\":true,\"span_old\":{},\"span_new\":{},\"span_start_old\":{},\"span_start_new\":{}}}",
                json_string(&c.span_old),
                json_string(&c.span_new),
                c.span_start_old,
                c.span_start_new
            ),
        };
        Ok::<*mut c_char, i32>(alloc_string(&json))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_word_diff".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Text tail after the first `word_count` words (post-processing overlap
/// helper, mirrors `WordDiff.tailAfterWords`). Leading whitespace stays on
/// the tail; the native insertion layer trims it. NULL only on invalid
/// UTF-8, null pointers, or panic.
#[no_mangle]
pub extern "C" fn nd_word_tail_after_words(
    text_ptr: *const c_char,
    text_len: usize,
    word_count: usize,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let text = str_from(text_ptr, text_len)?;
        Ok::<*mut c_char, i32>(alloc_string(&word_diff::tail_after_words(word_count, text)))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_word_tail_after_words".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Joins `count` chunk texts (`texts`/`lens` arrays) with boundary-overlap
/// dedup. NULL is returned only on error.
#[no_mangle]
pub extern "C" fn nd_text_join(
    texts: *const *const c_char,
    lens: *const usize,
    count: usize,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let texts = slice_from(texts, count)?;
        let lens = slice_from(lens, count)?;
        let mut owned: Vec<String> = Vec::with_capacity(count);
        for i in 0..count {
            let text = str_from(texts[i], lens[i])?;
            owned.push(text.to_string());
        }
        let refs: Vec<&str> = owned.iter().map(String::as_str).collect();
        Ok::<*mut c_char, i32>(alloc_string(&crate::text_joiner::join(&refs)))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_text_join".to_string());
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// STT policy and transcripts.
// ---------------------------------------------------------------------------

fn transport_name(transport: EngineTransport) -> &'static str {
    match transport {
        EngineTransport::BatchMultipart => "batch_multipart",
        EngineTransport::BatchRawAudio => "batch_raw_audio",
        EngineTransport::StreamingSession => "streaming_session",
    }
}

fn language_hint_name(hint: stt::LanguageHintMode) -> &'static str {
    match hint {
        stt::LanguageHintMode::None => "none",
        stt::LanguageHintMode::Single => "single",
        stt::LanguageHintMode::Multi => "multi",
    }
}

/// Resolves the model profile for an (adapter id, model) pair as JSON.
/// Never fails on unknown ids (conservative fallback); NULL only on
/// invalid UTF-8, null pointers, or panic.
#[no_mangle]
pub extern "C" fn nd_stt_resolve(
    adapter_ptr: *const c_char,
    adapter_len: usize,
    model_ptr: *const c_char,
    model_len: usize,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let adapter = str_from(adapter_ptr, adapter_len)?;
        let model = str_from(model_ptr, model_len)?;
        let profile = stt::resolve(adapter, model);
        let caps = &profile.capabilities;
        let flag = |b: bool| if b { "true" } else { "false" };
        let formats: Vec<&str> = caps
            .response_formats
            .iter()
            .map(|f| match f {
                stt::ResponseFormat::Json => "json",
                stt::ResponseFormat::VerboseJson => "verbose_json",
            })
            .collect();
        let formats_json = formats
            .iter()
            .map(|f| format!("\"{f}\""))
            .collect::<Vec<_>>()
            .join(",");
        let path_json = match &profile.transcript_path {
            Some(path) => {
                let parts: Vec<String> = path.iter().map(|s| json_string(s)).collect();
                format!("[{}]", parts.join(","))
            }
            None => "null".to_string(),
        };
        let json = format!(
            "{{\"adapter_id\":{},\"model\":{},\"transport\":\"{}\",\
            \"audio\":{{\"sample_rate\":{},\"channels\":{},\"upload_format\":\"wav\",\
            \"supports_flac\":{}}},\
            \"response_formats\":[{formats_json}],\
            \"capabilities\":{{\"supports_verbose_json\":{},\"supports_word_timestamps\":{},\
            \"supports_segment_timestamps\":{},\"supports_prompt\":{},\"supports_temperature\":{},\
            \"supports_vad_filter\":{},\"supports_no_speech_threshold\":{},\
            \"supports_compression_ratio_threshold\":{},\"supports_logprob_threshold\":{},\
            \"supports_keyword_biasing\":{},\"supports_server_vad\":{},\
            \"supports_server_chunking\":{},\"supports_noise_reduction\":{},\
            \"language_hint\":\"{}\"}},\
            \"transcript_path\":{path_json}}}",
            json_string(&profile.adapter_id),
            json_string(&profile.model),
            transport_name(caps.transport),
            profile.audio.sample_rate,
            profile.audio.channels,
            flag(profile.audio.supports_flac),
            flag(caps.supports_verbose_json),
            flag(caps.supports_word_timestamps),
            flag(caps.supports_segment_timestamps),
            flag(caps.supports_prompt),
            flag(caps.supports_temperature),
            flag(caps.supports_vad_filter),
            flag(caps.supports_no_speech_threshold),
            flag(caps.supports_compression_ratio_threshold),
            flag(caps.supports_logprob_threshold),
            flag(caps.supports_keyword_biasing),
            flag(caps.supports_server_vad),
            flag(caps.supports_server_chunking),
            flag(caps.supports_noise_reduction),
            language_hint_name(caps.language_hint),
        );
        Ok::<*mut c_char, i32>(alloc_string(&json))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_stt_resolve".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Default endpoint for an adapter id (empty for manual endpoints that
/// require an explicit base URL). Mirrors the portable configuration
/// default so macOS and Windows resolve the same value. NULL only on
/// invalid UTF-8, null pointers, or panic.
#[no_mangle]
pub extern "C" fn nd_stt_default_base_url(
    adapter_ptr: *const c_char,
    adapter_len: usize,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let adapter = str_from(adapter_ptr, adapter_len)?;
        let url = stt::AdapterId::from_id(adapter).default_base_url();
        Ok::<*mut c_char, i32>(alloc_string(url))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_stt_default_base_url".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Default model for an adapter id (empty when the adapter has none and
/// the model must come from configuration). Mirrors the portable
/// configuration default. NULL only on invalid UTF-8, null pointers, or
/// panic.
#[no_mangle]
pub extern "C" fn nd_stt_default_model(
    adapter_ptr: *const c_char,
    adapter_len: usize,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let adapter = str_from(adapter_ptr, adapter_len)?;
        let model = stt::AdapterId::from_id(adapter).default_model();
        Ok::<*mut c_char, i32>(alloc_string(model))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_stt_default_model".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Parses an STT response body into `{"text":...,"words":[...]}` JSON.
/// `path` selects the transcript field (`NULL`/empty means flat `text`;
/// otherwise a dot-separated path such as `result.text`). NULL only on
/// parse errors, invalid UTF-8, or panic. Empty text is an empty result,
/// not an error.
#[no_mangle]
pub extern "C" fn nd_transcript_parse(
    body_ptr: *const c_char,
    body_len: usize,
    path_ptr: *const c_char,
    path_len: usize,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let body = str_from(body_ptr, body_len)?;
        let path_raw = if path_ptr.is_null() {
            ""
        } else {
            str_from(path_ptr, path_len)?
        };
        let segments: Vec<String> = if path_raw.is_empty() {
            Vec::new()
        } else {
            path_raw.split('.').map(|s| s.to_string()).collect()
        };
        let path = if segments.is_empty() {
            None
        } else {
            Some(segments)
        };
        let root = transcript::parse_json(body).map_err(|e| {
            set_last_error(format!("transcript parse failed: {e}"));
            ND_ERR_DECODE
        })?;
        let text = transcript::extract_text(&root, path.as_deref()).map_err(|e| {
            set_last_error(format!("transcript extract failed: {e}"));
            ND_ERR_DECODE
        })?;
        let words = transcript::extract_words_with_path(&root, path.as_deref());
        let mut json = String::from("{\"text\":");
        json.push_str(&json_string(&text));
        json.push_str(",\"words\":[");
        for (i, w) in words.iter().enumerate() {
            if i > 0 {
                json.push(',');
            }
            json.push_str(&format!(
                "{{\"word\":{},\"start\":{},\"end\":{}}}",
                json_string(&w.word),
                w.start,
                w.end
            ));
        }
        json.push_str("]}");
        Ok::<*mut c_char, i32>(alloc_string(&json))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_transcript_parse".to_string());
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Retry / failover.
// ---------------------------------------------------------------------------

/// Orders failover candidates as comma-separated ids. `failed` selects the
/// last-failed provider (empty means none). `auto_failover` nonzero moves
/// it to the end. NULL only on error.
#[no_mangle]
pub extern "C" fn nd_failover_order(
    ids_ptr: *const c_char,
    ids_len: usize,
    failed_ptr: *const c_char,
    failed_len: usize,
    auto_failover: bool,
) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| {
        let ids_raw = str_from(ids_ptr, ids_len)?;
        let failed_raw = if failed_ptr.is_null() {
            ""
        } else {
            str_from(failed_ptr, failed_len)?
        };
        let order: Vec<String> = if ids_raw.is_empty() {
            Vec::new()
        } else {
            ids_raw.split(',').map(|s| s.to_string()).collect()
        };
        let failed = if failed_raw.is_empty() {
            None
        } else {
            Some(failed_raw)
        };
        let ordered = failover_order(&order, failed, auto_failover);
        Ok::<*mut c_char, i32>(alloc_string(&ordered.join(",")))
    })) {
        Ok(Ok(ptr)) => ptr,
        Ok(Err(_)) => std::ptr::null_mut(),
        Err(_) => {
            set_last_error("panic in nd_failover_order".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Number of candidates the caller may attempt. Never fails.
#[no_mangle]
pub extern "C" fn nd_failover_candidate_count(order_len: usize, auto_failover: bool) -> usize {
    candidate_count(order_len, auto_failover)
}

/// Whether a failed attempt of `kind` (0 = transcribe error, else other)
/// may fall over to the next provider. Never fails.
#[no_mangle]
pub extern "C" fn nd_should_failover(kind: u32) -> bool {
    let kind = if kind == 0 {
        TranscribeKind::Transcribe
    } else {
        TranscribeKind::Other
    };
    crate::retry::should_failover(kind)
}

/// Exponential backoff delay in milliseconds. Never fails.
#[no_mangle]
pub extern "C" fn nd_backoff_delay_ms(attempt: u32, base_ms: u64, cap_ms: u64) -> u64 {
    backoff_delay_ms(attempt, base_ms, cap_ms)
}

// ---------------------------------------------------------------------------
// Review, retry gate, overlay, mic policy.
// ---------------------------------------------------------------------------

/// Review-before-insert decision: 1 = insert, 0 = cancel. `has_line`
/// false means end of input (cancel). Negative values are errors.
#[no_mangle]
pub extern "C" fn nd_review_decide(
    line_ptr: *const c_char,
    line_len: usize,
    has_line: bool,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let line = if has_line {
            Some(str_from(line_ptr, line_len)?)
        } else {
            None
        };
        Ok(match review_decide(line) {
            ReviewDecision::Insert => 1,
            ReviewDecision::Cancel => 0,
        })
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_review_decide".to_string()),
    }
}

/// Retry-insertion drop guard: 1 = drop, 0 = keep. Negative values are errors.
#[no_mangle]
pub extern "C" fn nd_should_drop_retry(state: u32, processing_session: u64, session: u64) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let state = decode_state(state)?;
        Ok(i32::from(should_drop_retry(
            state,
            processing_session,
            session,
        )))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_should_drop_retry".to_string()),
    }
}

/// Overlay hide rule: 1 = may hide, 0 = must stay. Negative values are errors.
#[no_mangle]
pub extern "C" fn nd_overlay_should_hide(state: u32) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let state = decode_state(state)?;
        Ok(i32::from(overlay_should_hide(state)))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_overlay_should_hide".to_string()),
    }
}

/// Mic-request storm guard: 1 = a new request is allowed, 0 = blocked.
/// Negative values are errors.
#[no_mangle]
pub extern "C" fn nd_mic_request_allowed(
    stamps: *const c_double,
    count: usize,
    now: c_double,
    max_timeouts: usize,
    window_secs: c_double,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let stamps = slice_from(stamps, count)?;
        Ok(i32::from(mic_request_allowed(
            stamps,
            now,
            max_timeouts,
            window_secs,
        )))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_mic_request_allowed".to_string()),
    }
}

// ---------------------------------------------------------------------------
// Stateful handles: VAD, gain, auto-stop, session, cooldown, latch.
// ---------------------------------------------------------------------------

/// Creates an adaptive VAD handle with default configuration. NULL only on
/// panic (allocation failure aborts the process).
#[no_mangle]
pub extern "C" fn nd_vad_new() -> *mut NdVad {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(NdVad {
            inner: vad::AdaptiveVad::default(),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_vad_new".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Releases a VAD handle. NULL is accepted and ignored.
#[no_mangle]
pub extern "C" fn nd_vad_free(handle: *mut NdVad) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: handle came from `nd_vad_new` and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }));
}

/// Feeds one buffer RMS with its duration. Returns 1 for speech, 0 for
/// silence, negative on error.
#[no_mangle]
pub extern "C" fn nd_vad_feed(handle: *mut NdVad, rms: c_float, duration: c_double) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let vad = with_handle(handle, "vad")?;
        Ok(i32::from(vad.inner.update(rms, duration)))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_vad_feed".to_string()),
    }
}

/// Realtime ingress: feeds one block of Float32 samples at `sample_rate`.
/// Computes the block RMS inline (no allocation) and updates the detector.
/// Returns 1 for speech, 0 for silence, negative on error. Never performs
/// I/O, locking, or network work.
#[no_mangle]
pub extern "C" fn nd_vad_feed_samples(
    handle: *mut NdVad,
    samples: *const c_float,
    count: usize,
    sample_rate: u32,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let vad = with_handle(handle, "vad")?;
        let samples = slice_from(samples, count)?;
        if sample_rate == 0 {
            set_last_error("sample rate must be nonzero".to_string());
            return Err(ND_ERR_ARG);
        }
        let mut sum = 0.0f32;
        for &v in samples {
            sum += v * v;
        }
        let rms = if samples.is_empty() {
            0.0
        } else {
            (sum / samples.len() as f32).sqrt()
        };
        let duration = samples.len() as f64 / f64::from(sample_rate);
        Ok(i32::from(vad.inner.update(rms, duration)))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_vad_feed_samples".to_string()),
    }
}

/// Resets a VAD handle to the initial state. Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_vad_reset(handle: *mut NdVad) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let vad = with_handle(handle, "vad")?;
        vad.inner.reset();
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_vad_reset".to_string()),
    }
}

/// Creates an adaptive VAD handle with an explicit configuration. The
/// margins and clamps mirror the host-side `AdaptiveVADConfig` default
/// semantics: the hysteresis width is at least 1 dB and the enter clamp
/// keeps `max >= min`. NULL only on panic.
#[no_mangle]
pub extern "C" fn nd_vad_new_with_config(
    enter_margin_db: c_float,
    hysteresis_db: c_float,
    min_enter_db: c_float,
    max_enter_db: c_float,
) -> *mut NdVad {
    match catch_unwind(AssertUnwindSafe(|| {
        let config =
            AdaptiveVadConfig::new(enter_margin_db, hysteresis_db, min_enter_db, max_enter_db);
        Box::into_raw(Box::new(NdVad {
            inner: vad::AdaptiveVad::new(config, vad::NoiseFloorTracker::default()),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_vad_new_with_config".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Reads live VAD diagnostics without disturbing detector state: the
/// current noise floor, the enter/exit thresholds (linear RMS), and the
/// speech flag (1 = speech, 0 = silence). Observability for the host
/// level meter and debug logs; never part of the speech decision.
/// Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_vad_diagnostics(
    handle: *mut NdVad,
    out_floor: *mut c_float,
    out_enter: *mut c_float,
    out_exit: *mut c_float,
    out_is_speech: *mut i32,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let vad = with_handle(handle, "vad")?;
        if out_floor.is_null()
            || out_enter.is_null()
            || out_exit.is_null()
            || out_is_speech.is_null()
        {
            set_last_error("null output pointer".to_string());
            return Err(ND_ERR_NULL);
        }
        // SAFETY: caller-owned output slots (ABI contract).
        unsafe {
            *out_floor = vad.inner.noise_floor();
            *out_enter = vad.inner.enter_threshold();
            *out_exit = vad.inner.exit_threshold();
            *out_is_speech = i32::from(vad.inner.is_speech);
        }
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_vad_diagnostics".to_string()),
    }
}

/// Creates an input-gain handle with default configuration.
#[no_mangle]
pub extern "C" fn nd_gain_new() -> *mut NdGain {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(NdGain {
            inner: InputGain::default(),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_gain_new".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Creates an input-gain handle with an explicit configuration. The
/// target and ceiling are clamped to the same invariants as the default
/// constructor (`target` in -120..-1 dBFS, `max_gain` in 1..60 dB, time
/// constants at least 1 ms), so host environment overrides can never
/// break the gain invariants. NULL only on panic.
#[no_mangle]
pub extern "C" fn nd_gain_new_with_config(
    enabled: bool,
    target_rms_db: c_float,
    max_gain_db: c_float,
    attack_time: c_double,
    release_time: c_double,
) -> *mut NdGain {
    match catch_unwind(AssertUnwindSafe(|| {
        let config = InputGainConfig::new(
            enabled,
            target_rms_db,
            max_gain_db,
            attack_time,
            release_time,
        );
        Box::into_raw(Box::new(NdGain {
            inner: InputGain::new(config),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_gain_new_with_config".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Resets an input-gain handle (zero gain, fresh noise floor) for a new
/// recording session. Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_gain_reset(handle: *mut NdGain) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let gain = with_handle(handle, "gain")?;
        gain.inner.reset();
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_gain_reset".to_string()),
    }
}

/// Current smoothed gain in dB (0 = none) for host diagnostics and tests.
/// Returns a negative sentinel and records an error on a null handle;
/// the gain itself is never negative, so the sentinel is unambiguous.
#[no_mangle]
pub extern "C" fn nd_gain_current_db(handle: *mut NdGain) -> c_float {
    match catch_unwind(AssertUnwindSafe(|| {
        let gain = with_handle(handle, "gain")?;
        Ok::<c_float, i32>(gain.inner.current_gain_db)
    })) {
        Ok(Ok(value)) => value,
        Ok(Err(_)) => -1.0,
        Err(_) => {
            set_last_error("panic in nd_gain_current_db".to_string());
            -1.0
        }
    }
}

/// Releases an input-gain handle. NULL is accepted and ignored.
#[no_mangle]
pub extern "C" fn nd_gain_free(handle: *mut NdGain) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: handle came from `nd_gain_new` and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }));
}

/// Applies gain in place; returns the amplified RMS, or a negative value
/// on error. `rms` is the pre-gain RMS of the block.
#[no_mangle]
pub extern "C" fn nd_gain_apply(
    handle: *mut NdGain,
    samples: *mut c_float,
    count: usize,
    rms: c_float,
    sample_rate: u32,
) -> c_float {
    match catch_unwind(AssertUnwindSafe(|| {
        let gain = with_handle(handle, "gain")?;
        let samples = slice_mut_from(samples, count)?;
        if sample_rate == 0 {
            set_last_error("sample rate must be nonzero".to_string());
            return Err(ND_ERR_ARG);
        }
        Ok(gain.inner.apply(samples, rms, sample_rate))
    })) {
        Ok(Ok(value)) => value,
        Ok(Err(_)) => -1.0,
        Err(_) => {
            set_last_error("panic in nd_gain_apply".to_string());
            -1.0
        }
    }
}

/// Creates an auto-stop handle with default configuration.
#[no_mangle]
pub extern "C" fn nd_autostop_new() -> *mut NdAutoStop {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(NdAutoStop {
            inner: SilenceAutoStopDetector::default(),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_autostop_new".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Creates an auto-stop handle with an explicit configuration. The
/// hysteresis invariant holds as in the default constructor (the speech
/// threshold never goes below the silence threshold), so host overrides
/// can never break the detector. The feature kill switch stays host-side
/// (the host skips the feed when disabled); the engine only accumulates.
/// NULL only on panic.
#[no_mangle]
pub extern "C" fn nd_autostop_new_with_config(
    speech_rms: c_float,
    silence_rms: c_float,
    required_silence: c_double,
    grace: c_double,
    min_speech_run: c_double,
    min_recording: c_double,
) -> *mut NdAutoStop {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(NdAutoStop {
            inner: SilenceAutoStopDetector::new(
                silence_rms,
                speech_rms,
                required_silence,
                grace,
                min_speech_run,
                min_recording,
            ),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_autostop_new_with_config".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Resets an auto-stop handle (clears the silence accumulator, the
/// recording clock, and the speech gate) for a new recording session.
/// Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_autostop_reset(handle: *mut NdAutoStop) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let detector = with_handle(handle, "autostop")?;
        detector.inner.reset();
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_autostop_reset".to_string()),
    }
}

/// Releases an auto-stop handle. NULL is accepted and ignored.
#[no_mangle]
pub extern "C" fn nd_autostop_free(handle: *mut NdAutoStop) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: handle came from `nd_autostop_new` and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }));
}

/// Feeds one buffer. `is_speech`: 1 = speech, 0 = silence, negative =
/// no VAD hint (RMS thresholds apply). Returns 1 when all stop
/// conditions hold, 0 otherwise, negative on error.
#[no_mangle]
pub extern "C" fn nd_autostop_feed(
    handle: *mut NdAutoStop,
    rms: c_float,
    duration: c_double,
    is_speech: i32,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let detector = with_handle(handle, "autostop")?;
        let hint = if is_speech < 0 {
            None
        } else {
            Some(is_speech != 0)
        };
        Ok(i32::from(detector.inner.feed(rms, duration, hint)))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_autostop_feed".to_string()),
    }
}

// ---------------------------------------------------------------------------
// Live segmentation and batch chunk planning.
// ---------------------------------------------------------------------------

/// Portable live-segmentation configuration. Mirrors the host-side
/// segmenter policy: pause length that closes an utterance, minimum and
/// maximum segment lengths, glued overlap, and the adaptive speech
/// classifier (fixed legacy threshold when `use_adaptive_vad` is false).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NdSegmenterConfig {
    pub pause_duration: c_double,
    pub min_segment: c_double,
    pub max_segment: c_double,
    pub overlap: c_double,
    pub silence_rms: c_float,
    pub use_adaptive_vad: bool,
    pub enter_margin_db: c_float,
    pub hysteresis_db: c_float,
    pub min_enter_db: c_float,
    pub max_enter_db: c_float,
}

/// One live segment plan entry. Sample ranges address the source buffer
/// at `sample_rate` (0-based, end-exclusive); the overlap window is the
/// tail of the previous body (`has_overlap` false for the first
/// segment). The host owns the samples and materializes PCM on demand
/// through these ranges; the engine only decides boundaries.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NdLiveSegment {
    pub index: usize,
    pub start_seconds: c_double,
    pub end_seconds: c_double,
    pub body_start: usize,
    pub body_end: usize,
    pub has_overlap: bool,
    pub overlap_start: usize,
    pub overlap_end: usize,
    pub overlap_seconds: c_double,
}

/// One fixed-length batch chunk plan entry. Bodies cover the source back
/// to back with no gaps and no overlaps; every chunk but the first
/// starts with the tail of the previous body as context overlap.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NdBatchChunk {
    pub index: usize,
    pub body_start_seconds: c_double,
    pub body_end_seconds: c_double,
    pub body_start: usize,
    pub body_end: usize,
    pub has_overlap: bool,
    pub overlap_start: usize,
    pub overlap_end: usize,
}

fn segmenter_config_from(raw: &NdSegmenterConfig) -> SegmenterConfig {
    SegmenterConfig::new(
        raw.pause_duration,
        raw.min_segment,
        raw.max_segment,
        raw.overlap,
        raw.silence_rms,
        raw.use_adaptive_vad,
        AdaptiveVadConfig::new(
            raw.enter_margin_db,
            raw.hysteresis_db,
            raw.min_enter_db,
            raw.max_enter_db,
        ),
    )
}

/// Splits Int16 PCM samples into live segments with overlap (the offline
/// counterpart of the streaming utterance logic: pause-gated boundaries,
/// minimum segment glue, maximum segment hard cap, junction silence owned
/// by no segment). Single pass over the source; the engine allocates
/// only internal scratch (RMS timeline, plan) and never retains PCM.
/// Offline call, not for the realtime callback. `config` NULL
/// means defaults. When `out_specs` is NULL (or `capacity` is 0) the
/// required entry count is written to `out_written` and `ND_OK` is
/// returned; otherwise up to `capacity` entries are written and
/// `ND_ERR_SMALL_BUFFER` is returned with the required count when the
/// buffer is too small. Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_live_plan(
    samples: *const i16,
    count: usize,
    sample_rate: u32,
    config: *const NdSegmenterConfig,
    out_specs: *mut NdLiveSegment,
    capacity: usize,
    out_written: *mut usize,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let samples = slice_from(samples, count)?;
        if out_written.is_null() {
            set_last_error("null output pointer".to_string());
            return Err(ND_ERR_NULL);
        }
        if sample_rate == 0 {
            set_last_error("sample rate must be nonzero".to_string());
            return Err(ND_ERR_ARG);
        }
        // SAFETY: the caller guarantees a valid config or NULL (ABI contract).
        let engine_config = if config.is_null() {
            SegmenterConfig::default()
        } else {
            segmenter_config_from(unsafe { &*config })
        };
        let rate = f64::from(sample_rate);
        let plan = crate::segmenter::live_segments(samples, sample_rate, &engine_config);
        // SAFETY: caller-owned count slot (ABI contract).
        unsafe {
            *out_written = plan.len();
        }
        if out_specs.is_null() || capacity == 0 {
            return Ok(ND_OK);
        }
        if capacity < plan.len() {
            set_last_error(format!(
                "buffer too small: need {}, have {capacity}",
                plan.len()
            ));
            return Err(ND_ERR_SMALL_BUFFER);
        }
        // SAFETY: the caller guarantees room for `capacity` entries.
        let out = unsafe { std::slice::from_raw_parts_mut(out_specs, plan.len().min(capacity)) };
        for (index, spec) in plan.iter().enumerate() {
            let (has_overlap, overlap_start, overlap_end, overlap_seconds) =
                match spec.overlap_range.clone() {
                    Some(range) => (
                        true,
                        range.start,
                        range.end,
                        (range.end - range.start) as f64 / rate,
                    ),
                    None => (false, 0, 0, 0.0),
                };
            out[index] = NdLiveSegment {
                index,
                start_seconds: spec.start_seconds,
                end_seconds: spec.end_seconds,
                body_start: spec.body_range.start,
                body_end: spec.body_range.end,
                has_overlap,
                overlap_start,
                overlap_end,
                overlap_seconds,
            };
        }
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_live_plan".to_string()),
    }
}

/// Fixed-length batch chunk planning math over sample counts (no audio
/// content crosses the boundary): chunk bodies cover the source back to
/// back with overlap tails, exactly like the host-side fixed-length
/// planner. Buffering contract mirrors [`nd_live_plan`]: NULL output
/// queries the required count, a short buffer yields
/// `ND_ERR_SMALL_BUFFER` with the required count. Returns `ND_OK` or a
/// positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_batch_plan(
    sample_count: usize,
    sample_rate: u32,
    max_segment: c_double,
    overlap: c_double,
    out_specs: *mut NdBatchChunk,
    capacity: usize,
    out_written: *mut usize,
) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        if out_written.is_null() {
            set_last_error("null output pointer".to_string());
            return Err(ND_ERR_NULL);
        }
        if sample_rate == 0 {
            set_last_error("sample rate must be nonzero".to_string());
            return Err(ND_ERR_ARG);
        }
        let plan = crate::segmenter::batch_plan(sample_count, sample_rate, max_segment, overlap);
        // SAFETY: caller-owned count slot (ABI contract).
        unsafe {
            *out_written = plan.len();
        }
        if out_specs.is_null() || capacity == 0 {
            return Ok(ND_OK);
        }
        if capacity < plan.len() {
            set_last_error(format!(
                "buffer too small: need {}, have {capacity}",
                plan.len()
            ));
            return Err(ND_ERR_SMALL_BUFFER);
        }
        // SAFETY: the caller guarantees room for `capacity` entries.
        let out = unsafe { std::slice::from_raw_parts_mut(out_specs, plan.len().min(capacity)) };
        for (spec, slot) in plan.iter().zip(out.iter_mut()) {
            let (has_overlap, overlap_start, overlap_end) = match spec.overlap_range.clone() {
                Some(range) => (true, range.start, range.end),
                None => (false, 0, 0),
            };
            *slot = NdBatchChunk {
                index: spec.index,
                body_start_seconds: spec.body_start_seconds,
                body_end_seconds: spec.body_end_seconds,
                body_start: spec.body_range.start,
                body_end: spec.body_range.end,
                has_overlap,
                overlap_start,
                overlap_end,
            };
        }
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_batch_plan".to_string()),
    }
}

// ---------------------------------------------------------------------------
// Dictation session.
// ---------------------------------------------------------------------------

/// Creates a dictation session handle in the idle state.
#[no_mangle]
pub extern "C" fn nd_session_new() -> *mut NdSession {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(NdSession {
            inner: DictationSession::new(),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_session_new".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Releases a session handle. NULL is accepted and ignored.
#[no_mangle]
pub extern "C" fn nd_session_free(handle: *mut NdSession) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: handle came from `nd_session_new` and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }));
}

/// Starts a new session (bumps the generation, clears readiness) and
/// returns the new generation. Returns 0 on error (generations start at 1).
#[no_mangle]
pub extern "C" fn nd_session_start(handle: *mut NdSession) -> u64 {
    match catch_unwind(AssertUnwindSafe(|| {
        let session = with_handle(handle, "session")?;
        Ok::<u64, i32>(session.inner.start())
    })) {
        Ok(Ok(gen)) => gen,
        Ok(Err(_)) => 0,
        Err(_) => {
            set_last_error("panic in nd_session_start".to_string());
            0
        }
    }
}

/// Drives the session with an event for a generation. Stale generations
/// are rejected silently. Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_session_event(handle: *mut NdSession, event: u32, generation: u64) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let session = with_handle(handle, "session")?;
        let event = decode_event(event)?;
        session.inner.on_event(event, generation);
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_session_event".to_string()),
    }
}

/// Live capture-readiness flag. Returns 1 when ready, 0 otherwise,
/// negative on error.
#[no_mangle]
pub extern "C" fn nd_session_is_capture_ready(handle: *mut NdSession) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let session = with_handle(handle, "session")?;
        Ok(i32::from(session.inner.is_capture_ready()))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(
            ND_ERR_PANIC,
            "panic in nd_session_is_capture_ready".to_string(),
        ),
    }
}

/// Whether the recording-ready cue may be emitted now (at most once per
/// session, only after readiness). Returns 1 to emit, 0 to suppress,
/// negative on error.
#[no_mangle]
pub extern "C" fn nd_session_should_emit_ready_cue(handle: *mut NdSession) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let session = with_handle(handle, "session")?;
        Ok(i32::from(session.inner.should_emit_ready_cue()))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(
            ND_ERR_PANIC,
            "panic in nd_session_should_emit_ready_cue".to_string(),
        ),
    }
}

/// Current session state code. Returns `ND_STATE_*` or `u32::MAX` on error.
#[no_mangle]
pub extern "C" fn nd_session_state(handle: *mut NdSession) -> u32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let session = with_handle(handle, "session")?;
        Ok::<u32, i32>(match session.inner.state() {
            DictationState::Idle => ND_STATE_IDLE,
            DictationState::Recording => ND_STATE_RECORDING,
            DictationState::Transcribing => ND_STATE_TRANSCRIBING,
        })
    })) {
        Ok(Ok(code)) => code,
        Ok(Err(_)) => u32::MAX,
        Err(_) => {
            set_last_error("panic in nd_session_state".to_string());
            u32::MAX
        }
    }
}

/// Creates a mic-error cooldown handle with the given interval in seconds.
#[no_mangle]
pub extern "C" fn nd_cooldown_new(interval_secs: c_double) -> *mut NdCooldown {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(NdCooldown {
            inner: MicErrorCooldown::new(interval_secs),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_cooldown_new".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Releases a cooldown handle. NULL is accepted and ignored.
#[no_mangle]
pub extern "C" fn nd_cooldown_free(handle: *mut NdCooldown) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: handle came from `nd_cooldown_new` and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }));
}

/// Cooldown check: 1 = show allowed (records `now`), 0 = suppressed,
/// negative on error.
#[no_mangle]
pub extern "C" fn nd_cooldown_allow(handle: *mut NdCooldown, now_secs: c_double) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let cooldown = with_handle(handle, "cooldown")?;
        Ok(i32::from(cooldown.inner.allow(now_secs)))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_cooldown_allow".to_string()),
    }
}

/// Creates an enter-send latch handle.
#[no_mangle]
pub extern "C" fn nd_latch_new() -> *mut NdLatch {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(NdLatch {
            inner: EnterSendLatch::new(),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => {
            set_last_error("panic in nd_latch_new".to_string());
            std::ptr::null_mut()
        }
    }
}

/// Releases a latch handle. NULL is accepted and ignored.
#[no_mangle]
pub extern "C" fn nd_latch_free(handle: *mut NdLatch) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: handle came from `nd_latch_new` and is freed once.
        drop(unsafe { Box::from_raw(handle) });
    }));
}

/// Arms the latch. Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_latch_arm(handle: *mut NdLatch) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let latch = with_handle(handle, "latch")?;
        latch.inner.arm();
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_latch_arm".to_string()),
    }
}

/// One-shot take: 1 = post Enter, 0 = already consumed, negative on error.
#[no_mangle]
pub extern "C" fn nd_latch_consume(handle: *mut NdLatch) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let latch = with_handle(handle, "latch")?;
        Ok(i32::from(latch.inner.consume()))
    })) {
        Ok(code) => code.unwrap_or_else(|code: i32| -code),
        Err(_) => -fail(ND_ERR_PANIC, "panic in nd_latch_consume".to_string()),
    }
}

/// Disarms the latch. Returns `ND_OK` or a positive `ND_ERR_*` code.
#[no_mangle]
pub extern "C" fn nd_latch_cancel(handle: *mut NdLatch) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| {
        let latch = with_handle(handle, "latch")?;
        latch.inner.cancel();
        Ok(ND_OK)
    })) {
        Ok(code) => code.unwrap_or_else(|code| code),
        Err(_) => fail(ND_ERR_PANIC, "panic in nd_latch_cancel".to_string()),
    }
}
