namespace NanoDictate.Core;

/// <summary>
/// In-memory scripted capture source for tests, CI (including non-Windows
/// runners), and the smoke path. Emits caller-supplied device-format blocks
/// on a background thread with capture-thread semantics, so pipeline tests
/// prove first-buffer preservation, repeated start/stop, start-failure
/// recovery, and device-change handling without audio hardware.
/// </summary>
public sealed class SyntheticCaptureSource : IAudioCaptureSource
{
    private readonly object _gate = new();
    private readonly Queue<(float[] Frames, int Count)> _script = new();
    private readonly int _framesPerBlock;
    private Thread? _worker;
    private bool _running;
    private bool _disposed;
    private bool _failNextStart;

    public SyntheticCaptureSource(AudioFormat format, int framesPerBlock = 480)
    {
        format.Validate();
        if (framesPerBlock <= 0)
        {
            throw new NanoException(-1, "frames per block must be positive");
        }
        Format = format;
        _framesPerBlock = framesPerBlock;
    }

    public AudioFormat Format { get; }

    public bool IsRunning
    {
        get { lock (_gate) { return _running; } }
    }

    public event Action<CapturedBlock>? BlockAvailable;

    public event Action<Exception>? DeviceChanged;

    /// <summary>Queues one device-format block (interleaved Float32) for emission.</summary>
    public void EnqueueBlock(float[] interleavedFrames, int frameCount)
    {
        if (frameCount < 0 || frameCount * Format.Channels > interleavedFrames.Length)
        {
            throw new NanoException(-1, "frame count exceeds input span");
        }
        lock (_gate)
        {
            _script.Enqueue((interleavedFrames, frameCount));
            Monitor.PulseAll(_gate);
        }
    }

    /// <summary>Queues a constant-value block (test helper).</summary>
    public void EnqueueConstant(float value, int frameCount)
    {
        var frames = new float[frameCount * Format.Channels];
        Array.Fill(frames, value);
        EnqueueBlock(frames, frameCount);
    }

    /// <summary>Injects silence blocks (zeros).</summary>
    public void EnqueueSilence(int blocks)
    {
        for (var i = 0; i < blocks; i++)
        {
            EnqueueConstant(0.0f, _framesPerBlock);
        }
    }

    /// <summary>Makes the next <see cref="Start"/> throw (start-failure recovery test).</summary>
    public void FailNextStart() => _failNextStart = true;

    /// <summary>Fires a device-change notification (device-change test).</summary>
    public void SimulateDeviceChange()
    {
        DeviceChanged?.Invoke(new NanoException(-1, "synthetic device change"));
    }

    /// <summary>Number of scripted blocks still queued.</summary>
    public int QueuedBlocks
    {
        get { lock (_gate) { return _script.Count; } }
    }

    public void Start()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            if (_running)
            {
                return;
            }
            if (_failNextStart)
            {
                _failNextStart = false;
                throw new NanoException(-1, "synthetic capture start failed");
            }
            _running = true;
            _worker = new Thread(Worker) { IsBackground = true, Name = "nanodictate-synth-capture" };
            _worker.Start();
        }
    }

    public void Stop()
    {
        Thread? worker;
        lock (_gate)
        {
            _running = false;
            Monitor.PulseAll(_gate);
            worker = _worker;
            _worker = null;
        }
        worker?.Join(TimeSpan.FromSeconds(5));
    }

    private void Worker()
    {
        while (true)
        {
            (float[] Frames, int Count) next = default;
            var hasBlock = false;
            lock (_gate)
            {
                while (_running && _script.Count == 0)
                {
                    Monitor.Wait(_gate, TimeSpan.FromMilliseconds(20));
                }
                if (!_running)
                {
                    return;
                }
                if (_script.Count > 0)
                {
                    next = _script.Dequeue();
                    hasBlock = true;
                }
            }
            if (hasBlock)
            {
                bool disposed;
                lock (_gate)
                {
                    disposed = _disposed;
                }
                if (!disposed)
                {
                    BlockAvailable?.Invoke(new CapturedBlock(next.Frames, next.Count, Format));
                }
            }
            // Pace emissions like a device callback.
            Thread.Sleep(1);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(SyntheticCaptureSource));
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
        }
        Stop();
    }
}
