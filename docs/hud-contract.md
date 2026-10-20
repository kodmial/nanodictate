# Shared HUD presentation contract (#216)

This document defines the versioned presentation contract that the macOS HUD
already implements and that the Windows HUD (#212) must reproduce. It is a
verification contract, not a new UI framework: macOS keeps SwiftUI/AppKit, and
the Windows host keeps its own native renderer. Rust remains the owner of the
portable session, audio-metric, retry, and latch decisions only.

Authoritative data lives in
[`Tests/Fixtures/HUD/hud-contract-v1.json`](../Tests/Fixtures/HUD/hud-contract-v1.json).
The JSON is the executable source of truth for constants, level vectors, VU
traces, and presentation scenarios. Prose here explains intent; when they
disagree, the fixture plus the macOS reference tests win.

## Contract versions

| Field | Value |
|---|---|
| `contract` | `nanodictate.shared-hud` |
| `version` | `1` |
| Reference platform | macOS (`OverlayController`, `OverlayLevel`, `OverlayLifecycle`) |

A contract change that alters observable presentation must add a new fixture
version or explicitly evolve `version` and update every consumer in the same
change. Existing consumers must never be silently reinterpreted.

## Presentation phases

The HUD phase is host presentation state. It is deliberately **not**
`DictationState` and must not be derived from the Rust session state.

| Phase | Panel | Recording timer | Meaning |
|---|---|---|---|
| `idle` | optional | no | hidden, or a terminal status is still visible |
| `starting` | yes | no | engine bring-up before the first valid capture buffer |
| `recording` | yes | yes | capture is ready; the timer starts at the first valid buffer |
| `processing` | yes | no | STT/insertion owns the cycle; three-dot animation is shown |

Rules:

- `starting` is deferred by `starting_grace_seconds` (0.12 s). A start that
  reaches the first buffer inside the grace window goes directly to
  `recording` and never flashes `starting`.
- `recording` is entered only on the first valid microphone buffer. Starting
  the engine is not enough, and the timer must not run during `starting`.
- `processing` begins on manual/auto stop, before the terminal result.
- `reduce_motion` keeps every phase but removes pulsing and direct-envelope
  animation. The meter and peak follow the target level directly; the REC and
  processing indicators are static.

## Status keys

Status text is localized by the host. The fixture records keys, not translated
strings:

| Context | `status_key` | `status_argument_key` |
|---|---|---|
| Starting | `overlay.starting` | - |
| Recording | `overlay.recording` | - |
| Processing | `overlay.recognizing` | - |
| Insert/finish | `overlay.finishing` | - |
| Cancelled | `overlay.cancelled` | - |
| Empty result | `overlay.emptyResult` | - |
| Error | `overlay.error` | `error.noInternet`, `error.sttTimeout`, `error.micEnableFailed`, ... |

Terminal status stays visible for the terminal-hide delay, then the panel
hides and resets to `idle`.

## Timing

| Constant | Seconds |
|---|---|
| `meter_tick_seconds` | 0.05 (20 Hz) |
| `starting_grace_seconds` | 0.12 |
| `clock_tick_seconds` | 1.0 |
| `terminal_hide_seconds.insert` | 0.8 |
| `terminal_hide_seconds.cancelled` | 0.8 |
| `terminal_hide_seconds.empty_result` | 0.8 |
| `terminal_hide_seconds.error` | 2.0 |
| `terminal_hide_seconds.microphone_error` | 2.0 |

Every delayed hide is cycle-scoped. At the deadline the host re-checks both:

1. the scheduling cycle is still current (generation/cycle token), and
2. the engine state is Idle (`OverlayLifecycle.shouldHide`).

A stale hide is dropped when a newer cycle has started. One schedule produces
at most one hide. There is no hide while Recording or Transcribing.

The processing watchdog is at least `Transcriber.networkRequestTimeout + 5 s`.
Realtime/failover paths may extend it, never shorten it.

## Level math and VU ballistics

`rms_vectors` pins the reference mapping:

- `rms` is linear input amplitude, expected in `0...1`.
- `dbfs = 20 * log10(rms)`, or `-120` dBFS for zero/non-positive RMS.
- `meter = clamp((dbfs - dbfs_floor) / -dbfs_floor, 0, 1)`.
- `dbfs_floor = -50` dBFS, so `-6` dBFS maps to `0.88` (hot zone).
- Hot means `meter > 0.88`.
- Stroke width is `3 + meter * 6` points (`3...9`).
- The ring diameter is 68 points; the REC dot is 8 points.

VU ballistics use a 20 Hz tick:

- Attack: `meter += min(1, dt / 0.07) * (target - meter)` when rising.
- Release: `meter *= exp(-dt / 0.5)`, clamped not to fall below the target.
- Peak follower: hold the maximum for 0.8 s, then decay by `0.7` meter units
  per second.
- Reduce Motion bypasses ballistics: the displayed meter equals the target.

`vu_traces` contains three executable traces:

| Trace | Purpose |
|---|---|
| `attack_release` | rising attack, release, and peak hold/fall at 20 Hz |
| `peak_hold_then_fall` | peak dot survives brief spikes, then decays |
| `reduce_motion_passthrough` | meter equals target on every step |

## Terminal and exceptional paths

Scenarios are host-level. In particular, the HUD may show `idle` + a terminal
status while Rust is still `Transcribing` because an owner is settling an
in-flight result. Rust must not be asked to encode terminal HUD outcomes in
`DictationState`.

| Scenario | Contract |
|---|---|
| `quick_start_recording_insert_hide` | first buffer inside grace skips `starting`; insert status, then hide |
| `slow_start_then_record_and_cancel` | `starting` after grace; Escape cancels recording, short terminal hide |
| `quick_start_skips_starting_phase` | late `starting_deadline` never regresses `recording` |
| `cancel_during_recording` | Rust `Cancelled` ends Recording; HUD shows cancelled, then hides |
| `cancel_during_processing_owner_settles_rust` | HUD cancel is immediate; the Rust owner stays `Transcribing` until `owner_done` |
| `audio_error_after_slow_start` | microphone error stays in `starting`, shows the error, 2 s hide |
| `stt_error_no_internet` | no-internet error, short localized text, 2 s hide |
| `stt_timeout` | timeout error, 2 s hide |
| `empty_result` | empty-result terminal, short hide |
| `stale_hide_after_rapid_restart` | generation-1 hide is dropped after generation 2 starts |

Cancellation ownership follows the session contract in
[`architecture-rust-engine.md`](architecture-rust-engine.md#dictation-session-and-cancellation-contract-215):
Rust `Cancelled` is Recording-only; a Transcribing session is settled by its
native owner with `TranscriptionDone` after any in-flight insertion rolls back.
The HUD owns its own terminal outcome and generation check.

## Appearance and positioning

Appearance is descriptive for parity, not pixel-enforced through FFI:

- Two-line provider/model session label; the release version badge is
  `v`-prefixed in the header.
- REC dot only in Recording; three animated dots in Processing; both static
  under Reduce Motion.
- Accent arc `0...meter` with a 3...9 pt stroke and a peak dot at the peak
  angle.
- Timer is `m:ss` from the first valid buffer.
- Panel: continuous 10 pt corner radius, auto width clamped to 180...240 pt,
  height 178 pt in Recording and 150 pt otherwise.

Positioning is native presentation:

1. Anchor at the caret when valid.
2. Otherwise use the pointer when valid.
3. Otherwise use the screen center.

The panel is placed 12 pt above the anchor when it fits, otherwise below it,
clamped to the screen with an 8 pt margin. Windows should apply the same policy
inside its screen and DPI bounds. No window coordinates or pixels cross FFI.

## Fixture consumption

- macOS reference tests: `HUDContractFixture.swift`,
  `OverlayLevelTests.swift`, `OverlayLifecycleTests.swift`, and
  `OverlayControllerTests.swift` decode this fixture with `Codable`.
- Rust ABI tests: `rust/nanodictate-core/tests/hud_contract_tests.rs` reads the
  same file and validates `nd_rms_f32`, `nd_dbfs`, and the existing
  `nd_session_*` state/generation rules. No renderer or reducer is added.
- Windows (#212) should consume the same fixture for its own meter and
  presentation tests. It should not re-implement the Rust session contract.

When adding a scenario, include enough checkpoints to prove visibility, phase,
recording start, status key/argument, generation, and (where meaningful) the
Rust state. Change the fixture only together with its consumers.

## Verification

```sh
cargo test -p nanodictate-core --test hud_contract_tests
swift build
swift run NanoDictateCoreTests
```

The Swift/AppKit checks require macOS. The Rust fixture checks run on every
platform with a Rust toolchain.
