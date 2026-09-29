//! Dictation session state machine and small portable decision policies.
//!
//! Ports the deterministic cores of several Swift units:
//!
//! - the capture-readiness latch from `AudioService` (the recording-ready
//!   cue must only follow the first valid microphone buffer of the current
//!   engine generation; stale generations never fire readiness);
//! - the dictation cycle states from `OverlayLifecycle` (`idle`,
//!   `recording`, `transcribing`);
//! - `MicErrorCooldown`, `EnterSendLatch`, `RetryInsertionGate`,
//!   `ReviewGate::confirm` decision, and the `MicRequestPolicy` window
//!   counting (timestamp math only; file persistence stays native).
//!
//! The native layer still owns the actual audio callbacks, permission
//! prompts, event taps, and overlay rendering. It drives this state
//! machine ("start requested", "first buffer arrived", "stop requested")
//! and asks it what the user may observe ("is capture ready", "may the
//! ready cue be emitted").

/// Dictation cycle states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DictationState {
    Idle,
    Recording,
    Transcribing,
}

/// Session events understood by [`DictationSession`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionEvent {
    /// Native layer started the engine for `generation`.
    EngineStarted,
    /// First valid microphone buffer arrived for `generation`.
    FirstBuffer,
    /// Engine start failed for `generation`.
    EngineFailed,
    /// User cancelled before capture became ready.
    Cancelled,
    /// Recording stopped (manual or auto-stop); transcription begins.
    StopRequested,
    /// Transcription finished (success or terminal failure).
    TranscriptionDone,
}

/// A generation-tagged dictation session.
///
/// The recording-ready cue invariant (P0 first-word clipping): success of
/// `start` alone never reports capture readiness. Readiness fires exactly
/// once per successful session, on the first valid buffer of the current
/// generation, and lapses when the session ends. Stale generations (a
/// wedged engine replaced by a new start) can never fire readiness or
/// corrupt the new session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DictationSession {
    state: DictationState,
    /// Current engine generation (bumped on every start).
    generation: u64,
    /// Generation that fired readiness, if any.
    ready_generation: Option<u64>,
    /// Live readiness flag (cleared on stop/cancel/failure).
    capture_ready_live: bool,
    /// Whether the ready cue was already emitted for this session.
    cue_emitted: bool,
}

impl DictationSession {
    pub fn new() -> Self {
        Self {
            state: DictationState::Idle,
            generation: 0,
            ready_generation: None,
            capture_ready_live: false,
            cue_emitted: false,
        }
    }

    pub fn state(&self) -> DictationState {
        self.state
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Live readiness behind the native `isCaptureReady` flag.
    pub fn is_capture_ready(&self) -> bool {
        self.capture_ready_live
    }

    /// Starts a new session: bumps the generation and clears readiness.
    /// Prewarm alone (no start) never touches readiness.
    pub fn start(&mut self) -> u64 {
        self.generation = self.generation.wrapping_add(1);
        self.ready_generation = None;
        self.capture_ready_live = false;
        self.cue_emitted = false;
        self.state = DictationState::Recording;
        self.generation
    }

    /// Drives the session. `generation` tags the event source so stale
    /// engines are rejected.
    pub fn on_event(&mut self, event: SessionEvent, generation: u64) {
        // Stale generations never mutate the new session.
        if generation != self.generation {
            return;
        }
        match event {
            SessionEvent::EngineStarted => {
                // Engine start alone reports nothing.
            }
            SessionEvent::FirstBuffer => {
                if self.ready_generation.is_none() {
                    self.ready_generation = Some(generation);
                    self.capture_ready_live = true;
                }
            }
            SessionEvent::EngineFailed | SessionEvent::Cancelled => {
                self.ready_generation = None;
                self.capture_ready_live = false;
                self.state = DictationState::Idle;
            }
            SessionEvent::StopRequested => {
                self.capture_ready_live = false;
                self.state = DictationState::Transcribing;
            }
            SessionEvent::TranscriptionDone => {
                self.capture_ready_live = false;
                self.state = DictationState::Idle;
            }
        }
    }

    /// Whether the recording-ready cue may be emitted now: capture
    /// readiness was observed for this session and the cue has not fired
    /// yet. Emits at most once; records the emission.
    pub fn should_emit_ready_cue(&mut self) -> bool {
        if self.ready_generation == Some(self.generation)
            && !self.cue_emitted
            && self.state == DictationState::Recording
        {
            self.cue_emitted = true;
            return true;
        }
        false
    }
}

impl Default for DictationSession {
    fn default() -> Self {
        Self::new()
    }
}

/// Cooldown for terminal microphone errors: repeated activation must not
/// replay the error indication more often than once per `interval`.
#[derive(Debug, Clone, PartialEq)]
pub struct MicErrorCooldown {
    pub interval: f64,
    last_fired_at: f64,
}

impl MicErrorCooldown {
    pub fn new(interval: f64) -> Self {
        Self {
            interval,
            last_fired_at: f64::NEG_INFINITY,
        }
    }

    /// True when at least `interval` elapsed since the last show; records
    /// `now`. False suppresses without touching state.
    pub fn allow(&mut self, now: f64) -> bool {
        if now - self.last_fired_at >= self.interval {
            self.last_fired_at = now;
            true
        } else {
            false
        }
    }
}

/// One-shot latch: post exactly one synthetic Enter after insert.
/// `arm` is idempotent; `consume` fires once; `cancel` disarms.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EnterSendLatch {
    armed: bool,
}

impl EnterSendLatch {
    pub fn new() -> Self {
        Self { armed: false }
    }

    pub fn arm(&mut self) {
        self.armed = true;
    }

    pub fn consume(&mut self) -> bool {
        if self.armed {
            self.armed = false;
            true
        } else {
            false
        }
    }

    pub fn cancel(&mut self) {
        self.armed = false;
    }

    pub fn is_pending(&self) -> bool {
        self.armed
    }
}

/// Review-before-insert decision for one input line: empty/`y`/`Y`
/// inserts, anything else (including end of input) cancels. Mirrors
/// `ReviewGate::confirm` without touching the terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReviewDecision {
    Insert,
    Cancel,
}

pub fn review_decide(line: Option<&str>) -> ReviewDecision {
    match line {
        Some(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() || trimmed == "y" || trimmed == "Y" {
                ReviewDecision::Insert
            } else {
                ReviewDecision::Cancel
            }
        }
        None => ReviewDecision::Cancel,
    }
}

/// Retry-insertion drop guard: a retry result is dropped when a newer
/// cycle owns the session or the agent is not idle.
pub fn should_drop_retry(state: DictationState, processing_session: u64, session: u64) -> bool {
    state != DictationState::Idle || processing_session != session
}

/// Pure overlay hide rule: the overlay lives through the whole cycle and
/// hides only at terminal points (idle).
pub fn overlay_should_hide(state: DictationState) -> bool {
    state == DictationState::Idle
}

/// Anti-storm window counting for microphone permission requests: at most
/// `max_timeouts` timeouts inside the trailing `window_secs` window allow
/// a new request. Pure timestamp math over epoch seconds; persistence
/// stays native. Mirrors `MicRequestPolicy`.
pub fn mic_request_allowed(
    timeout_timestamps: &[f64],
    now: f64,
    max_timeouts: usize,
    window_secs: f64,
) -> bool {
    timeout_timestamps
        .iter()
        .filter(|&&t| {
            let age = now - t;
            age >= 0.0 && age < window_secs
        })
        .count()
        < max_timeouts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_alone_never_reports_readiness() {
        let mut s = DictationSession::new();
        let gen = s.start();
        s.on_event(SessionEvent::EngineStarted, gen);
        assert!(!s.is_capture_ready());
        assert!(!s.should_emit_ready_cue());
    }

    #[test]
    fn first_buffer_fires_readiness_exactly_once() {
        let mut s = DictationSession::new();
        let gen = s.start();
        s.on_event(SessionEvent::FirstBuffer, gen);
        assert!(s.is_capture_ready());
        assert!(s.should_emit_ready_cue());
        // Second buffer and second cue query do not re-fire.
        s.on_event(SessionEvent::FirstBuffer, gen);
        assert!(!s.should_emit_ready_cue());
        assert!(s.is_capture_ready());
    }

    #[test]
    fn repeated_cycles_reach_readiness_independently() {
        let mut s = DictationSession::new();
        let g1 = s.start();
        s.on_event(SessionEvent::FirstBuffer, g1);
        assert!(s.should_emit_ready_cue());
        s.on_event(SessionEvent::StopRequested, g1);
        s.on_event(SessionEvent::TranscriptionDone, g1);
        assert!(!s.is_capture_ready());
        let g2 = s.start();
        assert_ne!(g1, g2);
        assert!(!s.is_capture_ready());
        s.on_event(SessionEvent::FirstBuffer, g2);
        assert!(s.should_emit_ready_cue());
    }

    #[test]
    fn cancel_before_buffer_suppresses_readiness() {
        let mut s = DictationSession::new();
        let gen = s.start();
        s.on_event(SessionEvent::Cancelled, gen);
        assert!(!s.is_capture_ready());
        assert!(!s.should_emit_ready_cue());
        assert_eq!(s.state(), DictationState::Idle);
    }

    #[test]
    fn failure_never_cues_but_retry_recovers() {
        let mut s = DictationSession::new();
        let g1 = s.start();
        s.on_event(SessionEvent::EngineFailed, g1);
        assert!(!s.should_emit_ready_cue());
        let g2 = s.start();
        s.on_event(SessionEvent::FirstBuffer, g2);
        assert!(s.should_emit_ready_cue());
    }

    #[test]
    fn stale_generation_cannot_corrupt_new_session() {
        let mut s = DictationSession::new();
        let g1 = s.start();
        let g2 = s.start(); // wedged engine replaced
                            // Late buffer from the stale engine is rejected.
        s.on_event(SessionEvent::FirstBuffer, g1);
        assert!(!s.is_capture_ready());
        assert!(!s.should_emit_ready_cue());
        // Current generation still works.
        s.on_event(SessionEvent::FirstBuffer, g2);
        assert!(s.should_emit_ready_cue());
    }

    #[test]
    fn stop_lapses_readiness() {
        let mut s = DictationSession::new();
        let gen = s.start();
        s.on_event(SessionEvent::FirstBuffer, gen);
        s.on_event(SessionEvent::StopRequested, gen);
        assert_eq!(s.state(), DictationState::Transcribing);
        assert!(!s.is_capture_ready());
        assert!(!s.should_emit_ready_cue());
    }

    #[test]
    fn cooldown_vectors() {
        let mut c = MicErrorCooldown::new(5.0);
        assert!(c.allow(0.0));
        assert!(!c.allow(4.9));
        assert!(c.allow(5.0));
        assert!(!c.allow(5.0 - 0.001 + 5.0 - 5.0 + 4.999));
    }

    #[test]
    fn enter_latch_vectors() {
        let mut l = EnterSendLatch::new();
        assert!(!l.is_pending());
        assert!(!l.consume());
        l.arm();
        l.arm();
        assert!(l.is_pending());
        assert!(l.consume());
        assert!(!l.consume());
        l.arm();
        l.cancel();
        assert!(!l.consume());
    }

    #[test]
    fn review_decision_vectors() {
        assert_eq!(review_decide(Some("")), ReviewDecision::Insert);
        assert_eq!(review_decide(Some("  ")), ReviewDecision::Insert);
        assert_eq!(review_decide(Some("y")), ReviewDecision::Insert);
        assert_eq!(review_decide(Some("Y")), ReviewDecision::Insert);
        assert_eq!(review_decide(Some("n")), ReviewDecision::Cancel);
        assert_eq!(review_decide(Some("nope")), ReviewDecision::Cancel);
        assert_eq!(review_decide(None), ReviewDecision::Cancel);
    }

    #[test]
    fn retry_gate_and_overlay_vectors() {
        assert!(should_drop_retry(DictationState::Recording, 1, 1));
        assert!(should_drop_retry(DictationState::Idle, 1, 2));
        assert!(!should_drop_retry(DictationState::Idle, 2, 2));
        assert!(overlay_should_hide(DictationState::Idle));
        assert!(!overlay_should_hide(DictationState::Recording));
        assert!(!overlay_should_hide(DictationState::Transcribing));
    }

    #[test]
    fn mic_request_storm_guard_vectors() {
        let window = 6.0 * 3600.0;
        assert!(mic_request_allowed(&[], 1000.0, 3, window));
        assert!(mic_request_allowed(&[900.0, 950.0], 1000.0, 3, window));
        assert!(!mic_request_allowed(
            &[900.0, 950.0, 990.0],
            1000.0,
            3,
            window
        ));
        // Stale timeouts outside the window do not count.
        assert!(mic_request_allowed(&[1.0, 2.0, 3.0], 100000.0, 3, window));
        // Future timestamps (clock moved backward) do not block.
        assert!(mic_request_allowed(&[2000.0], 1000.0, 3, window));
    }
}
