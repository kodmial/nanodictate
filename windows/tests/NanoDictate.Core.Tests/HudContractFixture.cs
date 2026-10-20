using System.Text.Json;
using System.Text.Json.Serialization;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Decoded view of the shared #216 HUD fixture. Data only: tests drive the
/// production <see cref="HudLevel"/>, <see cref="HudMeter"/>,
/// <see cref="HudLayout"/> and <see cref="HudPresentation"/> primitives and
/// compare observations with the same golden vectors macOS uses.
/// </summary>
internal sealed class HudContractFixture
{
    public sealed class ConstantsData
    {
        public double DbfsFloor { get; set; }
        public double AttackSeconds { get; set; }
        public double ReleaseSeconds { get; set; }
        public double PeakHoldSeconds { get; set; }
        public double PeakFallRatePerSecond { get; set; }
        public double MeterTickSeconds { get; set; }
        public double StartingGraceSeconds { get; set; }
        public double StrokeMinPoints { get; set; }
        public double StrokeMaxPoints { get; set; }
        public double HotThresholdDbfs { get; set; }
        public double RingDiameterPoints { get; set; }
        public double RecDotDiameterPoints { get; set; }
        public int ProcessingDotCount { get; set; }
        public double PanelCornerRadiusPoints { get; set; }
        public double PanelMinWidthPoints { get; set; }
        public double PanelMaxWidthPoints { get; set; }
        public double PanelHeightIdlePoints { get; set; }
        public double PanelHeightRecordingPoints { get; set; }
        public double ClockTickSeconds { get; set; }
    }

    public sealed class TimingData
    {
        public sealed class TerminalHide
        {
            public double Insert { get; set; }
            public double Cancelled { get; set; }
            public double EmptyResult { get; set; }
            public double Error { get; set; }
            public double MicrophoneError { get; set; }
        }

        public TerminalHide TerminalHideSeconds { get; set; } = new();
    }

    public sealed class RmsVector
    {
        public double Rms { get; set; }
        public double Dbfs { get; set; }
        public double Meter { get; set; }
        public double StrokePoints { get; set; }
        public bool Hot { get; set; }
    }

    public sealed class VuTrace
    {
        public sealed class Step
        {
            public double AtMs { get; set; }
            public double Rms { get; set; }
            public double TargetMeter { get; set; }
            public double Meter { get; set; }
            public double Peak { get; set; }
            public double StrokePoints { get; set; }
        }

        public string Name { get; set; } = string.Empty;
        public double TickSeconds { get; set; }
        public bool ReduceMotion { get; set; }
        public List<Step> Steps { get; set; } = new();
    }

    public sealed class PresentationScenario
    {
        public sealed class Event
        {
            public double AtMs { get; set; }
            [JsonPropertyName("event")]
            public string EventName { get; set; } = string.Empty;
            public ulong Generation { get; set; }
        }

        public sealed class Checkpoint
        {
            public double AtMs { get; set; }
            public bool Visible { get; set; }
            public string Phase { get; set; } = string.Empty;
            public bool RecordingStarted { get; set; }
            public string? StatusKey { get; set; }
            public string? StatusArgumentKey { get; set; }
            public ulong Generation { get; set; }
            public string? RustState { get; set; }
        }

        public string Name { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public ulong SessionGeneration { get; set; }
        public List<Event> Events { get; set; } = new();
        public List<Checkpoint> Checkpoints { get; set; } = new();
    }

    public string Contract { get; set; } = string.Empty;
    public int Version { get; set; }
    public ConstantsData Constants { get; set; } = new();
    public TimingData Timing { get; set; } = new();
    public List<RmsVector> RmsVectors { get; set; } = new();
    public List<VuTrace> VuTraces { get; set; } = new();
    public List<PresentationScenario> PresentationScenarios { get; set; } = new();

    public PresentationScenario? Scenario(string name) =>
        PresentationScenarios.FirstOrDefault(s => s.Name == name);

    public static HudContractFixture Load()
    {
        var path = FixturePath();
        var json = File.ReadAllText(path);
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        };
        // The fixture uses "event" as a key; SnakeCaseLower maps it to EventName
        // only through the explicit property name below.
        options.PropertyNameCaseInsensitive = true;
        var fixture = JsonSerializer.Deserialize<HudContractFixture>(json, options);
        if (fixture is null)
        {
            throw new InvalidOperationException("HUD fixture could not be decoded");
        }
        return fixture;
    }

    private static string FixturePath()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "Tests", "Fixtures", "HUD", "hud-contract-v1.json");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        throw new FileNotFoundException("Tests/Fixtures/HUD/hud-contract-v1.json not found");
    }
}
