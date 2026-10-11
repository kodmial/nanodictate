using System.Globalization;

namespace NanoDictate.Core;

/// <summary>
/// Pure double-Alt detection ported from the macOS <c>DoubleAltDetector</c>
/// (see Sources/NanoDictateCore/HotkeyService.swift). No Win32 calls: works
/// on tap timestamps only so unit tests run on any OS.
/// </summary>
public struct DoubleAltDetector
{
    /// <summary>Maximum interval between two Alt presses to count as double tap.</summary>
    public double MaxInterval { get; }

    private const double Epsilon = 1e-9;

    /// <summary>Last tap timestamp; null means no pending first tap.</summary>
    public double? LastTimestamp { get; private set; }

    public DoubleAltDetector(double maxInterval = 0.4)
    {
        if (maxInterval <= 0)
        {
            throw new NanoException(-1, "double-tap interval must be positive");
        }
        MaxInterval = maxInterval;
        LastTimestamp = null;
    }

    /// <summary>
    /// Registers one Alt tap. Returns true for a confirming second tap inside
    /// the window (detector resets so the next tap opens a new window).
    /// A late tap past the window restarts the window and returns false.
    /// </summary>
    public bool RegisterTap(double timestamp)
    {
        if (LastTimestamp is null)
        {
            LastTimestamp = timestamp;
            return false;
        }
        var last = LastTimestamp.Value;
        if (timestamp - last <= MaxInterval + Epsilon)
        {
            LastTimestamp = null;
            return true;
        }
        LastTimestamp = timestamp;
        return false;
    }

    public void Reset() => LastTimestamp = null;

    /// <summary>
    /// Cancels a pending first tap: any other key or modifier between Alt
    /// presses means "Alt + anything else", not a double Alt. Idempotent.
    /// </summary>
    public void CancelPendingTap() => LastTimestamp = null;

    public bool IsPending => LastTimestamp.HasValue;

    public override string ToString() =>
        string.Create(CultureInfo.InvariantCulture, $"DoubleAltDetector(max={MaxInterval}, pending={IsPending})");
}
