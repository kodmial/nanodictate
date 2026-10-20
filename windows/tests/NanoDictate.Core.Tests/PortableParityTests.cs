using System.Text;
using System.Text.Json;
using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Cross-platform contract vectors shared with the Swift suite
/// (Tests/Fixtures/portable-parity.json). Configuration and request
/// assertions only cover fields both hosts advertise; intentional
/// platform differences live in docs/config-parity.md.
/// </summary>
public sealed class PortableParityTests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
    };

    private sealed class FixtureRoot
    {
        public int Version { get; set; }
        public List<ConfigCase> ConfigCases { get; set; } = new();
        public List<RequestCase> RequestCases { get; set; } = new();
    }

    private sealed class ConfigCase
    {
        public string Name { get; set; } = string.Empty;
        public Dictionary<string, string> Env { get; set; } = new();
        public List<string> Config { get; set; } = new();
        public Dictionary<string, string> Files { get; set; } = new();
        public ExpectedConfig Expected { get; set; } = new();
    }

    private sealed class ExpectedConfig
    {
        public string ActiveProvider { get; set; } = string.Empty;
        public string Language { get; set; } = string.Empty;
        public string SegmentProvider { get; set; } = string.Empty;
        public string FinalProvider { get; set; } = string.Empty;
        public List<ExpectedProvider> Providers { get; set; } = new();
        public List<string>? FailoverOrder { get; set; }
        public Dictionary<string, string> ResolvedApiKeys { get; set; } = new();
    }

    private sealed class ExpectedProvider
    {
        public string Id { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string BaseUrl { get; set; } = string.Empty;
        public string Model { get; set; } = string.Empty;
    }

    private sealed class RequestCase
    {
        public string Name { get; set; } = string.Empty;
        public RequestProvider Provider { get; set; } = new();
        public string Language { get; set; } = string.Empty;
        public string? Prompt { get; set; }
        public bool NeedsWordTimestamps { get; set; }
        public ExpectedRequest Expected { get; set; } = new();
    }

    private sealed class RequestProvider
    {
        public string Id { get; set; } = string.Empty;
        public string BaseUrl { get; set; } = string.Empty;
        public string Model { get; set; } = string.Empty;
        public string ApiKey { get; set; } = string.Empty;
    }

    private sealed class ExpectedRequest
    {
        public string Url { get; set; } = string.Empty;
        public string? Authorization { get; set; }
        public Dictionary<string, string> Fields { get; set; } = new();
        public List<string> Absent { get; set; } = new();
        public string FileContentType { get; set; } = string.Empty;
    }

    [Fact]
    public void SharedConfigVectorsMatchWindowsProductionPath()
    {
        var fixture = LoadFixture();
        Assert.Equal(1, fixture.Version);
        Assert.NotEmpty(fixture.ConfigCases);
        foreach (var testCase in fixture.ConfigCases)
        {
            WithEnv(testCase.Env, () => AssertConfigCase(testCase));
        }
    }

    [Fact]
    public void SharedRequestVectorsMatchWindowsProductionPath()
    {
        var fixture = LoadFixture();
        Assert.NotEmpty(fixture.RequestCases);
        foreach (var testCase in fixture.RequestCases)
        {
            var provider = new ProviderEntry(
                testCase.Provider.Id,
                testCase.Provider.Id,
                testCase.Provider.BaseUrl,
                testCase.Provider.Model,
                testCase.Provider.ApiKey);
            var model = string.IsNullOrEmpty(provider.Model)
                ? NanoEngine.SttDefaultModel(provider.Id)
                : provider.Model;
            var profile = SttProfile.Resolve(provider.Id, model);
            var plan = SttRequestBuilder.Plan(
                provider, profile, new byte[] { 1, 2, 3 },
                testCase.Language, testCase.Prompt, testCase.NeedsWordTimestamps,
                TransportConfig.Direct, provider.ApiKey, string.Empty);
            var body = Encoding.UTF8.GetString(plan.Body);
            var expected = testCase.Expected;
            Assert.Equal(expected.Url, plan.Url);
            if (expected.Authorization is null)
            {
                Assert.False(plan.Headers.ContainsKey("Authorization"), testCase.Name);
            }
            else
            {
                Assert.Equal(expected.Authorization, plan.Headers["Authorization"]);
            }
            foreach (var field in expected.Fields)
            {
                Assert.Contains($"name=\"{field.Key}\"\r\n\r\n{field.Value}\r\n", body);
            }
            foreach (var absent in expected.Absent)
            {
                Assert.DoesNotContain($"name=\"{absent}\"\r\n", body);
            }
            Assert.Contains(
                $"name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: {expected.FileContentType}\r\n\r\n",
                body);
        }
    }

    [Fact]
    public async Task FailoverRequestsUseEachProvidersConfiguredKey()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[]
            {
                new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty, ApiKey: "key-a"),
                new ProviderEntry("b", "B", "https://b.test/v1/audio/transcriptions", string.Empty, ApiKey: "key-b"),
            },
        };
        await WithEnv(new Dictionary<string, string>(), async () =>
        {
            var fake = new CapturingTransport(
                new SttHttpResponse(503, new Dictionary<string, string>(), Encoding.UTF8.GetBytes("busy")),
                new SttHttpResponse(200, new Dictionary<string, string>(), Encoding.UTF8.GetBytes("{\"text\":\"ok\"}")));
            var catalog = new ProviderCatalog(config.Providers, config.ActiveProvider);
            var client = new SttClient(catalog, fake, id => HostApp.ResolveApiKey(id, config), TimeSpan.FromSeconds(5));
            var wav = NanoEngine.WavEncode(new short[160], 16000, 1);
            var result = await client.TranscribeWavAsync(
                wav, string.Empty, null, true, TransportConfig.Direct, string.Empty,
                null, CancellationToken.None, _ => Task.CompletedTask);
            Assert.Equal("ok", result.Text);
            Assert.Equal(new[] { "Bearer key-a", "Bearer key-b" }, fake.Authorizations);
        });
    }

    [Fact]
    public void ExplicitProviderOrderDrivesCatalogFailover()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            ProvidersOrder = new[] { "b", "missing", "a", "b" },
            Providers = new[]
            {
                new ProviderEntry("a", "A", string.Empty, string.Empty),
                new ProviderEntry("b", "B", string.Empty, string.Empty),
            },
        };
        var catalog = new ProviderCatalog(
            config.Providers, config.ActiveProvider, config.SegmentProvider,
            config.FinalProvider, config.FailoverOrderIds);
        Assert.Equal(new[] { "b", "a" }, catalog.FailoverOrder(null, true));
    }

    [Fact]
    public void ProviderToStringRedactsSecrets()
    {
        var provider = new ProviderEntry(
            "openai", "OpenAI", "https://api.test", "gpt-transcribe",
            ApiKey: "sk-do-not-log", ApiKeyFile: "C:\\keys\\openai.txt");
        var text = provider.ToString();
        Assert.DoesNotContain("sk-do-not-log", text);
        Assert.DoesNotContain("C:\\keys\\openai.txt", text);
        Assert.Contains("redacted", text);
    }

    [Fact]
    public void KeyFilePathExpandsHomeDirectory()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Assert.NotEmpty(home);
        var expanded = PortableConfig.ExpandKeyFilePath("~/keys/provider.txt");
        Assert.Equal(Path.GetFullPath(Path.Combine(home, "keys", "provider.txt")), expanded);
    }

    private static void AssertConfigCase(ConfigCase testCase)
    {
        var dir = Path.Combine(Path.GetTempPath(), $"nanodictate-parity-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            foreach (var file in testCase.Files)
            {
                var path = Path.Combine(dir, file.Key);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, file.Value);
            }
            var configPath = Path.Combine(dir, "config.toml");
            var content = string.Join("\n", testCase.Config).Replace("${KEY_DIR}", dir, StringComparison.Ordinal);
            File.WriteAllText(configPath, content);
            var config = PortableConfig.Load(configPath);
            var expected = testCase.Expected;
            Assert.Equal(expected.ActiveProvider, config.ActiveProvider);
            Assert.Equal(expected.Language, config.Language);
            Assert.Equal(expected.SegmentProvider, config.SegmentProvider);
            Assert.Equal(expected.FinalProvider, config.FinalProvider);
            if (expected.FailoverOrder is not null)
            {
                Assert.Equal(expected.FailoverOrder, config.FailoverOrderIds);
            }
            Assert.Equal(expected.Providers.Count, config.Providers.Count);
            for (var i = 0; i < expected.Providers.Count; i++)
            {
                var actual = config.Providers[i];
                var wanted = expected.Providers[i];
                Assert.Equal(wanted.Id, actual.Id);
                Assert.Equal(wanted.Name, actual.Name);
                Assert.Equal(wanted.BaseUrl, actual.BaseUrl);
                Assert.Equal(wanted.Model, actual.Model);
            }
            foreach (var key in expected.ResolvedApiKeys)
            {
                Assert.Equal(key.Value, HostApp.ResolveApiKey(key.Key, config));
            }
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    private static FixtureRoot LoadFixture()
    {
        var path = Path.Combine(FindRepoRoot(), "Tests", "Fixtures", "portable-parity.json");
        return JsonSerializer.Deserialize<FixtureRoot>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidOperationException("portable parity fixture is empty");
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

    private static void WithEnv(Dictionary<string, string> values, Action action)
    {
        WithEnvCore(values, () =>
        {
            action();
            return Task.CompletedTask;
        }).GetAwaiter().GetResult();
    }

    private static Task WithEnv(Dictionary<string, string> values, Func<Task> action) =>
        WithEnvCore(values, action);

    private static async Task WithEnvCore(Dictionary<string, string> values, Func<Task> action)
    {
        var keys = values.Keys.Append("NANODICTATE_API_KEY").Distinct().ToList();
        var previous = keys.ToDictionary(
            key => key, key => Environment.GetEnvironmentVariable(key));
        try
        {
            foreach (var key in keys)
            {
                Environment.SetEnvironmentVariable(key, null);
            }
            foreach (var entry in values)
            {
                Environment.SetEnvironmentVariable(entry.Key, entry.Value);
            }
            await action();
        }
        finally
        {
            foreach (var key in keys)
            {
                Environment.SetEnvironmentVariable(key, previous[key]);
            }
        }
    }

    private sealed class CapturingTransport : ISttTransport
    {
        private readonly Queue<SttHttpResponse> _responses;
        public List<string> Authorizations { get; } = new();

        public CapturingTransport(params SttHttpResponse[] responses)
        {
            _responses = new Queue<SttHttpResponse>(responses);
        }

        public Task<SttHttpResponse> SendAsync(
            string url,
            IReadOnlyDictionary<string, string> headers,
            byte[] body,
            string contentType,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            Authorizations.Add(headers.TryGetValue("Authorization", out var value) ? value : string.Empty);
            return Task.FromResult(_responses.Dequeue());
        }
    }
}
