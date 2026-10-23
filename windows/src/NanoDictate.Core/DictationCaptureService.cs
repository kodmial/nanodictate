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

    // Tracks the capture source session ID at the time the source was
    // successfully started. Used to ignore stale DeviceChanged notifications
    // from a previous session that arrive after a new session has begun.
    private ulong _sourceSessionId;

    public DictationCaptureService(IAudioCaptureSource source)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        _pipeline = new RealtimeAudioPipeline(source.Format);
        _source.BlockAvailable += OnBlock;
        _source.DeviceChanged += OnDeviceChanged;
        _pipeline.CaptureReady += m => CaptureReady?.Invoke(m);
        _pipeline.AutoStop += samples => AutoStop?.Invoke(samples);
        _pipeline.RawRmsAvailable += rms => RawRmsAvailable?.Invoke(rms);
    }

    /// <summary>Fired exactly once per session on the first valid block.</summary>
    public event Action<CaptureMetrics>? CaptureReady;

    /// <summary>Fired at most once per session when Rust auto-stop fires.</summary>
    public event Action<IReadOnlyList<short>>? AutoStop;

    /// <summary>Coalesced latest raw RMS for HUD metering (no PCM copy).</summary>
    public event Action<float>? RawRmsAvailable;

    /// <summary>Fired when the OS device changed mid-capture (session aborted).</summary>
    public event Action<Exception>? DeviceChanged;

    public bool IsRunning => _pipeline.IsSessionLive;

    public bool IsCaptureReady => _pipeline.IsCaptureReady;

    public ulong Generation => _pipeline.Generation;

    public DictationState State => _pipeline.State;

    /// <summary>
    /// Lock-free session-state snapshot for the keyboard hook. Mirrors
    /// <see cref="RealtimeAudioPipeline.CachedState"/> so the swallow decision
    /// never blocks on audio work holding the pipeline lock.
    /// </summary>
    public DictationState CachedState => _pipeline.CachedState;

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

        // Record the source session ID at which the source successfully started.
        // Any DeviceChanged notification with a different session ID is stale
        // and will be ignored in OnDeviceChanged.
        _sourceSessionId = _source.SessionId;
    }

    /// <summary>
    /// Stops OS capture and the Rust session; returns the recording with
    /// engine-planned live segments. After a device-change abort this
    /// harvests whatever was captured before the abort; with nothing
    /// captured it returns an empty recording instead of throwing.
    /// </summary>
    public PipelineStopResult Stop()
    {
        Exception? sourceError = null;
        try
        {
            _source.Stop();
        }
        catch (Exception ex)
        {
            sourceError = ex;
        }
        PipelineStopResult result;
        if (IsRunning)
        {
            result = _pipeline.Stop();
        }
        else if (_pipeline.TryHarvestAborted(out var aborted))
        {
            result = aborted;
        }
        else
        {
            var snapshot = _pipeline.Snapshot();
            result = new PipelineStopResult(
                Array.Empty<short>(), Array.Empty<NanoEngine.LiveSegment>(), snapshot);
        }
        if (sourceError is not null)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(sourceError).Throw();
        }
        return result;
    }

    /// <summary>
    /// Cancels a live Recording session without producing a recording.
    /// After <see cref="Stop"/> the session is Transcribing and must be
    /// completed with <see cref="FinishTranscription"/>; this call is then a
    /// deliberate no-op because Rust <c>Cancelled</c> is Recording-only.
    /// </summary>
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

    private void OnDeviceChanged(ulong sessionId, Exception error)
    {
        // Ignore stale DeviceChanged notifications from a previous session.
        // If the source session ID has advanced since the source started,
        // this error belongs to an older session and must not abort the current one.
        if (sessionId != _sourceSessionId)
        {
            return;
        }

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
        _pipeline.Abort();
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
