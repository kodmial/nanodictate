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
    public void UnknownActiveProviderFallsBackToFirstConfiguredProvider()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "missing",
            Providers = new[]
            {
                new ProviderEntry("a", "A", string.Empty, string.Empty),
                new ProviderEntry("b", "B", string.Empty, string.Empty),
            },
        };
        using var app = new HostApp(config, new FakeSource(), new FakeInsertions(), new FakeTransport(), _ => string.Empty);
        Assert.Equal("a", app.ActiveProviderId);
        Assert.Equal("A", app.SessionLabel.Provider);
    }

    [Fact]
    public void EmptyProviderConfigurationPreservesStartup()
    {
        var config = new PortableConfig();
        using var app = new HostApp(config, new FakeSource(), new FakeInsertions(), new FakeTransport(), _ => string.Empty);
        using var coordinator = new HudCoordinator(app, useTimer: false);
        Assert.False(string.IsNullOrWhiteSpace(app.SessionLabel.Provider));
        Assert.Equal("NanoDictate", coordinator.Snapshot.Provider);
    }

    [Fact]
    public void SelectProviderPersistsActiveSelection()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[]
            {
                new ProviderEntry("a", "A", string.Empty, string.Empty),
                new ProviderEntry("b", "B", string.Empty, string.Empty),
            },
        };
        using var app = new HostApp(config, new FakeSource(), new FakeInsertions(), new FakeTransport(), _ => string.Empty);
        app.SelectProvider("b");
        Assert.Equal("b", app.ActiveProviderId);
        Assert.Equal("b", app.Catalog.Active().Id);
        var list = app.ListProviders();
        Assert.True(list.First(p => p.Id == "b").IsActive);
        Assert.False(list.First(p => p.Id == "a").IsActive);
        Assert.Throws<NanoException>(() => app.SelectProvider("missing"));
    }

    [Fact]
    public void SelectProviderSynchronizesActiveProviderForDefaultApiKeyResolution()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[]
            {
                new ProviderEntry("a", "A", string.Empty, string.Empty),
                new ProviderEntry("b", "B", string.Empty, string.Empty),
            },
        };
        var previousKey = Environment.GetEnvironmentVariable("NANODICTATE_API_KEY");
        try
        {
            Environment.SetEnvironmentVariable("NANODICTATE_API_KEY", "env-key");
            using var app = new HostApp(config, new FakeSource(), new FakeInsertions(), new FakeTransport());
            app.SelectProvider("b");
            Assert.Equal("b", config.ActiveProvider);
            Assert.Equal("env-key", HostApp.ResolveApiKey("b", config));
            Assert.Equal(string.Empty, HostApp.ResolveApiKey("a", config));
        }
        finally
        {
            Environment.SetEnvironmentVariable("NANODICTATE_API_KEY", previousKey);
        }
    }

    [Fact]
    public void OmittedActiveProviderKeepsEnvironmentKeyForEveryProvider()
    {
        var config = new PortableConfig
        {
            ActiveProvider = string.Empty,
            Providers = new[]
            {
                new ProviderEntry("a", "A", string.Empty, string.Empty),
                new ProviderEntry("b", "B", string.Empty, string.Empty),
            },
        };
        var previousKey = Environment.GetEnvironmentVariable("NANODICTATE_API_KEY");
        try
        {
            Environment.SetEnvironmentVariable("NANODICTATE_API_KEY", "env-key");
            using var app = new HostApp(config, new FakeSource(), new FakeInsertions(), new FakeTransport());
            Assert.Equal(string.Empty, config.ActiveProvider);
            Assert.Equal("a", app.Catalog.Active().Id);
            Assert.Equal("env-key", HostApp.ResolveApiKey("a", config));
            Assert.Equal("env-key", HostApp.ResolveApiKey("b", config));
        }
        finally
        {
            Environment.SetEnvironmentVariable("NANODICTATE_API_KEY", previousKey);
        }
    }

    [Fact]
    public async Task ReviewEnabledWithoutPromptFailsClosed()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            ReviewBeforeInsert = true,
            Providers = new[] { new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty) },
        };
        var insertions = new FakeInsertions();
        using var app = new HostApp(config, new FakeSource(), insertions, new FakeTransport(), _ => "k");
        var deliveries = new List<DictationDelivery>();
        app.DeliveryCompleted += deliveries.Add;

        var inserted = await app.TranscribeAndDeliverAsync(
            new short[1600], 16000, null, CancellationToken.None);

        Assert.False(inserted);
        Assert.Empty(insertions.Inserted);
        var delivery = Assert.Single(deliveries);
        Assert.False(delivery.Inserted);
        Assert.Equal("hi there", delivery.Text);
    }

    [Fact]
    public async Task ReviewPromptFailureFailsClosed()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            ReviewBeforeInsert = true,
            Providers = new[] { new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty) },
        };
        var insertions = new FakeInsertions();
        using var app = new HostApp(config, new FakeSource(), insertions, new FakeTransport(), _ => "k");
        app.Controller.ReviewPrompt = new ThrowingReviewPrompt();

        var inserted = await app.TranscribeAndDeliverAsync(
            new short[1600], 16000, null, CancellationToken.None);

        Assert.False(inserted);
        Assert.Empty(insertions.Inserted);
    }

    private sealed class ThrowingReviewPrompt : IReviewPrompt
    {
        public string? Ask(string text) => throw new InvalidOperationException("no UI");
    }

    [Fact]
    public void HostAppWiresStopTranscriptionHandler()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[] { new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty) },
        };
        using var app = new HostApp(config, new FakeSource(), new FakeInsertions(), new FakeTransport(), _ => "k");
        Assert.NotNull(app.Controller.StopTranscriptionHandler);
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
    public void NonChunkedWatchdogIncludesFailoverAndBackoff()
    {
        var config = new PortableConfig
        {
            Chunked = false,
            TimeoutSeconds = 30,
            AutoFailover = true,
            Providers = new[]
            {
                new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty),
                new ProviderEntry("b", "B", "https://b.test/v1/audio/transcriptions", string.Empty),
            },
        };
        var backoff = TimeSpan.FromMilliseconds(
            NanoEngine.BackoffDelayMs(0, 500, 8000) +
            NanoEngine.BackoffDelayMs(1, 500, 8000));
        Assert.Equal(TimeSpan.FromSeconds(65) + backoff,
            HostApp.InitialProcessingWatchdog(config));
        config.AutoFailover = false;
        Assert.Equal(TimeSpan.FromSeconds(35) +
            TimeSpan.FromMilliseconds(NanoEngine.BackoffDelayMs(0, 500, 8000)),
            HostApp.InitialProcessingWatchdog(config));
    }

    [Fact]
    public void ChunkedProcessingBudgetCoversEveryPlannedRequest()
    {
        var config = new PortableConfig
        {
            Chunked = true,
            TimeoutSeconds = 30,
            AutoFailover = true,
            Providers = new[]
            {
                new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty),
                new ProviderEntry("b", "B", "https://b.test/v1/audio/transcriptions", string.Empty),
            },
        };
        const int sampleRate = 16000;
        var samples = new short[sampleRate * 120];
        var chunks = NanoEngine.BatchPlan(samples.Length, sampleRate, 45.0, 1.0);
        var finalAttempts = NanoEngine.FailoverCandidateCount(config.Providers.Count, config.AutoFailover);

        var budget = HostApp.ChunkedProcessingBudget(config, samples.Length, sampleRate);
        var chunkBackoff = TimeSpan.FromMilliseconds(
            NanoEngine.BackoffDelayMs(0, 500, 8000) * (ulong)chunks.Length);

        Assert.True(chunks.Length > 1);
        Assert.True(finalAttempts > 1);
        Assert.Equal(
            TimeSpan.FromSeconds(
                config.TimeoutSeconds * (chunks.Length + finalAttempts)
                + (finalAttempts - 1) * 8
                + 5)
            + chunkBackoff,
            budget);
        Assert.True(budget > HostApp.InitialProcessingWatchdog(config));
    }

    [Fact]
    public void ChunkedProcessingBudgetCoversFailedChunksBeforeSuccessfulFinalPass()
    {
        var config = new PortableConfig
        {
            Chunked = true,
            ChunkedFinalPass = ChunkedFinalPass.OnUncertainty,
            TimeoutSeconds = 30,
            AutoFailover = false,
            Providers = new[]
            {
                new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty),
            },
        };
        const int sampleRate = 16000;
        var samples = new short[sampleRate * 120];
        var chunks = NanoEngine.BatchPlan(samples.Length, sampleRate, 45.0, 1.0);
        var finalAttempts = NanoEngine.FailoverCandidateCount(config.Providers.Count, config.AutoFailover);
        var perRequest = TimeSpan.FromSeconds(config.TimeoutSeconds);
        var perChunkBackoff = TimeSpan.FromMilliseconds(NanoEngine.BackoffDelayMs(0, 500, 8000));

        var budget = HostApp.ChunkedProcessingBudget(config, samples.Length, sampleRate);

        // Worst valid timeline: every chunk exhausts its timeout and its
        // retry backoff, then the final pass succeeds.
        var validTimeline = TimeSpan.FromTicks(
            perRequest.Ticks * (chunks.Length + finalAttempts)
            + perChunkBackoff.Ticks * chunks.Length);
        Assert.True(chunks.Length > 1);
        Assert.Equal(1, finalAttempts);
        Assert.True(budget >= validTimeline);
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
