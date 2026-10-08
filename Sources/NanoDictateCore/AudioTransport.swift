import Foundation

// MARK: - Provider-aware audio transport selection
//
// Routes the upload container through #22 capabilities: the caller states a
// preference (`STTUploadPreference`, from `upload_format` config), the model
// profile declares what it accepts (`STTAudioProfile.supportedUploadFormats`),
// and `AudioTransportSelection` picks the result. The selection never returns
// a codec the profile does not declare, and experimental formats (Opus) are
// never auto-selected.

/// Config-level upload preference (TOML `upload_format`).
///
/// - `auto` (default): profile preferred format (WAV everywhere today —
///   zero/low encoding overhead, no default change without benchmark
///   evidence).
/// - `wav`: force WAV.
/// - `flac`: lossless compact batch transport where the profile declares
///   FLAC support; falls back to WAV otherwise.
/// - `opusExperimental` (`"opus"` / `"opus-experimental"`): experimental
///   bandwidth mode. No local encoder ships yet, so it always resolves to
///   WAV today; kept as an explicit opt-in until benchmark evidence is
///   documented.
public enum STTUploadPreference: String, Equatable, CaseIterable {
  case auto
  case wav
  case flac
  case opusExperimental = "opus-experimental"

  /// Parse a config string (case-insensitive, trimmed). `"opus"` is an
  /// alias of `"opus-experimental"`; nil/empty maps to `.auto`.
  public static func parse(_ raw: String?) -> STTUploadPreference? {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .auto
    }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "auto", "": return .auto
    case "wav": return .wav
    case "flac": return .flac
    case "opus", "opus-experimental": return .opusExperimental
    default: return nil
    }
  }

  public var isExperimental: Bool {
    self == .opusExperimental
  }
}

/// Capability-gated format selection: preference x profile -> format.
public enum AudioTransportSelection {
  /// Resolve the upload format for a concrete model profile.
  ///
  /// Guarantees:
  /// - the result is always in `profile.supportedUploadFormats` (or the
  ///   preferred `profile.uploadFormat` when that list is empty);
  /// - experimental formats are never auto-selected (`.auto` maps to the
  ///   profile preferred format, which is never experimental);
  /// - an unsupported or un-encodable request falls back to WAV.
  public static func resolve(
    preference: STTUploadPreference, profile: STTAudioProfile
  ) -> STTUploadFormat {
    let supported = profile.supportedUploadFormats.isEmpty
      ? [profile.uploadFormat] : profile.supportedUploadFormats
    switch preference {
    case .auto:
      return profile.uploadFormat
    case .wav:
      return .wav
    case .flac:
      // Local FLAC encoding is lossless (bit-exact round-trip verified), so
      // recognition regression is not assumed — it is measured via the
      // benchmark harness (`BenchmarkTransportComparison`).
      if supported.contains(.flac), FLACEncoder.canEncode(profile: profile) {
        return .flac
      }
      return .wav
    case .opusExperimental:
      // No local Opus encoder ships: opt-in resolves to WAV until benchmark
      // evidence justifies stronger support.
      return .wav
    }
  }

  /// Resolve with a raw config string; unknown strings fall back to `.auto`.
  public static func resolve(rawPreference: String?, profile: STTAudioProfile) -> STTUploadFormat {
    resolve(preference: STTUploadPreference.parse(rawPreference) ?? .auto, profile: profile)
  }
}

// MARK: - Encoded audio payload

/// Encoded upload payload: bytes plus the transport metadata the request
/// builder needs (filename extension and MIME type follow the format).
public struct EncodedAudioPayload: Equatable {
  public var data: Data
  public var format: STTUploadFormat
  /// Multipart filename, e.g. `audio.wav` / `audio.flac`.
  public var filename: String
  /// MIME type, e.g. `audio/wav` / `audio/flac`.
  public var contentType: String

  public init(data: Data, format: STTUploadFormat, filename: String? = nil) {
    self.data = data
    self.format = format
    self.filename = filename.map { AudioTransportEncoder.coercedFilename($0, for: format) }
      ?? format.defaultFilename
    self.contentType = format.contentType
  }
}

/// Encode PCM16 samples for a concrete model profile and preference.
///
/// The audio shape always comes from the profile (16 kHz mono for every
/// built-in model): source audio is resampled/mixed upstream, never
/// upmixed here (no 48 kHz stereo is sent to 16 kHz mono models merely to
/// preserve a source format). FLAC encoding is lossless; any failure falls
/// back to WAV so the request path stays total.
public enum AudioTransportEncoder {
  public static func encode(
    samples: [Int16],
    profile: STTAudioProfile = .batchMono16k,
    preference: STTUploadPreference = .auto,
    filename: String? = nil
  ) -> EncodedAudioPayload {
    let format = AudioTransportSelection.resolve(preference: preference, profile: profile)
    switch format {
    case .flac:
      if let data = FLACEncoder.encode(
        samples: samples, sampleRate: profile.sampleRate, channels: profile.channels)
      {
        return EncodedAudioPayload(data: data, format: .flac, filename: filename)
      }
      // WAV fallback encoded by the shared engine (canonical WAV codec).
      let wav = RustEngine.requireWAVEncode(
        samples: samples, sampleRate: profile.sampleRate, channels: profile.channels)
      return EncodedAudioPayload(data: wav, format: .wav, filename: filename)
    case .wav:
      let wav = RustEngine.requireWAVEncode(
        samples: samples, sampleRate: profile.sampleRate, channels: profile.channels)
      return EncodedAudioPayload(data: wav, format: .wav, filename: filename)
    case .opus:
      // No encoder: fall back to WAV (never emit an unsupported body).
      let wav = RustEngine.requireWAVEncode(
        samples: samples, sampleRate: profile.sampleRate, channels: profile.channels)
      return EncodedAudioPayload(data: wav, format: .wav, filename: filename)
    case .pcm16:
      // Raw PCM16 for realtime streaming profiles (no container header).
      // The batch upload path never selects this (realtime dictation streams
      // via WebSocket through RealtimePCMConverter), but keep the encoder
      // total for direct calls with a realtime profile.
      let raw = RealtimePCMConverter.pcmData(from: samples)
      return EncodedAudioPayload(data: raw, format: .pcm16, filename: filename)
    }
  }

  /// Coerce a multipart filename to the payload format extension
  /// (`segment-1.wav` -> `segment-1.flac`); names without a known audio
  /// extension are left untouched.
  public static func coercedFilename(_ filename: String, for format: STTUploadFormat) -> String {
    let known = ["wav", "flac", "ogg", "pcm"]
    if let dot = filename.lastIndex(of: ".") {
      let ext = String(filename[filename.index(after: dot)...]).lowercased()
      if known.contains(ext) {
        return String(filename[..<dot]) + "." + format.fileExtension
      }
    }
    return filename
  }
}
