namespace NanoDictate.Core;

/// <summary>Clipboard snapshot: the exact text written plus the prior content.</summary>
public sealed record ClipboardSnapshot(string Text, ClipboardSnapshot? Prior = null);

/// <summary>Clipboard + paste + restore scheduling seams (testable on any OS).</summary>
public interface IClipboardBridge
{
    ClipboardSnapshot Read();
    void Write(string text);
    void Restore(ClipboardSnapshot snapshot);
    void SendPaste();
}

/// <summary>Scheduling seam for the clipboard restore delay.</summary>
public interface IRestoreScheduler
{
    void Schedule(Action restore, TimeSpan delay);
}

public sealed class ImmediateRestoreScheduler : IRestoreScheduler
{
    public void Schedule(Action restore, TimeSpan delay) => restore();
}

public sealed class TimerRestoreScheduler : IRestoreScheduler
{
    public void Schedule(Action restore, TimeSpan delay)
    {
        var timer = new Timer(_ => restore(), null, delay, Timeout.InfiniteTimeSpan);
        _ = timer;
    }
}

/// <summary>
/// Clipboard insertion mode: saves the current clipboard, writes the
/// dictation text, emulates Ctrl+V, then restores the original content after
/// <c>RestoreDelay</c> (0.5 s, matching macOS). Overlapping insertions reuse
/// the original snapshot (never our own dictation text); only the latest
/// scheduled restore runs (generation guard). Ports macOS
/// <c>Inserter.insertViaClipboard</c> semantics to the Windows clipboard.
/// </summary>
public sealed class ClipboardInsertService
{
    public static readonly TimeSpan DefaultRestoreDelay = TimeSpan.FromSeconds(0.5);

    private readonly object _gate = new();
    private readonly IClipboardBridge _bridge;
    private readonly IRestoreScheduler _scheduler;
    private readonly TimeSpan _restoreDelay;
    private ClipboardSnapshot? _pendingOriginal;
    private ulong _generation;

    public ClipboardInsertService(
        IClipboardBridge bridge,
        IRestoreScheduler? scheduler = null,
        TimeSpan? restoreDelay = null)
    {
        _bridge = bridge ?? throw new ArgumentNullException(nameof(bridge));
        _scheduler = scheduler ?? new TimerRestoreScheduler();
        _restoreDelay = restoreDelay ?? DefaultRestoreDelay;
    }

    /// <summary>True while a restore is pending (observability for tests).</summary>
    public bool HasPendingRestore
    {
        get { lock (_gate) { return _pendingOriginal is not null; } }
    }

    public void InsertViaClipboard(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        ClipboardSnapshot original;
        ulong generation;
        lock (_gate)
        {
            original = _pendingOriginal ?? _bridge.Read();
            _pendingOriginal = original;
            _generation++;
            generation = _generation;
        }
        _bridge.Write(text);
        _bridge.SendPaste();
        _scheduler.Schedule(() =>
        {
            lock (_gate)
            {
                if (generation != _generation)
                {
                    return;
                }
                _pendingOriginal = null;
            }
            _bridge.Restore(original);
        }, _restoreDelay);
    }
}

/// <summary>
/// Windows clipboard bridge over raw Win32 clipboard APIs (CF_UNICODETEXT).
/// No WinForms dependency: OpenClipboard/EmptyClipboard/SetClipboardData
/// plus Ctrl+V through SendInput. Must be called from an STA thread in the
/// host process (the controller documents this); the bridge itself fails
/// loudly on non-Windows instead of silently skipping the paste.
/// Platform difference (explicit): macOS snapshots every pasteboard item and
/// type (images, files); this bridge preserves the Unicode text slot, which
/// is the only slot dictation overwrites. Non-text formats coexisting with
/// text are left to the OS lifetime rules and documented, never silently
/// claimed as preserved.
/// </summary>
public sealed class WindowsClipboardBridge : IClipboardBridge
{
    private const uint CfUnicodeText = 13;
    private const uint GmemMoveable = 0x0002;

    public ClipboardSnapshot Read()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Clipboard insertion requires Windows.");
        }
        if (!OpenClipboard(IntPtr.Zero))
        {
            throw new NanoException(System.Runtime.InteropServices.Marshal.GetLastWin32Error(), "OpenClipboard failed while saving the clipboard");
        }
        try
        {
            var handle = GetClipboardData(CfUnicodeText);
            if (handle == IntPtr.Zero)
            {
                return new ClipboardSnapshot(string.Empty);
            }
            var locked = GlobalLock(handle);
            if (locked == IntPtr.Zero)
            {
                return new ClipboardSnapshot(string.Empty);
            }
            try
            {
                return new ClipboardSnapshot(System.Runtime.InteropServices.Marshal.PtrToStringUni(locked) ?? string.Empty);
            }
            finally
            {
                GlobalUnlock(handle);
            }
        }
        finally
        {
            CloseClipboard();
        }
    }

    public void Write(string text)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Clipboard insertion requires Windows.");
        }
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        SetUnicodeText(text);
    }

    public void Restore(ClipboardSnapshot snapshot)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Clipboard insertion requires Windows.");
        }
        if (snapshot.Text.Length == 0)
        {
            if (!OpenClipboard(IntPtr.Zero))
            {
                return;
            }
            try
            {
                EmptyClipboard();
            }
            finally
            {
                CloseClipboard();
            }
            return;
        }
        SetUnicodeText(snapshot.Text);
    }

    public void SendPaste()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Clipboard paste requires Windows.");
        }
        SendCtrlV();
    }

    private static void SetUnicodeText(string text)
    {
        if (!OpenClipboard(IntPtr.Zero))
        {
            throw new NanoException(System.Runtime.InteropServices.Marshal.GetLastWin32Error(), "OpenClipboard failed while writing dictation text");
        }
        try
        {
            EmptyClipboard();
            var bytes = (text.Length + 1) * 2;
            var mem = GlobalAlloc(GmemMoveable, (UIntPtr)bytes);
            if (mem == IntPtr.Zero)
            {
                throw new NanoException(System.Runtime.InteropServices.Marshal.GetLastWin32Error(), "GlobalAlloc failed for clipboard text");
            }
            var locked = GlobalLock(mem);
            if (locked == IntPtr.Zero)
            {
                GlobalFree(mem);
                throw new NanoException(System.Runtime.InteropServices.Marshal.GetLastWin32Error(), "GlobalLock failed for clipboard text");
            }
            try
            {
                System.Runtime.InteropServices.Marshal.Copy((text + "\0").ToCharArray(), 0, locked, text.Length + 1);
            }
            finally
            {
                GlobalUnlock(mem);
            }
            if (SetClipboardData(CfUnicodeText, mem) == IntPtr.Zero)
            {
                GlobalFree(mem);
                throw new NanoException(System.Runtime.InteropServices.Marshal.GetLastWin32Error(), "SetClipboardData failed for dictation text");
            }
            // Ownership passed to the clipboard; do not free on success.
        }
        finally
        {
            CloseClipboard();
        }
    }

    private static void SendCtrlV()
    {
        // Ctrl+V as virtual-key inputs (VK_CONTROL 0x11 held around 'V' 0x56).
        var inputs = new CtrlVInput[4];
        inputs[0] = Key(0x11, false);
        inputs[1] = Key(0x56, false);
        inputs[2] = Key(0x56, true);
        inputs[3] = Key(0x11, true);
        var sent = SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf<CtrlVInput>());
        if (sent != inputs.Length)
        {
            throw new NanoException(System.Runtime.InteropServices.Marshal.GetLastWin32Error(), "SendInput failed to deliver Ctrl+V");
        }
    }

    private static CtrlVInput Key(ushort vk, bool up) => new()
    {
        Type = 1,
        VirtualKey = vk,
        ScanCode = 0,
        Flags = up ? 0x0002u : 0u,
        Time = 0,
        ExtraInfo = IntPtr.Zero,
    };

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct CtrlVInput
    {
        public uint Type;
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
        private readonly ulong _pad;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint uFormat);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr hMem);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(IntPtr hMem);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr hMem);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, [System.Runtime.InteropServices.In] CtrlVInput[] pInputs, int cbSize);
}
