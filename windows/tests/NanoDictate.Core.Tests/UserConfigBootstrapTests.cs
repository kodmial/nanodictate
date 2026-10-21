using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// First-use configuration behavior for the installed Windows product:
/// a fresh profile receives the bundled keyless default, while upgrades and
/// relaunches never replace user-edited configuration.
/// </summary>
public sealed class UserConfigBootstrapTests
{
    [Fact]
    public void FreshProfileCopiesBundledDefaultAndLoadsKeylessAirubiz()
    {
        var root = NewTempDirectory();
        try
        {
            var bundled = Path.Combine(root, "app", "config.example.toml");
            var user = Path.Combine(root, "profile", "NanoDictate", "config.toml");
            Directory.CreateDirectory(Path.GetDirectoryName(bundled)!);
            File.WriteAllText(bundled, DefaultConfigText);

            var resolved = UserConfigBootstrap.EnsureUserConfig(user, bundled);

            Assert.Equal(user, resolved);
            Assert.Equal(DefaultConfigText, File.ReadAllText(user));
            var config = PortableConfig.Load(user);
            Assert.Equal("airubiz", config.ActiveProvider);
            var airubiz = Assert.Single(config.Providers, provider => provider.Id == "airubiz");
            Assert.Equal("https://api.airubiz.site/v1/audio/transcriptions", airubiz.BaseUrl);
            Assert.Equal("gigaam-v3-ctc-sherpa", airubiz.Model);
            Assert.Contains("api_key = \"\"", File.ReadAllText(user));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void RepositoryExampleIsTheFirstUseDefault()
    {
        var example = FindExampleConfig();
        var root = NewTempDirectory();
        try
        {
            var user = Path.Combine(root, "NanoDictate", "config.toml");
            var resolved = UserConfigBootstrap.EnsureUserConfig(user, example);

            Assert.Equal(user, resolved);
            Assert.Equal(File.ReadAllText(example), File.ReadAllText(user));
            var config = PortableConfig.Load(user);
            Assert.Equal("airubiz", config.ActiveProvider);
            Assert.Contains(config.Providers, provider => provider.Id == "airubiz");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void ExistingUserConfigIsNeverReplaced()
    {
        var root = NewTempDirectory();
        try
        {
            var bundled = Path.Combine(root, "config.example.toml");
            var user = Path.Combine(root, "NanoDictate", "config.toml");
            File.WriteAllText(bundled, DefaultConfigText);
            Directory.CreateDirectory(Path.GetDirectoryName(user)!);
            const string edited = "active_provider = \"openai\"\n";
            File.WriteAllText(user, edited);

            var resolved = UserConfigBootstrap.EnsureUserConfig(user, bundled);

            Assert.Equal(user, resolved);
            Assert.Equal(edited, File.ReadAllText(user));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void MissingBundledExampleFallsBackInsteadOfFailingStartup()
    {
        var root = NewTempDirectory();
        try
        {
            var bundled = Path.Combine(root, "missing-config.example.toml");
            var user = Path.Combine(root, "profile", "config.toml");

            var resolved = UserConfigBootstrap.EnsureUserConfig(user, bundled);

            Assert.Equal(bundled, resolved);
            Assert.False(File.Exists(user));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void FindsPackagedExampleNextToExecutableOrInParent()
    {
        var root = NewTempDirectory();
        try
        {
            var app = Path.Combine(root, "app");
            Directory.CreateDirectory(app);
            var nextToExe = Path.Combine(app, UserConfigBootstrap.ExampleFileName);
            File.WriteAllText(nextToExe, DefaultConfigText);
            Assert.Equal(nextToExe, UserConfigBootstrap.FindBundledExample(app));

            File.Delete(nextToExe);
            var parent = Path.Combine(root, UserConfigBootstrap.ExampleFileName);
            File.WriteAllText(parent, DefaultConfigText);
            Assert.Equal(parent, UserConfigBootstrap.FindBundledExample(app));

            File.Delete(parent);
            Assert.Null(UserConfigBootstrap.FindBundledExample(app));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static string NewTempDirectory()
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            $"nanodictate-first-use-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static string FindExampleConfig()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, UserConfigBootstrap.ExampleFileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
            directory = directory.Parent;
        }
        throw new FileNotFoundException("config.example.toml not found");
    }

    private const string DefaultConfigText = """
        active_provider = "airubiz"
        language = ""

        [providers.airubiz]
        name = "Airubiz"
        base_url = "https://api.airubiz.site/v1/audio/transcriptions"
        model = "gigaam-v3-ctc-sherpa"
        api_key = ""
        """;
}
