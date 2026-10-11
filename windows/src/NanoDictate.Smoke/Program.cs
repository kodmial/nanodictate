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
        // Flag-style arguments (live-capture options below) are not paths.
        var positional = args
            .Where((a, i) => !a.StartsWith('-') &&
                !(i > 0 && string.Equals(args[i - 1], "--live-seconds", StringComparison.OrdinalIgnoreCase)))
            .ToArray();
        var configPath = positional.Length > 0 ? positional[0] : FindExampleConfig();
        if (positional.Length > 0 && (configPath is null || !File.Exists(configPath)))
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
            Console.WriteLine(
                $"smoke: host insert-method={InsertMethodParser.ToConfigString(config.InsertMethod)} " +
                $"double-alt={config.DoubleAltMaxInterval} undo={config.UndoMaxInterval} " +
                $"review={config.ReviewBeforeInsert}");
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

        // 6. Windows host capabilities around the shared Rust core:
        // activation routing, Unicode chunking, Rust-backed text policy,
        // mic/privacy classification, and Windows paths. Deterministic and
        // hardware-free; Windows-only senders are not touched here.
        RunHostCapabilities();

        // 7. Windows capture pipeline through the shared Rust core:
        // synthetic device blocks (48 kHz stereo) feed the same session
        // state machine, VAD/gain/auto-stop, and live segmentation as
        // the WASAPI path. No algorithm is forked in C#.
        RunCapturePipeline();

        // 8. Opt-in Windows-native microphone capture: the production
        // composition of WasapiCaptureSource with DictationCaptureService
        // behind `--live-capture` (optionally `--live-seconds=N`).
        // The deterministic synthetic path above always runs; this path
        // proves the host entrypoint reaches the service lifecycle.
        if (HasFlag(args, "--live-capture") || HasFlag(args, "--live"))
        {
            RunLiveCapture(args);
        }
    }

    /// <summary>
    /// Production capture composition: a <see cref="WasapiCaptureSource"/>
    /// feeding a <see cref="DictationCaptureService"/>. Windows-only;
    /// fails loudly on other platforms instead of pretending to record.
    /// </summary>
    private static void RunLiveCapture(string[] args)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Live WASAPI capture requires Windows.");
        }
        var seconds = ParseLiveSeconds(args, 5.0);
        using var source = new WasapiCaptureSource();
        using var service = new DictationCaptureService(source);
        CaptureMetrics? ready = null;
        Exception? deviceError = null;
        service.CaptureReady += m => ready = m;
        service.DeviceChanged += ex => deviceError = ex;
        var probed = source.ProbeDefaultFormat();
        Console.WriteLine(
            $"smoke: live-capture-format rate={probed.SampleRate} " +
            $"channels={probed.Channels} bits={probed.BitsPerSample}");
        service.Start();
        try
        {
            var readyDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
            while (!service.IsCaptureReady && deviceError is null && DateTime.UtcNow < readyDeadline)
            {
                Thread.Sleep(10);
            }
            if (deviceError is not null)
            {
                throw new InvalidOperationException(
                    $"live capture device failed before readiness: {deviceError.Message}", deviceError);
            }
            if (!service.IsCaptureReady || ready is null)
            {
                throw new InvalidOperationException("live capture never became ready");
            }
            Thread.Sleep(TimeSpan.FromSeconds(seconds));
            if (deviceError is not null)
            {
                throw new InvalidOperationException(
                    $"live capture device failed: {deviceError.Message}", deviceError);
            }
            var result = service.Stop();
            var metrics = result.Metrics;
            Console.WriteLine(
                $"smoke: live-capture blocks={metrics.BlocksIngested} errors={metrics.EngineErrors} " +
                $"samples={result.Samples.Count} segments={result.Segments.Count}");
            service.FinishTranscription();
        }
        catch
        {
            try
            {
                service.Cancel();
            }
            catch
            {
                // Best effort: the original exception is authoritative.
            }
            throw;
        }
    }

    private static bool HasFlag(string[] args, string flag) =>
        args.Any(a =>
            string.Equals(a, flag, StringComparison.OrdinalIgnoreCase) ||
            a.StartsWith(flag + "=", StringComparison.OrdinalIgnoreCase));

    private static double ParseLiveSeconds(string[] args, double fallback)
    {
        foreach (var arg in args)
        {
            string? value = null;
            if (arg.StartsWith("--live-seconds=", StringComparison.OrdinalIgnoreCase))
            {
                value = arg.Substring("--live-seconds=".Length);
            }
            else if (string.Equals(arg, "--live-seconds", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (value is not null && double.TryParse(
                    value,
                    System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture,
                    out var parsed) && parsed > 0 && parsed <= 60)
            {
                return parsed;
            }
        }
        for (var i = 0; i + 1 < args.Length; i++)
        {
            if (string.Equals(args[i], "--live-seconds", StringComparison.OrdinalIgnoreCase) &&
                double.TryParse(
                    args[i + 1],
                    System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture,
                    out var parsed) && parsed > 0 && parsed <= 60)
            {
                return parsed;
            }
        }
        return fallback;
    }

    private static void RunHostCapabilities()
    {
        var detector = new DoubleAltDetector(0.4);
        if (detector.RegisterTap(100.0) || !detector.RegisterTap(100.3))
        {
            throw new InvalidOperationException("double-Alt detector vector failed");
        }
        const string sample = "Привет мир 🎉 done";
        var chunks = TextChunker.Chunk(sample);
        if (string.Concat(chunks) != sample)
        {
            throw new InvalidOperationException("Unicode chunk roundtrip failed");
        }
        Console.WriteLine($"smoke: host chunks={chunks.Count} elements={TextChunker.CountTextElements(sample)}");
        if (DictationTextPolicy.IsEmptyResult("   ...   "))
        {
            Console.WriteLine("smoke: host empty-guard=true");
        }
        var diff = RustTextPolicy.WordDiff("One three.", "One two three.");
        if (!diff.HasChange || string.IsNullOrEmpty(diff.SpanNew))
        {
            throw new InvalidOperationException("Rust word-diff vector failed");
        }
        var kind = MicFailureClassifier.Classify(unchecked((int)0x80070005), "start");
        if (kind != MicFailureKind.Denied)
        {
            throw new InvalidOperationException("mic classifier vector failed");
        }
        Console.WriteLine($"smoke: host mic-guide={MicPrivacyGuide.SettingsUri}");
        Console.WriteLine($"smoke: host config-path={WindowsPaths.ConfigPath()}");
        var poster = new CancellableEnterPoster();
        var fired = 0;
        poster.Action = () => fired++;
        poster.Schedule();
        if (!poster.FireForTests() || fired != 1)
        {
            throw new InvalidOperationException("enter poster vector failed");
        }
        Console.WriteLine("smoke: host-capabilities ok=true");
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
