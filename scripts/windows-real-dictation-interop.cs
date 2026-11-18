// Windows interop for the opt-in real-dictation qualification.
//
// This file is compiled at runtime by scripts/windows-real-dictation.psm1
// (Add-Type) and is never part of the shipped NanoDictate binaries. It only
// provides observation/injection primitives for a test harness:
//   * MMDevice/WASAPI endpoint enumeration and shared-mode WAV rendering
//   * SendInput keyboard events (real Double-Alt, Return, Escape, Ctrl+A/C)
//   * window discovery, focus and screenshot (BMP) capture
//   * session/desktop probes that explain whether an interactive desktop exists
//
// Every native call fails loudly with a Win32Exception instead of silently
// pretending that input, audio or rendering worked.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace NanoDictate.RealDictation
{
    public sealed class AudioEndpointInfo
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Flow { get; set; }
        public string State { get; set; }
        public int FormatTag { get; set; }
        public int Channels { get; set; }
        public int SampleRate { get; set; }
        public int BitsPerSample { get; set; }
    }

    public sealed class WindowProbe
    {
        public long Handle { get; set; }
        public string Title { get; set; }
        public string ClassName { get; set; }
        public bool Visible { get; set; }
        public int ProcessId { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
    }

    public sealed class ScreenCaptureResult
    {
        public bool Saved { get; set; }
        public string Path { get; set; }
        public string Method { get; set; }
        // True only for a successful PrintWindow capture. A BitBlt fallback is
        // a screen-region copy and may show an overlapping window instead.
        public bool WindowEvidence { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public int NonBlankPixels { get; set; }
    }

    public sealed class SessionProbe
    {
        public int ProcessId { get; set; }
        public int SessionId { get; set; }
        public int ActiveConsoleSessionId { get; set; }
        public bool UserInteractive { get; set; }
        public string DesktopName { get; set; }
        public bool InputDesktopAvailable { get; set; }
        public string InputDesktopName { get; set; }
    }

    public static class Native
    {
        // ---------------------------------------------------------------
        // Session / desktop probes
        // ---------------------------------------------------------------

        public static SessionProbe ProbeSession()
        {
            var probe = new SessionProbe();
            probe.ProcessId = (int)GetCurrentProcessId();
            uint session;
            if (ProcessIdToSessionId((uint)probe.ProcessId, out session))
            {
                probe.SessionId = (int)session;
            }
            probe.ActiveConsoleSessionId = (int)WTSGetActiveConsoleSessionId();
            probe.UserInteractive = Environment.UserInteractive;
            probe.DesktopName = ReadDesktopName(GetThreadDesktop(GetCurrentThreadId()));
            IntPtr input = OpenInputDesktop(0, false, DesktopReadObjects);
            probe.InputDesktopAvailable = input != IntPtr.Zero;
            if (input != IntPtr.Zero)
            {
                probe.InputDesktopName = ReadDesktopName(input);
                CloseDesktop(input);
            }
            return probe;
        }

        private static string ReadDesktopName(IntPtr desktop)
        {
            if (desktop == IntPtr.Zero)
            {
                return null;
            }
            uint needed;
            GetUserObjectInformation(desktop, UoiName, IntPtr.Zero, 0, out needed);
            if (needed <= 1 || needed > 4096)
            {
                return null;
            }
            IntPtr buffer = Marshal.AllocHGlobal((int)needed);
            try
            {
                uint written;
                if (!GetUserObjectInformation(desktop, UoiName, buffer, needed, out written))
                {
                    return null;
                }
                return Marshal.PtrToStringUni(buffer);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        // ---------------------------------------------------------------
        // WASAPI / MMDevice endpoints
        // ---------------------------------------------------------------

        public static AudioEndpointInfo[] EnumerateAudioEndpoints()
        {
            var results = new List<AudioEndpointInfo>();
            object enumerator = null;
            try
            {
                enumerator = CreateEnumerator();
                var enumInterface = (IMMDeviceEnumerator)enumerator;
                AddEndpoints(results, enumInterface, DataFlow.Capture, "capture");
                AddEndpoints(results, enumInterface, DataFlow.Render, "render");
            }
            finally
            {
                Release(enumerator);
            }
            return results.ToArray();
        }

        public static AudioEndpointInfo GetDefaultAudioEndpoint(string flow, string role)
        {
            object enumerator = null;
            object device = null;
            try
            {
                enumerator = CreateEnumerator();
                var enumInterface = (IMMDeviceEnumerator)enumerator;
                int hr = enumInterface.GetDefaultAudioEndpoint(ParseFlow(flow), ParseRole(role), out device);
                if (hr == ElementNotFound)
                {
                    return null;
                }
                // A failing HRESULT other than ELEMENT_NOTFOUND is a probe
                // failure, not an absent endpoint: surface it instead of
                // reporting an empty/null device.
                ThrowIfFailed(hr, "get default audio endpoint");
                if (device == null)
                {
                    return null;
                }
                return DescribeDevice((IMMDevice)device, flow);
            }
            finally
            {
                Release(device);
                Release(enumerator);
            }
        }

        private static void AddEndpoints(List<AudioEndpointInfo> results, IMMDeviceEnumerator enumerator,
            DataFlow flow, string flowName)
        {
            object collection = null;
            try
            {
                int hr = enumerator.EnumAudioEndpoints(flow, StateAll, out collection);
                if (hr == ElementNotFound)
                {
                    return;
                }
                ThrowIfFailed(hr, "enumerate audio endpoints");
                if (collection == null)
                {
                    return;
                }
                var devices = (IMMDeviceCollection)collection;
                uint count;
                ThrowIfFailed(devices.GetCount(out count), "count audio endpoints");
                for (uint index = 0; index < count; index++)
                {
                    object device = null;
                    try
                    {
                        if (devices.Item(index, out device) != 0 || device == null)
                        {
                            continue;
                        }
                        results.Add(DescribeDevice((IMMDevice)device, flowName));
                    }
                    finally
                    {
                        Release(device);
                    }
                }
            }
            finally
            {
                Release(collection);
            }
        }

        private static AudioEndpointInfo DescribeDevice(IMMDevice device, string flowName)
        {
            var info = new AudioEndpointInfo { Flow = flowName };
            try
            {
                string id;
                if (device.GetId(out id) == 0)
                {
                    info.Id = id ?? string.Empty;
                }
                else
                {
                    info.Id = string.Empty;
                }
            }
            catch
            {
                info.Id = string.Empty;
            }
            try
            {
                info.Name = ReadFriendlyName(device);
            }
            catch
            {
                info.Name = string.Empty;
            }
            uint state;
            if (device.GetState(out state) == 0)
            {
                info.State = DescribeState(state);
            }
            else
            {
                info.State = "unknown";
            }

            object clientObject = null;
            try
            {
                var iid = IidAudioClient;
                if (device.Activate(ref iid, ClsctxAll, IntPtr.Zero, out clientObject) == 0 && clientObject != null)
                {
                    var client = (IAudioClient)clientObject;
                    IntPtr format;
                    if (client.GetMixFormat(out format) == 0 && format != IntPtr.Zero)
                    {
                        try
                        {
                            var wave = (WaveFormatEx)Marshal.PtrToStructure(format, typeof(WaveFormatEx));
                            info.FormatTag = wave.FormatTag;
                            info.Channels = wave.Channels;
                            info.SampleRate = (int)wave.SamplesPerSec;
                            info.BitsPerSample = wave.BitsPerSample;
                        }
                        finally
                        {
                            Marshal.FreeCoTaskMem(format);
                        }
                    }
                }
            }
            catch
            {
                // Format details are diagnostic only.
            }
            finally
            {
                Release(clientObject);
            }
            return info;
        }

        private static string ReadFriendlyName(IMMDevice device)
        {
            object storeObject = null;
            try
            {
                ThrowIfFailed(device.OpenPropertyStore(0, out storeObject), "open device property store");
                var store = (IPropertyStore)storeObject;
                var key = PropertyKeyFriendlyName;
                PropVariant value;
                ThrowIfFailed(store.GetValue(ref key, out value), "read device friendly name");
                try
                {
                    if (value.vt == VtLpwstr && value.pointer != IntPtr.Zero)
                    {
                        return Marshal.PtrToStringUni(value.pointer);
                    }
                    return string.Empty;
                }
                finally
                {
                    PropVariantClear(ref value);
                }
            }
            finally
            {
                Release(storeObject);
            }
        }

        private static string DescribeState(uint state)
        {
            switch (state)
            {
                case 0x1: return "active";
                case 0x2: return "disabled";
                case 0x4: return "notpresent";
                case 0x8: return "unplugged";
                default: return "unknown";
            }
        }

        private static object CreateEnumerator()
        {
            var clsid = ClsidMmDeviceEnumerator;
            var iid = IidIMMDeviceEnumerator;
            object enumerator;
            CoCreateInstance(ref clsid, null, ClsctxAll, ref iid, out enumerator);
            return enumerator;
        }

        /// <summary>
        /// Plays a 16-bit PCM WAV file into one specific render endpoint in
        /// shared mode, blocking until the buffer has drained. The audio engine
        /// converts the file format to the endpoint mix format.
        /// </summary>
        public static double PlayWavToDevice(string deviceId, string wavPath)
        {
            if (string.IsNullOrEmpty(deviceId))
            {
                throw new ArgumentException("A render endpoint id is required.", "deviceId");
            }
            var wav = WavPcm16.Read(wavPath);
            if (wav.DurationSeconds > MaxPlaybackSeconds)
            {
                throw new InvalidDataException(
                    "The qualification WAV is " + wav.DurationSeconds.ToString("F1") +
                    " s long; the harness accepts at most " + MaxPlaybackSeconds.ToString("F0") +
                    " s so a stalled endpoint cannot consume the whole job budget.");
            }
            object enumerator = null;
            object device = null;
            object clientObject = null;
            object renderObject = null;
            IAudioClient client = null;
            try
            {
                enumerator = CreateEnumerator();
                var enumInterface = (IMMDeviceEnumerator)enumerator;
                int hr = enumInterface.GetDevice(deviceId, out device);
                ThrowIfFailed(hr, "open render endpoint " + deviceId);
                var dev = (IMMDevice)device;
                var iid = IidAudioClient;
                ThrowIfFailed(dev.Activate(ref iid, ClsctxAll, IntPtr.Zero, out clientObject),
                    "activate render audio client");
                client = (IAudioClient)clientObject;

                IntPtr format = Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(WaveFormatEx)));
                try
                {
                    var wave = new WaveFormatEx
                    {
                        FormatTag = 1,
                        Channels = (ushort)wav.Channels,
                        SamplesPerSec = (uint)wav.SampleRate,
                        AvgBytesPerSec = (uint)(wav.SampleRate * wav.Channels * 2),
                        BlockAlign = (ushort)(wav.Channels * 2),
                        BitsPerSample = 16,
                        ExtraSize = 0,
                    };
                    Marshal.StructureToPtr(wave, format, false);
                    const long bufferDurationHns = 200 * 10000;
                    ThrowIfFailed(client.Initialize(ShareModeShared,
                            StreamFlagAutoConvertPcm | StreamFlagSrcDefaultQuality,
                            bufferDurationHns, 0, format, IntPtr.Zero),
                        "initialize render audio client");
                    uint bufferFrames;
                    ThrowIfFailed(client.GetBufferSize(out bufferFrames), "read render buffer size");
                    var renderIid = IidAudioRenderClient;
                    ThrowIfFailed(client.GetService(ref renderIid, out renderObject),
                        "get render client service");
                    var render = (IAudioRenderClient)renderObject;
                    ThrowIfFailed(client.Start(), "start render audio client");
                    try
                    {
                        int bytesPerFrame = wav.Channels * 2;
                        int offset = 0;
                        // Bound the whole render loop, including repeated
                        // full-buffer polls, so a stalled endpoint cannot keep
                        // the run alive until the job times out. The budget is
                        // generous for the file plus engine latency.
                        var playback = Stopwatch.StartNew();
                        long playbackBudgetMilliseconds =
                            (long)Math.Ceiling((wav.DurationSeconds + PlaybackGraceSeconds) * 1000.0);
                        while (offset < wav.Data.Length)
                        {
                            if (playback.ElapsedMilliseconds > playbackBudgetMilliseconds)
                            {
                                throw new TimeoutException(
                                    "WAV playback exceeded " + playbackBudgetMilliseconds +
                                    " ms after rendering " + offset + " of " + wav.Data.Length + " bytes.");
                            }
                            uint padding;
                            ThrowIfFailed(client.GetCurrentPadding(out padding), "read render padding");
                            uint available = bufferFrames - padding;
                            if (available == 0)
                            {
                                Thread.Sleep(5);
                                continue;
                            }
                            int frames = Math.Min((int)available, (wav.Data.Length - offset) / bytesPerFrame);
                            if (frames <= 0)
                            {
                                break;
                            }
                            IntPtr buffer;
                            ThrowIfFailed(render.GetBuffer((uint)frames, out buffer), "get render buffer");
                            Marshal.Copy(wav.Data, offset, buffer, frames * bytesPerFrame);
                            ThrowIfFailed(render.ReleaseBuffer((uint)frames, 0), "release render buffer");
                            offset += frames * bytesPerFrame;
                            int pacing = (int)Math.Max(5, frames * 1000.0 / wav.SampleRate / 2.0);
                            Thread.Sleep(pacing);
                        }
                        Thread.Sleep((int)(bufferFrames * 1000.0 / wav.SampleRate) + 150);
                    }
                    finally
                    {
                        try { client.Stop(); } catch { }
                    }
                }
                finally
                {
                    Marshal.FreeCoTaskMem(format);
                }
            }
            finally
            {
                Release(renderObject);
                Release(clientObject);
                Release(device);
                Release(enumerator);
            }
            return wav.DurationSeconds;
        }

        // ---------------------------------------------------------------
        // Keyboard input (real system events through the low-level hook)
        // ---------------------------------------------------------------

        public static void SendAltTap()
        {
            SendKey(VkLMenu, false);
            SendKey(VkLMenu, true);
        }

        public static void SendDoubleAlt(int gapMilliseconds)
        {
            SendAltTap();
            if (gapMilliseconds > 0)
            {
                Thread.Sleep(gapMilliseconds);
            }
            SendAltTap();
        }

        public static void SendReturnKey()
        {
            SendKey(VkReturn, false);
            SendKey(VkReturn, true);
        }

        public static void SendEscapeKey()
        {
            SendKey(VkEscape, false);
            SendKey(VkEscape, true);
        }

        public static void SendControlShortcut(int virtualKey)
        {
            SendKey(VkControl, false);
            SendKey(virtualKey, false);
            SendKey(virtualKey, true);
            SendKey(VkControl, true);
        }

        private static void SendKey(int virtualKey, bool keyUp)
        {
            int inputSize = Marshal.SizeOf(typeof(Input));
            int expectedSize = IntPtr.Size == 8 ? 40 : 28;
            if (inputSize != expectedSize)
            {
                throw new InvalidOperationException(
                    "INPUT marshals to " + inputSize + " bytes; SendInput requires " + expectedSize + ".");
            }
            var input = new Input
            {
                type = InputKeyboard,
                union = new InputUnion
                {
                    keyboard = new KeyboardInput
                    {
                        virtualKey = (ushort)virtualKey,
                        scanCode = 0,
                        flags = keyUp ? KeyboardEventKeyUp : 0,
                        time = 0,
                        extraInfo = IntPtr.Zero,
                    },
                },
            };
            uint sent = SendInput(1, new[] { input }, Marshal.SizeOf(typeof(Input)));
            if (sent != 1)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SendInput delivered no keyboard event");
            }
            // The product's hook swallows Return while recording; a short pause
            // keeps the injected sequence ordered and avoids autorepeat logic.
            Thread.Sleep(15);
        }

        // ---------------------------------------------------------------
        // Windows / focus / text
        // ---------------------------------------------------------------

        public static WindowProbe FindWindowByTitle(string exactTitle)
        {
            IntPtr match = IntPtr.Zero;
            EnumWindows(delegate(IntPtr handle, IntPtr parameter)
            {
                if (!IsWindowVisible(handle))
                {
                    return true;
                }
                string title = ReadWindowText(handle);
                if (string.Equals(title, exactTitle, StringComparison.Ordinal))
                {
                    match = handle;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return match == IntPtr.Zero ? null : DescribeWindow(match);
        }

        public static WindowProbe FindWindowByTitlePattern(string pattern)
        {
            IntPtr match = IntPtr.Zero;
            var expression = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            EnumWindows(delegate(IntPtr handle, IntPtr parameter)
            {
                if (!IsWindowVisible(handle))
                {
                    return true;
                }
                string title = ReadWindowText(handle);
                if (!string.IsNullOrEmpty(title) && expression.IsMatch(title))
                {
                    match = handle;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return match == IntPtr.Zero ? null : DescribeWindow(match);
        }

        public static WindowProbe GetForegroundWindowInfo()
        {
            IntPtr handle = GetForegroundWindow();
            return handle == IntPtr.Zero ? null : DescribeWindow(handle);
        }

        public static WindowProbe DescribeWindow(long handle)
        {
            return DescribeWindow(new IntPtr(handle));
        }

        private static WindowProbe DescribeWindow(IntPtr handle)
        {
            if (handle == IntPtr.Zero || !IsWindow(handle))
            {
                return null;
            }
            var info = new WindowProbe { Handle = handle.ToInt64() };
            info.Title = ReadWindowText(handle);
            info.ClassName = ReadClassName(handle);
            info.Visible = IsWindowVisible(handle);
            uint processId;
            GetWindowThreadProcessId(handle, out processId);
            info.ProcessId = (int)processId;
            Rect rect;
            if (GetWindowRect(handle, out rect))
            {
                info.Left = rect.Left;
                info.Top = rect.Top;
                info.Width = rect.Right - rect.Left;
                info.Height = rect.Bottom - rect.Top;
            }
            return info;
        }

        public static WindowProbe[] FindProcessWindows(int processId)
        {
            var results = new List<WindowProbe>();
            EnumWindows(delegate(IntPtr handle, IntPtr parameter)
            {
                uint owner;
                GetWindowThreadProcessId(handle, out owner);
                if ((int)owner == processId && IsWindowVisible(handle))
                {
                    results.Add(DescribeWindow(handle));
                }
                return true;
            }, IntPtr.Zero);
            return results.ToArray();
        }

        public static bool FocusWindow(long handle, int timeoutMilliseconds)
        {
            IntPtr target = new IntPtr(handle);
            if (!IsWindow(target))
            {
                return false;
            }
            ShowWindow(target, SwRestore);
            var deadline = Environment.TickCount + Math.Max(1, timeoutMilliseconds);
            while (Environment.TickCount < deadline)
            {
                if (SetForegroundWindow(target))
                {
                    Thread.Sleep(50);
                    if (GetForegroundWindow() == target)
                    {
                        return true;
                    }
                }
                // The foreground lock can reject a focus change; temporarily
                // joining the target's input queue is the documented mitigation.
                uint targetThread = GetWindowThreadProcessId(target, IntPtr.Zero);
                uint currentThread = GetCurrentThreadId();
                if (targetThread != 0 && targetThread != currentThread)
                {
                    if (AttachThreadInput(currentThread, targetThread, true))
                    {
                        try
                        {
                            BringWindowToTop(target);
                            SetForegroundWindow(target);
                            SetFocus(target);
                        }
                        finally
                        {
                            AttachThreadInput(currentThread, targetThread, false);
                        }
                        Thread.Sleep(50);
                        if (GetForegroundWindow() == target)
                        {
                            return true;
                        }
                    }
                }
                Thread.Sleep(100);
            }
            return GetForegroundWindow() == target;
        }

        public static bool WaitForInputIdle(int processId, int timeoutMilliseconds)
        {
            IntPtr handle = OpenProcess(Synchronize, false, processId);
            if (handle == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                return WaitForInputIdleNative(handle, (uint)Math.Max(1, timeoutMilliseconds)) == 0;
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        /// <summary>Returns the text of the first classic Edit/RichEdit child, or null.</summary>
        public static string GetChildEditText(long handle)
        {
            string found = null;
            EnumChildWindows(new IntPtr(handle), delegate(IntPtr child, IntPtr parameter)
            {
                string className = ReadClassName(child);
                if (className == "Edit" || className == "RichEdit20W" || className == "RichEditD2DPT")
                {
                    // GetWindowText cannot read another process's edit text;
                    // WM_GETTEXT is the cross-process path for classic controls.
                    string text = ReadControlText(child);
                    if (text != null)
                    {
                        found = text;
                        return false;
                    }
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        public static string ReadWindowText(long handle)
        {
            return ReadWindowText(new IntPtr(handle));
        }

        private static string ReadWindowText(IntPtr handle)
        {
            int length = GetWindowTextLength(handle);
            var builder = new StringBuilder(Math.Max(length + 1, 2));
            GetWindowText(handle, builder, builder.Capacity);
            return builder.ToString();
        }

        /// <summary>
        /// Reads classic control text across process boundaries with a bounded
        /// WM_GETTEXT. A plain SendMessage can wait forever on a hung owner.
        /// </summary>
        private static string ReadControlText(IntPtr handle)
        {
            var builder = new StringBuilder(ControlTextMaximum);
            IntPtr result;
            IntPtr copied = SendMessageTimeout(handle, WmGetText, new IntPtr(ControlTextMaximum),
                builder, SmtoAbortIfHung, ControlTextTimeoutMilliseconds, out result);
            if (copied == IntPtr.Zero)
            {
                return null;
            }
            return builder.ToString();
        }

        private static string ReadClassName(IntPtr handle)
        {
            var builder = new StringBuilder(256);
            GetClassName(handle, builder, builder.Capacity);
            return builder.ToString();
        }

        // ---------------------------------------------------------------
        // Screenshots (BMP, no System.Drawing dependency)
        // ---------------------------------------------------------------

        public static ScreenCaptureResult SaveWindowScreenshot(long handle, string path)
        {
            IntPtr window = new IntPtr(handle);
            if (!IsWindow(window))
            {
                return new ScreenCaptureResult { Saved = false, Path = path };
            }
            var probe = DescribeWindow(window);
            if (probe.Width <= 0 || probe.Height <= 0)
            {
                return new ScreenCaptureResult { Saved = false, Path = path };
            }

            // PrintWindow waits synchronously for the window owner to render.
            // A hung owner must not block the harness before playback or the
            // evidence writer runs, so capture it on a bounded worker and fall
            // back to a screen-region copy that is reported as such.
            byte[] printed = TryPrintWindowPixels(window, probe.Width, probe.Height,
                PrintWindowTimeoutMilliseconds);
            if (printed != null)
            {
                int printedNonBlank = CountNonBlankPixels(printed);
                if (printedNonBlank > 0)
                {
                    WriteBmp(path, printed, probe.Width, probe.Height);
                    return new ScreenCaptureResult
                    {
                        Saved = true,
                        Path = path,
                        Method = "printwindow",
                        WindowEvidence = true,
                        Width = probe.Width,
                        Height = probe.Height,
                        NonBlankPixels = printedNonBlank,
                    };
                }
            }

            return CaptureRegion(path, probe.Width, probe.Height,
                delegate(IntPtr memoryDc, IntPtr bits)
                {
                    IntPtr screen = GetDC(IntPtr.Zero);
                    bool copied;
                    try
                    {
                        copied = BitBlt(memoryDc, 0, 0, probe.Width, probe.Height, screen,
                            probe.Left, probe.Top, SrcCopy);
                    }
                    finally
                    {
                        ReleaseDC(IntPtr.Zero, screen);
                    }
                    if (!copied)
                    {
                        return new CaptureOutcome
                        {
                            Method = "screen-region-unavailable",
                            Failed = true,
                        };
                    }
                    // A screen-region copy can include whatever window covers
                    // the HUD, so it is not proof of the window's content.
                    return new CaptureOutcome { Method = "screen-region" };
                });
        }

        public static ScreenCaptureResult SaveDesktopScreenshot(string path)
        {
            int width = GetSystemMetrics(SmCxScreen);
            int height = GetSystemMetrics(SmCyScreen);
            if (width <= 0 || height <= 0)
            {
                return new ScreenCaptureResult { Saved = false, Path = path };
            }
            return CaptureRegion(path, width, height, delegate(IntPtr memoryDc, IntPtr bits)
            {
                IntPtr screen = GetDC(IntPtr.Zero);
                bool copied;
                try
                {
                    copied = BitBlt(memoryDc, 0, 0, width, height, screen, 0, 0, SrcCopy);
                }
                finally
                {
                    ReleaseDC(IntPtr.Zero, screen);
                }
                if (!copied)
                {
                    return new CaptureOutcome
                    {
                        Method = "desktop-unavailable",
                        Failed = true,
                    };
                }
                return new CaptureOutcome { Method = "desktop" };
            });
        }

        private sealed class CaptureOutcome
        {
            public string Method;
            public bool Failed;
        }

        private delegate CaptureOutcome CapturePainter(IntPtr memoryDc, IntPtr bits);

        private static byte[] TryPrintWindowPixels(IntPtr window, int width, int height,
            int timeoutMilliseconds)
        {
            byte[] pixels = null;
            var worker = new Thread(delegate()
            {
                IntPtr screen = IntPtr.Zero;
                IntPtr memory = IntPtr.Zero;
                IntPtr dib = IntPtr.Zero;
                IntPtr previous = IntPtr.Zero;
                try
                {
                    screen = GetDC(IntPtr.Zero);
                    memory = CreateCompatibleDC(screen);
                    var info = CreateBitmapInfo(width, height);
                    IntPtr bits;
                    dib = CreateDIBSection(screen, ref info, 0, out bits, IntPtr.Zero, 0);
                    if (dib == IntPtr.Zero)
                    {
                        return;
                    }
                    previous = SelectObject(memory, dib);
                    if (!PrintWindow(window, memory, PwRenderFullContent))
                    {
                        return;
                    }
                    int stride = width * 4;
                    var buffer = new byte[stride * height];
                    Marshal.Copy(bits, buffer, 0, buffer.Length);
                    pixels = buffer;
                }
                catch
                {
                    pixels = null;
                }
                finally
                {
                    if (previous != IntPtr.Zero)
                    {
                        SelectObject(memory, previous);
                    }
                    if (dib != IntPtr.Zero)
                    {
                        DeleteObject(dib);
                    }
                    if (memory != IntPtr.Zero)
                    {
                        DeleteDC(memory);
                    }
                    if (screen != IntPtr.Zero)
                    {
                        ReleaseDC(IntPtr.Zero, screen);
                    }
                }
            });
            worker.IsBackground = true;
            worker.Start();
            if (!worker.Join(Math.Max(1, timeoutMilliseconds)))
            {
                // Abandon the stalled worker: it owns a private DIB that is
                // never reused, and a background thread cannot keep the
                // process alive after the harness finishes.
                return null;
            }
            return pixels;
        }

        private static BitmapInfo CreateBitmapInfo(int width, int height)
        {
            var info = new BitmapInfo();
            info.headerSize = 40;
            info.width = width;
            info.height = -height; // top-down
            info.planes = 1;
            info.bitCount = 32;
            info.compression = 0;
            return info;
        }

        private static ScreenCaptureResult CaptureRegion(string path, int width, int height, CapturePainter paint)
        {
            IntPtr screen = GetDC(IntPtr.Zero);
            IntPtr memory = IntPtr.Zero;
            IntPtr dib = IntPtr.Zero;
            IntPtr previous = IntPtr.Zero;
            try
            {
                memory = CreateCompatibleDC(screen);
                var info = CreateBitmapInfo(width, height);
                IntPtr bits;
                dib = CreateDIBSection(screen, ref info, 0, out bits, IntPtr.Zero, 0);
                if (dib == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDIBSection failed");
                }
                previous = SelectObject(memory, dib);
                var outcome = paint(memory, bits);
                if (outcome.Failed)
                {
                    return new ScreenCaptureResult
                    {
                        Saved = false,
                        Path = path,
                        Method = outcome.Method,
                        Width = width,
                        Height = height,
                    };
                }
                int nonBlank = CountNonBlankPixels(bits, width, height);
                WriteBmp(path, bits, width, height);
                return new ScreenCaptureResult
                {
                    Saved = true,
                    Path = path,
                    Method = outcome.Method,
                    Width = width,
                    Height = height,
                    NonBlankPixels = nonBlank,
                };
            }
            finally
            {
                if (previous != IntPtr.Zero)
                {
                    SelectObject(memory, previous);
                }
                if (dib != IntPtr.Zero)
                {
                    DeleteObject(dib);
                }
                if (memory != IntPtr.Zero)
                {
                    DeleteDC(memory);
                }
                ReleaseDC(IntPtr.Zero, screen);
            }
        }

        private static int CountNonBlankPixels(IntPtr bits, int width, int height)
        {
            int stride = width * 4;
            var pixels = new byte[stride * height];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            return CountNonBlankPixels(pixels);
        }

        private static int CountNonBlankPixels(byte[] pixels)
        {
            int nonBlank = 0;
            for (int offset = 0; offset + 2 < pixels.Length; offset += 4)
            {
                if ((pixels[offset] | pixels[offset + 1] | pixels[offset + 2]) != 0)
                {
                    nonBlank++;
                }
            }
            return nonBlank;
        }

        private static void WriteBmp(string path, IntPtr bits, int width, int height)
        {
            int stride = width * 4;
            int pixelBytes = stride * height;
            var pixels = new byte[pixelBytes];
            Marshal.Copy(bits, pixels, 0, pixelBytes);
            WriteBmp(path, pixels, width, height);
        }

        private static void WriteBmp(string path, byte[] pixels, int width, int height)
        {
            int stride = width * 4;
            int pixelBytes = stride * height;
            var directory = System.IO.Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            using (var stream = new FileStream(path, FileMode.Create, FileAccess.Write))
            using (var writer = new BinaryWriter(stream))
            {
                int fileSize = 14 + 40 + pixelBytes;
                writer.Write((byte)'B');
                writer.Write((byte)'M');
                writer.Write(fileSize);
                writer.Write(0);
                writer.Write(14 + 40);
                writer.Write(40);
                writer.Write(width);
                writer.Write(height);
                writer.Write((ushort)1);
                writer.Write((ushort)32);
                writer.Write(0);
                writer.Write(pixelBytes);
                writer.Write(2835);
                writer.Write(2835);
                writer.Write(0);
                writer.Write(0);
                // BMP rows are bottom-up; the DIB is top-down.
                for (int row = height - 1; row >= 0; row--)
                {
                    writer.Write(pixels, row * stride, stride);
                }
            }
        }

        // ---------------------------------------------------------------
        // P/Invoke and COM declarations
        // ---------------------------------------------------------------

        private const int VkLMenu = 0xA4;
        private const int VkReturn = 0x0D;
        private const int VkEscape = 0x1B;
        private const int VkControl = 0x11;
        private const uint InputKeyboard = 1;
        private const uint KeyboardEventKeyUp = 0x0002;
        private const uint ShareModeShared = 0;
        private const uint StreamFlagAutoConvertPcm = 0x80000000;
        private const uint StreamFlagSrcDefaultQuality = 0x10000000;
        private const uint StateAll = 0xF;
        private const int ElementNotFound = unchecked((int)0x80070490);
        private const uint ClsctxAll = 0x17;
        private const uint DesktopReadObjects = 0x0001;
        private const uint UoiName = 2;
        private const int SwRestore = 9;
        private const uint PwRenderFullContent = 2;
        private const uint WmGetText = 0x000D;
        private const uint SmtoAbortIfHung = 0x0002;
        private const int ControlTextMaximum = 4096;
        private const int ControlTextTimeoutMilliseconds = 1000;
        private const int PrintWindowTimeoutMilliseconds = 2000;
        // A qualification phrase is short. Rejecting longer input keeps a
        // stalled endpoint from consuming the whole job budget.
        private const double MaxPlaybackSeconds = 30.0;
        private const double PlaybackGraceSeconds = 10.0;
        private const int SrcCopy = 0x00CC0020;
        private const int SmCxScreen = 0;
        private const int SmCyScreen = 1;
        private const uint Synchronize = 0x00100000;
        private const ushort VtLpwstr = 31;

        private static readonly Guid ClsidMmDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        private static readonly Guid IidIMMDeviceEnumerator = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
        private static readonly Guid IidAudioClient = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        private static readonly Guid IidIAudioClient = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        private static readonly Guid IidAudioRenderClient = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
        private static readonly PropertyKey PropertyKeyFriendlyName = new PropertyKey
        {
            formatId = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
            propertyId = 14,
        };

        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid formatId;
            public int propertyId;
        }

        // PROPVARIANT is 24 bytes on x64 (vt at 0, padding, 16-byte union at
        // offset 8). Declaring only IntPtr would marshal 16 bytes and let
        // IPropertyStore.GetValue overwrite the stack. Size = 24 is also a
        // safe superset of the 16-byte x86 layout.
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropVariant
        {
            [FieldOffset(0)]
            public ushort vt;
            [FieldOffset(8)]
            public IntPtr pointer;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 2)]
        private struct WaveFormatEx
        {
            public ushort FormatTag;
            public ushort Channels;
            public uint SamplesPerSec;
            public uint AvgBytesPerSec;
            public ushort BlockAlign;
            public ushort BitsPerSample;
            public ushort ExtraSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BitmapInfo
        {
            public int headerSize;
            public int width;
            public int height;
            public ushort planes;
            public ushort bitCount;
            public int compression;
            public int sizeImage;
            public int xPelsPerMeter;
            public int yPelsPerMeter;
            public int colorsUsed;
            public int colorsImportant;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardInput
        {
            public ushort virtualKey;
            public ushort scanCode;
            public uint flags;
            public uint time;
            public IntPtr extraInfo;
        }

        // MOUSEINPUT is not used, but it defines the x64 union size (32 bytes).
        // Without it Marshal.SizeOf(Input) would be 32 instead of the 40 bytes
        // SendInput requires on x64 and every injection would fail.
        [StructLayout(LayoutKind.Sequential)]
        private struct MouseInput
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr extraInfo;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)]
            public MouseInput mouse;
            [FieldOffset(0)]
            public KeyboardInput keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Input
        {
            public uint type;
            public InputUnion union;
        }

        private enum DataFlow : uint
        {
            Render = 0,
            Capture = 1,
            All = 2,
        }

        private enum Role : uint
        {
            Console = 0,
            Multimedia = 1,
            Communications = 2,
        }

        private static DataFlow ParseFlow(string flow)
        {
            switch ((flow ?? "capture").ToLowerInvariant())
            {
                case "render": return DataFlow.Render;
                case "capture": return DataFlow.Capture;
                case "all": return DataFlow.All;
                default: throw new ArgumentException("Unknown data flow: " + flow, "flow");
            }
        }

        private static Role ParseRole(string role)
        {
            switch ((role ?? "console").ToLowerInvariant())
            {
                case "console": return Role.Console;
                case "multimedia": return Role.Multimedia;
                case "communications": return Role.Communications;
                default: throw new ArgumentException("Unknown role: " + role, "role");
            }
        }

        [ComImport]
        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            [PreserveSig]
            int EnumAudioEndpoints(DataFlow dataFlow, uint stateMask,
                [MarshalAs(UnmanagedType.Interface)] out object devices);

            [PreserveSig]
            int GetDefaultAudioEndpoint(DataFlow dataFlow, Role role,
                [MarshalAs(UnmanagedType.Interface)] out object device);

            [PreserveSig]
            int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id,
                [MarshalAs(UnmanagedType.Interface)] out object device);

            [PreserveSig]
            int RegisterEndpointNotificationCallback(IntPtr client);

            [PreserveSig]
            int UnregisterEndpointNotificationCallback(IntPtr client);
        }

        [ComImport]
        [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceCollection
        {
            [PreserveSig]
            int GetCount(out uint count);

            [PreserveSig]
            int Item(uint index, [MarshalAs(UnmanagedType.Interface)] out object device);
        }

        [ComImport]
        [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            [PreserveSig]
            int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams,
                [MarshalAs(UnmanagedType.IUnknown)] out object instance);

            [PreserveSig]
            int OpenPropertyStore(uint access,
                [MarshalAs(UnmanagedType.Interface)] out object properties);

            [PreserveSig]
            int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

            [PreserveSig]
            int GetState(out uint state);
        }

        [ComImport]
        [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig]
            int GetCount(out uint propertyCount);

            [PreserveSig]
            int GetAt(uint propertyIndex, out PropertyKey key);

            [PreserveSig]
            int GetValue(ref PropertyKey key, out PropVariant value);

            [PreserveSig]
            int SetValue(ref PropertyKey key, ref PropVariant value);

            [PreserveSig]
            int Commit();
        }

        [ComImport]
        [Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioClient
        {
            [PreserveSig]
            int Initialize(uint shareMode, uint streamFlags, long bufferDurationHns,
                long periodicityHns, IntPtr format, IntPtr audioSessionGuid);

            [PreserveSig]
            int GetBufferSize(out uint numBufferFrames);

            [PreserveSig]
            int GetStreamLatency(out long latencyHns);

            [PreserveSig]
            int GetCurrentPadding(out uint numPaddingFrames);

            [PreserveSig]
            int IsFormatSupported(uint shareMode, IntPtr format, out IntPtr closestMatch);

            [PreserveSig]
            int GetMixFormat(out IntPtr deviceFormat);

            [PreserveSig]
            int GetDevicePeriod(out long defaultPeriodHns, out long minimumPeriodHns);

            [PreserveSig]
            int Start();

            [PreserveSig]
            int Stop();

            [PreserveSig]
            int Reset();

            [PreserveSig]
            int SetEventHandle(IntPtr eventHandle);

            [PreserveSig]
            int GetService(ref Guid interfaceId,
                [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        }

        [ComImport]
        [Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioRenderClient
        {
            [PreserveSig]
            int GetBuffer(uint numFramesRequested, out IntPtr data);

            [PreserveSig]
            int ReleaseBuffer(uint numFramesWritten, uint flags);
        }

        private sealed class WavPcm16
        {
            public int Channels;
            public int SampleRate;
            public byte[] Data;
            public double DurationSeconds;

            public static WavPcm16 Read(string path)
            {
                byte[] bytes = File.ReadAllBytes(path);
                if (bytes.Length < 44 || Encoding.ASCII.GetString(bytes, 0, 4) != "RIFF" ||
                    Encoding.ASCII.GetString(bytes, 8, 4) != "WAVE")
                {
                    throw new InvalidDataException("Not a RIFF/WAVE file: " + path);
                }
                int offset = 12;
                int channels = 0;
                int sampleRate = 0;
                int bits = 0;
                int format = 0;
                int dataOffset = -1;
                int dataLength = 0;
                while (offset + 8 <= bytes.Length)
                {
                    string chunk = Encoding.ASCII.GetString(bytes, offset, 4);
                    int size = BitConverter.ToInt32(bytes, offset + 4);
                    if (size < 0 || offset + 8 + size > bytes.Length)
                    {
                        break;
                    }
                    if (chunk == "fmt " && size >= 16)
                    {
                        format = BitConverter.ToInt16(bytes, offset + 8);
                        channels = BitConverter.ToInt16(bytes, offset + 10);
                        sampleRate = BitConverter.ToInt32(bytes, offset + 12);
                        bits = BitConverter.ToInt16(bytes, offset + 22);
                    }
                    else if (chunk == "data")
                    {
                        dataOffset = offset + 8;
                        dataLength = size;
                    }
                    offset += 8 + size + (size % 2);
                }
                if (format != 1 || bits != 16 || channels <= 0 || sampleRate <= 0 || dataOffset < 0)
                {
                    throw new InvalidDataException(
                        "The qualification requires 16-bit PCM WAV input; got format=" + format +
                        " bits=" + bits + " channels=" + channels + " rate=" + sampleRate);
                }
                int bytesPerFrame = channels * 2;
                if (dataLength <= 0 || dataLength % bytesPerFrame != 0)
                {
                    // An empty or partial data chunk would let playback return
                    // without writing a complete frame while the harness
                    // reported the spoken-audio step as passed.
                    throw new InvalidDataException(
                        "The qualification WAV has no complete 16-bit PCM frames; got " +
                        dataLength + " data bytes for " + bytesPerFrame + " bytes per frame.");
                }
                var data = new byte[dataLength];
                Array.Copy(bytes, dataOffset, data, 0, dataLength);
                return new WavPcm16
                {
                    Channels = channels,
                    SampleRate = sampleRate,
                    Data = data,
                    DurationSeconds = dataLength / (double)(sampleRate * channels * 2),
                };
            }
        }

        private static void ThrowIfFailed(int hr, string operation)
        {
            if (hr < 0)
            {
                throw new COMException("WASAPI " + operation + " failed", hr);
            }
        }

        private static void Release(object instance)
        {
            if (instance != null && Marshal.IsComObject(instance))
            {
                Marshal.ReleaseComObject(instance);
            }
        }

        private delegate bool EnumWindowsProc(IntPtr handle, IntPtr parameter);

        [DllImport("ole32.dll", PreserveSig = false)]
        private static extern void CoCreateInstance(ref Guid clsid,
            [MarshalAs(UnmanagedType.IUnknown)] object aggregate, uint clsContext,
            ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object instance);

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, Input[] inputs, int size);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr handle);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr handle, StringBuilder text, int maximum);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr handle);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
        private static extern IntPtr SendMessageTimeout(IntPtr handle, uint message, IntPtr wParam,
            StringBuilder lParam, uint flags, uint timeout, out IntPtr result);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr handle, StringBuilder name, int maximum);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr handle, IntPtr processId);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr handle, out Rect rect);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern bool BringWindowToTop(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern IntPtr SetFocus(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern bool AttachThreadInput(uint attach, uint attachTo, bool attachFlag);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr handle, int command);

        [DllImport("user32.dll")]
        private static extern bool PrintWindow(IntPtr handle, IntPtr deviceContext, uint flags);

        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr handle);

        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr handle, IntPtr deviceContext);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int index);

        [DllImport("user32.dll")]
        private static extern IntPtr GetThreadDesktop(uint threadId);

        [DllImport("user32.dll")]
        private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

        [DllImport("user32.dll")]
        private static extern bool CloseDesktop(IntPtr desktop);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool GetUserObjectInformation(IntPtr handle, uint index,
            IntPtr information, uint length, out uint needed);

        [DllImport("gdi32.dll")]
        private static extern IntPtr CreateCompatibleDC(IntPtr deviceContext);

        [DllImport("gdi32.dll")]
        private static extern bool DeleteDC(IntPtr deviceContext);

        [DllImport("gdi32.dll")]
        private static extern IntPtr CreateDIBSection(IntPtr deviceContext, ref BitmapInfo info,
            uint usage, out IntPtr bits, IntPtr section, uint offset);

        [DllImport("gdi32.dll")]
        private static extern IntPtr SelectObject(IntPtr deviceContext, IntPtr handle);

        [DllImport("gdi32.dll")]
        private static extern bool DeleteObject(IntPtr handle);

        [DllImport("gdi32.dll")]
        private static extern bool BitBlt(IntPtr destination, int x, int y, int width, int height,
            IntPtr source, int sourceX, int sourceY, int operation);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentProcessId();

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("kernel32.dll")]
        private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

        [DllImport("kernel32.dll")]
        private static extern uint WTSGetActiveConsoleSessionId();

        [DllImport("kernel32.dll")]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inherit, int processId);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("user32.dll", EntryPoint = "WaitForInputIdle")]
        private static extern uint WaitForInputIdleNative(IntPtr process, uint milliseconds);
    }
}
