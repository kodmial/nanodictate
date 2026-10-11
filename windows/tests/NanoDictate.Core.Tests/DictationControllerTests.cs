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
        Assert.False(controller.CompleteWithTranscript("   ...   "));
        Assert.Empty(sink.Inserts);
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
