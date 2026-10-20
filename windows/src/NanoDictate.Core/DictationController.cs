namespace NanoDictate.Core;

using System.Runtime.InteropServices;

/// <summary>Capture driver seam (production: <see cref="DictationCaptureService"/>).</summary>
public interface ICaptureDriver
{
    DictationState State { get; }

    /// <summary>
    /// Lock-free session-state snapshot for the keyboard hook. Defaults to
    /// <see cref="State"/>; production drivers override with a volatile read
    /// that never blocks on audio work.
    /// </summary>
    DictationState CachedState => State;
    bool IsRunning { get; }
    bool IsCaptureReady { get; }
    void Start(ulong? triggerNanos = null);
    PipelineStopResult Stop();
    void Cancel();
    void FinishTranscription();
}

public sealed class CaptureDriverAdapter : ICaptureDriver
{
    private readonly DictationCaptureService _inner;
    public CaptureDriverAdapter(DictationCaptureService inner) => _inner = inner;
    public DictationState State => _inner.State;
    public DictationState CachedState => _inner.CachedState;
    public bool IsRunning => _inner.IsRunning;
    public bool IsCaptureReady => _inner.IsCaptureReady;
    public void Start(ulong? triggerNanos = null) => _inner.Start(triggerNanos);
    public PipelineStopResult Stop() => _inner.Stop();
    public void Cancel() => _inner.Cancel();
    public void FinishTranscription() => _inner.FinishTranscription();
}

/// <summary>Insertion sink seam (production: direct + clipboard inserters).</summary>
public interface IInsertionSink
{
    void Insert(string text, InsertMethod method);
    void DeleteText(string insertedText);
    void DeleteGraphemes(int count);
    void PostEnter();
}

public sealed class InsertionSinkAdapter : IInsertionSink
{
    private readonly TextInserter _direct;
    private readonly ClipboardInsertService _clipboard;

    public InsertionSinkAdapter(TextInserter direct, ClipboardInsertService clipboard)
    {
        _direct = direct;
        _clipboard = clipboard;
    }

    public void Insert(string text, InsertMethod method)
    {
        if (method == InsertMethod.Clipboard)
        {
            _clipboard.InsertViaClipboard(text);
        }
        else
        {
            _direct.Insert(text);
        }
    }

    public void DeleteText(string insertedText) => _direct.DeleteText(insertedText);
    public void DeleteGraphemes(int count) => _direct.DeleteGraphemes(count);
    public void PostEnter() => _direct.PostReturn();
}

/// <summary>Review prompt seam (production: console read on a background thread).</summary>
public interface IReviewPrompt
{
    string? Ask(string text);
}

public sealed class FakeReviewPrompt : IReviewPrompt
{
    private readonly Queue<string?> _answers = new();
    public void Enqueue(string? answer) => _answers.Enqueue(answer);
    public string? Ask(string text) => _answers.Count > 0 ? _answers.Dequeue() : "y";
}

/// <summary>
/// Cancellable deferred Enter post. Ports macOS <c>ScheduledEnterPoster</c>:
/// Enter-stop schedules exactly one synthetic Enter 0.25 s after insertion so
/// the target app processes the text first; Escape cancels the pending post.
/// Generation-guarded so re-schedule supersedes and stale fires never run.
/// </summary>
public sealed class CancellableEnterPoster
{
    public Action? Action { get; set; }
    public TimeSpan Delay { get; set; } = TimeSpan.FromSeconds(0.25);

    private readonly object _gate = new();
    private ulong _generation;
    private Timer? _timer;

    public void Schedule()
    {
        Action? action;
        TimeSpan delay;
        ulong generation;
        lock (_gate)
        {
            CancelLocked();
            _generation++;
            generation = _generation;
            action = Action;
            delay = Delay;
            _timer = new Timer(_ => Fire(generation), null, delay, Timeout.InfiniteTimeSpan);
        }
    }

    public void Cancel()
    {
        lock (_gate)
        {
            CancelLocked();
            _generation++;
        }
    }

    /// <summary>Deterministic fire for tests (runs the action synchronously).</summary>
    public bool FireForTests()
    {
        Action? action;
        lock (_gate)
        {
            action = Action;
            CancelLocked();
            _generation++;
        }
        if (action is null)
        {
            return false;
        }
        action();
        return true;
    }

    private void Fire(ulong generation)
    {
        Action? action;
        lock (_gate)
        {
            if (generation != _generation)
            {
                return;
            }
            action = Action;
            _timer?.Dispose();
            _timer = null;
        }
        action?.Invoke();
    }

    private void CancelLocked()
    {
        _timer?.Dispose();
        _timer = null;
    }
}

/// <summary>Outcome of a microphone start attempt (for UI/telemetry).</summary>
public sealed record MicStartOutcome(bool Started, MicFailureKind? Failure, string? Guidance);

/// <summary>
/// Windows dictation controller: the interaction model around the shared
/// Rust product logic. Every policy decision delegates to Rust
/// (<see cref="RustTextPolicy"/>, <see cref="NanoEngine"/>, session/latch/
/// cooldown handles); C# only provides Windows-native I/O (hook events,
/// SendInput, clipboard, WASAPI errors, registry/tray/paths).
/// Mirrors the macOS agent cycle: double-Alt toggles (idle: undo-or-start,
/// recording: stop, transcribing: ignore), Escape cancels, Enter stops and
/// latches one synthetic Enter, insertions go direct or via clipboard, and
/// undo erases the last insertion inside the undo window.
/// </summary>
public sealed class DictationController : IGlobalHotkeyDelegate, IDisposable
{
    private readonly object _gate = new();
    private readonly ICaptureDriver _capture;
    private readonly IInsertionSink _insertions;
    private readonly LatchHandle _enterLatch = new();
    private readonly CooldownHandle _micCooldown;
    private readonly CancellableEnterPoster _enterPoster = new();
    private readonly Func<DateTime> _clock;
    private bool _disposed;
    private bool _cancelled;
    private ulong _recordingSeq;
    private ulong _pendingTranscriptionSeq;
    private CancellationTokenSource? _transcriptionCts;
    private string _lastInserted = string.Empty;
    private DateTime? _lastInsertedAt;

    public DictationController(
        ICaptureDriver capture,
        IInsertionSink insertions,
        Func<DateTime>? clock = null,
        double micErrorCooldownSecs = 5.0)
    {
        _capture = capture ?? throw new ArgumentNullException(nameof(capture));
        _insertions = insertions ?? throw new ArgumentNullException(nameof(insertions));
        _clock = clock ?? (() => DateTime.UtcNow);
        _micCooldown = new CooldownHandle(micErrorCooldownSecs);
        _enterPoster.Action = () => _insertions.PostEnter();
    }

    public InsertMethod InsertMethod { get; set; } = InsertMethod.Direct;

    public TimeSpan UndoWindow { get; set; } = TimeSpan.FromSeconds(2.0);

    public bool ReviewBeforeInsert { get; set; }

    public IReviewPrompt? ReviewPrompt { get; set; }

    public event Action<MicStartOutcome>? MicStartAttempted;

    public event Action<string>? Inserted;

    /// <summary>Fired when a stopped recording enters Processing (STT owns the cycle).</summary>
    public event Action<ulong>? ProcessingStarted;

    /// <summary>Fired on Escape/terminal cancel, independent of a settling Rust owner.</summary>
    public event Action? Cancelled;

    /// <summary>Same terminal cancel with the recording id, for stale-event filtering.</summary>
    public event Action<ulong>? CancelledWithRecordingId;

    /// <summary>
    /// Capture-stop callback: receives the stopped recording for
    /// transcription. Set by the host to forward
    /// <see cref="PipelineStopResult.Samples"/> to transcription and
    /// delivery via <see cref="CompleteWithTranscript"/>. Runs off the
    /// hotkey thread (fire-and-forget); null means stop-only (tests).
    /// The session identifier rejects stale results from a previous
    /// recording; the token is cancelled on Escape or when a new recording
    /// starts.
    /// </summary>
    public Func<IReadOnlyList<short>, CancellationToken, ulong, Task>? StopTranscriptionHandler { get; set; }

    public DictationState State => _capture.State;

    public bool HasPendingEnter
    {
        get
        {
            lock (_gate)
            {
                return _pendingEnter;
            }
        }
    }

    private bool _pendingEnter;
    /// <summary>
    /// Recording identifier whose <see cref="IInsertionSink.Insert"/> call is
    /// currently in flight, or null when no insertion is running. Escape uses
    /// the owner to tell the current recording's insertion (leave the session
    /// Transcribing so the inserted text can be rolled back) apart from a
    /// superseded recording's insertion (settle the current session instead of
    /// reading the stale owner flag).
    /// </summary>
    private ulong? _insertionRecordingId;

    /// <summary>
    /// Recordings cancelled while their own insertion was in flight. The
    /// delivery path completes the capture session after the insert returns
    /// and any inserted text is rolled back, unless a newer recording
    /// superseded the owner first.
    /// </summary>
    private readonly HashSet<ulong> _finishAfterInsert = new();

    // -- IGlobalHotkeyDelegate -------------------------------------------

    public void AltDoubleTapped()
    {
        var state = _capture.State;
        if (state == DictationState.Idle)
        {
            DateTime? lastAt;
            string last;
            lock (_gate)
            {
                lastAt = _lastInsertedAt;
                last = _lastInserted;
            }
            if (DictationTextPolicy.ShouldUndoInsteadOfStart(state, lastAt, _clock(), UndoWindow)
                && !string.IsNullOrEmpty(last))
            {
                UndoLastInsert();
                return;
            }
            StartCapture();
        }
        else if (state == DictationState.Recording)
        {
            StopAndAwaitTranscript();
        }
        // Transcribing: ignore (never confused with undo).
    }

    public void AltFirstTapDetected()
    {
        // Pre-arm hint only: no microphone capture (macOS parity).
    }

    public void AltPendingCancelled()
    {
        // Discard pre-armed state; nothing was captured.
    }

    public void CancelKeyPressed() => CancelCurrent();

    public void EnterKeyPressed()
    {
        var state = _capture.State;
        if (state == DictationState.Recording)
        {
            _enterLatch.Arm();
            lock (_gate)
            {
                _pendingEnter = true;
            }
            StopAndAwaitTranscript();
        }
        // Transcribing: no-op. Idle never reaches here per contract.
    }

    /// <summary>
    /// Hook-thread swallow decision. Uses the lock-free <see
    /// cref="ICaptureDriver.CachedState"/> snapshot so the low-level hook never
    /// blocks on audio conversion or VAD work holding the pipeline lock.
    /// </summary>
    public bool ShouldSwallowReturnKeyEvent() => _capture.CachedState != DictationState.Idle;

    // -- Capture ----------------------------------------------------------

    private void StartCapture()
    {
        lock (_gate)
        {
            _cancelled = false;
            _pendingEnter = false;
            _recordingSeq++;
            // A new recording supersedes any still-running transcription
            // from the previous recording: cancel it so its late result
            // cannot insert after this recording stops.
            _transcriptionCts?.Cancel();
            _transcriptionCts?.Dispose();
            _transcriptionCts = null;
        }
        _enterLatch.Cancel();
        _enterPoster.Cancel();
        try
        {
            _capture.Start(CaptureClock.Nanos);
            MicStartAttempted?.Invoke(new MicStartOutcome(true, null, null));
        }
        catch (Exception ex)
        {
            var kind = ex is NanoException nano
                ? MicFailureClassifier.Classify(nano)
                : ex is COMException com
                    ? MicFailureClassifier.Classify(com.HResult, ex.Message)
                    : MicFailureKind.Other;
            var nowSecs = (DateTime.UtcNow - DateTime.UnixEpoch).TotalSeconds;
            bool allow = true;
            try
            {
                allow = _micCooldown.Allow(nowSecs);
            }
            catch (NanoException)
            {
                allow = true;
            }
            var guidance = allow ? MicPrivacyGuide.MessageFor(kind) : string.Empty;
            MicStartAttempted?.Invoke(new MicStartOutcome(false, kind, guidance));
            throw;
        }
    }

    private void StopAndAwaitTranscript()
    {
        PipelineStopResult result;
        try
        {
            result = _capture.Stop();
        }
        catch
        {
            _capture.Cancel();
            throw;
        }
        var handler = StopTranscriptionHandler;
        if (handler is not null)
        {
            CancellationToken token;
            ulong sessionId;
            lock (_gate)
            {
                _transcriptionCts?.Dispose();
                _transcriptionCts = new CancellationTokenSource();
                token = _transcriptionCts.Token;
                if (_recordingSeq == 0)
                {
                    // The capture was started outside the controller
                    // (tests/direct driver use): assign the first session so
                    // the stop callback still carries a non-zero identifier.
                    _recordingSeq = 1;
                }
                _pendingTranscriptionSeq = _recordingSeq;
                sessionId = _pendingTranscriptionSeq;
            }
            // Native presentation gets its own completion event: the HUD
            // must enter Processing on stop, not by inferring Rust state.
            ProcessingStarted?.Invoke(sessionId);
            var samples = result.Samples;
            _ = Task.Run(() => handler(samples, token, sessionId));
        }
    }

    /// <summary>
    /// Delivers an STT transcript after <see cref="StopAndAwaitTranscript"/>.
    /// Applies the Rust retry gate, empty guard, review gate, insertion, undo
    /// window, Enter latch, and overlay-hide rule. Returns true when text was
    /// inserted. When <paramref name="recordingId"/> is non-zero, results
    /// from a previous recording are rejected so a late transcription cannot
    /// insert after a newer recording started.
    /// </summary>
    public bool CompleteWithTranscript(string transcript, ulong processingSession = 0, ulong session = 0, ulong recordingId = 0)
    {
        lock (_gate)
        {
            if (recordingId != 0 && recordingId != _recordingSeq)
            {
                return false;
            }
        }
        var state = _capture.State;
        if (!DictationTextPolicy.ShouldDeliverResult(IsCancelled(), state == DictationState.Transcribing || state == DictationState.Idle))
        {
            return false;
        }
        if (RustTextPolicy.ShouldDropRetry(state, processingSession, session) && processingSession != 0 && session != 0)
        {
            return false;
        }
        if (DictationTextPolicy.IsEmptyResult(transcript))
        {
            FinishTranscriptionIfCurrent(recordingId);
            return false;
        }
        if (ReviewBeforeInsert)
        {
            // An explicitly enabled review requirement must never be silently
            // auto-approved when no review UI could be shown. Missing or
            // failing prompts are fail-closed: finish the session, insert
            // nothing, and let the caller surface the outcome.
            var prompt = ReviewPrompt;
            if (prompt is null)
            {
                FinishTranscriptionIfCurrent(recordingId);
                return false;
            }
            string? line;
            try
            {
                line = prompt.Ask(transcript);
            }
            catch
            {
                line = null;
            }
            // The prompt can block while Escape cancels recording A or a new
            // recording B starts. Re-validate under _gate before touching
            // insertion or capture state so a stale approval cannot insert
            // A's text or finish B's capture.
            if (IsDeliverySuperseded(recordingId))
            {
                return false;
            }
            bool insert;
            try
            {
                insert = RustTextPolicy.ReviewDecide(line);
            }
            catch (NanoException)
            {
                if (IsDeliverySuperseded(recordingId))
                {
                    return false;
                }
                FinishTranscriptionIfCurrent(recordingId);
                return false;
            }
            if (!insert)
            {
                if (IsDeliverySuperseded(recordingId))
                {
                    return false;
                }
                // Atomically claim the decline under _gate so a newer
                // recording B starting concurrently keeps its own pending
                // Enter and capture session.
                lock (_gate)
                {
                    if (IsDeliverySupersededLocked(recordingId))
                    {
                        return false;
                    }
                    _pendingEnter = false;
                    _capture.FinishTranscription();
                }
                _enterLatch.Cancel();
                _enterPoster.Cancel();
                return false;
            }
        }
        // Final delivery decision, synchronized with CancelCurrent and
        // StartCapture (both hold _gate). A check before the review prompt
        // is not sufficient because the prompt can wait. Claim the insertion
        // window in the same critical section, tagged with the owning
        // recording, so Escape can tell this recording's in-flight insertion
        // (defer completion for rollback) from a superseded recording's
        // insertion (settle the current session immediately).
        ulong insertionOwner;
        lock (_gate)
        {
            if (IsDeliverySupersededLocked(recordingId))
            {
                return false;
            }
            insertionOwner = _recordingSeq;
            _insertionRecordingId = insertionOwner;
        }
        try
        {
            _insertions.Insert(transcript, InsertMethod);
        }
        catch
        {
            // Only the current recording may clear shared delivery state
            // and complete the capture session; a stale failure must not
            // clear B's pending Enter or finish B's session.
            bool current;
            lock (_gate)
            {
                if (_insertionRecordingId == insertionOwner)
                {
                    _insertionRecordingId = null;
                }
                var deferred = _finishAfterInsert.Remove(insertionOwner);
                if (IsDeliverySupersededLocked(recordingId))
                {
                    current = false;
                    // A cancel deferred completion until this insert returned;
                    // settle the session now that the rollback is done unless a
                    // newer recording already superseded the owner.
                    if (deferred && insertionOwner == _recordingSeq)
                    {
                        _capture.FinishTranscription();
                    }
                }
                else
                {
                    _pendingEnter = false;
                    _capture.FinishTranscription();
                    current = true;
                }
            }
            if (current)
            {
                _enterLatch.Cancel();
            }
            throw;
        }
        // Commit insertion and capture completion atomically with the
        // cancellation/recording gate: the recording-identity check and
        // FinishTranscription run in one _gate critical section so Escape
        // or a newer recording B cannot interleave between the decision
        // and the side effect. A stale result rolls back its own insert
        // (best effort) without touching B's capture session or undo state.
        bool staleAfterInsert;
        bool deferredFinish;
        bool postEnter;
        lock (_gate)
        {
            if (_insertionRecordingId == insertionOwner)
            {
                _insertionRecordingId = null;
            }
            deferredFinish = _finishAfterInsert.Remove(insertionOwner);
            if (IsDeliverySupersededLocked(recordingId))
            {
                staleAfterInsert = true;
                deferredFinish = deferredFinish && insertionOwner == _recordingSeq;
                postEnter = false;
            }
            else
            {
                staleAfterInsert = false;
                deferredFinish = false;
                _lastInserted = transcript;
                _lastInsertedAt = _clock();
                _capture.FinishTranscription();
                postEnter = _pendingEnter;
                _pendingEnter = false;
            }
        }
        if (staleAfterInsert)
        {
            try
            {
                _insertions.DeleteText(transcript);
            }
            catch
            {
            }
            // Deferred cancel: complete only after the insert has been rolled
            // back, re-checking that no newer recording superseded the owner
            // while the rollback ran.
            if (deferredFinish)
            {
                lock (_gate)
                {
                    if (insertionOwner == _recordingSeq)
                    {
                        _capture.FinishTranscription();
                    }
                }
            }
            return false;
        }
        Inserted?.Invoke(transcript);
        if (postEnter && _enterLatch.Consume())
        {
            _enterPoster.Schedule();
        }
        else
        {
            _enterLatch.Cancel();
        }
        return true;
    }

    /// <summary>
    /// Escape: cancels capture, the Enter latch, and any scheduled Enter.
    ///
    /// A Recording session ends through Rust <c>Cancelled</c>. A stopped
    /// session (Transcribing) is already past that event's Recording-only
    /// contract, so its owner completes it with <c>TranscriptionDone</c>
    /// instead — the same routing the macOS agent uses. The one exception is
    /// an insertion already in flight: the session stays Transcribing until
    /// that delivery returns so the stale text can be rolled back first, then
    /// the delivery path completes it (when no newer recording superseded it).
    /// The cancellation flag remains authoritative for every late result.
    /// </summary>
    public void CancelCurrent() => CancelCore(0, requireActive: false);

    /// <summary>
    /// Cancels <paramref name="recordingId"/> only when it is still the
    /// controller's active recording. The identity check, the cancellation
    /// claim, the capture transition, and the capture teardown all run under
    /// <c>_gate</c> — the same gate used by recording start and the delivery
    /// commit — so a committed delivery or a replacement recording is never
    /// cancelled by a late watchdog. Returns false when the recording already
    /// completed or a newer recording owns the controller.
    /// </summary>
    public bool TryCancelRecording(ulong recordingId)
    {
        if (recordingId == 0)
        {
            return false;
        }
        return CancelCore(recordingId, requireActive: true);
    }

    private bool CancelCore(ulong recordingId, bool requireActive)
    {
        bool wasActive;
        ulong cancelledRecordingId;
        lock (_gate)
        {
            if (recordingId != 0 && recordingId != _recordingSeq)
            {
                return false;
            }
            wasActive = _capture.State != DictationState.Idle;
            if (requireActive && !wasActive)
            {
                // The delivery already committed (or the session otherwise
                // ended); a watchdog must not turn it into a timeout.
                return false;
            }
            cancelledRecordingId = _recordingSeq;
            _cancelled = true;
            _pendingEnter = false;
            // Cancel any pending transcription so its late result cannot
            // insert; the cancelled flag remains authoritative for late STT.
            _transcriptionCts?.Cancel();
            try
            {
                if (_capture.State == DictationState.Transcribing)
                {
                    if (_insertionRecordingId == _recordingSeq)
                    {
                        // This recording's own insertion is in flight: keep
                        // the session Transcribing until the insert returns so
                        // the stale text can be rolled back first, and record
                        // the deferred completion for the delivery path.
                        _finishAfterInsert.Add(_recordingSeq);
                    }
                    else
                    {
                        // Terminal cancel during processing: move
                        // Transcribing -> Idle so a new dictation can start
                        // immediately, without changing the portable Rust
                        // contract (Cancelled stays Recording-only). Done under
                        // _gate so StartCapture cannot interleave between the
                        // decision and the side effect.
                        _capture.FinishTranscription();
                    }
                }
            }
            catch
            {
                // Best effort: the cancelled flag still drops late results.
            }
            // Latch, scheduled Enter, and capture teardown are scoped to this
            // claim: running them under _gate prevents a replacement recording
            // from starting between the identity check and the side effects.
            _enterLatch.Cancel();
            _enterPoster.Cancel();
            try
            {
                _capture.Cancel();
            }
            catch
            {
                // Best effort: the cancelled flag is authoritative for late STT.
            }
        }
        if (wasActive)
        {
            // Terminal HUD event: it is bounded independently of a Rust
            // session that may still be Transcribing while rollback settles.
            // The id lets the HUD ignore a cancel that raced a newer recording.
            Cancelled?.Invoke();
            CancelledWithRecordingId?.Invoke(cancelledRecordingId);
        }
        return true;
    }

    private bool IsCancelled()
    {
        lock (_gate)
        {
            return _cancelled;
        }
    }

    /// <summary>
    /// Final delivery gate, synchronized with <see cref="CancelCurrent"/>
    /// and <see cref="StartCapture"/> (both hold <c>_gate</c>). Returns true
    /// when the transcript must be dropped without touching insertion or
    /// capture state: the recording is stale, was cancelled, or its
    /// transcription was superseded.
    /// </summary>
    private bool IsDeliverySuperseded(ulong recordingId)
    {
        lock (_gate)
        {
            return IsDeliverySupersededLocked(recordingId);
        }
    }

    /// <summary>
    /// Caller holds <c>_gate</c>. Same gate as <see cref="IsDeliverySuperseded"/>
    /// without re-locking, for use inside atomic commit sections.
    /// </summary>
    private bool IsDeliverySupersededLocked(ulong recordingId)
    {
        if (recordingId != 0 && recordingId != _recordingSeq)
        {
            return true;
        }
        if (_cancelled)
        {
            return true;
        }
        if (recordingId != 0 && _transcriptionCts?.IsCancellationRequested == true)
        {
            return true;
        }
        return false;
    }

    /// <summary>
    /// Completes the capture session only when <paramref name="recordingId"/>
    /// is still current. The identity check and <c>FinishTranscription</c>
    /// run in one <c>_gate</c> critical section (controller lock before the
    /// pipeline lock, matching <see cref="CancelCurrent"/>) so Escape or a
    /// newer recording cannot interleave between the decision and the side
    /// effect. Returns true when the session was finished.
    /// </summary>
    private bool FinishTranscriptionIfCurrent(ulong recordingId)
    {
        lock (_gate)
        {
            if (IsDeliverySupersededLocked(recordingId))
            {
                return false;
            }
            _capture.FinishTranscription();
            return true;
        }
    }

    private void UndoLastInsert()
    {
        string last;
        lock (_gate)
        {
            last = _lastInserted;
            _lastInserted = string.Empty;
            _lastInsertedAt = null;
        }
        if (!string.IsNullOrEmpty(last))
        {
            _insertions.DeleteText(last);
        }
    }

    public bool OverlayShouldHide() => RustTextPolicy.OverlayShouldHide(_capture.State);

    /// <summary>True after Escape/user cancel until the next cycle starts.</summary>
    public bool IsCancelRequested
    {
        get { lock (_gate) { return _cancelled; } }
    }

    /// <summary>Current recording sequence, used to scope native presentation events.</summary>
    public ulong CurrentRecordingId
    {
        get { lock (_gate) { return _recordingSeq; } }
    }

    public void Dispose()
    {
        CancellationTokenSource? cts;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            cts = _transcriptionCts;
            _transcriptionCts = null;
        }
        try
        {
            cts?.Cancel();
        }
        catch
        {
        }
        cts?.Dispose();
        _enterPoster.Cancel();
        _enterLatch.Dispose();
        _micCooldown.Dispose();
    }
}
