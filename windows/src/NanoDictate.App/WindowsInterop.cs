using System.Runtime.InteropServices;
using NanoDictate.Core;

namespace NanoDictate.App;

/// <summary>
/// Small Win32 surface used by the native HUD and optional settings window.
/// Kept separate from the presentation types so all HUD decisions remain
/// testable on non-Windows CI.
/// </summary>
internal static class WindowsInterop
{
    public const int SwHide = 0;
    public const int SwShowNoActivate = 4;
    public const uint SwpNoSize = 0x0001;
    public const uint SwpNoMove = 0x0002;
    public const uint SwpNoZOrder = 0x0004;
    public const uint SwpNoActivate = 0x0010;
    public static readonly IntPtr HwndTopmost = new(-1);

    private const int GwlExStyle = -20;
    private const int WsExTopmost = 0x00000008;
    private const int WsExTransparent = 0x00000020;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExAppWindow = 0x00040000;
    private const int WsExNoActivate = 0x08000000;

    private const uint MonitorDefaultToNearest = 2;
    private const uint GuiCaretBlinking = 0x0001;
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaWindowCornerPreference = 33;

    public static void MakeHudWindow(IntPtr hwnd)
    {
        var style = GetWindowLongPtr(hwnd, GwlExStyle).ToInt64();
        style |= WsExTopmost | WsExToolWindow | WsExNoActivate | WsExTransparent;
        style &= ~WsExAppWindow;
        SetWindowLongPtr(hwnd, GwlExStyle, new IntPtr(style));
        SetWindowPos(
            hwnd,
            HwndTopmost,
            0,
            0,
            0,
            0,
            SwpNoMove | SwpNoSize | SwpNoActivate);

        // Best effort: rounded outer corners and dark title-less frame. These
        // attributes are unsupported on older builds, which is harmless.
        var round = 2;
        _ = DwmSetWindowAttribute(hwnd, DwmwaWindowCornerPreference, ref round, sizeof(int));
        var dark = 1;
        _ = DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
    }

    public static void ShowNoActivate(IntPtr hwnd) =>
        ShowWindow(hwnd, SwShowNoActivate);

    public static void Hide(IntPtr hwnd) => ShowWindow(hwnd, SwHide);

    public static double DpiScale(IntPtr hwnd)
    {
        var dpi = GetDpiForWindow(hwnd);
        return dpi <= 0 ? 1.0 : dpi / 96.0;
    }

    /// <summary>DPI of the monitor containing the anchor point (per-monitor aware).</summary>
    public static double DpiScaleFor(HudPoint point, IntPtr fallbackWindow)
    {
        var monitor = MonitorFromPoint(new Point32((int)point.X, (int)point.Y), MonitorDefaultToNearest);
        if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out var dpiX, out _) == 0 && dpiX > 0)
        {
            return dpiX / 96.0;
        }
        return DpiScale(fallbackWindow);
    }

    public static HudRect WorkAreaFor(HudPoint point)
    {
        var monitor = MonitorFromPoint(new Point32((int)point.X, (int)point.Y), MonitorDefaultToNearest);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info))
        {
            var work = info.Work;
            return new HudRect(work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top);
        }
        return new HudRect(0, 0, 1920, 1080);
    }

    public static IntPtr ForegroundWindow() => GetForegroundWindow();

    public static bool RestoreForeground(IntPtr hwnd) =>
        hwnd != IntPtr.Zero
        && SetForegroundWindow(hwnd)
        && GetForegroundWindow() == hwnd;

    public static bool TryCaret(out HudPoint point)
    {
        if (UiaCaret.TryGet(out point))
        {
            return true;
        }
        return TryNativeCaret(out point);
    }

    private static bool TryNativeCaret(out HudPoint point)
    {
        point = default;
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero)
        {
            return false;
        }
        var thread = GetWindowThreadProcessId(foreground, out _);
        if (thread == 0)
        {
            return false;
        }
        var info = new GuiThreadInfo { Size = Marshal.SizeOf<GuiThreadInfo>() };
        if (!GetGUIThreadInfo(thread, ref info))
        {
            return false;
        }
        if ((info.Flags & GuiCaretBlinking) == 0 || info.CaretWindow == IntPtr.Zero)
        {
            return false;
        }
        var caret = new Point32(info.CaretRect.Left, info.CaretRect.Bottom);
        if (!ClientToScreen(info.CaretWindow, ref caret))
        {
            return false;
        }
        point = new HudPoint(caret.X, caret.Y);
        return true;
    }

    public static HudPoint Pointer()
    {
        return GetCursorPos(out var point)
            ? new HudPoint(point.X, point.Y)
            : new HudPoint(0, 0);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public Point32(int x, int y)
        {
            X = x;
            Y = y;
        }

        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect32
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public Rect32 Monitor;
        public Rect32 Work;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo
    {
        public int Size;
        public uint Flags;
        public IntPtr FocusWindow;
        public IntPtr ActiveWindow;
        public IntPtr CapturedWindow;
        public IntPtr MenuOwnerWindow;
        public IntPtr MoveSizeWindow;
        public IntPtr CaretWindow;
        public Rect32 CaretRect;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int x,
        int y,
        int cx,
        int cy,
        uint flags);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr value);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("Shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(Point32 point, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hWnd, ref Point32 point);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point32 point);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
