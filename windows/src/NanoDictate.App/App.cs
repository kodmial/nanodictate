using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using NanoDictate.Core;

namespace NanoDictate.App;

/// <summary>
/// Single installed WinUI process. It owns the shared Rust engine plus the
/// Windows capture/insertion/hotkey adapters, and presents only a transient
/// microphone HUD (plus optional settings and a transient review prompt).
/// There is no developer dashboard or second executable in normal use.
/// </summary>
public sealed partial class App : Application
{
    private const string ShowWindowEvent = @"Local\NanoDictateShowWindow";

    private SingleInstance? _instance;
    private HostApp? _app;
    private GlobalHotkeyService? _hotkeys;
    private HudCoordinator? _coordinator;
    private HudWindow? _hud;
    private SettingsWindow? _settings;
    private WindowReviewPrompt? _reviewPrompt;
    private DispatcherQueueTimer? _timer;
    private EventWaitHandle? _showWindowSignal;
    private CancellationTokenSource? _showWindowCancellation;
    private string _configPath = string.Empty;
    private bool _micPrivacyOpened;
    private bool _quitting;

    public App()
    {
        UnhandledException += (_, e) => System.Diagnostics.Debug.WriteLine(e.Message);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var commandLine = Environment.GetCommandLineArgs().Skip(1).ToArray();
        var wantsSettings = commandLine.Any(a =>
            string.Equals(a, "--settings", StringComparison.OrdinalIgnoreCase));

        _instance = new SingleInstance();
        if (!_instance.IsFirst)
        {
            // Updates/logon start with --background and must stay silent. An
            // explicit --settings launch or a plain relaunch is the user's
            // on-demand route to the optional settings window.
            if (wantsSettings || commandLine.Length == 0)
            {
                SignalExistingInstance();
            }
            _instance.Dispose();
            _instance = null;
            Exit();
            return;
        }

        try
        {
            // Create the relaunch signal before the heavier composition so a
            // second launch racing startup can still reach this process.
            _showWindowSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowWindowEvent);
            _showWindowCancellation = new CancellationTokenSource();
            NanoEngine.CheckAvailable();
            _configPath = ResolveConfig();
            var config = PortableConfig.Load(_configPath);
            config.NormalizeProviderSelection();
            var insertions = new InsertionSinkAdapter(
                new TextInserter(new WindowsInputSender()),
                new ClipboardInsertService(new WindowsClipboardBridge()));

            _app = new HostApp(config, new WasapiCaptureSource(), insertions);
            _hud = new HudWindow();
            _coordinator = new HudCoordinator(
                _app,
                processingWatchdog: HostApp.InitialProcessingWatchdog(config),
                clock: null,
                useTimer: false,
                reduceMotion: ReadReduceMotion());
            _coordinator.SnapshotChanged += OnSnapshotChanged;
            _reviewPrompt = new WindowReviewPrompt(_hud.DispatcherQueue);
            _app.Controller.ReviewPrompt = _reviewPrompt;
            _app.Controller.MicStartAttempted += OnMicStartAttempted;
            _app.Controller.CancelledWithRecordingId += id =>
            {
                if (id == _app.Controller.CurrentRecordingId)
                {
                    _reviewPrompt.Cancel();
                }
            };

            _hotkeys = new GlobalHotkeyService(config.DoubleAltMaxInterval) { Delegate = _app.Controller };
            _hotkeys.Start();

            _timer = _hud.DispatcherQueue.CreateTimer();
            _timer.Interval = TimeSpan.FromMilliseconds(50);
            _timer.Tick += (_, _) => _coordinator?.Tick();
            _timer.Start();

            _hud.Closed += (_, _) => Quit();
            StartSecondLaunchListener();

            // The installed app is a quiet background agent. Settings is
            // never a mandatory first-run window: the shortcut passes
            // --settings, and a second launch while idle opens it on demand.
            if (wantsSettings)
            {
                ShowSettingsIfIdle();
            }
        }
        catch
        {
            _quitting = true;
            _timer?.Stop();
            _hotkeys?.Dispose();
            _coordinator?.Dispose();
            try
            {
                _hud?.CloseForShutdown();
            }
            catch
            {
            }
            _app?.Dispose();
            Cleanup();
            throw;
        }
    }

    private void OnSnapshotChanged(HudSnapshot snapshot)
    {
        var hud = _hud;
        if (hud is null)
        {
            return;
        }
        if (hud.DispatcherQueue.HasThreadAccess)
        {
            hud.Apply(snapshot);
        }
        else
        {
            hud.DispatcherQueue.TryEnqueue(() => hud.Apply(snapshot));
        }
    }

    private void OnMicStartAttempted(MicStartOutcome outcome)
    {
        if (outcome.Started)
        {
            _reviewPrompt?.Cancel();
            return;
        }
        if (outcome.Failure != MicFailureKind.Denied || _micPrivacyOpened)
        {
            return;
        }
        // Unpackaged desktop apps use the OS-wide microphone privacy switch,
        // not a per-app consent broker. Open the exact page once; the HUD
        // already surfaces the bounded microphone error.
        _micPrivacyOpened = true;
        _hud?.DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                MicPrivacyGuide.OpenSettings();
            }
            catch
            {
                // The HUD remains the source of truth if Settings cannot open.
            }
        });
    }

    private void StartSecondLaunchListener()
    {
        var signal = _showWindowSignal
            ?? throw new InvalidOperationException("Relaunch signal unavailable");
        var cancellation = _showWindowCancellation?.Token
            ?? throw new InvalidOperationException("Relaunch signal unavailable");
        var dispatcher = _hud?.DispatcherQueue
            ?? throw new InvalidOperationException("HUD dispatcher unavailable");
        _ = Task.Run(() =>
        {
            try
            {
                while (!cancellation.IsCancellationRequested)
                {
                    if (signal.WaitOne(500))
                    {
                        // A second launch never hijacks an active recording or
                        // transcription; it only reveals optional settings.
                        dispatcher.TryEnqueue(ShowSettingsIfIdle);
                    }
                }
            }
            catch (ObjectDisposedException)
            {
            }
        });
    }

    private void SignalExistingInstance()
    {
        // The first process may still be between claiming the mutex and
        // creating the event; give it a short window instead of dropping an
        // explicit relaunch.
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                using var signal = EventWaitHandle.OpenExisting(ShowWindowEvent);
                signal.Set();
                return;
            }
            catch (WaitHandleCannotBeOpenedException)
            {
            }
            catch (UnauthorizedAccessException)
            {
                return;
            }
            Thread.Sleep(50);
        }
    }

    private void ShowSettingsIfIdle()
    {
        if (_quitting || _app is null)
        {
            return;
        }
        if (_app.Controller.State != DictationState.Idle)
        {
            return;
        }
        if (_settings is null)
        {
            var settings = new SettingsWindow(
                _app,
                _configPath,
                changed: () => _coordinator?.RefreshLabel(),
                exit: Quit);
            settings.Closed += (_, _) => _settings = null;
            _settings = settings;
        }
        _settings.Open();
    }

    private void Quit()
    {
        if (_quitting)
        {
            return;
        }
        _quitting = true;
        _timer?.Stop();
        _hotkeys?.Dispose();
        _hotkeys = null;
        _coordinator?.Dispose();
        _coordinator = null;
        _settings?.Close();
        _settings = null;
        _hud?.CloseForShutdown();
        _hud = null;
        _app?.Dispose();
        _app = null;
        Cleanup();
        Exit();
    }

    private void Cleanup()
    {
        _showWindowCancellation?.Cancel();
        _showWindowSignal?.Dispose();
        _showWindowSignal = null;
        _showWindowCancellation?.Dispose();
        _showWindowCancellation = null;
        _instance?.Dispose();
        _instance = null;
    }

    private static bool ReadReduceMotion()
    {
        try
        {
            return !new Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
        }
        catch
        {
            return false;
        }
    }

    private static string ResolveConfig()
    {
        var windowsPath = WindowsPaths.ConfigPath();
        if (File.Exists(windowsPath))
        {
            return windowsPath;
        }
        var bundled = FindBundledExample();
        if (bundled is null)
        {
            return Path.Combine(AppContext.BaseDirectory, "config.example.toml");
        }
        try
        {
            var dir = Path.GetDirectoryName(windowsPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            if (!File.Exists(windowsPath))
            {
                File.Copy(bundled, windowsPath);
            }
            return windowsPath;
        }
        catch
        {
            return bundled;
        }
    }

    private static string? FindBundledExample()
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(baseDir, "config.example.toml"),
            Path.Combine(
                Directory.GetParent(baseDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))?.FullName ?? baseDir,
                "config.example.toml"),
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

    [STAThread]
    public static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ => new App());
    }
}
