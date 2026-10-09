using System.Runtime.InteropServices;
using System.Text;

namespace NanoDictate.Core;

/// <summary>
/// Thin managed surface over the shared Rust engine. Every method below
/// marshals arguments, calls exactly one ABI entry point, maps errors, and
/// releases Rust-owned allocations. No product policy lives here: failover
/// ordering, backoff math, VAD thresholds, transcript rules, and session
/// semantics are all computed inside nanodictate-core.
/// </summary>
public static class NanoEngine
{
    /// <summary>ABI version this host was built against (mirrors ND_ABI_VERSION).</summary>
    public const uint ExpectedAbiVersion = 1;

    /// <summary>Returns the linked engine ABI version.</summary>
    public static uint AbiVersion() => NativeMethods.nd_abi_version();

    /// <summary>
    /// Fails loudly when the linked engine does not speak the expected ABI,
    /// so a link mismatch can never leave Rust silently unused.
    /// </summary>
    public static void CheckAvailable(uint expected = ExpectedAbiVersion)
    {
        var linked = AbiVersion();
        if (linked != expected)
        {
            throw new NanoException(-1, $"engine ABI mismatch: linked {linked}, expected {expected}");
        }
    }

    /// <summary>Thread-local last-error diagnostic from the engine.</summary>
    public static string LastError()
    {
        var ptr = NativeMethods.nd_last_error_text();
        if (ptr == IntPtr.Zero)
        {
            return "unknown engine error";
        }
        return Marshal.PtrToStringUTF8(ptr) ?? "unknown engine error";
    }

    internal static string TakeString(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero)
        {
            throw new NanoException(-1, LastError());
        }
        try
        {
            return Marshal.PtrToStringUTF8(ptr) ?? throw new NanoException(-1, LastError());
        }
        finally
        {
            NativeMethods.nd_string_free(ptr);
        }
    }

    internal static unsafe IntPtr CallStringReturn(byte[]? input, Func<IntPtr, UIntPtr, IntPtr> call)
    {
        if (input is null || input.Length == 0)
        {
            return call(IntPtr.Zero, UIntPtr.Zero);
        }
        fixed (byte* p = input)
        {
            return call((IntPtr)p, (UIntPtr)input.Length);
        }
    }

    private static void ThrowOnCode(int code)
    {
        if (code != NanoErrorCodes.Ok)
        {
            throw new NanoException(code, LastError());
        }
    }

    private static void ThrowOnNegative(int code)
    {
        if (code < 0)
        {
            throw new NanoException(code, LastError());
        }
    }

    // -- Audio metrics -----------------------------------------------------

    public static float Dbfs(float linear) => NativeMethods.nd_dbfs(linear);

    public static unsafe float RmsI16(ReadOnlySpan<short> samples)
    {
        fixed (short* p = samples)
        {
            var value = NativeMethods.nd_rms_i16(p, (UIntPtr)samples.Length);
            if (samples.Length > 0 && value < 0.0f)
            {
                throw new NanoException(-1, LastError());
            }
            return value;
        }
    }

    public static unsafe float RmsF32(ReadOnlySpan<float> samples)
    {
        fixed (float* p = samples)
        {
            var value = NativeMethods.nd_rms_f32(p, (UIntPtr)samples.Length);
            if (samples.Length > 0 && value < 0.0f)
            {
                throw new NanoException(-1, LastError());
            }
            return value;
        }
    }

    public static float SoftLimit(float x) => NativeMethods.nd_soft_limit(x);

    // -- WAV codec ----------------------------------------------------------

    public static unsafe byte[] WavEncode(ReadOnlySpan<short> samples, uint sampleRate, ushort channels)
    {
        NdByteBuffer outBuf = default;
        int code;
        fixed (short* p = samples)
        {
            code = NativeMethods.nd_wav_encode(p, (UIntPtr)samples.Length, sampleRate, channels, &outBuf);
        }
        ThrowOnCode(code);
        try
        {
            if (outBuf.Data == IntPtr.Zero)
            {
                throw new NanoException(-1, "engine returned an empty WAV buffer");
            }
            var len = (int)(uint)outBuf.Len;
            var managed = new byte[len];
            Marshal.Copy(outBuf.Data, managed, 0, len);
            return managed;
        }
        finally
        {
            NativeMethods.nd_bytes_free(outBuf);
        }
    }

    public readonly record struct WavInfo(uint SampleRate, ushort Channels, int SampleCount);

    public static unsafe WavInfo WavDecodeInfo(ReadOnlySpan<byte> data)
    {
        uint rate = 0;
        ushort channels = 0;
        UIntPtr count = UIntPtr.Zero;
        int code;
        fixed (byte* p = data)
        {
            code = NativeMethods.nd_wav_decode_info(p, (UIntPtr)data.Length, &rate, &channels, &count);
        }
        ThrowOnCode(code);
        return new WavInfo(rate, channels, (int)(uint)count);
    }

    public static unsafe short[] WavDecodeSamples(ReadOnlySpan<byte> data)
    {
        var info = WavDecodeInfo(data);
        var decoded = new short[info.SampleCount];
        UIntPtr written = UIntPtr.Zero;
        int code;
        fixed (byte* p = data)
        fixed (short* o = decoded)
        {
            code = NativeMethods.nd_wav_decode_samples(p, (UIntPtr)data.Length, o, (UIntPtr)decoded.Length, &written);
        }
        ThrowOnCode(code);
        return decoded;
    }

    // -- Text / STT policy (owned by Rust) -----------------------------------

    public static unsafe string WordDiff(string oldText, string newText)
    {
        var oldBytes = Encoding.UTF8.GetBytes(oldText);
        var newBytes = Encoding.UTF8.GetBytes(newText);
        fixed (byte* o = oldBytes)
        fixed (byte* n = newBytes)
        {
            return TakeString(NativeMethods.nd_word_diff(o, (UIntPtr)oldBytes.Length, n, (UIntPtr)newBytes.Length));
        }
    }

    public static unsafe string TextJoin(IReadOnlyList<string> texts)
    {
        if (texts.Count == 0)
        {
            return TakeString(NativeMethods.nd_text_join(null, null, UIntPtr.Zero));
        }
        var encoded = new byte[texts.Count][];
        for (var i = 0; i < texts.Count; i++)
        {
            encoded[i] = Encoding.UTF8.GetBytes(texts[i]);
        }
        var handles = new GCHandle[texts.Count];
        try
        {
            var ptrs = new IntPtr[texts.Count];
            var lens = new UIntPtr[texts.Count];
            for (var i = 0; i < texts.Count; i++)
            {
                handles[i] = GCHandle.Alloc(encoded[i], GCHandleType.Pinned);
                ptrs[i] = handles[i].AddrOfPinnedObject();
                lens[i] = (UIntPtr)encoded[i].Length;
            }
            fixed (void* p = ptrs)
            fixed (void* l = lens)
            {
                return TakeString(NativeMethods.nd_text_join((byte**)p, (UIntPtr*)l, (UIntPtr)texts.Count));
            }
        }
        finally
        {
            foreach (var h in handles)
            {
                if (h.IsAllocated)
                {
                    h.Free();
                }
            }
        }
    }

    public static unsafe string SttResolve(string adapterId, string model)
    {
        var adapter = Encoding.UTF8.GetBytes(adapterId);
        var mod = Encoding.UTF8.GetBytes(model);
        fixed (byte* a = adapter)
        fixed (byte* m = mod)
        {
            return TakeString(NativeMethods.nd_stt_resolve(a, (UIntPtr)adapter.Length, m, (UIntPtr)mod.Length));
        }
    }

    public static unsafe string TranscriptParse(string body, string? path = null)
    {
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        fixed (byte* b = bodyBytes)
        {
            if (string.IsNullOrEmpty(path))
            {
                return TakeString(NativeMethods.nd_transcript_parse(b, (UIntPtr)bodyBytes.Length, null, UIntPtr.Zero));
            }
            var pathBytes = Encoding.UTF8.GetBytes(path);
            fixed (byte* p = pathBytes)
            {
                return TakeString(NativeMethods.nd_transcript_parse(b, (UIntPtr)bodyBytes.Length, p, (UIntPtr)pathBytes.Length));
            }
        }
    }

    public static unsafe string FailoverOrder(IReadOnlyList<string> ids, string? failedId, bool autoFailover)
    {
        var joined = string.Join(",", ids);
        var idsBytes = Encoding.UTF8.GetBytes(joined);
        fixed (byte* i = idsBytes)
        {
            if (string.IsNullOrEmpty(failedId))
            {
                return TakeString(NativeMethods.nd_failover_order(i, (UIntPtr)idsBytes.Length, null, UIntPtr.Zero, autoFailover));
            }
            var failedBytes = Encoding.UTF8.GetBytes(failedId);
            fixed (byte* f = failedBytes)
            {
                return TakeString(NativeMethods.nd_failover_order(i, (UIntPtr)idsBytes.Length, f, (UIntPtr)failedBytes.Length, autoFailover));
            }
        }
    }

    public static int FailoverCandidateCount(int orderLength, bool autoFailover) =>
        (int)(uint)NativeMethods.nd_failover_candidate_count((UIntPtr)orderLength, autoFailover);

    /// <summary>
    /// Whether a failed attempt may fail over. Kind 0 is a transcribe error;
    /// any other value is a non-transcribe failure. The classification lives
    /// in Rust; this wrapper only marshals the code.
    /// </summary>
    public static bool ShouldFailover(uint kind) => NativeMethods.nd_should_failover(kind);

    public static ulong BackoffDelayMs(uint attempt, ulong baseMs, ulong capMs) =>
        NativeMethods.nd_backoff_delay_ms(attempt, baseMs, capMs);

    // -- Review / gates (owned by Rust) ---------------------------------------

    public static unsafe bool ReviewDecide(string? line)
    {
        int code;
        if (line is null)
        {
            code = NativeMethods.nd_review_decide(null, UIntPtr.Zero, false);
        }
        else
        {
            var bytes = Encoding.UTF8.GetBytes(line);
            fixed (byte* p = bytes)
            {
                code = NativeMethods.nd_review_decide(p, (UIntPtr)bytes.Length, true);
            }
        }
        ThrowOnNegative(code);
        return code != 0;
    }

    public static bool ShouldDropRetry(DictationState state, ulong processingSession, ulong session)
    {
        var code = NativeMethods.nd_should_drop_retry((uint)state, processingSession, session);
        ThrowOnNegative(code);
        return code != 0;
    }

    public static bool OverlayShouldHide(DictationState state)
    {
        var code = NativeMethods.nd_overlay_should_hide((uint)state);
        ThrowOnNegative(code);
        return code != 0;
    }

    public static unsafe bool MicRequestAllowed(ReadOnlySpan<double> stamps, double now, int maxTimeouts, double windowSecs)
    {
        int code;
        fixed (double* p = stamps)
        {
            code = NativeMethods.nd_mic_request_allowed(p, (UIntPtr)stamps.Length, now, (UIntPtr)maxTimeouts, windowSecs);
        }
        ThrowOnNegative(code);
        return code != 0;
    }
}
