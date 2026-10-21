using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NanoDictate.Core;
using Windows.UI;

namespace NanoDictate.App;

/// <summary>
/// Optional native settings surface (the developer dashboard is gone). It is
/// opened only by explicit <c>--settings</c> or a second launch while
/// dictation is idle. It never owns a second hotkey hook or capture session,
/// and closing it leaves background dictation running.
/// </summary>
public sealed class SettingsWindow : Window
{
    private readonly HostApp _app;
    private readonly string _configPath;
    private readonly Action _changed;
    private readonly Action _exit;
    private readonly ComboBox _providers;
    private readonly CheckBox _review;
    private readonly TextBlock _diagnostics;
    private bool _syncing;

    public SettingsWindow(HostApp app, string configPath, Action changed, Action exit)
    {
        _app = app;
        _configPath = configPath;
        _changed = changed;
        _exit = exit;
        Title = "NanoDictate settings";

        var title = new TextBlock
        {
            Text = "NanoDictate",
            FontSize = 24,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 4),
        };
        var subtitle = new TextBlock
        {
            Text = "Dictation stays active in the background. Double-Alt starts and stops; Escape cancels.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.75,
            Margin = new Thickness(0, 0, 0, 12),
        };

        _diagnostics = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 8, 0, 0),
            Opacity = 0.8,
        };

        _providers = new ComboBox
        {
            Header = "Provider",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(0, 0, 0, 12),
        };
        var providers = _app.ListProviders();
        foreach (var (id, name, isActive) in providers)
        {
            _providers.Items.Add(new ComboBoxItem { Content = $"{name} ({id})", Tag = id });
            if (isActive)
            {
                _providers.SelectedIndex = _providers.Items.Count - 1;
            }
        }
        _providers.SelectionChanged += (_, _) =>
        {
            if (_syncing || _providers.SelectedItem is not ComboBoxItem item || item.Tag is not string id)
            {
                return;
            }
            try
            {
                _app.SelectProvider(id);
                SaveSettings();
                _changed();
            }
            catch (Exception ex)
            {
                _diagnostics.Text = ex.Message;
            }
        };

        _review = new CheckBox
        {
            Content = "Review transcript before inserting",
            IsChecked = _app.Controller.ReviewBeforeInsert,
            Margin = new Thickness(0, 0, 0, 12),
        };
        _review.Checked += (_, _) => SetReview(true);
        _review.Unchecked += (_, _) => SetReview(false);

        var doctor = new Button { Content = "Run diagnostics" };
        doctor.Click += (_, _) =>
        {
            try
            {
                var checks = WindowsDiagnostics.Run(_configPath);
                _diagnostics.Text = WindowsDiagnostics.AllPassed(checks)
                    ? "Diagnostics: ok"
                    : "Diagnostics: " + string.Join(
                        Environment.NewLine,
                        checks.Where(c => !c.Passed).Select(c => $"FAIL {c.Name}: {c.Detail}"));
            }
            catch (Exception ex)
            {
                _diagnostics.Text = $"Diagnostics: {ex.Message}";
            }
        };

        var quit = new Button { Content = "Quit NanoDictate", Margin = new Thickness(0, 12, 0, 0) };
        quit.Click += (_, _) => _exit();

        var panel = new StackPanel
        {
            Spacing = 4,
            Padding = new Thickness(24),
            MaxWidth = 520,
        };
        panel.Children.Add(title);
        panel.Children.Add(subtitle);
        panel.Children.Add(_providers);
        panel.Children.Add(_review);
        panel.Children.Add(doctor);
        panel.Children.Add(_diagnostics);
        panel.Children.Add(quit);
        Content = new ScrollViewer { Content = panel };

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = true;
            presenter.IsMaximizable = false;
        }
        AppWindow.Resize(new Windows.Graphics.SizeInt32(560, 430));
    }

    public void Open()
    {
        _syncing = true;
        try
        {
            var active = _app.ActiveProviderId;
            for (var i = 0; i < _providers.Items.Count; i++)
            {
                if (_providers.Items[i] is ComboBoxItem item && item.Tag is string id && id == active)
                {
                    _providers.SelectedIndex = i;
                    break;
                }
            }
            _review.IsChecked = _app.Controller.ReviewBeforeInsert;
        }
        finally
        {
            _syncing = false;
        }
        Activate();
    }

    private void SetReview(bool enabled)
    {
        if (_syncing)
        {
            return;
        }
        try
        {
            _app.Controller.ReviewBeforeInsert = enabled;
            SaveSettings();
            _changed();
        }
        catch (Exception ex)
        {
            _diagnostics.Text = ex.Message;
        }
    }

    private void SaveSettings()
    {
        PortableConfig.SaveSettings(
            _configPath,
            _app.ActiveProviderId,
            _app.Controller.ReviewBeforeInsert);
    }
}
