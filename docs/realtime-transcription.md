# Realtime vs batch transcription

Two transcription modes exist. The mode is selected by the concrete
provider + model profile (`STTModelRegistry.resolve`), never by ad-hoc
branching at call sites.

## Batch mode (default, regression-safe)

- One HTTP request per audio: OpenAI-compatible multipart (`file`, `model`,
  optional `language`/`languages[]`/`prompt`) or Cloudflare raw WAV.
- Used by every built-in profile except the OpenAI `gpt-live-transcribe`
  family: `whisper-1`, `gpt-transcribe`, `gpt-4o-transcribe`, Groq Whisper,
  Cloudflare, and all custom OpenAI-compatible endpoints.
- Chunked/live stepwise dictation stitches independent batch requests with
  overlap dedup and a final whole-recording pass (`ChunkedPipeline`).
- Audio: 16 kHz mono WAV (`STTAudioProfile.batchMono16k`).

Batch behavior is unchanged by the realtime addition. Batch providers keep
exactly the previous request format, retry policy, and fallback semantics.

## Realtime mode (stateful streaming)

- One stateful WebSocket session per dictation
  (`RealtimeTranscriptionSession` + `RealtimeWebSocketTransport`).
- Supported profile: `[providers.openai]` with `model = "gpt-live-transcribe"`
  (dated snapshots such as `gpt-live-transcribe-2026-01-01` match by prefix).
- Wire schema verified against the official realtime transcription guide
  (2026-09):
  - connect `wss://api.openai.com/v1/realtime?intent=transcription` with
    `Authorization: Bearer <key>` and `OpenAI-Beta: realtime=v1`;
  - `session.update` with `type: "transcription"`,
    `audio.input.format = { type: "audio/pcm", rate: 24000 }`,
    `audio.input.transcription = { model, prompt?, languages?, keywords? }`,
    `turn_detection: null` (manual commit for push-to-talk dictation);
  - stream `input_audio_buffer.append` with base64 raw PCM16;
  - `input_audio_buffer.commit` at stop to request the final transcript;
  - consume `conversation.item.input_audio_transcription.delta`
    (partial text) and `.completed` (authoritative per-turn transcript).
- Audio: 24 kHz mono raw PCM16 little-endian, no WAV header
  (`STTAudioProfile.realtimeMono24k`). Microphone audio (16 kHz Int16) is
  upsampled with `RealtimeAudioConverter.upscale16kTo24k`. The 16 kHz batch
  profile is never forced onto the realtime path.
- Partials never duplicate committed text: the accumulator keeps per-item
  delta buffers, and each `.completed` transcript replaces (not appends to)
  its pending deltas. Late duplicate completions are ignored, so the final
  transcript is deterministic after stop/session completion.
- Microphone audio streams continuously: no independent WAV chunks, no
  overlap stitching, no second full-recording pass when streaming is used.

## Session lifecycle and error/reconnect policy

1. `start()`: connect, send `session.update`, enter `.ready`, start the
   receive loop. Calling `start()` twice throws.
2. `appendAudio(samples16k:)`: stream continuously from a background task
   (never from the realtime audio-tap callback directly). Each call
   upsamples to 24 kHz and sends one or more `append` events.
3. `stop()`: send `commit`, wait for the completion (bounded by
   `timeoutSeconds`), close the transport, return the deterministic final
   transcript (committed turns only). `cancel()`: drop buffered audio,
   close immediately, discard the transcript.
4. Teardown is deterministic and idempotent: `stop()`/`cancel()`/`close()`
   never block the audio thread, never wedge `AudioService` or the UI, and
   are safe to call from any state (wrong-state calls throw
   `invalidState` instead of hanging).
5. No automatic reconnect inside a dictation: a transport, timeout, or
   provider error moves the session to `.failed` and the session must be
   discarded. The next dictation opens a fresh session (fresh item IDs).
   Reconnecting mid-stream would duplicate or reorder committed turns.
6. No silent fallback: a failed realtime session surfaces
   `RealtimeSessionError` (network / provider / timeout / cancelled). It
   never degrades implicitly into repeated batch uploads. Callers opt in
   explicitly via `RealtimeFallbackPolicy.batchOnce` (exactly one batch
   request, never a retry loop); the default is `.fail`.

## Provider requirements

- Realtime requires an OpenAI provider section with a live-transcribe model
  and a valid API key:
  `base_url` empty (adapter default) or `https://api.openai.com/v1/audio/transcriptions`
  is irrelevant for streaming (the WebSocket URL is fixed); `model =
  "gpt-live-transcribe"` selects streaming. Any other model stays on batch.
- `language` maps to the session `languages` array (empty = auto-detect,
  omitted). `prompt` maps to the session transcription prompt; `keywords`
  map to session keyword biasing.
- Non-streaming providers (Groq, Cloudflare, custom endpoints) always use
  batch; configuring them never opens a WebSocket.

## Testing

Integration-level coverage with a mocked transport
(`Tests/NanoDictateCoreTests/RealtimeTranscriptionTests.swift`): event
parsing, accumulator dedup, session state machine, continuous streaming
without WAV headers, deterministic final transcript, cancellation,
timeout, and provider-error paths. The batch suite is untouched and must
keep passing unchanged.
