using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

internal sealed class FakeClipboardBridge : IClipboardBridge
{
    public string Stored = "original";
    public int Pastes;
    public readonly List<string> Writes = new();
    public ClipboardSnapshot Read() => new(Stored);
    public void Write(string text)
    {
        Writes.Add(text);
        Stored = text;
    }
    public void Restore(ClipboardSnapshot snapshot) => Stored = snapshot.Text;
    public void SendPaste() => Pastes++;
}

/// <summary>Clipboard insertion mode: save/paste/restore with generation guard.</summary>
public sealed class ClipboardInsertServiceTests
{
    [Fact]
    public void EmptyTextIsNoop()
    {
        var bridge = new FakeClipboardBridge();
        var service = new ClipboardInsertService(bridge, new ImmediateRestoreScheduler());
        service.InsertViaClipboard(string.Empty);
        Assert.Equal(0, bridge.Pastes);
    }

    [Fact]
    public void InsertRestoresOriginalImmediately()
    {
        var bridge = new FakeClipboardBridge { Stored = "keep me" };
        var service = new ClipboardInsertService(bridge, new ImmediateRestoreScheduler());
        service.InsertViaClipboard("Привет 🎉");
        Assert.Equal(1, bridge.Pastes);
        Assert.Equal("Привет 🎉", bridge.Writes[0]);
        Assert.Equal("keep me", bridge.Stored);
        Assert.False(service.HasPendingRestore);
    }

    [Fact]
    public void OverlappingInsertKeepsFirstOriginalAndLatestRestoreWins()
    {
        var bridge = new FakeClipboardBridge { Stored = "original" };
        var scheduled = new List<Action>();
        var manual = new ManualScheduler(scheduled);
        var service = new ClipboardInsertService(bridge, manual);
        service.InsertViaClipboard("first");
        service.InsertViaClipboard("second");
        Assert.Equal(2, bridge.Pastes);
        Assert.Equal(2, scheduled.Count);
        // Only the latest restore runs; the earlier one is superseded.
        scheduled[0]();
        Assert.Equal("second", bridge.Stored);
        scheduled[1]();
        Assert.Equal("original", bridge.Stored);
    }

    private sealed class ManualScheduler : IRestoreScheduler
    {
        private readonly List<Action> _list;
        public ManualScheduler(List<Action> list) => _list = list;
        public void Schedule(Action restore, TimeSpan delay) => _list.Add(restore);
    }
}
