using System.Text;
using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Transcription product wiring goes through the shared Rust engine;
/// C# only frames I/O. Fake transports keep every test offline.
/// </summary>
public sealed class SttProductTests
{
    private static ProviderCatalog TwoProviders() => new(
        new[]
        {
            new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty),
            new ProviderEntry("b", "B", "https://b.test/v1/audio/transcriptions", string.Empty),
        },
        "a");

    private sealed class FakeTransport : ISttTransport
    {
        private readonly Queue<Func<SttHttpResponse>> _script = new();
        public readonly List<(string Url, byte[] Body)> Seen = new();

        public void Enqueue(SttHttpResponse response) => _script.Enqueue(() => response);
        public void EnqueueThrow(TranscribeError error) => _script.Enqueue(() => throw error);

        public Task<SttHttpResponse> SendAsync(string url, IReadOnlyDictionary<string, string> headers, byte[] body, string contentType, TimeSpan timeout, CancellationToken cancellationToken)
        {
            Seen.Add((url, body));
            return Task.FromResult(_script.Dequeue()());
        }
    }

    private static SttHttpResponse Ok(string text) => new(
        200,
        new Dictionary<string, string>(),
        Encoding.UTF8.GetBytes($"{{\"text\": \"{text}\"}}"));

    [Fact]
    public void BatchAndRealtimeProfilesResolveThroughRust()
    {
        var batch = SttProfile.Resolve("openai", string.Empty);
        Assert.Equal("batch_multipart", batch.Transport);
        Assert.Equal(16000u, batch.SampleRate);
        Assert.False(batch.IsStreaming);
        var realtime = SttProfile.Resolve("openai", "gpt-live-transcribe");
        Assert.Equal("streaming_session", realtime.Transport);
        Assert.True(realtime.IsStreaming);
        Assert.Equal(string.Empty, NanoEngine.SttDefaultBaseUrl("cloudflare"));
    }

    [Fact]
    public void MultipartPlanGatesFieldsAndRejectsStreaming()
    {
        var provider = new ProviderEntry("openai", "OpenAI", "https://api.test/v1/audio/transcriptions", string.Empty);
        var batch = SttProfile.Resolve("openai", string.Empty);
        var plan = SttRequestBuilder.Plan(provider, batch, new byte[] { 1, 2 }, "en", "bias", false, TransportConfig.Direct, "k", string.Empty);
        var body = Encoding.UTF8.GetString(plan.Body);
        Assert.Contains("name=\"file\"", body);
        Assert.DoesNotContain("verbose_json", body);
        var streaming = SttProfile.Resolve("openai", "gpt-live-transcribe");
        Assert.Throws<NanoException>(() => SttRequestBuilder.Plan(provider, streaming, new byte[] { 1 }, string.Empty, null, false, TransportConfig.Direct, string.Empty, string.Empty));
        var relay = new TransportConfig(SttTransportMode.CookieRelay, string.Empty, string.Empty, string.Empty, string.Empty, "X-Proxy-Key");
        Assert.Throws<NanoException>(() => SttRequestBuilder.Plan(provider, batch, new byte[] { 1 }, string.Empty, null, false, relay, string.Empty, string.Empty));
    }

    [Fact]
    public void ProxyRewritesAreMechanical()
    {
        var direct = TransportConfig.Direct;
        Assert.Equal("https://x.test/y", direct.RewriteUrl("https://x.test/y"));
        var proxy = new TransportConfig(SttTransportMode.HttpProxy, "https://proxy.test", "u", "p", string.Empty, "X-Proxy-Key");
        Assert.Equal("https://proxy.test/https://x.test/y", proxy.RewriteUrl("https://x.test/y"));
        Assert.Equal("http://plain.test/y", proxy.RewriteUrl("http://plain.test/y"));
        var gateway = new TransportConfig(SttTransportMode.Gateway, string.Empty, string.Empty, string.Empty, "secret", "X-Custom");
        var provider = new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty);
        var profile = SttProfile.Resolve("a", string.Empty);
        var plan = SttRequestBuilder.Plan(provider, profile, new byte[] { 1 }, string.Empty, null, false, gateway, string.Empty, "secret");
        Assert.Equal("secret", plan.Headers["X-Custom"]);
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("u:p")), proxy.ProxyAuthHeader());
    }

    [Fact]
    public async Task NormalClientSucceedsAndLogsDiagnostics()
    {
        var fake = new FakeTransport();
        fake.Enqueue(Ok("hello"));
        var client = new SttClient(TwoProviders(), fake, _ => "k", TimeSpan.FromSeconds(5));
        var diagnostics = new SttDiagnostics();
        var wav = NanoEngine.WavEncode(new short[160], 16000, 1);
        var result = await client.TranscribeWavAsync(wav, "en", null, false, TransportConfig.Direct, string.Empty, diagnostics, CancellationToken.None, _ => Task.CompletedTask);
        Assert.Equal("hello", result.Text);
        Assert.Equal("attempts=1 ok=1", diagnostics.Summarize().Substring(0, "attempts=1 ok=1".Length));
    }

    [Fact]
    public async Task RetryableFailureFailsOverToNextProvider()
    {
        var fake = new FakeTransport();
        fake.Enqueue(new SttHttpResponse(503, new Dictionary<string, string>(), Encoding.UTF8.GetBytes("busy")));
        fake.Enqueue(Ok("recovered"));
        var client = new SttClient(TwoProviders(), fake, _ => "k", TimeSpan.FromSeconds(5));
        var wav = NanoEngine.WavEncode(new short[160], 16000, 1);
        var result = await client.TranscribeWavAsync(wav, string.Empty, null, true, TransportConfig.Direct, string.Empty, null, CancellationToken.None, _ => Task.CompletedTask);
        Assert.Equal("recovered", result.Text);
        Assert.Equal(2, fake.Seen.Count);
        Assert.Contains("https://b.test", fake.Seen[1].Url);
    }

    [Fact]
    public async Task NonRetryableFailureNeverFailsOver()
    {
        var fake = new FakeTransport();
        fake.Enqueue(new SttHttpResponse(400, new Dictionary<string, string>(), Encoding.UTF8.GetBytes("bad")));
        var client = new SttClient(TwoProviders(), fake, _ => "k", TimeSpan.FromSeconds(5));
        var wav = NanoEngine.WavEncode(new short[160], 16000, 1);
        await Assert.ThrowsAsync<TranscribeError>(() => client.TranscribeWavAsync(wav, string.Empty, null, true, TransportConfig.Direct, string.Empty, null, CancellationToken.None, _ => Task.CompletedTask));
        Assert.Single(fake.Seen);
    }

    [Fact]
    public void ChunkedStitchAndFinalPassArePure()
    {
        var stitched = ChunkedTranscriber.Stitch(new[] { "hello brave world", "brave world again" });
        Assert.NotEmpty(stitched);
        Assert.True(ChunkedTranscriber.NeedsFinalPass(ChunkedFinalPass.Always, new[] { "a", "b" }, false));
        Assert.False(ChunkedTranscriber.NeedsFinalPass(ChunkedFinalPass.Never, new[] { "a" }, false));
        Assert.True(ChunkedTranscriber.NeedsFinalPass(ChunkedFinalPass.Never, new[] { "a" }, true));
        Assert.True(ChunkedTranscriber.NeedsFinalPass(ChunkedFinalPass.OnUncertainty, new[] { "   " }, false));
        Assert.False(ChunkedTranscriber.NeedsFinalPass(ChunkedFinalPass.OnUncertainty, new[] { "hello" }, false));
    }

    private sealed class FakeRealtimeTransport : IRealtimeTransport
    {
        public event Action<string>? Delta;
        public event Action<string>? Completed;
        public event Action<string>? Failed;
        public bool FailConnect;
        public readonly List<int> Frames = new();
        public Task ConnectAsync(RealtimeSessionOptions options, CancellationToken cancellationToken) =>
            FailConnect ? throw new InvalidOperationException("no route") : Task.CompletedTask;
        public Task AppendPcm16Async(short[] pcm24kMono, CancellationToken cancellationToken)
        {
            Frames.Add(pcm24kMono.Length);
            Delta?.Invoke("he");
            return Task.CompletedTask;
        }
        public Task CommitAsync(CancellationToken cancellationToken)
        {
            Completed?.Invoke("hello");
            return Task.CompletedTask;
        }
        public Task CloseAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        public void RaiseFailed(string message) => Failed?.Invoke(message);
    }

    [Fact]
    public async Task RealtimeSessionStreamsAndFailsClosed()
    {
        var transport = new FakeRealtimeTransport();
        using var session = new RealtimeSession(transport, RealtimeSessionOptions.Default());
        await session.ConnectAsync(CancellationToken.None);
        Assert.Equal(RealtimeSessionState.Ready, session.State);
        var input = new short[1600];
        await session.AppendAsync(input, CancellationToken.None);
        Assert.Equal(RealtimeSessionState.Streaming, session.State);
        Assert.Equal(2400, transport.Frames[0]);
        Assert.Equal("he", session.AccumulatedDelta);
        var text = await session.CommitAsync(CancellationToken.None);
        Assert.Equal("hello", text);
        Assert.Equal(RealtimeSessionState.Closed, session.State);
    }

    [Fact]
    public async Task RealtimeConnectFailureIsFailedState()
    {
        var transport = new FakeRealtimeTransport { FailConnect = true };
        using var session = new RealtimeSession(transport, RealtimeSessionOptions.Default());
        await Assert.ThrowsAsync<NanoException>(() => session.ConnectAsync(CancellationToken.None));
        Assert.Equal(RealtimeSessionState.Failed, session.State);
    }

    [Fact]
    public void RealtimeResampleRejectsUnexpectedRates()
    {
        Assert.Equal(2400, RealtimeSession.Resample16kTo24k(new short[1600], 16000).Length);
        Assert.Throws<NanoException>(() => RealtimeSession.Resample16kTo24k(new short[8], 8000));
    }

    [Fact]
    public void DiagnosticsRunOffline()
    {
        var checks = WindowsDiagnostics.Run(FindConfigExample());
        var names = checks.Select(c => c.Name).ToList();
        Assert.Contains("engine-abi", names);
        Assert.Contains("rust-policy", names);
        Assert.Contains("audio-pipeline", names);
        Assert.Contains("stt-profiles", names);
        var config = checks.FirstOrDefault(c => c.Name == "config");
        Assert.NotNull(config);
        Assert.True(config!.Passed, $"config check failed: {config.Detail}");
    }

    private static string FindConfigExample()
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
        throw new FileNotFoundException("config.example.toml not found from repo root");
    }
}
