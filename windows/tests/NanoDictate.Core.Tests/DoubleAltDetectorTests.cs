using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>Pure double-Alt detection vectors (mirrors the macOS detector).</summary>
public sealed class DoubleAltDetectorTests
{
    [Fact]
    public void PairWithinWindowFiresOnceThenResets()
    {
        var detector = new DoubleAltDetector(0.4);
        Assert.False(detector.RegisterTap(10.0));
        Assert.True(detector.RegisterTap(10.3));
        Assert.False(detector.IsPending);
        Assert.False(detector.RegisterTap(11.0));
    }

    [Fact]
    public void LateTapRestartsWindow()
    {
        var detector = new DoubleAltDetector(0.4);
        Assert.False(detector.RegisterTap(0.0));
        Assert.False(detector.RegisterTap(1.0));
        Assert.True(detector.RegisterTap(1.2));
    }

    [Fact]
    public void CancelPendingTapIsIdempotent()
    {
        var detector = new DoubleAltDetector();
        detector.CancelPendingTap();
        Assert.False(detector.RegisterTap(5.0));
        detector.CancelPendingTap();
        Assert.False(detector.IsPending);
    }

    [Fact]
    public void BoundaryIsInclusiveWithEpsilon()
    {
        var detector = new DoubleAltDetector(0.4);
        Assert.False(detector.RegisterTap(5.0));
        Assert.True(detector.RegisterTap(5.4));
    }
}
