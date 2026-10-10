using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Windows capture through the shared Rust session/audio pipeline:
/// repeated sessions, first-word robustness, fail-closed errors, and
/// realtime instrumentation. All ingress executes through the production
/// Rust VAD/gain/auto-stop/session handles; nothing is forked in C#.
/// </summary>
public sealed class RealtimeAudioPipelineTests
{
    private static readonly AudioFormat Device48kStereo = new(48000, 2, 32, true);

    /// <summary>Builds one device block of constant value (interleaved).</summary>
    private static CapturedBlock ConstantBlock(float value, int frames = 480)
    {
        var interleaved = new float[frames * Device48kStereo.Channels];
        Array.Fill(interleaved, value);
        return new CapturedBlock(interleaved, frames, Device48kStereo);
    }

    /// <summary>Feeds enough device blocks for <paramref name="engineBlocks"/> full engine blocks.</summary>
    private static void FeedEngineBlocks(RealtimeAudioPipeline pipeline, float value, int engineBlocks)
    {
        // 4800 device frames @ 48 kHz -> 1600 engine samples (1 engine block).
        var deviceBlocks = engineBlocks * 10;
        for (var i = 0; i < deviceBlocks; i++)
        {
            pipeline.IngestDeviceBlock(ConstantBlock(value));
        }
    }

    [Fact]
    public void StartAloneNeverReportsReadiness()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        Assert.False(pipeline.IsCaptureReady);
        Assert.Equal(DictationState.Recording, pipeline.State);
        pipeline.Cancel();
        Assert.Equal(DictationState.Idle, pipeline.State);
    }

    [Fact]
    public void ImmediateSpeechFirstBlockIsReadyAndPreserved()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        CaptureMetrics? ready = null;
        pipeline.CaptureReady += m => ready = m;
        pipeline.Start();
        // Immediate speech as the very first device packet.
        pipeline.IngestDeviceBlock(ConstantBlock(0.02f));
        for (var i = 0; i < 9; i++)
        {
            pipeline.IngestDeviceBlock(ConstantBlock(0.02f));
        }
        Assert.True(pipeline.IsCaptureReady);
        Assert.NotNull(ready);
        Assert.True(ready!.Value.BlocksIngested >= 1);
        // First-word audio survived: the recording starts with speech energy.
        var result = pipeline.Stop();
        Assert.True(result.Samples.Count >= RealtimeAudioPipeline.EngineBlockSamples);
        Assert.True(Math.Abs(result.Samples[0]) > 100);
        pipeline.FinishTranscription();
        Assert.Equal(DictationState.Idle, pipeline.State);
    }

    [Fact]
    public void RepeatedSessionsThroughSameRustCore()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        var firstGen = 0UL;
        for (var session = 0; session < 3; session++)
        {
            var readyCount = 0;
            void OnReady(CaptureMetrics _) => readyCount++;
            pipeline.CaptureReady += OnReady;
            try
            {
                pipeline.Start();
                Assert.False(pipeline.IsCaptureReady);
                FeedEngineBlocks(pipeline, 0.02f, 2);
                Assert.True(pipeline.IsCaptureReady);
                Assert.Equal(1, readyCount);
                var result = pipeline.Stop();
                Assert.True(result.Metrics.BlocksIngested >= 2);
                Assert.True(result.Samples.Count > 0);
                Assert.True(pipeline.Generation > firstGen);
                firstGen = pipeline.Generation;
                pipeline.FinishTranscription();
                Assert.Equal(DictationState.Idle, pipeline.State);
            }
            finally
            {
                pipeline.CaptureReady -= OnReady;
            }
        }
        Assert.True(firstGen >= 3);
    }

    [Fact]
    public void CancelSuppressesReadinessAndStopAfterCancelThrows()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        pipeline.Cancel();
        Assert.False(pipeline.IsCaptureReady);
        Assert.Equal(DictationState.Idle, pipeline.State);
        Assert.Throws<NanoException>(() => pipeline.Stop());
    }

    [Fact]
    public void RustAutoStopFiresThroughSharedEngine()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        IReadOnlyList<short>? stopped = null;
        pipeline.AutoStop += s => stopped = s;
        pipeline.Start();
        FeedEngineBlocks(pipeline, 0.02f, 10);
        FeedEngineBlocks(pipeline, 0.0005f, 60);
        Assert.True(pipeline.AutoStopFired);
        Assert.NotNull(stopped);
        var metrics = pipeline.Snapshot();
        Assert.True(metrics.AutoStopFired);
        Assert.True(metrics.BlocksIngested >= 70);
        // Realtime work stays bounded: mean block cost is sub-millisecond
        // scale on any CI host (generous 5 ms ceiling guards regressions).
        Assert.True(metrics.MeanBlockMs < 5.0);
        pipeline.Cancel();
    }

    [Fact]
    public void MetricsTrackCopiesAndDeviceAccounting()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        FeedEngineBlocks(pipeline, 0.01f, 3);
        var metrics = pipeline.Snapshot();
        Assert.Equal(3, metrics.BlocksIngested);
        Assert.Equal(0, metrics.EngineErrors);
        Assert.Equal(2, metrics.CopiesPerBlock);
        Assert.Equal(3 * 4800, metrics.DeviceFramesConsumed);
        Assert.Equal(3 * 1600, metrics.EngineSamplesEmitted);
        Assert.True(metrics.MaxBlockMs >= metrics.MeanBlockMs);
        Assert.True(metrics.RequestToEngineStartedMs >= 0.0);
        pipeline.Cancel();
    }

    [Fact]
    public void VadDiagnosticsAndHandleResetsAreGreen()
    {
        using var vad = new VadHandle();
        var quiet = new float[1600];
        Array.Fill(quiet, 0.0005f);
        vad.FeedSamples(quiet, 16000);
        var diag = vad.Diagnostics();
        Assert.True(diag.NoiseFloor > 0.0f);
        Assert.True(diag.EnterThreshold > diag.ExitThreshold);
        vad.Reset();

        using var gain = new GainHandle();
        var block = new float[1600];
        Array.Fill(block, 0.004f);
        var amplified = gain.Apply(block, 0.004f, 16000);
        Assert.True(amplified > 0.0f);
        gain.Reset();
        Assert.True(gain.CurrentGainDb >= 0.0f);

        using var stop = new AutoStopHandle();
        stop.Feed(0.02f, 0.1, true);
        stop.Reset();
        Assert.False(stop.Feed(0.0005f, 0.1, false));
    }

    [Fact]
    public void ConverterBindsToFirstBlockFormatInsteadOfConstructorFormat()
    {
        // The constructor format may be the unresolved device placeholder
        // (WASAPI resolves the mix format after the pipeline is built); the
        // converter must follow the first captured block instead.
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        var resolved = new AudioFormat(16000, 1, 32, true);
        var frames = new float[480];
        Array.Fill(frames, 0.02f);
        for (var i = 0; i < 4; i++)
        {
            pipeline.IngestDeviceBlock(new CapturedBlock(frames, 480, resolved));
        }
        Assert.True(pipeline.BlocksIngested >= 1);
        pipeline.Cancel();
    }

    [Fact]
    public void MidSessionFormatChangeIsRejected()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        pipeline.IngestDeviceBlock(ConstantBlock(0.02f));
        var changed = new AudioFormat(44100, 2, 32, true);
        var frames = new float[480 * changed.Channels];
        Assert.Throws<NanoException>(
            () => pipeline.IngestDeviceBlock(new CapturedBlock(frames, 480, changed)));
        pipeline.Cancel();
    }

    [Fact]
    public void AbortedSessionHarvestsExactlyOnce()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        FeedEngineBlocks(pipeline, 0.02f, 2);
        pipeline.Abort();
        Assert.Equal(DictationState.Idle, pipeline.State);
        Assert.True(pipeline.TryHarvestAborted(out var first));
        Assert.True(first.Samples.Count > 0);
        Assert.False(pipeline.TryHarvestAborted(out _));
    }

    [Fact]
    public void CancelledSessionIsNotHarvestable()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        FeedEngineBlocks(pipeline, 0.02f, 2);
        pipeline.Cancel();
        Assert.False(pipeline.TryHarvestAborted(out _));
    }

    [Fact]
    public void StoppedSessionIsNotHarvestable()
    {
        using var pipeline = new RealtimeAudioPipeline(Device48kStereo);
        pipeline.Start();
        FeedEngineBlocks(pipeline, 0.02f, 2);
        var stopped = pipeline.Stop();
        Assert.True(stopped.Samples.Count > 0);
        Assert.False(pipeline.TryHarvestAborted(out _));
        pipeline.FinishTranscription();
        Assert.Equal(DictationState.Idle, pipeline.State);
    }

    [Fact]
    public void SegmentationPlansThroughSharedEngine()
    {
        // Batch planning is pure count math: deterministic chunk cover.
        var chunks = NanoEngine.BatchPlan(64000, 16000, 45.0, 1.0);
        Assert.True(chunks.Length >= 1);
        Assert.Equal(0, chunks[0].BodyStart);

        // Live planning over a voiced recording never throws and covers
        // the source range (exact segment count is engine policy).
        var samples = new short[64000];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = (short)(Math.Sin(i * 0.05) * 8000);
        }
        var segments = NanoEngine.LivePlan(samples, 16000);
        Assert.NotNull(segments);
        foreach (var seg in segments)
        {
            Assert.True(seg.BodyStart >= 0 && seg.BodyEnd <= samples.Length);
        }
    }
}
