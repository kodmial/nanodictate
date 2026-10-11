using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>Microphone/privacy failure handling and anti-storm policy.</summary>
public sealed class MicPrivacyTests
{
    [Fact]
    public void ClassifierMapsKnownHResults()
    {
        Assert.Equal(MicFailureKind.Denied, MicFailureClassifier.Classify(unchecked((int)0x80070005), "start"));
        Assert.Equal(MicFailureKind.NotFound, MicFailureClassifier.Classify(unchecked((int)0x80070490), "get default capture endpoint"));
        Assert.Equal(MicFailureKind.Disconnected, MicFailureClassifier.Classify(unchecked((int)0x88890004), "capture"));
        Assert.Equal(MicFailureKind.Other, MicFailureClassifier.Classify(-1, "other"));
    }

    [Fact]
    public void GuidancePointsAtPrivacySettings()
    {
        var message = MicPrivacyGuide.MessageFor(MicFailureKind.Denied);
        Assert.Contains("Microphone", message);
        Assert.Contains("Privacy", message);
        Assert.Equal("ms-settings:privacy-microphone", MicPrivacyGuide.SettingsUri);
    }

    [Fact]
    public void DeniedGuidanceNamesDesktopAppToggle()
    {
        var message = MicPrivacyGuide.MessageFor(MicFailureKind.Denied);
        Assert.Contains("Microphone", message);
        Assert.Contains("Let desktop apps access your microphone", message);
    }

    [Fact]
    public void RequestPolicyAllowsThenBlocksAfterThreeTimeouts()
    {
        var policy = new MicRequestPolicy(statePath: null);
        var now = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
        Assert.True(policy.AllowRequest(now));
        policy.RecordTimeout(now);
        policy.RecordTimeout(now.AddMinutes(1));
        Assert.True(policy.AllowRequest(now.AddMinutes(2)));
        policy.RecordTimeout(now.AddMinutes(2));
        Assert.False(policy.AllowRequest(now.AddMinutes(3)));
        policy.RecordGranted();
        Assert.True(policy.AllowRequest(now.AddMinutes(4)));
    }

    [Fact]
    public void RequestPolicyDecisionMatchesRustEngine()
    {
        var policy = new MicRequestPolicy(statePath: null);
        var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000);
        policy.RecordTimeout(now);
        var expected = NanoEngine.MicRequestAllowed(
            new double[] { now.ToUnixTimeMilliseconds() / 1000.0 },
            now.AddMinutes(1).ToUnixTimeMilliseconds() / 1000.0, 3, 21600.0);
        Assert.Equal(expected, policy.AllowRequest(now.AddMinutes(1)));
    }

    [Fact]
    public void RequestPolicyPersistsAcrossInstances()
    {
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-mic-{Guid.NewGuid():N}.json");
        try
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(3_000_000);
            var first = new MicRequestPolicy(path);
            first.RecordTimeout(now);
            first.RecordTimeout(now.AddMinutes(1));
            first.RecordTimeout(now.AddMinutes(2));
            var second = new MicRequestPolicy(path);
            Assert.False(second.AllowRequest(now.AddMinutes(3)));
        }
        finally
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    [Fact]
    public void CorruptStateMeansFreshAllow()
    {
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-mic-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, "not json{{{");
        try
        {
            var policy = new MicRequestPolicy(path);
            Assert.True(policy.AllowRequest(DateTimeOffset.UtcNow));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
