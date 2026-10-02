//! Live VAD segmentation and batch chunk planning.
//!
//! Ports the deterministic core of `AudioSegmenter` and the fixed-length
//! planning math of `BatchSegmenter` from the Swift layer. File-backed
//! sample windows (`PCMBatchContent`) stay native; the engine exposes the
//! boundary math over sample ranges so every platform shares identical
//! chunk bodies and overlap windows.

use crate::audio_metrics::{dbfs, rms_i16, NEAR_SILENCE_THRESHOLD};
use crate::vad::AdaptiveVadConfig;

/// Live segmentation configuration.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SegmenterConfig {
    pub pause_duration: f64,
    pub min_segment: f64,
    pub max_segment: f64,
    pub overlap: f64,
    pub silence_rms: f32,
    pub use_adaptive_vad: bool,
    pub vad_config: AdaptiveVadConfig,
}

impl SegmenterConfig {
    pub fn new(
        pause_duration: f64,
        min_segment: f64,
        max_segment: f64,
        overlap: f64,
        silence_rms: f32,
        use_adaptive_vad: bool,
        vad_config: AdaptiveVadConfig,
    ) -> Self {
        Self {
            pause_duration,
            min_segment,
            max_segment,
            overlap,
            silence_rms,
            use_adaptive_vad,
            vad_config,
        }
    }
}

impl Default for SegmenterConfig {
    fn default() -> Self {
        Self::new(
            1.0,
            3.0,
            45.0,
            1.0,
            NEAR_SILENCE_THRESHOLD,
            true,
            AdaptiveVadConfig::default(),
        )
    }
}

/// Sample-work window duration in seconds (85 ms, like the tap RMS buffers).
pub const DEFAULT_WINDOW_DURATION: f64 = 0.085;

/// Adaptive enter/exit thresholds from an RMS timeline, or the legacy
/// fixed pair when adaptive VAD is off.
pub fn thresholds(rms: &[f32], config: &SegmenterConfig) -> (f32, f32) {
    if !config.use_adaptive_vad {
        return (config.silence_rms, config.silence_rms);
    }
    let mut sorted = rms.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let idx = ((sorted.len() as f64) * 0.2) as usize;
    let low = if sorted.is_empty() {
        config.silence_rms
    } else {
        sorted[idx.min(sorted.len() - 1)]
    };
    let floor = low.clamp(0.0001, 0.01);
    let floor_db = dbfs(floor);
    let mut enter_db = floor_db + config.vad_config.enter_margin_db;
    enter_db = enter_db.clamp(
        config.vad_config.min_enter_db,
        config.vad_config.max_enter_db,
    );
    let exit_db = enter_db - config.vad_config.hysteresis_db;
    let enter = (10f32.powf(enter_db / 20.0)).clamp(0.00001, 1.0);
    let exit = (10f32.powf(exit_db / 20.0)).clamp(0.00001, 1.0);
    (enter, exit)
}

/// Splits an RMS timeline (one value per window) into segment window
/// ranges. Guarantees: boundaries only after a sustained pause, segments
/// shorter than `min_segment` are glued on, `max_segment` forces a cut,
/// junction silence belongs to no segment.
pub fn split_ranges(
    rms: &[f32],
    window_duration: f64,
    config: &SegmenterConfig,
) -> Vec<std::ops::Range<usize>> {
    if rms.is_empty() || !(window_duration.is_finite() && window_duration > 0.0) {
        return Vec::new();
    }
    let pause_windows = ((config.pause_duration / window_duration).round() as usize).max(1);
    let (enter, exit) = thresholds(rms, config);

    let mut segments: Vec<std::ops::Range<usize>> = Vec::new();
    let mut seg_start = 0usize;
    let mut silence_start: Option<usize> = None;
    let mut in_speech = false;
    let mut has_speech = false;

    let is_speech = |value: f32, state: &mut bool| -> bool {
        if *state {
            if value < exit {
                *state = false;
            }
        } else if value >= enter {
            *state = true;
        }
        *state
    };

    for (i, &value) in rms.iter().enumerate() {
        let speech = is_speech(value, &mut in_speech);
        if speech {
            has_speech = true;
        }
        let segment_duration = (i - seg_start + 1) as f64 * window_duration;
        if segment_duration >= config.max_segment {
            if has_speech {
                segments.push(seg_start..i + 1);
            }
            seg_start = i + 1;
            silence_start = None;
            has_speech = false;
            continue;
        }
        if !speech {
            if silence_start.is_none() {
                silence_start = Some(i);
            }
            continue;
        }
        if let Some(pause_start) = silence_start {
            silence_start = None;
            if i - pause_start < pause_windows {
                continue;
            }
            if pause_start == 0 || pause_start - 1 < seg_start {
                continue;
            }
            let boundary = pause_start - 1;
            let duration = (boundary - seg_start + 1) as f64 * window_duration;
            if duration < config.min_segment {
                continue;
            }
            segments.push(seg_start..boundary + 1);
            seg_start = i;
            has_speech = true;
        }
    }

    if seg_start < rms.len() && has_speech {
        let trail = seg_start..rms.len();
        let trail_seconds = trail.len() as f64 * window_duration;
        if trail_seconds < config.min_segment {
            if let Some(last) = segments.last().cloned() {
                if (rms.len() - last.start) as f64 * window_duration <= config.max_segment {
                    let idx = segments.len() - 1;
                    segments[idx] = last.start..rms.len();
                } else {
                    segments.push(trail);
                }
            } else {
                segments.push(trail);
            }
        } else {
            segments.push(trail);
        }
    }
    segments
}

/// One live segment: body boundaries plus overlap bookkeeping.
#[derive(Debug, Clone, PartialEq)]
pub struct LiveSegmentSpec {
    pub start_seconds: f64,
    pub end_seconds: f64,
    /// Sample range of the body (no overlap) at `sample_rate`.
    pub body_range: std::ops::Range<usize>,
    /// Sample range of the glued overlap tail of the previous body.
    pub overlap_range: Option<std::ops::Range<usize>>,
}

/// Splits Int16 PCM samples into live segments with overlap. Samples are
/// treated as continuous from the recording start.
pub fn live_segments(
    samples: &[i16],
    sample_rate: u32,
    config: &SegmenterConfig,
) -> Vec<LiveSegmentSpec> {
    let rate = sample_rate.max(1) as f64;
    let window_size = ((DEFAULT_WINDOW_DURATION * rate).round() as usize).max(1);
    let mut timeline = Vec::new();
    let mut cursor = 0usize;
    while cursor < samples.len() {
        let end = (cursor + window_size).min(samples.len());
        timeline.push(rms_i16(&samples[cursor..end]));
        cursor = end;
    }
    let ranges = split_ranges(&timeline, DEFAULT_WINDOW_DURATION, config);
    if ranges.is_empty() {
        return Vec::new();
    }
    let overlap_count = ((config.overlap * rate).round() as usize).min(samples.len());
    let mut out = Vec::with_capacity(ranges.len());
    for (index, range) in ranges.iter().enumerate() {
        let body_start = range.start * window_size;
        let body_end = (range.end * window_size).min(samples.len());
        let overlap_range = if index > 0 {
            let prev_end = (ranges[index - 1].end * window_size).min(samples.len());
            Some(prev_end.saturating_sub(overlap_count)..prev_end)
        } else {
            None
        };
        out.push(LiveSegmentSpec {
            start_seconds: body_start as f64 / rate,
            end_seconds: body_end as f64 / rate,
            body_range: body_start..body_end,
            overlap_range,
        });
    }
    out
}

/// One batch chunk spec: body boundaries plus read windows. Samples are
/// materialized on demand by the native layer through these ranges.
#[derive(Debug, Clone, PartialEq)]
pub struct BatchChunkSpec {
    pub index: usize,
    pub body_start_seconds: f64,
    pub body_end_seconds: f64,
    pub body_range: std::ops::Range<usize>,
    pub overlap_range: Option<std::ops::Range<usize>>,
}

/// Fixed-length batch planning math: chunk bodies cover the file back to
/// back with no gaps and no overlaps; every chunk but the first starts
/// with the tail of the previous body as context overlap.
pub fn batch_plan(
    sample_count: usize,
    sample_rate: u32,
    max_segment: f64,
    overlap: f64,
) -> Vec<BatchChunkSpec> {
    if sample_count == 0 || !(max_segment.is_finite() && max_segment > 0.0) {
        return Vec::new();
    }
    let rate = sample_rate.max(1) as f64;
    let body_size = ((max_segment * rate).round() as usize).max(1);
    let overlap_count = ((overlap * rate).round() as usize).min(sample_count);

    let mut out = Vec::new();
    let mut body_start = 0usize;
    let mut prev_end: Option<usize> = None;
    let mut index = 0usize;
    while body_start < sample_count {
        let body_end = (body_start + body_size).min(sample_count);
        let overlap_range = prev_end.map(|end| end.saturating_sub(overlap_count)..end);
        out.push(BatchChunkSpec {
            index,
            body_start_seconds: body_start as f64 / rate,
            body_end_seconds: body_end as f64 / rate,
            body_range: body_start..body_end,
            overlap_range,
        });
        index += 1;
        prev_end = Some(body_end);
        body_start = body_end;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn speech_silence_timeline() -> Vec<f32> {
        // 40 speech windows, 20 silence windows, 40 speech windows.
        let mut v = vec![0.05f32; 40];
        v.extend(vec![0.0002f32; 20]);
        v.extend(vec![0.05f32; 40]);
        v
    }

    #[test]
    fn splits_on_sustained_pause() {
        let rms = speech_silence_timeline();
        let config = SegmenterConfig::new(
            1.0,
            1.0,
            45.0,
            1.0,
            0.00316,
            false,
            AdaptiveVadConfig::default(),
        );
        let ranges = split_ranges(&rms, 0.085, &config);
        // Pause is 20 windows * 0.085 = 1.7 s >= 1.0 s; first body 3.4 s >= min 1 s.
        assert_eq!(ranges.len(), 2);
        assert_eq!(ranges[0].start, 0);
        // Junction silence belongs to neither segment.
        assert!(ranges[0].end <= 40);
        assert!(ranges[1].start >= 60);
        assert_eq!(ranges[1].end, 100);
    }

    #[test]
    fn short_pause_does_not_split() {
        let mut rms = vec![0.05f32; 40];
        rms.extend(vec![0.0002f32; 5]); // 0.425 s < 1.0 s pause
        rms.extend(vec![0.05f32; 40]);
        let config = SegmenterConfig::default();
        let ranges = split_ranges(&rms, 0.085, &config);
        assert_eq!(ranges.len(), 1);
    }

    #[test]
    fn voiceless_timeline_emits_nothing() {
        let rms = vec![0.0002f32; 100];
        assert!(split_ranges(&rms, 0.085, &SegmenterConfig::default()).is_empty());
        assert!(split_ranges(&[], 0.085, &SegmenterConfig::default()).is_empty());
    }

    #[test]
    fn rejects_non_finite_or_non_positive_window_duration() {
        let rms = speech_silence_timeline();
        let config = SegmenterConfig::default();
        assert!(split_ranges(&rms, 0.0, &config).is_empty());
        assert!(split_ranges(&rms, -0.085, &config).is_empty());
        assert!(split_ranges(&rms, f64::NAN, &config).is_empty());
        assert!(split_ranges(&rms, f64::INFINITY, &config).is_empty());
    }

    #[test]
    fn max_segment_forces_cut() {
        let rms = vec![0.05f32; 200];
        let config = SegmenterConfig::new(
            10.0,
            0.5,
            2.0,
            0.0,
            0.00316,
            false,
            AdaptiveVadConfig::default(),
        );
        let ranges = split_ranges(&rms, 0.085, &config);
        assert!(ranges.len() >= 5, "hard cap must cut mid-speech");
    }

    #[test]
    fn live_segments_carry_overlap_windows() {
        // 10 s of speech at 16 kHz with a 2 s pause in the middle.
        let rate = 16000usize;
        let mut samples = vec![2000i16; rate * 4];
        samples.extend(vec![0i16; rate * 2]);
        samples.extend(vec![2000i16; rate * 4]);
        let config = SegmenterConfig::new(
            1.0,
            1.0,
            45.0,
            1.0,
            0.00316,
            false,
            AdaptiveVadConfig::default(),
        );
        let segs = live_segments(&samples, 16000, &config);
        assert_eq!(segs.len(), 2);
        assert!(segs[0].overlap_range.is_none());
        let ov = segs[1]
            .overlap_range
            .clone()
            .expect("second segment has overlap");
        assert_eq!(ov.len(), rate, "1 s overlap at 16 kHz");
    }

    #[test]
    fn batch_plan_covers_file_exactly_once() {
        let plan = batch_plan(16000 * 65, 16000, 30.0, 2.5);
        assert_eq!(plan.len(), 3);
        assert_eq!(plan[0].body_range, 0..16000 * 30);
        assert_eq!(plan[1].body_range, 16000 * 30..16000 * 60);
        assert_eq!(plan[2].body_range, 16000 * 60..16000 * 65);
        assert!(plan[0].overlap_range.is_none());
        assert_eq!(
            plan[1].overlap_range.clone().unwrap().len(),
            (16000_f64 * 2.5) as usize
        );
        // Bodies are contiguous with no gaps or overlaps.
        for w in plan.windows(2) {
            assert_eq!(w[0].body_range.end, w[1].body_range.start);
        }
        assert!(batch_plan(0, 16000, 30.0, 2.5).is_empty());
    }

    #[test]
    fn batch_plan_rejects_non_finite_or_non_positive_max_segment() {
        assert!(batch_plan(16000, 16000, 0.0, 2.5).is_empty());
        assert!(batch_plan(16000, 16000, -30.0, 2.5).is_empty());
        assert!(batch_plan(16000, 16000, f64::NAN, 2.5).is_empty());
        assert!(batch_plan(16000, 16000, f64::INFINITY, 2.5).is_empty());
        assert!(batch_plan(16000, 16000, f64::NEG_INFINITY, 2.5).is_empty());
    }
}
