using NanoDictate.Core;

namespace NanoDictate.Smoke;

/// <summary>
/// Minimal executable smoke path: initializes the shared engine and
/// exercises representative deterministic and session operations.
/// Prints one deterministic line per stage; exits non-zero on failure.
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            Run(args);
            Console.WriteLine("smoke: PASS");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"smoke: FAIL: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static void Run(string[] args)
    {
        // 1. ABI handshake shared with macOS.
        NanoEngine.CheckAvailable();
        Console.WriteLine($"smoke: abi-version={NanoEngine.AbiVersion()}");

        // 2. Portable configuration through the Rust contracts.
        var configPath = args.Length > 0 ? args[0] : FindExampleConfig();
        if (args.Length > 0 && (configPath is null || !File.Exists(configPath)))
        {
            throw new FileNotFoundException("Configuration file was not found.", configPath);
        }
        if (configPath is not null && File.Exists(configPath))
        {
            var config = PortableConfig.Load(configPath);
            var profile = config.ResolveActiveProfile();
            Console.WriteLine($"smoke: active-provider={config.ActiveProvider} profile-bytes={profile.Length}");
            var order = config.ResolveFailoverOrder(null, false);
            Console.WriteLine($"smoke: failover-order={order}");
        }
        else
        {
            Console.WriteLine("smoke: config=missing (skipped)");
        }

        // 3. Deterministic text/STT operations owned by Rust.
        var diff = NanoEngine.WordDiff("One three.", "One two three.");
        Console.WriteLine($"smoke: word-diff={diff}");
        var joined = NanoEngine.TextJoin(new[] { "hello brave world", "brave world again" });
        Console.WriteLine($"smoke: text-join={joined}");
        var transcript = NanoEngine.TranscriptParse("{\"text\": \"hi\"}");
        Console.WriteLine($"smoke: transcript={transcript}");
        var backoff = NanoEngine.BackoffDelayMs(2, 500, 8000);
        Console.WriteLine($"smoke: backoff-ms={backoff}");
        var review = NanoEngine.ReviewDecide("y");
        Console.WriteLine($"smoke: review-decide={review}");

        // 4. WAV ownership roundtrip (Rust allocates, host copies, Rust frees).
        var samples = new short[1600];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = (short)((i % 251) * 40);
        }
        var wav = NanoEngine.WavEncode(samples, 16000, 1);
        var info = NanoEngine.WavDecodeInfo(wav);
        var decoded = NanoEngine.WavDecodeSamples(wav);
        Console.WriteLine($"smoke: wav-bytes={wav.Length} rate={info.SampleRate} samples={decoded.Length}");
        if (!samples.SequenceEqual(decoded))
        {
            throw new InvalidOperationException("WAV roundtrip mismatch");
        }

        // 5. Representative stateful handles.
        using (var vad = new VadHandle())
        {
            for (var i = 0; i < 5; i++)
            {
                vad.Feed(0.0005f, 0.085);
            }
            var speech = vad.Feed(0.02f, 0.085);
            Console.WriteLine($"smoke: vad-speech={speech}");
        }
        using (var gain = new GainHandle())
        {
            var block = new float[1600];
            Array.Fill(block, 0.004f);
            var amplified = gain.Apply(block, 0.004f, 16000);
            Console.WriteLine($"smoke: gain-rms={amplified:F6}");
        }
        using (var stop = new AutoStopHandle())
        {
            for (var i = 0; i < 5; i++)
            {
                stop.Feed(0.02f, 0.1, null);
            }
            var fired = false;
            for (var i = 0; i < 60; i++)
            {
                fired = stop.Feed(0.0005f, 0.1, null);
            }
            Console.WriteLine($"smoke: autostop-fired={fired}");
        }
        using (var session = new SessionHandle())
        {
            var generation = session.Start();
            session.OnEvent(SessionEvent.EngineStarted, generation);
            var readyBefore = session.IsCaptureReady;
            session.OnEvent(SessionEvent.FirstBuffer, generation);
            var readyAfter = session.IsCaptureReady;
            var cueOnce = session.ShouldEmitReadyCue();
            var cueTwice = session.ShouldEmitReadyCue();
            Console.WriteLine($"smoke: session-gen={generation} ready-before={readyBefore} ready-after={readyAfter} cue-once={cueOnce} cue-twice={cueTwice} state={session.State}");
            if (readyBefore || !readyAfter || !cueOnce || cueTwice)
            {
                throw new InvalidOperationException("session readiness latch violated");
            }
            session.OnEvent(SessionEvent.StopRequested, generation);
            session.OnEvent(SessionEvent.TranscriptionDone, generation);
            Console.WriteLine($"smoke: session-terminal={session.State}");
        }
        using (var cooldown = new CooldownHandle(5.0))
        {
            var first = cooldown.Allow(0.0);
            var suppressed = cooldown.Allow(1.0);
            Console.WriteLine($"smoke: cooldown-first={first} suppressed={suppressed}");
        }
        using (var latch = new LatchHandle())
        {
            latch.Arm();
            var once = latch.Consume();
            var twice = latch.Consume();
            Console.WriteLine($"smoke: latch-once={once} twice={twice}");
        }

        // 6. Windows capture pipeline through the shared Rust core:
        // synthetic device blocks (48 kHz stereo) feed the same session
        // state machine, VAD/gain/auto-stop, and live segmentation as
        // the WASAPI path. No algorithm is forked in C#.
        RunCapturePipeline();
    }

    private static void RunCapturePipeline()
    {
        var device = new AudioFormat(48000, 2, 32, true);
        using var pipeline = new RealtimeAudioPipeline(device);
        CaptureMetrics? ready = null;
        pipeline.CaptureReady += m => ready = m;
        pipeline.Start();
        if (pipeline.IsCaptureReady)
        {
            throw new InvalidOperationException("start alone must never report readiness");
        }
        // Immediate speech: first device packet is loud.
        FeedConstant(pipeline, device, 0.02f, deviceBlocks: 50);
        if (!pipeline.IsCaptureReady || ready is null)
        {
            throw new InvalidOperationException("first-buffer readiness never fired");
        }
        // Sustained silence long enough for the shared auto-stop detector.
        FeedConstant(pipeline, device, 0.0005f, deviceBlocks: 600);
        if (!pipeline.AutoStopFired)
        {
            throw new InvalidOperationException("shared auto-stop detector never fired");
        }
        var result = pipeline.Stop();
        var metrics = result.Metrics;
        Console.WriteLine(
            $"smoke: capture-blocks={metrics.BlocksIngested} errors={metrics.EngineErrors} " +
            $"mean-block-ms={metrics.MeanBlockMs:F3} max-block-ms={metrics.MaxBlockMs:F3} " +
            $"first-buffer-ms={metrics.RequestToFirstBufferMs:F1} " +
            $"samples={result.Samples.Count} segments={result.Segments.Count} " +
            $"copies-per-block={metrics.CopiesPerBlock} autostop={metrics.AutoStopFired}");
        if (result.Samples.Count == 0 || Math.Abs(result.Samples[0]) <= 100)
        {
            throw new InvalidOperationException("initial speech samples were dropped");
        }
        if (metrics.EngineErrors != 0)
        {
            throw new InvalidOperationException("engine errors on the smoke path");
        }
        pipeline.FinishTranscription();

        // Repeated session on the same pipeline (fresh detectors, new generation).
        var secondGen = pipeline.Generation;
        pipeline.Start();
        FeedConstant(pipeline, device, 0.02f, deviceBlocks: 10);
        if (!pipeline.IsCaptureReady || pipeline.Generation == secondGen)
        {
            throw new InvalidOperationException("repeated session did not reach readiness");
        }
        pipeline.Cancel();
        Console.WriteLine($"smoke: capture-repeat-gen={pipeline.Generation} ok=true");
    }

    private static void FeedConstant(
        RealtimeAudioPipeline pipeline, AudioFormat device, float value, int deviceBlocks)
    {
        for (var i = 0; i < deviceBlocks; i++)
        {
            var frames = new float[480 * device.Channels];
            Array.Fill(frames, value);
            pipeline.IngestDeviceBlock(new CapturedBlock(frames, 480, device));
        }
    }
    private static string? FindExampleConfig()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "config.example.toml");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        return null;
    }
}
