namespace NanoDictate.Core;

/// <summary>
/// Deterministic native HUD presentation state machine. It owns only what the
/// user sees: deferred Starting, Recording readiness/timer, Processing,
/// terminal statuses and cycle-scoped hide deadlines. Rust keeps ownership of
/// session readiness, VAD, STT and cancellation; this type never treats
/// <c>DictationState.Transcribing</c> as permission to keep the panel visible
/// after a user cancel.
///
/// Time is injected as a monotonic <see cref="TimeSpan"/>. The WinUI adapter
/// pumps it at the meter tick; tests drive it directly from the #216 golden
/// fixture, which keeps every terminal path bounded and generation-checked.
/// </summary>
public sealed class HudPresentation
{
    private const int MaxMeterCatchUpSteps = 40;

    private HudSessionLabel _label;
    private readonly HudMeter _meter = new();
    private readonly HudLevelSignal _level = new();
    private HudPhase _phase = HudPhase.Idle;
    private string? _statusKey;
    private string? _statusArgument;
    private bool _visible;
    private bool _startingShown;
    private bool _reduceMotion;
    private ulong _generation;
    private ulong _cycleToken;
    private ulong _hideToken;
    private TimeSpan? _cycleStartedAt;
    private TimeSpan? _recordingStartedAt;
    private TimeSpan? _hideAt;
    private TimeSpan _lastMeterTick;
    private TimeSpan _now;

    public HudPresentation(HudSessionLabel label)
    {
        _label = label ?? throw new ArgumentNullException(nameof(label));
    }

    public HudSessionLabel Label => _label;

    /// <summary>Updates the resolved provider/model label after an optional settings change.</summary>
    public void UpdateLabel(HudSessionLabel label) => _label = label ?? throw new ArgumentNullException(nameof(label));

    public bool ReduceMotion
    {
        get => _reduceMotion;
        set
        {
            _reduceMotion = value;
            if (value)
            {
                _meter.Step(0, reduceMotion: true);
            }
        }
    }

    public HudPhase Phase => _visible ? _phase : HudPhase.Idle;

    public bool Visible => _visible;

    public ulong Generation => _generation;

    public TimeSpan Now => _now;

    /// <summary>Latest RMS value from the audio path; coalesced, never queued.</summary>
    public void PublishLevel(float rms) => _level.Publish(rms);

    /// <summary>Starts a new presentation cycle. A start never means capture is ready.</summary>
    public void BeginCycle(ulong generation, TimeSpan now)
    {
        _cycleToken++;
        _generation = generation;
        _hideToken = 0;
        _hideAt = null;
        _cycleStartedAt = now;
        _recordingStartedAt = null;
        _startingShown = false;
        _phase = HudPhase.Starting;
        _visible = false;
        _statusKey = null;
        _statusArgument = null;
        _meter.Reset();
        _level.Clear();
        _lastMeterTick = now;
        _now = now;
    }

    /// <summary>
    /// First valid engine block. This is the only event that starts Recording
    /// and the timer; <c>MicStartAttempted.Started</c> never does.
    /// </summary>
    public bool CaptureReady(ulong generation, TimeSpan now)
    {
        if (generation != _generation)
        {
            return false;
        }
        if (_phase != HudPhase.Starting && _phase != HudPhase.Idle)
        {
            return false;
        }
        _now = now;
        _phase = HudPhase.Recording;
        _visible = true;
        _recordingStartedAt = now;
        _statusKey = HudStatusKeys.Recording;
        _statusArgument = null;
        _hideAt = null;
        _hideToken = 0;
        _startingShown = true;
        _lastMeterTick = now;
        _meter.Reset();
        _level.Clear();
        return true;
    }

    /// <summary>Manual/auto stop: Processing before any terminal result.</summary>
    public bool StopRequested(ulong generation, TimeSpan now)
    {
        if (generation != _generation)
        {
            return false;
        }
        if (_phase != HudPhase.Recording && _phase != HudPhase.Starting)
        {
            return false;
        }
        _now = now;
        _phase = HudPhase.Processing;
        _visible = true;
        _recordingStartedAt = null;
        _statusKey = HudStatusKeys.Recognizing;
        _statusArgument = null;
        _hideAt = null;
        _hideToken = 0;
        _meter.Reset();
        _level.Clear();
        return true;
    }

    public bool InsertionSucceeded(ulong generation, TimeSpan now)
    {
        if (generation != _generation)
        {
            return false;
        }
        Terminal(HudStatusKeys.Finishing, null, now, HudContract.InsertHideSeconds);
        return true;
    }

    public bool Cancelled(ulong generation, TimeSpan now)
    {
        if (generation != _generation)
        {
            return false;
        }
        Terminal(HudStatusKeys.Cancelled, null, now, HudContract.CancelledHideSeconds);
        return true;
    }

    public bool EmptyResult(ulong generation, TimeSpan now)
    {
        if (generation != _generation)
        {
            return false;
        }
        Terminal(HudStatusKeys.EmptyResult, null, now, HudContract.EmptyResultHideSeconds);
        return true;
    }

    public bool TranscriptionError(ulong generation, string argumentKey, TimeSpan now)
    {
        if (generation != _generation)
        {
            return false;
        }
        Terminal(HudStatusKeys.Error, argumentKey, now, HudContract.ErrorHideSeconds);
        return true;
    }

    /// <summary>Processing watchdog: bounded error/hide even if STT never returns.</summary>
    public bool ProcessingTimedOut(ulong generation, TimeSpan now) =>
        TranscriptionError(generation, HudStatusKeys.ErrorSttTimeout, now);

    /// <summary>
    /// Microphone start failure. It stays in Starting (no timer ever ran) and
    /// hides after the dedicated bounded delay.
    /// </summary>
    public bool MicrophoneError(ulong generation, TimeSpan now, string? statusKey = null)
    {
        if (generation != _generation)
        {
            return false;
        }
        _now = now;
        _phase = HudPhase.Starting;
        _visible = true;
        _recordingStartedAt = null;
        _statusKey = statusKey ?? HudStatusKeys.ErrorMicEnableFailed;
        _statusArgument = null;
        _startingShown = true;
        ScheduleHide(now, HudContract.MicrophoneErrorHideSeconds);
        return true;
    }

    /// <summary>Immediate hide (explicit exit/recovery), cycle-scoped.</summary>
    public void Hide(TimeSpan now)
    {
        _now = now;
        HideLocked();
    }

    /// <summary>
    /// Advances deferred Starting, meter ballistics, the recording clock and
    /// terminal hide deadlines. Safe to call at any rate; stale hide tokens
    /// are ignored so a rapid new cycle keeps its panel visible.
    /// </summary>
    public void Advance(TimeSpan now)
    {
        if (now > _now)
        {
            _now = now;
        }

        if (!_visible
            && _phase == HudPhase.Starting
            && !_startingShown
            && _cycleStartedAt.HasValue
            && now - _cycleStartedAt.Value >= TimeSpan.FromSeconds(HudContract.StartingGraceSeconds))
        {
            _startingShown = true;
            _visible = true;
            _statusKey = HudStatusKeys.Starting;
            _statusArgument = null;
        }

        if (_hideAt.HasValue && now >= _hideAt.Value && _hideToken == _cycleToken)
        {
            HideLocked();
            return;
        }

        if (_visible && _phase == HudPhase.Recording)
        {
            if (_level.TryConsume(out var rms))
            {
                _meter.SetTargetFromRms(rms);
            }
            var tick = TimeSpan.FromSeconds(HudContract.MeterTickSeconds);
            var steps = 0;
            while (now - _lastMeterTick >= tick && steps < MaxMeterCatchUpSteps)
            {
                _meter.Step(HudContract.MeterTickSeconds, _reduceMotion);
                _lastMeterTick += tick;
                steps++;
            }
            if (steps == MaxMeterCatchUpSteps)
            {
                // Never replay an unbounded backlog on a stalled UI thread.
                _lastMeterTick = now;
            }
        }
    }

    public HudSnapshot Snapshot()
    {
        var phase = _visible ? _phase : HudPhase.Idle;
        var recordingStarted = _visible && _phase == HudPhase.Recording && _recordingStartedAt.HasValue;
        var elapsed = recordingStarted && _recordingStartedAt.HasValue
            ? Math.Max(0, (_now - _recordingStartedAt!.Value).TotalSeconds)
            : 0;
        return new HudSnapshot(
            _visible,
            phase,
            _visible ? _statusKey : null,
            _visible ? _statusArgument : null,
            recordingStarted,
            _generation,
            _meter.Meter,
            _meter.Peak,
            elapsed,
            _label,
            _reduceMotion);
    }

    private void Terminal(string statusKey, string? argumentKey, TimeSpan now, double hideSeconds)
    {
        _now = now;
        _phase = HudPhase.Idle;
        _visible = true;
        _recordingStartedAt = null;
        _statusKey = statusKey;
        _statusArgument = argumentKey;
        _meter.Reset();
        _level.Clear();
        ScheduleHide(now, hideSeconds);
    }

    private void ScheduleHide(TimeSpan now, double hideSeconds)
    {
        _hideAt = now + TimeSpan.FromSeconds(hideSeconds);
        _hideToken = _cycleToken;
    }

    private void HideLocked()
    {
        _visible = false;
        _phase = HudPhase.Idle;
        _statusKey = null;
        _statusArgument = null;
        _recordingStartedAt = null;
        _cycleStartedAt = null;
        _hideAt = null;
        _hideToken = 0;
        _startingShown = false;
        _meter.Reset();
        _level.Clear();
    }
}
