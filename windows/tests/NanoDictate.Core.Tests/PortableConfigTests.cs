using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Portable configuration and shared product models go through the Rust
/// contracts; the host holds data only and never reimplements policy.
/// </summary>
public sealed class PortableConfigTests
{
    [Fact]
    public void SttResolveShapeMatchesEngine()
    {
        var json = NanoEngine.SttResolve("groq", "whisper-large-v3-turbo");
        Assert.Contains("\"transport\":\"batch_multipart\"", json);
        Assert.Contains("\"sample_rate\":16000", json);
    }

    [Fact]
    public void TranscriptParseExtractsText()
    {
        var json = NanoEngine.TranscriptParse("{\"text\": \"hi\"}");
        Assert.Contains("\"text\":\"hi\"", json);
    }

    [Fact]
    public void FailoverOrderAndBackoffMatchEngine()
    {
        Assert.Equal("b,c,a", NanoEngine.FailoverOrder(new[] { "a", "b", "c" }, "a", true));
        Assert.Equal(1, NanoEngine.FailoverCandidateCount(3, false));
        Assert.True(NanoEngine.ShouldFailover(0));
        Assert.False(NanoEngine.ShouldFailover(7));
        Assert.Equal(2000ul, NanoEngine.BackoffDelayMs(2, 500, 8000));
    }

    [Fact]
    public void ReviewAndGateVectorsMatchEngine()
    {
        Assert.True(NanoEngine.ReviewDecide("y"));
        Assert.False(NanoEngine.ReviewDecide(null));
        Assert.False(NanoEngine.ShouldDropRetry(DictationState.Idle, 2, 2));
        Assert.True(NanoEngine.ShouldDropRetry(DictationState.Recording, 1, 1));
        Assert.True(NanoEngine.OverlayShouldHide(DictationState.Idle));
        Assert.False(NanoEngine.OverlayShouldHide(DictationState.Transcribing));
        Assert.True(NanoEngine.MicRequestAllowed(new double[] { 900.0, 950.0 }, 1000.0, 3, 21600.0));
        Assert.False(NanoEngine.MicRequestAllowed(new double[] { 900.0, 950.0, 990.0 }, 1000.0, 3, 21600.0));
    }

    [Fact]
    public void ExampleConfigLoadsAndResolvesThroughRust()
    {
        var example = FindExampleConfig();
        Assert.True(File.Exists(example));
        var config = PortableConfig.Load(example);
        Assert.Equal("airubiz", config.ActiveProvider);
        Assert.NotEmpty(config.Providers);
        var profile = config.ResolveActiveProfile();
        Assert.Contains("\"adapter_id\"", profile);
        var order = config.ResolveFailoverOrder(null, false);
        Assert.Contains(config.Providers[0].Id, order);
    }

    [Fact]
    public void LoadStripsInlineCommentsOutsideQuotedValues()
    {
        var toml = """
            active_provider = "a" # trailing comment
            language = "en" # note
            [providers.a]
            name = "A" # trailing comment
            base_url = "https://example.test/#fragment"
            model = "x" # note
            """;
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-inline-comment-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, toml);
        try
        {
            var config = PortableConfig.Load(path);
            Assert.Equal("a", config.ActiveProvider);
            Assert.Equal("en", config.Language);
            var provider = Assert.Single(config.Providers);
            Assert.Equal("A", provider.Name);
            Assert.Equal("https://example.test/#fragment", provider.BaseUrl);
            Assert.Equal("x", provider.Model);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string FindExampleConfig()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "config.example.toml");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        // Fallback for CI layouts: walk further up from the worktree root.
        throw new FileNotFoundException("config.example.toml not found");
    }
}
