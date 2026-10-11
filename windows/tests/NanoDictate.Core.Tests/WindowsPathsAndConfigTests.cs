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
