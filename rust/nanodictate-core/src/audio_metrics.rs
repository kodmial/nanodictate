//! Recording-level math over RMS values and Int16 samples.
//!
//! Ports `AudioMetrics` from the Swift layer. Pure functions only, no I/O.
//! The microphone-permission label helper (`MicrophoneAuth`) stays native:
//! it depends on AVFoundation types.

/// Near-silence VAD threshold (0.00316, approximately -50 dBFS).
/// Values below this are microphone noise, not speech.
pub const NEAR_SILENCE_THRESHOLD: f32 = 0.00316;

/// Linear amplitude (0..1) to dBFS. Full scale maps to 0 dB, zero maps to a
/// -120 dBFS floor.
pub fn dbfs(linear: f32) -> f32 {
    if linear > 0.0 {
        20.0 * linear.log10()
    } else {
        -120.0
    }
}

/// Summary of an RMS history window plus a near-silence flag.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecordingMetrics {
    pub min_rms: f32,
    pub avg_rms: f32,
    pub max_rms: f32,
    pub near_silence: bool,
}

/// Summarizes RMS history. An empty history yields zeros with
/// `near_silence == false` (there is nothing to judge).
pub fn summarize_rms(values: &[f32], threshold: f32) -> RecordingMetrics {
    if values.is_empty() {
        return RecordingMetrics {
            min_rms: 0.0,
            avg_rms: 0.0,
            max_rms: 0.0,
            near_silence: false,
        };
    }
    let mut min = values[0];
    let mut max = values[0];
    let mut sum = 0.0f32;
    for &v in values {
        if v < min {
            min = v;
        }
        if v > max {
            max = v;
        }
        sum += v;
    }
    let avg = sum / values.len() as f32;
    RecordingMetrics {
        min_rms: min,
        avg_rms: avg,
        max_rms: max,
        near_silence: avg < threshold,
    }
}

/// RMS over Int16 samples (0..1, full scale 32767). Empty input yields 0.
/// Operates on the same array that is encoded to WAV and sent to STT.
pub fn rms_i16(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let mut sum = 0.0f32;
    for &s in samples {
        let v = s as f32 / 32767.0;
        sum += v * v;
    }
    (sum / samples.len() as f32).sqrt()
}

/// Near-silence predicate: average RMS strictly below the threshold.
/// The boundary value itself counts as sound, not silence.
pub fn is_near_silence(avg_rms: f32, threshold: f32) -> bool {
    avg_rms < threshold
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dbfs_reference_points() {
        assert!((dbfs(1.0) - 0.0).abs() < 1e-5);
        assert!((dbfs(0.1) - (-20.0)).abs() < 1e-4);
        assert_eq!(dbfs(0.0), -120.0);
        assert_eq!(dbfs(-0.5), -120.0);
    }

    #[test]
    fn summarize_matches_swift_vectors() {
        let m = summarize_rms(&[0.01, 0.02, 0.03], NEAR_SILENCE_THRESHOLD);
        assert!((m.min_rms - 0.01).abs() < 1e-6);
        assert!((m.avg_rms - 0.02).abs() < 1e-6);
        assert!((m.max_rms - 0.03).abs() < 1e-6);
        assert!(!m.near_silence);
        let quiet = summarize_rms(&[0.001, 0.001], NEAR_SILENCE_THRESHOLD);
        assert!(quiet.near_silence);
        let empty = summarize_rms(&[], NEAR_SILENCE_THRESHOLD);
        assert_eq!(
            empty,
            RecordingMetrics {
                min_rms: 0.0,
                avg_rms: 0.0,
                max_rms: 0.0,
                near_silence: false,
            }
        );
    }

    #[test]
    fn rms_i16_vectors() {
        assert_eq!(rms_i16(&[]), 0.0);
        assert!((rms_i16(&[32767, 32767]) - 1.0).abs() < 1e-4);
        assert!((rms_i16(&[0, 0, 0]) - 0.0).abs() < 1e-9);
    }

    #[test]
    fn boundary_is_sound() {
        assert!(!is_near_silence(
            NEAR_SILENCE_THRESHOLD,
            NEAR_SILENCE_THRESHOLD
        ));
        assert!(is_near_silence(
            NEAR_SILENCE_THRESHOLD - 0.00001,
            NEAR_SILENCE_THRESHOLD
        ));
    }
}
