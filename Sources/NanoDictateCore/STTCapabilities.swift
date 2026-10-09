import Foundation

// MARK: - Model-aware STT capabilities and audio profiles

// Request construction and audio preparation are driven by the selected
// concrete provider+model profile (STTModelRegistry.resolve), not by the
// provider enum alone. Adding a future model means adding one profile entry
// below — no branching in request/audio code.

// MARK: - Upload audio format

/// Accepted upload audio format for a model profile.
///
/// - `wav`: 16-bit PCM WAV. Zero/low encoding overhead, universally
///   accepted; the default transport everywhere.
/// - `flac`: lossless FLAC (16 kHz mono PCM16 source). Compact batch
///   transport where the provider declares support. Encoded locally with the
///   pure-Swift `FLACEncoder` (fixed predictors + Rice coding), so it works
///   on every supported macOS version with no extra dependency.
/// - `opus`: explicitly experimental bandwidth mode. No local encoder is
///   shipped yet, so capability-gated selection never auto-selects it; an
///   explicit request falls back to WAV until benchmark evidence justifies
///   stronger support.
/// - `pcm16`: raw mono signed 16-bit little-endian bytes without a container
///   header (OpenAI realtime transcription sessions).
///
/// Provider support (verified 2026-09 against current official docs):
/// OpenAI transcription API (`flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav,
/// webm`) and Groq Speech-to-Text (same list) both accept FLAC and
/// Ogg-encapsulated Opus. Cloudflare Workers AI raw-audio upload is only
/// verified for WAV in this repository, so its profile stays WAV-only, as
/// does the conservative custom-endpoint fallback (never assume an
/// undeclared codec).
public enum STTUploadFormat: String, Equatable, CaseIterable {
  case wav
  case flac
  case opus
  case pcm16

  /// File extension used for the multipart `filename` (no dot).
  public var fileExtension: String {
    switch self {
    case .wav: return "wav"
    case .flac: return "flac"
    case .opus: return "ogg"
    case .pcm16: return "pcm"
    }
  }

  /// MIME type used for the multipart file part and raw-audio bodies.
  public var contentType: String {
    switch self {
    case .wav: return "audio/wav"
    case .flac: return "audio/flac"
    case .opus: return "audio/ogg"
    case .pcm16: return "audio/pcm"
    }
  }

  /// Default multipart filename for batch uploads.
  public var defaultFilename: String {
    "audio.\(fileExtension)"
  }

  /// True for bit-exact transports (no recognition-quality risk).
  public var isLossless: Bool {
    switch self {
    case .wav, .flac, .pcm16: return true
    case .opus: return false
    }
  }

  /// Experimental formats are never auto-selected; they require an explicit
  /// opt-in and stay opt-in until benchmark evidence is documented.
  public var isExperimental: Bool {
    self == .opus
  }
}

// MARK: - Audio profile

/// Model-specific audio requirements for request preparation.
/// Batch profiles require 16 kHz mono PCM16 (WAV default, FLAC where the
/// profile declares support); realtime transcription profiles require 24 kHz
/// mono raw PCM16 (official OpenAI realtime transcription API:
/// `audio/input/format = {"type": "audio/pcm", "rate": 24000}`, base64 bytes
/// without a WAV header). The upload container varies per profile
/// (`uploadFormat` is the preferred/default container,
/// `supportedUploadFormats` lists every container the provider accepts).
/// Selection (`AudioTransportSelection`) never picks a format outside
/// `supportedUploadFormats`, and never upmixes source audio (e.g. no 48 kHz
/// stereo is sent to 16 kHz mono Whisper-style models merely to preserve a
/// source format). Callers request the requirement from the model instead of
/// hard-coding it.
public struct STTAudioProfile: Equatable {
  /// Required sample rate in Hz (preferred == required for current models).
  public var sampleRate: Int
  /// Required channel count (1 = mono).
  public var channels: Int
  /// Preferred upload container for this model (the default selection).
  public var uploadFormat: STTUploadFormat
  /// Every upload container the provider accepts for this model.
  public var supportedUploadFormats: [STTUploadFormat]

  public init(
    sampleRate: Int = 16000,
    channels: Int = 1,
    uploadFormat: STTUploadFormat = .wav,
    supportedUploadFormats: [STTUploadFormat]? = nil
  ) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.uploadFormat = uploadFormat
    // Default: only the preferred format is accepted (conservative: never
    // assume an undeclared codec).
    self.supportedUploadFormats = supportedUploadFormats ?? [uploadFormat]
  }

  /// Shared batch profile used by every batch model today.
  public static let batchMono16k = STTAudioProfile(sampleRate: 16000, channels: 1, uploadFormat: .wav)
  /// Realtime transcription profile (OpenAI `gpt-live-transcribe` family):
  /// 24 kHz mono raw PCM16, streamed continuously over one WebSocket session.
  public static let realtimeMono24kPCM =
    STTAudioProfile(sampleRate: 24000, channels: 1, uploadFormat: .pcm16)

  /// Batch profile for providers verified to accept lossless FLAC
  /// (OpenAI and Groq transcription APIs, 2026-09). Preferred/default
  /// transport stays WAV (zero encoding overhead); FLAC is opt-in via
  /// `upload_format = "flac"` and is only ever selected where declared here.
  public static let batchMono16kFLACCapable = STTAudioProfile(
    sampleRate: 16000, channels: 1, uploadFormat: .wav,
    supportedUploadFormats: [.wav, .flac])
}

// MARK: - Transport

/// Session/transport semantics of a model profile.
/// Batch transports upload one request per audio; `.streamingSession` keeps
/// one stateful WebSocket session per dictation (OpenAI realtime
/// transcription) and streams raw PCM16 continuously.
public enum STTTransportKind: String, Equatable {
  /// OpenAI-compatible multipart/form-data upload, one request per audio.
  case batchMultipart
  /// Raw audio bytes upload (Cloudflare Workers AI), one request per audio.
  case batchRawAudio
  /// Persistent realtime transcription session (WebSocket).
  case streamingSession
}

// MARK: - Response format

/// Response shape a model profile is asked to return.
public enum STTResponseFormat: String, Equatable {
  /// Flat `{"text": ...}` JSON (default OpenAI-compatible).
  case json
  /// `verbose_json` with word-level timestamps where supported.
  case verboseJSON
}

// MARK: - Language hint mode

/// How a model profile accepts the language hint.
public enum STTLanguageHintMode: String, Equatable {
  /// Language field is never sent (e.g. Cloudflare raw body).
  case none
  /// Single `language` field (Whisper-style, e.g. "ru").
  case single
  /// Multiple language hints (reserved for future multi-language models).
  case multi
}

// MARK: - Capabilities

/// Full capability set of one concrete STT model profile.
/// Request builders consult this struct; they never branch on the provider
/// id or model name directly.
public struct STTCapabilities: Equatable {
  /// Transport/session semantics.
  public var transport: STTTransportKind
  /// Response formats the profile may request.
  public var responseFormats: [STTResponseFormat]
  /// Ask for `response_format=verbose_json` where applicable.
  public var supportsVerboseJSON: Bool
  /// Ask for `timestamp_granularities[]=word` (word timestamps for stitching).
  public var supportsWordTimestamps: Bool
  /// Segment-level timestamps (reserved; no builder emits them yet).
  public var supportsSegmentTimestamps: Bool
  /// Send the `prompt` context field (prior text / chunk chaining).
  public var supportsPrompt: Bool
  /// Send the `temperature` stable field.
  public var supportsTemperature: Bool
  /// Send the `vad_filter` server-side VAD flag (Groq only today).
  public var supportsVadFilter: Bool
  /// Send Whisper hallucination thresholds (reserved; no current provider).
  public var supportsNoSpeechThreshold: Bool
  public var supportsCompressionRatioThreshold: Bool
  public var supportsLogprobThreshold: Bool
  /// Language hint acceptance.
  public var languageHint: STTLanguageHintMode
  /// Keyword/hotword biasing list (reserved; no current provider).
  public var supportsKeywordBiasing: Bool
  /// Server-side VAD/chunking/noise-reduction performed by the backend.
  public var supportsServerVAD: Bool
  public var supportsServerChunking: Bool
  public var supportsNoiseReduction: Bool

  public init(
    transport: STTTransportKind = .batchMultipart,
    responseFormats: [STTResponseFormat] = [.json],
    supportsVerboseJSON: Bool = false,
    supportsWordTimestamps: Bool = false,
    supportsSegmentTimestamps: Bool = false,
    supportsPrompt: Bool = true,
    supportsTemperature: Bool = true,
    supportsVadFilter: Bool = false,
    supportsNoSpeechThreshold: Bool = false,
    supportsCompressionRatioThreshold: Bool = false,
    supportsLogprobThreshold: Bool = false,
    languageHint: STTLanguageHintMode = .single,
    supportsKeywordBiasing: Bool = false,
    supportsServerVAD: Bool = false,
    supportsServerChunking: Bool = false,
    supportsNoiseReduction: Bool = false
  ) {
    self.transport = transport
    self.responseFormats = responseFormats
    self.supportsVerboseJSON = supportsVerboseJSON
    self.supportsWordTimestamps = supportsWordTimestamps
    self.supportsSegmentTimestamps = supportsSegmentTimestamps
    self.supportsPrompt = supportsPrompt
    self.supportsTemperature = supportsTemperature
    self.supportsVadFilter = supportsVadFilter
    self.supportsNoSpeechThreshold = supportsNoSpeechThreshold
    self.supportsCompressionRatioThreshold = supportsCompressionRatioThreshold
    self.supportsLogprobThreshold = supportsLogprobThreshold
    self.languageHint = languageHint
    self.supportsKeywordBiasing = supportsKeywordBiasing
    self.supportsServerVAD = supportsServerVAD
    self.supportsServerChunking = supportsServerChunking
    self.supportsNoiseReduction = supportsNoiseReduction
  }
}

// MARK: - Model profile

/// One concrete provider+model profile: capabilities, audio requirements,
/// and response extraction path.
public struct STTModelProfile: Equatable {
  /// Canonical adapter id this profile was resolved for (e.g. "openai").
  public var adapterID: String
  /// Normalized model name this profile describes ("" = family fallback).
  public var model: String
  public var capabilities: STTCapabilities
  public var audio: STTAudioProfile
  /// JSON path to transcript text; nil = flat "text" (OpenAI-compatible).
  public var transcriptPath: [String]?

  public init(
    adapterID: String,
    model: String,
    capabilities: STTCapabilities,
    audio: STTAudioProfile = .batchMono16k,
    transcriptPath: [String]? = nil
  ) {
    self.adapterID = adapterID
    self.model = model
    self.capabilities = capabilities
    self.audio = audio
    self.transcriptPath = transcriptPath
  }
}

// MARK: - Resolver

/// Model-aware profile registry: concrete (adapterID, model) -> profile.
///
/// Resolution order for a known adapter family:
/// 1. Exact known model name (case-insensitive).
/// 2. Known model prefix (e.g. `gpt-transcribe-` snapshots and `gpt-4o-`
///    for OpenAI modern models).
/// 3. Family fallback (conservative for unknown models; see docs).
/// Unknown adapter ids (custom OpenAI-compatible endpoints, including the
/// historic `airubiz`/`gigaam`/`selfhosted` section names) always resolve to
/// the conservative OpenAI-compatible fallback documented in
/// `docs/stt-capabilities.md`.
public enum STTModelRegistry {
  /// Known OpenAI whisper-class models: full Whisper parameter set.
  /// Legacy compatibility path: explicit `whisper-1` keeps working unless
  /// the API itself rejects it. Not the default or recommended model.
  private static let openAIWhisperModels: Set<String> = ["whisper-1"]
  /// Recommended modern batch transcription model (2026-09, verified against
  /// the official transcription guide): `gpt-transcribe` for file/batch
  /// transcription of completed recordings. Narrower parameter set:
  /// JSON response only (no verbose_json / word granularities), no
  /// temperature, singular `language` replaced by the `languages[]` array.
  private static let openAIGPTTranscribeModels: Set<String> = ["gpt-transcribe"]
  /// Deprecated modern transcription models (removal announced 2026-08-26,
  /// effective 2027-02-26): narrower parameter set (no verbose_json / word
  /// granularities / temperature in requests). Kept as compatibility profiles
  /// for existing integrations; new integrations must use `gpt-transcribe`.
  private static let openAIModernModels: Set<String> = [
    "gpt-4o-transcribe",
    "gpt-4o-mini-transcribe",
  ]
  /// Realtime transcription models (stateful WebSocket sessions, verified
  /// against the official realtime-transcription guide 2026-10-01):
  /// `gpt-live-transcribe` family. Transport is `.streamingSession`, audio
  /// is 24 kHz mono raw PCM16 (NOT the 16 kHz batch WAV profile). Checked
  /// before the batch `gpt-transcribe` prefix so a future
  /// `gpt-live-transcribe-*` snapshot keeps the streaming profile.
  private static let openAIRealtimeModels: Set<String> = ["gpt-live-transcribe"]
  /// Known Groq models (verbose_json without timestamp granularities).
  private static let groqModels: Set<String> = [
    "whisper-large-v3",
    "whisper-large-v3-turbo",
    "distil-whisper-large-v3-en",
  ]

  /// Conservative fallback for custom OpenAI-compatible endpoints:
  /// plain transcription only. No verbose_json (not guaranteed), no word
  /// timestamp granularities, no vad_filter/thresholds, no keyword biasing.
  /// Prompt, single language hint and temperature are sent when provided.
  public static let openAICompatibleFallback = STTCapabilities(
    transport: .batchMultipart,
    responseFormats: [.json],
    supportsVerboseJSON: false,
    supportsWordTimestamps: false,
    supportsSegmentTimestamps: false,
    supportsPrompt: true,
    supportsTemperature: true,
    supportsVadFilter: false,
    supportsNoSpeechThreshold: false,
    supportsCompressionRatioThreshold: false,
    supportsLogprobThreshold: false,
    languageHint: .single,
    supportsKeywordBiasing: false,
    supportsServerVAD: false,
    supportsServerChunking: false,
    supportsNoiseReduction: false
  )

  /// Resolve the profile for a concrete (adapterID, model) pair.
  /// - Parameters:
  ///   - adapterID: provider section id ("openai", "groq", ...); unknown ids
  ///     resolve to the conservative OpenAI-compatible fallback.
  ///   - model: configured (already default-resolved) model name; matching
  ///     is case-insensitive, surrounding whitespace trimmed.
  public static func resolve(adapterID: String, model: String) -> STTModelProfile {
    let normalizedModel =
      model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch STTAdapterID.from(adapterID) {
    case .openai:
      return resolveOpenAI(model: normalizedModel)
    case .groq:
      return resolveGroq(model: normalizedModel)
    case .cloudflare:
      return STTModelProfile(
        adapterID: adapterID,
        model: normalizedModel,
        capabilities: STTCapabilities(
          transport: .batchRawAudio,
          responseFormats: [.json],
          supportsVerboseJSON: false,
          supportsWordTimestamps: false,
          supportsSegmentTimestamps: false,
          supportsPrompt: false,
          supportsTemperature: false,
          languageHint: .none
        ),
        audio: .batchMono16k,
        transcriptPath: ["result", "text"]
      )
    case .openAICompatible:
      return STTModelProfile(
        adapterID: adapterID,
        model: normalizedModel,
        capabilities: openAICompatibleFallback,
        audio: .batchMono16k,
        transcriptPath: nil
      )
    }
  }

  /// Audio requirements for a concrete (adapterID, model) pair.
  public static func audioProfile(adapterID: String, model: String) -> STTAudioProfile {
    resolve(adapterID: adapterID, model: model).audio
  }

  /// Capabilities for a concrete (adapterID, model) pair.
  public static func capabilities(adapterID: String, model: String) -> STTCapabilities {
    resolve(adapterID: adapterID, model: model).capabilities
  }

  // MARK: - Families

  private static func resolveOpenAI(model: String) -> STTModelProfile {
    // Realtime first: `gpt-live-transcribe` family (exact name plus dated
    // snapshots) never matches the batch `gpt-transcribe` prefix below, but
    // the order documents intent. Other `gpt-live-*` names (e.g.
    // voice-conversation models such as `gpt-live-1`) stay on batch.
    if openAIRealtimeModels.contains(model) || model.hasPrefix("gpt-live-transcribe")
    {
      // Stateful realtime transcription session: deltas + completion events
      // over one WebSocket; 24 kHz mono raw PCM16; languages[] (multi),
      // prompt/keywords/delay configured in session.update.
      return STTModelProfile(
        adapterID: STTAdapterID.openai.rawValue,
        model: model,
        capabilities: STTCapabilities(
          transport: .streamingSession,
          responseFormats: [.json],
          supportsVerboseJSON: false,
          supportsWordTimestamps: false,
          supportsSegmentTimestamps: false,
          supportsPrompt: true,
          supportsTemperature: false,
          languageHint: .multi,
          supportsKeywordBiasing: true,
          supportsServerVAD: false,
          supportsServerChunking: true,
          supportsNoiseReduction: false
        ),
        audio: .realtimeMono24kPCM,
        transcriptPath: nil
      )
    }
    if openAIWhisperModels.contains(model) || model.hasPrefix("whisper-") {
      return STTModelProfile(
        adapterID: STTAdapterID.openai.rawValue,
        model: model,
        capabilities: STTCapabilities(
          transport: .batchMultipart,
          responseFormats: [.json, .verboseJSON],
          supportsVerboseJSON: true,
          supportsWordTimestamps: true,
          supportsSegmentTimestamps: false,
          supportsPrompt: true,
          supportsTemperature: true,
          languageHint: .single
        ),
        audio: .batchMono16kFLACCapable,
        transcriptPath: nil
      )
    }
    if openAIGPTTranscribeModels.contains(model) || model.hasPrefix("gpt-transcribe") {
      // Recommended batch profile: JSON only, prompt supported, singular
      // `language` replaced by the `languages[]` array (never send both),
      // no temperature / verbose / timestamp granularities.
      return STTModelProfile(
        adapterID: STTAdapterID.openai.rawValue,
        model: model,
        capabilities: STTCapabilities(
          transport: .batchMultipart,
          responseFormats: [.json],
          supportsVerboseJSON: false,
          supportsWordTimestamps: false,
          supportsSegmentTimestamps: false,
          supportsPrompt: true,
          supportsTemperature: false,
          languageHint: .multi
        ),
        audio: .batchMono16kFLACCapable,
        transcriptPath: nil
      )
    }
    if openAIModernModels.contains(model) || model.hasPrefix("gpt-4o-") {
      return STTModelProfile(
        adapterID: STTAdapterID.openai.rawValue,
        model: model,
        capabilities: STTCapabilities(
          transport: .batchMultipart,
          responseFormats: [.json],
          supportsVerboseJSON: false,
          supportsWordTimestamps: false,
          supportsSegmentTimestamps: false,
          supportsPrompt: true,
          supportsTemperature: false,
          languageHint: .single
        ),
        audio: .batchMono16kFLACCapable,
        transcriptPath: nil
      )
    }
    // Unknown OpenAI model: conservative fallback (same rationale as custom
    // endpoints). Previously every openai-id model received verbose_json +
    // word granularities; that fallback is intentionally narrowed so an
    // unsupported parameter is never sent merely because whisper-1 supports
    // it. Known whisper models above keep byte-identical behavior.
    return STTModelProfile(
      adapterID: STTAdapterID.openai.rawValue,
      model: model,
      capabilities: STTCapabilities(
        transport: .batchMultipart,
        responseFormats: [.json],
        supportsVerboseJSON: false,
        supportsWordTimestamps: false,
        supportsSegmentTimestamps: false,
        supportsPrompt: true,
        supportsTemperature: true,
        languageHint: .single
      ),
      audio: .batchMono16k,
      transcriptPath: nil
    )
  }

  private static func resolveGroq(model: String) -> STTModelProfile {
    if groqModels.contains(model) || model.hasPrefix("whisper-") || model.hasPrefix("distil-whisper-") {
      return STTModelProfile(
        adapterID: STTAdapterID.groq.rawValue,
        model: model,
        capabilities: STTCapabilities(
          transport: .batchMultipart,
          responseFormats: [.json, .verboseJSON],
          supportsVerboseJSON: true,
          supportsWordTimestamps: false,
          supportsSegmentTimestamps: false,
          supportsPrompt: true,
          supportsTemperature: true,
          supportsVadFilter: true,
          languageHint: .single,
          supportsServerVAD: true
        ),
        audio: .batchMono16kFLACCapable,
        transcriptPath: nil
      )
    }
    // Unknown Groq model: conservative fallback (no verbose_json assumed).
    return STTModelProfile(
      adapterID: STTAdapterID.groq.rawValue,
      model: model,
      capabilities: STTCapabilities(
        transport: .batchMultipart,
        responseFormats: [.json],
        supportsVerboseJSON: false,
        supportsWordTimestamps: false,
        supportsSegmentTimestamps: false,
        supportsPrompt: true,
        supportsTemperature: true,
        languageHint: .single
      ),
      audio: .batchMono16k,
      transcriptPath: nil
    )
  }
}
