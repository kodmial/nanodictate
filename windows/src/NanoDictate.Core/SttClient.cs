using System.Text;

namespace NanoDictate.Core;

/// <summary>
/// Provider catalog: selection and routing over configured providers.
/// Carries data only; ordering/failover math goes through Rust.
/// </summary>
public sealed class ProviderCatalog
{
    private readonly IReadOnlyList<ProviderEntry> _providers;
    private readonly string _activeId;
    private readonly string _segmentId;
    private readonly string _finalId;
    private readonly IReadOnlyList<string>? _failoverOrderIds;

    public ProviderCatalog(
        IReadOnlyList<ProviderEntry> providers,
        string activeId,
        string segmentId = "",
        string finalId = "",
        IReadOnlyList<string>? failoverOrderIds = null)
    {
        _providers = providers;
        _activeId = activeId;
        _segmentId = segmentId;
        _finalId = finalId;
        _failoverOrderIds = failoverOrderIds;
    }

    public IReadOnlyList<ProviderEntry> Providers => _providers;

    /// <summary>Effective active provider (empty active id means the first provider).</summary>
    public ProviderEntry Active()
    {
        if (!string.IsNullOrEmpty(_activeId))
        {
            var match = Find(_activeId);
            if (match is not null)
            {
                return match;
            }
            throw new NanoException(-1, $"unknown provider '{_activeId}'. Available: {string.Join(", ", _providers.Select(p => p.Id))}");
        }
        if (_providers.Count > 0)
        {
            return _providers[0];
        }
        throw new NanoException(-1, "no STT providers configured");
    }

    public ProviderEntry ForRole(string roleId, string roleName)
    {
        if (string.IsNullOrEmpty(roleId))
        {
            return Active();
        }
        var match = Find(roleId);
        if (match is null)
        {
            throw new NanoException(-1, $"unknown {roleName} provider '{roleId}'. Available: {string.Join(", ", _providers.Select(p => p.Id))}");
        }
        return match;
    }

    public ProviderEntry SegmentProvider() => ForRole(_segmentId, "segment");

    public ProviderEntry FinalProvider() => ForRole(_finalId, "final");

    private ProviderEntry? Find(string id) => _providers.FirstOrDefault(p => p.Id == id);

    /// <summary>Failover order for the given role through Rust.</summary>
    public IReadOnlyList<string> FailoverOrder(string? failedId, bool autoFailover)
    {
        var ids = _failoverOrderIds ?? _providers.Select(p => p.Id).ToList();
        var joined = NanoEngine.FailoverOrder(ids, failedId, autoFailover);
        return string.IsNullOrEmpty(joined)
            ? Array.Empty<string>()
            : joined.Split(',', StringSplitOptions.RemoveEmptyEntries);
    }

    public int CandidateCount(bool autoFailover) =>
        NanoEngine.FailoverCandidateCount(_providers.Count, autoFailover);
}

/// <summary>One fully-planned STT request (URL, headers, multipart body).</summary>
public sealed record SttRequestPlan(
    string Url,
    IReadOnlyDictionary<string, string> Headers,
    byte[] Body,
    string ContentType,
    string ProviderId,
    string Model,
    string? TranscriptPath);

/// <summary>
/// Builds OpenAI-compatible multipart STT requests from the resolved Rust
/// profile. Field gating (verbose_json only when the profile supports word
/// timestamps for segment stitching, prompt/temperature/VAD only when
/// supported, language hint per hint mode) mirrors the macOS
/// ProviderRequestBuilder rules; the profile itself always comes from Rust.
/// </summary>
public static class SttRequestBuilder
{
    public static SttRequestPlan Plan(
        ProviderEntry provider,
        SttProfile profile,
        byte[] wavBytes,
        string language,
        string? prompt,
        bool needWordTimestamps,
        TransportConfig transport,
        string apiKey,
        string proxyKey)
    {
        var baseUrl = string.IsNullOrEmpty(provider.BaseUrl)
            ? NanoEngine.SttDefaultBaseUrl(provider.Id)
            : provider.BaseUrl;
        if (string.IsNullOrEmpty(baseUrl))
        {
            throw new NanoException(-1, $"provider '{provider.Id}' has no base URL and no adapter default");
        }
        // Empty configured model resolves through Rust to the adapter default
        // (same portable decision as macOS ProviderRequestBuilder.resolveModel).
        var model = string.IsNullOrEmpty(provider.Model)
            ? NanoEngine.SttDefaultModel(provider.Id)
            : provider.Model;
        if (string.IsNullOrEmpty(profile.Model) && !string.IsNullOrEmpty(model))
        {
            profile = SttProfile.Resolve(provider.Id, model);
        }
        if (profile.IsStreaming)
        {
            throw new NanoException(-1, $"profile '{profile.Model}' requires a streaming session, not a batch upload");
        }
        var url = transport.RewriteUrl(baseUrl);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(apiKey))
        {
            headers["Authorization"] = "Bearer " + apiKey;
        }
        if (transport.Transport == SttTransportMode.Gateway && !string.IsNullOrEmpty(proxyKey))
        {
            var header = string.IsNullOrEmpty(transport.ProxyKeyHeader) ? "X-Proxy-Key" : transport.ProxyKeyHeader;
            headers[header] = proxyKey;
        }
        if (transport.Transport == SttTransportMode.HttpProxy && transport.HasProxyAuth)
        {
            headers["Proxy-Authorization"] = transport.ProxyAuthHeader();
        }
        if (transport.Transport == SttTransportMode.CookieRelay)
        {
            throw new NanoException(-1, "cookie-relay transport is not supported on the Windows host; use direct, http, or gateway");
        }

        var boundary = "----NanoDictate" + Guid.NewGuid().ToString("N");
        using var body = new MemoryStream();
        void WriteField(string name, string value)
        {
            var header = $"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n";
            var headerBytes = Encoding.UTF8.GetBytes(header);
            body.Write(headerBytes, 0, headerBytes.Length);
            var valueBytes = Encoding.UTF8.GetBytes(value);
            body.Write(valueBytes, 0, valueBytes.Length);
            var crlf = Encoding.UTF8.GetBytes("\r\n");
            body.Write(crlf, 0, crlf.Length);
        }
        if (!string.IsNullOrEmpty(model))
        {
            WriteField("model", model);
        }
        if (needWordTimestamps && profile.SupportsVerboseJson && profile.SupportsWordTimestamps)
        {
            WriteField("response_format", "verbose_json");
            WriteField("timestamp_granularities[]", "word");
        }
        if (!string.IsNullOrEmpty(prompt) && profile.SupportsPrompt)
        {
            WriteField("prompt", prompt);
        }
        if (!string.IsNullOrEmpty(language))
        {
            if (profile.LanguageHint == "multi")
            {
                WriteField("languages[]", language);
            }
            else if (profile.LanguageHint == "single")
            {
                WriteField("language", language);
            }
        }
        var fileHeader = $"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n";
        var fileHeaderBytes = Encoding.UTF8.GetBytes(fileHeader);
        body.Write(fileHeaderBytes, 0, fileHeaderBytes.Length);
        body.Write(wavBytes, 0, wavBytes.Length);
        var footer = Encoding.UTF8.GetBytes($"\r\n--{boundary}--\r\n");
        body.Write(footer, 0, footer.Length);
        var contentType = "multipart/form-data; boundary=" + boundary;
        string? path = profile.TranscriptPath.Count == 0 ? null : profile.TranscriptPathDotted;
        return new SttRequestPlan(url, headers, body.ToArray(), contentType, provider.Id, model, path);
    }
}

/// <summary>
/// Normal (single-utterance) transcription client. Uploads one complete
/// WAV per request, retries retryable failures with Rust backoff, and
/// fails over across providers through Rust ordering/classification.
/// Network I/O stays in <see cref="ISttTransport"/>; all policy lives in Rust.
/// </summary>
public sealed class SttClient
{
    private readonly ProviderCatalog _catalog;
    private readonly ISttTransport _transport;
    private readonly Func<string, string> _apiKeyFor;
    private readonly TimeSpan _timeout;
    private readonly ulong _backoffBaseMs;
    private readonly ulong _backoffCapMs;

    public SttClient(
        ProviderCatalog catalog,
        ISttTransport transport,
        Func<string, string>? apiKeyFor = null,
        TimeSpan? timeout = null,
        ulong backoffBaseMs = 500,
        ulong backoffCapMs = 8000)
    {
        _catalog = catalog;
        _transport = transport;
        _apiKeyFor = apiKeyFor ?? (_ => string.Empty);
        _timeout = timeout ?? TimeSpan.FromSeconds(120);
        _backoffBaseMs = backoffBaseMs;
        _backoffCapMs = backoffCapMs;
    }

    public async Task<TranscriptionResult> TranscribeAsync(
        short[] samples,
        uint sampleRate,
        string language,
        string? prompt,
        bool autoFailover,
        TransportConfig transport,
        string proxyKey,
        SttDiagnostics? diagnostics,
        CancellationToken cancellationToken,
        Func<uint, Task>? delayAsync = null)
    {
        var wav = NanoEngine.WavEncode(samples, sampleRate, 1);
        return await TranscribeWavAsync(wav, language, prompt, autoFailover, transport, proxyKey, diagnostics, cancellationToken, delayAsync).ConfigureAwait(false);
    }

    public async Task<TranscriptionResult> TranscribeWavAsync(
        byte[] wavBytes,
        string language,
        string? prompt,
        bool autoFailover,
        TransportConfig transport,
        string proxyKey,
        SttDiagnostics? diagnostics,
        CancellationToken cancellationToken,
        Func<uint, Task>? delayAsync = null)
    {
        var order = _catalog.FailoverOrder(null, autoFailover).ToList();
        if (order.Count == 0)
        {
            throw new NanoException(-1, "no STT providers configured");
        }
        var attempts = NanoEngine.FailoverCandidateCount(order.Count, autoFailover);
        TranscribeError? lastError = null;
        for (var attempt = 0; attempt < attempts; attempt++)
        {
            var providerId = order[Math.Min(attempt, order.Count - 1)];
            var provider = _catalog.Providers.First(p => p.Id == providerId);
            SttProfile profile;
            SttRequestPlan plan;
            try
            {
                var model = string.IsNullOrEmpty(provider.Model)
                    ? NanoEngine.SttDefaultModel(provider.Id)
                    : provider.Model;
                profile = SttProfile.Resolve(provider.Id, model);
                var needPlanWords = false;
                plan = SttRequestBuilder.Plan(provider, profile, wavBytes, language, prompt, needPlanWords, transport, _apiKeyFor(provider.Id), proxyKey);
            }
            catch (NanoException ex) when (attempt > 0)
            {
                diagnostics?.Add(new SttAttemptLog(providerId, provider.Model, string.Empty, wavBytes.Length, 0, false, ex.Message));
                continue;
            }
            var started = DateTime.UtcNow;
            try
            {
                var response = await _transport.SendAsync(plan.Url, plan.Headers, plan.Body, plan.ContentType, _timeout, cancellationToken).ConfigureAwait(false);
                var elapsed = (DateTime.UtcNow - started).TotalMilliseconds;
                if (response.Status < 200 || response.Status >= 300)
                {
                    var text = Truncate(Encoding.UTF8.GetString(response.Body), 500);
                    var error = new TranscribeError(TranscribeError.ErrorKind.Http, $"STT HTTP {response.Status}: {text}", response.Status);
                    diagnostics?.Add(new SttAttemptLog(providerId, plan.Model, plan.Url, plan.Body.Length, elapsed, false, error.Message));
                    lastError = error;
                    if (!error.IsRetryable || !NanoEngine.ShouldFailover(error.RustKind))
                    {
                        throw error;
                    }
                    await Backoff((uint)attempt, delayAsync, cancellationToken).ConfigureAwait(false);
                    continue;
                }
                var parsed = TranscriptionResult.Parse(Encoding.UTF8.GetString(response.Body), plan.TranscriptPath);
                diagnostics?.Add(new SttAttemptLog(providerId, plan.Model, plan.Url, plan.Body.Length, elapsed, true, string.Empty));
                return parsed;
            }
            catch (TranscribeError ex)
            {
                var elapsed = (DateTime.UtcNow - started).TotalMilliseconds;
                diagnostics?.Add(new SttAttemptLog(providerId, plan.Model, plan.Url, plan.Body.Length, elapsed, false, ex.Message));
                lastError = ex;
                if (!ex.IsRetryable || !NanoEngine.ShouldFailover(ex.RustKind))
                {
                    throw;
                }
                await Backoff((uint)attempt, delayAsync, cancellationToken).ConfigureAwait(false);
            }
        }
        throw lastError ?? new TranscribeError(TranscribeError.ErrorKind.Network, "STT failed with no attempts");
    }

    private async Task Backoff(uint attempt, Func<uint, Task>? delayAsync, CancellationToken cancellationToken)
    {
        var delayMs = NanoEngine.BackoffDelayMs(attempt, _backoffBaseMs, _backoffCapMs);
        if (delayMs == 0)
        {
            return;
        }
        if (delayAsync is not null)
        {
            await delayAsync((uint)delayMs).ConfigureAwait(false);
            return;
        }
        await Task.Delay(TimeSpan.FromMilliseconds(delayMs), cancellationToken).ConfigureAwait(false);
    }

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value.Substring(0, max);
}
