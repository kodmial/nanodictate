using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Strings, buffers, and error propagation across the boundary.
/// </summary>
public sealed class StringsBuffersErrorsTests
{
    [Fact]
    public void WordDiffVectorsMatchEngine()
    {
        var changed = NanoEngine.WordDiff("One three.", "One two three.");
        Assert.Contains("\"change\":true", changed);
        Assert.Contains("\"span_new\":\"two\"", changed);

        Assert.Equal("{\"change\":false}", NanoEngine.WordDiff("Same text.", "Same text."));
    }

    [Fact]
    public void UnicodeTextCrossesBoundary()
    {
        var diff = NanoEngine.WordDiff("Привет мир", "Привет большой мир");
        Assert.Contains("\"change\":true", diff);
        var joined = NanoEngine.TextJoin(new[] { "hello brave world", "brave world again" });
        Assert.Equal("hello brave world again", joined);
        var emoji = NanoEngine.TextJoin(new[] { "note 🎙️ test" });
        Assert.Equal("note 🎙️ test", emoji);
    }

    [Fact]
    public void WavEncodeDecodeRoundtrip()
    {
        var samples = new short[1600];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = (short)((i % 251) * 40);
        }
        var wav = NanoEngine.WavEncode(samples, 16000, 1);
        Assert.Equal(44 + samples.Length * 2, wav.Length);
        var info = NanoEngine.WavDecodeInfo(wav);
        Assert.Equal(16000u, info.SampleRate);
        Assert.Equal((ushort)1, info.Channels);
        Assert.Equal(samples.Length, info.SampleCount);
        Assert.Equal(samples, NanoEngine.WavDecodeSamples(wav));
    }

    [Fact]
    public void WavDecodeRejectsGarbage()
    {
        var ex = Assert.Throws<NanoException>(() => NanoEngine.WavDecodeInfo(new byte[] { 1, 2, 3 }));
        Assert.Equal(NanoErrorCodes.Decode, ex.Code);
        Assert.False(string.IsNullOrEmpty(ex.Message));
    }

    [Fact]
    public void SmallBufferMapsToCleanError()
    {
        // Decode through the byte-level path is covered in Rust; here the
        // host proves the diagnostic is recorded and non-empty.
        var samples = new short[] { 1, 2, 3 };
        var wav = NanoEngine.WavEncode(samples, 16000, 1);
        var ex = Assert.Throws<NanoException>(() => NanoEngine.WavDecodeInfo(new byte[4]));
        Assert.Equal(NanoErrorCodes.Decode, ex.Code);
        Assert.False(string.IsNullOrEmpty(NanoEngine.LastError()));
        Assert.True(wav.Length > 4);
    }

    [Fact]
    public void TranscriptParseRejectsInvalidJson()
    {
        // String-returning entries signal failure with NULL; the stable
        // code is recorded in the diagnostic, so the host asserts the
        // message (mirroring the Swift bridge, which maps NULL to -1).
        var ex = Assert.Throws<NanoException>(() => NanoEngine.TranscriptParse("nope"));
        Assert.False(string.IsNullOrEmpty(ex.Message));
    }

    [Fact]
    public void ReviewGateRejectsUnknownState()
    {
        var ex = Assert.Throws<NanoException>(() => NanoEngine.ShouldDropRetry((DictationState)99, 1, 1));
        Assert.False(string.IsNullOrEmpty(ex.Message));
    }
}
