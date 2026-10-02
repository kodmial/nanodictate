# NanoDictate shared Rust engine: architecture

## Status

The shared Rust engine, C ABI, Swift bridge, build integration, and cross-platform Rust CI are now merged into `main` as the foundation from PR #67. Production call-site activation and the real-macOS hardware parity/performance gate remain mandatory follow-up work tracked in #123 before the overall migration in #50 can be considered complete.

Migration Step 2 is complete and Step 3 is implemented at the parity-test/foundation level:

- Step 1 (baseline): the macOS behavioral baseline is documented by the
  existing Swift unit/integration suites under `Tests/NanoDictateCoreTests`
  (recording readiness, VAD, autostop, segmentation, provider routing,
  insertion, permissions) plus the parity vectors below.
- Step 2 (workspace + ABI): `rust/` workspace, stable C ABI, generated
  header, Swift bridge, build integration, and CI exist. No production
  behavior was replaced to get here.
- Step 3 (deterministic logic): the engine ports the subsystems listed
  below. `Tests/NanoDictateCoreTests/RustParityTests.swift` runs the same
  input vectors against the Swift reference implementations and the
  engine, requiring equivalent output.
- Not yet done: switching production call sites to the engine (one
  subsystem at a time, after the macOS hardware parity gate passes),
  removing the superseded Swift implementations, and the Windows native
  layer (blocked on this refactor by design).

## Non-negotiable principle

macOS is the reference implementation and must not be reduced to a
cross-platform common denominator. Code moves to Rust only when the Rust
implementation preserves the macOS behavior without meaningful
regression. Where Apple APIs are materially better, the Swift
implementation stays and the engine exposes a boundary for it. A macOS
feature is never removed, weakened, or delayed because another platform
cannot provide it the same way.

## Responsibility split

### Shared Rust engine (`rust/nanodictate-core`)

Behavior whose meaning does not depend on the operating system.
Ported so far:

| Module | Ports (Swift) | Notes |
|---|---|---|
| `audio_metrics` | `AudioMetrics` | dBFS, Int16 RMS, history summary, near-silence |
| `wav` | `WAVEncoder`, `WAVDecoder` | Byte-identical encoder; same canonical decoder |
| `word_diff` | `WordDiff` | One contiguous change range for single-action fixup |
| `text_joiner` | `BatchTextJoiner` | Boundary-overlap dedup, placeholder verbatim rule |
| `vad` | `NoiseFloorTracker`, `AdaptiveVAD(Config)`, `SoftLimiter` | Raw-signal decisions, hysteresis |
| `input_gain` | `InputGain(Config)` | Adaptive-gated AGC, per-sample smoothing, limiter |
| `autostop` | `AutoStopConfig`, `SilenceAutoStopDetector` | Hysteresis, grace, speech gate, duration floor |
| `segmenter` | `AudioSegmenter`, `BatchSegmenter` (planning math) | Pause-aligned split, overlap windows, batch bodies |
| `stt` | `STTAdapterID`, `STTCapabilities`, `STTModelRegistry` | Profile resolution, audio requirements |
| `transcript` | `Transcriber` response extraction | Flat/nested text paths, word timestamps |
| `retry` | `RetryProvider` queue policy | Failover ordering, error classification, backoff |
| `session` | `AudioService` readiness latch, `MicErrorCooldown`, `EnterSendLatch`, `ReviewGate` decision, `RetryInsertionGate`, `OverlayLifecycle`, `MicRequestPolicy` window math | State machine + small policies |

Deliberately Unicode-adjacent caveat: `word_diff` offsets count Unicode
scalar values. For Latin/Cyrillic product text this coincides with Swift
`String` character offsets; multi-scalar grapheme clusters stay the
native insertion layer's responsibility.

### Native Swift/macOS layer (`Sources/NanoDictateCore`, executables)

Everything that depends on macOS APIs, hardware integration,
permissions, lifecycle, or platform optimization. This includes, and is
not limited to:

- microphone acquisition through AVFoundation (`AudioService`:
  `AVAudioEngine` lifecycle, input-node/tap management, hardware format
  discovery, `AVAudioConverter` normalization, serialized operations,
  ObjC exception guard, generation tracking, stale-generation rejection,
  device-change recovery, first-buffer preservation, recording limits);
- microphone TCC and Accessibility permission flows, watchdogs,
  anti-storm persistence, settings-panel routing;
- global key capture through CoreGraphics event taps, Option-event
  semantics, Escape/Return handling, synthetic Return identification;
- text injection through `CGEvent` (chunked Unicode insertion,
  clipboard mode, undo, insertion-after-review);
- overlay/application behavior, system sounds, launchd lifecycle,
  macOS paths, signing continuity, Homebrew/MacPorts packaging;
- OS networking (the engine produces STT request policy and consumes
  normalized responses; `URLSession`/proxy/cookie transport stays
  native);
- file-backed sample windows (`PCMBatchContent`); the engine exposes
  the boundary math over sample ranges.

Do not replace the proven AVFoundation capture path with a generic Rust
audio library. Do not replace working macOS integrations to reduce
Swift code.

## Dependency direction

```text
macOS native code ─────► shared Rust engine
       └──── owns Apple framework integration
```

The Rust engine has zero OS-specific dependencies (no AppKit,
AVFoundation, CoreGraphics, TCC, launchd; no Windows crates either).
The native layer may expose platform capabilities to the engine without
requiring every future platform to expose identical ones.

## ABI contract (`rust/nanodictate-core/src/abi.rs`)

- Language-neutral C ABI: `extern "C"` functions, C-compatible
  representations only, opaque handles (`NdVad`, `NdGain`,
  `NdAutoStop`, `NdSession`, `NdCooldown`, `NdLatch`).
- Input strings/buffers use explicit pointer + length contracts.
- Every Rust-owned output allocation has a release function
  (`nd_string_free`, `nd_bytes_free`); output byte buffers are
  `NdByteBuffer` values carrying length and capacity.
- Errors use stable codes (`rust/nanodictate-core/src/error.rs`; never
  renumbered) plus a thread-local diagnostic (`nd_last_error_text`).
- Rust panics never cross the boundary: every entry point catches
  panics and maps them to `ND_ERR_PANIC` (or NULL).
- Handles are movable across threads but not thread-safe; the host
  serializes calls (same contract as the Swift objects they mirror).
- `ND_ABI_VERSION` (`nd_abi_version`) is bumped on any incompatible
  change. The public header is generated deterministically with
  cbindgen (`rust/nanodictate-core/cbindgen.toml`) into
  `Sources/NanoDictateRustFFI/include/nanodictate_core.h`; CI fails
  when the committed header is stale (`scripts/check-rust-abi.sh`).

## Realtime audio boundary

Native capture stays responsible for obtaining valid audio. The
ingress into the engine is narrow and block-oriented:

- `nd_vad_feed_samples` / `nd_gain_apply` transfer whole Float32 blocks
  with explicit sample-rate metadata; there are no per-sample FFI calls.
- The engine performs O(n) math with no allocation, no locks, no I/O,
  and no synchronous network work on this path.
- VAD/autostop decisions consume the raw (pre-gain) signal; the
  amplified signal feeds only level meters and the recording.
- Overhead is measured on the macOS side around the bridge call; if a
  boundary ever shows material latency/copy/allocation regression, the
  boundary is rebatched before any algorithm is accepted into the
  engine.

## Host capability model

Platforms expose capabilities; the engine never assumes them. The
session state machine (`NdSession`) encodes cross-platform invariants
that every host must honor — most importantly the capture-readiness
latch (the recording-ready cue follows the first valid buffer of the
current engine generation, exactly once; stale generations are
rejected) — while the native layer owns how buffers, permissions, and
the cue itself are produced.

## Build / link flow

```text
scripts/build-rust-core.sh
  ├── cargo build --release -p nanodictate-core
  │     ├── libnanodictate_core.a (staticlib) → linked into the macOS app
  │     │     by absolute archive path (-Xlinker .../libnanodictate_core.a);
  │     │     never via -L/-lnanodictate_core, which would pick the cdylib
  │     │     and embed an absolute LC_LOAD_DYLIB path that breaks packaged
  │     │     binaries on other hosts.
  │     └── cdylib/DLL         → Windows portability artifact
  ├── scripts/check-rust-abi.sh (cbindgen freshness gate)
  └── prints the -Xlinker <abs path>/libnanodictate_core.a flags for swift build
```

SwiftPM targets:

- `NanoDictateRustFFI` (clang): the generated C header + compile shim.
- `NanoDictateRustBridge` (Swift): memory-safe wrappers, no behavior.
- `NanoDictateCore` → depends on the bridge; `Sources/NanoDictateCore/
  RustEngine.swift` is the composition seam for engine-backed entry
  points (production call sites switch over after the parity gate).

## Windows path (future, separate task)

A Windows implementation reuses `nanodictate-core` through the same C
ABI (or a thin projection of it) while implementing Windows-native
capture/input/permissions separately. The Windows CI job in
`.github/workflows/rust.yml` already builds the engine and its tests
with MSVC and publishes the DLL as a portability artifact; it is not
the Windows application. Windows capabilities may differ from macOS
capabilities; the architecture allows that without touching the engine.

## Parity gate (before removing any Swift implementation)

Same vectors, equivalent output (enforced by `RustParityTests` in CI),
plus real-hardware macOS validation: repeated start/stop, rapid speech
after activation, permission states, device changes, wedge recovery,
normal/chunked dictation, silence auto-stop, recording limits,
routing/failover, review-before-insert, direct/clipboard insertion,
Escape/Return, undo. Baseline vs post-refactor measurements (start
latency, callback time, CPU, memory, copy/allocation counts) must show
no material regression before the old path is removed.
