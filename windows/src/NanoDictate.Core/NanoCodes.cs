namespace NanoDictate.Core;

/// <summary>Stable ABI error codes (see rust/nanodictate-core/src/error.rs).</summary>
public static class NanoErrorCodes
{
    public const int Ok = 0;
    public const int Null = 1;
    public const int Utf8 = 2;
    public const int Arg = 3;
    public const int SmallBuffer = 4;
    public const int Decode = 5;
    public const int Internal = 6;
    public const int Panic = 100;
}

/// <summary>Dictation cycle state codes (see NdSession / DictationState).</summary>
public enum DictationState : uint
{
    Idle = 0,
    Recording = 1,
    Transcribing = 2,
}

/// <summary>Session event codes (see SessionEvent).</summary>
public enum SessionEvent : uint
{
    EngineStarted = 0,
    FirstBuffer = 1,
    EngineFailed = 2,
    Cancelled = 3,
    StopRequested = 4,
    TranscriptionDone = 5,
}
