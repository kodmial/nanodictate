using System.Diagnostics;

namespace NanoDictate.Core;

/// <summary>
/// Timing and cost snapshot for one dictation capture session through the
/// shared Rust core. Timing uses the monotonic <see cref="Stopwatch"/>
/// clock (never wall-clock, never audio content).
/// </summary>
public readonly record struct CaptureMetrics(
    double? TriggerToRequestMs,
    double RequestToEngineStartedMs,
    double EngineStartedToFirstBufferMs,
    double RequestToFirstBufferMs,
    int BlocksIngested,
    int EngineErrors,
    double MeanBlockMs,
    double MaxBlockMs,
    long CpuMs,
    long WorkingSetBytes,
    long DeviceFramesConsumed,
    long EngineSamplesEmitted,
    int CollectedSamples,
    int CopiesPerBlock,
    bool AutoStopFired)
{
    public static CaptureMetrics Empty => new(
        null, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, false);
}

/// <summary>Monotonic clock helpers shared by the capture pipeline.</summary>
internal static class CaptureClock
{
    public static ulong Nanos => (ulong)(Stopwatch.GetTimestamp() * 1_000_000_000L / Stopwatch.Frequency);

    public static double MsBetween(ulong start, ulong end) =>
        end >= start ? (double)(end - start) / 1_000_000.0 : 0.0;
}
