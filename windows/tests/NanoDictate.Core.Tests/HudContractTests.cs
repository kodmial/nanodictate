using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Windows presentation adapter checks against the shared #216 golden fixture.
/// The math, phases, generation guards and terminal hides are the production
/// types used by the WinUI window; only window rendering is native-only.
/// </summary>
public sealed class HudContractTests
{
    private const double Tolerance = 0.0005;

    [Fact]
    public void FixtureAndConstantsMatchProductionContract()
    {
        var fixture = HudContractFixture.Load();
        Assert.Equal(HudContract.Contract, fixture.Contract);
        Assert.Equal(HudContract.Version, fixture.Version);

        Assert.Equal(HudContract.DbfsFloor, fixture.Constants.DbfsFloor, Tolerance);
        Assert.Equal(HudContract.AttackSeconds, fixture.Constants.AttackSeconds, Tolerance);
        Assert.Equal(HudContract.ReleaseSeconds, fixture.Constants.ReleaseSeconds, Tolerance);
        Assert.Equal(HudContract.PeakHoldSeconds, fixture.Constants.PeakHoldSeconds, Tolerance);
        Assert.Equal(HudContract.PeakFallRatePerSecond, fixture.Constants.PeakFallRatePerSecond, Tolerance);
        Assert.Equal(HudContract.MeterTickSeconds, fixture.Constants.MeterTickSeconds, Tolerance);
        Assert.Equal(HudContract.StartingGraceSeconds, fixture.Constants.StartingGraceSeconds, Tolerance);
        Assert.Equal(HudContract.StrokeMinPoints, fixture.Constants.StrokeMinPoints, Tolerance);
        Assert.Equal(HudContract.StrokeMaxPoints, fixture.Constants.StrokeMaxPoints, Tolerance);
        Assert.Equal(HudContract.HotThresholdDbfs, fixture.Constants.HotThresholdDbfs, Tolerance);
        Assert.Equal(HudContract.RingDiameterPoints, fixture.Constants.RingDiameterPoints, Tolerance);
        Assert.Equal(HudContract.RecDotDiameterPoints, fixture.Constants.RecDotDiameterPoints, Tolerance);
        Assert.Equal(HudContract.ProcessingDotCount, fixture.Constants.ProcessingDotCount);
        Assert.Equal(HudContract.PanelCornerRadiusPoints, fixture.Constants.PanelCornerRadiusPoints, Tolerance);
        Assert.Equal(HudContract.PanelMinWidthPoints, fixture.Constants.PanelMinWidthPoints, Tolerance);
        Assert.Equal(HudContract.PanelMaxWidthPoints, fixture.Constants.PanelMaxWidthPoints, Tolerance);
        Assert.Equal(HudContract.PanelHeightIdlePoints, fixture.Constants.PanelHeightIdlePoints, Tolerance);
        Assert.Equal(HudContract.PanelHeightRecordingPoints, fixture.Constants.PanelHeightRecordingPoints, Tolerance);
        Assert.Equal(HudContract.ClockTickSeconds, fixture.Constants.ClockTickSeconds, Tolerance);

        Assert.Equal(HudContract.InsertHideSeconds, fixture.Timing.TerminalHideSeconds.Insert, Tolerance);
        Assert.Equal(HudContract.CancelledHideSeconds, fixture.Timing.TerminalHideSeconds.Cancelled, Tolerance);
        Assert.Equal(HudContract.EmptyResultHideSeconds, fixture.Timing.TerminalHideSeconds.EmptyResult, Tolerance);
        Assert.Equal(HudContract.ErrorHideSeconds, fixture.Timing.TerminalHideSeconds.Error, Tolerance);
        Assert.Equal(HudContract.MicrophoneErrorHideSeconds, fixture.Timing.TerminalHideSeconds.MicrophoneError, Tolerance);
    }

    [Fact]
    public void RmsVectorsMatchReferenceMath()
    {
        var fixture = HudContractFixture.Load();
        Assert.NotEmpty(fixture.RmsVectors);
        foreach (var vector in fixture.RmsVectors)
        {
            var rms = (float)vector.Rms;
            Assert.Equal(vector.Dbfs, HudLevel.Dbfs(rms), 0.001);
            var meter = HudLevel.MeterFromRms(rms);
            Assert.Equal(vector.Meter, meter, 0.0001);
            Assert.Equal(vector.StrokePoints, HudLevel.StrokeWidth(meter), 0.0001);
            Assert.Equal(vector.Hot, HudLevel.IsHot(meter));
        }
    }

    [Fact]
    public void VuTracesMatchEnvelopeAndPeak()
    {
        var fixture = HudContractFixture.Load();
        Assert.Equal(
            new[] { "attack_release", "peak_hold_then_fall", "reduce_motion_passthrough" },
            fixture.VuTraces.Select(t => t.Name).ToArray());

        foreach (var trace in fixture.VuTraces)
        {
            var meter = new HudMeter();
            foreach (var step in trace.Steps)
            {
                meter.SetTargetFromRms((float)step.Rms);
                Assert.Equal(step.TargetMeter, HudLevel.MeterFromRms((float)step.Rms), 0.0001);
                meter.Step(trace.TickSeconds, trace.ReduceMotion);
                Assert.Equal(step.Meter, meter.Meter, Tolerance);
                Assert.Equal(step.Peak, meter.Peak, Tolerance);
                Assert.Equal(step.StrokePoints, HudLevel.StrokeWidth(meter.Meter), Tolerance);
            }
        }
    }

    [Fact]
    public void PresentationScenariosMatchGoldenCheckpoints()
    {
        var fixture = HudContractFixture.Load();
        Assert.Equal(10, fixture.PresentationScenarios.Count);
        foreach (var scenario in fixture.PresentationScenarios)
        {
            RunScenario(scenario);
        }
    }

    private static void RunScenario(HudContractFixture.PresentationScenario scenario)
    {
        var presentation = new HudPresentation(
            new HudSessionLabel("provider", "model", "9.9.9"));
        var events = scenario.Events.OrderBy(e => e.AtMs).ToList();
        var eventIndex = 0;
        string? rustState = null;

        foreach (var checkpoint in scenario.Checkpoints.OrderBy(c => c.AtMs))
        {
            while (eventIndex < events.Count && events[eventIndex].AtMs <= checkpoint.AtMs)
            {
                var evt = events[eventIndex++];
                Apply(presentation, evt, ref rustState);
            }
            presentation.Advance(TimeSpan.FromMilliseconds(checkpoint.AtMs));
            var snapshot = presentation.Snapshot();
            Assert.Equal(checkpoint.Visible, snapshot.Visible);
            Assert.Equal(checkpoint.Phase, PhaseName(snapshot.Phase));
            Assert.Equal(checkpoint.RecordingStarted, snapshot.RecordingStarted);
            Assert.Equal(checkpoint.StatusKey, snapshot.StatusKey);
            Assert.Equal(checkpoint.StatusArgumentKey, snapshot.StatusArgumentKey);
            Assert.Equal(checkpoint.Generation, snapshot.Generation);
            if (checkpoint.RustState is not null)
            {
                Assert.True(checkpoint.RustState == rustState, $"{scenario.Name} @{checkpoint.AtMs}ms expected rust {checkpoint.RustState} actual {rustState}");
            }
        }
    }

    private static void Apply(
        HudPresentation presentation,
        HudContractFixture.PresentationScenario.Event evt,
        ref string? rustState)
    {
        var now = TimeSpan.FromMilliseconds(evt.AtMs);
        switch (evt.EventName)
        {
            case "double_alt":
                if (presentation.Phase == HudPhase.Recording)
                {
                    presentation.StopRequested(evt.Generation, now);
                    rustState = "transcribing";
                }
                else
                {
                    presentation.BeginCycle(evt.Generation, now);
                    rustState = "recording";
                }
                break;
            case "first_buffer":
                presentation.CaptureReady(evt.Generation, now);
                rustState = "recording";
                break;
            case "insert_done":
                presentation.InsertionSucceeded(evt.Generation, now);
                break;
            case "escape":
                var phaseBeforeEscape = presentation.Phase;
                presentation.Cancelled(evt.Generation, now);
                rustState = phaseBeforeEscape == HudPhase.Processing ? "transcribing" : "idle";
                break;
            case "audio_error":
                presentation.MicrophoneError(evt.Generation, now);
                rustState = "idle";
                break;
            case "stt_error":
                presentation.TranscriptionError(evt.Generation, HudStatusKeys.ErrorNoInternet, now);
                rustState = "transcribing";
                break;
            case "stt_timeout":
                presentation.ProcessingTimedOut(evt.Generation, now);
                rustState = "transcribing";
                break;
            case "empty_result":
                presentation.EmptyResult(evt.Generation, now);
                rustState = "transcribing";
                break;
            case "owner_done":
                if (evt.Generation == presentation.Snapshot().Generation)
                {
                    rustState = "idle";
                }
                break;
            case "grace_pending":
            case "starting_visible":
            case "starting_deadline":
            case "hide_deadline":
            case "stale_hide_deadline":
            case "checkpoint":
                break;
            default:
                throw new InvalidOperationException($"unknown fixture event '{evt.EventName}'");
        }
        presentation.Advance(now);
    }

    private static string PhaseName(HudPhase phase) => phase switch
    {
        HudPhase.Idle => "idle",
        HudPhase.Starting => "starting",
        HudPhase.Recording => "recording",
        HudPhase.Processing => "processing",
        _ => throw new ArgumentOutOfRangeException(nameof(phase)),
    };

    [Fact]
    public void StartingGraceBoundaryMatchesFixture()
    {
        var fixture = HudContractFixture.Load();
        var grace = fixture.Constants.StartingGraceSeconds;
        var presentation = new HudPresentation(new HudSessionLabel("p", "m", "1"));
        presentation.BeginCycle(1, TimeSpan.Zero);
        presentation.Advance(TimeSpan.FromSeconds(grace - 0.001));
        Assert.False(presentation.Snapshot().Visible);
        presentation.Advance(TimeSpan.FromSeconds(grace));
        Assert.True(presentation.Snapshot().Visible);
        Assert.Equal(HudPhase.Starting, presentation.Snapshot().Phase);
    }

    [Fact]
    public void StaleTerminalHideCannotDismissNewGeneration()
    {
        var presentation = new HudPresentation(new HudSessionLabel("p", "m", "1"));
        presentation.BeginCycle(1, TimeSpan.Zero);
        presentation.CaptureReady(1, TimeSpan.FromMilliseconds(100));
        presentation.StopRequested(1, TimeSpan.FromMilliseconds(800));
        presentation.Cancelled(1, TimeSpan.FromMilliseconds(900));
        presentation.BeginCycle(2, TimeSpan.FromMilliseconds(1500));
        presentation.CaptureReady(2, TimeSpan.FromMilliseconds(1580));
        presentation.Advance(TimeSpan.FromMilliseconds(1700));
        var snapshot = presentation.Snapshot();
        Assert.True(snapshot.Visible);
        Assert.Equal(HudPhase.Recording, snapshot.Phase);
        Assert.Equal(2ul, snapshot.Generation);

        presentation.Cancelled(2, TimeSpan.FromMilliseconds(2500));
        presentation.Advance(TimeSpan.FromMilliseconds(3300));
        Assert.False(presentation.Snapshot().Visible);
    }

    [Fact]
    public void LateOldGenerationEventsAreIgnored()
    {
        var presentation = new HudPresentation(new HudSessionLabel("p", "m", "1"));
        presentation.BeginCycle(2, TimeSpan.Zero);
        presentation.CaptureReady(2, TimeSpan.FromSeconds(0.1));
        Assert.False(presentation.InsertionSucceeded(1, TimeSpan.FromSeconds(1)));
        Assert.Equal(HudStatusKeys.Recording, presentation.Snapshot().StatusKey);
        Assert.Equal(2ul, presentation.Snapshot().Generation);
    }

    [Fact]
    public void TimerStartsOnlyAtFirstValidBuffer()
    {
        var presentation = new HudPresentation(new HudSessionLabel("p", "m", "1"));
        presentation.BeginCycle(1, TimeSpan.Zero);
        presentation.Advance(TimeSpan.FromSeconds(0.5));
        Assert.Equal(HudPhase.Starting, presentation.Snapshot().Phase);
        Assert.False(presentation.Snapshot().RecordingStarted);

        presentation.CaptureReady(1, TimeSpan.FromSeconds(0.6));
        presentation.Advance(TimeSpan.FromSeconds(2.6));
        var snapshot = presentation.Snapshot();
        Assert.True(snapshot.RecordingStarted);
        Assert.Equal("0:02", snapshot.ElapsedText);
    }

    [Fact]
    public void ProcessingTerminalHidesWithoutWaitingForRustOwner()
    {
        var presentation = new HudPresentation(new HudSessionLabel("p", "m", "1"));
        presentation.BeginCycle(1, TimeSpan.Zero);
        presentation.CaptureReady(1, TimeSpan.FromSeconds(0.1));
        presentation.StopRequested(1, TimeSpan.FromSeconds(0.9));
        presentation.Cancelled(1, TimeSpan.FromSeconds(1.2));
        Assert.Equal(HudPhase.Idle, presentation.Phase);
        Assert.Equal(HudStatusKeys.Cancelled, presentation.Snapshot().StatusKey);
        presentation.Advance(TimeSpan.FromSeconds(2.0));
        Assert.False(presentation.Snapshot().Visible);
    }

    [Fact]
    public void LevelSignalIsLatestValueOnly()
    {
        var signal = new HudLevelSignal();
        Assert.False(signal.TryConsume(out _));
        signal.Publish(0.1f);
        signal.Publish(0.9f);
        Assert.True(signal.TryConsume(out var value));
        Assert.Equal(0.9f, value, 0.0001);
        Assert.False(signal.TryConsume(out _));
    }

    [Fact]
    public void CaptureReadyBeforeStartEventKeepsRecordingAndTimer()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[] { new ProviderEntry("a", "A", string.Empty, string.Empty) },
        };
        using var app = new HostApp(config, new ImmediateReadySource(), new NoopInsertions());
        using var coordinator = new HudCoordinator(app, useTimer: false);

        app.Controller.AltDoubleTapped();

        var snapshot = coordinator.Snapshot;
        Assert.True(snapshot.Visible);
        Assert.Equal(HudPhase.Recording, snapshot.Phase);
        Assert.True(snapshot.RecordingStarted);

        // The previous cycle is terminal while the next first buffer arrives
        // before its start event; the new generation must still be visible.
        app.Controller.CancelKeyPressed();
        Assert.Equal(HudStatusKeys.Cancelled, coordinator.Snapshot.StatusKey);

        app.Controller.AltDoubleTapped();
        var next = coordinator.Snapshot;
        Assert.True(next.Visible);
        Assert.Equal(HudPhase.Recording, next.Phase);
        Assert.True(next.RecordingStarted);
        Assert.True(next.Generation > snapshot.Generation);
    }

    [Fact]
    public async Task ProcessingWatchdogCancelsTheTimedOutRecording()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[]
            {
                new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty),
            },
        };
        var insertions = new TrackingInsertions();
        using var app = new HostApp(config, new ImmediateReadySource(), insertions, new BlockingTransport(), _ => "k");
        var cancelled = new TaskCompletionSource<ulong>(TaskCreationOptions.RunContinuationsAsynchronously);
        app.Controller.CancelledWithRecordingId += id => cancelled.TrySetResult(id);
        using var coordinator = new HudCoordinator(
            app,
            processingWatchdog: TimeSpan.FromMilliseconds(50),
            useTimer: false);
        var timeout = new TaskCompletionSource<HudSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var sawCancelled = 0;
        coordinator.SnapshotChanged += snapshot =>
        {
            if (snapshot.StatusKey == HudStatusKeys.Cancelled)
            {
                Interlocked.Exchange(ref sawCancelled, 1);
            }
            if (snapshot.StatusArgumentKey == HudStatusKeys.ErrorSttTimeout)
            {
                timeout.TrySetResult(snapshot);
            }
        };

        app.Controller.AltDoubleTapped();
        app.Controller.AltDoubleTapped();

        var recordingId = await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(app.Controller.IsCancelRequested);
        // The timeout is published only after the controller confirms that it
        // cancelled this exact recording.
        var snapshot = await timeout.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(HudStatusKeys.Error, snapshot.StatusKey);
        Assert.Equal(HudStatusKeys.ErrorSttTimeout, snapshot.StatusArgumentKey);
        // The watchdog's synchronous cancellation event must not publish a
        // transient Cancelled snapshot before the timeout status.
        Assert.Equal(0, Volatile.Read(ref sawCancelled));
        Assert.False(app.Controller.CompleteWithTranscript("late", recordingId: recordingId));
        Assert.Empty(insertions.Inserted);
    }

    [Fact]
    public async Task ProcessingWatchdogDoesNotOverrideCommittedDelivery()
    {
        var config = new PortableConfig
        {
            ActiveProvider = "a",
            Providers = new[]
            {
                new ProviderEntry("a", "A", "https://a.test/v1/audio/transcriptions", string.Empty),
            },
        };
        var insertions = new TrackingInsertions();
        using var app = new HostApp(
            config,
            new ImmediateReadySource(),
            insertions,
            new ImmediateTransport(),
            _ => "k");
        var delivered = new TaskCompletionSource<DictationDelivery>(TaskCreationOptions.RunContinuationsAsynchronously);
        app.DeliveryCompleted += delivery => delivered.TrySetResult(delivery);
        using var coordinator = new HudCoordinator(
            app,
            processingWatchdog: TimeSpan.FromMilliseconds(200),
            useTimer: false);

        app.Controller.AltDoubleTapped();
        app.Controller.AltDoubleTapped();

        var delivery = await delivered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(delivery.Inserted);
        // Let the watchdog deadline pass: a committed delivery must not be
        // reported as a timeout or cancelled.
        await Task.Delay(300);
        var snapshot = coordinator.Snapshot;
        Assert.NotEqual(HudStatusKeys.ErrorSttTimeout, snapshot.StatusArgumentKey);
        Assert.Equal(HudStatusKeys.Finishing, snapshot.StatusKey);
        Assert.False(app.Controller.IsCancelRequested);
        Assert.Equal(new[] { "hi there" }, insertions.Inserted);
    }

    private sealed class ImmediateTransport : ISttTransport
    {
        public Task<SttHttpResponse> SendAsync(
            string url,
            IReadOnlyDictionary<string, string> headers,
            byte[] body,
            string contentType,
            TimeSpan timeout,
            CancellationToken cancellationToken) =>
            Task.FromResult(new SttHttpResponse(
                200,
                new Dictionary<string, string>(),
                System.Text.Encoding.UTF8.GetBytes("{\"text\": \"hi there\"}")));
    }

    private sealed class BlockingTransport : ISttTransport
    {
        public async Task<SttHttpResponse> SendAsync(
            string url,
            IReadOnlyDictionary<string, string> headers,
            byte[] body,
            string contentType,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            throw new OperationCanceledException(cancellationToken);
        }
    }

    private sealed class TrackingInsertions : IInsertionSink
    {
        public List<string> Inserted { get; } = new();

        public void Insert(string text, InsertMethod method) => Inserted.Add(text);

        public void DeleteText(string insertedText)
        {
        }

        public void DeleteGraphemes(int count)
        {
        }

        public void PostEnter()
        {
        }
    }

    private sealed class ImmediateReadySource : IAudioCaptureSource
    {
        private static readonly AudioFormat Audio = new(16000, 1, 32, true);

        public AudioFormat Format => Audio;

        public bool IsRunning { get; private set; }

        public event Action<CapturedBlock>? BlockAvailable;

        public event Action<Exception>? DeviceChanged;

        public void Start()
        {
            _ = DeviceChanged;
            IsRunning = true;
            // A fast device can deliver the first full engine block before
            // DictationController reports MicStartAttempted.Started.
            BlockAvailable?.Invoke(new CapturedBlock(new float[1600], 1600, Audio));
        }

        public void Stop() => IsRunning = false;

        public void Dispose() => IsRunning = false;
    }

    private sealed class NoopInsertions : IInsertionSink
    {
        public void Insert(string text, InsertMethod method)
        {
        }

        public void DeleteText(string insertedText)
        {
        }

        public void DeleteGraphemes(int count)
        {
        }

        public void PostEnter()
        {
        }
    }

    [Fact]
    public void LayoutUsesCaretPointerCenterFallback()
    {
        var caret = new HudPoint(100, 200);
        var pointer = new HudPoint(300, 400);
        var center = new HudPoint(500, 300);
        Assert.Equal(caret, HudLayout.ResolvePoint(caret, pointer, center, _ => true));
        Assert.Equal(pointer, HudLayout.ResolvePoint(null, pointer, center, _ => true));
        Assert.Equal(center, HudLayout.ResolvePoint(null, pointer, center, p => p == center));
    }

    [Fact]
    public void LayoutPlacesPanelAboveThenBelowAndClampsToScreen()
    {
        var screen = new HudRect(0, 0, 1440, 900);
        var panel = new HudSize(200, 150);

        var above = HudLayout.PanelFrame(new HudPoint(700, 500), screen, panel);
        Assert.Equal(700, above.X + above.Width / 2, 0.001);
        Assert.Equal(500 - 12 - 150, above.Y, 0.001);
        Assert.True(above.X >= 8 && above.Right <= screen.Right - 8);

        var below = HudLayout.PanelFrame(new HudPoint(700, 20), screen, panel);
        Assert.Equal(20 + 12, below.Y, 0.001);

        var left = HudLayout.PanelFrame(new HudPoint(2, 500), screen, panel);
        Assert.Equal(8, left.X, 0.001);

        var shortScreen = new HudRect(0, 0, 1440, 120);
        var clamped = HudLayout.PanelFrame(new HudPoint(700, 100), shortScreen, panel);

        var scaled = HudLayout.PanelFrame(
            new HudPoint(1000, 500),
            screen,
            new HudSize(440, 300),
            scale: 2);
        Assert.Equal(176, scaled.Y, 3);
        Assert.Equal(780, scaled.X, 3);
        Assert.Equal(8, clamped.Y, 0.001);
    }
}
