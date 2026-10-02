//! Adaptive voice activity detection and the speech soft limiter.
//!
//! Ports `NoiseFloorTracker`, `AdaptiveVADConfig`, `AdaptiveVAD`, and
//! `SoftLimiter` from the Swift layer. Speech decisions run on the raw
//! (pre-gain) signal with an asymmetric noise-floor tracker plus
//! hysteresis. The per-buffer cost is a few floating-point operations and
//! no allocations, so the detector is safe to call from the native
//! realtime audio path (via block transfers, never per-sample FFI).

use crate::audio_metrics::dbfs;

/// Adaptive noise-floor tracker over raw RMS.
///
/// Asymmetric one-pole follower in the dB domain: fast down (quiet gaps
/// pull the floor down quickly), slow up (speech bursts barely move it).
/// Observations more than [`NoiseFloorTracker::MAX_UP_GAP_DB`] above the
/// floor adapt upward at a slowed rate instead of freezing, so sustained
/// loud noise still converges while short speech bursts do not drag the
/// floor up.
#[derive(Debug, Clone, PartialEq)]
pub struct NoiseFloorTracker {
    pub floor: f32,
    pub min_floor: f32,
    pub max_floor: f32,
    pub down_tau: f64,
    pub up_tau: f64,
}

impl NoiseFloorTracker {
    pub const MAX_UP_GAP_DB: f32 = 20.0;
    pub const FAR_ABOVE_SLOWDOWN: f64 = 5.0;

    pub fn new(
        initial_floor: f32,
        min_floor: f32,
        max_floor: f32,
        down_tau: f64,
        up_tau: f64,
    ) -> Self {
        Self {
            floor: initial_floor.clamp(min_floor, max_floor),
            min_floor,
            max_floor,
            down_tau: down_tau.max(0.01),
            up_tau: up_tau.max(0.1),
        }
    }

    /// Advances the floor estimate with one buffer RMS and its duration,
    /// returning the new floor. Deterministic, no I/O.
    pub fn update(&mut self, rms: f32, duration: f64) -> f32 {
        let dt = duration.max(0.0);
        if dt <= 0.0 || !rms.is_finite() {
            return self.floor;
        }
        let clean = rms.clamp(0.0, 1.0);
        let floor_db = dbfs(self.floor);
        let rms_db = dbfs(clean);
        let tau = if rms_db < floor_db {
            self.down_tau
        } else if rms_db > floor_db + Self::MAX_UP_GAP_DB {
            self.up_tau * Self::FAR_ABOVE_SLOWDOWN
        } else {
            self.up_tau
        };
        let alpha = 1.0 - (-dt / tau).exp();
        let new_db = floor_db + (alpha as f32) * (rms_db - floor_db);
        self.floor = (10f32.powf(new_db / 20.0)).clamp(self.min_floor, self.max_floor);
        self.floor
    }

    pub fn reset(&mut self, value: Option<f32>) {
        match value {
            Some(v) if v.is_finite() => self.floor = v.clamp(self.min_floor, self.max_floor),
            _ => self.floor = 0.001f32.clamp(self.min_floor, self.max_floor),
        }
    }
}

impl Default for NoiseFloorTracker {
    fn default() -> Self {
        Self::new(0.001, 0.0001, 0.02, 0.4, 3.0)
    }
}

/// Adaptive VAD configuration. Thresholds are relative to the noise
/// floor: enter = floor + enter_margin_db, exit = enter - hysteresis_db,
/// with absolute clamps for very quiet or very loud rooms.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AdaptiveVadConfig {
    pub enter_margin_db: f32,
    pub hysteresis_db: f32,
    pub min_enter_db: f32,
    pub max_enter_db: f32,
}

impl AdaptiveVadConfig {
    pub fn new(
        enter_margin_db: f32,
        hysteresis_db: f32,
        min_enter_db: f32,
        max_enter_db: f32,
    ) -> Self {
        let max_enter_db = max_enter_db.max(min_enter_db);
        Self {
            enter_margin_db,
            hysteresis_db: hysteresis_db.max(1.0),
            min_enter_db,
            max_enter_db,
        }
    }
}

impl Default for AdaptiveVadConfig {
    fn default() -> Self {
        Self::new(8.0, 4.0, -60.0, -25.0)
    }
}

/// Stateful adaptive voice activity detector fed with raw (pre-gain) RMS
/// per buffer. Hysteresis prevents threshold chatter.
#[derive(Debug, Clone, PartialEq)]
pub struct AdaptiveVad {
    pub config: AdaptiveVadConfig,
    pub tracker: NoiseFloorTracker,
    pub is_speech: bool,
}

impl AdaptiveVad {
    pub fn new(config: AdaptiveVadConfig, tracker: NoiseFloorTracker) -> Self {
        Self {
            config,
            tracker,
            is_speech: false,
        }
    }

    pub fn noise_floor(&self) -> f32 {
        self.tracker.floor
    }

    fn enter_db(&self) -> f32 {
        let raw = dbfs(self.tracker.floor) + self.config.enter_margin_db;
        raw.clamp(self.config.min_enter_db, self.config.max_enter_db)
    }

    fn threshold_linear(db: f32) -> f32 {
        (10f32.powf(db / 20.0)).clamp(0.00001, 1.0)
    }

    pub fn enter_threshold(&self) -> f32 {
        Self::threshold_linear(self.enter_db())
    }

    pub fn exit_threshold(&self) -> f32 {
        Self::threshold_linear(self.enter_db() - self.config.hysteresis_db)
    }

    /// Feeds one buffer. The decision uses the prior floor, then the floor
    /// adapts to the observation. Returns the new speech state.
    pub fn update(&mut self, rms: f32, duration: f64) -> bool {
        let clean = if rms.is_finite() {
            rms.clamp(0.0, 1.0)
        } else {
            0.0
        };
        let enter = self.enter_threshold();
        let exit = self.exit_threshold();
        // Relative tolerance for the enter comparison: a level sitting
        // exactly on the threshold must read as speech despite float
        // rounding of 10^(db/20).
        let enter_with_tolerance = enter * 0.999;
        if self.is_speech {
            if clean < exit {
                self.is_speech = false;
            }
        } else if clean >= enter_with_tolerance {
            self.is_speech = true;
        }
        self.tracker.update(clean, duration);
        self.is_speech
    }

    pub fn reset(&mut self) {
        self.is_speech = false;
        self.tracker.reset(None);
    }
}

impl Default for AdaptiveVad {
    fn default() -> Self {
        Self::new(AdaptiveVadConfig::default(), NoiseFloorTracker::default())
    }
}

/// Bounded soft knee above 0.8 for speech: linear below, exponential
/// compression toward 1.0 above. Loud transients compress instead of
/// flattening into hard-clipped plateaus.
pub struct SoftLimiter;

impl SoftLimiter {
    pub const KNEE: f32 = 0.8;

    pub fn process(x: f32) -> f32 {
        let ax = x.abs();
        if ax <= Self::KNEE {
            return x;
        }
        let sign = if x >= 0.0 { 1.0 } else { -1.0 };
        let excess = (ax - Self::KNEE) / (1.0 - Self::KNEE);
        let compressed = 1.0 - (-excess).exp();
        sign * (Self::KNEE + (1.0 - Self::KNEE) * compressed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: f64 = 0.085;

    #[test]
    fn quiet_stays_silence_and_speech_attack_detected() {
        let mut vad = AdaptiveVad::default();
        for _ in 0..30 {
            assert!(!vad.update(0.0005, FRAME));
        }
        // Leading silence keeps the floor low so the first word attack is caught.
        assert!(vad.update(0.02, FRAME), "first word attack detected");
        // Hysteresis: a mid-level buffer after speech stays speech.
        assert!(vad.update(vad.exit_threshold(), FRAME));
        // Deep quiet collapses back to silence without latching.
        for _ in 0..5 {
            vad.update(0.0002, FRAME);
        }
        assert!(!vad.is_speech);
    }

    #[test]
    fn steady_noise_converges_to_silence() {
        let mut vad = AdaptiveVad::default();
        // Moderate steady noise reads as speech at first...
        assert!(vad.update(0.01, FRAME));
        // ...but the floor rises to meet it and it stops crossing enter.
        for _ in 0..400 {
            vad.update(0.01, FRAME);
        }
        assert!(!vad.is_speech, "converged noise must read as silence");
    }

    #[test]
    fn tracker_asymmetry_fast_down_slow_up() {
        let mut t = NoiseFloorTracker::default();
        t.update(0.02, 1.0);
        let after_speech = t.floor;
        t.update(0.0002, 1.0);
        let after_quiet = t.floor;
        assert!(after_quiet < after_speech, "down adaptation must be fast");
        assert!(
            after_speech - 0.001 < 0.01,
            "short speech must barely move floor"
        );
    }

    #[test]
    fn non_finite_and_zero_duration_are_noops() {
        let mut t = NoiseFloorTracker::default();
        let before = t.floor;
        t.update(f32::NAN, 0.1);
        t.update(0.5, 0.0);
        t.update(0.5, -1.0);
        assert_eq!(t.floor, before);
    }

    #[test]
    fn soft_limiter_vectors() {
        assert_eq!(SoftLimiter::process(0.5), 0.5);
        assert_eq!(SoftLimiter::process(-0.5), -0.5);
        assert_eq!(SoftLimiter::process(0.8), 0.8);
        let hot = SoftLimiter::process(2.0);
        assert!(hot > 0.8 && hot < 1.0, "compresses toward 1.0, got {hot}");
        assert!(SoftLimiter::process(-2.0) < -0.8);
        // Symmetry.
        assert!((SoftLimiter::process(1.5) + SoftLimiter::process(-1.5)).abs() < 1e-6);
    }
}
