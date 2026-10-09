using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Device-format normalization into the agreed 16 kHz mono engine ingress:
/// no dropped initial samples, channel downmix, resample ratio, flush.
/// </summary>
public sealed class AudioFormatConverterTests
{
    [Fact]
    public void EngineNativeFormatPassesThrough()
    {
        var converter = new AudioFormatConverter(new AudioFormat(16000, 1, 32, true));
        var input = new float[] { 0.1f, -0.2f, 0.3f, 0.0f };
        var output = new float[8];
        var written = converter.Convert(input, 4, output);
        Assert.Equal(4, written);
        Assert.Equal(input, output[..4]);
        Assert.Equal(4, converter.DeviceFramesConsumed);
        Assert.Equal(4, converter.EngineSamplesEmitted);
    }

    [Fact]
    public void FirstSamplesPreservedWithoutWarmupDrop()
    {
        // Immediate speech: the very first device frame must survive.
        var converter = new AudioFormatConverter(new AudioFormat(48000, 2, 32, true));
        var frames = new float[480 * 2];
        Array.Fill(frames, 0.02f);
        var output = new float[512];
        var written = converter.Convert(frames, 480, output);
        Assert.Equal(160, written);
        // First engine sample equals the input level (no warm-up drop).
        Assert.Equal(0.02f, output[0], precision: 5);
        Assert.All(output[..written], s => Assert.Equal(0.02f, s, precision: 5));
    }

    [Fact]
    public void DownmixAveragesChannels()
    {
        var converter = new AudioFormatConverter(new AudioFormat(16000, 2, 32, true));
        // Left 0.4, right -0.2 -> mono 0.1 per frame.
        var input = new float[] { 0.4f, -0.2f, 0.4f, -0.2f };
        var output = new float[4];
        var written = converter.Convert(input, 2, output);
        Assert.Equal(2, written);
        Assert.Equal(0.1f, output[0], precision: 5);
        Assert.Equal(0.1f, output[1], precision: 5);
    }

    [Fact]
    public void ResampleRatio48kTo16k()
    {
        var converter = new AudioFormatConverter(new AudioFormat(48000, 1, 32, true));
        var output = new float[4096];
        var total = 0;
        for (var i = 0; i < 10; i++)
        {
            var frames = new float[480];
            Array.Fill(frames, 0.01f);
            total += converter.Convert(frames, 480, output.AsSpan(total));
        }
        // 4800 device frames at 48 kHz -> 1600 engine samples at 16 kHz.
        Assert.Equal(1600, total);
        Assert.Equal(4800, converter.DeviceFramesConsumed);
        Assert.Equal(1600, converter.EngineSamplesEmitted);
    }

    [Fact]
    public void BlockBoundariesNeitherDropNorDuplicate()
    {
        var converter = new AudioFormatConverter(new AudioFormat(44100, 1, 32, true));
        var output = new float[8192];
        var total = 0;
        const int blocks = 20;
        const int framesPerBlock = 441;
        for (var i = 0; i < blocks; i++)
        {
            var frames = new float[framesPerBlock];
            Array.Fill(frames, 0.01f);
            total += converter.Convert(frames, framesPerBlock, output.AsSpan(total));
        }
        // 8820 frames @ 44.1 kHz -> ~3200 engine samples @ 16 kHz (+/-1 for phase).
        Assert.InRange(total, 3199, 3201);
        Assert.Equal(blocks * framesPerBlock, converter.DeviceFramesConsumed);
    }

    [Fact]
    public void FlushAndResetForRepeatedSessions()
    {
        var converter = new AudioFormatConverter(new AudioFormat(48000, 1, 32, true));
        var frames = new float[481];
        Array.Fill(frames, 0.01f);
        var output = new float[512];
        var written = converter.Convert(frames, 481, output);
        // 481 frames @ 48 kHz -> positions 0,3,...,480 -> 161 engine samples.
        Assert.Equal(161, written);
        var tail = new float[8];
        var flushed = converter.Flush(tail);
        Assert.True(flushed <= 1);
        converter.Reset();
        Assert.Equal(0, converter.DeviceFramesConsumed);
        Assert.Equal(0, converter.EngineSamplesEmitted);
        var again = converter.Convert(frames, 481, output);
        Assert.Equal(written, again);
    }

    [Fact]
    public void AudioFormatValidation()
    {
        Assert.Throws<NanoException>(() => new AudioFormat(0, 1, 32, true).Validate());
        Assert.Throws<NanoException>(() => new AudioFormat(48000, 0, 32, true).Validate());
        Assert.Throws<NanoException>(() => new AudioFormat(48000, 2, 8, true).Validate());
        Assert.Throws<NanoException>(() => new AudioFormatConverter(new AudioFormat(48000, 2, 16, false)));
        Assert.True(new AudioFormat(16000, 1, 32, true).IsEngineNative);
        Assert.False(new AudioFormat(48000, 2, 32, true).IsEngineNative);
        Assert.Equal("48000Hz-ch2", new AudioFormat(48000, 2, 32, true).Signature);
    }
}
