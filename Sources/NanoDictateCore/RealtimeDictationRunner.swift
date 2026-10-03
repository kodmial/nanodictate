import Foundation

// MARK: - One-shot realtime dictation (ordinary push-to-talk over streaming)

/// One-shot ordinary dictation over a stateful realtime session.
///
/// Production entry point is `Transcriber.transcribe(wav:)` (which rejects
/// `.streamingSession` profiles with an invalid `STTRequestSpec` on the batch
/// path and routes realtime profiles to `transcribeViaRealtime` below):
/// ordinary push-to-talk with a realtime profile (today:
/// `gpt-live-transcribe`) runs here through this runner — raw PCM samples
/// stream through `RealtimeTranscriptionSession`
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
    // Esc/watchdog cancellation must close the WebSocket immediately instead
    // of waiting for a stalled send to return: the handler cancels the
    // session (which closes the transport and unblocks suspended sends)
    // before the awaited operation observes cancellation.
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
    } catch is CancellationError {
      await session.cancel()
      throw CancellationError()
    } catch let error as RealtimeTranscriptionError {
      if case .cancelled = error {
        await session.cancel()
      } else {
        await session.close()
      }
      throw error
    } catch {
      // Concurrent cancellation racing a failure must not flip `.cancelled`
      // back to `.closed`: cancelling preserves the terminal state.
      if Task.isCancelled {
        await session.cancel()
      } else {
        await session.close()
      }
      throw error
    }
  }
}
