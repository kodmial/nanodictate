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

| Provider id | Model(s) | Transport | verbose_json | word granularities | prompt | temperature | vad_filter | language hint | transcript path |
|---|---|---|---|---|---|---|---|---|---|
| `openai` | `whisper-1`, `whisper-*` | batch multipart | yes | yes (`word`) | yes | yes | no | single | flat `text` |
| `openai` | `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-*` | batch multipart | no | no | yes | no | no | single | flat `text` |
| `openai` | unknown (fallback) | batch multipart | no | no | yes | yes | no | single | flat `text` |
| `groq` | `whisper-large-v3`, `whisper-large-v3-turbo`, `distil-whisper-large-v3-en`, `whisper-*` | batch multipart | yes | no (Groq rejects the field with HTTP 400) | yes | yes | yes (server-side VAD) | single | flat `text` |
| `groq` | unknown (fallback) | batch multipart | no | no | yes | yes | no | single | flat `text` |
| `cloudflare` | any (model baked into URL) | batch raw WAV (`audio/wav`) | no | no | no | no | no | none | `result.text` |
| `airubiz` / `gigaam` / `selfhosted` / custom | any | batch multipart (conservative fallback below) | no | no | yes | yes | no | single | flat `text` |

Audio requirements for every built-in profile: 16 kHz mono WAV
(`STTAudioProfile.batchMono16k`). The profile struct carries
`sampleRate` / `channels` / `uploadFormat` so future models with different
requirements only change the registry entry; `streamingSession` transport,
`multi` language hints, keyword biasing, segment timestamps,
server-side chunking and noise reduction are modeled in
`STTCapabilities` as reserved fields (all `false` / unused today).

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
granularities, and every `groq`-id model received `verbose_json`. Known
models above keep byte-identical requests. Unknown models under those ids
now resolve to the conservative family fallback (no verbose/timestamps
assumed); pin the model name to a known entry if the old parameter set
is required.
