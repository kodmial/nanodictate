using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NanoDictate.Core;

namespace NanoDictate.App;

/// <summary>
/// WinUI 3 application entrypoint. Owns no product policy: it composes the
/// same <see cref="HostApp"/> as the console host (shared Rust engine plus
/// Windows-native capture/insertion) and surfaces status, provider/model
/// selection, review-before-insert, and diagnostics through native controls.
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly PortableConfig _config;
    private readonly HostApp _app;
    private readonly GlobalHotkeyService _hotkeys;
    private bool _exiting;
    private bool _micPrivacyOpened;
    private readonly TextBlock _status;
    private readonly ComboBox _providers;
    private readonly CheckBox _review;

    public MainWindow()
    {
        Title = "NanoDictate";
        _config = PortableConfig.Load(ResolveConfig());
        var insertions = new InsertionSinkAdapter(
            new TextInserter(new WindowsInputSender()),
            new ClipboardInsertService(new WindowsClipboardBridge()));
        _app = new HostApp(_config, new WasapiCaptureSource(), insertions);

        var panel = new StackPanel { Spacing = 8, Padding = new Thickness(16) };
        _status = new TextBlock { Text = "idle" };
        _providers = new ComboBox { Header = "Provider" };
        var providers = _app.ListProviders();
        foreach (var (id, name, isActive) in providers)
        {
            _providers.Items.Add($"{name} ({id})");
            if (isActive)
            {
                _providers.SelectedIndex = _providers.Items.Count - 1;
            }
        }
        _providers.SelectionChanged += (_, _) =>
        {
            var index = _providers.SelectedIndex;
            if (index >= 0 && index < providers.Count) { _app.SelectProvider(providers[index].Id); }
        };
        _review = new CheckBox { Content = "Review before insert", IsChecked = _config.ReviewBeforeInsert };
        _review.Checked += (_, _) => _app.Controller.ReviewBeforeInsert = true;
        _review.Unchecked += (_, _) => _app.Controller.ReviewBeforeInsert = false;
        var doctor = new Button { Content = "Run diagnostics" };
        doctor.Click += (_, _) => ShowDiagnostics();
        panel.Children.Add(_status);
        panel.Children.Add(_providers);
        panel.Children.Add(_review);
        panel.Children.Add(doctor);
        var exit = new Button { Content = "Exit NanoDictate" };
        exit.Click += (_, _) => { _exiting = true; Close(); };
        panel.Children.Add(exit);
        Content = panel;
        _app.Controller.ReviewPrompt = new WindowReviewPrompt(DispatcherQueue, panel);
        _app.Controller.MicStartAttempted += outcome => DispatcherQueue.TryEnqueue(() =>
        {
            _status.Text = outcome.Started ? "recording" : $"microphone: {outcome.Guidance ?? "unavailable"}";
            if (!outcome.Started && outcome.Failure == MicFailureKind.Denied && !_micPrivacyOpened)
            {
                // Unpackaged Windows desktop apps use the OS-wide desktop-app
                // microphone privacy switch, not a per-app consent broker.
                // Open the exact privacy page once so consent is the only
                // action requested of a user who has disabled microphone access.
                _micPrivacyOpened = true;
                try { MicPrivacyGuide.OpenSettings(); }
                catch (Exception ex) { _status.Text = $"Enable microphone access in Windows Settings: {ex.Message}"; }
            }
        });
        _app.Controller.Inserted += _ => DispatcherQueue.TryEnqueue(() => _status.Text = "inserted");
        _hotkeys = new GlobalHotkeyService(_config.DoubleAltMaxInterval) { Delegate = _app.Controller };
        // Closing the window hides it; dictation remains active until Exit is selected.
        AppWindow.Closing += (_, args) =>
        {
            if (!_exiting)
            {
                args.Cancel = true;
                AppWindow.Hide();
            }
        };
        Closed += (_, _) => { _hotkeys.Dispose(); _app.Dispose(); };
        _hotkeys.Start();
    }

    private void ShowDiagnostics()
    {
        var checks = WindowsDiagnostics.Run(ResolveConfig());
        _status.Text = WindowsDiagnostics.AllPassed(checks) ? "diagnostics: ok" : "diagnostics: FAIL";
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
            // No user config and no bundled example: return the expected
            // beside-executable path so PortableConfig.Load fails loudly
            // with a FileNotFoundException instead of silently continuing.
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
            Path.Combine(Directory.GetParent(baseDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))?.FullName ?? baseDir, "config.example.toml"),
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

internal sealed class WindowReviewPrompt : IReviewPrompt
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _dispatcher;
    private readonly FrameworkElement _root;

    public WindowReviewPrompt(Microsoft.UI.Dispatching.DispatcherQueue dispatcher, FrameworkElement root)
    {
        _dispatcher = dispatcher;
        _root = root;
    }

    public string? Ask(string text)
    {
        // Called from the STT worker. Never block the WinUI dispatcher thread.
        var answer = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_dispatcher.TryEnqueue(async () =>
        {
            try
            {
                var dialog = new ContentDialog
                {
                    XamlRoot = _root.XamlRoot,
                    Title = "Insert dictation?",
                    Content = new ScrollViewer { Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap } },
                    PrimaryButtonText = "Insert",
                    CloseButtonText = "Discard",
                    DefaultButton = ContentDialogButton.Close,
                };
                var result = await dialog.ShowAsync();
                answer.TrySetResult(result == ContentDialogResult.Primary ? "y" : "n");
            }
            catch { answer.TrySetResult("n"); }
        })) { return "n"; }
        return answer.Task.Wait(TimeSpan.FromMinutes(2)) ? answer.Task.Result : "n";
    }
}

public sealed partial class App : Application
{
    private const string ShowWindowEvent = @"Local\NanoDictateShowWindow";
    private MainWindow? _window;
    private SingleInstance? _instance;
    private EventWaitHandle? _showWindowSignal;
    private CancellationTokenSource? _showWindowCancellation;

    public App()
    {
        UnhandledException += (_, e) => System.Diagnostics.Debug.WriteLine(e.Message);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _instance = new SingleInstance();
        if (!_instance.IsFirst)
        {
            // A second launch (Start menu / Scoop shortcut) opens the existing
            // background instance rather than failing or installing two hooks.
            try
            {
                using var signal = EventWaitHandle.OpenExisting(ShowWindowEvent);
                signal.Set();
            }
            catch (WaitHandleCannotBeOpenedException) { }
            _instance.Dispose();
            _instance = null;
            Exit();
            return;
        }

        try
        {
            NanoEngine.CheckAvailable();
            _window = new MainWindow();
            _showWindowSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowWindowEvent);
            _showWindowCancellation = new CancellationTokenSource();
            var signal = _showWindowSignal;
            var cancellation = _showWindowCancellation.Token;
            var dispatcher = _window.DispatcherQueue;
            var main = _window;
            _ = Task.Run(() =>
            {
                try
                {
                    while (!cancellation.IsCancellationRequested)
                    {
                        if (signal.WaitOne(500))
                        {
                            dispatcher.TryEnqueue(() =>
                            {
                                main.AppWindow.Show();
                                main.Activate();
                            });
                        }
                    }
                }
                catch (ObjectDisposedException) { }
            });
            _window.Closed += (_, _) =>
            {
                _showWindowCancellation?.Cancel();
                _showWindowSignal?.Dispose();
                _instance?.Dispose();
                _instance = null;
            };
            _window.Activate();
            // Registry/Scoop starts at each user logon with --background.
            // WinUI's dispatcher/hotkey hook keeps running while hidden.
            if (Environment.GetCommandLineArgs().Skip(1).Any(a =>
                string.Equals(a, "--background", StringComparison.OrdinalIgnoreCase)))
            {
                _window.AppWindow.Hide();
            }
        }
        catch
        {
            _showWindowCancellation?.Cancel();
            _showWindowSignal?.Dispose();
            _instance?.Dispose();
            _instance = null;
            throw;
        }
    }

    [STAThread]
    public static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ => new App());
    }
}
