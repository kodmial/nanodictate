using System.Globalization;

namespace NanoDictate.Core;

/// <summary>
/// Grapheme-aware chunking for direct Unicode insertion. Mirrors the macOS
/// <c>Inserter.chunkedForEvents</c> contract: chunks honor both a grapheme
/// ceiling and a UTF-16-unit ceiling so surrogate pairs, ZWJ sequences, and
/// combining marks are never split across input bursts.
/// Platform difference (explicit): macOS chunks because
/// <c>CGEventKeyboardSetUnicodeString</c> truncates past ~20 UTF-16 units;
/// Windows SendInput has no such truncation, but the same ceilings are kept
/// so long insertions stay responsive (5 ms pause between chunks) and
/// Cyrillic/emoji behavior stays identical across hosts.
/// </summary>
public static class TextChunker
{
    /// <summary>Maximum grapheme clusters per chunk (matches macOS chunkSize).</summary>
    public const int ChunkSize = 16;

    /// <summary>Maximum UTF-16 code units per chunk (matches macOS compat bound).</summary>
    public const int MaxUtf16PerChunk = 20;

    /// <summary>Splits text into insertion chunks. Empty input yields no chunks.</summary>
    public static IReadOnlyList<string> Chunk(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return Array.Empty<string>();
        }
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var elements = new List<string>();
        while (enumerator.MoveNext())
        {
            elements.Add(enumerator.GetTextElement());
        }
        var chunks = new List<string>();
        var current = new List<string>();
        var currentUtf16 = 0;
        void Flush()
        {
            if (current.Count > 0)
            {
                chunks.Add(string.Concat(current));
                current.Clear();
                currentUtf16 = 0;
            }
        }
        foreach (var element in elements)
        {
            var units = element.Length;
            if (units > MaxUtf16PerChunk)
            {
                // Oversized grapheme cluster: flush, then cut at scalar
                // boundaries so no chunk exceeds the UTF-16 ceiling.
                Flush();
                var scalarChunk = string.Empty;
                var scalarUtf16 = 0;
                foreach (var rune in element.EnumerateRunes())
                {
                    var runeUnits = rune.Utf16SequenceLength;
                    if (scalarUtf16 + runeUnits > MaxUtf16PerChunk && scalarChunk.Length > 0)
                    {
                        chunks.Add(scalarChunk);
                        scalarChunk = string.Empty;
                        scalarUtf16 = 0;
                    }
                    scalarChunk += rune.ToString();
                    scalarUtf16 += runeUnits;
                }
                if (scalarChunk.Length > 0)
                {
                    chunks.Add(scalarChunk);
                }
            }
            else if (current.Count >= ChunkSize || currentUtf16 + units > MaxUtf16PerChunk)
            {
                Flush();
                current.Add(element);
                currentUtf16 = units;
            }
            else
            {
                current.Add(element);
                currentUtf16 += units;
            }
        }
        Flush();
        return chunks;
    }

    /// <summary>
    /// Counts grapheme clusters (what one Backspace press erases). WordDiff
    /// offsets count Unicode scalars; multi-scalar clusters stay the native
    /// insertion layer's responsibility (same split as macOS).
    /// </summary>
    public static int CountTextElements(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return 0;
        }
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var count = 0;
        while (enumerator.MoveNext())
        {
            count++;
        }
        return count;
    }
}
