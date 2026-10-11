namespace NanoDictate.Core;

/// <summary>
/// Supported product composition: portable config → provider catalog →
/// capture service → transcription (normal/chunked) → controller → host
/// I/O (tray, lifecycle, paths). All policy stays in Rust; this type only
/// sequences Windows-native services around the engine.
/// </summary>
public sealed class HostApp : IDisposable
{
    private readonly PortableConfig _config;
    private readonly DictationCaptureService _capture;
    private readonly DictationController _controller;
    private readonly SttClient _stt;
    private readonly ChunkedTranscriber _chunked;
    private readonly ProviderCatalog _catalog;
    private bool _disposed;

    public HostApp(
        PortableConfig config,
        IAudioCaptureSource captureSource,
        IInsertionSink insertions,
        ISttTransport? transport = null,
        Func<string, string>? apiKeyFor = null)
    {
        _config = config;
        _catalog = new ProviderCatalog(config.Providers, config.ActiveProvider, config.SegmentProvider, config.FinalProvider);
        _capture = new DictationCaptureService(captureSource);
        _controller = new DictationController(
            new CaptureDriverAdapter(_capture),
            insertions,
            null,
            5.0)
        {
            InsertMethod = config.InsertMethod,
            UndoWindow = TimeSpan.FromSeconds(config.UndoMaxInterval),
            ReviewBeforeInsert = config.ReviewBeforeInsert,
        };
        _stt = new SttClient(
            _catalog,
            transport ?? new HttpSttTransport(),
            apiKeyFor ?? (id => ResolveApiKey(id, config)),
            TimeSpan.FromSeconds(config.TimeoutSeconds));
        _chunked = new ChunkedTranscriber(_stt);
    }

    public DictationController Controller => _controller;

    public DictationCaptureService Capture => _capture;

    public ProviderCatalog Catalog => _catalog;

    public static string ResolveApiKey(string providerId, PortableConfig config)
    {
        // Env beats config files for the active provider only (parity with
        // macOS applyEnvAPIKey); role/failover candidates keep their own
        // configured keys (none are stored by this host).
        if (providerId == config.ActiveProvider || string.IsNullOrEmpty(config.ActiveProvider))
        {
            var env = Environment.GetEnvironmentVariable("NANODICTATE_API_KEY");
            if (!string.IsNullOrEmpty(env))
            {
                return env;
            }
        }
        return string.Empty;
    }

    /// <summary>
    /// Transcribes a finished recording with the configured mode
    /// (normal or chunked) and delivers the result through the controller
    /// (review gate, insertion, undo window, Enter latch).
    /// Returns true when text was inserted.
    /// </summary>
    public async Task<bool> TranscribeAndDeliverAsync(
        short[] samples,
        uint sampleRate,
        SttDiagnostics? diagnostics,
        CancellationToken cancellationToken)
    {
        TranscriptionResult result;
        if (_config.Chunked)
        {
            result = await _chunked.TranscribeAsync(
                samples, sampleRate, 45.0, 1.0,
                _config.Language, NullIfEmpty(_config.Prompt),
                _config.AutoFailover, _config.ChunkedFinalPass,
                _config.Transport, _config.ProxyKey,
                diagnostics, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            result = await _stt.TranscribeAsync(
                samples, sampleRate,
                _config.Language, NullIfEmpty(_config.Prompt),
                _config.AutoFailover,
                _config.Transport, _config.ProxyKey,
                diagnostics, cancellationToken).ConfigureAwait(false);
        }
        return _controller.CompleteWithTranscript(result.Text);
    }

    /// <summary>Provider/model selection for UI/menus (no secrets).</summary>
    public IReadOnlyList<(string Id, string Name, bool IsActive)> ListProviders()
    {
        var active = string.IsNullOrEmpty(_config.ActiveProvider)
            ? _catalog.Providers.FirstOrDefault()?.Id ?? string.Empty
            : _config.ActiveProvider;
        return _catalog.Providers
            .Select(p => (p.Id, string.IsNullOrEmpty(p.Name) ? p.Id : p.Name, p.Id == active))
            .ToList();
    }

    public void SelectProvider(string id)
    {
        if (_catalog.Providers.All(p => p.Id != id))
        {
            throw new NanoException(-1, $"unknown provider '{id}'");
        }
    }

    private static string? NullIfEmpty(string value) =>
        string.IsNullOrEmpty(value) ? null : value;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _controller.Dispose();
        _capture.Dispose();
    }
}
