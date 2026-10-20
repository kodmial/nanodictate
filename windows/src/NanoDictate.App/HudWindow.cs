using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using NanoDictate.Core;
using Windows.Foundation;
using Windows.Graphics;
using Windows.UI;
using Windows.UI.ViewManagement;
using WinRT.Interop;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace NanoDictate.App;

/// <summary>
/// Transient, non-activating microphone HUD. Rendering is deliberately thin:
/// all phases, hide deadlines, meter ballistics and placement math live in
/// <see cref="NanoDictate.Core"/> so the same behavior is covered by the
/// shared #216 fixture on non-Windows CI. This window only paints a snapshot
/// and applies Win32 styles (tool window, topmost, no activation, click-through).
/// </summary>
public sealed class HudWindow : Window
{
    private const double PanelWidth = 220;
    private const double MeterTrackWidth = 170;

    private readonly IntPtr _hwnd;
    private readonly TextBlock _provider;
    private readonly TextBlock _model;
    private readonly TextBlock _timer;
    private readonly TextBlock _status;
    private readonly TextBlock _version;
    private readonly Ellipse _ring;
    private readonly XamlPath _arc;
    private readonly Ellipse _peakDot;
    private readonly Ellipse _recordDot;
    private readonly Ellipse[] _processingDots;
    private readonly Canvas _processingDotsPanel;
    private readonly Rectangle _meterFill;
    private readonly Grid _ringGrid;
    private readonly Border _panel;
    private readonly Grid _meterTrack;
    private readonly DispatcherQueueTimer _dotsTimer;
    private readonly SolidColorBrush _foregroundBrush = new();
    private readonly SolidColorBrush _secondaryBrush = new();
    private readonly SolidColorBrush _mutedBrush = new();
    private readonly SolidColorBrush _trackBrush = new();
    private readonly SolidColorBrush _accentBrush = new();
    private readonly SolidColorBrush _hotBrush = new();
    private readonly SolidColorBrush _recordBrush = new();
    private UISettings? _uiSettings;
    private bool _visible;
    private bool _allowClose;
    private bool _reduceMotion;
    private int _frame;
    private HudPhase _lastPhase = HudPhase.Idle;

    public HudWindow()
    {
        Title = "NanoDictate";
        _provider = new TextBlock
        {
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 150,
        };
        _model = new TextBlock
        {
            FontSize = 10,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 150,
        };
        _timer = new TextBlock
        {
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        _status = new TextBlock
        {
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        };
        _version = new TextBlock
        {
            FontSize = 10,
            HorizontalAlignment = HorizontalAlignment.Right,
        };

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        header.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_provider, 0);
        Grid.SetColumn(_provider, 0);
        Grid.SetRow(_version, 0);
        Grid.SetColumn(_version, 1);
        Grid.SetRow(_model, 1);
        Grid.SetColumn(_model, 0);
        Grid.SetRow(_timer, 1);
        Grid.SetColumn(_timer, 1);
        header.Children.Add(_provider);
        header.Children.Add(_version);
        header.Children.Add(_model);
        header.Children.Add(_timer);

        _ring = new Ellipse
        {
            Width = HudContract.RingDiameterPoints,
            Height = HudContract.RingDiameterPoints,
            StrokeThickness = HudContract.StrokeMinPoints,
            Fill = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
        };
        _arc = new XamlPath
        {
            StrokeThickness = HudContract.StrokeMinPoints,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        _peakDot = new Ellipse
        {
            Width = 5,
            Height = 5,
            Visibility = Visibility.Collapsed,
        };
        _recordDot = new Ellipse
        {
            Width = HudContract.RecDotDiameterPoints,
            Height = HudContract.RecDotDiameterPoints,
            Visibility = Visibility.Collapsed,
        };
        Canvas.SetLeft(_recordDot, (HudContract.RingDiameterPoints - HudContract.RecDotDiameterPoints) / 2);
        Canvas.SetTop(_recordDot, (HudContract.RingDiameterPoints - HudContract.RecDotDiameterPoints) / 2);

        _processingDots = new Ellipse[HudContract.ProcessingDotCount];
        var dots = new Canvas
        {
            Width = HudContract.RingDiameterPoints,
            Height = HudContract.RingDiameterPoints,
            Visibility = Visibility.Collapsed,
        };
        var dotX = (HudContract.RingDiameterPoints - (HudContract.ProcessingDotCount * 4 + (HudContract.ProcessingDotCount - 1) * 4)) / 2;
        for (var i = 0; i < _processingDots.Length; i++)
        {
            var dot = new Ellipse
            {
                Width = 4,
                Height = 4,
                Opacity = 0.35,
            };
            Canvas.SetLeft(dot, dotX + i * 8);
            Canvas.SetTop(dot, (HudContract.RingDiameterPoints - 4) / 2);
            _processingDots[i] = dot;
            dots.Children.Add(dot);
        }
        _processingDotsPanel = dots;

        var canvas = new Canvas
        {
            Width = HudContract.RingDiameterPoints,
            Height = HudContract.RingDiameterPoints,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        canvas.Children.Add(_ring);
        canvas.Children.Add(_arc);
        canvas.Children.Add(_peakDot);
        canvas.Children.Add(_recordDot);
        canvas.Children.Add(_processingDotsPanel);
        _ringGrid = new Grid
        {
            Width = HudContract.RingDiameterPoints,
            Height = HudContract.RingDiameterPoints,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _ringGrid.Children.Add(canvas);

        _meterTrack = new Grid
        {
            Width = MeterTrackWidth,
            Height = 4,
            CornerRadius = new CornerRadius(2),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _meterFill = new Rectangle
        {
            Width = 0,
            Height = 4,
            RadiusX = 2,
            RadiusY = 2,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        _meterTrack.Children.Add(_meterFill);

        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(header);
        stack.Children.Add(_ringGrid);
        stack.Children.Add(_status);
        stack.Children.Add(_meterTrack);

        _panel = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(HudContract.PanelCornerRadiusPoints),
            Padding = new Thickness(14, 9, 14, 9),
            Child = stack,
            IsHitTestVisible = false,
        };
        Content = _panel;

        _dotsTimer = DispatcherQueue.CreateTimer();
        _dotsTimer.Interval = TimeSpan.FromMilliseconds(300);
        _dotsTimer.Tick += (_, _) => AdvanceProcessingDots();

        _hwnd = WindowNative.GetWindowHandle(this);
        WindowsInterop.MakeHudWindow(_hwnd);
        // The HUD is only shown when the presentation snapshot is visible.
        WindowsInterop.Hide(_hwnd);
        AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.SetBorderAndTitleBar(false, false);
        }
        AppWindow.Closing += (_, args) =>
        {
            if (!_allowClose)
            {
                args.Cancel = true;
                HidePanel();
            }
        };
        ApplyPalette();

        try
        {
            // Theme and high-contrast changes are rare; re-read the system
            // colors on the UI thread rather than sampling them per frame.
            _uiSettings = new UISettings();
            _uiSettings.ColorValuesChanged += (_, _) =>
                DispatcherQueue.TryEnqueue(ApplyPalette);
        }
        catch
        {
            // Keep the startup palette if the settings broker is unavailable.
        }
    }

    public void Apply(HudSnapshot snapshot)
    {
        if (!snapshot.Visible)
        {
            HidePanel();
            return;
        }

        _provider.Text = snapshot.Provider;
        _model.Text = snapshot.Model;
        _version.Text = string.IsNullOrEmpty(snapshot.Version) ? string.Empty : "v" + snapshot.Version;
        _status.Text = snapshot.StatusText;
        _timer.Text = snapshot.HasTimer ? snapshot.ElapsedText : string.Empty;

        var hot = HudLevel.IsHot(snapshot.Meter);
        var levelBrush = hot ? _hotBrush : _accentBrush;
        _arc.Stroke = levelBrush;
        _arc.StrokeThickness = snapshot.StrokeWidth;
        UpdateArc(snapshot.Meter);
        _peakDot.Fill = levelBrush;
        _meterFill.Fill = levelBrush;
        _meterFill.Width = MeterTrackWidth * snapshot.Meter;

        _recordDot.Visibility = snapshot.HasRecordingIndicator ? Visibility.Visible : Visibility.Collapsed;
        _processingDotsPanel.Visibility = snapshot.HasProcessingDots ? Visibility.Visible : Visibility.Collapsed;
        _peakDot.Visibility = snapshot.Meter > 0.01 ? Visibility.Visible : Visibility.Collapsed;

        if (snapshot.Peak > 0.01)
        {
            var angle = (-90 + 360 * snapshot.Peak) * Math.PI / 180;
            var radius = HudContract.RingDiameterPoints / 2 - 3;
            var cx = HudContract.RingDiameterPoints / 2 + Math.Cos(angle) * radius;
            var cy = HudContract.RingDiameterPoints / 2 + Math.Sin(angle) * radius;
            Canvas.SetLeft(_peakDot, cx - 2.5);
            Canvas.SetTop(_peakDot, cy - 2.5);
        }

        _reduceMotion = snapshot.ReduceMotion;
        if (snapshot.HasProcessingDots)
        {
            ApplyProcessingDots();
            _dotsTimer.Start();
        }
        else
        {
            _dotsTimer.Stop();
        }

        if (!_visible || _lastPhase != snapshot.Phase)
        {
            Place(snapshot.Phase);
        }
        _lastPhase = snapshot.Phase;
        WindowsInterop.ShowNoActivate(_hwnd);
        _visible = true;
    }

    public void HidePanel()
    {
        _dotsTimer.Stop();
        WindowsInterop.Hide(_hwnd);
        _visible = false;
        _lastPhase = HudPhase.Idle;
    }

    public void CloseForShutdown()
    {
        _dotsTimer.Stop();
        _allowClose = true;
        Close();
    }

    private void AdvanceProcessingDots()
    {
        _frame = (_frame + 1) % HudContract.ProcessingDotCount;
        ApplyProcessingDots();
    }

    private void ApplyProcessingDots()
    {
        for (var i = 0; i < _processingDots.Length; i++)
        {
            _processingDots[i].Opacity = _reduceMotion
                ? 0.9
                : i == _frame ? 1.0 : 0.25;
        }
    }

    private void ApplyPalette()
    {
        Color background;
        Color foreground;
        Color accent;
        bool highContrast;
        try
        {
            var ui = new UISettings();
            var accessibility = new AccessibilitySettings();
            background = ui.GetColorValue(UIColorType.Background);
            foreground = ui.GetColorValue(UIColorType.Foreground);
            accent = ui.GetColorValue(UIColorType.Accent);
            highContrast = accessibility.HighContrast;
        }
        catch
        {
            return;
        }

        var dark = (background.R * 0.2126 + background.G * 0.7152 + background.B * 0.0722) < 128;
        var panelAlpha = highContrast ? (byte)255 : dark ? (byte)0xE6 : (byte)0xF2;
        _panel.Background = new SolidColorBrush(WithAlpha(background, panelAlpha));
        _panel.BorderBrush = new SolidColorBrush(WithAlpha(foreground, highContrast ? (byte)255 : (byte)0x33));
        _foregroundBrush.Color = WithAlpha(foreground, 0xFF);
        _secondaryBrush.Color = WithAlpha(foreground, highContrast ? (byte)255 : (byte)0x99);
        _mutedBrush.Color = WithAlpha(foreground, highContrast ? (byte)255 : (byte)0x80);
        _trackBrush.Color = WithAlpha(foreground, highContrast ? (byte)0x80 : (byte)0x2E);
        _accentBrush.Color = accent;
        _hotBrush.Color = highContrast ? foreground : Color.FromArgb(0xFF, 0xFF, 0x6B, 0x6B);
        _recordBrush.Color = highContrast ? foreground : Color.FromArgb(0xFF, 0xFF, 0x5B, 0x5B);

        _provider.Foreground = _foregroundBrush;
        _model.Foreground = _secondaryBrush;
        _timer.Foreground = _secondaryBrush;
        _status.Foreground = _foregroundBrush;
        _version.Foreground = _mutedBrush;
        _ring.Stroke = _trackBrush;
        _recordDot.Fill = _recordBrush;
        _meterTrack.Background = _trackBrush;
        foreach (var dot in _processingDots)
        {
            dot.Fill = _foregroundBrush;
        }
    }

    private static Color WithAlpha(Color color, byte alpha) =>
        Color.FromArgb(alpha, color.R, color.G, color.B);

    private void UpdateArc(float meter)
    {
        var clamped = Math.Clamp(meter, 0f, 0.9999f);
        if (clamped <= 0.001f)
        {
            _arc.Data = null;
            return;
        }
        var center = HudContract.RingDiameterPoints / 2;
        var radius = center - _arc.StrokeThickness / 2;
        var sweep = clamped * 2 * Math.PI;
        var start = new Point(center, center - radius);
        var end = new Point(
            center + radius * Math.Sin(sweep),
            center - radius * Math.Cos(sweep));
        var figure = new PathFigure
        {
            StartPoint = start,
            IsClosed = false,
            IsFilled = false,
        };
        figure.Segments.Add(new ArcSegment
        {
            Point = end,
            Size = new Size(radius, radius),
            IsLargeArc = clamped > 0.5f,
            SweepDirection = SweepDirection.Clockwise,
        });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        _arc.Data = geometry;
    }

    private void Place(HudPhase phase)
    {
        var hasCaret = WindowsInterop.TryCaret(out var caret);
        var pointer = WindowsInterop.Pointer();
        var anchorProbe = hasCaret ? caret : pointer;
        var scale = WindowsInterop.DpiScaleFor(anchorProbe, _hwnd);
        var panel = new HudSize(PanelWidth * scale, HudLayout.PanelHeight(phase) * scale);
        var screen = WindowsInterop.WorkAreaFor(anchorProbe);
        var center = new HudPoint(screen.X + screen.Width / 2, screen.Y + screen.Height / 2);
        var anchor = HudLayout.ResolvePoint(
            hasCaret ? caret : null,
            pointer,
            center,
            p => p.X >= screen.X && p.X <= screen.Right && p.Y >= screen.Y && p.Y <= screen.Bottom);
        var frame = HudLayout.PanelFrame(anchor, screen, panel, scale);
        AppWindow.MoveAndResize(new RectInt32(
            (int)Math.Round(frame.X),
            (int)Math.Round(frame.Y),
            (int)Math.Round(panel.Width),
            (int)Math.Round(panel.Height)));
    }

}
