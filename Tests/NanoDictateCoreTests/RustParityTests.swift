import Foundation
import NanoDictateRustBridge

@testable import NanoDictateCore

// MARK: - Swift<->Rust parity tests (shared engine migration)
//
// For each deterministic subsystem ported to the Rust engine, the same
// input vectors run against the Swift reference implementation and the
// engine-backed entry points, requiring equivalent output. Production
// call sites switch to the engine one subsystem at a time only after
// these parity checks (plus the macOS hardware gate) pass.
//
// The vectors below intentionally duplicate the canonical Swift unit
// tests so a behavioral drift in either implementation fails loudly.

final class RustParityTests: XCTestCase {

  // MARK: - Helpers

  /// Unwraps a throwing engine call, failing the test on error.
  private func engine<T>(_ label: String, _ body: () throws -> T) -> T? {
    do {
      return try body()
    } catch {
      XCTFail("\(label) threw: \(error)")
      return nil
    }
  }

  // MARK: - ABI smoke

  @objc func testABIVersionMatchesBridge() {
    _ = engine("abi version") { try assertEngineABIVersion() }
    _ = engine("seam availability") { try RustEngine.checkAvailable() }
  }

  // MARK: - WordDiff

  @objc func testWordDiffParity() {
    let vectors: [(old: String, new: String)] = [
      ("Один два три.", "Один два три."),
      ("Один  два.", "Один два."),
      ("Один три.", "Один два три."),
      ("А Б В.", "А В."),
      ("Было слово.", "Стало слово."),
      ("Один два", "Один два три"),
      ("Один два три.", ""),
      ("", "Привет мир."),
      ("Привет мир.", "привет мир."),
      ("hello brave world", "hello brave new world"),
    ]
    for vector in vectors {
      let swift = WordDiff.change(old: vector.old, new: vector.new)
      guard
        let rust = engine(
          "word diff '\(vector.old)' -> '\(vector.new)'",
          {
            try RustEngine.wordDiff(old: vector.old, new: vector.new)
          })
      else { continue }
      XCTAssertEqual(rust.change, swift != nil, "change flag for '\(vector.old)'")
      XCTAssertEqual(rust.spanOld, swift?.spanOld ?? "", "spanOld for '\(vector.old)'")
      XCTAssertEqual(rust.spanNew, swift?.spanNew ?? "", "spanNew for '\(vector.old)'")
      XCTAssertEqual(
        rust.spanStartOld, swift?.spanStartOld ?? 0, "spanStartOld for '\(vector.old)'")
      XCTAssertEqual(
        rust.spanStartNew, swift?.spanStartNew ?? 0, "spanStartNew for '\(vector.old)'")
    }
  }

  // MARK: - WAV codec

  @objc func testWAVCodecParity() {
    let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234, -1234]
    guard
      let rustWAV = engine(
        "wav encode",
        {
          try RustEngine.wavEncode(samples: samples, sampleRate: 16000, channels: 1)
        })
    else { return }
    let swiftWAV = WAVEncoder.encode(samples: samples, sampleRate: 16000, channels: 1)
    XCTAssertEqual(Array(rustWAV), Array(swiftWAV), "WAV bytes must be identical")

    guard let info = engine("wav info", { try RustEngine.wavInfo(rustWAV) }) else { return }
    XCTAssertEqual(info.sampleRate, 16000)
    XCTAssertEqual(info.channels, 1)
    XCTAssertEqual(info.sampleCount, samples.count)
    let decoded = WAVDecoder.decodePCM16(rustWAV)
    XCTAssertNotNil(decoded)
    XCTAssertEqual(decoded?.samples ?? [], samples)
  }

  // MARK: - Text stitching

  @objc func testTextJoinParity() {
    let vectors: [[String]] = [
      ["hello world", "foo bar"],
      ["hello brave world", "brave world again"],
      ["Hello World", "hello world again"],
      ["first part", "[…]", "last part"],
      ["", "  ", "hello"],
      ["a\nb", "c"],
    ]
    for texts in vectors {
      guard let rust = engine("text join \(texts)", { try RustEngine.joinChunkTexts(texts) })
      else { continue }
      XCTAssertEqual(rust, BatchTextJoiner.join(texts), "join for \(texts)")
    }
  }

  // MARK: - STT policy

  @objc func testSTTResolveParity() {
    let vectors: [(adapter: String, model: String)] = [
      ("openai", "whisper-1"),
      ("openai", "gpt-4o-transcribe"),
      ("openai", "some-future-model"),
      ("groq", "whisper-large-v3-turbo"),
      ("cloudflare", "anything"),
      ("my-custom-provider", "my-model"),
    ]
    for vector in vectors {
      guard
        let json = engine(
          "stt resolve \(vector)",
          {
            try RustEngine.resolveSTTProfile(adapterID: vector.adapter, model: vector.model)
          })
      else { continue }
      let swift = STTModelRegistry.resolve(adapterID: vector.adapter, model: vector.model)
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let caps = object["capabilities"] as? [String: Any],
        let audio = object["audio"] as? [String: Any]
      else {
        XCTFail("malformed profile JSON for \(vector)")
        continue
      }
      XCTAssertEqual(
        caps["supports_verbose_json"] as? Bool, swift.capabilities.supportsVerboseJSON,
        "verbose_json for \(vector)")
      XCTAssertEqual(
        caps["supports_word_timestamps"] as? Bool, swift.capabilities.supportsWordTimestamps,
        "word timestamps for \(vector)")
      XCTAssertEqual(
        caps["supports_temperature"] as? Bool, swift.capabilities.supportsTemperature,
        "temperature for \(vector)")
      XCTAssertEqual(
        caps["language_hint"] as? String, swift.capabilities.languageHint.rawValue,
        "language_hint for \(vector)")
      XCTAssertEqual(
        audio["supports_flac"] as? Bool,
        swift.audio.supportedUploadFormats.contains(.flac),
        "supports_flac for \(vector)")
      XCTAssertEqual(
        object["transport"] as? String,
        swift.capabilities.transport == .batchMultipart ? "batch_multipart" : "batch_raw_audio",
        "transport for \(vector)")
    }
  }

  // MARK: - Transcript parsing

  @objc func testTranscriptParseParity() {
    let flat = #"{"text": "hello world"}"#
    guard let parsed = engine("transcript flat", { try RustEngine.parseTranscript(body: flat) })
    else { return }
    XCTAssertTrue(parsed.contains("\"text\":\"hello world\""), "flat text: \(parsed)")

    let nested = #"{"result": {"text": "nested ok"}}"#
    guard
      let nestedParsed = engine(
        "transcript nested", { try RustEngine.parseTranscript(body: nested, path: "result.text") }
      )
    else { return }
    XCTAssertTrue(nestedParsed.contains("nested ok"), "nested text: \(nestedParsed)")
  }

  // MARK: - Failover / backoff / review

  @objc func testFailoverParity() {
    guard
      let ordered = engine(
        "failover order",
        {
          try RustEngine.failoverOrder(ids: ["a", "b", "c"], failedID: "a", autoFailover: true)
        })
    else { return }
    XCTAssertEqual(ordered, ["b", "c", "a"])
  }

  @objc func testReviewDecideParity() {
    let vectors: [(line: String?, insert: Bool)] = [
      ("", true), ("  ", true), ("y", true), ("Y", true),
      ("n", false), ("nope", false), (nil, false),
    ]
    for vector in vectors {
      _ = engine(
        "review decide \(String(describing: vector.line))",
        {
          let rust = try rustReviewDecide(line: vector.line)
          ReviewGate.readLineFunction = { vector.line }
          defer { ReviewGate.readLineFunction = { readLine() } }
          let swift = ReviewGate.confirm(text: "parity")
          XCTAssertEqual(
            rust, swift == .insert, "review for \(String(describing: vector.line))")
        })
    }
  }

  // MARK: - Adaptive VAD

  @objc func testVADParity() {
    guard let rust = engine("vad init", { try RustVAD() }) else { return }
    var swift = AdaptiveVAD()
    let frame = 0.085
    // Quiet room tone, then a speech attack, then quiet again.
    let timeline: [Float] =
      [Float](repeating: 0.0005, count: 30) + [0.02]
      + [Float](repeating: 0.0002, count: 10)
    for rms in timeline {
      guard let rustSpeech = engine("vad feed", { try rust.feed(rms: rms, duration: frame) })
      else { return }
      XCTAssertEqual(
        rustSpeech, swift.update(rms: rms, duration: frame), "vad state at rms \(rms)")
    }
  }

  @objc func testVADBlockIngressParity() {
    guard let rust = engine("vad init", { try RustVAD() }) else { return }
    // Loud block must read as speech through the realtime ingress.
    let loud = [Float](repeating: 0.05, count: 1360)
    guard
      let speech = engine(
        "vad block", { try rust.feedSamples(loud, sampleRate: 16000) })
    else { return }
    XCTAssertTrue(speech, "loud block reads as speech")
  }

  // MARK: - Input gain

  @objc func testInputGainParity() {
    guard let rust = engine("gain init", { try RustInputGain() }) else { return }
    var buf = [Float](repeating: 0.004, count: 1600)
    guard
      let amplified = engine(
        "gain apply", { try rust.apply(samples: &buf, rms: 0.004, sampleRate: 16000) })
    else { return }
    XCTAssertTrue(amplified > 0.004, "engine lifts quiet speech")
    XCTAssertTrue(buf.allSatisfy { abs($0) <= 1.0 }, "engine output stays bounded")
    // Same stimulus through the Swift reference implementation.
    let reference = InputGain()
    var swiftBuf = [Float](repeating: 0.004, count: 1600)
    let swiftRMS = reference.apply(to: &swiftBuf, rms: 0.004, sampleRate: 16000)
    XCTAssertEqual(amplified, swiftRMS, accuracy: 0.002, "amplified RMS parity")
  }

  // MARK: - Silence auto-stop

  @objc func testAutoStopParity() {
    guard let rust = engine("autostop init", { try RustAutoStop() }) else { return }
    var swift = SilenceAutoStopDetector()
    var rustFired = false
    var swiftFired = false
    // Speech opens the gate, then continuous silence fires the stop.
    for _ in 0..<5 {
      _ = engine("autostop speech", { try rust.feed(rms: 0.02, duration: 0.1, isSpeech: nil) })
      swiftFired = swift.feed(rms: 0.02, duration: 0.1)
    }
    XCTAssertTrue(swift.speechGatePassed, "swift gate opens")
    for _ in 0..<60 {
      guard
        let fed = engine(
          "autostop silence",
          {
            try rust.feed(rms: 0.0005, duration: 0.1, isSpeech: nil)
          })
      else { return }
      rustFired = fed
      swiftFired = swift.feed(rms: 0.0005, duration: 0.1)
    }
    XCTAssertEqual(rustFired, swiftFired, "auto-stop agreement")
    XCTAssertTrue(rustFired, "auto-stop fires after sustained silence")
  }

  // MARK: - Capture-readiness latch (issue #48 invariant)

  @objc func testCaptureReadinessLatchParity() {
    guard let session = engine("session init", { try RustSession() }) else { return }
    guard let generation = engine("session start", { try session.start() }) else { return }
    _ = engine("engine started", { try session.onEvent(.engineStarted, generation: generation) })
    // Start alone never reports readiness; no cue before the first buffer.
    XCTAssertFalse(session.isCaptureReady, "no readiness on start alone")
    XCTAssertFalse(session.shouldEmitReadyCue, "no cue before capture readiness")
    // First valid buffer fires readiness exactly once.
    _ = engine("first buffer", { try session.onEvent(.firstBuffer, generation: generation) })
    XCTAssertTrue(session.isCaptureReady, "readiness fires on first buffer")
    XCTAssertTrue(session.shouldEmitReadyCue, "cue follows readiness")
    XCTAssertFalse(session.shouldEmitReadyCue, "cue is one-shot")
    // Stale generations are rejected.
    _ = engine(
      "stale event",
      { try session.onEvent(.firstBuffer, generation: generation &- 1) })
    XCTAssertTrue(session.isCaptureReady, "stale event cannot clear readiness")
  }
}
