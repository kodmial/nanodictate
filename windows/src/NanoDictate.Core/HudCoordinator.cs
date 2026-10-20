using System.Diagnostics;

namespace NanoDictate.Core;

/// <summary>
/// Connects the existing Windows product events to the deterministic
/// <see cref="HudPresentation"/>. It owns no dictation policy: start/stop,
/// cancellation, readiness, insertion and errors still come from
/// <see cref="DictationController"/>, <see cref="HostApp"/> and the shared
/// Rust engine. The coordinator only coalesces raw RMS into the HUD and
/// pumps presentation timers, with generation guards for stale callbacks.
/// </summary>
public sealed class HudCoordinator : IDisposable
{
    private readonly object _gate = new();
    private readonly HostApp _app;
    private readonly HudPresentation _presentation;
    private readonly Func<TimeSpan> _clock;
    private readonly Stopwatch _stopwatch = Stopwatch.StartNew();
    private readonly Timer? _ticker;
    private Timer? _watchdog;
    private readonly TimeSpan _processingWatchdog;
    private HudSnapshot? _lastSnapshot;
    private ulong _currentGeneration;
    private ulong _fallbackGeneration;
    private ulong _activeRecordingId;
    private ulong _watchdogRecordingId;
    private ulong _timedOutRecordingId;
    private bool _watchdogActive;
    private bool _terminal;
    private bool _disposed;

    public HudCoordinator(
        HostApp app,
        TimeSpan? processingWatchdog = null,
        Func<TimeSpan>? clock = null,
        bool useTimer = true,
        bool reduceMotion = false)
    {
        _app = app ?? throw new ArgumentNullException(nameof(app));
        _clock = clock ?? (() => _stopwatch.Elapsed);
        _presentation = new HudPresentation(app.SessionLabel) { ReduceMotion = reduceMotion };
        _processingWatchdog = processingWatchdog ?? TimeSpan.FromSeconds(125);

        app.Controller.MicStartAttempted += OnMicStartAttempted;
        app.Controller.ProcessingStarted += OnProcessingStarted;
        app.Controller.CancelledWithRecordingId += OnCancelled;
        app.CaptureReady += OnCaptureReady;
        app.RawRmsAvailable += OnRawRms;
        app.DeviceChanged += OnDeviceChanged;
        app.DeliveryCompleted += OnDeliveryCompleted;
        app.DeliveryFailed += OnDeliveryFailed;

        if (useTimer)
        {
            _ticker = new Timer(_ => Tick(), null, 50, 50);
        }
    }

    public HudPresentation Presentation => _presentation;

    public HudSnapshot Snapshot
    {
        get { lock (_gate) { return _presentation.Snapshot(); } }
    }

    public event Action<HudSnapshot>? SnapshotChanged;

    /// <summary>Refreshes the provider/model header after an optional settings change.</summary>
    public void RefreshLabel()
    {
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            _presentation.UpdateLabel(_app.SessionLabel);
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    /// <summary>Advance presentation timers once (also used deterministically by tests).</summary>
    public void Tick()
    {
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _presentation.Advance(_clock());
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private void OnMicStartAttempted(MicStartOutcome outcome)
    {
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            if (outcome.Started)
            {
                // CaptureReady can fire on the audio worker before the
                // controller reports Started. Synchronize to the capture
                // generation without resetting a cycle that first-buffer
                // readiness already advanced.
                _ = SyncGenerationLocked();
                _activeRecordingId = _app.Controller.CurrentRecordingId;
                _terminal = false;
                StopWatchdogLocked();
            }
            else
            {
                _ = SyncGenerationLocked();
                _activeRecordingId = _app.Controller.CurrentRecordingId;
                _terminal = true;
                _presentation.MicrophoneError(_currentGeneration, _clock());
            }
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private void OnCaptureReady(CaptureMetrics metrics)
    {
        _ = metrics;
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            // A first buffer can arrive before MicStartAttempted.Started and
            // after the previous cycle's terminal state. Only a newer capture
            // generation may clear that terminal; same-generation callbacks
            // remain stale.
            if (SyncGenerationLocked())
            {
                _terminal = false;
            }
            if (_terminal)
            {
                return;
            }
            _presentation.CaptureReady(_currentGeneration, _clock());
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private void OnProcessingStarted(ulong recordingId)
    {
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            if (_terminal)
            {
                return;
            }
            if (!_presentation.StopRequested(_currentGeneration, _clock()))
            {
                return;
            }
            _activeRecordingId = recordingId;
            StartWatchdogLocked(recordingId);
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private void OnCancelled(ulong recordingId)
    {
        var currentRecordingId = _app.Controller.CurrentRecordingId;
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            if (_terminal
                || (recordingId != 0
                    && currentRecordingId != 0
                    && recordingId != currentRecordingId)
                || !IsCurrentDeliveryLocked(recordingId))
            {
                return;
            }
            StopWatchdogLocked();
            _terminal = true;
            _presentation.Cancelled(_currentGeneration, _clock());
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private void OnRawRms(float rms)
    {
        // Audio callback path: no lock, no UI dispatch, no queue.
        _presentation.PublishLevel(rms);
    }

    private void OnDeviceChanged(Exception error)
    {
        _ = error;
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            if (_currentGeneration == 0 || _terminal)
            {
                return;
            }
            StopWatchdogLocked();
            _terminal = true;
            _presentation.MicrophoneError(_currentGeneration, _clock());
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private void OnDeliveryCompleted(DictationDelivery delivery)
    {
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            if (_terminal || !IsCurrentDeliveryLocked(delivery.RecordingId))
            {
                return;
            }
            _terminal = true;
            StopWatchdogLocked();
            if (delivery.Inserted)
            {
                _presentation.InsertionSucceeded(_currentGeneration, _clock());
            }
            else if (DictationTextPolicy.IsEmptyResult(delivery.Text))
            {
                _presentation.EmptyResult(_currentGeneration, _clock());
            }
            else
            {
                // Review was explicitly enabled and declined/failed closed;
                // never present that as an insertion.
                _presentation.Cancelled(_currentGeneration, _clock());
            }
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private void OnDeliveryFailed(DictationFailure failure)
    {
        HudSnapshot? snapshot = null;
        lock (_gate)
        {
            if (_terminal || !IsCurrentDeliveryLocked(failure.RecordingId))
            {
                return;
            }
            _terminal = true;
            StopWatchdogLocked();
            var (key, argument) = failure.Kind == DictationFailureKind.Insertion
                ? (HudStatusKeys.Error, HudStatusKeys.ErrorInsertFailed)
                : HudStrings.ErrorFor(failure.Error);
            if (key == HudStatusKeys.Error)
            {
                _presentation.TranscriptionError(_currentGeneration, argument ?? string.Empty, _clock());
            }
            else
            {
                _presentation.MicrophoneError(_currentGeneration, _clock(), key);
            }
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);
    }

    private bool IsCurrentDeliveryLocked(ulong recordingId)
    {
        if (recordingId != 0 && _activeRecordingId != 0 && recordingId != _activeRecordingId)
        {
            return false;
        }
        if (_timedOutRecordingId != 0 && recordingId == _timedOutRecordingId)
        {
            return false;
        }
        return true;
    }

    private void StartWatchdogLocked(ulong recordingId)
    {
        _watchdog?.Dispose();
        _watchdogRecordingId = recordingId;
        _watchdogActive = true;
        // A per-session timer carries its recording id, so a callback queued
        // before a rapid restart cannot time out the new recording.
        _watchdog = new Timer(OnWatchdog, recordingId, _processingWatchdog, Timeout.InfiniteTimeSpan);
    }

    private void StopWatchdogLocked()
    {
        _watchdogActive = false;
        _watchdog?.Dispose();
        _watchdog = null;
    }

    private void OnWatchdog(object? state)
    {
        var recordingId = state is ulong id ? id : 0;
        HudSnapshot? snapshot = null;
        ulong timedOutRecordingId;
        lock (_gate)
        {
            if (_disposed
                || !_watchdogActive
                || (_watchdogRecordingId != 0 && recordingId != _watchdogRecordingId))
            {
                return;
            }
            _watchdogActive = false;
            _watchdog?.Dispose();
            _watchdog = null;
            _terminal = true;
            timedOutRecordingId = _watchdogRecordingId;
            _timedOutRecordingId = timedOutRecordingId;
            _presentation.ProcessingTimedOut(_currentGeneration, _clock());
            snapshot = _presentation.Snapshot();
        }
        Raise(snapshot);

        // A timed-out session must not insert its late transcript. Cancel the
        // owning recording (not a newer one that may have started meanwhile)
        // so the controller drops the result before insertion.
        if (_app.Controller.CurrentRecordingId == timedOutRecordingId)
        {
            try
            {
                _app.Controller.CancelCurrent();
            }
            catch
            {
                // The cancelled flag is still authoritative for late results.
            }
        }
    }

    private bool SyncGenerationLocked()
    {
        var generation = _app.Capture.Generation;
        if (generation == 0)
        {
            if (_currentGeneration != 0)
            {
                return false;
            }
            generation = ++_fallbackGeneration;
        }
        if (generation == _currentGeneration)
        {
            return false;
        }
        _currentGeneration = generation;
        _presentation.BeginCycle(_currentGeneration, _clock());
        return true;
    }

    private void Raise(HudSnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return;
        }
        lock (_gate)
        {
            if (_lastSnapshot == snapshot)
            {
                return;
            }
            _lastSnapshot = snapshot;
        }
        SnapshotChanged?.Invoke(snapshot);
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
        _ticker?.Dispose();
        _watchdog?.Dispose();
        _app.Controller.MicStartAttempted -= OnMicStartAttempted;
        _app.Controller.ProcessingStarted -= OnProcessingStarted;
        _app.Controller.CancelledWithRecordingId -= OnCancelled;
        _app.CaptureReady -= OnCaptureReady;
        _app.RawRmsAvailable -= OnRawRms;
        _app.DeviceChanged -= OnDeviceChanged;
        _app.DeliveryCompleted -= OnDeliveryCompleted;
        _app.DeliveryFailed -= OnDeliveryFailed;
    }
}
