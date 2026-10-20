using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>Windows paths and extended portable config surface.</summary>
public sealed class WindowsPathsAndConfigTests
{
    [Fact]
    public void PathsUseWindowsConventions()
    {
        Assert.EndsWith("NanoDictate", WindowsPaths.AppDataDirectory());
        Assert.EndsWith("NanoDictate", WindowsPaths.LocalDataDirectory());
        Assert.EndsWith("config.toml", WindowsPaths.ConfigPath());
        Assert.EndsWith("mic-request-state.json", WindowsPaths.MicRequestStatePath());
        Assert.EndsWith("Logs", WindowsPaths.LogDirectory());
        Assert.Contains(DateTime.UtcNow.ToString("yyyy-MM"), WindowsPaths.LogFilePath(DateTime.UtcNow));
    }

    [Fact]
    public void StartupManagerFailsLoudlyOffWindows()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }
        Assert.Throws<PlatformNotSupportedException>(() => StartupManager.IsEnabled());
        Assert.Throws<PlatformNotSupportedException>(() => StartupManager.Enable("x"));
        Assert.Throws<PlatformNotSupportedException>(() => StartupManager.Disable());
    }

    [Fact]
    public void InsertMethodParserMapsCgeventToDirect()
    {
        Assert.Equal(InsertMethod.Direct, InsertMethodParser.Parse("cgevent"));
        Assert.Equal(InsertMethod.Direct, InsertMethodParser.Parse(null));
        Assert.Equal(InsertMethod.Clipboard, InsertMethodParser.Parse("clipboard"));
        Assert.Throws<NanoException>(() => InsertMethodParser.Parse("bogus"));
    }

    [Fact]
    public void PortableConfigParsesHostOptions()
    {
        var toml = """
            active_provider = "a"
            insert_method = "clipboard"
            double_alt_max_interval = 0.3
            undo_max_interval = 5.0
            review_before_insert = true
            [providers.a]
            name = "A"
            base_url = ""
            model = "m"
            """;
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-host-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, toml);
        try
        {
            var config = PortableConfig.Load(path);
            Assert.Equal(InsertMethod.Clipboard, config.InsertMethod);
            Assert.Equal(0.3, config.DoubleAltMaxInterval, 9);
            Assert.Equal(5.0, config.UndoMaxInterval, 9);
            Assert.True(config.ReviewBeforeInsert);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void SaveSettingsPersistsBothValuesAndPreservesRemainingConfig()
    {
        var toml = """
            language = "ru"
            active_provider = "a" # selected
            review_before_insert = false # set "true" to enable
            timeout_seconds = 30

            [providers.a]
            name = "A" # keep
            api_key = "secret"

            [providers.b]
            name = "B"
            """;
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-save-settings-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, toml);
        try
        {
            PortableConfig.SaveSettings(path, "b", true);

            var text = File.ReadAllText(path);
            Assert.Contains("language = \"ru\"", text);
            Assert.Contains("active_provider = \"b\" # selected", text);
            Assert.Contains("review_before_insert = true", text);
            Assert.Contains("timeout_seconds = 30", text);
            Assert.Contains("name = \"A\" # keep", text);
            Assert.Contains("api_key = \"secret\"", text);
            Assert.Contains("[providers.b]", text);

            var config = PortableConfig.Load(path);
            Assert.Equal("b", config.ActiveProvider);
            Assert.True(config.ReviewBeforeInsert);
            Assert.Equal(30, config.TimeoutSeconds);
            Assert.Equal(2, config.Providers.Count);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void SaveSettingsInsertsMissingRootKeysBeforeFirstSection()
    {
        var toml = """
            language = "ru"

            [providers.a]
            name = "A"
            review_before_insert = true # section value

            [providers.b]
            name = "B"
            """;
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-save-root-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, toml);
        try
        {
            PortableConfig.SaveSettings(path, "b", false);

            var text = File.ReadAllText(path);
            Assert.True(text.IndexOf("active_provider = \"b\"", StringComparison.Ordinal)
                < text.IndexOf("[providers.a]", StringComparison.Ordinal));
            Assert.True(text.IndexOf("review_before_insert = false", StringComparison.Ordinal)
                < text.IndexOf("[providers.a]", StringComparison.Ordinal));
            Assert.Contains("review_before_insert = true # section value", text);

            var config = PortableConfig.Load(path);
            Assert.Equal("b", config.ActiveProvider);
            Assert.False(config.ReviewBeforeInsert);
            Assert.Equal(2, config.Providers.Count);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void SaveSettingsCreatesMissingConfigFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-save-new-{Guid.NewGuid():N}.toml");
        try
        {
            PortableConfig.SaveSettings(path, "a", true);

            var config = PortableConfig.Load(path);
            Assert.Equal("a", config.ActiveProvider);
            Assert.True(config.ReviewBeforeInsert);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void PortableConfigRejectsUnknownInsertMethod()
    {
        var toml = "insert_method = \"clipbord\"\n";
        var path = Path.Combine(Path.GetTempPath(), $"nanodictate-host-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, toml);
        try
        {
            Assert.Throws<NanoException>(() => PortableConfig.Load(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void PortableConfigDefaultsMatchExample()
    {
        var config = PortableConfig.Load(FindExampleConfig());
        Assert.Equal(InsertMethod.Direct, config.InsertMethod);
        Assert.Equal(0.4, config.DoubleAltMaxInterval, 9);
        Assert.Equal(2.0, config.UndoMaxInterval, 9);
        Assert.False(config.ReviewBeforeInsert);
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
        throw new FileNotFoundException("config.example.toml not found");
    }
}
