using System.Runtime.InteropServices;

namespace NanoDictate.Core;

/// <summary>
/// Minimal WASAPI COM interop for shared-mode microphone capture.
/// Windows-only: every entry point is a raw P/Invoke/COM declaration with
/// no behavior. All calls are guarded by
/// <see cref="OperatingSystem.IsWindows"/> at the call site
/// (<see cref="WasapiCaptureSource"/>); referencing this type on Linux
/// never loads a native library.
/// </summary>
internal static class WasapiInterop
{
    internal static readonly Guid ClsidMmDeviceEnumerator = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    internal static readonly Guid IidIMMDeviceEnumerator = new("A95664D2-9614-4F35-A746-DE8DB63617E6");
    internal static readonly Guid IidIAudioClient = new("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
    internal static readonly Guid IidIAudioCaptureClient = new("C8ADBD64-E71E-48A0-B833-99663978D7B0");

    internal const int ClsctxAll = 0x17;
    internal const ushort WaveFormatIeeeFloat = 3;
    internal const ushort WaveFormatExtensible = 0xFFFE;
    internal const uint BufferFlagSilent = 0x2;

    internal enum DataFlow : uint
    {
        Render = 0,
        Capture = 1,
        All = 2,
    }

    internal enum Role : uint
    {
        Console = 0,
        Multimedia = 1,
        Communications = 2,
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    internal struct WaveFormatEx
    {
        public ushort FormatTag;
        public ushort Channels;
        public uint SamplesPerSec;
        public uint AvgBytesPerSec;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort ExtraSize;
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MmDeviceEnumerator
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(
            DataFlow dataFlow, uint stateMask,
            [MarshalAs(UnmanagedType.Interface)] out object devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(
            DataFlow dataFlow, Role role,
            [MarshalAs(UnmanagedType.Interface)] out object device);

        [PreserveSig]
        int GetDevice(
            [MarshalAs(UnmanagedType.LPWStr)] string id,
            [MarshalAs(UnmanagedType.Interface)] out object device);

        [PreserveSig]
        int RegisterEndpointNotificationCallback(
            [MarshalAs(UnmanagedType.Interface)] IMMNotificationClient client);

        [PreserveSig]
        int UnregisterEndpointNotificationCallback(
            [MarshalAs(UnmanagedType.Interface)] IMMNotificationClient client);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig]
        int Activate(
            ref Guid iid, uint clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object instance);

        [PreserveSig]
        int OpenPropertyStore(uint access, [MarshalAs(UnmanagedType.Interface)] out object properties);

        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

        [PreserveSig]
        int GetState(out uint state);
    }

    [ComImport]
    [Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        [PreserveSig]
        int Initialize(
            uint shareMode, uint streamFlags,
            long bufferDurationHns, long periodicityHns,
            IntPtr format, IntPtr audioSessionGuid);

        [PreserveSig]
        int GetBufferSize(out uint numBufferFrames);

        [PreserveSig]
        int GetStreamLatency(out long latencyHns);

        [PreserveSig]
        int GetCurrentPadding(out uint numPaddingFrames);

        [PreserveSig]
        int IsFormatSupported(
            uint shareMode, IntPtr format, out IntPtr closestMatch);

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
        int GetService(
            ref Guid interfaceId,
            [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    }

    [ComImport]
    [Guid("C8ADBD64-E71E-48A0-B833-99663978D7B0")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        [PreserveSig]
        int GetBuffer(
            out IntPtr data, out uint framesToRead, out uint flags,
            out ulong devicePosition, out ulong qpcPosition);

        [PreserveSig]
        int ReleaseBuffer(uint framesRead);

        [PreserveSig]
        int GetNextPacketSize(out uint framesInNextPacket);
    }

    [ComImport]
    [Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMNotificationClient
    {
        void OnDeviceStateChanged(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceId, uint newState);

        void OnDeviceAdded(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceId);

        void OnDeviceRemoved(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceId);

        void OnDefaultDeviceChanged(
            DataFlow flow, Role role,
            [MarshalAs(UnmanagedType.LPWStr)] string? defaultDeviceId);

        void OnPropertyValueChanged(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceId, Guid key);
    }

    [DllImport("ole32.dll", PreserveSig = false)]
    internal static extern void CoCreateInstance(
        [In] ref Guid rclsid,
        [MarshalAs(UnmanagedType.IUnknown)] object? aggregate,
        uint clsContext,
        [In] ref Guid riid,
        [MarshalAs(UnmanagedType.IUnknown)] out object instance);

    internal static void ThrowOnHResult(int hr, string operation)
    {
        if (hr < 0)
        {
            throw new NanoException(hr, $"WASAPI {operation} failed (HRESULT 0x{hr:X8})");
        }
    }

    /// <summary>
    /// Reads the device mix format into an <see cref="AudioFormat"/> plus
    /// the raw channel count. Only IEEE-float formats are accepted: the
    /// pipeline normalizes Float32 frames and never reimplements a codec.
    /// </summary>
    internal static unsafe AudioFormat ReadMixFormat(IntPtr formatPtr)
    {
        if (formatPtr == IntPtr.Zero)
        {
            throw new NanoException(-1, "WASAPI returned a null mix format");
        }
        var native = Marshal.PtrToStructure<WaveFormatEx>(formatPtr);
        ushort tag = native.FormatTag;
        int channels = native.Channels;
        int rate = (int)native.SamplesPerSec;
        int bits = native.BitsPerSample;
        if (tag == WaveFormatExtensible)
        {
            // WAVEFORMATEXTENSIBLE: the real tag sits 2 bytes after the
            // 22-byte base (SubFormat GUID first field).
            var subTag = (ushort)Marshal.ReadInt16(formatPtr, 24);
            tag = subTag;
            channels = native.Channels;
        }
        if (tag != WaveFormatIeeeFloat || bits != 32)
        {
            throw new NanoException(-1, $"unsupported WASAPI mix format tag {tag} (Float32 required)");
        }
        var format = new AudioFormat(rate, channels, 32, true);
        format.Validate();
        return format;
    }
}
