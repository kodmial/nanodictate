using System.Diagnostics;
using System.Text.Json;

namespace NanoDictate.Core;

/// <summary>Windows microphone failure classification.</summary>
public enum MicFailureKind
{
    Denied,
    NotFound,
    Disconnected,
    Other,
}

/// <summary>
/// Classifies WASAPI start failures. Privacy-blocked capture surfaces as
/// E_ACCESSDENIED; a missing endpoint as E_NOTFOUND; a pulled device as
/// AUDCLNT_E_DEVICE_INVALIDATED. Anything else is Other (failover-eligible
/// only per the Rust retry policy, never reclassified here).
/// </summary>
public static class MicFailureClassifier
{
    private const int EAccessDenied = unchecked((int)0x80070005);
    private const int ENotFound = unchecked((int)0x80070490);
    private const int AudclntEDeviceInvalidated = unchecked((int)0x88890004);

    public static MicFailureKind Classify(int hresult, string operation)
    {
        _ = operation;
        if (hresult == EAccessDenied)
        {
            return MicFailureKind.Denied;
        }
        if (hresult == ENotFound)
        {
            return MicFailureKind.NotFound;
        }
        if (hresult == AudclntEDeviceInvalidated)
        {
            return MicFailureKind.Disconnected;
        }
        return MicFailureKind.Other;
    }

    public static MicFailureKind Classify(NanoException ex) => Classify(ex.Code, ex.Message);
}

/// <summary>
/// Windows microphone/privacy settings guidance. Points at the exact
/// Settings page instead of a generic error so a privacy-blocked user can
/// recover in one click. All strings are English per repository policy.
/// </summary>
public static class MicPrivacyGuide
{
    /// <summary>Settings URI for microphone privacy on Windows 10/11.</summary>
    public const string SettingsUri = "ms-settings:privacy-microphone";

    public static string MessageFor(MicFailureKind kind) => kind switch
    {
        MicFailureKind.Denied =>
            "Microphone access is blocked. Enable Microphone access and Let desktop apps access your microphone in Settings > Privacy & security > Microphone, then try again.",
        MicFailureKind.NotFound =>
            "No microphone was found. Connect an input device and check Settings > System > Sound > Input.",
        MicFailureKind.Disconnected =>
            "The microphone was disconnected during capture. Reconnect it and start again.",
        _ => "Microphone capture failed. Check the device in Settings > System > Sound > Input and try again.",
    };

    /// <summary>Opens the microphone privacy page. Windows only.</summary>
    public static void OpenSettings()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Microphone privacy settings require Windows.");
        }
        Process.Start(new ProcessStartInfo(SettingsUri) { UseShellExecute = true });
    }
}

/// <summary>
/// Anti-storm guard for microphone capture requests. Ports the macOS
/// <c>MicRequestPolicy</c> persistence shape (JSON timeout timestamps) to the
/// Windows state path; the allow decision itself is computed by the shared
/// Rust engine through <see cref="NanoEngine.MicRequestAllowed"/> (never
/// reimplemented in C#). Corrupt or missing state files mean fresh state.
/// Persistence failures never throw: the guard stays in memory.
/// </summary>
public sealed class MicRequestPolicy
{
    public const int MaxTimeoutsInWindow = 3;
    public static readonly TimeSpan Window = TimeSpan.FromHours(6);

    private readonly string? _statePath;
    private List<double> _timeoutEpochs = new();

    public MicRequestPolicy(string? statePath = null)
    {
        _statePath = statePath;
        if (_statePath is not null)
        {
            _timeoutEpochs = Load(_statePath);
        }
    }

    public static string DefaultStatePath() =>
        Path.Combine(WindowsPaths.AppDataDirectory(), "mic-request-state.json");

    public bool AllowRequest(DateTimeOffset now)
    {
        try
        {
            return NanoEngine.MicRequestAllowed(
                InWindow(now).ToArray(),
                now.ToUnixTimeMilliseconds() / 1000.0,
                MaxTimeoutsInWindow,
                Window.TotalSeconds);
        }
        catch (NanoException)
        {
            // Fail open for the guard itself: an engine failure must not
            // block a first microphone request.
            return true;
        }
    }

    public void RecordTimeout(DateTimeOffset now)
    {
        _timeoutEpochs = InWindow(now);
        _timeoutEpochs.Add(now.ToUnixTimeMilliseconds() / 1000.0);
        Persist();
    }

    public void RecordGranted()
    {
        _timeoutEpochs = new List<double>();
        Persist();
    }

    private List<double> InWindow(DateTimeOffset now)
    {
        var nowSecs = now.ToUnixTimeMilliseconds() / 1000.0;
        return _timeoutEpochs
            .Where(t => nowSecs - t >= 0 && nowSecs - t < Window.TotalSeconds)
            .ToList();
    }

    private static List<double> Load(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return new List<double>();
            }
            var json = File.ReadAllText(path);
            var state = JsonSerializer.Deserialize<StateFile>(json);
            return state?.TimeoutTimestamps?.ToList() ?? new List<double>();
        }
        catch
        {
            return new List<double>();
        }
    }

    private void Persist()
    {
        if (_statePath is null)
        {
            return;
        }
        try
        {
            var dir = Path.GetDirectoryName(_statePath);
            if (dir is not null)
            {
                Directory.CreateDirectory(dir);
            }
            var json = JsonSerializer.Serialize(new StateFile { TimeoutTimestamps = _timeoutEpochs.ToArray() });
            var tmp = _statePath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, _statePath, overwrite: true);
        }
        catch
        {
            // Auxiliary guard: never break recording on a persist failure.
        }
    }

    private sealed class StateFile
    {
        public double[] TimeoutTimestamps { get; set; } = Array.Empty<double>();
    }
}
