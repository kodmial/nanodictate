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
    private Thread? _worker;
    private volatile bool _running;
    private bool _disposed;
    private long _discontinuityCount;

    // COM objects owned exclusively by the capture worker thread.
    // Created in CaptureLoop, released in CaptureLoop finally block.
    private object? _enumerator;
    private object? _device;
    private IAudioClient? _client;
    private IAudioCaptureClient? _capture;

    // Synchronization for Start/Stop coordination.
    private readonly ManualResetEventSlim _startedEvent = new(false);
    private readonly ManualResetEventSlim _stoppedEvent = new(false);
    private Exception? _startError;
    private bool _stopRequested;

    // Result of the last Stop/Dispose: true = clean shutdown, false = incomplete (worker timed out).
    private volatile bool _lastStopClean = true;

    // Test seam: allows injecting a custom capture loop for deterministic
    // fault injection (e.g., simulating a stalled worker). Null in production.
    // The capture loop receives the startedEvent to signal startup completion.
    private Action<ManualResetEventSlim>? _testCaptureLoopOverride;

    // Test callback to signal cleanup completion from the test capture loop.
    private Action? _testCleanupCompleteCallback;

    // Test seams for startup fault injection through the production capture
    // loop and cleanup path. Null in production.
    private readonly Action? _testStartupAcquireOverride;
    private readonly Action<object>? _testReleaseComOverride;

    // Set to true when the worker has completed cleanup (set by CaptureLoop finally
    // or by test cleanup callback). Internal for test access.
    internal bool _cleanupComplete;

    // True when constructed via the test constructor; bypasses platform check.
    private readonly bool _isTestMode;

    public WasapiCaptureSource()
    {
        _notifier = new DeviceChangeForwarder(this);
    }

    // Internal test constructor for fault injection.
    // The captureLoop receives the startedEvent to signal when startup is complete.
    // The cleanupCallback is invoked when the test capture loop completes cleanup.
    internal WasapiCaptureSource(Action<ManualResetEventSlim> testCaptureLoopOverride, Action? testCleanupCompleteCallback = null)
    {
        _notifier = new DeviceChangeForwarder(this);
        _testCaptureLoopOverride = testCaptureLoopOverride;
        _testCleanupCompleteCallback = testCleanupCompleteCallback;
        _isTestMode = true;
    }

    // Internal test constructor for startup fault injection through the
    // production CaptureLoop. The acquire action replaces WASAPI acquisition
    // and may throw after installing fake COM resources; the release override
    // stands in for Marshal.ReleaseComObject so cleanup runs with managed fakes.
    internal WasapiCaptureSource(Action testStartupAcquireOverride, Action<object>? testReleaseComOverride = null)
    {
        _notifier = new DeviceChangeForwarder(this);
        _testStartupAcquireOverride = testStartupAcquireOverride;
        _testReleaseComOverride = testReleaseComOverride;
        _isTestMode = true;
    }

    public AudioFormat Format
    {
        get { lock (_gate) { return _format; } }
    }

    public bool IsRunning => _running;

    /// <summary>
    /// Number of capture packets flagged with
    /// <c>AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY</c> in the current session.
    /// The WASAPI engine sets the flag when capture data was dropped before
    /// the packet; the counter makes the glitch visible for dropped-audio
    /// measurement. Reset on every <see cref="Start"/>.
    /// </summary>
    public long DiscontinuityCount => Interlocked.Read(ref _discontinuityCount);

    /// <summary>
    /// Returns true if the last Stop or Dispose completed a clean shutdown
    /// (WASAPI client stopped and all COM objects released). False indicates
    /// the worker did not exit within the bounded wait; the OS stream may
    /// still be active and COM objects unreleased. While the previous capture
    /// worker is still alive, <see cref="Start"/> throws <see
    /// cref="NanoException"/>; once that worker exits, a later <see
    /// cref="Start"/> can be retried.
    /// </summary>
    public bool LastStopClean => _lastStopClean;

    public event Action<CapturedBlock>? BlockAvailable;

    public event Action<Exception>? DeviceChanged;

    public void Start()
    {
        if (!_isTestMode && !OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("WASAPI capture requires Windows.");
        }
        lock (_gate)
        {
            ThrowIfDisposed();
            if (_running)
            {
                return;
            }
            if (_worker is not null && _worker.IsAlive)
            {
                throw new NanoException(-1, "capture worker is still stopping");
            }
            _running = true;
            _stopRequested = false;
            _cleanupComplete = false;
            _startError = null;
            _startedEvent.Reset();
            _stoppedEvent.Reset();
            _worker = new Thread(_testCaptureLoopOverride is not null
                ? () =>
                {
                    try
                    {
                        _testCaptureLoopOverride!(_startedEvent);
                    }
                    catch (Exception ex)
                    {
                        CleanupFailedStartup(ex);
                        _startedEvent.Set();
                    }
                    finally
                    {
                        _testCleanupCompleteCallback?.Invoke();
                    }
                }
                : CaptureLoop)
            {
                IsBackground = true,
                Name = "nanodictate-wasapi-capture",
            };
            _worker.Start();
        }

        // Wait for worker to signal startup completion or failure.
        // This preserves synchronous start failure reporting.
        if (!_startedEvent.Wait(TimeSpan.FromSeconds(10)))
        {
            // Startup timed out - request stop and wait for cleanup.
            Thread? worker;
            lock (_gate)
            {
                _stopRequested = true;
                _running = false;
                worker = _worker;
            }
            var joined = worker?.Join(TimeSpan.FromSeconds(5)) ?? true;
            lock (_gate)
            {
                _lastStopClean = joined && _cleanupComplete;
                if (joined)
                {
                    _worker = null;
                    _stopRequested = false;
                }
            }
            throw new NanoException(-1, "WASAPI capture startup timed out");
        }

        lock (_gate)
        {
            if (_startError is not null)
            {
                _running = false;
                var error = _startError;
                _startError = null;
                throw error;
            }
        }
    }

    public void Stop()
    {
        bool cleanShutdown;
        lock (_gate)
        {
            if (!_running && _worker is null)
            {
                _lastStopClean = true;
                return;
            }
            _stopRequested = true;
            _running = false;
        }

        // Bounded wait for worker to exit and release COM objects.
        Thread? worker;
        lock (_gate)
        {
            worker = _worker;
            if (worker is not null && ReferenceEquals(worker, Thread.CurrentThread))
            {
                // Keep _stopRequested set so the packet loop exits through its
                // finally block. The CaptureLoop device-error callback runs
                // after cleanup and can clear the reference.
                if (_cleanupComplete)
                {
                    _worker = null;
                    _stopRequested = false;
                    _lastStopClean = true;
                }
                else
                {
                    _lastStopClean = false;
                }
                return;
            }
        }
        cleanShutdown = worker is null || worker.Join(TimeSpan.FromSeconds(5));

        lock (_gate)
        {
            _lastStopClean = cleanShutdown && _cleanupComplete;
            if (cleanShutdown)
            {
                _worker = null;
                _stopRequested = false;
            }
            // If not clean, _worker remains set and _stopRequested stays true,
            // blocking a new Start until the worker finally exits.
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

    private void CaptureLoop()
    {
        Exception? deviceError = null;
        bool startSucceeded = false;
        AudioFormat format = AudioFormat.DefaultDevice;

        try
        {
            // All COM acquisition happens on this worker thread.
            OpenClientOnWorkerThread();

            lock (_gate)
            {
                format = _format;
                startSucceeded = true;
            }
        }
        catch (Exception ex)
        {
            CleanupFailedStartup(ex);
        }
        finally
        {
            _startedEvent.Set();
        }

        if (!startSucceeded)
        {
            return;
        }

        try
        {
            if (_client is null || _capture is null)
            {
                return;
            }

            var interleavedScratch = new float[4800 * Math.Max(1, format.Channels)];
            while (true)
            {
                bool shouldStop;
                lock (_gate)
                {
                    shouldStop = _stopRequested;
                }
                if (shouldStop)
                {
                    break;
                }

                int hr = _capture.GetNextPacketSize(out var packetFrames);
                ThrowOnHResult(hr, "get next packet size");
                if (packetFrames == 0)
                {
                    Thread.Sleep(5);
                    continue;
                }
                hr = _capture.GetBuffer(
                    out var data, out var frames, out var flags,
                    out _, out _);
                ThrowOnHResult(hr, "get capture buffer");
                Exception? packetError = null;
                try
                {
                    if ((flags & BufferFlagDataDiscontinuity) != 0)
                    {
                        Interlocked.Increment(ref _discontinuityCount);
                    }
                    var count = (int)frames;
                    var needed = count * format.Channels;
                    if (interleavedScratch.Length < needed)
                    {
                        interleavedScratch = new float[needed];
                    }
                    var interleaved = interleavedScratch;
                    if ((flags & BufferFlagSilent) != 0 || data == IntPtr.Zero)
                    {
                        Array.Clear(interleaved, 0, needed);
                    }
                    else if (count > 0)
                    {
                        Marshal.Copy(data, interleaved, 0, needed);
                    }
                    // First packet included: synchronous delivery, no warm-up drop.
                    BlockAvailable?.Invoke(new CapturedBlock(interleaved, count, format));
                }
                catch (Exception ex)
                {
                    packetError = ex;
                }
                finally
                {
                    var releaseHr = _capture.ReleaseBuffer(frames);
                    if (releaseHr < 0)
                    {
                        var releaseError = new NanoException(
                            releaseHr,
                            $"WASAPI release capture buffer failed (HRESULT 0x{releaseHr:X8})");
                        packetError = packetError is null
                            ? releaseError
                            : new AggregateException(packetError, releaseError);
                    }
                }
                if (packetError is not null)
                {
                    System.Runtime.ExceptionServices.ExceptionDispatchInfo
                        .Capture(packetError)
                        .Throw();
                }
            }
        }
        catch (Exception ex)
        {
            // Retained until cleanup completes: raising DeviceChanged here
            // would run before the finally block releases the COM objects,
            // so a subscriber restarting synchronously would hit "capture
            // worker is still stopping".
            deviceError = ex;
        }
        finally
        {
            // Release all COM objects on the same worker thread that acquired them.
            ReleaseOnWorkerThread();
            _cleanupComplete = true;
            _stoppedEvent.Set();
        }

        // Notify after cleanup so a subscriber can restart immediately, and
        // only while capture was active: failures surfacing after Stop or
        // Dispose began are shutdown races, not device failures.
        if (deviceError is not null)
        {
            bool wasRunning;
            lock (_gate)
            {
                wasRunning = _running;
            }
            if (wasRunning)
            {
                DeviceChanged?.Invoke(deviceError);
            }
        }
    }

    private void OpenClientOnWorkerThread()
    {
        if (_testStartupAcquireOverride is not null)
        {
            _testStartupAcquireOverride();
            return;
        }

        Interlocked.Exchange(ref _discontinuityCount, 0);
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
            // 100 ms shared buffer (REFERENCE_TIME is 100 ns units);
            // periodicity 0 lets the engine choose.
            const long BufferDurationHns = 100 * 10_000;
            ThrowOnHResult(
                _client.Initialize(ShareModeShared, 0, BufferDurationHns, 0, fmtPtr, IntPtr.Zero),
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

    // Installs fake COM resources for startup fault-injection tests. Only
    // valid together with the test startup acquire override.
    internal void SetTestStartupResources(
        object enumerator,
        object device,
        IAudioClient client,
        IAudioCaptureClient? capture)
    {
        _enumerator = enumerator;
        _device = device;
        _client = client;
        _capture = capture;
    }

    private void CleanupFailedStartup(Exception ex)
    {
        _startError = ex;
        ReleaseOnWorkerThread();
        _cleanupComplete = true;
        _stoppedEvent.Set();
    }

    private void ReleaseOnWorkerThread()
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
        }
    }

    /// <summary>
    /// Releases one COM object. The <see cref="OperatingSystem.IsWindows"/>
    /// guard keeps the Windows-only <c>ReleaseComObject</c> unreachable on
    /// other platforms (release paths run on every OS).
    /// </summary>
    private void ReleaseCom(object instance)
    {
        if (_testReleaseComOverride is not null)
        {
            _testReleaseComOverride(instance);
            return;
        }
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
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _stopRequested = true;
            _running = false;
            worker = _worker;
        }

        if (worker is null)
        {
            _lastStopClean = true;
            return;
        }

        if (ReferenceEquals(worker, Thread.CurrentThread))
        {
            // Reentrant dispose from the worker thread: the worker's finally
            // block owns the cleanup after the loop observes _stopRequested.
            return;
        }

        // Bounded wait for worker to exit and release COM objects.
        bool cleanShutdown = worker.Join(TimeSpan.FromSeconds(5));

        lock (_gate)
        {
            _lastStopClean = cleanShutdown && _cleanupComplete;
            if (cleanShutdown)
            {
                _worker = null;
                _stopRequested = false;
            }
            // If not clean, _worker remains set and _stopRequested stays true,
            // preventing a new Start until the worker finally exits.
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
            bool running;
            lock (_owner._gate)
            {
                running = _owner._running;
            }
            if (!running)
            {
                return;
            }
            var error = new NanoException(-1, "Windows default capture device changed");
            ThreadPool.QueueUserWorkItem(_ => _owner.DeviceChanged?.Invoke(error));
        }

        public void OnPropertyValueChanged(string deviceId, Guid key) { }
    }
}