using NanoDictate.Core;

namespace NanoDictate.Host;

/// <summary>
/// Supported Windows product entrypoint. Verbs: run (tray/background
/// dictation), doctor (diagnostics), transcribe-file (offline WAV→text),
/// providers (selection/routing inspection). All product policy resolves
/// through the shared Rust engine; this host only sequences Windows I/O.
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        var verb = args.Length > 0 ? args[0].ToLowerInvariant() : "run";
        try
        {
            return verb switch
            {
                "run" => Run(args.Skip(1).ToArray()),
                "doctor" => Doctor(args.Skip(1).ToArray()),
                "transcribe-file" => TranscribeFile(args.Skip(1).ToArray()).GetAwaiter().GetResult(),
                "providers" => Providers(args.Skip(1).ToArray()),
                "--help" or "-h" or "help" => Usage(),
                _ => Fail($"unknown verb '{verb}'. Expected run, doctor, transcribe-file, or providers."),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"nanodictate: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static int Usage()
    {
        Console.WriteLine("usage: nanodictate <run|doctor|transcribe-file|providers> [options]");
        Console.WriteLine("  run [--config PATH] [--background]");
        Console.WriteLine("  doctor [--config PATH]");
        Console.WriteLine("  transcribe-file --config PATH --wav PATH [--out PATH]");
        Console.WriteLine("  providers [--config PATH]");
        return 0;
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine($"nanodictate: {message}");
        return 2;
    }

    private static string ConfigPath(string[] args, string? fallback = null)
    {
        for (var i = 0; i < args.Length; i++)
        {
            if ((args[i] == "--config" || args[i] == "-c") && i + 1 < args.Length)
            {
                return args[i + 1];
            }
        }
        if (!string.IsNullOrEmpty(fallback))
        {
            return fallback;
        }
        var windowsPath = WindowsPaths.ConfigPath();
        return File.Exists(windowsPath) ? windowsPath : "config.example.toml";
    }

    private static int Doctor(string[] args)
    {
        var config = ConfigPath(args);
        var checks = WindowsDiagnostics.Run(config);
        foreach (var check in checks)
        {
            Console.WriteLine($"doctor: {(check.Passed ? "ok" : "FAIL")} {check.Name}: {check.Detail}");
        }
        return WindowsDiagnostics.AllPassed(checks) ? 0 : 1;
    }

    private static int Providers(string[] args)
    {
        var config = PortableConfig.Load(ConfigPath(args));
        var catalog = new ProviderCatalog(
            config.Providers, config.ActiveProvider, config.SegmentProvider,
            config.FinalProvider, config.FailoverOrderIds);
        var active = catalog.Active();
        var activeModel = string.IsNullOrEmpty(active.Model)
            ? NanoEngine.SttDefaultModel(active.Id)
            : active.Model;
        Console.WriteLine($"providers: active={active.Id} model={activeModel}");
        foreach (var provider in config.Providers)
        {
            var model = string.IsNullOrEmpty(provider.Model)
                ? NanoEngine.SttDefaultModel(provider.Id)
                : provider.Model;
            var profile = SttProfile.Resolve(provider.Id, model);
            Console.WriteLine($"providers: id={provider.Id} name={provider.Name} model={profile.Model} transport={profile.Transport} audio={profile.SampleRate}/{profile.Channels}");
        }
        Console.WriteLine($"providers: segment={catalog.SegmentProvider().Id} final={catalog.FinalProvider().Id}");
        Console.WriteLine($"providers: failover={string.Join(",", catalog.FailoverOrder(null, config.AutoFailover))}");
        return 0;
    }

    private static async Task<int> TranscribeFile(string[] args)
    {
        string? wavPath = null;
        string? outPath = null;
        string? configPath = null;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--wav" && i + 1 < args.Length)
            {
                wavPath = args[++i];
            }
            else if (args[i] == "--out" && i + 1 < args.Length)
            {
                outPath = args[++i];
            }
            else if ((args[i] == "--config" || args[i] == "-c") && i + 1 < args.Length)
            {
                configPath = args[++i];
            }
        }
        if (string.IsNullOrEmpty(wavPath) || !File.Exists(wavPath))
        {
            return Fail("transcribe-file requires --wav PATH to an existing WAV file.");
        }
        configPath ??= ConfigPath(Array.Empty<string>());
        var config = PortableConfig.Load(configPath);
        var bytes = await File.ReadAllBytesAsync(wavPath).ConfigureAwait(false);
        var samples = NanoEngine.WavDecodeSamples(bytes);
        var info = NanoEngine.WavDecodeInfo(bytes);
        var catalog = new ProviderCatalog(
            config.Providers, config.ActiveProvider, config.SegmentProvider,
            config.FinalProvider, config.FailoverOrderIds);
        using var transport = new HttpSttTransport();
        var client = new SttClient(catalog, transport, id => HostApp.ResolveApiKey(id, config), TimeSpan.FromSeconds(config.TimeoutSeconds));
        var diagnostics = new SttDiagnostics();
        TranscriptionResult result;
        if (config.Chunked)
        {
            var chunked = new ChunkedTranscriber(client);
            result = await chunked.TranscribeAsync(samples, info.SampleRate, 45.0, 1.0, config.Language, string.IsNullOrEmpty(config.Prompt) ? null : config.Prompt, config.AutoFailover, config.ChunkedFinalPass, config.Transport, config.ProxyKey, diagnostics, CancellationToken.None).ConfigureAwait(false);
        }
        else
        {
            result = await client.TranscribeAsync(samples, info.SampleRate, config.Language, string.IsNullOrEmpty(config.Prompt) ? null : config.Prompt, config.AutoFailover, config.Transport, config.ProxyKey, diagnostics, CancellationToken.None).ConfigureAwait(false);
        }
        Console.WriteLine($"transcribe: text={result.Text}");
        Console.WriteLine($"transcribe: {diagnostics.Summarize()}");
        if (!string.IsNullOrEmpty(outPath))
        {
            await File.WriteAllTextAsync(outPath, result.Text).ConfigureAwait(false);
        }
        return 0;
    }

    private static int Run(string[] args)
    {
        var background = args.Contains("--background");
        var config = PortableConfig.Load(ConfigPath(args));
        NanoEngine.CheckAvailable();
        WindowsPaths.EnsureDirectories();
        using var lifecycle = new HostLifecycle(new ConsoleTrayIcon());
        using var hotkeys = new GlobalHotkeyService(config.DoubleAltMaxInterval);
        var insertions = CreateInsertionSink(config.InsertMethod);
        using var source = CreateCaptureSource();
        using var app = new HostApp(config, source, insertions);
        app.Controller.ReviewPrompt = new ConsoleReviewPrompt();
        hotkeys.Delegate = app.Controller;
        if (OperatingSystem.IsWindows())
        {
            hotkeys.Start();
        }
        else if (!background)
        {
            Console.WriteLine("run: hotkeys require Windows; continuing without global activation.");
        }
        lifecycle.Announce("NanoDictate", "idle", false);
        Console.WriteLine($"nanodictate: running provider={config.ActiveProvider} chunked={config.Chunked} transport={config.Transport.Transport}");
        Console.WriteLine("nanodictate: double-Alt toggles, Escape cancels, Return stops. Ctrl+C exits.");
        lifecycle.Token.WaitHandle.WaitOne();
        return 0;
    }

    private static IAudioCaptureSource CreateCaptureSource()
    {
        if (OperatingSystem.IsWindows())
        {
            return new WasapiCaptureSource();
        }
        throw new PlatformNotSupportedException("Live capture requires Windows (WASAPI). Use doctor or transcribe-file elsewhere.");
    }

    private static IInsertionSink CreateInsertionSink(InsertMethod method)
    {
        if (!OperatingSystem.IsWindows())
        {
            return new NullInsertionSink();
        }
        var direct = new TextInserter(new WindowsInputSender());
        var clipboard = new ClipboardInsertService(new WindowsClipboardBridge());
        return new InsertionSinkAdapter(direct, clipboard);
    }

    private sealed class ConsoleTrayIcon : ITrayIcon
    {
        public void Show(string tooltip) => Console.WriteLine($"tray: {tooltip}");
        public void SetStatus(string text, bool isRecording) => Console.WriteLine($"tray: {(isRecording ? "recording" : "idle")}: {text}");
        public void Hide() { }
    }

    private sealed class NullInsertionSink : IInsertionSink
    {
        public void Insert(string text, InsertMethod method) => Console.WriteLine($"insert: {text}");
        public void DeleteText(string insertedText) { }
        public void DeleteGraphemes(int count) { }
        public void PostEnter() { }
    }

    private sealed class ConsoleReviewPrompt : IReviewPrompt
    {
        public string? Ask(string text)
        {
            Console.WriteLine($"review: {text}");
            Console.Write("review: insert? [y/N] ");
            return Console.ReadLine();
        }
    }
}
