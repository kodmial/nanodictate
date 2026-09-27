import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Adaptive VAD/AGC separation tests (issue #21).
///
/// Before/after fixtures around the previous fixed -50 dBFS boundary
/// (nearSilenceThreshold = 0.00316):
///   before: any RMS below -50 dBFS was silence (no gain, no VAD speech);
///   after: speech is decided on raw RMS vs an adaptive noise floor with
///   hysteresis, and AGC gates on raw RMS vs its own floor estimate.
///
/// Levels used (linear RMS -> dBFS):
///   0.00100 -> -60 dBFS (quiet room floor)
///   0.00158 -> -56 dBFS (adaptive exit with floor 0.001)
///   0.00251 -> -52 dBFS (quiet speech, below old -50 boundary)
///   0.00316 -> -50 dBFS (old fixed threshold)
///   0.00560 -> -45 dBFS (steady fan noise above old threshold)
///   0.05000 -> -26 dBFS (normal speech)
final class AdaptiveVADTests: XCTestCase {

    private let frameDuration: TimeInterval = 0.085

    private func dbfs(_ linear: Float) -> Float {
        AudioMetrics.dbfs(linear)
    }

    // MARK: - Quiet speech below the old fixed threshold is speech

    /// Raw -52 dBFS (0.00251) with floor -60 dBFS (0.001): +8 dB above floor,
    /// at the adaptive enter threshold -> VAD speech. Before: silence solely
    /// because absolute RMS < -50 dBFS.
    @objc func testQuietSpeechBelowOldThresholdIsSpeech() {
        var vad = AdaptiveVAD()
        XCTAssertEqual(dbfs(0.00251), -52, accuracy: 0.5)
        XCTAssertTrue((dbfs(0.00251)) < (dbfs(AudioMetrics.nearSilenceThreshold)), "precondition: below old -50 boundary")

        let isSpeech = vad.update(rms: 0.00251, duration: frameDuration)

        XCTAssertTrue(isSpeech, "quiet -52 dBFS speech above quiet floor must read as speech")
    }

    /// Same quiet level drives AGC: target gain is the shortfall to -20 dBFS
    /// (~+32 dB, capped at +30), not zero.
    @objc func testQuietSpeechBelowOldThresholdIsAmplified() {
        let gain = InputGain()
        let target = gain.targetGainDb(forRms: 0.00251)
        XCTAssertTrue((target) > (25), "quiet -52 dBFS gets large positive target, not 0")
        XCTAssertLessThanOrEqual(target, 30, "capped at maxGainDb")

        var buffer = [Float](repeating: 0.00251, count: 16000)
        let outRms = gain.apply(to: &buffer, rms: 0.00251, sampleRate: 16000)
        XCTAssertTrue((dbfs(outRms)) > (dbfs(0.00251) + 15), "buffer lifted substantially")
    }

    // MARK: - Steady noise above the old threshold is not speech

    /// Steady fan noise -45 dBFS (0.0056): first buffers may read as speech
    /// while the floor converges, but after sustained noise the floor rises
    /// and the same level reads as silence. Before: always speech because
    /// absolute RMS > -50 dBFS.
    @objc func testSteadyNoiseFloorAdaptsToSilence() {
        var vad = AdaptiveVAD()
        // Converge the floor on sustained noise (60 frames x 85 ms ~ 5.1 s).
        for _ in 0..<60 {
            _ = vad.update(rms: 0.0056, duration: frameDuration)
        }
        XCTAssertTrue((vad.noiseFloor) > (0.002), "floor rose toward steady noise")
        let isSpeech = vad.update(rms: 0.0056, duration: frameDuration)
        XCTAssertFalse(isSpeech, "steady noise at its own floor must read as silence")
    }

    /// Offline segmenter: noise-only timeline yields no segments (before: one
    /// speech segment because every window exceeded -50 dBFS).
    @objc func testNoiseOnlyTimelineYieldsNoSegments() {
        let noise: Float = 0.0056
        let rms = Array(repeating: noise, count: 12)
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0,
            config: AudioSegmenterConfig(pauseDuration: 1.0, minSegment: 1.0, maxSegment: 45.0))
        XCTAssertTrue(ranges.isEmpty, "steady noise must not segment as speech")
    }

    // MARK: - Changing noise floor

    /// Floor tracks down fast (quiet gap) and up slowly (speech barely moves
    /// it): mic level decrease re-adapts within ~1 s, speech does not drag
    /// the floor to speech level.
    @objc func testNoiseFloorTracksDownFastUpSlow() {
        var tracker = NoiseFloorTracker(initialFloor: 0.01, downTau: 0.4, upTau: 8.0)
        // Quiet gap 0.001 for ~0.85 s (10 frames): floor must drop most of the way.
        for _ in 0..<10 {
            _ = tracker.update(rms: 0.001, duration: frameDuration)
        }
        XCTAssertTrue((tracker.floor) < (0.003), "floor drops fast toward quiet gap")
        // Loud speech 0.05 for the same duration: floor must barely rise.
        let before = tracker.floor
        for _ in 0..<10 {
            _ = tracker.update(rms: 0.05, duration: frameDuration)
        }
        XCTAssertTrue((tracker.floor) < (before + 0.008), "speech does not drag floor up quickly")
        XCTAssertTrue((tracker.floor) < (0.02), "floor stays far below speech level")
    }

    /// Speech on noise: floor adapted to fan -45 dBFS, then normal speech
    /// -26 dBFS (+19 dB above floor) reads as speech.
    @objc func testSpeechOnNoiseIsSpeech() {
        var vad = AdaptiveVAD()
        for _ in 0..<60 {
            _ = vad.update(rms: 0.0056, duration: frameDuration)
        }
        XCTAssertFalse(vad.update(rms: 0.0056, duration: frameDuration), "precondition: noise is silence")
        XCTAssertTrue(vad.update(rms: 0.05, duration: frameDuration), "speech +19 dB above noise floor is speech")
    }

    // MARK: - Hysteresis (no threshold chatter)

    /// Between enter and exit the state holds: rising from silence needs
    /// enter, falling from speech needs below exit. A level in the gray zone
    /// neither enters nor exits.
    @objc func testHysteresisHoldsGrayZone() {
        var vad = AdaptiveVAD()
        let enter = vad.enterThreshold
        let exit = vad.exitThreshold
        XCTAssertTrue((enter) > (exit), "precondition: hysteresis pair ordered")
        let gray = (enter + exit) / 2

        // From silence, gray alone does not enter.
        XCTAssertFalse(vad.update(rms: gray, duration: frameDuration), "gray zone does not enter from silence")
        XCTAssertFalse(vad.isSpeech)
        // Loud enters.
        XCTAssertTrue(vad.update(rms: enter * 2, duration: frameDuration), "loud enters speech")
        // Gray holds speech (no chatter down).
        XCTAssertTrue(vad.update(rms: gray, duration: frameDuration), "gray zone holds speech (no chatter)")
        // Below exit leaves.
        XCTAssertFalse(vad.update(rms: exit * 0.5, duration: frameDuration), "below exit returns to silence")
    }

    // MARK: - Limiter behavior (bounded, no hard plateau)

    /// Soft limiter is transparent below the knee and bounded above: normal
    /// speech peaks pass untouched, large transients compress toward but never
    /// exceed 1.0, monotonically (no flat hard-clipped plateau for typical
    /// microphone transients).
    @objc func testSoftLimiterTransparentBelowKneeBoundedAbove() {
        XCTAssertEqual(SoftLimiter.process(0.5), 0.5, accuracy: 0.000001, "below knee passes through")
        XCTAssertEqual(SoftLimiter.process(-0.5), -0.5, accuracy: 0.000001)
        XCTAssertEqual(SoftLimiter.process(0.8), 0.8, accuracy: 0.000001, "at knee exact")

        let limited15 = SoftLimiter.process(1.5)
        let limited20 = SoftLimiter.process(2.0)
        XCTAssertTrue((limited15) < (1.0), "transient 1.5 compresses below full scale")
        XCTAssertTrue((limited15) > (0.8), "but above the knee")
        XCTAssertLessThan(limited20, 1.0)
        XCTAssertTrue((limited20) > (limited15), "monotonic: louder in -> louder (compressed) out, no flat plateau")
        XCTAssertEqual(SoftLimiter.process(-2.0), -limited20, accuracy: 0.00001, "symmetric")
    }

    /// AGC output never hard-clips into a flat plateau on normal transients:
    /// a loud spike through high gain stays bounded and strictly below 1.0
    /// for moderate excess.
    @objc func testGainWithLimiterAvoidsHardClipping() {
        let gain = InputGain()
        // Prime gain high with quiet speech so the transient hits large gain.
        var quiet = [Float](repeating: 0.003, count: 1600)
        let quietRms: Float = 0.003
        gain.apply(to: &quiet, rms: quietRms, sampleRate: 16000)
        XCTAssertTrue((gain.currentGainDb) > (5), "precondition: gain pumped up")

        var transient: [Float] = [Float](repeating: 0.003, count: 1599) + [0.4]
        let before = transient.last!
        gain.apply(to: &transient, rms: quietRms, sampleRate: 16000)
        let peak = transient.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 1.0, "bounded to full scale")
        XCTAssertTrue((peak) > (abs(before)), "transient still louder than body (not flattened away)")
    }

    // MARK: - VAD/AGC separation (decisions on raw, not amplified)

    /// VAD state does not depend on applied gain: the same raw quiet level
    /// reads identically before and after heavy amplification of prior buffers.
    @objc func testVADUsesRawNotAmplified() {
        var vad = AdaptiveVAD()
        let gain = InputGain()
        // Pump AGC gain up with quiet speech.
        var loud: [Float] = [Float](repeating: 0.003, count: 16000)
        gain.apply(to: &loud, rms: 0.003, sampleRate: 16000)
        XCTAssertTrue((gain.currentGainDb) > (10), "precondition: gain pumped")

        // VAD on raw silence stays silence regardless of accumulated gain.
        XCTAssertFalse(vad.update(rms: 0.0005, duration: frameDuration))
        // VAD on raw quiet speech stays speech regardless of gain state.
        var vad2 = AdaptiveVAD()
        XCTAssertTrue(vad2.update(rms: 0.003, duration: frameDuration))
    }

    // MARK: - Leading/trailing silence and impulsive noise

    /// Leading silence keeps floor low so the first word attack is caught;
    /// trailing silence returns to silence without latching.
    @objc func testLeadingTrailingSilence() {
        var vad = AdaptiveVAD()
        for _ in 0..<10 {
            XCTAssertFalse(vad.update(rms: 0.001, duration: frameDuration), "leading silence stays silence")
        }
        XCTAssertTrue(vad.update(rms: 0.02, duration: frameDuration), "first word attack detected")
        for _ in 0..<10 {
            _ = vad.update(rms: 0.001, duration: frameDuration)
        }
        XCTAssertFalse(vad.isSpeech, "trailing silence returns to silence")
    }

    /// Short impulsive burst reads as momentary speech (it is loud) but the
    /// very next quiet buffers return to silence — no sustained utterance and
    /// no latch.
    @objc func testImpulsiveNoiseDoesNotLatch() {
        var vad = AdaptiveVAD()
        XCTAssertFalse(vad.update(rms: 0.001, duration: frameDuration))
        XCTAssertTrue(vad.update(rms: 0.2, duration: 0.01), "impulse is momentarily loud")
        XCTAssertFalse(vad.update(rms: 0.001, duration: frameDuration), "immediately back to silence")
        XCTAssertFalse(vad.update(rms: 0.001, duration: frameDuration))
        XCTAssertFalse(vad.isSpeech, "no latch after impulse")
    }
}
