using System.Reflection;
using System.Runtime.InteropServices;

namespace NanoDictate.Core;

/// <summary>
/// Narrow P/Invoke layer over the stable C ABI exported by nanodictate-core.
/// This class declares the ABI surface only; all product behavior stays in
/// Rust. Callers must use <see cref="NanoEngine"/> wrappers instead of
/// calling these entries directly so ownership and error mapping stay in
/// one place.
/// </summary>
internal static class NativeMethods
{
    internal const string LibraryName = "nanodictate_core";

    static NativeMethods()
    {
        NativeLibrary.SetDllImportResolver(
            typeof(NativeMethods).Assembly,
            Resolve);
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != LibraryName)
        {
            return IntPtr.Zero;
        }

        // Explicit override wins (CI sets this to the freshly built DLL).
        var overridePath = Environment.GetEnvironmentVariable("NANODICTATE_CORE_DLL");
        if (!string.IsNullOrEmpty(overridePath) && File.Exists(overridePath))
        {
            return NativeLibrary.Load(overridePath);
        }

        var candidates = new List<string>();
        var appDir = AppContext.BaseDirectory;
        if (OperatingSystem.IsWindows())
        {
            candidates.Add(Path.Combine(appDir, "nanodictate_core.dll"));
            candidates.Add(Path.Combine(appDir, "runtimes", "win-x64", "native", "nanodictate_core.dll"));
        }
        else if (OperatingSystem.IsLinux())
        {
            candidates.Add(Path.Combine(appDir, "libnanodictate_core.so"));
        }
        else if (OperatingSystem.IsMacOS())
        {
            candidates.Add(Path.Combine(appDir, "libnanodictate_core.dylib"));
        }

        // Repository-relative fallbacks so `dotnet test` works from a source
        // checkout without installing the engine first.
        var repoRoot = FindRepoRoot(appDir);
        if (repoRoot is not null)
        {
            if (OperatingSystem.IsWindows())
            {
                candidates.Add(Path.Combine(repoRoot, "rust", "target", "release", "nanodictate_core.dll"));
                candidates.Add(Path.Combine(repoRoot, "windows", "artifacts", "nanodictate_core.dll"));
            }
            else if (OperatingSystem.IsLinux())
            {
                candidates.Add(Path.Combine(repoRoot, "rust", "target", "release", "libnanodictate_core.so"));
            }
            else if (OperatingSystem.IsMacOS())
            {
                candidates.Add(Path.Combine(repoRoot, "rust", "target", "release", "libnanodictate_core.dylib"));
            }
        }

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return NativeLibrary.Load(candidate);
            }
        }

        // Fall back to the default loader search (app directory, PATH).
        return NativeLibrary.Load(LibraryName, assembly, searchPath);
    }

    private static string? FindRepoRoot(string start)
    {
        var dir = new DirectoryInfo(start);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Package.swift"))
                && Directory.Exists(Path.Combine(dir.FullName, "rust")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        return null;
    }

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern uint nd_abi_version();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr nd_last_error_text();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_string_free(IntPtr text);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_bytes_free(NdByteBuffer buffer);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern float nd_dbfs(float linear);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe float nd_rms_i16(short* samples, UIntPtr count);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe float nd_rms_f32(float* samples, UIntPtr count);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern float nd_soft_limit(float x);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe int nd_wav_encode(short* samples, UIntPtr count, uint sampleRate, ushort channels, NdByteBuffer* @out);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe int nd_wav_decode_info(byte* data, UIntPtr len, uint* outSampleRate, ushort* outChannels, UIntPtr* outSampleCount);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe int nd_wav_decode_samples(byte* data, UIntPtr len, short* outSamples, UIntPtr capacity, UIntPtr* outWritten);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe IntPtr nd_word_diff(byte* oldPtr, UIntPtr oldLen, byte* newPtr, UIntPtr newLen);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe IntPtr nd_text_join(byte** texts, UIntPtr* lens, UIntPtr count);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe IntPtr nd_stt_resolve(byte* adapterPtr, UIntPtr adapterLen, byte* modelPtr, UIntPtr modelLen);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe IntPtr nd_transcript_parse(byte* bodyPtr, UIntPtr bodyLen, byte* pathPtr, UIntPtr pathLen);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe IntPtr nd_failover_order(byte* idsPtr, UIntPtr idsLen, byte* failedPtr, UIntPtr failedLen, [MarshalAs(UnmanagedType.I1)] bool autoFailover);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern UIntPtr nd_failover_candidate_count(UIntPtr orderLen, [MarshalAs(UnmanagedType.I1)] bool autoFailover);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool nd_should_failover(uint kind);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong nd_backoff_delay_ms(uint attempt, ulong baseMs, ulong capMs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe int nd_review_decide(byte* linePtr, UIntPtr lineLen, [MarshalAs(UnmanagedType.I1)] bool hasLine);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_should_drop_retry(uint state, ulong processingSession, ulong session);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_overlay_should_hide(uint state);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe int nd_mic_request_allowed(double* stamps, UIntPtr count, double now, UIntPtr maxTimeouts, double windowSecs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr nd_vad_new();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_vad_free(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_vad_feed(IntPtr handle, float rms, double duration);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe int nd_vad_feed_samples(IntPtr handle, float* samples, UIntPtr count, uint sampleRate);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_vad_reset(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr nd_gain_new();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_gain_free(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern unsafe float nd_gain_apply(IntPtr handle, float* samples, UIntPtr count, float rms, uint sampleRate);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr nd_autostop_new();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_autostop_free(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_autostop_feed(IntPtr handle, float rms, double duration, int isSpeech);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr nd_session_new();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_session_free(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong nd_session_start(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_session_event(IntPtr handle, uint @event, ulong generation);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_session_is_capture_ready(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_session_should_emit_ready_cue(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern uint nd_session_state(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr nd_cooldown_new(double intervalSecs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_cooldown_free(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_cooldown_allow(IntPtr handle, double nowSecs);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr nd_latch_new();

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void nd_latch_free(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_latch_arm(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_latch_consume(IntPtr handle);

    [DllImport(LibraryName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int nd_latch_cancel(IntPtr handle);
}
