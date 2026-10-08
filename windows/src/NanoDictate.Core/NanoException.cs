namespace NanoDictate.Core;

/// <summary>
/// Failure of a Rust engine call. The message is the ABI diagnostic text
/// from <c>nd_last_error_text</c>. Numeric codes match
/// <c>rust/nanodictate-core/src/error.rs</c> and are never renumbered.
/// </summary>
public sealed class NanoException : Exception
{
    /// <summary>Stable ABI error code, or -1 for host-side mapping failures.</summary>
    public int Code { get; }

    public NanoException(int code, string message)
        : base(message)
    {
        Code = code;
    }
}
