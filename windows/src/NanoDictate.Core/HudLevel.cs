namespace NanoDictate.Core;

/// <summary>
/// Pure VU meter math for the native HUD: RMS remap, envelope ballistics,
/// hot-zone threshold and ring stroke width. Mirrors the macOS
/// <c>OverlayLevel</c> reference and the shared fixture vectors; no I/O and
/// no Rust state decisions live here.
/// </summary>
public static class HudLevel
{
    public static float Dbfs(float rms) =>
        rms <= 0 ? -120.0f : 20.0f * MathF.Log10(rms);

    public static float MeterFromRms(float rms)
    {
        if (rms <= 0)
        {
            return 0;
        }
        var decibels = 20.0f * MathF.Log10(rms);
        return Math.Clamp((decibels - HudContract.DbfsFloor) / -HudContract.DbfsFloor, 0, 1);
    }

    public static float DbfsForMeter(float meter) =>
        HudContract.DbfsFloor + Math.Clamp(meter, 0, 1) * -HudContract.DbfsFloor;

    public static float HotMeterThreshold =>
        (HudContract.HotThresholdDbfs - HudContract.DbfsFloor) / -HudContract.DbfsFloor;

    public static bool IsHot(float meter) => meter > HotMeterThreshold;

    public static float Envelope(float current, float target, double deltaSeconds)
    {
        var from = Math.Clamp(current, 0, 1);
        var to = Math.Clamp(target, 0, 1);
        if (to > from)
        {
            var step = (float)(deltaSeconds / HudContract.AttackSeconds);
            return Math.Min(to, from + step * (to - from));
        }
        var decayed = from * (float)Math.Exp(-deltaSeconds / HudContract.ReleaseSeconds);
        return Math.Max(to, decayed);
    }

    public static float StrokeWidth(float meter) =>
        HudContract.StrokeMinPoints
        + Math.Clamp(meter, 0, 1) * (HudContract.StrokeMaxPoints - HudContract.StrokeMinPoints);
}

/// <summary>
/// Peak follower for the HUD ring dot: holds the maximum for the contract
/// window, then decays linearly. Reset at every cycle/hide.
/// </summary>
public sealed class HudPeak
{
    private float _value;
    private double _holdRemaining;

    public float Value => _value;

    public float Update(float level, double deltaSeconds)
    {
        var clamped = Math.Clamp(level, 0, 1);
        if (clamped > _value)
        {
            _value = clamped;
            _holdRemaining = HudContract.PeakHoldSeconds;
        }
        else if (_holdRemaining > 0)
        {
            _holdRemaining -= deltaSeconds;
        }
        else if (_value > 0)
        {
            _value = Math.Max(0, _value - HudContract.PeakFallRatePerSecond * (float)deltaSeconds);
        }
        return _value;
    }

    public void Reset()
    {
        _value = 0;
        _holdRemaining = 0;
    }
}

/// <summary>Meter + peak animation state advanced at the contract tick rate.</summary>
public sealed class HudMeter
{
    private readonly HudPeak _peak = new();
    private float _target;

    public float Meter { get; private set; }

    public float Peak => _peak.Value;

    public float Target => _target;

    public void SetTargetFromRms(float rms) => _target = HudLevel.MeterFromRms(rms);

    public void Step(double deltaSeconds, bool reduceMotion)
    {
        if (reduceMotion)
        {
            Meter = _target;
            _peak.Reset();
            // Reduce Motion keeps the peak dot on the same value as the meter.
            _peak.Update(Meter, 0);
            return;
        }
        Meter = HudLevel.Envelope(Meter, _target, deltaSeconds);
        _peak.Update(Meter, deltaSeconds);
    }

    public void Reset()
    {
        _target = 0;
        Meter = 0;
        _peak.Reset();
    }
}

/// <summary>
/// Bounded, latest-value-only RMS signal between the audio callback and the
/// HUD tick. Publishing never blocks and never queues: a slow renderer skips
/// intermediate values instead of growing a backlog.
/// </summary>
public sealed class HudLevelSignal
{
    private int _bits;
    private int _hasValue;

    public void Publish(float rms)
    {
        var clamped = float.IsFinite(rms) ? Math.Clamp(rms, 0, 1) : 0;
        Volatile.Write(ref _bits, BitConverter.SingleToInt32Bits(clamped));
        Volatile.Write(ref _hasValue, 1);
    }

    public bool TryConsume(out float rms)
    {
        if (Interlocked.Exchange(ref _hasValue, 0) == 0)
        {
            rms = 0;
            return false;
        }
        rms = BitConverter.Int32BitsToSingle(Volatile.Read(ref _bits));
        return true;
    }

    public void Clear()
    {
        Volatile.Write(ref _hasValue, 0);
    }
}
