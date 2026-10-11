using System.Text;
using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>Product composition: config → catalog → transcribe → controller.</summary>
public sealed class HostAppTests
{
    private sealed class FakeInsertions : IInsertionSink
    {
        public readonly List<string> Inserted = new();
        public void Insert(string text, InsertMethod method) => Inserted.Add(text);
        public void DeleteText(string insertedText) { }
        public void DeleteGraphemes(int count) { }
        public void PostEnter() { }
    }

    private sealed class FakeTransport : ISttTransport
    {
        public Task<SttHttpResponse> SendAsync(string url, IReadOnlyDictionary<string, string> headers, byte[] body, string contentType, TimeSpan timeout, CancellationToken cancellationToken) =>
            Task.FromResult(new SttHttpResponse(200, new Dictionary<string, string>(), Encoding.UTF8.GetBytes("{\"text\": \"hi there\"}")));
    }

    private sealed class FakeSource : IAudioCaptureSource
    {
        public AudioFormat Format => new(16000, 1, 32, true);
        public bool IsRunning => false;
        public event Action<CapturedBlock>? BlockAvailable;
        public event Action<Exception>? DeviceChanged;
        public void Start() { }
        public void Stop() { }
        public void Dispose() { }
    }

    [Fact]
    public async Task TranscribeAndDeliverInsertsOnce()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[] { new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty) },
        };
        var capture = new FakeSource();
        var insertions = new FakeInsertions();
        using var app = new HostApp(config, capture, insertions, new FakeTransport(), _ => "k");
        var samples = new short[1600];
        var delivered = await app.TranscribeAndDeliverAsync(samples, 16000, null, CancellationToken.None);
        Assert.True(delivered);
        Assert.Equal(new[] { "hi there" }, insertions.Inserted);
    }

    [Fact]
    public void ProviderListingMarksActive()
    {
        var config = new PortableConfig
        {
            ActiveProvider = string.Empty,
            Providers = new[]
            {
                new ProviderEntry("a", "A", string.Empty, string.Empty),
                new ProviderEntry("b", string.Empty, string.Empty, string.Empty),
            },
        };
        using var app = new HostApp(config, new FakeSource(), new FakeInsertions(), new FakeTransport(), _ => string.Empty);
        var list = app.ListProviders();
        Assert.Equal(2, list.Count);
        Assert.True(list[0].IsActive);
        Assert.Equal("b", list[1].Id);
    }

    [Fact]
    public void ExtendedConfigParsesTransportAndModes()
    {
        var toml = """
            active_provider = "a"
            transport = "http"
            http_proxy = "https://proxy.test"
            chunked = true
            chunked_final_pass = "never"
            timeout_seconds = 30
            auto_failover = true
            [providers.a]
            name = "A"
            base_url = "https://a.test/v1/audio/transcriptions"
            model = "m"
            """;
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-hostcfg-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, toml);
        try
        {
            var config = PortableConfig.Load(path);
            Assert.Equal(SttTransportMode.HttpProxy, config.Transport.Transport);
            Assert.True(config.Chunked);
            Assert.Equal(ChunkedFinalPass.Never, config.ChunkedFinalPass);
            Assert.Equal(30, config.TimeoutSeconds);
            Assert.True(config.AutoFailover);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void PackagingAndDocsExist()
    {
        var root = FindRepoRoot();
        Assert.True(File.Exists(Path.Combine(root, "windows", "package", "Package.appxmanifest")));
        Assert.True(File.Exists(Path.Combine(root, "windows", "package", "make-msix.ps1")));
        Assert.True(File.Exists(Path.Combine(root, "windows", "DISTRIBUTION.md")));
        Assert.True(File.Exists(Path.Combine(root, "windows", "PARITY.md")));
        Assert.True(File.Exists(Path.Combine(root, "windows", "VALIDATION.md")));
        Assert.True(File.Exists(Path.Combine(root, "windows", "src", "NanoDictate.App", "NanoDictate.App.csproj")));
        Assert.True(File.Exists(Path.Combine(root, "windows", "src", "NanoDictate.Host", "NanoDictate.Host.csproj")));
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Package.swift")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new FileNotFoundException("repo root not found");
    }
}
