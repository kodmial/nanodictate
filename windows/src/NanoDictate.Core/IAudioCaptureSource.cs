namespace NanoDictate.Core;

/// <summary>
/// One captured device block: interleaved Float32 frames plus the device
/// format they were captured in. The pipeline normalizes these into the
/// agreed 16 kHz mono engine ingress; sources never resample themselves.
/// </summary>
public readonly record struct CapturedBlock(float[] InterleavedFrames, int FrameCount, AudioFormat Format);

/// <summary>
/// Windows-native microphone capture abstraction. Production uses
/// <see cref="WasapiCaptureSource"/> (WASAPI shared-mode capture);
/// tests and non-Windows hosts use <see cref="SyntheticCaptureSource"/>.
/// The pipeline drives the same Rust session state machine regardless
/// of which source feeds it.
/// </summary>
public interface IAudioCaptureSource : IDisposable
{
    /// <summary>Device format of the blocks this source emits.</summary>
    AudioFormat Format { get; }

    /// <summary>True while the OS capture client is running.</summary>
    bool IsRunning { get; }

    /// <summary>
    /// Fired on the capture thread for every captured block, starting
    /// with the first device packet (never dropped). Handlers must be
    /// light: copy or ingest synchronously, never block.
    /// </summary>
    event Action<CapturedBlock>? BlockAvailable;

    /// <summary>
    /// Fired when the default device changed mid-capture. The pipeline
    /// must stop the session: continuing on the old format would yield
    /// silence or sample desync (mirrors the macOS device-change rule).
    /// </summary>
    event Action<Exception>? DeviceChanged;

    /// <summary>
    /// Starts OS capture. Throws <see cref="NanoException"/> on start
    /// failures (no device, format unsupported, client init failed) and
    /// <see cref="PlatformNotSupportedException"/> on non-Windows for
    /// the WASAPI source. A failed start leaves the source stopped and
    /// reusable for a later retry.
    /// </summary>
    void Start();

    /// <summary>Stops OS capture. Idempotent; safe to call when stopped.</summary>
    void Stop();
}
