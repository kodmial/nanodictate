//! ABI-level integration tests: ownership, error mapping, panic
//! safety, threading, and the realtime audio ingress contract.
//!
//! The exported `extern "C"` functions are safe Rust functions (raw
//! pointer contracts are validated at runtime), so no `unsafe` blocks
//! are needed at the call sites below.

use nanodictate_core::abi::*;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

fn to_c(text: &str) -> CString {
    CString::new(text).unwrap()
}

fn read_string(ptr: *mut c_char) -> String {
    assert!(!ptr.is_null());
    // SAFETY: the ABI guarantees a valid NUL-terminated string that we own.
    let text = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    nd_string_free(ptr);
    text
}

#[test]
fn abi_version_is_one() {
    assert_eq!(nd_abi_version(), 1);
}

#[test]
fn word_diff_json_vectors_match_engine() {
    let old = to_c("One three.");
    let new = to_c("One two three.");
    let json = read_string(nd_word_diff(
        old.as_ptr(),
        old.as_bytes().len(),
        new.as_ptr(),
        new.as_bytes().len(),
    ));
    assert!(json.contains("\"change\":true"), "{json}");
    assert!(json.contains("\"span_new\":\"two\""), "{json}");

    let same = to_c("Same text.");
    let json = read_string(nd_word_diff(
        same.as_ptr(),
        same.as_bytes().len(),
        same.as_ptr(),
        same.as_bytes().len(),
    ));
    assert_eq!(json, "{\"change\":false}");
}

#[test]
fn null_pointer_maps_to_error_not_panic() {
    assert!(nd_word_diff(std::ptr::null(), 4, std::ptr::null(), 0).is_null());
    // SAFETY: the ABI guarantees a valid NUL-terminated diagnostic string.
    let msg = unsafe { CStr::from_ptr(nd_last_error_text()) }
        .to_string_lossy()
        .into_owned();
    assert!(!msg.is_empty(), "diagnostic must be recorded");
    // Invalid UTF-8 is reported, not fatal.
    let bad = [0xffu8, 0xfe];
    let ok = to_c("ok");
    assert!(nd_word_diff(
        bad.as_ptr() as *const c_char,
        bad.len(),
        ok.as_ptr(),
        ok.as_bytes().len(),
    )
    .is_null());
}

#[test]
fn wav_encode_decode_roundtrip_through_abi() {
    let samples: Vec<i16> = (0..1600).map(|i| (i % 251) as i16 * 40).collect();
    let mut out = NdByteBuffer {
        data: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    };
    let code = nd_wav_encode(samples.as_ptr(), samples.len(), 16000, 1, &mut out);
    assert_eq!(code, 0);
    assert_eq!(out.len, 44 + samples.len() * 2);

    let (mut rate, mut channels, mut count) = (0u32, 0u16, 0usize);
    let code = nd_wav_decode_info(out.data, out.len, &mut rate, &mut channels, &mut count);
    assert_eq!(code, 0);
    assert_eq!((rate, channels, count), (16000, 1, samples.len()));

    let mut decoded = vec![0i16; count];
    let mut written = 0usize;
    let code = nd_wav_decode_samples(
        out.data,
        out.len,
        decoded.as_mut_ptr(),
        decoded.len(),
        &mut written,
    );
    assert_eq!(code, 0);
    assert_eq!(written, samples.len());
    assert_eq!(decoded, samples);

    // Small buffer is a clean error, not a truncation.
    let mut tiny = vec![0i16; 4];
    let mut written = 0usize;
    let code = nd_wav_decode_samples(
        out.data,
        out.len,
        tiny.as_mut_ptr(),
        tiny.len(),
        &mut written,
    );
    assert_eq!(code, 4);

    nd_bytes_free(out);
}

#[test]
fn wav_encode_rejects_header_overflow() {
    let samples: Vec<i16> = vec![1, 2, 3];
    let mut out = NdByteBuffer {
        data: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    };
    // byte_rate overflows u32 (u32::MAX * 2 * 2).
    let code = nd_wav_encode(samples.as_ptr(), samples.len(), u32::MAX, 2, &mut out);
    assert_eq!(code, 3);
    assert!(out.data.is_null());
    // block_align overflows u16 (u16::MAX * 2).
    let code = nd_wav_encode(samples.as_ptr(), samples.len(), 16000, u16::MAX, &mut out);
    assert_eq!(code, 3);
    assert!(out.data.is_null());
}

#[test]
fn stt_resolve_json_shape() {
    let adapter = to_c("groq");
    let model = to_c("whisper-large-v3-turbo");
    let json = read_string(nd_stt_resolve(
        adapter.as_ptr(),
        adapter.as_bytes().len(),
        model.as_ptr(),
        model.as_bytes().len(),
    ));
    assert!(json.contains("\"transport\":\"batch_multipart\""), "{json}");
    assert!(json.contains("\"supports_vad_filter\":true"), "{json}");
    assert!(json.contains("\"sample_rate\":16000"), "{json}");
}

#[test]
fn stt_resolve_reports_portable_policy_for_host_transport() {
    // gpt-transcribe: multi-language hint, no temperature, FLAC accepted.
    let adapter = to_c("openai");
    let model = to_c("gpt-transcribe");
    let json = read_string(nd_stt_resolve(
        adapter.as_ptr(),
        adapter.as_bytes().len(),
        model.as_ptr(),
        model.as_bytes().len(),
    ));
    assert!(json.contains("\"language_hint\":\"multi\""), "{json}");
    assert!(json.contains("\"supports_temperature\":false"), "{json}");
    assert!(json.contains("\"supports_flac\":true"), "{json}");
    // Unknown models stay conservative and WAV-only.
    let future = to_c("some-future-model");
    let json = read_string(nd_stt_resolve(
        adapter.as_ptr(),
        adapter.as_bytes().len(),
        future.as_ptr(),
        future.as_bytes().len(),
    ));
    assert!(json.contains("\"language_hint\":\"single\""), "{json}");
    assert!(json.contains("\"supports_flac\":false"), "{json}");
}

#[test]
fn stt_resolve_realtime_uses_streaming_24k_pcm16() {
    // Task #25: gpt-live-transcribe resolves to one stateful session with
    // 24 kHz raw PCM16, not the 16 kHz batch WAV profile.
    let adapter = to_c("openai");
    let model = to_c("gpt-live-transcribe");
    let json = read_string(nd_stt_resolve(
        adapter.as_ptr(),
        adapter.as_bytes().len(),
        model.as_ptr(),
        model.as_bytes().len(),
    ));
    assert!(
        json.contains("\"transport\":\"streaming_session\""),
        "{json}"
    );
    assert!(json.contains("\"sample_rate\":24000"), "{json}");
    assert!(json.contains("\"upload_format\":\"pcm16\""), "{json}");
    assert!(json.contains("\"language_hint\":\"multi\""), "{json}");
}

#[test]
fn stt_portable_defaults_through_abi() {
    let openai = to_c("openai");
    let url = read_string(nd_stt_default_base_url(
        openai.as_ptr(),
        openai.as_bytes().len(),
    ));
    assert_eq!(url, "https://api.openai.com/v1/audio/transcriptions");
    let model = read_string(nd_stt_default_model(
        openai.as_ptr(),
        openai.as_bytes().len(),
    ));
    assert_eq!(model, "gpt-transcribe");

    let groq = to_c("groq");
    let model = read_string(nd_stt_default_model(groq.as_ptr(), groq.as_bytes().len()));
    assert_eq!(model, "whisper-large-v3");

    // Manual endpoints have no defaults.
    let custom = to_c("my-custom-provider");
    let url = read_string(nd_stt_default_base_url(
        custom.as_ptr(),
        custom.as_bytes().len(),
    ));
    assert_eq!(url, "");
    let model = read_string(nd_stt_default_model(
        custom.as_ptr(),
        custom.as_bytes().len(),
    ));
    assert_eq!(model, "");
}

#[test]
fn wav_full_header_and_word_tail_through_abi() {
    let samples: Vec<i16> = vec![1, -2, 300, -4000];
    let mut out = NdByteBuffer {
        data: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    };
    assert_eq!(
        nd_wav_encode(samples.as_ptr(), samples.len(), 16000, 1, &mut out),
        0
    );
    let (mut rate, mut channels, mut bits, mut offset, mut size, mut count) =
        (0u32, 0u16, 0u16, 0usize, 0usize, 0usize);
    let code = nd_wav_header_full(
        out.data,
        out.len,
        &mut rate,
        &mut channels,
        &mut bits,
        &mut offset,
        &mut size,
        &mut count,
    );
    assert_eq!(code, 0);
    assert_eq!((rate, channels, bits), (16000, 1, 16));
    assert_eq!(offset, 44);
    assert_eq!(size, samples.len() * 2);
    assert_eq!(count, samples.len());
    nd_bytes_free(out);

    let text = to_c("hello brave world");
    let tail = read_string(nd_word_tail_after_words(
        text.as_ptr(),
        text.as_bytes().len(),
        1,
    ));
    assert_eq!(tail, " brave world");
}

#[test]
fn transcript_parse_through_abi() {
    let body = to_c(r#"{"text": "hi", "words": [{"word": "hi", "start": 0.0, "end": 0.2}]}"#);
    let json = read_string(nd_transcript_parse(
        body.as_ptr(),
        body.as_bytes().len(),
        std::ptr::null(),
        0,
    ));
    assert!(json.contains("\"text\":\"hi\""), "{json}");
    assert!(json.contains("\"word\":\"hi\""), "{json}");

    let bad = to_c("nope");
    assert!(nd_transcript_parse(bad.as_ptr(), bad.as_bytes().len(), std::ptr::null(), 0).is_null());
}

#[test]
fn failover_order_and_backoff_through_abi() {
    let ids = to_c("a,b,c");
    let failed = to_c("a");
    let json = read_string(nd_failover_order(
        ids.as_ptr(),
        ids.as_bytes().len(),
        failed.as_ptr(),
        failed.as_bytes().len(),
        true,
    ));
    assert_eq!(json, "b,c,a");
    assert_eq!(nd_failover_candidate_count(3, false), 1);
    assert!(nd_should_failover(0));
    assert!(!nd_should_failover(7));
    assert_eq!(nd_backoff_delay_ms(2, 500, 8000), 2000);
}

#[test]
fn vad_handle_lifecycle_and_realtime_ingress() {
    let vad = nd_vad_new();
    assert!(!vad.is_null());
    for _ in 0..30 {
        assert_eq!(nd_vad_feed(vad, 0.0005, 0.085), 0);
    }
    assert_eq!(nd_vad_feed(vad, 0.02, 0.085), 1);

    // Block transfer: a quiet Float32 block over the wire, no per-sample calls.
    let quiet = vec![0.0005f32; 1360];
    assert_eq!(nd_vad_reset(vad), 0);
    assert_eq!(
        nd_vad_feed_samples(vad, quiet.as_ptr(), quiet.len(), 16000),
        0
    );
    // Null buffer with nonzero count is an error, not UB.
    assert!(nd_vad_feed_samples(vad, std::ptr::null(), 8, 16000) < 0);
    assert!(nd_vad_feed(std::ptr::null_mut(), 0.1, 0.1) < 0);
    nd_vad_free(vad);
    nd_vad_free(std::ptr::null_mut());
}

#[test]
fn gain_apply_in_place_through_abi() {
    let gain = nd_gain_new();
    assert!(!gain.is_null());
    let mut buf = vec![0.004f32; 1600];
    // The default floor starts at 0.001, so 0.004 RMS passes the +4 dB gate.
    let out = nd_gain_apply(gain, buf.as_mut_ptr(), buf.len(), 0.004, 16000);
    assert!(out > 0.004, "AGC must lift quiet speech, got {out}");
    assert!(buf.iter().all(|s| s.abs() <= 1.0));
    assert!(nd_gain_apply(gain, std::ptr::null_mut(), 8, 0.1, 16000) < 0.0);
    nd_gain_free(gain);
}

#[test]
fn autostop_and_session_capture_readiness_through_abi() {
    let stop = nd_autostop_new();
    assert!(!stop.is_null());
    for _ in 0..5 {
        assert_eq!(nd_autostop_feed(stop, 0.02, 0.1, -1), 0);
    }
    let mut fired = false;
    for _ in 0..60 {
        fired = nd_autostop_feed(stop, 0.0005, 0.1, -1) == 1;
    }
    assert!(fired);
    nd_autostop_free(stop);

    let session = nd_session_new();
    assert!(!session.is_null());
    let gen = nd_session_start(session);
    assert!(gen >= 1);
    assert_eq!(nd_session_event(session, 0, gen), 0); // engine started
    assert_eq!(nd_session_is_capture_ready(session), 0);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);
    assert_eq!(nd_session_event(session, 1, gen), 0); // first buffer
    assert_eq!(nd_session_is_capture_ready(session), 1);
    assert_eq!(nd_session_should_emit_ready_cue(session), 1);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);
    assert_eq!(nd_session_state(session), 1); // recording
                                              // Stale generation rejected.
    assert_eq!(nd_session_event(session, 1, gen.wrapping_sub(1)), 0);
    nd_session_free(session);
}

#[test]
fn handles_are_usable_across_threads_with_external_lock() {
    let vad = nd_vad_new();
    // Raw pointers are Send; the test moves the pointer into a scoped
    // thread the way a host dispatch queue would.
    let addr = vad as usize;
    std::thread::scope(|scope| {
        scope
            .spawn(move || {
                let handle = addr as *mut NdVad;
                for _ in 0..10 {
                    nd_vad_feed(handle, 0.001, 0.085);
                }
            })
            .join()
            .unwrap();
    });
    nd_vad_free(vad);
}

#[test]
fn text_join_review_gate_cooldown_latch_through_abi() {
    let a = to_c("hello brave world");
    let b = to_c("brave world again");
    let texts = [a.as_ptr(), b.as_ptr()];
    let lens = [a.as_bytes().len(), b.as_bytes().len()];
    let joined = read_string(nd_text_join(texts.as_ptr(), lens.as_ptr(), 2));
    assert_eq!(joined, "hello brave world again");

    let yes = to_c("y");
    assert_eq!(
        nd_review_decide(yes.as_ptr(), yes.as_bytes().len(), true),
        1
    );
    assert_eq!(nd_review_decide(std::ptr::null(), 0, false), 0);
    assert_eq!(nd_should_drop_retry(0, 2, 2), 0);
    assert_eq!(nd_should_drop_retry(1, 1, 1), 1);
    assert!(nd_should_drop_retry(99, 1, 1) < 0);
    assert_eq!(nd_overlay_should_hide(0), 1);
    assert_eq!(nd_overlay_should_hide(2), 0);

    let stamps = [900.0f64, 950.0, 990.0];
    assert_eq!(
        nd_mic_request_allowed(stamps.as_ptr(), stamps.len(), 1000.0, 3, 21600.0),
        0
    );
    assert_eq!(
        nd_mic_request_allowed(stamps.as_ptr(), 2, 1000.0, 3, 21600.0),
        1
    );

    let cooldown = nd_cooldown_new(5.0);
    assert_eq!(nd_cooldown_allow(cooldown, 0.0), 1);
    assert_eq!(nd_cooldown_allow(cooldown, 1.0), 0);
    nd_cooldown_free(cooldown);

    let latch = nd_latch_new();
    assert_eq!(nd_latch_arm(latch), 0);
    assert_eq!(nd_latch_consume(latch), 1);
    assert_eq!(nd_latch_consume(latch), 0);
    assert_eq!(nd_latch_cancel(latch), 0);
    nd_latch_free(latch);
}

#[test]
fn rms_and_metrics_error_conventions() {
    let samples = [1000i16, -1000, 2000];
    assert!(nd_rms_i16(samples.as_ptr(), samples.len()) > 0.0);
    assert_eq!(nd_rms_i16(std::ptr::null(), 0), 0.0);
    assert!(nd_rms_i16(std::ptr::null(), 3) < 0.0);
    assert!((nd_dbfs(1.0) - 0.0).abs() < 1e-5);
}
