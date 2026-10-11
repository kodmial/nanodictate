namespace NanoDictate.Core;

/// <summary>Status surface for the tray/background host (testable on any OS).</summary>
public interface ITrayIcon
{
    void Show(string tooltip);
    void SetStatus(string text, bool isRecording);
    void Hide();
}

public sealed class NoopTrayIcon : ITrayIcon
{
    public void Show(string tooltip) { }
    public void SetStatus(string text, bool isRecording) { }
    public void Hide() { }
}

public sealed class RecordingTrayIcon : ITrayIcon
{
    private readonly List<string> _log = new();
    public IReadOnlyList<string> Log => _log;
    public void Show(string tooltip) => _log.Add($"show:{tooltip}");
    public void SetStatus(string text, bool isRecording) => _log.Add($"status:{isRecording}:{text}");
    public void Hide() => _log.Add("hide");
}

/// <summary>
/// Single-instance guard via a global mutex. The second process observes
/// <see cref="IsFirst"/> == false and exits instead of double-hooking the
/// keyboard or double-capturing the microphone.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    private readonly Mutex _mutex;
    private bool _disposed;

    public SingleInstance(string name = "Global\\NanoDictate")
    {
        _mutex = new Mutex(initiallyOwned: true, name, out var createdNew);
        IsFirst = createdNew;
    }

    public bool IsFirst { get; }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        try
        {
            _mutex.ReleaseMutex();
        }
        catch
        {
            // Not the owner (second instance): nothing to release.
        }
        _mutex.Dispose();
    }
}

/// <summary>
/// Startup registration (Run key) and background/tray/process lifecycle.
/// Platform difference (explicit): macOS uses launchd; Windows uses
/// HKCU\...\Run plus a tray icon. Registry access is Windows-only and fails
/// loudly elsewhere; tray rendering stays behind <see cref="ITrayIcon"/> so
/// headless tests never need WinForms.
/// </summary>
public static class StartupManager
{
    public const string RunValueName = "NanoDictate";

    public static void Enable(string executablePath)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Startup registration requires Windows (Run key).");
        }
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new NanoException(-1, "executable path must not be empty");
        }
#pragma warning disable CA1416
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run")
            ?? throw new NanoException(-1, "cannot open the Run registry key");
        key.SetValue(RunValueName, $"\"{executablePath}\" --background");
#pragma warning restore CA1416
    }

    public static void Disable()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Startup registration requires Windows (Run key).");
        }
#pragma warning disable CA1416
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", writable: true);
        key?.DeleteValue(RunValueName, throwOnMissingValue: false);
#pragma warning restore CA1416
    }

    public static bool IsEnabled()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Startup registration requires Windows (Run key).");
        }
#pragma warning disable CA1416
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", writable: false);
        return key?.GetValue(RunValueName) is not null;
#pragma warning restore CA1416
    }
}

/// <summary>
/// Background host lifecycle: single-instance guard, tray status, and
/// graceful Ctrl+C / shutdown handling. Owns no dictation policy; it only
/// sequences startup and teardown around the controller.
/// </summary>
public sealed class HostLifecycle : IDisposable
{
    private readonly SingleInstance _instance;
    private readonly ITrayIcon _tray;
    private readonly CancellationTokenSource _cts = new();
    private bool _disposed;

    public HostLifecycle(ITrayIcon? tray = null, SingleInstance? instance = null)
    {
        _tray = tray ?? new NoopTrayIcon();
        _instance = instance ?? new SingleInstance();
        if (!_instance.IsFirst)
        {
            throw new NanoException(-1, "another NanoDictate instance is already running");
        }
        Console.CancelKeyPress += OnCancel;
    }

    public bool IsFirst => _instance.IsFirst;

    public CancellationToken Token => _cts.Token;

    public void Announce(string tooltip, string status, bool isRecording)
    {
        _tray.Show(tooltip);
        _tray.SetStatus(status, isRecording);
    }

    public void RequestStop() => _cts.Cancel();

    private void OnCancel(object? sender, ConsoleCancelEventArgs e)
    {
        e.Cancel = true;
        _cts.Cancel();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Console.CancelKeyPress -= OnCancel;
        try
        {
            _tray.Hide();
        }
        catch
        {
            // Best effort.
        }
        _cts.Cancel();
        _cts.Dispose();
        _instance.Dispose();
    }
}
