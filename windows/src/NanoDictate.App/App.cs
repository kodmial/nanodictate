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
        foreach (var (id, name, isActive) in _app.ListProviders())
        {
            _providers.Items.Add($"{name} ({id})");
            if (isActive)
            {
                _providers.SelectedIndex = _providers.Items.Count - 1;
            }
        }
        _review = new CheckBox { Content = "Review before insert", IsChecked = _config.ReviewBeforeInsert };
        _review.Checked += (_, _) => _app.Controller.ReviewBeforeInsert = true;
        _review.Unchecked += (_, _) => _app.Controller.ReviewBeforeInsert = false;
        var doctor = new Button { Content = "Run diagnostics" };
        doctor.Click += (_, _) => ShowDiagnostics();
        panel.Children.Add(_status);
        panel.Children.Add(_providers);
        panel.Children.Add(_review);
        panel.Children.Add(doctor);
        Content = panel;
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

public sealed partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        UnhandledException += (_, e) => System.Diagnostics.Debug.WriteLine(e.Message);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        NanoEngine.CheckAvailable();
        _window = new MainWindow();
        _window.Activate();
    }

    public static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ => new App());
    }
}
