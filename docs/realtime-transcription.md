# Realtime vs batch transcription

This document defines the two transcription modes, the session lifecycle and
the error/reconnect policy for the stateful realtime backend. It was written
before coding (DoR requirement) and verified against the official OpenAI
realtime-transcription guide on 2026-10-01.

## Modes

| | Batch | Realtime (stateful) |
|---|---|---|
| Transport | One HTTP request per audio (`batchMultipart`, `batchRawAudio`) | One WebSocket session per dictation (`streamingSession`) |
| Audio | 16 kHz mono WAV (`STTAudioProfile.batchMono16k`) | 24 kHz mono raw PCM16 (`STTAudioProfile.realtimeMono24kPCM`), base64 chunks, no WAV header |
| Model state | None across chunks; overlap/deduplication + optional final full-recording pass | Model keeps state for the whole session; earlier-turn context is not documented as automatic; use `prompt` and `keywords` as transcription hints |
| Events | Single `{"text": ...}` response | `conversation.item.input_audio_transcription.delta` (partial) + `.completed` (final, authoritative) per `item_id` |
| Providers | All batch profiles (OpenAI `whisper-1`/`gpt-transcribe`/`gpt-4o-*`, Groq, Cloudflare, custom) | OpenAI `gpt-live-transcribe` family only (today) |

Batch behavior is unchanged. Realtime is selected by the model profile
(`STTModelRegistry.isRealtime(adapterID:model:)`), never by a runtime sniff.

## Provider requirements (realtime)

- Provider id `openai`, model `gpt-live-transcribe` (or `gpt-live-*` snapshot).
- WebSocket endpoint `wss://api.openai.com/v1/realtime?intent=transcription`
  with `Authorization: Bearer <key>`.
- Realtime bypasses custom routing: configured `base_url`, `http_proxy`
  (`httpProxy`), `proxy_key` (`proxyKey`), and `cookie-relay` transport do
  not apply to the WebSocket session. Audio and the API key always go
  directly to the fixed endpoint above; a conflicting configuration logs a
  warning (`Transcriber.transcribeViaRealtime`) instead of failing silently.
- Session configuration (`session.update`, type `transcription`):
  `audio.input.format = {"type": "audio/pcm", "rate": 24000}`,
  `audio.input.transcription = {model, prompt?, keywords?, languages?, delay?}`,
  `audio.input.turn_detection = null` (client-side VAD; server VAD unsupported
  for `gpt-live-transcribe`).
- `gpt-transcribe` stays a **batch** profile. It can technically run inside a
  realtime session for committed-turn transcription, but this codebase keeps it
  on the batch path so existing behavior (multipart, `languages[]`, prompt
  chaining, final pass) is preserved. Use `gpt-live-transcribe` for streaming.
- `gpt-live-transcribe` returns no word timestamps, speaker labels, or
  confidence scores. Applications needing them must use a batch/file model.

## Session lifecycle (one per dictation)

```
idle --connect()--> connecting --ack--> ready --appendAudio()--> streaming
  --commit()--> committing --completed--> closed --close()--> (transport closed)
```

- `connect()`: sends `session.update`, waits for `session.created` /
  `session.updated` within `RealtimeSessionPolicy.connectTimeout`.
- `appendAudio(_:sourceSampleRate:)`: resamples to 24 kHz (linear), splits
  into `maxSamplesPerAppend` chunks, sends ordered
  `input_audio_buffer.append` messages. No WAV files are written. The whole
  send phase is bounded by `appendTimeout` (all chunks share the budget).
- `commit()`: sends `input_audio_buffer.commit` (end of turn), bounded by
  its own separate `appendTimeout` budget (one budget for all append chunks,
  another one for the commit send).
- `waitForFinal()` / `runToCompletion()`: consumes delta/completed events
  until the deterministic final transcript.
- `close()` / `cancel()`: deterministic teardown, transport closed exactly
  once. `cancel()` from any state moves to `.cancelled` and blocks further
  append/commit.

Partial display text (`partialText`) is completed items plus pending deltas in
first-seen `item_id` order. A `completed` transcript replaces its item's delta
buffer, so partials never duplicate committed text. The final transcript
(`finalText`) joins completed items with single spaces in first-seen order and
is deterministic after stop/session completion.

## Error / reconnect / timeout policy

- Every wait is bounded (`connectTimeout`, `appendTimeout`, `commitTimeout`,
  `closeTimeout`). Audio appends and the commit send each get their own
  `appendTimeout` budget, so a stalled upload cannot outlive the caller's
  watchdog (connect + 2 x append + final wait + close + margin). Task
  cancellation closes the transport up front instead
  of waiting for a stalled send to return.
  Timeouts throw `RealtimeTranscriptionError.timeout`; Task cancellation
  throws `.cancelled`. Neither wedges `AudioService` nor the UI.
- Provider errors (`error` event, `...transcription.failed`) move the session
  to `.failed` with `lastErrorMessage` preserved and surface
  `.sessionFailed`. The failed session never retries the same audio silently.
- No automatic reconnect. A transport drop that yields no transcript leaves
  the session `.failed` with `lastErrorMessage` preserved (this includes a
  missing session ack at connect time and a dropped transport while waiting
  for completion); reconnecting or restarting the dictation
  is the caller's responsibility. When a final or partial transcript is
  already buffered, `waitForFinal()` / `runToCompletion()` return it instead
  of throwing. Already-sent audio is NOT re-uploaded
  automatically; the caller decides whether to restart the dictation.
- **No silent batch fallback.** `ProviderRequestBuilder.plan` for a streaming
  profile returns an invalid spec (`url == nil`) instead of a multipart body.
  `RealtimeFallbackPolicy` defaults to `.failClosed`: a failed realtime
  session surfaces an error. Batch transcription of the full audio happens
  only when the caller explicitly selects `.allowBatch` for that dictation.

## Implementation map

- `Sources/NanoDictateCore/RealtimeTranscription.swift`: event parser,
  accumulator, PCM converter/resampler, client event builders, endpoint,
  `RealtimeTranscriptionSession` actor.
- `Sources/NanoDictateCore/RealtimeTransport.swift`: `RealtimeTransport`
  protocol, `RealtimeReceiveChannel` receive channel, `URLSessionWebSocketTransport`.
- `Sources/NanoDictateCore/STTCapabilities.swift`: `STTUploadFormat.pcm16`,
  `STTAudioProfile.realtimeMono24kPCM`, `STTTransportKind.streamingSession`
  (now implemented), `gpt-live-transcribe` registry entry.
- `Sources/NanoDictateCore/STTAdapter.swift`: batch `plan` refuses streaming
  profiles (nil URL) so the batch path cannot duplicate realtime audio.
- `Tests/NanoDictateCoreTests/RealtimeTranscriptionTests.swift`: event parsing,
  accumulator, payload builders, resampling, and session state with a mocked
  transport.
