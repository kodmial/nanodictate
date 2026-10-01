# STT model capabilities and audio profiles

Model-aware request construction: every STT request is built from the
concrete **provider + model profile** resolved by `STTModelRegistry.resolve(adapterID:model:)`,
not from the provider id alone. Audio preparation consults
`ProviderRequestBuilder.audioProfile(adapterID:model:)` (sample rate /
channels / upload format) instead of assuming a shared batch profile.

Adding a future model means adding one profile entry in
`Sources/NanoDictateCore/STTCapabilities.swift` — request builders
(`ProviderRequestBuilder.plan`), stable-field gating
(`BatchStableMultipartFields.stableFields(for:model:params:)`) and audio
helpers (`WAVEncoder.encode(samples:audioProfile:)`) follow the profile
automatically, without branching in unrelated code.

## Built-in profiles (2026-09)

The default and recommended OpenAI batch transcription model is
`gpt-transcribe` (verified against the official transcription guide;
empty `model` in `[providers.openai]` resolves to it). Normal
push-to-talk sends one complete utterance per transcription request as
plain JSON without word timestamps; `verbose_json` + word granularities
are requested only when the processing mode requires them (chunked/live
segment overlap stitching) and only for profiles that support them.

| Provider id | Model(s) | Transport | verbose_json | word granularities | prompt | temperature | vad_filter | language hint | transcript path |
|---|---|---|---|---|---|---|---|---|---|
| `openai` | `gpt-transcribe`, `gpt-transcribe-*` (default, recommended) | batch multipart | no | no | yes | no | no | multi (`languages[]`) | flat `text` |
| `openai` | `whisper-1`, `whisper-*` (legacy compat) | batch multipart | on request | on request (`word`) | yes | yes | no | single | flat `text` |
| `openai` | `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-*` (deprecated upstream, removal 2027-02-26) | batch multipart | no | no | yes | no | no | single | flat `text` |
| `openai` | unknown (fallback) | batch multipart | no | no | yes | yes | no | single | flat `text` |
| `groq` | `whisper-large-v3`, `whisper-large-v3-turbo`, `distil-whisper-large-v3-en`, `whisper-*` | batch multipart | on request | no (Groq rejects the field with HTTP 400) | yes | yes | yes (server-side VAD) | single | flat `text` |
| `groq` | unknown (fallback) | batch multipart | no | no | yes | yes | no | single | flat `text` |
| `cloudflare` | any (model baked into URL) | batch raw WAV (`audio/wav`) | no | no | no | no | no | none | `result.text` |
| `airubiz` / `gigaam` / `selfhosted` / custom | any | batch multipart (conservative fallback below) | no | no | yes | yes | no | single | flat `text` |

Audio requirements for every built-in profile: 16 kHz mono PCM16
(`STTAudioProfile.batchMono16k`). The profile struct carries
`sampleRate` / `channels` / `uploadFormat` / `supportedUploadFormats` so
future models with different requirements only change the registry entry;
`streamingSession` transport,
keyword biasing, segment timestamps, server-side chunking and noise
reduction are modeled in `STTCapabilities` as reserved fields (all `false` /
unused today). The `multi` language-hint mode is used by `gpt-transcribe`:
the configured single `language` value is forwarded as one `languages[]`
entry (the API rejects sending both `language` and `languages`).

## Audio transport formats (WAV/FLAC, optional Opus)

Upload format support per profile (verified 2026-09 against current official
docs: OpenAI transcription API and Groq Speech-to-Text both accept
`flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm`; Cloudflare Workers AI
raw-audio upload is only verified for WAV in this repository):

| Provider id | Model(s) | preferred | accepted |
|---|---|---|---|
| `openai` | `gpt-transcribe`, `whisper-1`, `gpt-4o-*`, `whisper-*` | WAV | WAV, FLAC |
| `groq` | `whisper-large-v3`, `whisper-large-v3-turbo`, `distil-whisper-large-v3-en`, `whisper-*` | WAV | WAV, FLAC |
| `openai` / `groq` | unknown (fallback) | WAV | WAV only (conservative: never assume an undeclared codec) |
| `cloudflare` | any (model baked into URL) | WAV | WAV only (`audio/wav` raw body) |
| `airubiz` / `gigaam` / `selfhosted` / custom | any | WAV | WAV only (conservative fallback) |

Rules:

- WAV remains supported everywhere and is the default (`auto` resolves to
  the profile preferred format — WAV for all built-in models today). The
  default does not change without benchmark evidence (see
  `docs/stt-benchmark.md`).
- FLAC is a lossless compact batch transport: same 16 kHz mono PCM16 source,
  encoded locally with the pure-Swift `FLACEncoder` (fixed predictors +
  Rice coding, no extra dependency), so recognition quality is preserved by
  construction and verified by round-trip tests. `upload_format = "flac"`
  selects it where the profile declares support and falls back to WAV
  elsewhere.
- Format selection (`AudioTransportSelection.resolve`) never returns a codec
  outside `supportedUploadFormats`.
- Opus stays explicitly experimental: no local encoder ships, so it is
  never auto-selected and an explicit `upload_format = "opus"` (alias
  `"opus-experimental"`) resolves to WAV until benchmark evidence justifies
  stronger support.
- Source audio is never upmixed to preserve a container: no 48 kHz stereo
  is sent to 16 kHz mono Whisper-style models.

Configuration (`upload_format`: `auto` | `wav` | `flac` |
`opus`/`opus-experimental`, default `auto`): top-level key plus optional
per-provider override (`[providers.groq] upload_format = "flac"`; empty
inherits the top level). Effective format for a request:
`AppConfig.effectiveUploadFormat(adapterID:model:)` — config preference
through the model profile capabilities.

## Conservative fallback for custom OpenAI-compatible endpoints

Unknown provider ids (custom `base_url`/`model` sections, including the
historic `airubiz`, `gigaam` and `selfhosted` names) resolve to a
conservative OpenAI-compatible profile:

- batch multipart upload, flat `{"text": ...}` response;
- **never** sends `response_format=verbose_json`,
  `timestamp_granularities[]`, `vad_filter`, Whisper thresholds,
  keyword lists, or multi-language hints — the endpoint is not assumed to
  implement them;
- sends `model`, `file`, single `language` (only when configured),
  `prompt` (only when provided) and `temperature` (batch path only);
- audio: 16 kHz mono WAV.

Rationale: an unsupported parameter must never be sent merely because
another model in the same provider family supports it. If a custom
endpoint does support `verbose_json`, add an explicit profile entry for
its model instead of widening the fallback.

## Migration note

Previously every `openai`-id model received `verbose_json` + word
granularities, and every `groq`-id model received `verbose_json`. Word
timestamps are now opt-in per processing mode (`needsWordTimestamps`):
normal single-request push-to-talk and whole-utterance final passes send
plain transcription; only chunked/live segment requests ask for
`verbose_json` + word granularities, and only profiles that support them
(`whisper-1` family, Groq verbose without granularities) emit those
fields. Unknown models under those ids resolve to the conservative family
fallback (no verbose/timestamps assumed); pin the model name to a known
entry if the old parameter set is required.

### OpenAI modern batch profile (`gpt-transcribe`)

- Default when `[providers.openai] model` is empty; recommended for all new
  configurations.
- Sends only supported fields: `file`, `model`, `prompt` (when provided),
  `languages[]` (single entry mapped from the configured `language`; omitted
  when empty). Never sends `response_format`, `timestamp_granularities[]`,
  `temperature`, `vad_filter`, thresholds, or the legacy singular
  `language`.
- Response is flat JSON (`{"text": ...}` plus detected `languages` metadata,
  which the parser ignores); parsing is identical to other flat-text
  profiles.
- Explicit `model = "whisper-1"` remains a compatibility path with the
  previous parameter set (timestamps only on request as above). It is
  deprecated upstream with removal scheduled for 2027-02-26, alongside the
  `gpt-4o-transcribe` family: existing integrations keep working through the same
  capability gating; prefer `gpt-transcribe` for new setups.

Manual integration validation (no secrets in CI): set the OpenAI key via
`nanodictate config set-key openai`, select the provider
(`nanodictate provider use openai`), keep `log_level = "debug"` for
request/response correlation, then capture the actual outgoing multipart
request body with a local HTTP proxy (for example mitmproxy) while running
one real request (`nanodictate transcribe <wav>` or a push-to-talk
utterance) against the default model and once with
`model = "whisper-1"`; both must return text. Inspect the captured
multipart body directly — not only the `transcriber-debug.log`
selected-fields dump, which lists just `model`/`language(s)`/`prompt` and
cannot prove a field is absent — and verify the default request body
contains neither `response_format` nor `timestamp_granularities[]`.
