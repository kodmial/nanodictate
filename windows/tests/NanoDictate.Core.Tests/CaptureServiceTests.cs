using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// End-to-end capture service behavior with the synthetic source:
/// repeated sessions, start-failure recovery, device-change abort, and
/// first-sample preservation. The WASAPI source itself is covered by
/// <see cref="WasapiSourceTests"/> (platform-gated).
/// </summary>
public sealed class CaptureServiceTests
{
    private static readonly AudioFormat Device48kStereo = new(48000, 2, 32, true);

    private static void EnqueueSpeech(SyntheticCaptureSource source, int deviceBlocks, float level = 0.02f)
    {
        for (var i = 0; i < deviceBlocks; i++)
        {
            source.EnqueueConstant(level, 480);
        }
    }

    private static bool WaitFor(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (condition())
            {
                return true;
            }
            Thread.Sleep(10);
        }
        return condition();
    }

    [Fact]
    public void RepeatedDictationSessionsEndToEnd()
    {
        using var source = new SyntheticCaptureSource(Device48kStereo);
        using var service = new DictationCaptureService(source);
        for (var session = 0; session < 2; session++)
        {
            var ready = false;
            void OnReady(CaptureMetrics _) => ready = true;
            service.CaptureReady += OnReady;
            try
            {
                EnqueueSpeech(source, 30);
                service.Start();
                Assert.True(WaitFor(() => ready, TimeSpan.FromSeconds(10)), "capture never became ready");
                Assert.True(service.IsCaptureReady);
                Assert.True(WaitFor(() => service.Snapshot().BlocksIngested >= 2, TimeSpan.FromSeconds(10)));
                var result = service.Stop();
                Assert.True(result.Samples.Count > 0);
                Assert.True(result.Metrics.BlocksIngested >= 2);
                service.FinishTranscription();
                Assert.Equal(DictationState.Idle, service.State);
            }
            finally
            {
                service.CaptureReady -= OnReady;
            }
        }
    }

    [Fact]
    public void SourceStartFailureReturnsSessionToIdleForRetry()
    {
        using var source = new SyntheticCaptureSource(Device48kStereo);
        using var service = new DictationCaptureService(source);
        source.FailNextStart();
        Assert.Throws<NanoException>(() => service.Start());
        Assert.Equal(DictationState.Idle, service.State);
        Assert.False(service.IsCaptureReady);

        // Recovery: the next start succeeds on the same service.
        var ready = false;
        void OnReady(CaptureMetrics _) => ready = true;
        service.CaptureReady += OnReady;
        try
        {
            EnqueueSpeech(source, 30);
            service.Start();
            Assert.True(WaitFor(() => ready, TimeSpan.FromSeconds(10)));
            service.Cancel();
            Assert.Equal(DictationState.Idle, service.State);
        }
        finally
        {
            service.CaptureReady -= OnReady;
        }
    }

    [Fact]
    public void DeviceChangeAbortsSession()
    {
        using var source = new SyntheticCaptureSource(Device48kStereo);
        using var service = new DictationCaptureService(source);
        Exception? changed = null;
        service.DeviceChanged += ex => changed = ex;
        EnqueueSpeech(source, 30);
        service.Start();
        Assert.True(WaitFor(() => service.IsCaptureReady, TimeSpan.FromSeconds(10)));
        source.SimulateDeviceChange();
        Assert.True(WaitFor(() => changed is not null, TimeSpan.FromSeconds(5)));
        Assert.False(service.IsRunning);
        Assert.NotNull(service.DeviceError);
        // The aborted session still yields its partial recording.
        var aborted = service.Stop();
        Assert.True(aborted.Samples.Count > 0);
        // The next session can start again after the abort.
        service.Start();
        service.Cancel();
    }

    [Fact]
    public void NoDroppedInitialSamples()
    {
        using var source = new SyntheticCaptureSource(Device48kStereo);
        using var service = new DictationCaptureService(source);
        // Speech from the very first queued block.
        EnqueueSpeech(source, 20, 0.03f);
        var ready = false;
        service.CaptureReady += _ => ready = true;
        service.Start();
        Assert.True(WaitFor(() => ready, TimeSpan.FromSeconds(10)));
        Assert.True(WaitFor(() => service.Snapshot().BlocksIngested >= 1, TimeSpan.FromSeconds(10)));
        var result = service.Stop();
        Assert.True(result.Samples.Count > 0);
        // Leading samples carry speech energy (attack not clipped).
        var head = result.Samples.Take(160).Select(s => Math.Abs((double)s)).Average();
        Assert.True(head > 50);
        service.FinishTranscription();
    }
}

/// <summary>Platform gate for the Windows-native WASAPI source.</summary>
public sealed class WasapiSourceTests
{
    [Fact]
    public void NonWindowsStartFailsLoudly()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }
        using var source = new WasapiCaptureSource();
        Assert.Throws<PlatformNotSupportedException>(() => source.Start());
        Assert.Throws<PlatformNotSupportedException>(() => source.ProbeDefaultFormat());
        Assert.False(source.IsRunning);
    }

    [Fact]
    public void WasapiSourceLifecycleIsIdempotent()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }
        using var source = new WasapiCaptureSource();
        source.Stop();
        source.Stop();
        source.Dispose();
    }
}
