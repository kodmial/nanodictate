# Windows product (supported release)

Native Windows product for NanoDictate on the **same production Rust
core used by macOS** (`rust/nanodictate-core` through its stable C ABI).

This stage adds the core interaction model around the capture pipeline
from the previous stage: global double-Alt activation with false-trigger
protection and hook recovery, Escape cancellation and Return/Enter
workflow, microphone/privacy failure handling with settings guidance,
direct Unicode insertion (SendInput KEYEVENTF_UNICODE) plus clipboard
mode with restore, chunked insertion, undo, synthetic Enter, and
startup/background/tray/process lifecycle with Windows config/log
locations. All policy decisions (session readiness, VAD/gain/auto-stop,
failover/backoff, word diff, text join, review, retry/overlay/mic-request
gates, STT profile resolution) stay in Rust; C# provides Windows-native
I/O and capabilities. This is the supported product stage: transcription
wiring (normal/chunked/realtime), provider/model selection and routing,
retry/failover, review-before-insert, diagnostics, proxy/transport modes,
WinUI 3 entrypoint, reproducible packaging, and release CI.


## Install and update without developer tools

See [Windows distribution](DISTRIBUTION.md). With Scoop installed:

```powershell
scoop bucket add nanodictate https://github.com/kodmial/nanodictate
scoop install nanodictate
scoop update nanodictate
```

Windows binary releases share the macOS version and GitHub Release.
The release workflow refuses to publish a new version without both
platforms' artifacts and their checksums. A direct EXE installer is
also published for users without Scoop, once the combined release
pipeline completes successfully.

## Layout

```text
windows/
  NanoDictate.sln              # portable: Core + Host + Smoke + Tests (net8.0, any OS)
  src/NanoDictate.Core/        # thin P/Invoke adapter + Windows-native I/O, no product logic
  src/NanoDictate.Host/        # supported console/tray product host (run/doctor/transcribe-file/providers)
  src/NanoDictate.App/         # Windows-only WinUI 3 entrypoint (built on windows-latest only)
  src/NanoDictate.Smoke/       # minimal executable smoke path
  tests/NanoDictate.Core.Tests/  # xUnit ABI/ownership/error/session/capture/host/transcription tests
  package/                     # MSIX manifest + make-msix.ps1 reproducible packaging
  DISTRIBUTION.md              # installer/update/uninstall/supported versions
  PARITY.md                    # feature parity matrix and explicit differences
  VALIDATION.md                # hardware validation runbook + measurement contracts
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

## Developer build prerequisites

- Windows 10 22H2 or Windows 11, x64.
- .NET 8 SDK or later.
- Rust stable with the MSVC target (`rustup target add x86_64-pc-windows-msvc`).

## Local build

```powershell
# From the repository root:
cargo build --release -p nanodictate-core
dotnet build windows/NanoDictate.sln -c Release
dotnet build windows/src/NanoDictate.Host/NanoDictate.Host.csproj -c Release
dotnet test windows/NanoDictate.sln -c Release
dotnet run --project windows/src/NanoDictate.Smoke -c Release -- config.example.toml
dotnet run --project windows/src/NanoDictate.Host -c Release -- doctor --config config.example.toml
# Windows-only (windows-latest):
dotnet build windows/src/NanoDictate.App/NanoDictate.App.csproj -c Release
pwsh windows/package/make-msix.ps1 -Version 0.1.33
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

## Host capabilities (this stage)

- **Activation** (`GlobalHotkeyService` + `DoubleAltDetector`): WH_KEYBOARD_LL
  hook; only Alt key codes count as taps; any other key/modifier cancels the
  pending first tap; held-key repeat never counts; pending expiry fires
  `AltPendingCancelled`; hook install/reinstall failures throw loudly and
  `Recover()` reinstalls after silent removal. Off Windows, `Start`
  throws `PlatformNotSupportedException` (never a silent no-op).
- **Cancel/Enter** (`DictationController` as `IGlobalHotkeyDelegate`):
  Escape cancels capture, the Enter latch, and any scheduled Enter; Return
  arms the Rust latch (`LatchHandle`) in Recording and stops, no-ops in
  Transcribing, and is swallowed outside Idle. Own synthetic Enter (extra-info
  token `SyntheticEnterMarker`) is excluded from routing entirely.
- **Microphone/privacy** (`MicPrivacy.cs`): WASAPI HRESULT classification
  (E_ACCESSDENIED = privacy-blocked with `ms-settings:privacy-microphone`
  guidance, E_NOTFOUND = no device, device-invalidated = disconnected);
  error UI throttled through the Rust cooldown (`CooldownHandle`); request
  storm guard through Rust `nd_mic_request_allowed` with JSON persistence at
  `%APPDATA%\NanoDictate\mic-request-state.json`.
- **Direct insertion** (`TextInserter` + `TextChunker` + `WindowsInputSender`):
  SendInput KEYEVENTF_UNICODE per UTF-16 unit (Cyrillic/emoji-safe),
  16-grapheme / 20-unit chunks with 5 ms pauses between chunks, Backspace
  undo in matching chunks, VK_RETURN down/up tagged for the hook.
  Platform difference (explicit): macOS chunks around a CGEvent truncation
  limit; Windows keeps the same ceilings for responsiveness and parity.
- **Clipboard mode** (`ClipboardInsertService` + Win32 bridge): save text,
  Ctrl+V, restore after 0.5 s; overlapping inserts reuse the original
  snapshot and only the latest restore runs. The bridge preserves the
  Unicode text slot via raw clipboard APIs (no WinForms); non-text formats
  are an explicit documented limitation, mirroring the macOS full-snapshot
  difference rather than silently claiming parity.
- **Undo + Enter** (`DictationController` + `CancellableEnterPoster`):
  double-Alt in Idle inside the undo window erases the last insertion;
  Enter-stop posts exactly one synthetic Enter 0.25 s after insertion;
  Escape cancels the scheduled post. Word-diff/text-join/review/retry/
  overlay choices all come from Rust (`RustTextPolicy`/`NanoEngine`).
- **Lifecycle + paths** (`HostLifecycle`, `StartupManager`, `WindowsPaths`):
  global-mutex single instance, Run-key startup registration, tray status
  behind `ITrayIcon`, Ctrl+C shutdown; `%APPDATA%\NanoDictate\config.toml`
  and `%LOCALAPPDATA%\NanoDictate\Logs` (macOS uses
  `~/Library/Application Support` + `~/.config`; never mixed silently).
- **Config** (`PortableConfig`): carries `insert_method` (`cgevent` maps to
  Direct on Windows), `double_alt_max_interval`, `undo_max_interval`, and
  `review_before_insert`; every policy still resolves through Rust. Provider
  credentials use the shared contract: per-provider `api_key` /
  `api_key_file`, with `NANODICTATE_API_KEY` overriding only the effective
  active provider. See `docs/config-parity.md` for the shared key matrix and
  explicit platform differences.

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
