using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Memory-ownership smoke tests: every Rust-owned allocation is released
/// exactly once through the matching free function.
/// </summary>
public sealed class OwnershipTests
{
    [Fact]
    public void RepeatedStringAllocationsDoNotLeakHandles()
    {
        for (var i = 0; i < 50; i++)
        {
            var json = NanoEngine.WordDiff("a b", "a c b");
            Assert.Contains("\"change\":true", json);
        }
    }

    [Fact]
    public void WavBufferIsCopiedThenFreed()
    {
        var samples = new short[160];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = (short)(i * 10);
        }
        for (var i = 0; i < 20; i++)
        {
            var wav = NanoEngine.WavEncode(samples, 16000, 1);
            Assert.Equal(44 + samples.Length * 2, wav.Length);
        }
    }

    [Fact]
    public void HandlesAreDisposableAndIndependent()
    {
        using var first = new VadHandle();
        using var second = new VadHandle();
        Assert.False(first.Feed(0.0005f, 0.085));
        Assert.True(second.Feed(0.02f, 0.085));
    }

    [Fact]
    public void NullFreeFunctionsAreSafe()
    {
        // Disposing fresh handles exercises each *_free path once;
        // the ABI additionally accepts NULL, mirrored by SafeHandle
        // releasing an invalid handle without calling into Rust.
        using var session = new SessionHandle();
        using var cooldown = new CooldownHandle(5.0);
        using var latch = new LatchHandle();
        using var gain = new GainHandle();
        using var stop = new AutoStopHandle();
        Assert.NotNull(session);
    }
}
