namespace NanoDictate.Core;

/// <summary>
/// Windows-appropriate config/log locations. Platform differences are
/// explicit: macOS uses ~/Library/Application Support + ~/Library/Logs and
/// ~/.config/nanodictate; Windows uses %APPDATA% for roaming config/state
/// and %LOCALAPPDATA% for logs (never silently reuses the macOS layout).
/// </summary>
public static class WindowsPaths
{
    public const string AppFolderName = "NanoDictate";

    public static string AppDataDirectory()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
        {
            baseDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Roaming");
        }
        return Path.Combine(baseDir, AppFolderName);
    }

    public static string LocalDataDirectory()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrEmpty(baseDir))
        {
            baseDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Local");
        }
        return Path.Combine(baseDir, AppFolderName);
    }

    public static string ConfigPath() => Path.Combine(AppDataDirectory(), "config.toml");

    public static string MicRequestStatePath() => Path.Combine(AppDataDirectory(), "mic-request-state.json");

    public static string LogDirectory() => Path.Combine(LocalDataDirectory(), "Logs");

    public static string LogFilePath(DateTime date) =>
        Path.Combine(LogDirectory(), $"nanodictate-{date:yyyy-MM-dd}.log");

    /// <summary>Creates config/log directories. Never throws for missing profiles.</summary>
    public static void EnsureDirectories()
    {
        Directory.CreateDirectory(AppDataDirectory());
        Directory.CreateDirectory(LogDirectory());
    }
}
