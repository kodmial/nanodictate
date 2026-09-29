//! Digital input gain (AGC) over Float32 audio buffers.
//!
//! Ports `InputGainConfig` and `InputGain` from the Swift layer. The AGC
//! lifts the current raw RMS toward a target speech level, capped by a
//! ceiling. Gating is adaptive: only raw signal above the noise floor
//! (+4 dB) and above an absolute -70 dBFS minimum is amplified, so steady
//! noise at the floor never climbs toward speech level. VAD/autostop
//! decisions always use the raw (pre-gain) RMS, never the amplified value.

use crate::audio_metrics::dbfs;
use crate::vad::{NoiseFloorTracker, SoftLimiter};

/// AGC configuration.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InputGainConfig {
    pub enabled: bool,
    pub target_rms_db: f32,
    pub max_gain_db: f32,
    pub attack_time: f64,
    pub release_time: f64,
}

impl InputGainConfig {
    pub fn new(
        enabled: bool,
        target_rms_db: f32,
        max_gain_db: f32,
        attack_time: f64,
        release_time: f64,
    ) -> Self {
        Self {
            enabled,
            target_rms_db: target_rms_db.clamp(-120.0, -1.0),
            max_gain_db: max_gain_db.clamp(1.0, 60.0),
            attack_time: attack_time.max(0.001),
            release_time: release_time.max(0.001),
        }
    }
}

impl Default for InputGainConfig {
    fn default() -> Self {
        Self::new(true, -20.0, 30.0, 0.025, 0.300)
    }
}

/// Input gain processor. Pure math over Float32 buffers; no audio hardware.
#[derive(Debug, Clone, PartialEq)]
pub struct InputGain {
    pub config: InputGainConfig,
    pub current_gain_db: f32,
    pub floor_tracker: NoiseFloorTracker,
}

impl InputGain {
    /// Absolute minimum raw level that may be amplified (-70 dBFS).
    pub const ABSOLUTE_MIN_DB: f32 = -70.0;
    /// Gate margin above the noise floor in dB.
    pub const GATE_MARGIN_DB: f32 = 4.0;
    /// Linear-factor refresh cadence inside the per-sample loop.
    pub const FACTOR_REFRESH_SAMPLES: usize = 64;

    pub fn new(config: InputGainConfig) -> Self {
        Self {
            config,
            current_gain_db: 0.0,
            floor_tracker: NoiseFloorTracker::default(),
        }
    }

    /// Resets gain and floor estimate (new recording session).
    pub fn reset(&mut self) {
        self.current_gain_db = 0.0;
        self.floor_tracker.reset(None);
    }

    pub fn noise_floor(&self) -> f32 {
        self.floor_tracker.floor
    }

    fn clean_rms(rms: f32) -> f32 {
        if rms.is_finite() {
            rms.clamp(0.0, 1.0)
        } else {
            0.0
        }
    }

    /// Whether the raw RMS passes the adaptive amplification gate.
    pub fn should_amplify(&self, rms: f32) -> bool {
        if !self.config.enabled {
            return false;
        }
        let clean = Self::clean_rms(rms);
        if dbfs(clean) <= Self::ABSOLUTE_MIN_DB {
            return false;
        }
        let gate = self.floor_tracker.floor * 10f32.powf(Self::GATE_MARGIN_DB / 20.0);
        clean > gate
    }

    /// Target gain for the current RMS in dB: shortfall to the target
    /// level, clamped to 0..=max_gain_db. Zero below the gate.
    pub fn target_gain_db(&self, rms: f32) -> f32 {
        if !self.config.enabled || !self.should_amplify(rms) {
            return 0.0;
        }
        (self.config.target_rms_db - dbfs(Self::clean_rms(rms))).clamp(0.0, self.config.max_gain_db)
    }

    /// Applies gain to a Float32 channel in place and returns the RMS of
    /// the amplified (post-limiter) buffer. Disabled AGC or an empty
    /// buffer returns `rms` unchanged.
    pub fn apply(&mut self, channel: &mut [f32], rms: f32, sample_rate: u32) -> f32 {
        if !self.config.enabled || channel.is_empty() {
            return rms;
        }
        let rate = sample_rate.max(1) as f64;
        let duration = channel.len() as f64 / rate;
        let gated = self.should_amplify(rms);
        let target = if gated { self.target_gain_db(rms) } else { 0.0 };
        self.floor_tracker.update(Self::clean_rms(rms), duration);
        if !gated {
            self.current_gain_db = 0.0;
            return rms;
        }
        let attack_alpha = 1.0 - (-1.0 / (self.config.attack_time * rate).max(1.0)).exp();
        let release_alpha = 1.0 - (-1.0 / (self.config.release_time * rate).max(1.0)).exp();

        let mut sum = 0.0f32;
        let mut factor = 10f32.powf(self.current_gain_db / 20.0);
        let mut since_update = Self::FACTOR_REFRESH_SAMPLES;
        for sample in channel.iter_mut() {
            let alpha = (if target > self.current_gain_db {
                attack_alpha
            } else {
                release_alpha
            }) as f32;
            self.current_gain_db += alpha * (target - self.current_gain_db);
            if since_update >= Self::FACTOR_REFRESH_SAMPLES {
                factor = 10f32.powf(self.current_gain_db / 20.0);
                since_update = 0;
            }
            since_update += 1;
            let limited = SoftLimiter::process(*sample * factor);
            *sample = limited;
            sum += limited * limited;
        }
        (sum / channel.len() as f32).sqrt()
    }
}

impl Default for InputGain {
    fn default() -> Self {
        Self::new(InputGainConfig::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_passes_through() {
        let mut g = InputGain::new(InputGainConfig::new(false, -20.0, 30.0, 0.025, 0.3));
        let mut buf = vec![0.1f32; 160];
        let rms = g.apply(&mut buf, 0.01, 16000);
        assert_eq!(rms, 0.01);
        assert!(buf.iter().all(|&s| s == 0.1));
    }

    #[test]
    fn digital_silence_never_amplified() {
        let g = InputGain::default();
        assert!(!g.should_amplify(0.0));
        assert_eq!(g.target_gain_db(0.0), 0.0);
    }

    #[test]
    fn quiet_speech_above_floor_gets_gain() {
        let mut g = InputGain::default();
        // Adapt the floor to quiet room tone first.
        for _ in 0..50 {
            g.floor_tracker.update(0.0005, 0.085);
        }
        // -46 dBFS speech sits above floor + 4 dB and above -70 dBFS.
        assert!(g.should_amplify(0.005));
        let target = g.target_gain_db(0.005);
        assert!(target > 20.0 && target <= 30.0, "target was {target}");
    }

    #[test]
    fn steady_noise_at_floor_not_amplified() {
        let mut g = InputGain::default();
        for _ in 0..200 {
            g.floor_tracker.update(0.004, 0.085);
        }
        assert!(!g.should_amplify(0.004));
    }

    #[test]
    fn apply_lifts_quiet_buffer_and_returns_amplified_rms() {
        let mut g = InputGain::default();
        for _ in 0..50 {
            g.floor_tracker.update(0.0005, 0.085);
        }
        let mut buf = vec![0.004f32; 1600];
        let out_rms = g.apply(&mut buf, 0.004, 16000);
        assert!(out_rms > 0.004, "AGC must lift quiet speech");
        assert!(buf.iter().all(|s| s.abs() <= 1.0), "limiter bounds output");
        assert!(g.current_gain_db > 0.0);
    }

    #[test]
    fn config_clamps_invariants() {
        let c = InputGainConfig::new(true, 5.0, 500.0, 0.0, -1.0);
        assert_eq!(c.target_rms_db, -1.0);
        assert_eq!(c.max_gain_db, 60.0);
        assert!(c.attack_time >= 0.001 && c.release_time >= 0.001);
    }
}
