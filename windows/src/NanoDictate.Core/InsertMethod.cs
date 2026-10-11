namespace NanoDictate.Core;

/// <summary>Text insertion method (mirrors the macOS <c>InsertMethod</c>).</summary>
public enum InsertMethod
{
    /// <summary>Direct Unicode keystroke emulation (SendInput on Windows).</summary>
    Direct = 0,
    /// <summary>Clipboard write followed by Ctrl+V with restore.</summary>
    Clipboard = 1,
}

/// <summary>
/// Parses the shared <c>insert_method</c> config value. The canonical file
/// uses <c>cgevent</c> (macOS name) and <c>clipboard</c>; on Windows
/// <c>cgevent</c> explicitly maps to <see cref="InsertMethod.Direct"/>
/// (SendInput with KEYEVENTF_UNICODE) rather than being silently dropped.
/// </summary>
public static class InsertMethodParser
{
    public static InsertMethod Parse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return InsertMethod.Direct;
        }
        var normalized = value.Trim().ToLowerInvariant();
        return normalized switch
        {
            "clipboard" => InsertMethod.Clipboard,
            "cgevent" => InsertMethod.Direct,
            "direct" => InsertMethod.Direct,
            "sendinput" => InsertMethod.Direct,
            _ => throw new NanoException(-1, $"unknown insert_method '{value}' (expected 'cgevent' or 'clipboard')"),
        };
    }

    public static string ToConfigString(InsertMethod method) =>
        method == InsertMethod.Clipboard ? "clipboard" : "cgevent";
}
