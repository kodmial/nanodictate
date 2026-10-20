namespace NanoDictate.Core;

/// <summary>
/// Supported product composition: portable config → provider catalog →
/// capture service → transcription (normal/chunked) → controller → host
/// I/O (tray, lifecycle, paths). All policy stays in Rust; this type only
/// sequences Windows-native services around the engine.
/// </summary>
public sealed class HostApp : IDisposable
{
    private const string DeliveryFailureReportedKey = "NanoDictate.DeliveryFailureReported";

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
        config.NormalizeProviderSelection();
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
        _capture.CaptureReady += metrics => CaptureReady?.Invoke(metrics);
        _capture.RawRmsAvailable += rms => RawRmsAvailable?.Invoke(rms);
        _capture.DeviceChanged += error => DeviceChanged?.Invoke(error);
        _capture.AutoStop += _ =>
        {
            // Auto-stop is a user-visible terminal transition owned by the
            // capture engine. Stop the session off the audio callback and let
            // the controller's ProcessingStarted event drive the HUD.
            AutoStopped?.Invoke();
            var generation = _capture.Generation;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    // Do not let a late auto-stop callback stop a newer
                    // recording that started after this session ended.
                    if (_capture.Generation == generation
                        && _controller.State == DictationState.Recording)
                    {
                        _controller.AltDoubleTapped();
                    }
                }
                catch
                {
                    // The capture path will report DeviceChanged/failure.
                }
            });
        };
    }

    public DictationController Controller => _controller;

    /// <summary>Fired exactly once per session on the first valid engine block.</summary>
    public event Action<CaptureMetrics>? CaptureReady;

    /// <summary>Bounded latest-value RMS signal for the native HUD (never queued).</summary>
    public event Action<float>? RawRmsAvailable;

    /// <summary>Raw audio device change aborted the session.</summary>
    public event Action<Exception>? DeviceChanged;

    /// <summary>Rust auto-stop decided to end the recording.</summary>
    public event Action? AutoStopped;

    /// <summary>
    /// Chunked STT is about to issue its sequential requests. The budget covers
    /// every planned chunk plus the conservative final pass, so the HUD
    /// watchdog can replace its single-request budget before the first call.
    /// </summary>
    public event Action<ulong, TimeSpan>? ProcessingBudgetAvailable;

    /// <summary>
    /// STT returned for this recording, before review/insertion. The HUD stops
    /// its processing watchdog here so an open review prompt is never timed out.
    /// </summary>
    public event Action<ulong>? TranscriptionReturned;

    /// <summary>Transcription completed (inserted or empty/review-declined).</summary>
    public event Action<DictationDelivery>? DeliveryCompleted;

    /// <summary>Transcription or insertion failed; insertion remains fail-closed.</summary>
    public event Action<DictationFailure>? DeliveryFailed;

    /// <summary>Resolved provider/model and real release version for the HUD header.</summary>
    public HudSessionLabel SessionLabel
    {
        get
        {
            ProviderEntry provider;
            try
            {
                provider = _catalog.Active();
            }
            catch (NanoException)
            {
                return new HudSessionLabel(
                    "NanoDictate",
                    "No provider configured",
                    HudSessionLabel.ResolveVersion());
            }
            var name = string.IsNullOrEmpty(provider.Name) ? provider.Id : provider.Name;
            var profile = SttProfile.Resolve(provider.Id, provider.Model);
            return new HudSessionLabel(name, profile.Model, HudSessionLabel.ResolveVersion());
        }
    }

    public DictationCaptureService Capture => _capture;

    public ProviderCatalog Catalog => _catalog;

    /// <summary>
    /// Launch-time watchdog budget before a recording plan exists. Chunked
    /// recordings replace it with <see cref="ChunkedProcessingBudget"/> through
    /// <see cref="ProcessingBudgetAvailable"/> before the first request.
    /// </summary>
    public static TimeSpan InitialProcessingWatchdog(PortableConfig config)
    {
        var perRequest = TimeSpan.FromSeconds(config.TimeoutSeconds);
        if (config.Chunked)
        {
            // The chunk plan publishes its full budget before the first STT request.
            return TimeSpan.FromTicks(perRequest.Ticks * 2) + TimeSpan.FromSeconds(5);
        }

        // A non-chunked recording has no later budget update. Cover every
        // permitted provider attempt and its retry backoff, including a
        // retryable failure on the last attempt, before watchdog cancellation.
        var attempts = Math.Max(1,
            NanoEngine.FailoverCandidateCount(Math.Max(1, config.Providers.Count), config.AutoFailover));
        var backoffTicks = 0L;
        for (var attempt = 0; attempt < attempts; attempt++)
        {
            backoffTicks = checked(backoffTicks +
                TimeSpan.FromMilliseconds(NanoEngine.BackoffDelayMs((uint)attempt, 500, 8000)).Ticks);
        }
        return TimeSpan.FromTicks(checked(perRequest.Ticks * attempts + backoffTicks))
            + TimeSpan.FromSeconds(5);
    }

    /// <summary>
    /// Total STT request budget for a chunked recording. Every planned chunk is
    /// one request and pays its own retry backoff even when no failover
    /// candidate remains; the final full-recording pass is budgeted with its
    /// possible failover candidates and backoff pauses, mirroring the macOS
    /// watchdog.
    /// </summary>
    public static TimeSpan ChunkedProcessingBudget(
        PortableConfig config,
        int sampleCount,
        uint sampleRate)
    {
        var chunks = NanoEngine.BatchPlan(sampleCount, sampleRate, 45.0, 1.0);
        var providerCount = Math.Max(1, config.Providers.Count);
        var finalAttempts = Math.Max(
            1,
            NanoEngine.FailoverCandidateCount(providerCount, config.AutoFailover));
        var perRequest = TimeSpan.FromSeconds(config.TimeoutSeconds);
        var requestTicks = perRequest.Ticks * (chunks.Length + finalAttempts);
        var finalBackoff = TimeSpan.FromSeconds(Math.Max(0, finalAttempts - 1) * 8);
        var chunkBackoff = TimeSpan.FromMilliseconds(
            NanoEngine.BackoffDelayMs(0, 500, 8000) * (ulong)chunks.Length);
        return TimeSpan.FromTicks(requestTicks) + finalBackoff + chunkBackoff + TimeSpan.FromSeconds(5);
    }

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
            ProcessingBudgetAvailable?.Invoke(
                recordingId,
                ChunkedProcessingBudget(_config, samples.Length, sampleRate));
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
        TranscriptionReturned?.Invoke(recordingId);
        bool inserted;
        try
        {
            inserted = _controller.CompleteWithTranscript(result.Text, 0, 0, recordingId);
        }
        catch (Exception ex)
        {
            DeliveryFailed?.Invoke(new DictationFailure(recordingId, ex, DictationFailureKind.Insertion));
            ex.Data[DeliveryFailureReportedKey] = true;
            throw;
        }
        DeliveryCompleted?.Invoke(new DictationDelivery(recordingId, result.Text, inserted));
        return inserted;
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
        _config.ActiveProvider = id;
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
        catch (Exception ex)
        {
            if (cancellationToken.IsCancellationRequested || _controller.IsCancelRequested)
            {
                return;
            }
            // Keep fail-closed insertion: an STT failure still completes the
            // capture session with an empty result, but the HUD receives the
            // truthful error instead of silently coalescing it to "no speech".
            // Insertion failures already reported their kind above.
            if (!ex.Data.Contains(DeliveryFailureReportedKey))
            {
                DeliveryFailed?.Invoke(new DictationFailure(recordingId, ex, DictationFailureKind.Transcription));
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
