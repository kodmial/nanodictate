//! ABI-level integration tests: ownership, error mapping, panic
//! safety, threading, and the realtime audio ingress contract.
//!
//! The exported `extern "C"` functions are safe Rust functions (raw
//! pointer contracts are validated at runtime), so no `unsafe` blocks
//! are needed at the call sites below.

use nanodictate_core::abi::*;
use nanodictate_core::error::{
    ND_ERR_ARG, ND_ERR_DECODE, ND_ERR_NULL, ND_ERR_PANIC, ND_ERR_SMALL_BUFFER, ND_ERR_UTF8, ND_OK,
};
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

#[test]
fn configured_handles_match_default_behavior() {
    // Explicit default-equivalent configs behave like the default handles.
    let vad = nd_vad_new_with_config(8.0, 4.0, -60.0, -25.0);
    assert!(!vad.is_null());
    for _ in 0..30 {
        assert_eq!(nd_vad_feed(vad, 0.0005, 0.085), 0);
    }
    assert_eq!(nd_vad_feed(vad, 0.02, 0.085), 1);
    let (mut floor, mut enter, mut exit, mut speech) = (0.0f32, 0.0f32, 0.0f32, 0i32);
    assert_eq!(
        nd_vad_diagnostics(vad, &mut floor, &mut enter, &mut exit, &mut speech),
        0
    );
    assert!(
        floor > 0.0 && floor < 0.02,
        "floor follows the signal, got {floor}"
    );
    assert!(exit < enter, "hysteresis keeps exit below enter");
    assert_eq!(speech, 1, "speech latches after the attack");
    assert!(
        nd_vad_diagnostics(
            vad,
            std::ptr::null_mut(),
            &mut enter,
            &mut exit,
            &mut speech
        ) > 0
    );
    assert!(
        nd_vad_diagnostics(
            std::ptr::null_mut(),
            &mut floor,
            &mut enter,
            &mut exit,
            &mut speech
        ) != 0
    );
    assert_eq!(nd_vad_reset(vad), 0);
    assert_eq!(
        nd_vad_diagnostics(vad, &mut floor, &mut enter, &mut exit, &mut speech),
        0
    );
    assert_eq!(speech, 0, "reset returns to silence");
    nd_vad_free(vad);

    // Config clamping mirrors the Swift invariants (hysteresis floor 1 dB).
    let clamped = nd_vad_new_with_config(8.0, 0.0, -25.0, -60.0);
    assert!(!clamped.is_null());
    let mut exit_only = 0.0f32;
    assert_eq!(
        nd_vad_diagnostics(clamped, &mut floor, &mut enter, &mut exit_only, &mut speech),
        0
    );
    assert!(
        exit_only < enter,
        "clamped hysteresis still separates exit from enter"
    );
    nd_vad_free(clamped);

    // Gain with an explicit config lifts quiet speech and reports its state.
    let gain = nd_gain_new_with_config(true, -20.0, 30.0, 0.025, 0.3);
    assert!(!gain.is_null());
    let mut buf = vec![0.004f32; 1600];
    let out = nd_gain_apply(gain, buf.as_mut_ptr(), buf.len(), 0.004, 16000);
    assert!(
        out > 0.004,
        "configured AGC must lift quiet speech, got {out}"
    );
    assert!(
        nd_gain_current_db(gain) > 0.0,
        "smoothed gain must be positive"
    );
    assert_eq!(nd_gain_reset(gain), 0);
    assert_eq!(
        nd_gain_current_db(gain),
        0.0,
        "reset zeroes the smoothed gain"
    );
    assert!(nd_gain_reset(std::ptr::null_mut()) != 0);
    assert!(nd_gain_current_db(std::ptr::null_mut()) < 0.0);
    nd_gain_free(gain);

    // Disabled gain passes the buffer through untouched.
    let off = nd_gain_new_with_config(false, -20.0, 30.0, 0.025, 0.3);
    assert!(!off.is_null());
    let mut passthrough = vec![0.1f32; 160];
    let out = nd_gain_apply(
        off,
        passthrough.as_mut_ptr(),
        passthrough.len(),
        0.01,
        16000,
    );
    assert_eq!(out, 0.01);
    assert!(passthrough.iter().all(|&s| s == 0.1));
    nd_gain_free(off);

    // Auto-stop with an explicit config fires after sustained silence.
    let stop = nd_autostop_new_with_config(0.00562, 0.00126, 3.0, 2.0, 0.3, 3.0);
    assert!(!stop.is_null());
    for _ in 0..5 {
        assert_eq!(nd_autostop_feed(stop, 0.02, 0.1, -1), 0);
    }
    let mut fired = false;
    for _ in 0..60 {
        fired = nd_autostop_feed(stop, 0.0005, 0.1, -1) == 1;
    }
    assert!(
        fired,
        "configured auto-stop must fire after sustained silence"
    );
    assert_eq!(nd_autostop_reset(stop), 0);
    assert_eq!(
        nd_autostop_feed(stop, 0.0005, 0.1, -1),
        0,
        "reset clears the gate: silence alone never stops"
    );
    assert!(nd_autostop_reset(std::ptr::null_mut()) != 0);
    nd_autostop_free(stop);

    // Hysteresis invariant: a speech threshold below silence clamps up.
    let inv = nd_autostop_new_with_config(0.0001, 0.01, 0.5, 0.0, 0.0, 0.0);
    assert!(!inv.is_null());
    assert_eq!(
        nd_autostop_feed(inv, 0.005, 0.6, -1),
        0,
        "gray-zone input holds state"
    );
    nd_autostop_free(inv);
}

#[test]
fn live_and_batch_plan_through_abi() {
    // 4 s of speech, 2 s of pause, 4 s of speech at 16 kHz.
    let rate = 16000u32;
    let mut samples = vec![2000i16; 4 * rate as usize];
    samples.extend(vec![0i16; 2 * rate as usize]);
    samples.extend(vec![2000i16; 4 * rate as usize]);
    let config = NdSegmenterConfig {
        pause_duration: 1.0,
        min_segment: 1.0,
        max_segment: 45.0,
        overlap: 1.0,
        silence_rms: 0.00316,
        use_adaptive_vad: false,
        enter_margin_db: 8.0,
        hysteresis_db: 4.0,
        min_enter_db: -60.0,
        max_enter_db: -25.0,
    };
    // NULL output queries the required entry count.
    let mut needed = 0usize;
    assert_eq!(
        nd_live_plan(
            samples.as_ptr(),
            samples.len(),
            rate,
            &config,
            std::ptr::null_mut(),
            0,
            &mut needed
        ),
        0
    );
    assert_eq!(needed, 2, "pause splits the recording in two");
    let mut specs = vec![
        NdLiveSegment {
            index: 0,
            start_seconds: 0.0,
            end_seconds: 0.0,
            body_start: 0,
            body_end: 0,
            has_overlap: false,
            overlap_start: 0,
            overlap_end: 0,
            overlap_seconds: 0.0,
        };
        needed
    ];
    let mut written = 0usize;
    assert_eq!(
        nd_live_plan(
            samples.as_ptr(),
            samples.len(),
            rate,
            &config,
            specs.as_mut_ptr(),
            specs.len(),
            &mut written
        ),
        0
    );
    assert_eq!(written, 2);
    assert!(!specs[0].has_overlap, "first segment carries no overlap");
    assert!(
        specs[1].has_overlap,
        "second segment glues the previous tail"
    );
    assert_eq!(specs[1].overlap_end - specs[1].overlap_start, rate as usize);
    assert!((specs[1].overlap_seconds - 1.0).abs() < 1e-9);
    // Bodies are ordered and non-overlapping; the pause belongs to neither.
    assert!(specs[0].body_end <= specs[1].body_start);
    // A short buffer is a clean error carrying the required count.
    let mut short = vec![specs[0]; 1];
    let mut short_written = 0usize;
    assert_eq!(
        nd_live_plan(
            samples.as_ptr(),
            samples.len(),
            rate,
            &config,
            short.as_mut_ptr(),
            short.len(),
            &mut short_written
        ),
        4 // ND_ERR_SMALL_BUFFER
    );
    assert_eq!(short_written, 2);
    // Zero sample rate and null count slots are argument errors.
    assert_eq!(
        nd_live_plan(
            samples.as_ptr(),
            samples.len(),
            0,
            &config,
            std::ptr::null_mut(),
            0,
            &mut needed
        ),
        3
    );
    assert_eq!(
        nd_live_plan(
            samples.as_ptr(),
            samples.len(),
            rate,
            &config,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut()
        ),
        1
    );
    // NULL config means defaults; empty input plans to nothing.
    let mut empty_needed = 0usize;
    assert_eq!(
        nd_live_plan(
            samples.as_ptr(),
            0,
            rate,
            std::ptr::null(),
            std::ptr::null_mut(),
            0,
            &mut empty_needed
        ),
        0
    );
    assert_eq!(empty_needed, 0);

    // Fixed-length batch planning covers the source exactly once.
    let total = 65 * rate as usize;
    let mut batch_needed = 0usize;
    assert_eq!(
        nd_batch_plan(
            total,
            rate,
            30.0,
            2.5,
            std::ptr::null_mut(),
            0,
            &mut batch_needed
        ),
        0
    );
    assert_eq!(batch_needed, 3);
    let mut chunks = vec![
        NdBatchChunk {
            index: 0,
            body_start_seconds: 0.0,
            body_end_seconds: 0.0,
            body_start: 0,
            body_end: 0,
            has_overlap: false,
            overlap_start: 0,
            overlap_end: 0,
        };
        batch_needed
    ];
    let mut batch_written = 0usize;
    assert_eq!(
        nd_batch_plan(
            total,
            rate,
            30.0,
            2.5,
            chunks.as_mut_ptr(),
            chunks.len(),
            &mut batch_written
        ),
        0
    );
    assert_eq!(batch_written, 3);
    assert_eq!(chunks[0].body_start, 0);
    assert_eq!(chunks[0].body_end, 30 * rate as usize);
    assert!(!chunks[0].has_overlap);
    assert!(chunks[1].has_overlap);
    assert_eq!(
        chunks[1].overlap_end - chunks[1].overlap_start,
        (2.5 * rate as f64) as usize
    );
    for pair in chunks.windows(2) {
        assert_eq!(
            pair[0].body_end, pair[1].body_start,
            "bodies stay contiguous"
        );
    }
    assert_eq!(
        nd_batch_plan(
            0,
            rate,
            30.0,
            2.5,
            std::ptr::null_mut(),
            0,
            &mut batch_needed
        ),
        0
    );
    assert_eq!(batch_needed, 0);
}

// ---------------------------------------------------------------------------
// Issue #123: automated software-gate coverage.
//
// The shared engine is the single source of platform-independent product
// logic; the macOS and future Windows hosts share this ABI. These tests
// pin the ownership/lifetime contract, the full session state matrix, the
// retry/failover tables, the realtime block contract, and the text
// insertion state transitions. They run on every CI OS (macOS, Linux,
// Windows/MSVC) with no hardware, no microphone, and no timing
// assertions. Missing manual/hardware evidence is tracked in #35 and is
// never asserted here.
// ---------------------------------------------------------------------------

#[test]
fn stable_codes_and_diagnostics_for_all_hosts() {
    // Numeric codes are ABI contract (see error.rs): hosts on any OS rely
    // on these exact values, so they are pinned here for the Windows DLL
    // consumer as well as the macOS staticlib consumer.
    assert_eq!(ND_OK, 0);
    assert_eq!(ND_ERR_NULL, 1);
    assert_eq!(ND_ERR_UTF8, 2);
    assert_eq!(ND_ERR_ARG, 3);
    assert_eq!(ND_ERR_SMALL_BUFFER, 4);
    assert_eq!(ND_ERR_DECODE, 5);
    assert_eq!(ND_ERR_PANIC, 100);
    assert_eq!(nd_abi_version(), 1);
    assert_eq!(ND_STATE_IDLE, 0);
    assert_eq!(ND_STATE_RECORDING, 1);
    assert_eq!(ND_STATE_TRANSCRIBING, 2);
    assert_eq!(ND_EVENT_ENGINE_STARTED, 0);
    assert_eq!(ND_EVENT_FIRST_BUFFER, 1);
    assert_eq!(ND_EVENT_ENGINE_FAILED, 2);
    assert_eq!(ND_EVENT_CANCELLED, 3);
    assert_eq!(ND_EVENT_STOP_REQUESTED, 4);
    assert_eq!(ND_EVENT_TRANSCRIPTION_DONE, 5);

    // The diagnostic slot is never NULL and always NUL-terminated.
    let text = nd_last_error_text();
    assert!(!text.is_null());
    // SAFETY: the ABI guarantees a valid NUL-terminated diagnostic string.
    let initial = unsafe { CStr::from_ptr(text) }.to_bytes().to_vec();

    // A failing call records a non-empty diagnostic on this thread.
    assert!(nd_word_diff(std::ptr::null(), 4, std::ptr::null(), 0).is_null());
    // SAFETY: same contract as above.
    let after = unsafe { CStr::from_ptr(nd_last_error_text()) }
        .to_string_lossy()
        .into_owned();
    assert!(!after.is_empty(), "failing call must record a diagnostic");
    drop(initial);

    // Diagnostics are thread-local: a fresh thread starts empty, so one
    // host thread can never observe another thread's failure text.
    std::thread::spawn(|| {
        // SAFETY: the ABI guarantees a valid NUL-terminated diagnostic string.
        let fresh = unsafe { CStr::from_ptr(nd_last_error_text()) };
        assert!(
            fresh.to_bytes().is_empty(),
            "fresh thread must start with an empty diagnostic"
        );
    })
    .join()
    .unwrap();
}

#[test]
fn engine_outputs_are_deterministic_for_all_hosts() {
    // The Windows host must observe byte-identical product logic for the
    // same inputs: repeated calls agree exactly.
    let old = to_c("One three.");
    let new = to_c("One two three.");
    let first = read_string(nd_word_diff(
        old.as_ptr(),
        old.as_bytes().len(),
        new.as_ptr(),
        new.as_bytes().len(),
    ));
    let second = read_string(nd_word_diff(
        old.as_ptr(),
        old.as_bytes().len(),
        new.as_ptr(),
        new.as_bytes().len(),
    ));
    assert_eq!(first, second);

    let adapter = to_c("groq");
    let model = to_c("whisper-large-v3-turbo");
    let resolve_first = read_string(nd_stt_resolve(
        adapter.as_ptr(),
        adapter.as_bytes().len(),
        model.as_ptr(),
        model.as_bytes().len(),
    ));
    let resolve_second = read_string(nd_stt_resolve(
        adapter.as_ptr(),
        adapter.as_bytes().len(),
        model.as_ptr(),
        model.as_bytes().len(),
    ));
    assert_eq!(resolve_first, resolve_second);

    let ids = to_c("a,b,c");
    let failed = to_c("b");
    let order_first = read_string(nd_failover_order(
        ids.as_ptr(),
        ids.as_bytes().len(),
        failed.as_ptr(),
        failed.as_bytes().len(),
        true,
    ));
    let order_second = read_string(nd_failover_order(
        ids.as_ptr(),
        ids.as_bytes().len(),
        failed.as_ptr(),
        failed.as_bytes().len(),
        true,
    ));
    assert_eq!(order_first, order_second);
    assert_eq!(
        nd_backoff_delay_ms(3, 500, 8000),
        nd_backoff_delay_ms(3, 500, 8000)
    );
}

#[test]
fn ownership_release_functions_are_safe_and_roundtrip() {
    // Every release function accepts NULL: hosts can free unconditionally.
    nd_string_free(std::ptr::null_mut());
    nd_bytes_free(NdByteBuffer {
        data: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    });
    nd_vad_free(std::ptr::null_mut());
    nd_gain_free(std::ptr::null_mut());
    nd_autostop_free(std::ptr::null_mut());
    nd_session_free(std::ptr::null_mut());
    nd_cooldown_free(std::ptr::null_mut());
    nd_latch_free(std::ptr::null_mut());

    // Output strings are freshly owned per call: two identical calls hand
    // out distinct buffers with equal content, each freed exactly once.
    let adapter = to_c("openai");
    let first = nd_stt_default_model(adapter.as_ptr(), adapter.as_bytes().len());
    let second = nd_stt_default_model(adapter.as_ptr(), adapter.as_bytes().len());
    assert!(!first.is_null() && !second.is_null());
    assert_ne!(first as usize, second as usize, "each call allocates anew");
    // SAFETY: both pointers came from the ABI as NUL-terminated strings.
    let (first_text, second_text) = unsafe {
        (
            CStr::from_ptr(first).to_string_lossy().into_owned(),
            CStr::from_ptr(second).to_string_lossy().into_owned(),
        )
    };
    assert_eq!(first_text, second_text);
    nd_string_free(first);
    nd_string_free(second);

    // Byte buffers roundtrip: free, then encode again into a fresh buffer
    // with identical length (the allocator is reused, never retained).
    let samples: Vec<i16> = vec![7, -8, 900];
    let mut first_out = NdByteBuffer {
        data: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    };
    assert_eq!(
        nd_wav_encode(samples.as_ptr(), samples.len(), 16000, 1, &mut first_out),
        ND_OK
    );
    let first_len = first_out.len;
    nd_bytes_free(first_out);
    let mut second_out = NdByteBuffer {
        data: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    };
    assert_eq!(
        nd_wav_encode(samples.as_ptr(), samples.len(), 16000, 1, &mut second_out),
        ND_OK
    );
    assert_eq!(second_out.len, first_len);
    nd_bytes_free(second_out);
}

#[test]
fn session_full_lifecycle_start_stop_cancel_through_abi() {
    let session = nd_session_new();
    assert!(!session.is_null());

    // Fresh sessions are idle, never ready, never cueing.
    assert_eq!(nd_session_state(session), ND_STATE_IDLE);
    assert_eq!(nd_session_is_capture_ready(session), 0);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);

    // Restart clears readiness: the second generation starts clean.
    let stale = nd_session_start(session);
    assert!(stale >= 1);
    let gen = nd_session_start(session);
    assert!(gen > stale, "each start bumps the generation");
    assert_eq!(nd_session_state(session), ND_STATE_RECORDING);
    assert_eq!(nd_session_is_capture_ready(session), 0);

    // Engine start alone never reports readiness.
    assert_eq!(
        nd_session_event(session, ND_EVENT_ENGINE_STARTED, gen),
        ND_OK
    );
    assert_eq!(nd_session_is_capture_ready(session), 0);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);

    // A stale generation is rejected silently and changes nothing.
    assert_eq!(
        nd_session_event(session, ND_EVENT_FIRST_BUFFER, stale),
        ND_OK
    );
    assert_eq!(nd_session_is_capture_ready(session), 0);

    // First valid buffer fires readiness with a one-shot cue.
    assert_eq!(nd_session_event(session, ND_EVENT_FIRST_BUFFER, gen), ND_OK);
    assert_eq!(nd_session_is_capture_ready(session), 1);
    assert_eq!(nd_session_should_emit_ready_cue(session), 1);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);

    // Stop lapses readiness and moves to transcribing; the cue is gone.
    assert_eq!(
        nd_session_event(session, ND_EVENT_STOP_REQUESTED, gen),
        ND_OK
    );
    assert_eq!(nd_session_state(session), ND_STATE_TRANSCRIBING);
    assert_eq!(nd_session_is_capture_ready(session), 0);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);

    // Transcription-done outside transcribing is impossible: while still
    // recording it leaves the session untouched.
    let recording = nd_session_start(session);
    assert_eq!(
        nd_session_event(session, ND_EVENT_FIRST_BUFFER, recording),
        ND_OK
    );
    assert_eq!(
        nd_session_event(session, ND_EVENT_TRANSCRIPTION_DONE, recording),
        ND_OK
    );
    assert_eq!(nd_session_state(session), ND_STATE_RECORDING);
    assert_eq!(nd_session_is_capture_ready(session), 1);

    // Stop while idle is a no-op (stays idle); cancel while transcribing
    // is a no-op (only recording cancels).
    let idle_session = nd_session_new();
    assert_eq!(
        nd_session_event(idle_session, ND_EVENT_STOP_REQUESTED, 1),
        ND_OK
    );
    assert_eq!(nd_session_state(idle_session), ND_STATE_IDLE);
    assert_eq!(
        nd_session_event(session, ND_EVENT_CANCELLED, recording + 1000),
        ND_OK,
        "stale cancel is rejected silently"
    );
    assert_eq!(nd_session_state(session), ND_STATE_RECORDING);

    // Cancel before any buffer ends the lifecycle with no cue, and a late
    // buffer after cancel can never fire readiness.
    let cancelled = nd_session_start(session);
    assert_eq!(
        nd_session_event(session, ND_EVENT_CANCELLED, cancelled),
        ND_OK
    );
    assert_eq!(nd_session_state(session), ND_STATE_IDLE);
    assert_eq!(nd_session_is_capture_ready(session), 0);
    assert_eq!(
        nd_session_event(session, ND_EVENT_FIRST_BUFFER, cancelled),
        ND_OK
    );
    assert_eq!(nd_session_is_capture_ready(session), 0);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);
    // Late stop after cancel stays idle.
    assert_eq!(
        nd_session_event(session, ND_EVENT_STOP_REQUESTED, cancelled),
        ND_OK
    );
    assert_eq!(nd_session_state(session), ND_STATE_IDLE);

    // Engine failure ends the session without cueing, and the next start
    // recovers with a fresh generation.
    let failed = nd_session_start(session);
    assert_eq!(
        nd_session_event(session, ND_EVENT_ENGINE_FAILED, failed),
        ND_OK
    );
    assert_eq!(nd_session_state(session), ND_STATE_IDLE);
    assert_eq!(nd_session_should_emit_ready_cue(session), 0);
    let recovered = nd_session_start(session);
    assert!(recovered > failed);
    assert_eq!(
        nd_session_event(session, ND_EVENT_FIRST_BUFFER, recovered),
        ND_OK
    );
    assert_eq!(nd_session_should_emit_ready_cue(session), 1);

    // Full stop/done cycle returns to idle with readiness lapsed.
    assert_eq!(
        nd_session_event(session, ND_EVENT_STOP_REQUESTED, recovered),
        ND_OK
    );
    assert_eq!(
        nd_session_event(session, ND_EVENT_TRANSCRIPTION_DONE, recovered),
        ND_OK
    );
    assert_eq!(nd_session_state(session), ND_STATE_IDLE);
    assert_eq!(nd_session_is_capture_ready(session), 0);

    // Null handles fail loudly with stable codes, never UB.
    assert_eq!(nd_session_start(std::ptr::null_mut()), 0);
    assert_eq!(
        nd_session_event(std::ptr::null_mut(), ND_EVENT_FIRST_BUFFER, 1),
        ND_ERR_NULL
    );
    assert!(nd_session_is_capture_ready(std::ptr::null_mut()) < 0);
    assert!(nd_session_should_emit_ready_cue(std::ptr::null_mut()) < 0);
    assert_eq!(nd_session_state(std::ptr::null_mut()), u32::MAX);
    // Unknown event codes are argument errors, not silent acceptance.
    assert_eq!(nd_session_event(session, 99, recovered), ND_ERR_ARG);

    nd_session_free(idle_session);
    nd_session_free(session);
    nd_session_free(std::ptr::null_mut());
}

#[test]
fn retry_failover_edge_cases_through_abi() {
    // Empty input joins to an empty order (still an owned string).
    let empty = to_c("");
    let none = read_string(nd_failover_order(
        empty.as_ptr(),
        empty.as_bytes().len(),
        std::ptr::null(),
        0,
        true,
    ));
    assert_eq!(none, "");
    // A failed id outside the list leaves the order untouched.
    let ids = to_c("a,b,c");
    let unknown = to_c("zzz");
    let kept = read_string(nd_failover_order(
        ids.as_ptr(),
        ids.as_bytes().len(),
        unknown.as_ptr(),
        unknown.as_bytes().len(),
        true,
    ));
    assert_eq!(kept, "a,b,c");
    // Without auto-failover the order is untouched even for a known id.
    let failed = to_c("a");
    let untouched = read_string(nd_failover_order(
        ids.as_ptr(),
        ids.as_bytes().len(),
        failed.as_ptr(),
        failed.as_bytes().len(),
        false,
    ));
    assert_eq!(untouched, "a,b,c");
    // A single candidate stays put when it is the failed one.
    let single = to_c("only");
    let stayed = read_string(nd_failover_order(
        single.as_ptr(),
        single.as_bytes().len(),
        single.as_ptr(),
        single.as_bytes().len(),
        true,
    ));
    assert_eq!(stayed, "only");

    // Candidate counts: all with auto-failover, exactly one without.
    assert_eq!(nd_failover_candidate_count(0, true), 0);
    assert_eq!(nd_failover_candidate_count(0, false), 0);
    assert_eq!(nd_failover_candidate_count(5, true), 5);
    assert_eq!(nd_failover_candidate_count(5, false), 1);

    // Error classification: only transcribe errors may fail over.
    assert!(nd_should_failover(0));
    assert!(!nd_should_failover(1));
    assert!(!nd_should_failover(99));

    // Backoff table: doubling, saturation, zero base, huge attempts.
    assert_eq!(nd_backoff_delay_ms(0, 500, 8000), 500);
    assert_eq!(nd_backoff_delay_ms(1, 500, 8000), 1000);
    assert_eq!(nd_backoff_delay_ms(4, 500, 8000), 8000);
    assert_eq!(nd_backoff_delay_ms(100, 500, 8000), 8000);
    assert_eq!(nd_backoff_delay_ms(u32::MAX, 500, 8000), 8000);
    assert_eq!(nd_backoff_delay_ms(0, 0, 8000), 0);
    assert_eq!(nd_backoff_delay_ms(100, 0, 8000), 0);
    assert_eq!(nd_backoff_delay_ms(3, 500, u64::MAX), 4000);
}

#[test]
fn realtime_block_contract_edge_cases_through_abi() {
    // An empty block (NULL with zero count) meters as silence, not UB.
    assert_eq!(nd_rms_f32(std::ptr::null(), 0), 0.0);
    assert!(nd_rms_f32(std::ptr::null(), 3) < 0.0);

    let vad = nd_vad_new();
    assert!(!vad.is_null());
    assert!(nd_vad_feed_samples(vad, std::ptr::null(), 0, 16000) >= 0);
    assert!(nd_vad_feed_samples(vad, std::ptr::null(), 8, 16000) < 0);
    let quiet = [0.0005f32; 8];
    assert!(nd_vad_feed_samples(vad, quiet.as_ptr(), quiet.len(), 0) < 0);
    assert!(nd_vad_feed(std::ptr::null_mut(), 0.1, 0.1) < 0);
    nd_vad_free(vad);

    // Gain: zero sample rate and null buffers are loud errors; loud but
    // finite input stays bounded through the soft limiter.
    let gain = nd_gain_new();
    assert!(!gain.is_null());
    let mut loud = vec![0.9f32; 160];
    let out = nd_gain_apply(gain, loud.as_mut_ptr(), loud.len(), 0.9, 16000);
    assert!(
        out.is_finite() && out >= 0.0,
        "amplified RMS is valid, got {out}"
    );
    assert!(
        loud.iter().all(|s| s.is_finite() && s.abs() <= 1.0),
        "conditioned blocks stay bounded"
    );
    assert!(nd_gain_apply(gain, loud.as_mut_ptr(), loud.len(), 0.9, 0) < 0.0);
    assert!(nd_gain_apply(gain, std::ptr::null_mut(), 8, 0.1, 16000) < 0.0);
    assert!(
        nd_gain_apply(
            std::ptr::null_mut(),
            loud.as_mut_ptr(),
            loud.len(),
            0.1,
            16000
        ) < 0.0
    );
    nd_gain_free(gain);

    // Auto-stop accepts every VAD hint shape (speech/silence/none) and
    // resets cleanly; null handles fail loudly.
    let stop = nd_autostop_new();
    assert!(!stop.is_null());
    assert!(nd_autostop_feed(stop, 0.02, 0.1, 1) >= 0);
    assert!(nd_autostop_feed(stop, 0.0005, 0.1, 0) >= 0);
    assert!(nd_autostop_feed(stop, 0.0005, 0.1, -1) >= 0);
    assert_eq!(nd_autostop_reset(stop), 0);
    assert!(nd_autostop_feed(std::ptr::null_mut(), 0.02, 0.1, 1) < 0);
    assert!(nd_autostop_reset(std::ptr::null_mut()) != 0);
    nd_autostop_free(stop);
}

#[test]
fn text_insertion_state_transitions_through_abi() {
    // Review decisions: empty/whitespace/y/Y insert, anything else cancels.
    for insert in ["", "  ", "y", "Y", " y "] {
        let line = to_c(insert);
        assert_eq!(
            nd_review_decide(line.as_ptr(), line.as_bytes().len(), true),
            1,
            "insert for {insert:?}"
        );
    }
    for cancel in ["n", "N", "nope", "yes", "yy"] {
        let line = to_c(cancel);
        assert_eq!(
            nd_review_decide(line.as_ptr(), line.as_bytes().len(), true),
            0,
            "cancel for {cancel:?}"
        );
    }
    assert_eq!(nd_review_decide(std::ptr::null(), 0, false), 0);
    // A claimed line over a null buffer, and invalid UTF-8, are errors.
    assert!(nd_review_decide(std::ptr::null(), 4, true) < 0);
    let bad = [0xffu8, 0xfe];
    let bad_ptr = bad.as_ptr() as *const c_char;
    assert!(nd_review_decide(bad_ptr, bad.len(), true) < 0);

    // Retry-insertion drop guard: only idle + current session keeps.
    assert_eq!(nd_should_drop_retry(ND_STATE_IDLE, 5, 5), 0);
    assert_eq!(nd_should_drop_retry(ND_STATE_IDLE, 5, 6), 1);
    assert_eq!(nd_should_drop_retry(ND_STATE_RECORDING, 5, 5), 1);
    assert_eq!(nd_should_drop_retry(ND_STATE_TRANSCRIBING, 5, 5), 1);
    assert_eq!(nd_should_drop_retry(ND_STATE_RECORDING, 7, 6), 1);
    assert!(nd_should_drop_retry(99, 1, 1) < 0);

    // Overlay hide rule: the overlay lives through the whole cycle.
    assert_eq!(nd_overlay_should_hide(ND_STATE_IDLE), 1);
    assert_eq!(nd_overlay_should_hide(ND_STATE_RECORDING), 0);
    assert_eq!(nd_overlay_should_hide(ND_STATE_TRANSCRIBING), 0);
    assert!(nd_overlay_should_hide(99) < 0);

    // Mic-request storm guard: window edges and degenerate configs.
    let stamps = [900.0f64, 950.0, 990.0];
    assert_eq!(
        nd_mic_request_allowed(stamps.as_ptr(), stamps.len(), 1000.0, 3, 21600.0),
        0
    );
    assert_eq!(
        nd_mic_request_allowed(stamps.as_ptr(), 2, 1000.0, 3, 21600.0),
        1
    );
    // A timeout exactly one window old has aged out (age < window counts).
    assert_eq!(
        nd_mic_request_allowed(stamps.as_ptr(), 1, 1000.0, 1, 100.0),
        1,
        "age == window is outside the window"
    );
    // Future timestamps (clock moved backward) never block.
    let future = [2000.0f64];
    assert_eq!(
        nd_mic_request_allowed(future.as_ptr(), future.len(), 1000.0, 1, 21600.0),
        1
    );
    // Zero allowance blocks everything; empty stamps with NULL base allow.
    assert_eq!(
        nd_mic_request_allowed(stamps.as_ptr(), 0, 1000.0, 0, 21600.0),
        0
    );
    assert_eq!(
        nd_mic_request_allowed(std::ptr::null(), 0, 1000.0, 3, 21600.0),
        1
    );
    assert!(nd_mic_request_allowed(std::ptr::null(), 3, 1000.0, 3, 21600.0) < 0);

    // Cooldown lifecycle: fires, suppresses inside the interval, refires.
    let cooldown = nd_cooldown_new(5.0);
    assert!(!cooldown.is_null());
    assert_eq!(nd_cooldown_allow(cooldown, 10.0), 1);
    assert_eq!(nd_cooldown_allow(cooldown, 10.0), 0);
    assert_eq!(nd_cooldown_allow(cooldown, 14.9), 0);
    assert_eq!(nd_cooldown_allow(cooldown, 15.0), 1);
    assert!(nd_cooldown_allow(std::ptr::null_mut(), 20.0) < 0);
    nd_cooldown_free(cooldown);

    // Latch lifecycle: consume-before-arm misses, double arm fires once.
    let latch = nd_latch_new();
    assert!(!latch.is_null());
    assert_eq!(nd_latch_consume(latch), 0);
    assert_eq!(nd_latch_arm(latch), 0);
    assert_eq!(nd_latch_arm(latch), 0);
    assert_eq!(nd_latch_consume(latch), 1);
    assert_eq!(nd_latch_consume(latch), 0);
    assert_eq!(nd_latch_arm(latch), 0);
    assert_eq!(nd_latch_cancel(latch), 0);
    assert_eq!(nd_latch_consume(latch), 0);
    assert!(nd_latch_arm(std::ptr::null_mut()) != 0);
    assert!(nd_latch_consume(std::ptr::null_mut()) < 0);
    assert!(nd_latch_cancel(std::ptr::null_mut()) != 0);
    nd_latch_free(latch);

    // Text joining: empty input joins to empty; a single text is itself.
    let joined_empty = read_string(nd_text_join(std::ptr::null(), std::ptr::null(), 0));
    assert_eq!(joined_empty, "");
    let solo = to_c("just this");
    let joined_solo = read_string(nd_text_join(
        [solo.as_ptr()].as_ptr(),
        [solo.as_bytes().len()].as_ptr(),
        1,
    ));
    assert_eq!(joined_solo, "just this");
}

#[test]
fn plan_buffer_contracts_reject_bad_inputs() {
    let rate = 16000u32;
    let samples = vec![1000i16; rate as usize];
    let config = NdSegmenterConfig {
        pause_duration: 1.0,
        min_segment: 1.0,
        max_segment: 45.0,
        overlap: 1.0,
        silence_rms: 0.00316,
        use_adaptive_vad: false,
        enter_margin_db: 8.0,
        hysteresis_db: 4.0,
        min_enter_db: -60.0,
        max_enter_db: -25.0,
    };
    // A null count slot is a null-pointer error even for valid inputs.
    assert_eq!(
        nd_live_plan(
            samples.as_ptr(),
            samples.len(),
            rate,
            &config,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut()
        ),
        ND_ERR_NULL
    );
    // Batch planning mirrors the same contract: null count slot, zero
    // sample rate, and empty input planning to nothing.
    let mut needed = 0usize;
    assert_eq!(
        nd_batch_plan(
            100,
            rate,
            30.0,
            2.5,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut()
        ),
        ND_ERR_NULL
    );
    assert_eq!(
        nd_batch_plan(100, 0, 30.0, 2.5, std::ptr::null_mut(), 0, &mut needed),
        ND_ERR_ARG
    );
    assert_eq!(
        nd_batch_plan(0, rate, 30.0, 2.5, std::ptr::null_mut(), 0, &mut needed),
        ND_OK
    );
    assert_eq!(needed, 0);
    // A short batch buffer is a clean error carrying the required count.
    let total = 65 * rate as usize;
    assert_eq!(
        nd_batch_plan(total, rate, 30.0, 2.5, std::ptr::null_mut(), 0, &mut needed),
        ND_OK
    );
    assert_eq!(needed, 3);
    let mut one = [NdBatchChunk {
        index: 0,
        body_start_seconds: 0.0,
        body_end_seconds: 0.0,
        body_start: 0,
        body_end: 0,
        has_overlap: false,
        overlap_start: 0,
        overlap_end: 0,
    }];
    let mut written = 0usize;
    assert_eq!(
        nd_batch_plan(
            total,
            rate,
            30.0,
            2.5,
            one.as_mut_ptr(),
            one.len(),
            &mut written
        ),
        ND_ERR_SMALL_BUFFER
    );
    assert_eq!(written, 3);
    // Transcript parse rejects undecodable bodies with a decode error
    // recorded in the diagnostic slot.
    let bad = to_c("nope");
    assert!(nd_transcript_parse(bad.as_ptr(), bad.as_bytes().len(), std::ptr::null(), 0).is_null());
    // SAFETY: the ABI guarantees a valid NUL-terminated diagnostic string.
    let diagnostic = unsafe { CStr::from_ptr(nd_last_error_text()) }
        .to_string_lossy()
        .into_owned();
    assert!(!diagnostic.is_empty());
    // Invalid UTF-8 on the transcript path is a clean NULL, not a panic.
    let utf8_bad = [0xffu8, 0xfe];
    let path = to_c("text");
    assert!(nd_transcript_parse(
        utf8_bad.as_ptr() as *const c_char,
        utf8_bad.len(),
        path.as_ptr(),
        path.as_bytes().len(),
    )
    .is_null());
}
