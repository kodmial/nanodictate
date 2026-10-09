//! Model-aware STT capability profiles and request-planning policy.
//!
//! Ports `STTAdapterID`, `STTUploadFormat`, `STTAudioProfile`,
//! `STTTransportKind`, `STTResponseFormat`, `STTLanguageHintMode`,
//! `STTCapabilities`, `STTModelProfile`, and `STTModelRegistry` from the
//! Swift layer. Request construction and audio preparation are driven by
//! the resolved concrete provider+model profile, never by branching on
//! provider names at call sites. Transport itself (networking) stays
//! native; the engine produces the policy that the native transport
//! executes.

/// Known STT adapter ids. Unknown ids resolve to `openai_compatible`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterId {
    Openai,
    Groq,
    Cloudflare,
    OpenaiCompatible,
}

impl AdapterId {
    pub fn from_id(id: &str) -> Self {
        match id {
            "openai" => Self::Openai,
            "groq" => Self::Groq,
            "cloudflare" => Self::Cloudflare,
            _ => Self::OpenaiCompatible,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Openai => "openai",
            Self::Groq => "groq",
            Self::Cloudflare => "cloudflare",
            Self::OpenaiCompatible => "openai-compatible",
        }
    }

    pub fn default_base_url(&self) -> &'static str {
        match self {
            Self::Openai => "https://api.openai.com/v1/audio/transcriptions",
            Self::Groq => "https://api.groq.com/openai/v1/audio/transcriptions",
            Self::Cloudflare | Self::OpenaiCompatible => "",
        }
    }

    pub fn default_model(&self) -> &'static str {
        match self {
            // Recommended batch default (mirrors STTAdapterID.defaultModel):
            // modern transcription profile, not the legacy whisper path.
            Self::Openai => "gpt-transcribe",
            Self::Groq => "whisper-large-v3",
            Self::Cloudflare | Self::OpenaiCompatible => "",
        }
    }
}

/// Accepted upload audio container.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadFormat {
    Wav,
    Pcm16,
}

impl UploadFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Wav => "wav",
            Self::Pcm16 => "pcm16",
        }
    }
}

/// Model-specific audio requirements for request preparation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioProfile {
    pub sample_rate: u32,
    pub channels: u16,
    pub upload_format: UploadFormat,
    /// Whether the provider accepts a lossless FLAC upload body in addition
    /// to WAV (mirrors `STTAudioProfile.supportedUploadFormats`). The
    /// preferred/default transport stays WAV everywhere; FLAC is opt-in.
    pub supports_flac: bool,
}

impl AudioProfile {
    pub const BATCH_MONO_16K: Self = Self {
        sample_rate: 16000,
        channels: 1,
        upload_format: UploadFormat::Wav,
        supports_flac: false,
    };

    /// Batch profile for providers verified to accept lossless FLAC
    /// (OpenAI and Groq transcription APIs). Preferred transport stays WAV.
    pub const BATCH_MONO_16K_FLAC_CAPABLE: Self = Self {
        sample_rate: 16000,
        channels: 1,
        upload_format: UploadFormat::Wav,
        supports_flac: true,
    };

    /// Realtime transcription profile (OpenAI `gpt-live-transcribe` family):
    /// 24 kHz mono raw PCM16 streamed over one stateful session (official
    /// realtime-transcription API: `audio/input/format = audio/pcm @24kHz`).
    pub const REALTIME_MONO_24K_PCM: Self = Self {
        sample_rate: 24000,
        channels: 1,
        upload_format: UploadFormat::Pcm16,
        supports_flac: false,
    };
}

/// Session/transport semantics of a model profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportKind {
    BatchMultipart,
    BatchRawAudio,
    StreamingSession,
}

/// Response shape a model profile is asked to return.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResponseFormat {
    Json,
    VerboseJson,
}

/// How a model profile accepts the language hint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LanguageHintMode {
    None,
    Single,
    Multi,
}

/// Full capability set of one concrete STT model profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capabilities {
    pub transport: TransportKind,
    pub response_formats: Vec<ResponseFormat>,
    pub supports_verbose_json: bool,
    pub supports_word_timestamps: bool,
    pub supports_segment_timestamps: bool,
    pub supports_prompt: bool,
    pub supports_temperature: bool,
    pub supports_vad_filter: bool,
    pub supports_no_speech_threshold: bool,
    pub supports_compression_ratio_threshold: bool,
    pub supports_logprob_threshold: bool,
    pub language_hint: LanguageHintMode,
    pub supports_keyword_biasing: bool,
    pub supports_server_vad: bool,
    pub supports_server_chunking: bool,
    pub supports_noise_reduction: bool,
}

impl Capabilities {
    /// Conservative fallback for custom OpenAI-compatible endpoints.
    pub fn openai_compatible_fallback() -> Self {
        Self {
            transport: TransportKind::BatchMultipart,
            response_formats: vec![ResponseFormat::Json],
            supports_verbose_json: false,
            supports_word_timestamps: false,
            supports_segment_timestamps: false,
            supports_prompt: true,
            supports_temperature: true,
            supports_vad_filter: false,
            supports_no_speech_threshold: false,
            supports_compression_ratio_threshold: false,
            supports_logprob_threshold: false,
            language_hint: LanguageHintMode::Single,
            supports_keyword_biasing: false,
            supports_server_vad: false,
            supports_server_chunking: false,
            supports_noise_reduction: false,
        }
    }
}

/// One concrete provider+model profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelProfile {
    pub adapter_id: String,
    pub model: String,
    pub capabilities: Capabilities,
    pub audio: AudioProfile,
    /// JSON path to transcript text; `None` means flat `text`.
    pub transcript_path: Option<Vec<String>>,
}

fn normalize_model(model: &str) -> String {
    model.trim().to_lowercase()
}

fn openai_profile(model: &str) -> ModelProfile {
    let base = |capabilities: Capabilities, audio: AudioProfile| ModelProfile {
        adapter_id: AdapterId::Openai.as_str().to_string(),
        model: model.to_string(),
        capabilities,
        audio,
        transcript_path: None,
    };
    // Realtime first: `gpt-live-transcribe` family (exact name plus dated
    // snapshots) is a stateful streaming session (24 kHz mono raw PCM16),
    // never the batch `gpt-transcribe` profile. Other `gpt-live-*` names
    // (e.g. voice-conversation models such as `gpt-live-1`) stay on batch.
    if model == "gpt-live-transcribe" || model.starts_with("gpt-live-transcribe")
    {
        return base(
            Capabilities {
                transport: TransportKind::StreamingSession,
                response_formats: vec![ResponseFormat::Json],
                supports_verbose_json: false,
                supports_word_timestamps: false,
                supports_prompt: true,
                supports_temperature: false,
                language_hint: LanguageHintMode::Multi,
                supports_keyword_biasing: true,
                supports_server_chunking: true,
                ..Capabilities::openai_compatible_fallback()
            },
            AudioProfile::REALTIME_MONO_24K_PCM,
        );
    }
    if model == "whisper-1" || model.starts_with("whisper-") {
        return base(
            Capabilities {
                transport: TransportKind::BatchMultipart,
                response_formats: vec![ResponseFormat::Json, ResponseFormat::VerboseJson],
                supports_verbose_json: true,
                supports_word_timestamps: true,
                supports_prompt: true,
                supports_temperature: true,
                ..Capabilities::openai_compatible_fallback()
            },
            AudioProfile::BATCH_MONO_16K_FLAC_CAPABLE,
        );
    }
    // Recommended modern batch profile (mirrors STTModelRegistry): JSON
    // only, prompt supported, multi-language hint, no temperature or word
    // timestamps. Exact names plus dated snapshots share the profile.
    if model == "gpt-transcribe" || model.starts_with("gpt-transcribe") {
        return base(
            Capabilities {
                transport: TransportKind::BatchMultipart,
                response_formats: vec![ResponseFormat::Json],
                supports_verbose_json: false,
                supports_word_timestamps: false,
                supports_prompt: true,
                supports_temperature: false,
                language_hint: LanguageHintMode::Multi,
                ..Capabilities::openai_compatible_fallback()
            },
            AudioProfile::BATCH_MONO_16K_FLAC_CAPABLE,
        );
    }
    if model == "gpt-4o-transcribe"
        || model == "gpt-4o-mini-transcribe"
        || model.starts_with("gpt-4o-")
    {
        return base(
            Capabilities {
                transport: TransportKind::BatchMultipart,
                response_formats: vec![ResponseFormat::Json],
                supports_verbose_json: false,
                supports_word_timestamps: false,
                supports_prompt: true,
                supports_temperature: false,
                ..Capabilities::openai_compatible_fallback()
            },
            AudioProfile::BATCH_MONO_16K_FLAC_CAPABLE,
        );
    }
    base(
        Capabilities {
            supports_temperature: true,
            ..Capabilities::openai_compatible_fallback()
        },
        AudioProfile::BATCH_MONO_16K,
    )
}

fn groq_profile(model: &str) -> ModelProfile {
    let base = |capabilities: Capabilities, audio: AudioProfile| ModelProfile {
        adapter_id: AdapterId::Groq.as_str().to_string(),
        model: model.to_string(),
        capabilities,
        audio,
        transcript_path: None,
    };
    if model == "whisper-large-v3"
        || model == "whisper-large-v3-turbo"
        || model == "distil-whisper-large-v3-en"
        || model.starts_with("whisper-")
        || model.starts_with("distil-whisper-")
    {
        return base(
            Capabilities {
                transport: TransportKind::BatchMultipart,
                response_formats: vec![ResponseFormat::Json, ResponseFormat::VerboseJson],
                supports_verbose_json: true,
                supports_word_timestamps: false,
                supports_prompt: true,
                supports_temperature: true,
                supports_vad_filter: true,
                supports_server_vad: true,
                ..Capabilities::openai_compatible_fallback()
            },
            AudioProfile::BATCH_MONO_16K_FLAC_CAPABLE,
        );
    }
    base(
        Capabilities {
            supports_temperature: true,
            ..Capabilities::openai_compatible_fallback()
        },
        AudioProfile::BATCH_MONO_16K,
    )
}

/// Resolves the profile for a concrete (adapter id, model) pair.
/// Matching is case-insensitive with surrounding whitespace trimmed.
pub fn resolve(adapter_id: &str, model: &str) -> ModelProfile {
    let normalized = normalize_model(model);
    match AdapterId::from_id(adapter_id) {
        AdapterId::Openai => openai_profile(&normalized),
        AdapterId::Groq => groq_profile(&normalized),
        AdapterId::Cloudflare => ModelProfile {
            adapter_id: adapter_id.to_string(),
            model: normalized,
            capabilities: Capabilities {
                transport: TransportKind::BatchRawAudio,
                response_formats: vec![ResponseFormat::Json],
                supports_verbose_json: false,
                supports_word_timestamps: false,
                supports_prompt: false,
                supports_temperature: false,
                language_hint: LanguageHintMode::None,
                ..Capabilities::openai_compatible_fallback()
            },
            audio: AudioProfile::BATCH_MONO_16K,
            transcript_path: Some(vec!["result".to_string(), "text".to_string()]),
        },
        AdapterId::OpenaiCompatible => ModelProfile {
            adapter_id: adapter_id.to_string(),
            model: normalized,
            capabilities: Capabilities::openai_compatible_fallback(),
            audio: AudioProfile::BATCH_MONO_16K,
            transcript_path: None,
        },
    }
}

/// Audio requirements for a concrete (adapter id, model) pair.
pub fn audio_profile(adapter_id: &str, model: &str) -> AudioProfile {
    resolve(adapter_id, model).audio
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whisper_profile_has_full_word_timestamps() {
        let p = resolve("openai", "whisper-1");
        assert!(p.capabilities.supports_verbose_json);
        assert!(p.capabilities.supports_word_timestamps);
        assert!(p.capabilities.supports_temperature);
        assert_eq!(p.transcript_path, None);
    }

    #[test]
    fn modern_openai_models_are_narrow() {
        let p = resolve("openai", "gpt-4o-transcribe");
        assert!(!p.capabilities.supports_verbose_json);
        assert!(!p.capabilities.supports_word_timestamps);
        assert!(!p.capabilities.supports_temperature);
        assert!(p.capabilities.supports_prompt);
        assert!(p.audio.supports_flac);
    }

    #[test]
    fn gpt_transcribe_profile_matches_swift_registry() {
        // Mirrors STTModelRegistry gpt-transcribe: JSON only, prompt only,
        // multi-language hint, no temperature, FLAC-capable audio.
        let p = resolve("openai", "gpt-transcribe");
        assert_eq!(p.capabilities.transport, TransportKind::BatchMultipart);
        assert!(!p.capabilities.supports_verbose_json);
        assert!(!p.capabilities.supports_word_timestamps);
        assert!(p.capabilities.supports_prompt);
        assert!(!p.capabilities.supports_temperature);
        assert_eq!(p.capabilities.language_hint, LanguageHintMode::Multi);
        assert_eq!(p.transcript_path, None);
        assert!(p.audio.supports_flac);
        // Dated snapshots share the profile (prefix match, like Swift).
        let snapshot = resolve("openai", "gpt-transcribe-2026-01-01");
        assert_eq!(snapshot.capabilities, p.capabilities);
        // Matching stays case-insensitive with whitespace trimmed.
        let upper = resolve("openai", "  GPT-TRANSCRIBE ");
        assert_eq!(upper.capabilities, p.capabilities);
    }

    #[test]
    fn openai_default_model_is_gpt_transcribe() {
        assert_eq!(AdapterId::Openai.default_model(), "gpt-transcribe");
        assert_eq!(AdapterId::Groq.default_model(), "whisper-large-v3");
        assert_eq!(AdapterId::Cloudflare.default_model(), "");
        assert_eq!(AdapterId::OpenaiCompatible.default_model(), "");
    }

    #[test]
    fn flac_capability_matches_swift_audio_profiles() {
        // Swift STTAudioProfile.batchMono16kFLACCapable for known whisper /
        // modern / groq profiles; conservative WAV-only everywhere else.
        for (adapter, model) in [
            ("openai", "whisper-1"),
            ("openai", "gpt-transcribe"),
            ("openai", "gpt-4o-mini-transcribe"),
            ("groq", "whisper-large-v3"),
        ] {
            assert!(
                resolve(adapter, model).audio.supports_flac,
                "{adapter}/{model} must accept FLAC"
            );
        }
        for (adapter, model) in [
            ("openai", "some-future-model"),
            ("groq", "some-future-model"),
            ("cloudflare", "x"),
            ("custom", "y"),
        ] {
            assert!(
                !resolve(adapter, model).audio.supports_flac,
                "{adapter}/{model} must stay WAV-only"
            );
        }
    }

    #[test]
    fn unknown_openai_model_is_conservative() {
        let p = resolve("openai", "some-future-model");
        assert!(!p.capabilities.supports_verbose_json);
        assert!(p.capabilities.supports_temperature);
    }

    #[test]
    fn groq_profile_has_vad_filter_and_server_vad() {
        let p = resolve("groq", "whisper-large-v3-turbo");
        assert!(p.capabilities.supports_vad_filter);
        assert!(p.capabilities.supports_server_vad);
        assert!(!p.capabilities.supports_word_timestamps);
    }

    #[test]
    fn cloudflare_uses_raw_audio_and_nested_path() {
        let p = resolve("cloudflare", "anything");
        assert_eq!(p.capabilities.transport, TransportKind::BatchRawAudio);
        assert_eq!(p.capabilities.language_hint, LanguageHintMode::None);
        assert_eq!(
            p.transcript_path,
            Some(vec!["result".to_string(), "text".to_string()])
        );
    }

    #[test]
    fn unknown_adapter_falls_back_to_openai_compatible() {
        let p = resolve("my-custom-provider", "my-model");
        assert_eq!(p.capabilities, Capabilities::openai_compatible_fallback());
        // Model matching is case-insensitive with whitespace trimmed;
        // adapter ids match exactly, like the Swift registry.
        let q = resolve("openai", "  WHISPER-1 ");
        assert!(q.capabilities.supports_word_timestamps);
        let r = resolve("  OpenAI ", "whisper-1");
        assert_eq!(r.capabilities, Capabilities::openai_compatible_fallback());
    }

    #[test]
    fn realtime_profile_uses_streaming_24k_pcm16() {
        // Task #25: realtime uses the model-required 24 kHz raw PCM16
        // profile, not the 16 kHz batch WAV profile.
        for model in [
            "gpt-live-transcribe",
            "gpt-live-transcribe-2026-09-01",
            "gpt-live-transcribe-2026-09-01-preview",
        ] {
            let p = resolve("openai", model);
            assert_eq!(
                p.capabilities.transport,
                TransportKind::StreamingSession,
                "{model}"
            );
            assert_eq!(p.audio.sample_rate, 24000, "{model}");
            assert_eq!(p.audio.channels, 1, "{model}");
            assert_eq!(p.audio.upload_format, UploadFormat::Pcm16, "{model}");
            assert!(!p.audio.supports_flac, "{model}");
            assert_eq!(
                p.capabilities.language_hint,
                LanguageHintMode::Multi,
                "{model}"
            );
            assert!(p.capabilities.supports_prompt, "{model}");
            assert!(!p.capabilities.supports_temperature, "{model}");
            assert!(p.capabilities.supports_keyword_biasing, "{model}");
            assert!(p.capabilities.supports_server_chunking, "{model}");
            assert!(!p.capabilities.supports_verbose_json, "{model}");
            assert!(!p.capabilities.supports_word_timestamps, "{model}");
        }
        // Batch models are untouched.
        let batch = resolve("openai", "gpt-transcribe");
        assert_eq!(batch.capabilities.transport, TransportKind::BatchMultipart);
        assert_eq!(batch.audio.sample_rate, 16000);
        // Voice-conversation and other non-transcription `gpt-live-*` names
        // stay on batch (never the streaming transcription protocol).
        for model in ["gpt-live-1", "gpt-live-foo", "gpt-live"] {
            let p = resolve("openai", model);
            assert_eq!(
                p.capabilities.transport,
                TransportKind::BatchMultipart,
                "{model}"
            );
            assert_eq!(p.audio.sample_rate, 16000, "{model}");
        }
        // Case-insensitive with whitespace trimmed, like the Swift registry.
        let upper = resolve("openai", "  GPT-LIVE-TRANSCRIBE ");
        assert_eq!(
            upper.capabilities.transport,
            TransportKind::StreamingSession
        );
        assert_eq!(upper.audio.sample_rate, 24000);
    }

    #[test]
    fn every_builtin_batch_profile_requires_mono_16k_wav_default() {
        // Realtime profiles intentionally use 24 kHz raw PCM16 (see
        // realtime_profile_uses_streaming_24k_pcm16); every batch profile
        // keeps the 16 kHz mono WAV default.
        for (adapter, model) in [
            ("openai", "whisper-1"),
            ("openai", "gpt-4o-mini-transcribe"),
            ("groq", "whisper-large-v3"),
            ("cloudflare", "x"),
            ("custom", "y"),
        ] {
            let audio = audio_profile(adapter, model);
            assert_eq!(audio.sample_rate, 16000);
            assert_eq!(audio.channels, 1);
            // Preferred/default upload stays WAV everywhere.
            assert_eq!(audio.upload_format, UploadFormat::Wav);
        }
    }
}
