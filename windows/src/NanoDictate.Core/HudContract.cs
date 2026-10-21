namespace NanoDictate.Core;

/// <summary>
/// Versioned native HUD presentation contract (shared with macOS, #216).
/// These constants mirror <c>Tests/Fixtures/HUD/hud-contract-v1.json</c>;
/// tests decode the fixture and fail when either side drifts.
/// </summary>
public static class HudContract
{
    public const string Contract = "nanodictate.shared-hud";
    public const int Version = 1;

    public const float DbfsFloor = -50.0f;
    public const double AttackSeconds = 0.07;
    public const double ReleaseSeconds = 0.5;
    public const double PeakHoldSeconds = 0.8;
    public const float PeakFallRatePerSecond = 0.7f;
    public const double MeterTickSeconds = 0.05;
    public const double StartingGraceSeconds = 0.12;
    public const float StrokeMinPoints = 3.0f;
    public const float StrokeMaxPoints = 9.0f;
    public const float HotThresholdDbfs = -6.0f;
    public const float RingDiameterPoints = 68.0f;
    public const float RecDotDiameterPoints = 8.0f;
    public const int ProcessingDotCount = 3;
    public const float PanelCornerRadiusPoints = 10.0f;
    public const float PanelMinWidthPoints = 180.0f;
    public const float PanelMaxWidthPoints = 240.0f;
    public const float PanelHeightIdlePoints = 150.0f;
    public const float PanelHeightRecordingPoints = 178.0f;
    public const double ClockTickSeconds = 1.0;

    public const double InsertHideSeconds = 0.8;
    public const double CancelledHideSeconds = 0.8;
    public const double EmptyResultHideSeconds = 0.8;
    public const double ErrorHideSeconds = 2.0;
    public const double MicrophoneErrorHideSeconds = 2.0;
}

/// <summary>
/// Presentation phases are host state and deliberately not derived from the
/// Rust session state. See <c>docs/hud-contract.md</c>.
/// </summary>
public enum HudPhase
{
    Idle,
    Starting,
    Recording,
    Processing,
}

/// <summary>Localized status keys used by the shared contract.</summary>
public static class HudStatusKeys
{
    public const string Starting = "overlay.starting";
    public const string Recording = "overlay.recording";
    public const string Recognizing = "overlay.recognizing";
    public const string Finishing = "overlay.finishing";
    public const string Cancelled = "overlay.cancelled";
    public const string EmptyResult = "overlay.emptyResult";
    public const string Error = "overlay.error";

    public const string ErrorNoInternet = "error.noInternet";
    public const string ErrorSttTimeout = "error.sttTimeout";
    public const string ErrorMicEnableFailed = "error.micEnableFailed";
    public const string ErrorInsertFailed = "error.insertFailed";
}

/// <summary>Resolved provider/model plus the real release version shown in the HUD.</summary>
public sealed record HudSessionLabel(string Provider, string Model, string Version)
{
    public string VersionBadge => string.IsNullOrEmpty(Version) ? string.Empty : "v" + Version;

    /// <summary>
    /// Reads the informational version of the entry assembly and strips
    /// source-revision metadata. Release packaging injects <c>/p:Version</c>,
    /// so this is the same version users see in installers and releases.
    /// </summary>
    public static string ResolveVersion(System.Reflection.Assembly? assembly = null)
    {
        assembly ??= System.Reflection.Assembly.GetEntryAssembly()
            ?? typeof(HudSessionLabel).Assembly;
        var informational = assembly
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>()
            .FirstOrDefault()?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(informational))
        {
            var plus = informational.IndexOf('+');
            return plus >= 0 ? informational[..plus] : informational;
        }
        var version = assembly.GetName().Version;
        return version is null ? "0.0.0" : $"{version.Major}.{version.Minor}.{version.Build}";
    }
}

/// <summary>One immutable observation of what the HUD should render.</summary>
public sealed record HudSnapshot(
    bool Visible,
    HudPhase Phase,
    string? StatusKey,
    string? StatusArgumentKey,
    bool RecordingStarted,
    ulong Generation,
    float Meter,
    float Peak,
    double ElapsedSeconds,
    HudSessionLabel Label,
    bool ReduceMotion)
{
    public bool HasTimer => Visible && Phase == HudPhase.Recording && RecordingStarted;

    public bool HasRecordingIndicator => HasTimer;

    public bool HasProcessingDots => Visible && Phase == HudPhase.Processing;

    public float StrokeWidth => HudLevel.StrokeWidth(Meter);

    public string Provider => Label.Provider;

    public string Model => Label.Model;

    public string Version => Label.Version;

    public string ElapsedText => HudTimeFormat.Format(ElapsedSeconds);

    public string StatusText => HudStrings.StatusText(StatusKey, StatusArgumentKey);
}

/// <summary>Timer formatting shared by the native HUD and tests.</summary>
public static class HudTimeFormat
{
    public static string Format(double seconds)
    {
        if (seconds < 0 || double.IsNaN(seconds))
        {
            seconds = 0;
        }
        var total = (long)Math.Floor(seconds);
        var minutes = total / 60;
        var secs = total % 60;
        return $"{minutes}:{secs:00}";
    }
}

/// <summary>English status strings for the Windows HUD (repository UI language).</summary>
public static class HudStrings
{
    public static string StatusText(string? key, string? argumentKey)
    {
        if (string.IsNullOrEmpty(key))
        {
            return string.Empty;
        }
        var text = key switch
        {
            HudStatusKeys.Starting => "Starting microphone…",
            HudStatusKeys.Recording => "Recording",
            HudStatusKeys.Recognizing => "Recognizing…",
            HudStatusKeys.Finishing => "Finishing…",
            HudStatusKeys.Cancelled => "Cancelled",
            HudStatusKeys.EmptyResult => "No speech detected",
            HudStatusKeys.Error => "Error: {message}",
            HudStatusKeys.ErrorMicEnableFailed => "Microphone unavailable",
            _ => key,
        };
        if (text.Contains("{message}", StringComparison.Ordinal))
        {
            var message = string.IsNullOrEmpty(argumentKey) ? "unknown error" : ArgumentText(argumentKey);
            text = text.Replace("{message}", message, StringComparison.Ordinal);
        }
        return text;
    }

    public static string ArgumentText(string key) => key switch
    {
        HudStatusKeys.ErrorNoInternet => "No internet",
        HudStatusKeys.ErrorSttTimeout => "STT timeout",
        HudStatusKeys.ErrorMicEnableFailed => "Microphone unavailable",
        HudStatusKeys.ErrorInsertFailed => "Text insertion failed",
        _ => key,
    };

    /// <summary>Maps a native/transcription failure to the truthful HUD status.</summary>
    public static (string Key, string? ArgumentKey) ErrorFor(Exception error)
    {
        if (error is TranscribeError transcribe)
        {
            var message = transcribe.Message ?? string.Empty;
            if (transcribe.Kind == TranscribeError.ErrorKind.Network
                && (message.Contains("timeout", StringComparison.OrdinalIgnoreCase)
                    || message.Contains("timed out", StringComparison.OrdinalIgnoreCase)
                    || message.Contains("canceled", StringComparison.OrdinalIgnoreCase)
                    || message.Contains("cancelled", StringComparison.OrdinalIgnoreCase)))
            {
                return (HudStatusKeys.Error, HudStatusKeys.ErrorSttTimeout);
            }
            if (transcribe.Kind == TranscribeError.ErrorKind.Network)
            {
                return (HudStatusKeys.Error, HudStatusKeys.ErrorNoInternet);
            }
        }
        if (error is NanoException nano && nano.Message.Contains("insert", StringComparison.OrdinalIgnoreCase))
        {
            return (HudStatusKeys.Error, HudStatusKeys.ErrorInsertFailed);
        }
        return (HudStatusKeys.Error, null);
    }
}
