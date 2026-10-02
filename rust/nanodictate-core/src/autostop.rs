//! Silence auto-stop detector.
//!
//! Ports `AutoStopConfig` and `SilenceAutoStopDetector` from the Swift
//! layer. About three seconds of continuous silence mean "the user finished
//! speaking": recording stops and recognition runs the same path as a
//! manual stop. Silence uses hysteresis (separate speech/silence RMS
//! thresholds with a deliberate no-change band between them) plus a grace
//! period, a speech gate, and a minimum recording duration.

/// Auto-stop configuration. See [`SilenceAutoStopDetector`] for semantics.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AutoStopConfig {
    pub enabled: bool,
    pub speech_rms_threshold: f32,
    pub silence_rms_threshold: f32,
    pub required_silence_duration: f64,
    pub grace_period: f64,
    pub min_speech_run: f64,
    pub min_recording_duration: f64,
}

impl AutoStopConfig {
    pub const DEFAULT_SPEECH_RMS_THRESHOLD: f32 = 0.00562; // -45 dBFS
    pub const DEFAULT_SILENCE_RMS_THRESHOLD: f32 = 0.00126; // -58 dBFS
    pub const DEFAULT_GRACE_PERIOD: f64 = 2.0;
    pub const DEFAULT_MIN_SPEECH_RUN: f64 = 0.3;
    pub const DEFAULT_MIN_RECORDING_DURATION: f64 = 3.0;

    #[allow(clippy::too_many_arguments)]
    pub fn new(
        enabled: bool,
        speech_rms_threshold: f32,
        silence_rms_threshold: f32,
        required_silence_duration: f64,
        grace_period: f64,
        min_speech_run: f64,
        min_recording_duration: f64,
    ) -> Self {
        Self {
            enabled,
            // Hysteresis invariant: the speech threshold never goes below
            // the silence threshold.
            speech_rms_threshold: speech_rms_threshold.max(silence_rms_threshold),
            silence_rms_threshold,
            required_silence_duration,
            grace_period,
            min_speech_run,
            min_recording_duration,
        }
    }

    /// Parses environment-style overrides. All keys are optional; invalid
    /// values keep the default. Mirrors the Swift `fromEnvironment` keys:
    /// `NANODICTATE_AUTOSTOP_DISABLED`, `NANODICTATE_AUTOSTOP_DURATION`,
    /// `NANODICTATE_AUTOSTOP_RMS`, `NANODICTATE_AUTOSTOP_SPEECH_RMS`.
    pub fn from_env(get: &dyn Fn(&str) -> Option<String>) -> Self {
        let mut config = Self::default();
        if get("NANODICTATE_AUTOSTOP_DISABLED")
            .as_deref()
            .is_some_and(Self::is_disabled_flag)
        {
            config.enabled = false;
        }
        if let Some(raw) = get("NANODICTATE_AUTOSTOP_DURATION") {
            if let Ok(v) = raw.parse::<f64>() {
                if v.is_finite() && v > 0.0 {
                    config.required_silence_duration = v;
                }
            }
        }
        if let Some(raw) = get("NANODICTATE_AUTOSTOP_RMS") {
            if let Ok(v) = raw.parse::<f32>() {
                if v.is_finite() && v > 0.0 {
                    config.silence_rms_threshold = v;
                }
            }
        }
        if let Some(raw) = get("NANODICTATE_AUTOSTOP_SPEECH_RMS") {
            if let Ok(v) = raw.parse::<f32>() {
                if v.is_finite() && v > 0.0 {
                    config.speech_rms_threshold = v;
                }
            }
        }
        if config.speech_rms_threshold < config.silence_rms_threshold {
            config.speech_rms_threshold = config.silence_rms_threshold;
        }
        config
    }

    fn is_disabled_flag(raw: &str) -> bool {
        raw == "1" || raw == "true" || raw == "TRUE"
    }
}

impl Default for AutoStopConfig {
    fn default() -> Self {
        Self::new(
            true,
            Self::DEFAULT_SPEECH_RMS_THRESHOLD,
            Self::DEFAULT_SILENCE_RMS_THRESHOLD,
            3.0,
            Self::DEFAULT_GRACE_PERIOD,
            Self::DEFAULT_MIN_SPEECH_RUN,
            Self::DEFAULT_MIN_RECORDING_DURATION,
        )
    }
}

/// Pure auto-stop detector: accumulates continuous silence. No I/O.
#[derive(Debug, Clone, PartialEq)]
pub struct SilenceAutoStopDetector {
    pub speech_rms_threshold: f32,
    pub silence_rms_threshold: f32,
    pub required_silence_duration: f64,
    pub grace_period: f64,
    pub min_speech_run: f64,
    pub min_recording_duration: f64,
    pub silence_duration: f64,
    pub elapsed: f64,
    pub speech_run: f64,
    pub speech_gate_passed: bool,
}

impl SilenceAutoStopDetector {
    pub fn new(
        silence_rms_threshold: f32,
        speech_rms_threshold: f32,
        required_silence_duration: f64,
        grace_period: f64,
        min_speech_run: f64,
        min_recording_duration: f64,
    ) -> Self {
        Self {
            speech_rms_threshold: speech_rms_threshold.max(silence_rms_threshold),
            silence_rms_threshold,
            required_silence_duration,
            grace_period,
            min_speech_run,
            min_recording_duration,
            silence_duration: 0.0,
            elapsed: 0.0,
            speech_run: 0.0,
            speech_gate_passed: false,
        }
    }

    pub fn from_config(config: &AutoStopConfig) -> Self {
        Self::new(
            config.silence_rms_threshold,
            config.speech_rms_threshold,
            config.required_silence_duration,
            config.grace_period,
            config.min_speech_run,
            config.min_recording_duration,
        )
    }

    /// Feeds one buffer.
    ///
    /// `is_speech` carries the optional adaptive VAD decision on the raw
    /// signal: `Some(true)` counts as speech even below the RMS speech
    /// threshold, `Some(false)` counts as silence even above it, `None`
    /// falls back to the RMS thresholds. Returns true once all stop
    /// conditions hold (speech gate passed, recording floor reached,
    /// continuous silence reached), and keeps returning true on later
    /// quiet buffers until speech or [`Self::reset`].
    pub fn feed(&mut self, rms: f32, duration: f64, is_speech: Option<bool>) -> bool {
        let effective = duration.max(0.0);
        let starts_in_grace = self.elapsed < self.grace_period;
        self.elapsed += effective;

        if is_speech == Some(true) || (is_speech.is_none() && rms >= self.speech_rms_threshold) {
            self.speech_run += effective;
            if !self.speech_gate_passed && self.speech_run >= self.min_speech_run {
                self.speech_gate_passed = true;
            }
            self.silence_duration = 0.0;
        } else if is_speech == Some(false) || rms < self.silence_rms_threshold {
            self.speech_run = 0.0;
            if !starts_in_grace {
                self.silence_duration += effective;
            }
        }
        self.can_stop()
    }

    fn can_stop(&self) -> bool {
        self.speech_gate_passed
            && self.elapsed >= self.min_recording_duration
            && self.silence_duration >= self.required_silence_duration
    }

    pub fn reset(&mut self) {
        self.silence_duration = 0.0;
        self.elapsed = 0.0;
        self.speech_run = 0.0;
        self.speech_gate_passed = false;
    }
}

impl Default for SilenceAutoStopDetector {
    fn default() -> Self {
        Self::from_config(&AutoStopConfig::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn full_cycle_fires_after_three_seconds_of_silence() {
        let mut d = SilenceAutoStopDetector::default();
        // Speech opens the gate (0.3 s run).
        for _ in 0..5 {
            assert!(!d.feed(0.02, 0.1, None));
        }
        assert!(d.speech_gate_passed);
        // Inter-word gray-zone buffers neither accumulate nor reset.
        d.feed(0.003, 0.1, None);
        // Continuous silence accumulates to the 3 s threshold. Buffers that
        // start inside the 2 s grace period do not count, so the loop
        // covers grace plus the full silence window.
        let mut fired = false;
        for _ in 0..60 {
            fired = d.feed(0.0005, 0.1, None);
        }
        assert!(fired);
        // Stays true on later quiet buffers.
        assert!(d.feed(0.0005, 0.1, None));
        // Speech breaks it.
        assert!(!d.feed(0.02, 0.1, None));
    }

    #[test]
    fn grace_period_shields_setup_silence() {
        let mut d = SilenceAutoStopDetector::new(0.00126, 0.00562, 1.0, 2.0, 0.0, 0.0);
        // Gate opens instantly (min_speech_run = 0 requires one speech feed).
        d.feed(0.02, 0.1, None);
        assert!(d.speech_gate_passed);
        // Silence starting inside the 2 s grace does not accumulate.
        for _ in 0..19 {
            assert!(!d.feed(0.0005, 0.1, None));
        }
        assert_eq!(d.silence_duration, 0.0);
    }

    #[test]
    fn no_speech_no_stop() {
        let mut d = SilenceAutoStopDetector::default();
        for _ in 0..100 {
            assert!(!d.feed(0.0005, 0.1, None));
        }
    }

    #[test]
    fn vad_hint_overrides_thresholds() {
        let mut d = SilenceAutoStopDetector::default();
        // Loud steady noise with VAD silence still accumulates toward stop
        // once the gate was opened by real speech.
        for _ in 0..5 {
            d.feed(0.02, 0.1, Some(true));
        }
        assert!(d.speech_gate_passed);
        let mut fired = false;
        for _ in 0..60 {
            fired = d.feed(0.02, 0.1, Some(false));
        }
        assert!(fired);
    }

    #[test]
    fn env_parsing_vectors() {
        let empty = env(&[]);
        assert_eq!(
            AutoStopConfig::from_env(&|k| empty.get(k).cloned()),
            AutoStopConfig::default()
        );
        let off = env(&[("NANODICTATE_AUTOSTOP_DISABLED", "1")]);
        assert!(!AutoStopConfig::from_env(&|k| off.get(k).cloned()).enabled);
        let bad = env(&[
            ("NANODICTATE_AUTOSTOP_DURATION", "-5"),
            ("NANODICTATE_AUTOSTOP_RMS", "nope"),
        ]);
        let c = AutoStopConfig::from_env(&|k| bad.get(k).cloned());
        assert_eq!(c.required_silence_duration, 3.0);
        // Hysteresis invariant holds for any key combination.
        let inv = env(&[
            ("NANODICTATE_AUTOSTOP_RMS", "0.05"),
            ("NANODICTATE_AUTOSTOP_SPEECH_RMS", "0.01"),
        ]);
        let c = AutoStopConfig::from_env(&|k| inv.get(k).cloned());
        assert!(c.speech_rms_threshold >= c.silence_rms_threshold);
    }
}
