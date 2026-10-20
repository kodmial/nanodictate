using System.Runtime.InteropServices;
using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

internal sealed class FakeCaptureDriver : ICaptureDriver
{
    private readonly SessionHandle _session = new();
    private ulong _generation;
    private bool _live;

    public DictationState State => _session.State;
    public bool IsRunning => _live;
    public bool IsCaptureReady => _live && _session.IsCaptureReady;
    public int Cancels;
    public int Starts;
    public bool ThrowOnStop;

    public void Start(ulong? triggerNanos = null)
    {
        _generation = _session.Start();
        _session.OnEvent(SessionEvent.EngineStarted, _generation);
        _live = true;
        Starts++;
    }

    public void MakeReady()
    {
        _session.OnEvent(SessionEvent.FirstBuffer, _generation);
    }

    public PipelineStopResult Stop()
    {
        _session.OnEvent(SessionEvent.StopRequested, _generation);
        _live = false;
        if (ThrowOnStop)
        {
            throw new InvalidOperationException("capture stop failed");
        }
        return new PipelineStopResult(
            new short[] { 1, 2, 3 }, Array.Empty<NanoEngine.LiveSegment>(), CaptureMetrics.Empty);
    }

    public void Cancel()
    {
        Cancels++;
        _session.OnEvent(SessionEvent.Cancelled, _generation);
        _live = false;
    }

    public void FinishTranscription() => _session.OnEvent(SessionEvent.TranscriptionDone, _generation);
}

internal sealed class FakeInsertionSink : IInsertionSink
{
    public readonly List<(string Text, InsertMethod Method)> Inserts = new();
    public int DeletedGraphemes;
    public int Enters;
    public void Insert(string text, InsertMethod method) => Inserts.Add((text, method));
    public void DeleteText(string insertedText) => DeletedGraphemes += TextChunker.CountTextElements(insertedText);
    public void DeleteGraphemes(int count) => DeletedGraphemes += count;
    public void PostEnter() => Enters++;
}

internal sealed class ThrowingInsertionSink : IInsertionSink
{
    public void Insert(string text, InsertMethod method) => throw new NanoException(-1, "SendInput failed to deliver events");
    public void DeleteText(string insertedText) { }
    public void DeleteGraphemes(int count) { }
    public void PostEnter() { }
}

internal sealed class ComFailingCaptureDriver : ICaptureDriver
{
    public DictationState State => DictationState.Idle;
    public bool IsRunning => false;
    public bool IsCaptureReady => false;
    public void Start(ulong? triggerNanos = null) =>
        throw new COMException("COM activation failed", unchecked((int)0x80070005));
    public PipelineStopResult Stop() => throw new NotSupportedException();
    public void Cancel() { }
    public void FinishTranscription() { }
}

/// <summary>
/// Controller workflows: activation, cancel, insert, undo, Enter latch.
/// All policy branches delegate to Rust; fakes prove the wiring.
/// </summary>
public sealed class DictationControllerTests
{
    [Fact]
    public void DoubleAltInRecordingStopsAndTranscriptInserts()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Transcribing, capture.State);
        Assert.True(controller.CompleteWithTranscript("hello world"));
        Assert.Single(sink.Inserts);
        Assert.Equal(DictationState.Idle, capture.State);
    }

    [Fact]
    public async Task StopForwardsSamplesToTranscriptionHandler()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        IReadOnlyList<short>? forwarded = null;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (samples, _, _) =>
        {
            forwarded = samples;
            done.SetResult();
            return Task.CompletedTask;
        };
        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        await done.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.NotNull(forwarded);
        Assert.Equal(new short[] { 1, 2, 3 }, forwarded!);
    }

    [Fact]
    public async Task CancelCurrentCancelsPendingTranscription()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        CancellationToken capturedToken = default;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (samples, token, _) =>
        {
            capturedToken = token;
            done.SetResult();
            return Task.CompletedTask;
        };
        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        await done.Task.WaitAsync(TimeSpan.FromSeconds(5));
        controller.CancelKeyPressed();
        Assert.True(capturedToken.IsCancellationRequested);
    }

    [Fact]
    public async Task StopRaisesProcessingAndCancelRaisesTerminalOnlyWhenActive()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        ulong processingId = 0;
        var processing = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = 0;
        ulong cancelledId = 0;
        controller.ProcessingStarted += id =>
        {
            processingId = id;
            processing.SetResult();
        };
        controller.Cancelled += () => cancelled++;
        controller.CancelledWithRecordingId += id => cancelledId = id;
        controller.StopTranscriptionHandler = (_, _, _) => Task.CompletedTask;

        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        await processing.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.NotEqual(0ul, processingId);
        Assert.Equal(0, cancelled);

        controller.CancelKeyPressed();
        Assert.Equal(1, cancelled);
        Assert.Equal(processingId, cancelledId);
        controller.CancelKeyPressed();
        Assert.Equal(1, cancelled);
    }

    [Fact]
    public void FailedStopSettlesSessionAndRaisesTerminalEvent()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        controller.StopTranscriptionHandler = (_, _, _) => Task.CompletedTask;
        var cancelled = 0;
        ulong cancelledId = 0;
        controller.Cancelled += () => cancelled++;
        controller.CancelledWithRecordingId += id => cancelledId = id;

        controller.AltDoubleTapped();
        capture.MakeReady();
        var recordingId = controller.CurrentRecordingId;
        Assert.NotEqual(0ul, recordingId);
        capture.ThrowOnStop = true;

        Assert.Throws<InvalidOperationException>(() => controller.AltDoubleTapped());
        Assert.Equal(DictationState.Idle, capture.State);
        Assert.Equal(1, cancelled);
        Assert.Equal(recordingId, cancelledId);
        Assert.True(controller.IsCancelRequested);
    }

    [Fact]
    public void TryCancelRecordingRejectsCommittedDelivery()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        controller.StopTranscriptionHandler = (_, _, _) => Task.CompletedTask;
        controller.AltDoubleTapped();
        capture.MakeReady();
        controller.AltDoubleTapped();
        var recordingId = controller.CurrentRecordingId;
        Assert.NotEqual(0ul, recordingId);
        Assert.True(controller.CompleteWithTranscript("committed", recordingId: recordingId));

        Assert.False(controller.TryCancelRecording(recordingId));
        Assert.False(controller.IsCancelRequested);
        Assert.Equal(new[] { "committed" }, sink.Inserts.Select(i => i.Text));
    }

    [Fact]
    public void TryCancelRecordingRejectsReplacementRecording()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        controller.StopTranscriptionHandler = (_, _, _) => Task.CompletedTask;
        controller.AltDoubleTapped();
        capture.MakeReady();
        controller.AltDoubleTapped();
        var previousId = controller.CurrentRecordingId;
        Assert.NotEqual(0ul, previousId);
        Assert.False(controller.CompleteWithTranscript(string.Empty, recordingId: previousId));

        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        Assert.False(controller.TryCancelRecording(previousId));
        Assert.False(controller.IsCancelRequested);
        Assert.Equal(DictationState.Recording, capture.State);
    }

    [Fact]
    public void ActiveRecordingCanBeCancelledByRecordingId()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        controller.AltDoubleTapped();
        var recordingId = controller.CurrentRecordingId;

        Assert.True(controller.TryCancelRecording(recordingId));
        Assert.True(controller.IsCancelRequested);
        Assert.Equal(DictationState.Idle, capture.State);
        Assert.Equal(1, capture.Cancels);
    }

    [Fact]
    public async Task ReviewApprovalAfterRecordingScopedCancellationDoesNotInsert()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        var prompt = new BlockingReviewPrompt();
        using var controller = new DictationController(capture, sink)
        {
            ReviewBeforeInsert = true,
            ReviewPrompt = prompt,
        };
        controller.StopTranscriptionHandler = (_, _, _) => Task.CompletedTask;
        controller.AltDoubleTapped();
        controller.AltDoubleTapped();
        var recordingId = controller.CurrentRecordingId;

        var delivery = Task.Run(() => controller.CompleteWithTranscript("late", recordingId: recordingId));
        Assert.True(prompt.Entered.Wait(TimeSpan.FromSeconds(5)));
        Assert.True(controller.TryCancelRecording(recordingId));
        prompt.Release.Set();

        Assert.False(await delivery.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Empty(sink.Inserts);
    }

    [Fact]
    public async Task StaleRecordingResultIsRejectedAfterNewRecordingStarts()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        ulong stoppedId = 0;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (samples, _, id) =>
        {
            stoppedId = id;
            done.SetResult();
            return Task.CompletedTask;
        };
        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        await done.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.NotEqual(0ul, stoppedId);
        // Finish A so the session returns to idle, then start B before
        // A's late transcription result arrives. B supersedes A.
        Assert.False(controller.CompleteWithTranscript(string.Empty, recordingId: stoppedId));
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        Assert.False(controller.CompleteWithTranscript("stale A", recordingId: stoppedId));
        Assert.Empty(sink.Inserts);
    }

    [Fact]
    public void StaleEmptyResultDoesNotFinishNewRecording()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        ulong stoppedId = 0;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (_, _, id) =>
        {
            stoppedId = id;
            done.SetResult();
            return Task.CompletedTask;
        };
        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        Assert.True(done.Task.Wait(TimeSpan.FromSeconds(5)));
        Assert.False(controller.CompleteWithTranscript(string.Empty, recordingId: stoppedId));
        Assert.Equal(DictationState.Idle, capture.State);
        // Start B, then deliver stale A empty: B must stay Recording.
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        Assert.False(controller.CompleteWithTranscript(string.Empty, recordingId: stoppedId));
        Assert.Equal(DictationState.Recording, capture.State);
    }

    [Fact]
    public void StaleSuccessDoesNotFinishNewRecording()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        ulong stoppedId = 0;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (_, _, id) =>
        {
            stoppedId = id;
            done.SetResult();
            return Task.CompletedTask;
        };
        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        Assert.True(done.Task.Wait(TimeSpan.FromSeconds(5)));
        Assert.False(controller.CompleteWithTranscript(string.Empty, recordingId: stoppedId));
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        Assert.False(controller.CompleteWithTranscript("stale A", recordingId: stoppedId));
        Assert.Empty(sink.Inserts);
        Assert.Equal(DictationState.Recording, capture.State);
    }

    private sealed class BlockingInsertionSink : IInsertionSink
    {
        public readonly List<string> Inserts = new();
        public int Deletes;
        public readonly ManualResetEventSlim EnteredInsert = new(false);
        public readonly ManualResetEventSlim ReleaseInsert = new(false);
        public void Insert(string text, InsertMethod method)
        {
            lock (Inserts)
            {
                Inserts.Add(text);
            }
            EnteredInsert.Set();
            ReleaseInsert.Wait(TimeSpan.FromSeconds(5));
        }
        public void DeleteText(string insertedText) => Interlocked.Increment(ref Deletes);
        public void DeleteGraphemes(int count) { }
        public void PostEnter() { }
    }

    [Fact]
    public async Task CancelNewRecordingDuringBlockedStaleInsertFinishesNewSession()
    {
        var capture = new FakeCaptureDriver();
        var sink = new BlockingInsertionSink();
        using var controller = new DictationController(capture, sink);
        ulong stoppedId = 0;
        var stopCount = 0;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (_, _, id) =>
        {
            if (Interlocked.Increment(ref stopCount) == 1)
            {
                stoppedId = id;
                stopped.SetResult();
            }
            return Task.CompletedTask;
        };
        controller.AltDoubleTapped();
        controller.AltDoubleTapped();
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(DictationState.Transcribing, capture.State);

        // Recording A's insert blocks. A's session is settled externally, then
        // recording B starts and stops. Escape during B must settle B's session
        // rather than reading A's stale in-flight insertion flag.
        var delivery = Task.Run(() => controller.CompleteWithTranscript("A", recordingId: stoppedId));
        Assert.True(sink.EnteredInsert.Wait(TimeSpan.FromSeconds(5)));
        capture.FinishTranscription();
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Transcribing, capture.State);

        controller.CancelKeyPressed();
        Assert.Equal(DictationState.Idle, capture.State);

        sink.ReleaseInsert.Set();
        Assert.False(await delivery.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(1, sink.Deletes);
        Assert.Equal(DictationState.Idle, capture.State);
    }

    [Fact]
    public async Task CancelledDeliveryDuringInsertRollsBackThenFinishesSession()
    {
        var capture = new FakeCaptureDriver();
        var sink = new BlockingInsertionSink();
        using var controller = new DictationController(capture, sink);
        ulong stoppedId = 0;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (_, _, id) =>
        {
            stoppedId = id;
            stopped.SetResult();
            return Task.CompletedTask;
        };
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        controller.AltDoubleTapped();
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(DictationState.Transcribing, capture.State);
        // Delivery blocks inside Insert; Escape cancels while blocked.
        var delivery = Task.Run(() => controller.CompleteWithTranscript("cancelled A", recordingId: stoppedId));
        Assert.True(sink.EnteredInsert.Wait(TimeSpan.FromSeconds(5)));
        controller.CancelKeyPressed();
        sink.ReleaseInsert.Set();
        var delivered = await delivery.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(delivered);
        // The stale insert is rolled back, then the deferred cancel settles
        // the session through TranscriptionDone.
        Assert.Equal(1, sink.Deletes);
        Assert.Equal(DictationState.Idle, capture.State);
    }

    [Fact]
    public async Task CancelWhileProcessingFinishesSessionDropsLateResultAndAllowsRestart()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        ulong stoppedId = 0;
        CancellationToken capturedToken = default;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (_, token, id) =>
        {
            capturedToken = token;
            stoppedId = id;
            stopped.SetResult();
            return Task.CompletedTask;
        };
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        controller.AltDoubleTapped();
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(DictationState.Transcribing, capture.State);
        Assert.NotEqual(0ul, stoppedId);

        // Escape during processing is terminal: the stopped session is
        // completed through TranscriptionDone (Cancelled is Recording-only in
        // Rust), so a new dictation can start immediately.
        controller.CancelKeyPressed();
        Assert.True(capturedToken.IsCancellationRequested);
        Assert.Equal(DictationState.Idle, capture.State);
        Assert.False(controller.CompleteWithTranscript("late A", recordingId: stoppedId));
        Assert.Empty(sink.Inserts);

        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        Assert.Equal(2, capture.Starts);
    }

    private sealed class BlockingReviewPrompt : IReviewPrompt
    {
        public readonly ManualResetEventSlim Entered = new(false);
        public readonly ManualResetEventSlim Release = new(false);
        public string? Ask(string text)
        {
            Entered.Set();
            Release.Wait(TimeSpan.FromSeconds(5));
            return "y";
        }
    }

    [Fact]
    public async Task CancelWhileReviewPendingDropsDecisionAndFinishesSession()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        var prompt = new BlockingReviewPrompt();
        using var controller = new DictationController(capture, sink)
        {
            ReviewBeforeInsert = true,
            ReviewPrompt = prompt,
        };
        ulong stoppedId = 0;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (_, _, id) =>
        {
            stoppedId = id;
            stopped.SetResult();
            return Task.CompletedTask;
        };
        controller.AltDoubleTapped();
        controller.AltDoubleTapped();
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(DictationState.Transcribing, capture.State);

        var delivery = Task.Run(() => controller.CompleteWithTranscript("review A", recordingId: stoppedId));
        Assert.True(prompt.Entered.Wait(TimeSpan.FromSeconds(5)));
        controller.CancelKeyPressed();
        Assert.Equal(DictationState.Idle, capture.State);
        prompt.Release.Set();
        Assert.False(await delivery.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Empty(sink.Inserts);
    }

    [Fact]
    public void CancelDuringRecordingStillUsesRecordingTerminalEvent()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        controller.CancelKeyPressed();
        Assert.Equal(1, capture.Cancels);
        Assert.Equal(DictationState.Idle, capture.State);
        Assert.False(controller.CompleteWithTranscript("late recording"));
        Assert.Empty(sink.Inserts);
    }

    [Fact]
    public void StaleReviewDeclineDoesNotFinishNewRecording()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink)
        {
            ReviewBeforeInsert = true,
            ReviewPrompt = new FakeReviewPrompt(),
        };
        ulong stoppedId = 0;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        controller.StopTranscriptionHandler = (_, _, id) =>
        {
            stoppedId = id;
            done.SetResult();
            return Task.CompletedTask;
        };
        capture.Start();
        capture.MakeReady();
        controller.AltDoubleTapped();
        Assert.True(done.Task.Wait(TimeSpan.FromSeconds(5)));
        Assert.False(controller.CompleteWithTranscript(string.Empty, recordingId: stoppedId));
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Recording, capture.State);
        ((FakeReviewPrompt)controller.ReviewPrompt).Enqueue("n");
        Assert.False(controller.CompleteWithTranscript("stale A", recordingId: stoppedId));
        Assert.Equal(DictationState.Recording, capture.State);
    }

    [Fact]
    public void EscapeCancelsAndDropsLateTranscript()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        capture.Start();
        controller.CancelKeyPressed();
        Assert.Equal(1, capture.Cancels);
        Assert.False(controller.CompleteWithTranscript("late text"));
        Assert.Empty(sink.Inserts);
    }

    [Fact]
    public void EmptyTranscriptInsertsNothing()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        capture.Start();
        controller.AltDoubleTapped();
        Assert.Equal(DictationState.Transcribing, capture.State);
        Assert.False(controller.CompleteWithTranscript("   ...   "));
        Assert.Empty(sink.Inserts);
        // Empty/failed STT is a terminal result: no insertion, no Enter, and
        // the Rust session returns to Idle through TranscriptionDone.
        Assert.Equal(DictationState.Idle, capture.State);
        Assert.Equal(0, sink.Enters);
    }

    [Fact]
    public void UndoWithinWindowDeletesLastInsertInsteadOfStarting()
    {
        var now = new DateTime(2026, 10, 11, 12, 0, 0, DateTimeKind.Utc);
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink, () => now);
        capture.Start();
        controller.AltDoubleTapped();
        Assert.True(controller.CompleteWithTranscript("hello"));
        Assert.Equal(0, capture.Starts - 1);
        controller.AltDoubleTapped();
        Assert.Equal(TextChunker.CountTextElements("hello"), sink.DeletedGraphemes);
        Assert.Equal(1, capture.Starts);
    }

    [Fact]
    public void EnterArmsLatchAndSchedulesOneSyntheticEnter()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        capture.Start();
        controller.EnterKeyPressed();
        Assert.True(controller.HasPendingEnter || capture.State == DictationState.Transcribing);
        Assert.True(controller.CompleteWithTranscript("send this"));
        Assert.Equal(1, sink.Inserts.Count);
    }

    [Fact]
    public void ReviewCancelSkipsInsertion()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink)
        {
            ReviewBeforeInsert = true,
            ReviewPrompt = new FakeReviewPrompt(),
        };
        ((FakeReviewPrompt)controller.ReviewPrompt).Enqueue("n");
        capture.Start();
        controller.AltDoubleTapped();
        Assert.False(controller.CompleteWithTranscript("needs review"));
        Assert.Empty(sink.Inserts);
    }

    [Fact]
    public void InsertionFailureFinishesTranscriptionAndClearsEnter()
    {
        var capture = new FakeCaptureDriver();
        var sink = new ThrowingInsertionSink();
        using var controller = new DictationController(capture, sink);
        capture.Start();
        controller.EnterKeyPressed();
        Assert.Equal(DictationState.Transcribing, capture.State);
        Assert.True(controller.HasPendingEnter);
        Assert.Throws<NanoException>(() => controller.CompleteWithTranscript("hello"));
        Assert.Equal(DictationState.Idle, capture.State);
        Assert.False(controller.HasPendingEnter);
        Assert.False(controller.ShouldSwallowReturnKeyEvent());
    }

    [Fact]
    public void ComActivationFailureMapsHResultToDeniedGuidance()
    {
        var capture = new ComFailingCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        MicStartOutcome? outcome = null;
        controller.MicStartAttempted += o => outcome = o;
        Assert.Throws<COMException>(() => controller.AltDoubleTapped());
        Assert.NotNull(outcome);
        Assert.False(outcome!.Started);
        Assert.Equal(MicFailureKind.Denied, outcome.Failure);
        Assert.Contains("microphone", outcome.Guidance, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ShouldSwallowReturnOutsideIdle()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        Assert.False(controller.ShouldSwallowReturnKeyEvent());
        capture.Start();
        Assert.True(controller.ShouldSwallowReturnKeyEvent());
    }

    [Fact]
    public void OverlayHideRuleComesFromRust()
    {
        var capture = new FakeCaptureDriver();
        var sink = new FakeInsertionSink();
        using var controller = new DictationController(capture, sink);
        Assert.True(controller.OverlayShouldHide());
        capture.Start();
        Assert.False(controller.OverlayShouldHide());
    }
}
