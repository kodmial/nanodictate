import Foundation

// MARK: - One-shot realtime dictation (ordinary push-to-talk over streaming)

/// One-shot ordinary dictation over a stateful realtime session.
///
/// Batch callers keep using `Transcriber.transcribe` (which rejects
/// `.streamingSession` profiles with an invalid `STTRequestSpec`); ordinary
/// push-to-talk with a realtime profile (today: `gpt-live-transcribe`) runs
/// here: raw PCM samples stream through `RealtimeTranscriptionSession`
/// (connect -> append -> commit -> final), never as a WAV batch upload.
/// Fail-closed: a realtime failure surfaces and never falls back to batch.
public enum RealtimeDictationRunner {
  /// Transcribe already-captured PCM samples via a realtime session.
  /// - Parameters:
  ///   - samples: microphone PCM samples at `sourceSampleRate`.
  ///   - sourceSampleRate: capture rate of `samples` (resampled to 24 kHz).
  ///   - config/policy: session configuration.
  ///   - transport: WebSocket transport (production:
  ///     `URLSessionWebSocketTransport`; tests inject a mock).
  public static func transcribe(
    samples: [Int16],
    sourceSampleRate: Int = 16000,
    config: RealtimeSessionConfig,
    policy: RealtimeSessionPolicy = RealtimeSessionPolicy(),
    transport: RealtimeTransport
  ) async throws -> TranscriptionResult {
    let session = RealtimeTranscriptionSession(
      transport: transport, config: config, policy: policy, fallback: .failClosed)
    // Same cancellation contract as Transcriber.transcribeViaRealtime: close
    // the transport up front so a stalled send cannot outlive cancellation.
    do {
      return try await withTaskCancellationHandler {
        try await session.connect()
        try await session.appendAudio(samples, sourceSampleRate: sourceSampleRate)
        try await session.commit()
        let text = try await session.waitForFinal()
        await session.close()
        return TranscriptionResult(text: text, rawData: Data(text.utf8))
      } onCancel: {
        Task { await session.cancel() }
      }
    } catch {
      await session.close()
      throw error
    }
  }
}
