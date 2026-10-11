using System.Text;

namespace NanoDictate.Core;

/// <summary>Final full-recording pass policy for chunked mode (mirrors macOS).</summary>
public enum ChunkedFinalPass
{
    Always,
    OnUncertainty,
    Never,
}

/// <summary>
/// Chunked (long-form) transcription: fixed-length batch chunks with
/// overlap (<c>nd_batch_plan</c>) → per-chunk transcription with one
/// provider (no cross-chunk failover routing) → stitching with dedup via
/// Rust <c>nd_text_join</c> → optional final full-recording pass.
/// Chunk boundaries and text joining stay in Rust; C# only sequences I/O.
/// </summary>
public sealed class ChunkedTranscriber
{
    private readonly SttClient _client;

    public ChunkedTranscriber(SttClient client)
    {
        _client = client;
    }

    public static ChunkedFinalPass ParseFinalPass(string value) => value switch
    {
        "always" => ChunkedFinalPass.Always,
        "never" => ChunkedFinalPass.Never,
        _ => ChunkedFinalPass.OnUncertainty,
    };

    /// <summary>
    /// Pure chunk-text stitching through Rust (no network). Used by tests
    /// and by the pipeline after per-chunk transcripts arrive.
    /// </summary>
    public static string Stitch(IReadOnlyList<string> chunkTexts) =>
        NanoEngine.TextJoin(chunkTexts);

    /// <summary>Whether a final full-recording pass is needed (pure decision).</summary>
    public static bool NeedsFinalPass(
        ChunkedFinalPass policy,
        IReadOnlyList<string> chunkTexts,
        bool hasFailedChunk)
    {
        return policy switch
        {
            ChunkedFinalPass.Always => chunkTexts.Count > 1 || hasFailedChunk,
            ChunkedFinalPass.Never => hasFailedChunk,
            _ => hasFailedChunk || chunkTexts.Any(t => DictationTextPolicy.IsEmptyResult(t)),
        };
    }

    public async Task<TranscriptionResult> TranscribeAsync(
        short[] samples,
        uint sampleRate,
        double maxSegmentSecs,
        double overlapSecs,
        string language,
        string? prompt,
        bool autoFailover,
        ChunkedFinalPass finalPass,
        TransportConfig transport,
        string proxyKey,
        SttDiagnostics? diagnostics,
        CancellationToken cancellationToken)
    {
        var chunks = NanoEngine.BatchPlan(samples.Length, sampleRate, maxSegmentSecs, overlapSecs);
        if (chunks.Length == 0)
        {
            var empty = await _client.TranscribeAsync(samples, sampleRate, language, prompt, autoFailover, transport, proxyKey, diagnostics, cancellationToken).ConfigureAwait(false);
            return empty;
        }
        var texts = new List<string>();
        var words = new List<TimedWordResult>();
        var failed = false;
        foreach (var chunk in chunks)
        {
            var slice = samples.Skip(chunk.BodyStart).Take(chunk.BodyEnd - chunk.BodyStart).ToArray();
            try
            {
                var result = await _client.TranscribeAsync(slice, sampleRate, language, prompt, false, transport, proxyKey, diagnostics, cancellationToken).ConfigureAwait(false);
                texts.Add(result.Text);
                words.AddRange(result.Words);
            }
            catch (TranscribeError)
            {
                failed = true;
                texts.Add(string.Empty);
            }
        }
        if (NeedsFinalPass(finalPass, texts, failed))
        {
            var full = await _client.TranscribeAsync(samples, sampleRate, language, prompt, autoFailover, transport, proxyKey, diagnostics, cancellationToken).ConfigureAwait(false);
            return full;
        }
        var stitched = Stitch(texts.Where(t => !string.IsNullOrEmpty(t)).ToList());
        return new TranscriptionResult(stitched, words, string.Empty);
    }
}

/// <summary>Realtime session configuration (mirrors macOS RealtimeSessionConfig).</summary>
public sealed record RealtimeSessionOptions(
    string Model,
    string Language,
    string? Prompt,
    IReadOnlyList<string> Keywords,
    uint SourceSampleRate)
{
    public static RealtimeSessionOptions Default(string model = "gpt-live-transcribe", uint sourceRate = 16000) =>
        new(model, string.Empty, null, Array.Empty<string>(), sourceRate);
}

/// <summary>Realtime session state (mirrors macOS RealtimeSessionState).</summary>
public enum RealtimeSessionState
{
    Idle,
    Connecting,
    Ready,
    Streaming,
    Committing,
    Closed,
    Failed,
    Cancelled,
}

/// <summary>Realtime transport seam (WebSocket in production, fakes in tests).</summary>
public interface IRealtimeTransport
{
    Task ConnectAsync(RealtimeSessionOptions options, CancellationToken cancellationToken);
    Task AppendPcm16Async(short[] pcm24kMono, CancellationToken cancellationToken);
    Task CommitAsync(CancellationToken cancellationToken);
    Task CloseAsync(CancellationToken cancellationToken);
    event Action<string>? Delta;
    event Action<string>? Completed;
    event Action<string>? Failed;
}

/// <summary>
/// Stateful realtime transcription session: streams 24 kHz mono PCM16
/// frames (resampled from the 16 kHz engine ingress) over one session.
/// Fail-closed: transport drops leave the session Failed and never fall
/// back to batch uploads silently. Deltas accumulate; the completed event
/// carries the final hypothesis.
/// </summary>
public sealed class RealtimeSession : IDisposable
{
    private readonly IRealtimeTransport _transport;
    private readonly RealtimeSessionOptions _options;
    private readonly StringBuilder _delta = new();
    private bool _disposed;

    public RealtimeSession(IRealtimeTransport transport, RealtimeSessionOptions options)
    {
        _transport = transport;
        _options = options;
        _transport.Delta += OnDelta;
        _transport.Completed += OnCompleted;
        _transport.Failed += OnFailed;
    }

    public RealtimeSessionState State { get; private set; } = RealtimeSessionState.Idle;

    public string? FinalText { get; private set; }

    public string? Failure { get; private set; }

    public string AccumulatedDelta
    {
        get
        {
            lock (_delta)
            {
                return _delta.ToString();
            }
        }
    }

    public async Task ConnectAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        if (State != RealtimeSessionState.Idle)
        {
            throw new NanoException(-1, $"realtime session is {State}, expected idle");
        }
        State = RealtimeSessionState.Connecting;
        try
        {
            await _transport.ConnectAsync(_options, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            State = RealtimeSessionState.Failed;
            Failure = ex.Message;
            throw new NanoException(-1, $"realtime connect failed: {ex.Message}");
        }
        State = RealtimeSessionState.Ready;
    }

    /// <summary>
    /// Appends 16 kHz engine samples: resampled to 24 kHz mono PCM16
    /// (linear interpolation, no filtering claims) and forwarded as one
    /// frame. Pure resampling math lives here as transport framing; VAD,
    /// gain, and segmentation policy stay in Rust.
    /// </summary>
    public async Task AppendAsync(short[] samples16k, CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        if (State != RealtimeSessionState.Ready && State != RealtimeSessionState.Streaming)
        {
            throw new NanoException(-1, $"realtime append in state {State}");
        }
        State = RealtimeSessionState.Streaming;
        var framed = Resample16kTo24k(samples16k, _options.SourceSampleRate);
        try
        {
            await _transport.AppendPcm16Async(framed, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            State = RealtimeSessionState.Failed;
            Failure = ex.Message;
            throw new NanoException(-1, $"realtime append failed: {ex.Message}");
        }
    }

    public async Task<string> CommitAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        if (State != RealtimeSessionState.Streaming && State != RealtimeSessionState.Ready)
        {
            throw new NanoException(-1, $"realtime commit in state {State}");
        }
        State = RealtimeSessionState.Committing;
        try
        {
            await _transport.CommitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            State = RealtimeSessionState.Failed;
            Failure = ex.Message;
            throw new NanoException(-1, $"realtime commit failed: {ex.Message}");
        }
        State = RealtimeSessionState.Closed;
        return FinalText ?? AccumulatedDelta;
    }

    public void Cancel()
    {
        if (State == RealtimeSessionState.Closed || State == RealtimeSessionState.Cancelled)
        {
            return;
        }
        State = RealtimeSessionState.Cancelled;
    }

    public static short[] Resample16kTo24k(short[] input, uint sourceRate)
    {
        if (sourceRate == 24000)
        {
            return (short[])input.Clone();
        }
        if (sourceRate != 16000)
        {
            throw new NanoException(-1, $"unsupported realtime source rate {sourceRate}; expected 16000 or 24000");
        }
        var outputLength = (int)((long)input.Length * 24000 / 16000);
        var output = new short[outputLength];
        for (var i = 0; i < outputLength; i++)
        {
            var position = (double)i * input.Length / outputLength;
            var index = (int)position;
            var fraction = position - index;
            var first = input[Math.Min(index, input.Length - 1)];
            var second = input[Math.Min(index + 1, input.Length - 1)];
            output[i] = (short)(first + (second - first) * fraction);
        }
        return output;
    }

    private void OnDelta(string text)
    {
        lock (_delta)
        {
            _delta.Append(text);
        }
    }

    private void OnCompleted(string text) => FinalText = text;

    private void OnFailed(string message)
    {
        State = RealtimeSessionState.Failed;
        Failure = message;
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(RealtimeSession));
        }
    }

    public void Dispose() => _disposed = true;
}
