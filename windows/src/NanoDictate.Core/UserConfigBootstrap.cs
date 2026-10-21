namespace NanoDictate.Core;

/// <summary>
/// First-use configuration bootstrap for the installed Windows product.
/// A missing per-user config is copied from the bundled example so a fresh
/// install has the keyless default provider and remains editable. An existing
/// config is never replaced, which keeps upgrades from overwriting user
/// settings. If the file cannot be created (for example a read-only profile),
/// the bundled example is used directly so dictation can still start.
/// </summary>
public static class UserConfigBootstrap
{
    public const string ExampleFileName = "config.example.toml";

    /// <summary>
    /// Ensures the user config exists and returns the path to load. Existing
    /// content is left byte-for-byte untouched.
    /// </summary>
    public static string EnsureUserConfig(string userConfigPath, string? bundledExamplePath)
    {
        if (string.IsNullOrWhiteSpace(userConfigPath))
        {
            throw new ArgumentException("user config path must not be empty", nameof(userConfigPath));
        }
        if (File.Exists(userConfigPath))
        {
            return userConfigPath;
        }
        if (string.IsNullOrWhiteSpace(bundledExamplePath) || !File.Exists(bundledExamplePath))
        {
            return bundledExamplePath ?? string.Empty;
        }
        try
        {
            var directory = Path.GetDirectoryName(userConfigPath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            if (!File.Exists(userConfigPath))
            {
                File.Copy(bundledExamplePath, userConfigPath);
            }
            return userConfigPath;
        }
        catch (IOException)
        {
            return File.Exists(userConfigPath) ? userConfigPath : bundledExamplePath;
        }
        catch (UnauthorizedAccessException)
        {
            return File.Exists(userConfigPath) ? userConfigPath : bundledExamplePath;
        }
    }

    /// <summary>
    /// Locates the packaged example next to the executable, with the parent
    /// directory as a fallback for development layouts.
    /// </summary>
    public static string? FindBundledExample(string baseDirectory)
    {
        if (string.IsNullOrWhiteSpace(baseDirectory))
        {
            return null;
        }
        var candidates = new[]
        {
            Path.Combine(baseDirectory, ExampleFileName),
            Path.Combine(
                Directory.GetParent(
                    baseDirectory.TrimEnd(
                        Path.DirectorySeparatorChar,
                        Path.AltDirectorySeparatorChar))?.FullName ?? baseDirectory,
                ExampleFileName),
        };
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return null;
    }
}
