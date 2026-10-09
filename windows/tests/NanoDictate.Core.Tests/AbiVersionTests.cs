using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>ABI handshake shared with macOS: version check only.</summary>
public sealed class AbiVersionTests
{
    [Fact]
    public void AbiVersionIsOne()
    {
        Assert.Equal(1u, NanoEngine.AbiVersion());
    }

    [Fact]
    public void CheckAvailableAcceptsLinkedVersion()
    {
        NanoEngine.CheckAvailable();
    }

    [Fact]
    public void CheckAvailableRejectsMismatch()
    {
        var ex = Assert.Throws<NanoException>(() => NanoEngine.CheckAvailable(expected: 9999));
        Assert.Contains("ABI mismatch", ex.Message);
    }
}
