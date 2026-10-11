namespace NanoDictate.Core;

/// <summary>
/// Marks the host's own synthetic Enter so the global hotkey hook can tell
/// it apart from a physical Return press. Ports the macOS
/// <c>SyntheticReturnMarker</c> idea to Windows: SendInput lets the sender
/// set <c>dwExtraInfo</c> per INPUT, and the low-level keyboard hook
/// observes the same value in <c>KBDLLHOOKSTRUCT.dwExtraInfo</c>.
/// Platform difference (explicit): macOS tags a CGEvent field; Windows tags
/// the SendInput extra-info word. The token value is shared with tests.
/// </summary>
public static class SyntheticEnterMarker
{
    /// <summary>Magic token ("NDTK") identifying our synthetic Enter.</summary>
    public const uint Token = 0x4E44544B;

    public static bool IsOwnSyntheticEnter(IntPtr extraInfo) =>
        (extraInfo.ToInt64() & 0xFFFFFFFFL) == Token;

    public static bool IsOwnSyntheticEnter(uint extraInfo) => extraInfo == Token;

    public static IntPtr ToExtraInfo() => new(unchecked((nint)Token));
}
