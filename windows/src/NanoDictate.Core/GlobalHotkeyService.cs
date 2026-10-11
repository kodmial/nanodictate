using System.Runtime.InteropServices;

namespace NanoDictate.Core;

/// <summary>Delegate for global hotkey events (mirrors macOS HotkeyDelegate).</summary>
public interface IGlobalHotkeyDelegate
{
    void AltDoubleTapped();
    void AltFirstTapDetected();
    void AltPendingCancelled();
    /// <summary>Escape: the only cancel key.</summary>
    void CancelKeyPressed();
    /// <summary>Return/Enter: the agent decides by Rust session state.</summary>
    void EnterKeyPressed();
    /// <summary>
    /// Swallow the physical Return event? True hides it from the focused app.
    /// The agent returns true while recording/transcribing (queried from the
    /// Rust session via <c>nd_overlay_should_hide</c> inversion), false in idle.
    /// </summary>
    bool ShouldSwallowReturnKeyEvent();
}

/// <summary>Testable key-event description for the routing core.</summary>
public readonly record struct HotkeyEvent(
    int VirtualKey,
    bool IsKeyDown,
    bool IsRepeat,
    IntPtr ExtraInfo,
    double TimestampSecs);

/// <summary>
/// Global double-Alt activation with false-trigger protection and safe hook
/// recovery (Windows counterpart of macOS <c>HotkeyService</c>).
/// The routing core (<see cref="HandleKeyEvent"/>) is pure and runs on any
/// OS; only <see cref="Start"/>/<see cref="Stop"/> touch Win32.
/// False-trigger rules (ported verbatim): only Alt key codes count as taps;
/// any other key or modifier between Alt presses cancels the pending first
/// tap; held-key autorepeat is never a new tap; Escape cancels the pending
/// tap and raises cancel; Return cancels the pending tap and raises enter
/// (own synthetic Return is excluded entirely).
/// </summary>
public sealed class GlobalHotkeyService : IDisposable
{
    // Virtual keys.
    public const int VkMenu = 0x12;
    public const int VkLMenu = 0xA4;
    public const int VkRMenu = 0xA5;
    public const int VkEscape = 0x1B;
    public const int VkReturn = 0x0D;
    public const int VkControl = 0x11;
    public const int VkShift = 0x10;
    public const int VkLWin = 0x5B;
    public const int VkRWin = 0x5C;

    private const int WhKeyboardLl = 13;
    private const int WmKeydown = 0x0100;
    private const int WmSyskeydown = 0x0104;
    private const int WmKeyup = 0x0101;
    private const int WmSyskeyup = 0x0105;

    private readonly object _gate = new();
    private DoubleAltDetector _detector;
    private readonly double _maxInterval;
    private Timer? _expiryTimer;
    private ulong _generation;
    private bool _disposed;

    // Win32 hook state (Windows only).
    private IntPtr _hookId = IntPtr.Zero;
    private LowLevelKeyboardProc? _proc;
    private int _hookFailures;

    public GlobalHotkeyService(double doubleTapMaxInterval = 0.4)
    {
        if (doubleTapMaxInterval <= 0)
        {
            throw new NanoException(-1, "double-tap interval must be positive");
        }
        _maxInterval = doubleTapMaxInterval;
        _detector = new DoubleAltDetector(doubleTapMaxInterval);
    }

    public IGlobalHotkeyDelegate? Delegate { get; set; }

    public bool IsRunning => _hookId != IntPtr.Zero;

    /// <summary>True while a first Alt tap awaits confirmation.</summary>
    public bool IsAltPending
    {
        get { lock (_gate) { return _detector.IsPending; } }
    }

    /// <summary>Consecutive hook-install failures (observability for recovery).</summary>
    public int HookFailures => Volatile.Read(ref _hookFailures);

    /// <summary>
    /// Pure routing core. Returns true when the caller must swallow the event
    /// (physical Return outside idle). Safe to call from tests on any OS.
    /// </summary>
    public bool HandleKeyEvent(HotkeyEvent evt)
    {
        IGlobalHotkeyDelegate? sink;
        bool fireDouble = false;
        bool fireFirst = false;
        bool firePendingCancelled = false;
        bool fireCancel = false;
        bool fireEnter = false;
        bool swallow = false;
        lock (_gate)
        {
            ThrowIfDisposed();
            sink = Delegate;
            if (!evt.IsKeyDown)
            {
                // Key-up never routes; Alt release keeps the pending tap valid
                // (clean Alt down/up/down stays a double tap).
            }
            else if (SyntheticEnterMarker.IsOwnSyntheticEnter(evt.ExtraInfo))
            {
                // Own synthetic Enter: excluded entirely.
            }
            else if (evt.VirtualKey == VkLMenu || evt.VirtualKey == VkRMenu || evt.VirtualKey == VkMenu)
            {
                if (!evt.IsRepeat)
                {
                    if (_detector.RegisterTap(evt.TimestampSecs))
                    {
                        CancelExpiryLocked();
                        fireDouble = true;
                    }
                    else
                    {
                        fireFirst = true;
                        ScheduleExpiryLocked();
                    }
                }
            }
            else if (evt.VirtualKey == VkEscape)
            {
                if (_detector.IsPending)
                {
                    _detector.CancelPendingTap();
                    CancelExpiryLocked();
                    firePendingCancelled = true;
                }
                fireCancel = true;
            }
            else if (evt.VirtualKey == VkReturn)
            {
                if (_detector.IsPending)
                {
                    _detector.CancelPendingTap();
                    CancelExpiryLocked();
                    firePendingCancelled = true;
                }
                fireEnter = true;
                swallow = sink?.ShouldSwallowReturnKeyEvent() ?? false;
            }
            else if (_detector.IsPending)
            {
                // Any other key (including Control/Shift/Win modifiers) between
                // Alt presses cancels the pending first tap.
                _detector.CancelPendingTap();
                CancelExpiryLocked();
                firePendingCancelled = true;
            }
        }
        // Delegate callbacks run outside the lock: a delegate may call back
        // into ExpirePendingForTests/Stop without deadlocking.
        if (firePendingCancelled)
        {
            sink?.AltPendingCancelled();
        }
        if (fireDouble)
        {
            sink?.AltDoubleTapped();
        }
        else if (fireFirst)
        {
            sink?.AltFirstTapDetected();
        }
        if (fireCancel)
        {
            sink?.CancelKeyPressed();
        }
        if (fireEnter)
        {
            sink?.EnterKeyPressed();
        }
        return swallow;
    }

    /// <summary>Deterministic pending-expiry for tests (no wall-clock wait).</summary>
    public void ExpirePendingForTests()
    {
        IGlobalHotkeyDelegate? sink;
        bool fire = false;
        lock (_gate)
        {
            if (!_detector.IsPending)
            {
                return;
            }
            _detector.CancelPendingTap();
            CancelExpiryLocked();
            sink = Delegate;
            fire = true;
        }
        if (fire)
        {
            sink?.AltPendingCancelled();
        }
    }

    /// <summary>
    /// Installs the low-level keyboard hook. Windows only; throws
    /// <see cref="PlatformNotSupportedException"/> elsewhere (never a silent
    /// no-op) and <see cref="NanoException"/> with recovery guidance when
    /// the hook cannot be installed.
    /// </summary>
    public void Start()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Global hotkeys require Windows (WH_KEYBOARD_LL).");
        }
        lock (_gate)
        {
            ThrowIfDisposed();
            if (_hookId != IntPtr.Zero)
            {
                return;
            }
            _proc = HookCallback;
            var module = GetModuleHandle(null);
            var id = SetWindowsHookEx(WhKeyboardLl, _proc, module, 0);
            if (id == IntPtr.Zero)
            {
                Interlocked.Increment(ref _hookFailures);
                var error = Marshal.GetLastWin32Error();
                throw new NanoException(error, $"Failed to install the global keyboard hook (Win32 error {error}). Restart the app; if it persists, check that no security software blocks low-level keyboard hooks.");
            }
            _hookId = id;
        }
    }

    /// <summary>
    /// Reinstalls the hook after a failure or a suspected silent removal
    /// (Windows drops slow low-level hooks). Safe to call when stopped.
    /// </summary>
    public void Recover()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Global hotkeys require Windows (WH_KEYBOARD_LL).");
        }
        lock (_gate)
        {
            ThrowIfDisposed();
            if (_hookId != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hookId);
                _hookId = IntPtr.Zero;
            }
            _proc = HookCallback;
            var module = GetModuleHandle(null);
            var id = SetWindowsHookEx(WhKeyboardLl, _proc, module, 0);
            if (id == IntPtr.Zero)
            {
                Interlocked.Increment(ref _hookFailures);
                var error = Marshal.GetLastWin32Error();
                throw new NanoException(error, $"Failed to reinstall the global keyboard hook (Win32 error {error}).");
            }
            _hookId = id;
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            CancelExpiryLocked();
            _detector.CancelPendingTap();
            if (_hookId != IntPtr.Zero && OperatingSystem.IsWindows())
            {
                UnhookWindowsHookEx(_hookId);
            }
            _hookId = IntPtr.Zero;
        }
    }

    private void ScheduleExpiryLocked()
    {
        CancelExpiryLocked();
        _generation++;
        var generation = _generation;
        _expiryTimer = new Timer(_ =>
        {
            IGlobalHotkeyDelegate? sink;
            bool fire = false;
            lock (_gate)
            {
                if (generation != _generation || !_detector.IsPending)
                {
                    return;
                }
                _detector.CancelPendingTap();
                _expiryTimer?.Dispose();
                _expiryTimer = null;
                sink = Delegate;
                fire = true;
            }
            if (fire)
            {
                sink?.AltPendingCancelled();
            }
        }, null, TimeSpan.FromSeconds(_maxInterval), Timeout.InfiniteTimeSpan);
    }

    private void CancelExpiryLocked()
    {
        _generation++;
        _expiryTimer?.Dispose();
        _expiryTimer = null;
    }

    private IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && lParam != IntPtr.Zero)
        {
            var msg = wParam.ToInt32();
            bool isDown = msg == WmKeydown || msg == WmSyskeydown;
            bool isUp = msg == WmKeyup || msg == WmSyskeyup;
            if (isDown || isUp)
            {
                var data = Marshal.PtrToStructure<KbdLlHookStruct>(lParam);
                var evt = new HotkeyEvent(
                    (int)data.VkCode,
                    isDown,
                    (data.Flags & 0x4000) != 0,
                    new IntPtr(unchecked((nint)data.DwExtraInfo)),
                    CurrentMonotonicSecs());
                bool swallow = false;
                try
                {
                    swallow = HandleKeyEvent(evt);
                }
                catch
                {
                    // The hook must never throw across Win32: fail open and
                    // let the event through; the failure is observable via
                    // HookFailures for the watchdog.
                    Interlocked.Increment(ref _hookFailures);
                    swallow = false;
                }
                if (swallow)
                {
                    return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(_hookId, code, wParam, lParam);
    }

    private static double CurrentMonotonicSecs() =>
        (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(GlobalHotkeyService));
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            CancelExpiryLocked();
            if (_hookId != IntPtr.Zero && OperatingSystem.IsWindows())
            {
                UnhookWindowsHookEx(_hookId);
            }
            _hookId = IntPtr.Zero;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KbdLlHookStruct
    {
        public uint VkCode;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr DwExtraInfo;
    }

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
}
