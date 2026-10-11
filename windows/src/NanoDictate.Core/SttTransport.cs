using System.Net;
using System.Text;
using System.Text.Json;

namespace NanoDictate.Core;

/// <summary>Transport selection for STT uploads (mirrors macOS AppConfig.transport).</summary>
public enum SttTransportMode
{
    Direct,
    HttpProxy,
    Gateway,
    CookieRelay,
}

/// <summary>Proxy/transport configuration. Carries data only; request
/// rewriting is mechanical and never reimplements provider policy.</summary>
public sealed record TransportConfig(
    SttTransportMode Transport,
    string HttpProxy,
    string ProxyUser,
    string ProxyPassword,
    string ProxyKey,
    string ProxyKeyHeader)
{
    public static TransportConfig Direct => new(SttTransportMode.Direct, string.Empty, string.Empty, string.Empty, string.Empty, "X-Proxy-Key");

    public static SttTransportMode ParseMode(string value) => value switch
    {
        "http" => SttTransportMode.HttpProxy,
        "gateway" => SttTransportMode.Gateway,
        "cookie-relay" or "cookie_relay" or "cookierelay" => SttTransportMode.CookieRelay,
        _ => SttTransportMode.Direct,
    };

    /// <summary>
    /// Rewrites the request URI for HTTP-proxy transport
    /// (scheme "URL-as-path"): only https URLs are rewritten; anything else
    /// leaves the proxy unused (fail-closed, mirrors macOS CWE-319 rule).
    /// </summary>
    public string RewriteUrl(string baseUrl)
    {
        if (Transport != SttTransportMode.HttpProxy || string.IsNullOrEmpty(HttpProxy))
        {
            return baseUrl;
        }
        if (!baseUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return baseUrl;
        }
        var proxy = HttpProxy.TrimEnd('/');
        return proxy + "/" + baseUrl;
    }

    public bool HasProxyAuth => !string.IsNullOrEmpty(ProxyUser) || !string.IsNullOrEmpty(ProxyPassword);

    public string ProxyAuthHeader()
    {
        var raw = $"{ProxyUser}:{ProxyPassword}";
        return "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(raw));
    }
}

/// <summary>One STT HTTP error with retry classification owned by Rust.</summary>
public sealed class TranscribeError : Exception
{
    public enum ErrorKind
    {
        Network,
        Http,
        InvalidResponse,
    }

    public ErrorKind Kind { get; }

    public int? StatusCode { get; }

    public TranscribeError(ErrorKind kind, string message, int? status = null)
        : base(message)
    {
        Kind = kind;
        StatusCode = status;
    }

    /// <summary>
    /// Retryable: transport failure, 429, or 5xx. Anything else is final.
    /// Mirrors the macOS BatchHTTPError.isRetryable rule; the failover
    /// decision itself goes through Rust nd_should_failover.
    /// </summary>
    public bool IsRetryable => Kind switch
    {
        ErrorKind.Network => true,
        ErrorKind.InvalidResponse => false,
        ErrorKind.Http => StatusCode is 429 || (StatusCode is >= 500),
        _ => false,
    };

    /// <summary>Rust transcribe-kind code: 0 may fail over, anything else rethrows at once.</summary>
    public uint RustKind => 0;
}

/// <summary>Normalized transcription result parsed via the Rust transcript contract.</summary>
public sealed record TimedWordResult(string Word, double Start, double End);

public sealed record TranscriptionResult(string Text, IReadOnlyList<TimedWordResult> Words, string RawBody)
{
    public static TranscriptionResult Parse(string rawBody, string? transcriptPath)
    {
        var json = NanoEngine.TranscriptParse(rawBody, transcriptPath);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var text = root.TryGetProperty("text", out var t) ? t.GetString() ?? string.Empty : string.Empty;
        var words = new List<TimedWordResult>();
        if (root.TryGetProperty("words", out var w) && w.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in w.EnumerateArray())
            {
                var word = item.TryGetProperty("word", out var wo) ? wo.GetString() ?? string.Empty : string.Empty;
                var start = item.TryGetProperty("start", out var s) && s.TryGetDouble(out var sv) ? sv : 0.0;
                var end = item.TryGetProperty("end", out var e) && e.TryGetDouble(out var ev) ? ev : 0.0;
                words.Add(new TimedWordResult(word, start, end));
            }
        }
        return new TranscriptionResult(text, words, rawBody);
    }
}

/// <summary>Raw HTTP exchange for one STT attempt (testable without network).</summary>
public sealed record SttHttpResponse(int Status, IReadOnlyDictionary<string, string> Headers, byte[] Body);

/// <summary>Minimal transport seam: real HTTP in production, fakes in tests.</summary>
public interface ISttTransport
{
    Task<SttHttpResponse> SendAsync(
        string url,
        IReadOnlyDictionary<string, string> headers,
        byte[] body,
        string contentType,
        TimeSpan timeout,
        CancellationToken cancellationToken);
}

/// <summary>
/// Production HTTP transport over HttpClient. Applies only mechanical
/// proxy/transport rewrites (URL-as-path, Proxy-Authorization, gateway
/// header); provider/model request shape comes from the caller.
/// </summary>
public sealed class HttpSttTransport : ISttTransport, IDisposable
{
    private readonly HttpClient _client;
    private bool _disposed;

    public HttpSttTransport(HttpClient? client = null)
    {
        _client = client ?? new HttpClient();
    }

    public async Task<SttHttpResponse> SendAsync(
        string url,
        IReadOnlyDictionary<string, string> headers,
        byte[] body,
        string contentType,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linked.CancelAfter(timeout);
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        foreach (var kv in headers)
        {
            request.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
        }
        request.Content = new ByteArrayContent(body);
        request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
        HttpResponseMessage response;
        try
        {
            response = await _client.SendAsync(request, linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex) when (ex is not TranscribeError)
        {
            throw new TranscribeError(TranscribeError.ErrorKind.Network, $"STT transport failed: {ex.Message}");
        }
        using var _ = response;
        byte[] responseBody;
        try
        {
            responseBody = await response.Content.ReadAsByteArrayAsync(linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex) when (ex is not TranscribeError)
        {
            throw new TranscribeError(TranscribeError.ErrorKind.Network, $"STT transport failed: {ex.Message}");
        }
        var responseHeaders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var h in response.Headers)
        {
            responseHeaders[h.Key.ToLowerInvariant()] = string.Join(",", h.Value);
        }
        foreach (var h in response.Content.Headers)
        {
            responseHeaders[h.Key.ToLowerInvariant()] = string.Join(",", h.Value);
        }
        return new SttHttpResponse((int)response.StatusCode, responseHeaders, responseBody);
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _disposed = true;
            _client.Dispose();
        }
    }
}

/// <summary>Per-attempt diagnostic record (timings, sizes, outcome).</summary>
public sealed record SttAttemptLog(
    string ProviderId,
    string Model,
    string Url,
    long SentBytes,
    double ElapsedMs,
    bool Succeeded,
    string Error);

/// <summary>Aggregate diagnostics for one transcription operation.</summary>
public sealed class SttDiagnostics
{
    private readonly List<SttAttemptLog> _attempts = new();

    public IReadOnlyList<SttAttemptLog> Attempts => _attempts;

    public void Add(SttAttemptLog attempt) => _attempts.Add(attempt);

    public int AttemptCount => _attempts.Count;

    public int SuccessCount => _attempts.Count(a => a.Succeeded);

    public double TotalMs => _attempts.Sum(a => a.ElapsedMs);

    public string Summarize() =>
        $"attempts={AttemptCount} ok={SuccessCount} total_ms={TotalMs:F1}";
}
