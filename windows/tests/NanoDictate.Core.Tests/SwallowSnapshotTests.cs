using System;
using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Verifies the hook swallow decision uses the lock-free snapshot.
/// </summary>
internal sealed class SnapshotCaptureDriver : ICaptureDriver
{
    public DictationState Snapshot { get; set; } = DictationState.Idle;

    public DictationState State => throw new InvalidOperationException("Hook path must not read State");

    public DictationState CachedState => Snapshot;

    public bool IsRunning => Snapshot != DictationState.Idle;

    public bool IsCaptureReady => false;

    public void Start(ulong? triggerNanos = null) => throw new NotSupportedException();

    public PipelineStopResult Stop() => throw new NotSupportedException();

    public void Cancel() { }

    public void FinishTranscription() { }
}

internal sealed class SnapshotInsertionSink : IInsertionSink
{
    public void Insert(string text, InsertMethod method) { }
    public void DeleteText(string insertedText) { }
    public void DeleteGraphemes(int count) { }
    public void PostEnter() { }
}

public sealed class SwallowSnapshotTests
{
    [Fact]
    public void ShouldSwallowUsesCachedSnapshotWithoutTouchingState()
    {
        var capture = new SnapshotCaptureDriver { Snapshot = DictationState.Idle };
        using var controller = new DictationController(capture, new SnapshotInsertionSink());
        Assert.False(controller.ShouldSwallowReturnKeyEvent());

        capture.Snapshot = DictationState.Recording;
        Assert.True(controller.ShouldSwallowReturnKeyEvent());

        capture.Snapshot = DictationState.Transcribing;
        Assert.True(controller.ShouldSwallowReturnKeyEvent());
    }

    [Fact]
    public void HookRoutingHonoursSnapshotDrivenDelegate()
    {
        var capture = new SnapshotCaptureDriver { Snapshot = DictationState.Recording };
        using var controller = new DictationController(capture, new SnapshotInsertionSink());
        using var service = new GlobalHotkeyService();
        service.Delegate = controller;
        var evt = new HotkeyEvent(GlobalHotkeyService.VkReturn, true, false, IntPtr.Zero, 1.0);
        Assert.True(service.HandleKeyEvent(evt));
    }
}
