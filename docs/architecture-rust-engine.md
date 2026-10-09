# NanoDictate shared Rust engine: architecture

## Status

The shared Rust engine, C ABI, Swift bridge, build integration, and cross-platform Rust CI are now merged into `main` as the foundation from PR #67. Production call-site activation is complete (#131, #132, #133 are closed and merged: the shipping macOS app drives the production Rust session, deterministic STT/retry/text, and realtime audio algorithms through `Sources/NanoDictateCore/RustEngine.swift`). The remaining #123 work is the automated software-gate qualification in CI; real-hardware and manual validation is tracked separately in #35 and blocks neither Windows work nor release publication, and the Windows native layer follows in #137/#167.

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
- Production cutover (#132): the default shipping path drives the engine
  for the deterministic subsystems through `Sources/NanoDictateCore/
  RustEngine.swift` — model/profile resolution and portable STT defaults,
  transcript parsing, failover ordering and deterministic retry/backoff,
  chunk text joining, word diff and overlap tails, review decisions, and
  offline WAV encode/decode. Native networking (`URLSession`/proxy/cookie
  transport), realtime capture/VAD/gain/autostop/segmenter behavior, and
  macOS integration stay in Swift. `Tests/NanoDictateCoreTests/
  RustDeterministicCutoverTests.swift` proves the shipping call sites
  exercise the engine; the Swift references stay until the final parity
  gate below removes them.
- Not yet done: the Windows native layer (blocked on this refactor by
  design; it reuses the engine through the same C ABI). Superseded
  Swift is removed only when the automated software gate passes and the
  audit confirms the logic is actually superseded with a safe fallback:
  the reference implementations stay on as parity oracles and the
  OS-native adapters stay native (see the parity gate below).

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

- `nd_rms_f32` meters one Float32 block; `nd_vad_feed` /
  `nd_vad_feed_samples` decide speech per block; `nd_gain_apply`
  conditions the block in place; `nd_autostop_feed` accumulates silence
  with the VAD hint. There are no per-sample FFI calls.
- Handles are configured at construction (`nd_vad_new_with_config`,
  `nd_gain_new_with_config`, `nd_autostop_new_with_config`) so host
  policy (gain targets, VAD margins, auto-stop thresholds) is honored
  without a Swift fallback; `nd_gain_reset` / `nd_autostop_reset` /
  `nd_vad_reset` and `nd_vad_diagnostics` / `nd_gain_current_db` cover
  session lifecycle and meter observability.
- Offline boundary math is a single block call per recording or file:
  `nd_live_plan` (pause-gated live segments with overlap) and
  `nd_batch_plan` (fixed-length chunk bodies with overlap). The host
  keeps owning the samples and materializes PCM through the returned
  ranges.
- Per-block realtime calls perform O(n) math with no allocation, no
  locks, no I/O, and no synchronous network work on this path. The
  offline planners (`nd_live_plan`, `nd_batch_plan`) allocate only
  internal scratch (RMS timeline, plan) and never retain PCM; they are
  not for the realtime callback.
- VAD/autostop decisions consume the raw (pre-gain) signal; the
  amplified signal feeds only level meters and the recording.
- Overhead is measured on the macOS side around the bridge call
  (`RealtimeAudioStats` on the shipping path; `RustParityGate`
  budgets); if a boundary ever shows material latency/copy/allocation
  regression, the boundary is rebatched before any algorithm is accepted
  into the engine.

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

Two tracks, per #123:

- Automated software gate (CI-executable, no hardware prerequisite).
  `Sources/NanoDictateCore/RustParityGate.swift`
  (`evaluateSoftware`) passes when every automated coverage area is
  green — C ABI/lifetime and memory ownership, the native Swift bridge,
  start/stop/cancel/session state, STT retry/failover, realtime
  audio/VAD, and text insertion state transitions — plus
  CI-generated performance measurements for supported, measurable cases
  (block-oriented FFI overhead around the bridge call) show no material
  regression. Tests use fake audio devices and permissions; physical
  microphone latency or resource parity is never asserted from mocks.
  A coding agent completes this gate using existing CI alone: no
   human-operated hardware run, owner attestation, or out-of-band
   evidence is required. Passing it unblocks the Windows implementation
   (#137/#167) and release publication. Release publication enforces this:
   the release `candidate-gate`
   (`.github/workflows/nanodictate-release-engine.yml`) requires both the
   exact-head Packaging smoke run and the exact-head CI run to be green.
   The CI run executes `scripts/ci-validation.sh` → `NanoDictateCoreTests`,
   which carries the `evaluateSoftware` unit coverage plus the real
   block-oriented FFI overhead probes measured against the linked engine;
   fixed `passingMeasurements()` fixtures in `RustParityGateTests` are
   unit-test oracles for the gate logic, not release evidence. Packaging
   success alone never publishes.
- Real-hardware qualification (tracked in #35, never blocking). The
  same gate model keeps the hardware checklist
  (`ChecklistItem` / `evaluate`): repeated start/stop, rapid speech
  after activation, permission states, device changes, wedge recovery,
  normal/chunked dictation, silence auto-stop, recording limits,
  routing/failover, review-before-insert, direct/clipboard insertion,
  Escape/Return, undo. Baseline vs post-refactor measurements (start
  latency, callback time, CPU, memory, copy/allocation counts) must show
  no material regression before superseded Swift is removed. Missing
  hardware evidence lives in #35; it never fails the automated gate.

Same vectors, equivalent output (enforced by `RustParityTests` in CI).
Only actually superseded duplicate business logic may be removed, after
ensuring a safe fallback where required: the Swift reference
implementations stay on as parity oracles, and OS-native
capture/TCC/Accessibility adapters stay in their respective hosts. The
Windows host reuses this engine through the same C ABI (or a thin
projection of it) instead of reimplementing product logic.

No macOS 12 runtime compatibility is claimed by CI here: automated
runs execute on newer macOS runners (the actual runner OS version is
reported in each workflow log) against the 12.0 deployment target.
Optional target-runtime verification on real macOS 12 remains the
separate #35 workstream.
