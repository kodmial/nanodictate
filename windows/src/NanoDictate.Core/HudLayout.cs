namespace NanoDictate.Core;

/// <summary>Screen-space point in physical pixels (Win32 top-left origin).</summary>
public readonly record struct HudPoint(double X, double Y);

/// <summary>
/// Screen-space caret anchor in physical pixels. <see cref="Point"/> is the
/// caret's bottom-left point and <see cref="Height"/> is its vertical extent.
/// </summary>
public readonly record struct HudCaret(HudPoint Point, double Height);

/// <summary>Screen-space size in physical pixels.</summary>
public readonly record struct HudSize(double Width, double Height);

/// <summary>Screen-space rectangle in physical pixels.</summary>
public readonly record struct HudRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;

    public double Bottom => Y + Height;
}

/// <summary>
/// Pure HUD placement policy shared by the WinUI adapter and tests. Windows
/// coordinates grow downward, so "above the caret" subtracts the panel height
/// plus the contract gap. The panel is clamped into the monitor work area and
/// falls back caret → pointer → monitor center, matching the macOS reference.
/// </summary>
public static class HudLayout
{
    public const double GapPoints = 12;
    public const double ScreenMarginPoints = 8;

    public static HudPoint ResolvePoint(
        HudPoint? caret,
        HudPoint pointer,
        HudPoint screenCenter,
        Func<HudPoint, bool> isValid)
    {
        if (caret.HasValue && isValid(caret.Value))
        {
            return caret.Value;
        }
        if (isValid(pointer))
        {
            return pointer;
        }
        return screenCenter;
    }

    public static HudRect PanelFrame(
        HudPoint anchor,
        HudRect screen,
        HudSize panel,
        double scale = 1,
        double anchorHeight = 0)
    {
        scale = scale > 0 ? scale : 1;
        var gap = GapPoints * scale;
        var margin = ScreenMarginPoints * scale;
        var posX = anchor.X - panel.Width / 2;
        var clampedX = Math.Clamp(
            posX,
            screen.X + margin,
            Math.Max(screen.X + margin, screen.Right - panel.Width - margin));

        var anchorTop = anchor.Y - Math.Max(0, anchorHeight);
        var aboveY = anchorTop - gap - panel.Height;
        if (aboveY >= screen.Y + margin)
        {
            return new HudRect(clampedX, aboveY, panel.Width, panel.Height);
        }

        var belowY = Math.Max(
            anchor.Y + gap,
            screen.Y + margin);
        belowY = Math.Min(belowY, Math.Max(screen.Y + margin, screen.Bottom - panel.Height - margin));
        return new HudRect(clampedX, belowY, panel.Width, panel.Height);
    }

    public static double PanelHeight(HudPhase phase) =>
        phase == HudPhase.Recording
            ? HudContract.PanelHeightRecordingPoints
            : HudContract.PanelHeightIdlePoints;

    public static double ClampPanelWidth(double width) =>
        Math.Clamp(width, HudContract.PanelMinWidthPoints, HudContract.PanelMaxWidthPoints);
}
