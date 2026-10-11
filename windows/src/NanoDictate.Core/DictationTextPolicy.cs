using System.Text.Json;

namespace NanoDictate.Core;

/// <summary>
/// Pure dictation-cycle text decisions shared by the Windows controller.
/// <c>IsEmptyResult</c> mirrors macOS <c>NanoDictateFlow.isEmptyResult</c>
/// verbatim (whitespace-only or no letter/digit means no insert).
/// Platform note (explicit): the shared Rust engine currently exposes no
/// empty-result entry point, so the Swift rule is mirrored here rather than
/// silently dropped; if Rust gains one, this must delegate to it.
/// <c>ShouldDeliverResult</c>, <c>ShouldUndoInsertion</c>, and
/// <c>ShouldUndoInsteadOfStart</c> mirror <c>NanoDictateFlow</c> the same way.
/// </summary>
public static class DictationTextPolicy
{
    public static bool IsEmptyResult(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return true;
        }
        foreach (var ch in text)
        {
            if (char.IsLetterOrDigit(ch))
            {
                return false;
            }
        }
        return true;
    }

    public static bool ShouldDeliverResult(bool isCancelled, bool sessionActive) =>
        !isCancelled && sessionActive;

    public static bool ShouldUndoInsertion(DateTime? lastInsertedAt, DateTime now, TimeSpan window)
    {
        if (lastInsertedAt is null)
        {
            return false;
        }
        return (now - lastInsertedAt.Value) <= window;
    }

    public static bool ShouldUndoInsteadOfStart(
        DictationState state, DateTime? lastInsertedAt, DateTime now, TimeSpan undoWindow) =>
        state == DictationState.Idle && ShouldUndoInsertion(lastInsertedAt, now, undoWindow);
}

/// <summary>
/// Word-diff result parsed from the Rust <c>nd_word_diff</c> JSON contract.
/// The decision (whether anything changed, and which spans to fix up) stays
/// in Rust; this type only carries the parsed spans for the native insertion
/// layer (same split as the macOS WordDiff + Inserter path).
/// </summary>
public sealed record WordDiffResult(bool HasChange, string SpanOld, string SpanNew, int SpanStartOld, int SpanStartNew)
{
    public static WordDiffResult Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var change = root.GetProperty("change").GetBoolean();
        if (!change)
        {
            return new WordDiffResult(false, string.Empty, string.Empty, 0, 0);
        }
        return new WordDiffResult(
            true,
            root.TryGetProperty("span_old", out var so) ? so.GetString() ?? string.Empty : string.Empty,
            root.TryGetProperty("span_new", out var sn) ? sn.GetString() ?? string.Empty : string.Empty,
            root.TryGetProperty("span_start_old", out var sso) && sso.TryGetInt32(out var v0) ? v0 : 0,
            root.TryGetProperty("span_start_new", out var ssn) && ssn.TryGetInt32(out var v1) ? v1 : 0);
    }
}

/// <summary>
/// Rust-backed text helpers: every boundary/ordering decision delegates to
/// <see cref="NanoEngine"/> (WordDiff, TextJoin, ReviewDecide) instead of
/// reimplementing the policy in C#.
/// </summary>
public static class RustTextPolicy
{
    public static WordDiffResult WordDiff(string oldText, string newText) =>
        WordDiffResult.Parse(NanoEngine.WordDiff(oldText, newText));

    public static string Join(IReadOnlyList<string> texts) => NanoEngine.TextJoin(texts);

    /// <summary>
    /// Review-before-insert decision from the engine (empty/y/Y inserts,
    /// anything else or end-of-input cancels). Fail-closed: engine errors
    /// cancel the insertion loudly in the caller.
    /// </summary>
    public static bool ReviewDecide(string? line) => NanoEngine.ReviewDecide(line);

    public static bool ShouldDropRetry(DictationState state, ulong processingSession, ulong session) =>
        NanoEngine.ShouldDropRetry(state, processingSession, session);

    public static bool OverlayShouldHide(DictationState state) => NanoEngine.OverlayShouldHide(state);
}
