# Windows product parity (vs macOS)

The Windows host uses the same production Rust core as macOS
(`rust/nanodictate-core` through the stable C ABI, ABI version 1).
Shared product logic is not duplicated in C#: every policy decision
(session readiness, VAD/gain/auto-stop, segmentation, failover ordering,
backoff, word diff, text join, transcript extraction, review/retry/
overlay/mic-request gates, STT profile resolution) calls into Rust.
C# provides Windows-native I/O only (WASAPI, hooks, SendInput,
clipboard, registry, paths, HUD styling, HTTP transport framing).

## Covered portable workflows

- Normal transcription: one complete WAV per request (OpenAI-compatible
  multipart), response parsed via `nd_transcript_parse`.
- Chunked transcription: `nd_batch_plan` chunks → per-chunk transcribe
  with one provider → Rust `nd_text_join` stitching → configurable final
  full-recording pass (`always` / `on-uncertainty` / `never`).
- Realtime transcription: one streaming session per dictation over 24 kHz
  mono PCM16 (resampled from the 16 kHz engine ingress); deltas
  accumulate, completion carries the final hypothesis, transport drops
  fail closed with no silent batch fallback.
- Provider/model selection and routing: active/segment/final roles from
  the shared TOML shape; failover order, candidate count, and
  should-failover through `nd_failover_order` / `nd_failover_candidate_count` /
  `nd_should_failover`; backoff through `nd_backoff_delay_ms`.
- Review-before-insert: `nd_review_decide` (empty/y/Y inserts, anything
  else or end-of-input cancels, fail-closed).
- Diagnostics: `doctor` verb runs engine ABI, config resolution, Rust
  policy vectors, synthetic audio pipeline, and STT profile checks with
  no network or hardware.
- Proxy/transport modes: `direct` (default), `http` (URL-as-path rewrite,
  https only, optional Proxy-Authorization), `gateway` (secret header).
- Retry/failover: retryable = transport failure, 429, or 5xx; anything
  else is final; non-transcribe failures never fail over (Rust kind gate).

## Explicit platform differences

- UI: both platforms run a background agent with a transient HUD. macOS
  uses `NSApplicationActivationPolicy.accessory` (no menu-bar item and no
  Dock icon); Windows runs one WinUI 3 process (`NanoDictate.App`) with a
  non-activating HUD, optional settings, and a transient review prompt.
  Neither ships a developer dashboard or permanent tray icon. The
  source-built console host (`NanoDictate.Host`) provides on-demand
  `doctor`, `providers`, `transcribe-file`, and headless `run` commands but
  is not installed by the Windows EXE/ZIP. The cross-platform solution
  excludes the WinUI project so Linux/macOS verification never needs the
  Windows App SDK.
- HUD presentation: both platforms consume the same #216 fixture for
  phases, deferred Starting, first-buffer readiness, meter ballistics,
  terminal hide delays, generation checks, and caret/pointer/screen
  placement. Windows renders with WinUI and Win32 styles (UIA/native caret,
  system theme/high-contrast colors, Reduce Motion); macOS keeps
  SwiftUI/AppKit. Neither platform derives HUD phase from Rust
  `DictationState`.
- Activation: double-Alt via WH_KEYBOARD_LL on a dedicated message-loop
  thread (macOS uses its own hotkey service); only Alt codes count, other
  keys cancel, repeats never count.
- Insertion: SendInput KEYEVENTF_UNICODE per UTF-16 unit (macOS: CGEvent);
  same 16-grapheme / 20-unit chunk ceilings for responsiveness.
- Clipboard: raw Win32 CF_UNICODETEXT bridge preserves the Unicode text
  slot only; macOS snapshots every pasteboard type. Non-text formats are
  a documented limitation, not silently claimed.
- Capture: WASAPI shared mode on the default console endpoint, Float32
  mix only (macOS: AVFoundation); device change aborts the session.
- Config/log paths: `%APPDATA%\NanoDictate\config.toml` and
  `%LOCALAPPDATA%\NanoDictate\Logs` (macOS: Application Support/Logs).
- Startup: HKCU Run key (macOS: launchd). Logon startup, the Inno installer,
  PowerShell and Scoop launch `NanoDictate.App.exe --background`. The WinUI
  process has no permanent tray icon; a second launch opens optional
  settings only while idle, and the settings window exposes Quit.
- `cookie-relay` transport is rejected loudly on Windows (no JS-challenge
  cookie solver); use `direct`, `http`, or `gateway`.
- `DictationTextPolicy.IsEmptyResult` mirrors the Swift whitespace/letter-
  digit rule in C# because the engine exposes no empty-result entry point;
  it delegates to Rust if one is added.
