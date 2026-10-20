namespace NanoDictate.Core;

/// <summary>Native completion of one stopped-recording transcription attempt.</summary>
public sealed record DictationDelivery(ulong RecordingId, string Text, bool Inserted);

/// <summary>Where a failed native dictation cycle failed.</summary>
public enum DictationFailureKind
{
    Transcription,
    Insertion,
}

/// <summary>
/// Truthful terminal failure event for the HUD. Transcription failures are
/// fail-closed at the controller; insertion failures keep the same atomic
/// rollback/session-completion behavior and only add user feedback.
/// </summary>
public sealed record DictationFailure(ulong RecordingId, Exception Error, DictationFailureKind Kind);
