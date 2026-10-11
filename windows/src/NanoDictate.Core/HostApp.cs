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
    private SttClient _stt;
    private ChunkedTranscriber _chunked;
    private ProviderCatalog _catalog;
    private readonly ISttTransport? _ownedTransport;
    private readonly ISttTransport _transport;
    private readonly Func<string, string> _apiKeyFor;
    private readonly TimeSpan _timeout;
    private string _activeProviderId;
    private bool _disposed;

    public HostApp(
        PortableConfig config,
        IAudioCaptureSource captureSource,
        IInsertionSink insertions,
        ISttTransport? transport = null,
        Func<string, string>? apiKeyFor = null)
    {
        _config = config;
        _activeProviderId = config.ActiveProvider;
        _catalog = new ProviderCatalog(config.Providers, _activeProviderId, config.SegmentProvider, config.FinalProvider);
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
        _apiKeyFor = apiKeyFor ?? (id => ResolveApiKey(id, config));
        _timeout = TimeSpan.FromSeconds(config.TimeoutSeconds);
        if (transport is null)
        {
            var owned = new HttpSttTransport();
            _ownedTransport = owned;
            transport = owned;
        }
        _transport = transport;
        _stt = new SttClient(
            _catalog,
            transport,
            _apiKeyFor,
            _timeout);
        _chunked = new ChunkedTranscriber(_stt);
        _controller.StopTranscriptionHandler = TranscribeStoppedAsync;
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
        CancellationToken cancellationToken,
        ulong recordingId = 0)
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
        cancellationToken.ThrowIfCancellationRequested();
        return _controller.CompleteWithTranscript(result.Text, 0, 0, recordingId);
    }

    /// <summary>Provider/model selection for UI/menus (no secrets).</summary>
    public IReadOnlyList<(string Id, string Name, bool IsActive)> ListProviders()
    {
        var active = string.IsNullOrEmpty(_activeProviderId)
            ? _catalog.Providers.FirstOrDefault()?.Id ?? string.Empty
            : _activeProviderId;
        return _catalog.Providers
            .Select(p => (p.Id, string.IsNullOrEmpty(p.Name) ? p.Id : p.Name, p.Id == active))
            .ToList();
    }

    public string ActiveProviderId => _activeProviderId;

    public void SelectProvider(string id)
    {
        if (_catalog.Providers.All(p => p.Id != id))
        {
            throw new NanoException(-1, $"unknown provider '{id}'");
        }
        _activeProviderId = id;
        var reordered = _catalog.Providers
            .OrderBy(p => p.Id == id ? 0 : 1)
            .ToList();
        _catalog = new ProviderCatalog(reordered, _activeProviderId, _config.SegmentProvider, _config.FinalProvider);
        _stt = new SttClient(_catalog, _transport, _apiKeyFor, _timeout);
        _chunked = new ChunkedTranscriber(_stt);
    }

    /// <summary>
    /// Capture-stop callback: forwards the stopped recording to
    /// transcription and delivery. Runs off the hotkey thread; cancellation
    /// is honored through the token and the controller's cancel flag, and
    /// delivery still flows through <see cref="DictationController.CompleteWithTranscript"/>.
    /// The session identifier rejects stale results when a newer recording
    /// started before this transcription completed.
    /// </summary>
    private async Task TranscribeStoppedAsync(IReadOnlyList<short> stoppedSamples, CancellationToken cancellationToken, ulong recordingId)
    {
        try
        {
            var samples = stoppedSamples as short[] ?? stoppedSamples.ToArray();
            await TranscribeAndDeliverAsync(samples, 16000, null, cancellationToken, recordingId).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            try
            {
                _controller.CompleteWithTranscript(string.Empty, 0, 0, recordingId);
            }
            catch
            {
            }
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
        _controller.StopTranscriptionHandler = null;
        _controller.Dispose();
        _capture.Dispose();
        (_ownedTransport as IDisposable)?.Dispose();
    }
}
