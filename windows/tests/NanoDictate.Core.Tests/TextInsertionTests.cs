using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

internal sealed class RecordingInputSender : IInputSender
{
    public readonly List<string> Chunks = new();
    public int BackspaceCalls;
    public int BackspaceTotal;
    public int Enters;
    public void SendUnicodeChunk(string chunk) => Chunks.Add(chunk);
    public void SendBackspaces(int graphemeCount)
    {
        BackspaceCalls++;
        BackspaceTotal += graphemeCount;
    }
    public void SendEnter() => Enters++;
}

internal sealed class CountingSleeper : ISleeper
{
    public int Pauses;
    public void SleepMicroseconds(int microseconds) => Pauses++;
}

/// <summary>Unicode insertion: chunking, Cyrillic/emoji, undo, synthetic Enter.</summary>
public sealed class TextInsertionTests
{
    [Fact]
    public void EmptyInsertIsNoop()
    {
        var sender = new RecordingInputSender();
        var inserter = new TextInserter(sender, new CountingSleeper());
        inserter.Insert(string.Empty);
        Assert.Empty(sender.Chunks);
    }

    [Fact]
    public void CyrillicRoundTripsThroughChunks()
    {
        var sender = new RecordingInputSender();
        var sleeper = new CountingSleeper();
        var inserter = new TextInserter(sender, sleeper);
        const string text = "Привет мир, dictation works.";
        inserter.Insert(text);
        Assert.Equal(text, string.Concat(sender.Chunks));
        Assert.True(sender.Chunks.Count >= 1);
        Assert.Equal(sender.Chunks.Count - 1, sleeper.Pauses);
    }

    [Fact]
    public void EmojiSurrogatePairsStayWhole()
    {
        var sender = new RecordingInputSender();
        var inserter = new TextInserter(sender, new CountingSleeper());
        const string text = "done 🎉 test Привет";
        inserter.Insert(text);
        Assert.Equal(text, string.Concat(sender.Chunks));
        foreach (var chunk in sender.Chunks)
        {
            Assert.True(chunk.Length <= 20 || TextChunker.CountTextElements(chunk) <= 16);
        }
    }

    [Fact]
    public void LongTextChunksWithPausesBetweenOnly()
    {
        var sender = new RecordingInputSender();
        var sleeper = new CountingSleeper();
        var inserter = new TextInserter(sender, sleeper);
        var text = new string('a', 100);
        inserter.Insert(text);
        Assert.True(sender.Chunks.Count > 1);
        Assert.Equal(text, string.Concat(sender.Chunks));
        Assert.Equal(sender.Chunks.Count - 1, sleeper.Pauses);
    }

    [Fact]
    public void UndoErasesExactGraphemeCountInChunks()
    {
        var sender = new RecordingInputSender();
        var sleeper = new CountingSleeper();
        var inserter = new TextInserter(sender, sleeper);
        const string text = "hi 🎉";
        inserter.DeleteText(text);
        Assert.Equal(TextChunker.CountTextElements(text), sender.BackspaceTotal);
    }

    [Fact]
    public void ReplaceRangeBackspacesOldThenTypesNew()
    {
        var sender = new RecordingInputSender();
        var inserter = new TextInserter(sender, new CountingSleeper());
        inserter.ReplaceRange("hello", "hello world");
        Assert.Equal(5, sender.BackspaceTotal);
        Assert.Equal("hello world", string.Concat(sender.Chunks));
    }

    [Fact]
    public void ReplaceRangeEqualIsNoop()
    {
        var sender = new RecordingInputSender();
        var inserter = new TextInserter(sender, new CountingSleeper());
        inserter.ReplaceRange("same", "same");
        Assert.Empty(sender.Chunks);
        Assert.Equal(0, sender.BackspaceTotal);
    }

    [Fact]
    public void SyntheticEnterPostsOnce()
    {
        var sender = new RecordingInputSender();
        var inserter = new TextInserter(sender, new CountingSleeper());
        inserter.PostReturn();
        Assert.Equal(1, sender.Enters);
    }

    [Fact]
    public void RustWordDiffDrivesReplacementSpans()
    {
        var diff = RustTextPolicy.WordDiff("One three.", "One two three.");
        Assert.True(diff.HasChange);
        Assert.False(string.IsNullOrEmpty(diff.SpanNew));
        var same = RustTextPolicy.WordDiff("same", "same");
        Assert.False(same.HasChange);
    }

    [Fact]
    public void RustTextJoinAndReviewDecideOwnPolicies()
    {
        Assert.Equal("hello brave world again", RustTextPolicy.Join(new[] { "hello brave world", "brave world again" }));
        Assert.True(RustTextPolicy.ReviewDecide("y"));
        Assert.False(RustTextPolicy.ReviewDecide("n"));
        Assert.False(RustTextPolicy.ReviewDecide(null));
    }
}
