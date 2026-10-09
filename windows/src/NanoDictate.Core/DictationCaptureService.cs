namespace NanoDictate.Core;

/// <summary>
/// Repeated-session dictation capture service: binds an <see
/// cref="IAudioCaptureSource"/> (WASAPI in production, synthetic in
/// tests) to a <see cref="RealtimeAudioPipeline"/> driving the shared
/// Rust session state machine.
///
/// Lifecycle mirrors the macOS AudioService session rules:
/// <list type="bullet">
/// <item><c>Start</c> success means "engine started", not "capture
/// ready": gate the start cue on <see cref="CaptureReady"/> (first valid
/// block), never on <c>Start</c> alone.</item>
/// <item>A source start failure drives <c>EngineFailed</c> into the Rust
/// session and rethrows: the session returns to Idle, ready for retry.</item>
/// <item>A device change mid-capture aborts the session (old format would
/// yield silence or desync); the client restarts with one command.</item>
/// <item>Repeated start/stop cycles reuse the service: each <c>Start</c>
/// bumps the Rust generation and creates fresh detector handles.</item>
/// </list>
/// </summary>
public sealed class DictationCaptureService : IDisposable
{
    private readonly object _gate = new();
    private readonly IAudioCaptureSource _source;
    private readonly RealtimeAudioPipeline _pipeline;
    private bool _disposed;
    private Exception? _deviceError;

    public DictationCaptureService(IAudioCaptureSource source)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        _pipeline = new RealtimeAudioPipeline(source.Format);
        _source.BlockAvailable += OnBlock;
        _source.DeviceChanged += OnDeviceChanged;
        _pipeline.CaptureReady += m => CaptureReady?.Invoke(m);
        _pipeline.AutoStop += samples => AutoStop?.Invoke(samples);
    }

    /// <summary>Fired exactly once per session on the first valid block.</summary>
    public event Action<CaptureMetrics>? CaptureReady;

    /// <summary>Fired at most once per session when Rust auto-stop fires.</summary>
    public event Action<IReadOnlyList<short>>? AutoStop;

    /// <summary>Fired when the OS device changed mid-capture (session aborted).</summary>
    public event Action<Exception>? DeviceChanged;

    public bool IsRunning => _pipeline.IsSessionLive;

    public bool IsCaptureReady => _pipeline.IsCaptureReady;

    public ulong Generation => _pipeline.Generation;

    public DictationState State => _pipeline.State;

    public CaptureMetrics Snapshot() => _pipeline.Snapshot();

    /// <summary>
    /// Starts one dictation session: the Rust session first, then OS
    /// capture. A source failure reports <c>EngineFailed</c> and rethrows.
    /// </summary>
    public void Start(ulong? triggerNanos = null)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            _deviceError = null;
        }
        _pipeline.Start(triggerNanos);
        try
        {
            _source.Start();
        }
        catch
        {
            _pipeline.FailStart();
            throw;
        }
    }

    /// <summary>
    /// Stops OS capture and the Rust session; returns the recording with
    /// engine-planned live segments. After a device-change abort this
    /// harvests whatever was captured before the abort; with nothing
    /// captured it returns an empty recording instead of throwing.
    /// </summary>
    public PipelineStopResult Stop()
    {
        try
        {
            _source.Stop();
        }
        finally
        {
            // Pipeline stop owns the session transition even when the
            // source stop throws.
        }
        if (IsRunning)
        {
            return _pipeline.Stop();
        }
        if (_pipeline.TryHarvestAborted(out var aborted))
        {
            return aborted;
        }
        var snapshot = _pipeline.Snapshot();
        return new PipelineStopResult(
            Array.Empty<short>(), Array.Empty<NanoEngine.LiveSegment>(), snapshot);
    }

    /// <summary>Cancels the live session without producing a recording.</summary>
    public void Cancel()
    {
        try
        {
            _source.Stop();
        }
        finally
        {
            _pipeline.Cancel();
        }
    }

    /// <summary>Completes transcription after <see cref="Stop"/>.</summary>
    public void FinishTranscription() => _pipeline.FinishTranscription();

    private void OnBlock(CapturedBlock block)
    {
        _pipeline.IngestDeviceBlock(block);
    }

    private void OnDeviceChanged(Exception error)
    {
        lock (_gate)
        {
            _deviceError = error;
        }
        try
        {
            _source.Stop();
        }
        catch
        {
            // Best effort: the session abort below is authoritative.
        }
        _pipeline.Cancel();
        DeviceChanged?.Invoke(error);
    }

    /// <summary>Device error that aborted the session, if any.</summary>
    public Exception? DeviceError
    {
        get { lock (_gate) { return _deviceError; } }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(DictationCaptureService));
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
        }
        _source.BlockAvailable -= OnBlock;
        _source.DeviceChanged -= OnDeviceChanged;
        try
        {
            _source.Stop();
        }
        catch
        {
            // Best effort.
        }
        _pipeline.Dispose();
        _source.Dispose();
    }
}
