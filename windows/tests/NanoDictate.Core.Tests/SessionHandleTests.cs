using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Representative stateful-handle lifecycle shared with macOS:
/// VAD, gain, auto-stop, session readiness latch, cooldown, latch.
/// </summary>
public sealed class SessionHandleTests
{
    [Fact]
    public void SessionReadinessLatchFiresExactlyOnce()
    {
        using var session = new SessionHandle();
        var generation = session.Start();
        Assert.True(generation >= 1);

        session.OnEvent(SessionEvent.EngineStarted, generation);
        Assert.False(session.IsCaptureReady);
        Assert.False(session.ShouldEmitReadyCue());

        session.OnEvent(SessionEvent.FirstBuffer, generation);
        Assert.True(session.IsCaptureReady);
        Assert.True(session.ShouldEmitReadyCue());
        Assert.False(session.ShouldEmitReadyCue());
        Assert.Equal(DictationState.Recording, session.State);

        // Stale generations are rejected silently.
        session.OnEvent(SessionEvent.FirstBuffer, generation - 1);
        Assert.True(session.IsCaptureReady);
    }

    [Fact]
    public void SessionStopAndTranscriptionLifecycle()
    {
        using var session = new SessionHandle();
        var generation = session.Start();
        session.OnEvent(SessionEvent.FirstBuffer, generation);
        session.OnEvent(SessionEvent.StopRequested, generation);
        Assert.Equal(DictationState.Transcribing, session.State);
        Assert.False(session.IsCaptureReady);
        session.OnEvent(SessionEvent.TranscriptionDone, generation);
        Assert.Equal(DictationState.Idle, session.State);
    }

    [Fact]
    public void SessionCancelSuppressesReadiness()
    {
        using var session = new SessionHandle();
        var generation = session.Start();
        session.OnEvent(SessionEvent.Cancelled, generation);
        Assert.Equal(DictationState.Idle, session.State);
        Assert.False(session.IsCaptureReady);
        Assert.False(session.ShouldEmitReadyCue());
    }

    [Fact]
    public void VadFeedAndRealtimeIngress()
    {
        using var vad = new VadHandle();
        for (var i = 0; i < 30; i++)
        {
            Assert.False(vad.Feed(0.0005f, 0.085));
        }
        Assert.True(vad.Feed(0.02f, 0.085));

        vad.Reset();
        var quiet = new float[1360];
        Array.Fill(quiet, 0.0005f);
        Assert.False(vad.FeedSamples(quiet, 16000));
    }

    [Fact]
    public void GainAppliesInPlace()
    {
        using var gain = new GainHandle();
        var block = new float[1600];
        Array.Fill(block, 0.004f);
        var amplified = gain.Apply(block, 0.004f, 16000);
        Assert.True(amplified > 0.004f);
        Assert.All(block, s => Assert.True(Math.Abs(s) <= 1.0f));
    }

    [Fact]
    public void AutoStopFiresAfterSustainedSilence()
    {
        using var stop = new AutoStopHandle();
        for (var i = 0; i < 5; i++)
        {
            Assert.False(stop.Feed(0.02f, 0.1, null));
        }
        var fired = false;
        for (var i = 0; i < 60; i++)
        {
            fired = stop.Feed(0.0005f, 0.1, null);
        }
        Assert.True(fired);
    }

    [Fact]
    public void CooldownAndLatchVectors()
    {
        using var cooldown = new CooldownHandle(5.0);
        Assert.True(cooldown.Allow(0.0));
        Assert.False(cooldown.Allow(1.0));

        using var latch = new LatchHandle();
        latch.Arm();
        Assert.True(latch.Consume());
        Assert.False(latch.Consume());
        latch.Arm();
        latch.Cancel();
        Assert.False(latch.Consume());
    }
}
