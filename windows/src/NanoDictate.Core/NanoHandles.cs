using System.Runtime.InteropServices;

namespace NanoDictate.Core;

/// <summary>
/// Base class for opaque Rust handles. Handles are movable across threads
/// but not thread-safe; the host serializes calls, matching the ABI
/// contract and the Swift bridge.
/// </summary>
public abstract class NanoHandle : SafeHandle
{
    protected NanoHandle()
        : base(IntPtr.Zero, ownsHandle: true)
    {
    }

    public override bool IsInvalid => handle == IntPtr.Zero;

    protected void ThrowIfInvalid()
    {
        if (IsInvalid)
        {
            throw new NanoException(-1, $"{GetType().Name} is not initialized");
        }
    }
}

/// <summary>Adaptive VAD handle (see AdaptiveVAD in Rust).</summary>
public sealed class VadHandle : NanoHandle
{
    public VadHandle()
    {
        var ptr = NativeMethods.nd_vad_new();
        if (ptr == IntPtr.Zero)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        SetHandle(ptr);
    }

    public bool Feed(float rms, double duration)
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_vad_feed(handle, rms, duration);
        if (code < 0)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
        return code != 0;
    }

    public unsafe bool FeedSamples(ReadOnlySpan<float> samples, uint sampleRate)
    {
        ThrowIfInvalid();
        int code;
        fixed (float* p = samples)
        {
            code = NativeMethods.nd_vad_feed_samples(handle, p, (UIntPtr)samples.Length, sampleRate);
        }
        if (code < 0)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
        return code != 0;
    }

    public void Reset()
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_vad_reset(handle);
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
    }

    /// <summary>
    /// Reads live VAD diagnostics without disturbing detector state.
    /// Observability for the level meter and debug logs only.
    /// </summary>
    public unsafe VadDiagnostics Diagnostics()
    {
        ThrowIfInvalid();
        float floor = 0, enter = 0, exit = 0;
        int isSpeech = 0;
        var code = NativeMethods.nd_vad_diagnostics(handle, &floor, &enter, &exit, &isSpeech);
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
        return new VadDiagnostics(floor, enter, exit, isSpeech != 0);
    }

    protected override bool ReleaseHandle()
    {
        NativeMethods.nd_vad_free(handle);
        return true;
    }
}

/// <summary>Live VAD diagnostics snapshot (meter/debug only).</summary>
public readonly record struct VadDiagnostics(float NoiseFloor, float EnterThreshold, float ExitThreshold, bool IsSpeech);

/// <summary>Input-gain (AGC) handle. Applies gain to blocks in place.</summary>
public sealed class GainHandle : NanoHandle
{
    public GainHandle()
    {
        var ptr = NativeMethods.nd_gain_new();
        if (ptr == IntPtr.Zero)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        SetHandle(ptr);
    }

    public unsafe float Apply(Span<float> samples, float rms, uint sampleRate)
    {
        ThrowIfInvalid();
        float result;
        fixed (float* p = samples)
        {
            result = NativeMethods.nd_gain_apply(handle, p, (UIntPtr)samples.Length, rms, sampleRate);
        }
        if (result < 0.0f)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        return result;
    }

    public void Reset()
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_gain_reset(handle);
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
    }

    public float CurrentGainDb
    {
        get
        {
            ThrowIfInvalid();
            var value = NativeMethods.nd_gain_current_db(handle);
            if (value < 0.0f)
            {
                throw new NanoException(-1, NanoEngine.LastError());
            }
            return value;
        }
    }

    protected override bool ReleaseHandle()
    {
        NativeMethods.nd_gain_free(handle);
        return true;
    }
}

/// <summary>Silence auto-stop handle.</summary>
public sealed class AutoStopHandle : NanoHandle
{
    public AutoStopHandle()
    {
        var ptr = NativeMethods.nd_autostop_new();
        if (ptr == IntPtr.Zero)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        SetHandle(ptr);
    }

    public bool Feed(float rms, double duration, bool? isSpeech)
    {
        ThrowIfInvalid();
        var hint = isSpeech.HasValue ? (isSpeech.Value ? 1 : 0) : -1;
        var code = NativeMethods.nd_autostop_feed(handle, rms, duration, hint);
        if (code < 0)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
        return code != 0;
    }

    public void Reset()
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_autostop_reset(handle);
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
    }

    protected override bool ReleaseHandle()
    {
        NativeMethods.nd_autostop_free(handle);
        return true;
    }
}

/// <summary>
/// Dictation session handle. Encodes the capture-readiness latch: the
/// recording-ready cue may only follow the first valid buffer of the
/// current generation.
/// </summary>
public sealed class SessionHandle : NanoHandle
{
    public SessionHandle()
    {
        var ptr = NativeMethods.nd_session_new();
        if (ptr == IntPtr.Zero)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        SetHandle(ptr);
    }

    public ulong Start()
    {
        ThrowIfInvalid();
        var generation = NativeMethods.nd_session_start(handle);
        if (generation == 0)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        return generation;
    }

    public void OnEvent(SessionEvent @event, ulong generation)
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_session_event(handle, (uint)@event, generation);
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
    }

    public bool IsCaptureReady
    {
        get
        {
            ThrowIfInvalid();
            var code = NativeMethods.nd_session_is_capture_ready(handle);
            if (code < 0)
            {
                throw new NanoException(code, NanoEngine.LastError());
            }
            return code != 0;
        }
    }

    public bool ShouldEmitReadyCue()
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_session_should_emit_ready_cue(handle);
        if (code < 0)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
        return code != 0;
    }

    public DictationState State
    {
        get
        {
            ThrowIfInvalid();
            var code = NativeMethods.nd_session_state(handle);
            if (code > (uint)DictationState.Transcribing)
            {
                throw new NanoException(-1, NanoEngine.LastError());
            }
            return (DictationState)code;
        }
    }

    protected override bool ReleaseHandle()
    {
        NativeMethods.nd_session_free(handle);
        return true;
    }
}

/// <summary>Mic-error cooldown handle.</summary>
public sealed class CooldownHandle : NanoHandle
{
    public CooldownHandle(double intervalSecs)
    {
        var ptr = NativeMethods.nd_cooldown_new(intervalSecs);
        if (ptr == IntPtr.Zero)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        SetHandle(ptr);
    }

    public bool Allow(double nowSecs)
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_cooldown_allow(handle, nowSecs);
        if (code < 0)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
        return code != 0;
    }

    protected override bool ReleaseHandle()
    {
        NativeMethods.nd_cooldown_free(handle);
        return true;
    }
}

/// <summary>Enter-send latch handle.</summary>
public sealed class LatchHandle : NanoHandle
{
    public LatchHandle()
    {
        var ptr = NativeMethods.nd_latch_new();
        if (ptr == IntPtr.Zero)
        {
            throw new NanoException(-1, NanoEngine.LastError());
        }
        SetHandle(ptr);
    }

    public void Arm()
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_latch_arm(handle);
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
    }

    public bool Consume()
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_latch_consume(handle);
        if (code < 0)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
        return code != 0;
    }

    public void Cancel()
    {
        ThrowIfInvalid();
        var code = NativeMethods.nd_latch_cancel(handle);
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, NanoEngine.LastError());
        }
    }

    protected override bool ReleaseHandle()
    {
        NativeMethods.nd_latch_free(handle);
        return true;
    }
}
