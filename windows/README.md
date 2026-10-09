# Windows host (capture stage)

Native Windows host for NanoDictate on the **same production Rust
core used by macOS** (`rust/nanodictate-core` through its stable C ABI).

This stage adds real microphone capture: WASAPI shared-mode capture
feeds the block-oriented shared-engine ingress (per-block RMS, adaptive
VAD, AGC input gain, silence auto-stop) and drives the same Rust session
state machine as macOS, including the capture-readiness latch and
first-buffer semantics. Still out of scope: global hotkeys, text
insertion, UI polish, installer, and packaging.

## Layout

```text
windows/
  NanoDictate.sln
  src/NanoDictate.Core/    # thin P/Invoke adapter, no product logic
  src/NanoDictate.Smoke/   # minimal executable smoke path
  tests/NanoDictate.Core.Tests/  # xUnit ABI/ownership/error/session/capture tests
```

`NanoDictate.Core` owns no behavior. Every wrapper marshals arguments,
calls exactly one `nd_*` entry point, maps the stable error code plus
`nd_last_error_text`, and releases Rust-owned allocations with the
matching `nd_string_free` / `nd_bytes_free` / `*_free` function.
Failover ordering, backoff math, VAD thresholds, transcript rules, and
session semantics stay in Rust.

Portable configuration (`PortableConfig`) only carries data parsed from
the shared TOML shape (`config.example.toml`); all policy decisions go
through `NanoEngine` into Rust.

## Prerequisites

- Windows 10 22H2 or Windows 11, x64.
- .NET 8 SDK or later.
- Rust stable with the MSVC target (`rustup target add x86_64-pc-windows-msvc`).

## Local build

```powershell
# From the repository root:
cargo build --release -p nanodictate-core
dotnet build windows/NanoDictate.sln -c Release
dotnet test windows/NanoDictate.sln -c Release
dotnet run --project windows/src/NanoDictate.Smoke -c Release -- config.example.toml
```

The loader resolves the engine in this order: `NANODICTATE_CORE_DLL`
environment variable, app directory, `rust/target/release/`, then the
default OS search. CI copies the freshly built
`nanodictate_core.dll` next to the managed binaries before running
tests and the smoke executable.

## Supported scope

- Windows x64 desktop. ARM64 is not packaged in this stage.
- The Rust `cdylib` is built with the MSVC target; no Windows-specific
  behavior was added to the Rust core for this stage.

## Windows-native capture behavior

Capture is Windows-native end to end; AVFoundation is not emulated and
no Rust algorithm is forked in C#.

- **API**: WASAPI shared mode on the default console capture endpoint
  (`WasapiCaptureSource` via `WasapiInterop`: `IMMDeviceEnumerator`,
  `IAudioClient`, `IAudioCaptureClient`, `IMMNotificationClient`).
  No exclusive mode, no format forcing.
- **Default device format**: the device mix format is accepted as-is
  (typically 48 kHz stereo Float32); only Float32 mix formats are
  supported and anything else fails the start loudly. `AudioFormat`
  describes the device side; the agreed engine ingress is always
  16 kHz mono Float32.
- **Normalization** (`AudioFormatConverter`): channel downmix by mean,
  linear resample to 16 kHz, fractional phase carried across callbacks.
  The first device packet is converted synchronously: no warm-up frames
  are dropped, so speech starting immediately after activation survives
  (first-word robustness). `Flush` emits the trailing remainder at stop.
- **Shared-engine ingress** (`RealtimeAudioPipeline`, one 1600-sample /
  100 ms engine block at a time): raw RMS (`nd_rms_f32`) on the
  pre-gain signal, adaptive VAD (`nd_vad_feed_samples`), AGC applied in
  place (`nd_gain_apply`), auto-stop with the VAD hint
  (`nd_autostop_feed`). The amplified signal feeds the recording; VAD
  and auto-stop always consume the raw value. Live segmentation
  (`nd_live_plan`) and batch chunk planning (`nd_batch_plan`) run
  through the same engine at stop time.
- **Session state machine**: the same Rust `NdSession` as macOS.
  `Start` alone never reports readiness; readiness fires exactly once
  per session on the first valid engine block of the current generation
  (`CaptureReady` event with timing). Gate the start cue on that event,
  never on `Start` alone. Stale generations are rejected by the engine.
- **Device changes**: a default-capture-device change mid-session aborts
  the session (`DeviceChanged`); continuing on the old format would
  yield silence or desync. Restart with one command.
- **Start failures and recovery**: a failed source start drives
  `EngineFailed` into the Rust session (back to Idle) and rethrows; the
  service stays reusable for a retry. Every stop releases all COM
  objects, so repeated start/stop never leaks a client.
- **Tests without hardware**: `SyntheticCaptureSource` replays scripted
  device-format blocks with capture-thread semantics, so the xUnit
  suite proves repeated sessions, first-buffer preservation,
  start-failure recovery, and device-change abort on any OS.

## Realtime bounds and measurements

Per-block realtime work is O(n) engine math with no allocation beyond
the block itself, no I/O, and no network work; the single instance lock
only serializes handle access (the Rust handles are not thread-safe).
Engine errors drop the block fail-closed (counted, never C#-processed).

Every session snapshot (`CaptureMetrics`) reports: activation-to-ready
(trigger to request, request to engine-started, engine-started to
first buffer), per-block callback cost (mean/max over the session),
CPU time and working set, device frames consumed vs engine samples
emitted, collected sample count, structural copies per block (2:
downmix/resample staging plus Int16 append), and the auto-stop flag.
The smoke path prints one line per run with block/error counts,
mean/max block cost, first-buffer latency, sample/segment counts, and
the auto-stop outcome; the xUnit suite asserts the mean block cost
stays far below the 100 ms block budget.
