import Foundation

// MARK: - PCM conversion and resampling

/// Raw PCM16 helpers for the realtime path (no WAV headers anywhere here).
public enum RealtimePCMConverter {
  /// Int16 samples -> little-endian bytes.
  public static func pcmData(from samples: [Int16]) -> Data {
    var data = Data()
    data.reserveCapacity(samples.count * 2)
    if !samples.isEmpty {
      samples.withUnsafeBytes { raw in
        data.append(contentsOf: raw)
      }
    }
    return data
  }

  /// Int16 samples -> base64 PCM16 string for `input_audio_buffer.append`.
  public static func base64PCM(from samples: [Int16]) -> String {
    pcmData(from: samples).base64EncodedString()
  }

  /// Linear resample between integer rates (used for 16 kHz mic -> 24 kHz
  /// realtime). Identity when rates match; empty in -> empty out.
  public static func resample(_ samples: [Int16], fromRate: Int, toRate: Int) -> [Int16] {
    guard !samples.isEmpty, fromRate > 0, toRate > 0, fromRate != toRate else {
      return samples
    }
    let ratio = Double(toRate) / Double(fromRate)
    let outCount = max(1, Int((Double(samples.count) * ratio).rounded()))
    var out: [Int16] = []
    out.reserveCapacity(outCount)
    for i in 0..<outCount {
      let pos = Double(i) / ratio
      let lo = Int(pos)
      let hi = min(lo + 1, samples.count - 1)
      let frac = pos - Double(lo)
      let interpolated = Double(samples[lo]) * (1.0 - frac) + Double(samples[hi]) * frac
      out.append(Int16(clamping: Int(interpolated.rounded())))
    }
    return out
  }

  /// Resample to the model-required realtime rate (24 kHz PCM).
  public static func resampleToRealtime(_ samples: [Int16], sourceRate: Int) -> [Int16] {
    resample(samples, fromRate: sourceRate, toRate: 24000)
  }

  /// Split samples into chunks of at most `maxSamples` (preserves order).
  public static func chunk(_ samples: [Int16], maxSamples: Int) -> [[Int16]] {
    guard maxSamples > 0, samples.count > maxSamples else {
      return samples.isEmpty ? [] : [samples]
    }
    var out: [[Int16]] = []
    var start = 0
    while start < samples.count {
      let end = min(start + maxSamples, samples.count)
      out.append(Array(samples[start..<end]))
      start = end
    }
    return out
  }
}

// MARK: - Client event builders (pure JSON)

/// Pure builders for realtime client JSON (unit-tested, no transport).
public enum RealtimeClientEvents {
  /// `session.update` for a transcription session (official schema).
  public static func sessionUpdate(
    model: String,
    language: String = "",
    prompt: String? = nil,
    keywords: [String] = [],
    delay: RealtimeTranscriptionDelay? = nil
  ) -> String {
    var transcription: [String: Any] = ["model": model]
    if let prompt, !prompt.isEmpty {
      transcription["prompt"] = prompt
    }
    let cleanKeywords = keywords.filter { !$0.isEmpty }
    if !cleanKeywords.isEmpty {
      transcription["keywords"] = cleanKeywords
    }
    if !language.isEmpty {
      transcription["languages"] = [language]
    }
    if let delay {
      transcription["delay"] = delay.rawValue
    }
    let session: [String: Any] = [
      "type": "transcription",
      "audio": [
        "input": [
          "format": ["type": "audio/pcm", "rate": 24000],
          "transcription": transcription,
          // Client-side VAD: server VAD unsupported for gpt-live-transcribe.
          "turn_detection": NSNull(),
        ] as [String: Any],
      ] as [String: Any],
    ]
    let event: [String: Any] = ["type": "session.update", "session": session]
    let data =
      (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"type\":\"session.update\"}"
  }

  /// `input_audio_buffer.append` with base64 PCM16.
  public static func appendAudio(base64PCM: String) -> String {
    let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": base64PCM]
    let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"type\":\"input_audio_buffer.append\"}"
  }

  /// `input_audio_buffer.commit` (end of turn -> final transcript).
  public static func commit() -> String {
    "{\"type\":\"input_audio_buffer.commit\"}"
  }

  /// `input_audio_buffer.clear` (discard buffered audio).
  public static func clear() -> String {
    "{\"type\":\"input_audio_buffer.clear\"}"
  }
}

// MARK: - Endpoint

/// WebSocket endpoint for realtime transcription sessions.
public enum RealtimeEndpoint {
  /// Base URL for OpenAI realtime WebSocket sessions.
  public static let baseURL = "wss://api.openai.com/v1/realtime"
  /// Session URL: transcription intent keeps model selection inside
  /// `session.update` (official transcription flow).
  public static func transcriptionURL() -> URL? {
    URL(string: "\(baseURL)?intent=transcription")
  }
  /// Model-scoped URL (conversational realtime sessions).
  public static func modelURL(model: String) -> URL? {
    URL(string: "\(baseURL)?model=\(model)")
  }
}
