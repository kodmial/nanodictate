using System.Runtime.InteropServices;
using static NanoDictate.Core.WasapiInterop;

namespace NanoDictate.Core;

/// <summary>
/// Windows-native microphone capture through WASAPI shared mode.
///
/// Behavior contract (documented for operators; see windows/README.md):
/// <list type="bullet">
/// <item>Captures the default console capture endpoint in shared mode at
/// the device mix format (no exclusive mode, no format forcing).</item>
/// <item>Only Float32 mix formats are accepted; anything else fails the
/// start loudly instead of silently capturing garbage.</item>
/// <item>The first device packet is delivered to <see
/// cref="IAudioCaptureSource.BlockAvailable"/> synchronously: no warm-up
/// frames are dropped, so immediate speech survives.</item>
/// <item>A default-device change mid-capture raises <see
/// cref="IAudioCaptureSource.DeviceChanged"/>; the session must stop
/// (continuing on the old format would yield silence or desync).</item>
/// <item>Repeated start/stop is supported: every start re-resolves the
/// default device and every stop releases all COM objects.</item>
/// <item>Start failures clean up partial initialization and throw <see
/// cref="NanoException"/>; the source stays reusable for a retry.</item>
/// </list>
/// Non-Windows: <see cref="Start"/> throws <see
/// cref="PlatformNotSupportedException"/> (fail loudly, never pretend).
/// </summary>
public sealed class WasapiCaptureSource : IAudioCaptureSource
{
    private const uint ShareModeShared = 0;
    private const uint DeviceStateActive = 0x00000001;

    private readonly object _gate = new();
    private readonly DeviceChangeForwarder _notifier;
    private AudioFormat _format = AudioFormat.DefaultDevice;
    private bool _formatResolved;
    private Thread? _worker;
    private volatile bool _running;
    private bool _disposed;

    // COM objects owned by the capture thread; released on stop.
    private object? _enumerator;
    private object? _device;
    private IAudioClient? _client;
    private IAudioCaptureClient? _capture;
    // Set when Stop times out while the worker still uses the COM objects;
    // the worker releases them on exit and Start is blocked until then.
    private bool _releaseDeferred;

    public WasapiCaptureSource()
    {
        _notifier = new DeviceChangeForwarder(this);
    }

    public AudioFormat Format
    {
        get { lock (_gate) { return _format; } }
    }

    public bool IsRunning => _running;

    public event Action<CapturedBlock>? BlockAvailable;

    public event Action<Exception>? DeviceChanged;

    public void Start()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("WASAPI capture requires Windows.");
        }
        lock (_gate)
        {
            ThrowIfDisposed();
            if (_releaseDeferred)
            {
                throw new NanoException(-1, "capture worker is still stopping");
            }
            if (_running)
            {
                return;
            }
            try
            {
                OpenClientLocked();
            }
            catch
            {
                ReleaseLocked();
                throw;
            }
            _running = true;
            _worker = new Thread(CaptureLoop)
            {
                IsBackground = true,
                Name = "nanodictate-wasapi-capture",
            };
            _worker.Start();
        }
    }

    public void Stop()
    {
        Thread? worker;
        lock (_gate)
        {
            _running = false;
            worker = _worker;
            if (worker is null)
            {
                // No worker active: safe to release idempotently. A deferred
                // release without a worker means the worker already exited,
                // so complete the pending cleanup here.
                if (_releaseDeferred)
                {
                    _releaseDeferred = false;
                }
                ReleaseLocked();
                return;
            }
            // Block Start throughout the join window and retain the worker
            // reference until the worker stops using the COM objects.
            _releaseDeferred = true;
        }
        if (!ReferenceEquals(worker, Thread.CurrentThread))
        {
            worker.Join(TimeSpan.FromSeconds(5));
        }
        lock (_gate)
        {
            if (!worker.IsAlive)
            {
                // Worker terminated: this thread owns the COM cleanup. The
                // worker's finally block skips cleanup once the flag is
                // cleared, so repeated stops cannot double-release while the
                // worker is active.
                if (ReferenceEquals(_worker, worker))
                {
                    _worker = null;
                }
                _releaseDeferred = false;
                ReleaseLocked();
            }
            // Else the join timed out: keep _worker retained and
            // _releaseDeferred set so the worker releases the COM objects on
            // exit, repeated stops rejoin the same worker, and Start stays
            // blocked until cleanup completes.
        }
    }

    /// <summary>
    /// Resolves the current default capture format without starting
    /// capture. Windows-only; used for diagnostics and format logging.
    /// </summary>
    public AudioFormat ProbeDefaultFormat()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("WASAPI capture requires Windows.");
        }
        object? enumerator = null;
        object? device = null;
        IAudioClient? client = null;
        try
        {
            var clsid = ClsidMmDeviceEnumerator;
            var iid = IidIMMDeviceEnumerator;
            CoCreateInstance(ref clsid, null, ClsctxAll, ref iid, out enumerator);
            var enumIf = (IMMDeviceEnumerator)enumerator;
            ThrowOnHResult(
                enumIf.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console, out device),
                "get default capture endpoint");
            var devIf = (IMMDevice)device;
            var audioIid = IidIAudioClient;
            ThrowOnHResult(
                devIf.Activate(ref audioIid, ClsctxAll, IntPtr.Zero, out var clientObj),
                "activate audio client");
            client = (IAudioClient)clientObj;
            ThrowOnHResult(client.GetMixFormat(out var fmtPtr), "get mix format");
            try
            {
                return ReadMixFormat(fmtPtr);
            }
            finally
            {
                Marshal.FreeCoTaskMem(fmtPtr);
            }
        }
        finally
        {
            if (client is not null)
            {
                ReleaseCom(client);
            }
            if (device is not null)
            {
                ReleaseCom(device);
            }
            if (enumerator is not null)
            {
                ReleaseCom(enumerator);
            }
        }
    }

    private void OpenClientLocked()
    {
        var clsid = ClsidMmDeviceEnumerator;
        var iid = IidIMMDeviceEnumerator;
        CoCreateInstance(ref clsid, null, ClsctxAll, ref iid, out _enumerator);
        var enumIf = (IMMDeviceEnumerator)_enumerator;
        ThrowOnHResult(
            enumIf.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console, out _device),
            "get default capture endpoint");
        ThrowOnHResult(
            enumIf.RegisterEndpointNotificationCallback(_notifier),
            "register device-change notifications");

        var devIf = (IMMDevice)_device;
        var audioIid = IidIAudioClient;
        ThrowOnHResult(
            devIf.Activate(ref audioIid, ClsctxAll, IntPtr.Zero, out var clientObj),
            "activate audio client");
        _client = (IAudioClient)clientObj;

        ThrowOnHResult(_client.GetMixFormat(out var fmtPtr), "get mix format");
        try
        {
            _format = ReadMixFormat(fmtPtr);
            _formatResolved = true;
            // 100 ms shared buffer; periodicity 0 lets the engine choose.
            ThrowOnHResult(
                _client.Initialize(ShareModeShared, 0, 100_000 * 100, 0, fmtPtr, IntPtr.Zero),
                "initialize audio client");
        }
        finally
        {
            Marshal.FreeCoTaskMem(fmtPtr);
        }

        var captureIid = IidIAudioCaptureClient;
        ThrowOnHResult(
            _client.GetService(ref captureIid, out var captureObj),
            "get capture client");
        _capture = (IAudioCaptureClient)captureObj;
        ThrowOnHResult(_client.Start(), "start audio client");
    }

    private void CaptureLoop()
    {
        var client = _client;
        var capture = _capture;
        AudioFormat format;
        lock (_gate)
        {
            format = _format;
        }
        if (client is null || capture is null || !_formatResolved)
        {
            return;
        }
        try
        {
            while (_running)
            {
                int hr = capture.GetNextPacketSize(out var packetFrames);
                ThrowOnHResult(hr, "get next packet size");
                if (packetFrames == 0)
                {
                    Thread.Sleep(5);
                    continue;
                }
                hr = capture.GetBuffer(
                    out var data, out var frames, out var flags,
                    out _, out _);
                ThrowOnHResult(hr, "get capture buffer");
                try
                {
                    var count = (int)frames;
                    var interleaved = new float[count * format.Channels];
                    if ((flags & BufferFlagSilent) == 0 && data != IntPtr.Zero && count > 0)
                    {
                        Marshal.Copy(data, interleaved, 0, interleaved.Length);
                    }
                    // First packet included: synchronous delivery, no warm-up drop.
                    BlockAvailable?.Invoke(new CapturedBlock(interleaved, count, format));
                }
                finally
                {
                    capture.ReleaseBuffer(frames);
                }
            }
        }
        catch (Exception ex)
        {
            DeviceChanged?.Invoke(ex);
        }
        finally
        {
            // Complete a deferred Stop: release the COM objects the worker
            // was still using when the join timed out. The flag is set before
            // Stop waits, so a worker exit can never slip between the join
            // timeout and the deferred mark.
            lock (_gate)
            {
                if (_releaseDeferred)
                {
                    _releaseDeferred = false;
                    if (ReferenceEquals(_worker, Thread.CurrentThread))
                    {
                        _worker = null;
                    }
                    ReleaseLocked();
                }
                else if (ReferenceEquals(_worker, Thread.CurrentThread))
                {
                    // Worker exited without a stop request: drop the stale
                    // reference so a later Stop treats the source as stopped.
                    _worker = null;
                }
            }
        }
    }

    private void ReleaseLocked()
    {
        try
        {
            if (_client is not null)
            {
                try
                {
                    _client.Stop();
                }
                catch
                {
                    // Best effort: release must not throw.
                }
            }
        }
        finally
        {
            if (_enumerator is not null)
            {
                try
                {
                    ((IMMDeviceEnumerator)_enumerator).UnregisterEndpointNotificationCallback(_notifier);
                }
                catch
                {
                    // Best effort.
                }
            }
            if (_capture is not null)
            {
                ReleaseCom(_capture);
                _capture = null;
            }
            if (_client is not null)
            {
                ReleaseCom(_client);
                _client = null;
            }
            if (_device is not null)
            {
                ReleaseCom(_device);
                _device = null;
            }
            if (_enumerator is not null)
            {
                ReleaseCom(_enumerator);
                _enumerator = null;
            }
            _formatResolved = false;
        }
    }

    /// <summary>
    /// Releases one COM object. The <see cref="OperatingSystem.IsWindows"/>
    /// guard keeps the Windows-only <c>ReleaseComObject</c> unreachable on
    /// other platforms (release paths run on every OS).
    /// </summary>
    private static void ReleaseCom(object instance)
    {
        if (OperatingSystem.IsWindows())
        {
            Marshal.ReleaseComObject(instance);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(WasapiCaptureSource));
        }
    }

    public void Dispose()
    {
        Thread? worker;
        lock (_gate)
        {
            _disposed = true;
            _running = false;
            worker = _worker;
            if (worker is not null && !ReferenceEquals(worker, Thread.CurrentThread))
            {
                _releaseDeferred = true;
            }
        }
        if (worker is null)
        {
            lock (_gate)
            {
                _releaseDeferred = false;
                ReleaseLocked();
            }
            return;
        }
        if (ReferenceEquals(worker, Thread.CurrentThread))
        {
            // Reentrant dispose from the worker thread: the finally block
            // owns the deferred cleanup.
            return;
        }
        // Blocking fallback (like SyntheticCaptureSource) guarantees no
        // callback uses COM after disposal returns.
        if (!worker.Join(TimeSpan.FromSeconds(5)))
        {
            worker.Join();
        }
        lock (_gate)
        {
            if (ReferenceEquals(_worker, worker))
            {
                _worker = null;
            }
            _releaseDeferred = false;
            ReleaseLocked();
        }
    }

    /// <summary>
    /// Forwards WASAPI default-device changes to the managed event.
    /// A change of the capture console endpoint aborts the session;
    /// other flows/roles are ignored.
    /// </summary>
    private sealed class DeviceChangeForwarder : IMMNotificationClient
    {
        private readonly WasapiCaptureSource _owner;

        public DeviceChangeForwarder(WasapiCaptureSource owner) => _owner = owner;

        public void OnDeviceStateChanged(string deviceId, uint newState) { }

        public void OnDeviceAdded(string deviceId) { }

        public void OnDeviceRemoved(string deviceId) { }

        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string? defaultDeviceId)
        {
            if (flow != DataFlow.Capture || role != Role.Console)
            {
                return;
            }
            _owner.DeviceChanged?.Invoke(
                new NanoException(-1, "Windows default capture device changed"));
        }

        public void OnPropertyValueChanged(string deviceId, Guid key) { }
    }
}
