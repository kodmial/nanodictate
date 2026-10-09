using System.Diagnostics;

namespace NanoDictate.Core;

/// <summary>
/// Block-oriented shared-engine ingress for Windows dictation capture.
///
/// This is the Windows counterpart of the macOS <c>RustRealtimeAudio</c>
/// shipping path: every realtime decision (per-block RMS metrics, adaptive
/// VAD on the raw/pre-gain signal, AGC input gain applied in place, and
/// the silence auto-stop decision fed with the VAD hint) executes through
/// the shared Rust engine. No Rust algorithm is forked in C#: the pipeline
/// only marshals blocks, drives the session state machine, and stages PCM.
///
/// Ingress order per engine block (16 kHz mono Float32, 100 ms):
/// raw RMS (<c>nd_rms_f32</c>) on the pre-gain signal, then the adaptive
/// VAD decision (<c>nd_vad_feed_samples</c>), then AGC applied in place
/// (<c>nd_gain_apply</c>), then the auto-stop feed with the VAD hint
/// (<c>nd_autostop_feed</c>). The amplified signal feeds the recording;
/// VAD and auto-stop always consume the raw value.
///
/// Capture-readiness latch (same invariant as macOS): <c>Start</c> alone
/// never reports readiness. Readiness fires exactly once per session, on
/// the first valid engine block of the current generation, and lapses on
/// stop/cancel/failure. Stale generations are rejected by the engine.
///
/// Realtime bounds: per-block work is O(n) math with no allocation beyond
/// the block itself, no I/O, and no network work. The single instance
/// lock is held across conversion, staging, and per-block engine
/// composition because the handles are not thread-safe; engine errors
/// drop the block fail-closed (counted, never Swift/C#-processed), and
/// CaptureReady/AutoStop handlers always run after the lock is released.
/// </summary>
public sealed class RealtimeAudioPipeline : IDisposable
{
    /// <summary>Engine block: 1600 samples = 100 ms at 16 kHz.</summary>
    public const int EngineBlockSamples = 1600;

    private const uint EngineSampleRate = 16000;

    private readonly object _gate = new();
    private readonly SessionHandle _session = new();
    private readonly AudioFormatConverter _converter;
    private readonly float[] _staging;
    private int _staged;

    private VadHandle? _vad;
    private GainHandle? _gain;
    private AutoStopHandle? _stop;

    private bool _sessionLive;
    private ulong _generation;
    private bool _captureReadyFired;
    private bool _autoStopFired;
    private bool _disposed;

    private ulong _requestNanos;
    private ulong _engineStartedNanos;
    private ulong _firstBufferNanos;
    private ulong? _triggerNanos;

    private int _blocksIngested;
    private int _engineErrors;
    private ulong _totalBlockNanos;
    private ulong _maxBlockNanos;
    private long _deviceFramesConsumed;
    private long _engineSamplesEmitted;

    private readonly List<short> _collected = new();
    private TimeSpan _startCpu;
    private bool _started;

    /// <summary>Fired exactly once per session when the first valid block lands.</summary>
    public event Action<CaptureMetrics>? CaptureReady;

    /// <summary>Fired at most once per session when the Rust auto-stop detector fires.</summary>
    public event Action<IReadOnlyList<short>>? AutoStop;

    public RealtimeAudioPipeline(AudioFormat deviceFormat)
    {
        deviceFormat.Validate();
        _converter = new AudioFormatConverter(deviceFormat);
        _staging = new float[EngineBlockSamples];
    }

    public bool IsSessionLive
    {
        get { lock (_gate) { return _sessionLive; } }
    }

    public bool IsCaptureReady
    {
        get { lock (_gate) { return _sessionLive && _captureReadyFired && _session.IsCaptureReady; } }
    }

    public ulong Generation
    {
        get { lock (_gate) { return _generation; } }
    }

    public DictationState State
    {
        get { lock (_gate) { return _session.State; } }
    }

    public int BlocksIngested
    {
        get { lock (_gate) { return _blocksIngested; } }
    }

    public int CollectedSampleCount
    {
        get { lock (_gate) { return _collected.Count; } }
    }

    public bool AutoStopFired
    {
        get { lock (_gate) { return _autoStopFired; } }
    }

    /// <summary>
    /// Starts a new dictation session: bumps the Rust generation, clears
    /// readiness, and creates fresh VAD/gain/auto-stop handles so every
    /// session starts from clean detector state.
    /// </summary>
    public void Start(ulong? triggerNanos = null)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            NanoEngine.CheckAvailable();
            DisposeHandlesLocked();

            _vad = new VadHandle();
            _gain = new GainHandle();
            _stop = new AutoStopHandle();

            _converter.Reset();
            _collected.Clear();
            _staged = 0;
            _captureReadyFired = false;
            _autoStopFired = false;
            _blocksIngested = 0;
            _engineErrors = 0;
            _totalBlockNanos = 0;
            _maxBlockNanos = 0;
            _deviceFramesConsumed = 0;
            _engineSamplesEmitted = 0;

            _triggerNanos = triggerNanos;
            _requestNanos = CaptureClock.Nanos;
            _generation = _session.Start();
            _session.OnEvent(SessionEvent.EngineStarted, _generation);
            _engineStartedNanos = CaptureClock.Nanos;
            _firstBufferNanos = 0;
            _sessionLive = true;
            _started = true;
            try
            {
                _startCpu = Process.GetCurrentProcess().TotalProcessorTime;
            }
            catch
            {
                _startCpu = TimeSpan.Zero;
            }
        }
    }

    /// <summary>
    /// Ingests one device-format block from the capture thread. Converts
    /// to 16 kHz mono, accumulates full engine blocks, and drives the
    /// Rust composition per block. The first device packet is converted
    /// and ingested synchronously: no warm-up frames are dropped.
    /// </summary>
    public void IngestDeviceBlock(CapturedBlock block)
    {
        // Conversion, staging, and per-block engine composition run as one
        // _gate-protected operation: the resample phase, the staging
        // buffer, and the session latches are shared with
        // Start/Stop/Cancel/HarvestTailLocked, so no Stop/Cancel/Start can
        // interleave between staging a full block and driving it through
        // the engine. Event payloads are collected under the lock and the
        // CaptureReady/AutoStop handlers run after it is released.
        var capacity = Math.Max(
            EngineBlockSamples * 2,
            (int)((long)block.FrameCount * EngineSampleRate / Math.Max(1, block.Format.SampleRate)) + 16);
        var outBuffer = new float[capacity];
        CaptureMetrics? readyToFire = null;
        IReadOnlyList<short>? stopToFire = null;
        lock (_gate)
        {
            var produced = _converter.Convert(
                block.InterleavedFrames.AsSpan(), block.FrameCount, outBuffer.AsSpan());
            _deviceFramesConsumed = _converter.DeviceFramesConsumed;
            _engineSamplesEmitted = _converter.EngineSamplesEmitted;
            var offset = 0;
            while (offset < produced)
            {
                var room = EngineBlockSamples - _staged;
                var take = Math.Min(room, produced - offset);
                Array.Copy(outBuffer, offset, _staging, _staged, take);
                _staged += take;
                offset += take;
                if (_staged == EngineBlockSamples)
                {
                    ulong start = CaptureClock.Nanos;
                    try
                    {
                        if (_sessionLive && _vad is not null && _gain is not null && _stop is not null)
                        {
                            ProcessEngineBlockLocked(
                                _staging.AsSpan(),
                                out var firedReady,
                                out var readyMetrics,
                                out var firedStop,
                                out var stopSnapshot);
                            if (firedReady && readyToFire is null)
                            {
                                readyToFire = readyMetrics;
                            }
                            if (firedStop && stopToFire is null && stopSnapshot is not null)
                            {
                                stopToFire = stopSnapshot;
                            }
                        }
                    }
                    catch (NanoException)
                    {
                        _engineErrors++;
                    }
                    finally
                    {
                        ulong elapsed = CaptureClock.Nanos - start;
                        _totalBlockNanos += elapsed;
                        if (elapsed > _maxBlockNanos)
                        {
                            _maxBlockNanos = elapsed;
                        }
                    }
                    _staged = 0;
                }
            }
        }
        if (readyToFire.HasValue)
        {
            CaptureReady?.Invoke(readyToFire.Value);
        }
        if (stopToFire is not null)
        {
            AutoStop?.Invoke(stopToFire);
        }
    }

    /// <summary>
    /// Runs the Rust composition for one full engine block. Caller holds
    /// <c>_gate</c>; the session is live and the handles are non-null.
    /// Fail-closed: engine errors propagate to the caller, which counts
    /// the dropped block. Event payloads are returned for invocation
    /// after the lock is released.
    /// </summary>
    private void ProcessEngineBlockLocked(
        Span<float> span,
        out bool firedReady,
        out CaptureMetrics readyMetrics,
        out bool firedStop,
        out IReadOnlyList<short>? stopSnapshot)
    {
        var rawRms = NanoEngine.RmsF32(span);
        var isSpeech = _vad!.FeedSamples(span, EngineSampleRate);
        // AGC conditions the block in place; the recording below
        // sees the amplified signal, VAD/auto-stop saw the raw one.
        var amplifiedRms = _gain!.Apply(span, rawRms, EngineSampleRate);
        var duration = (double)span.Length / EngineSampleRate;
        var shouldStop = _stop!.Feed(rawRms, duration, isSpeech);
        _ = amplifiedRms;

        // Stage amplified PCM for the recording (float -> int16).
        foreach (var s in span)
        {
            var clamped = Math.Clamp(s, -1.0f, 1.0f);
            _collected.Add((short)Math.Round(clamped * 32767.0f));
        }
        _blocksIngested++;

        firedReady = false;
        readyMetrics = CaptureMetrics.Empty;
        if (!_captureReadyFired)
        {
            _session.OnEvent(SessionEvent.FirstBuffer, _generation);
            _firstBufferNanos = CaptureClock.Nanos;
            _captureReadyFired = true;
            firedReady = true;
            readyMetrics = SnapshotLocked();
        }
        firedStop = false;
        stopSnapshot = null;
        if (shouldStop && !_autoStopFired)
        {
            _autoStopFired = true;
            firedStop = true;
            stopSnapshot = _collected.ToArray();
        }
    }

    /// <summary>
    /// Stops the session: flushes the converter remainder (no trailing
    /// samples dropped), drives StopRequested, and returns the recording
    /// with live segmentation from the shared engine.
    /// </summary>
    public PipelineStopResult Stop()
    {
        List<short> samples;
        CaptureMetrics metrics;
        lock (_gate)
        {
            ThrowIfDisposed();
            if (!_sessionLive)
            {
                throw new NanoException(-1, "no live session to stop");
            }
            // Flush trailing resample remainder as a final partial block.
            HarvestTailLocked();
            _session.OnEvent(SessionEvent.StopRequested, _generation);
            _sessionLive = false;
            samples = new List<short>(_collected);
            metrics = SnapshotLocked();
        }
        var segments = samples.Count > 0
            ? NanoEngine.LivePlan(
                System.Runtime.InteropServices.CollectionsMarshal.AsSpan(samples),
                EngineSampleRate)
            : Array.Empty<NanoEngine.LiveSegment>();
        return new PipelineStopResult(samples, segments, metrics);
    }

    private void AppendPartialLocked(float[] padded, int valid)
    {
        // Caller holds _gate. Runs the Rust composition on the ragged
        // tail without disturbing the first-buffer latch. The padding
        // past `valid` is silence (never fabricated speech); only the
        // true remainder is appended to the recording.
        if (_vad is null || _gain is null || _stop is null)
        {
            return;
        }
        try
        {
            var span = padded.AsSpan();
            var rawRms = NanoEngine.RmsF32(span);
            var isSpeech = _vad.FeedSamples(span, EngineSampleRate);
            _gain.Apply(span, rawRms, EngineSampleRate);
            _stop.Feed(rawRms, (double)padded.Length / EngineSampleRate, isSpeech);
            for (var i = 0; i < valid; i++)
            {
                var clamped = Math.Clamp(padded[i], -1.0f, 1.0f);
                _collected.Add((short)Math.Round(clamped * 32767.0f));
            }
            _blocksIngested++;
        }
        catch (NanoException)
        {
            _engineErrors++;
        }
    }

    /// <summary>Completes transcription after <see cref="Stop"/> (state -> Idle).</summary>
    public void FinishTranscription()
    {
        lock (_gate)
        {
            _session.OnEvent(SessionEvent.TranscriptionDone, _generation);
        }
    }

    /// <summary>Cancels the live session (state -> Idle, readiness suppressed).</summary>
    public void Cancel()
    {
        lock (_gate)
        {
            if (!_sessionLive)
            {
                return;
            }
            _session.OnEvent(SessionEvent.Cancelled, _generation);
            _sessionLive = false;
        }
    }

    /// <summary>
    /// Harvests whatever was captured before an abort (device change or
    /// cancel): flushes the converter remainder through the engine and
    /// returns the partial recording with engine-planned segments.
    /// Returns false when nothing was captured. Unlike <see cref="Stop"/>,
    /// this never drives session events: the session already ended.
    /// </summary>
    public bool TryHarvestAborted(out PipelineStopResult result)
    {
        List<short> samples;
        CaptureMetrics metrics;
        lock (_gate)
        {
            ThrowIfDisposed();
            if (_sessionLive || (_blocksIngested == 0 && _collected.Count == 0))
            {
                result = null!;
                return false;
            }
            HarvestTailLocked();
            samples = new List<short>(_collected);
            metrics = SnapshotLocked();
        }
        var segments = samples.Count > 0
            ? NanoEngine.LivePlan(
                System.Runtime.InteropServices.CollectionsMarshal.AsSpan(samples),
                EngineSampleRate)
            : Array.Empty<NanoEngine.LiveSegment>();
        result = new PipelineStopResult(samples, segments, metrics);
        return true;
    }

    /// <summary>
    /// Flushes the converter remainder into the recording through the
    /// engine (caller holds <c>_gate</c>).
    /// </summary>
    private void HarvestTailLocked()
    {
        var tail = new float[EngineBlockSamples];
        var tailCount = _converter.Flush(tail.AsSpan());
        if (tailCount > 0)
        {
            for (var i = 0; i < tailCount && _staged < EngineBlockSamples; i++)
            {
                _staging[_staged++] = tail[i];
            }
        }
        if (_staged > 0)
        {
            var partial = new float[_staged];
            Array.Copy(_staging, partial, _staged);
            var padded = new float[EngineBlockSamples];
            Array.Copy(partial, padded, _staged);
            _staged = 0;
            AppendPartialLocked(padded, partial.Length);
        }
    }

    /// <summary>Reports a capture start failure into the session (state -> Idle).</summary>
    public void FailStart()
    {
        lock (_gate)
        {
            if (!_sessionLive)
            {
                return;
            }
            _session.OnEvent(SessionEvent.EngineFailed, _generation);
            _sessionLive = false;
        }
    }

    public CaptureMetrics Snapshot()
    {
        lock (_gate)
        {
            return SnapshotLocked();
        }
    }

    private CaptureMetrics SnapshotLocked()
    {
        double? triggerToRequest = _triggerNanos.HasValue
            ? CaptureClock.MsBetween(_triggerNanos.Value, _requestNanos)
            : null;
        var requestToEngine = CaptureClock.MsBetween(_requestNanos, _engineStartedNanos);
        var engineToFirst = _firstBufferNanos > 0
            ? CaptureClock.MsBetween(_engineStartedNanos, _firstBufferNanos)
            : 0.0;
        var requestToFirst = _firstBufferNanos > 0
            ? CaptureClock.MsBetween(_requestNanos, _firstBufferNanos)
            : 0.0;
        var meanMs = _blocksIngested > 0
            ? (double)_totalBlockNanos / _blocksIngested / 1_000_000.0
            : 0.0;
        var maxMs = (double)_maxBlockNanos / 1_000_000.0;
        long cpuMs = 0;
        long rss = 0;
        if (_started)
        {
            try
            {
                var proc = Process.GetCurrentProcess();
                cpuMs = (long)(proc.TotalProcessorTime - _startCpu).TotalMilliseconds;
                rss = proc.WorkingSet64;
            }
            catch
            {
                // Diagnostics only; never fail the session.
            }
        }
        return new CaptureMetrics(
            triggerToRequest,
            requestToEngine,
            engineToFirst,
            requestToFirst,
            _blocksIngested,
            _engineErrors,
            meanMs,
            maxMs,
            cpuMs,
            rss,
            _deviceFramesConsumed,
            _engineSamplesEmitted,
            _collected.Count,
            CopiesPerBlock: 2,
            _autoStopFired);
    }

    private void DisposeHandlesLocked()
    {
        _vad?.Dispose();
        _gain?.Dispose();
        _stop?.Dispose();
        _vad = null;
        _gain = null;
        _stop = null;
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(RealtimeAudioPipeline));
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
            DisposeHandlesLocked();
            _session.Dispose();
        }
    }
}

/// <summary>Result of <see cref="RealtimeAudioPipeline.Stop"/>.</summary>
public sealed class PipelineStopResult
{
    public PipelineStopResult(
        IReadOnlyList<short> samples,
        IReadOnlyList<NanoEngine.LiveSegment> segments,
        CaptureMetrics metrics)
    {
        Samples = samples;
        Segments = segments;
        Metrics = metrics;
    }

    public IReadOnlyList<short> Samples { get; }

    public IReadOnlyList<NanoEngine.LiveSegment> Segments { get; }

    public CaptureMetrics Metrics { get; }
}
