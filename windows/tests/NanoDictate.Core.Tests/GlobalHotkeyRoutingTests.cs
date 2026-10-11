using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

internal sealed class RecordingHotkeyDelegate : IGlobalHotkeyDelegate
{
    public int Doubles;
    public int Firsts;
    public int Pending;
    public int Cancels;
    public int Enters;
    public bool SwallowReturn;

    public void AltDoubleTapped() => Doubles++;
    public void AltFirstTapDetected() => Firsts++;
    public void AltPendingCancelled() => Pending++;
    public void CancelKeyPressed() => Cancels++;
    public void EnterKeyPressed() => Enters++;
    public bool ShouldSwallowReturnKeyEvent() => SwallowReturn;
}

/// <summary>
/// Hotkey routing: false-trigger protection, Escape/Enter workflow, swallow
/// rules, and synthetic-Enter exclusion. Runs on any OS (no Win32).
/// </summary>
public sealed class GlobalHotkeyRoutingTests
{
    private static HotkeyEvent Key(int vk, double t, bool repeat = false, uint extra = 0) =>
        new(vk, true, repeat, new IntPtr(unchecked((nint)extra)), t);

    [Fact]
    public void DoubleAltFiresOnSecondTap()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate();
        service.Delegate = sink;
        Assert.False(service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.0)));
        Assert.Equal(1, sink.Firsts);
        Assert.True(service.IsAltPending);
        Assert.False(service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.2)));
        Assert.Equal(1, sink.Doubles);
        Assert.False(service.IsAltPending);
    }

    [Fact]
    public void ForeignKeyCancelsPendingTap()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate();
        service.Delegate = sink;
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.0));
        service.HandleKeyEvent(Key(0x41, 1.1));
        Assert.Equal(1, sink.Pending);
        Assert.False(service.IsAltPending);
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.2));
        Assert.Equal(2, sink.Firsts);
        Assert.Equal(0, sink.Doubles);
    }

    [Fact]
    public void OtherModifierCancelsPendingTap()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate();
        service.Delegate = sink;
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.0));
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkControl, 1.1));
        Assert.Equal(1, sink.Pending);
        Assert.Equal(0, sink.Doubles);
    }

    [Fact]
    public void HeldAltRepeatIsNotANewTap()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate();
        service.Delegate = sink;
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.0));
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.05, repeat: true));
        Assert.Equal(1, sink.Firsts);
        Assert.Equal(0, sink.Doubles);
        Assert.True(service.IsAltPending);
    }

    [Fact]
    public void EscapeCancelsPendingAndRaisesCancel()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate();
        service.Delegate = sink;
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.0));
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkEscape, 1.1));
        Assert.Equal(1, sink.Pending);
        Assert.Equal(1, sink.Cancels);
        Assert.False(service.IsAltPending);
    }

    [Fact]
    public void EnterCancelsPendingRaisesEnterAndSwallowsOutsideIdle()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate { SwallowReturn = true };
        service.Delegate = sink;
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.0));
        var swallowed = service.HandleKeyEvent(Key(GlobalHotkeyService.VkReturn, 1.1));
        Assert.True(swallowed);
        Assert.Equal(1, sink.Pending);
        Assert.Equal(1, sink.Enters);
    }

    [Fact]
    public void EnterPassesThroughInIdle()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate { SwallowReturn = false };
        service.Delegate = sink;
        Assert.False(service.HandleKeyEvent(Key(GlobalHotkeyService.VkReturn, 1.0)));
        Assert.Equal(1, sink.Enters);
    }

    [Fact]
    public void OwnSyntheticEnterIsExcludedEntirely()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate { SwallowReturn = true };
        service.Delegate = sink;
        var swallowed = service.HandleKeyEvent(Key(GlobalHotkeyService.VkReturn, 1.0, extra: SyntheticEnterMarker.Token));
        Assert.False(swallowed);
        Assert.Equal(0, sink.Enters);
        Assert.Equal(0, sink.Pending);
    }

    [Fact]
    public void PendingExpiryIsDeterministicForTests()
    {
        using var service = new GlobalHotkeyService();
        var sink = new RecordingHotkeyDelegate();
        service.Delegate = sink;
        service.HandleKeyEvent(Key(GlobalHotkeyService.VkLMenu, 1.0));
        service.ExpirePendingForTests();
        Assert.Equal(1, sink.Pending);
        Assert.False(service.IsAltPending);
    }

    [Fact]
    public void NonWindowsStartFailsLoudly()
    {
        if (OperatingSystem.IsWindows())
        {
            return;
        }
        using var service = new GlobalHotkeyService();
        Assert.Throws<PlatformNotSupportedException>(() => service.Start());
    }
}
