namespace NanoDictate.Core;

/// <summary>One diagnostic check outcome (name, pass/fail, detail).</summary>
public sealed record DiagnosticCheck(string Name, bool Passed, string Detail);

/// <summary>
/// Windows diagnostics ("doctor"): engine ABI, config resolution, audio
/// format contract, and transcription planning — all without network or
/// hardware. Network reachability is a best-effort preflight only; the
/// hard request timeout backs up dictation when the preflight is silent.
/// </summary>
public static class WindowsDiagnostics
{
    public static IReadOnlyList<DiagnosticCheck> Run(string? configPath)
    {
        var checks = new List<DiagnosticCheck>();
        try
        {
            NanoEngine.CheckAvailable();
            checks.Add(new DiagnosticCheck("engine-abi", true, $"abi={NanoEngine.AbiVersion()}"));
        }
        catch (Exception ex)
        {
            checks.Add(new DiagnosticCheck("engine-abi", false, ex.Message));
            return checks;
        }
        if (!string.IsNullOrEmpty(configPath) && File.Exists(configPath))
        {
            try
            {
                var config = PortableConfig.Load(configPath);
                var profile = config.ResolveActiveProfile();
                var order = config.ResolveFailoverOrder(null, false);
                checks.Add(new DiagnosticCheck("config", true, $"provider={config.ActiveProvider} order={order} profile_bytes={profile.Length}"));
            }
            catch (Exception ex)
            {
                checks.Add(new DiagnosticCheck("config", false, ex.Message));
            }
        }
        else
        {
            checks.Add(new DiagnosticCheck("config", false, "config file not found"));
        }
        try
        {
            var diff = NanoEngine.WordDiff("One three.", "One two three.");
            var joined = NanoEngine.TextJoin(new[] { "hello brave world", "brave world again" });
            var transcript = NanoEngine.TranscriptParse("{\"text\": \"hi\"}");
            var ok = diff.Contains("change") && joined.Length > 0 && transcript.Contains("hi");
            checks.Add(new DiagnosticCheck("rust-policy", ok, ok ? "word-diff/text-join/transcript ok" : "policy vector mismatch"));
        }
        catch (Exception ex)
        {
            checks.Add(new DiagnosticCheck("rust-policy", false, ex.Message));
        }
        try
        {
            var device = new AudioFormat(48000, 2, 32, true);
            using var pipeline = new RealtimeAudioPipeline(device);
            pipeline.Start();
            var frames = new float[480 * device.Channels];
            Array.Fill(frames, 0.02f);
            for (var i = 0; i < 20 && !pipeline.IsCaptureReady; i++)
            {
                pipeline.IngestDeviceBlock(new CapturedBlock(frames, 480, device));
            }
            var ready = pipeline.IsCaptureReady;
            pipeline.Cancel();
            checks.Add(new DiagnosticCheck("audio-pipeline", ready, ready ? "synthetic first-buffer ready" : "readiness never fired"));
        }
        catch (Exception ex)
        {
            checks.Add(new DiagnosticCheck("audio-pipeline", false, ex.Message));
        }
        try
        {
            var profile = SttProfile.Resolve("openai", string.Empty);
            var realtime = SttProfile.Resolve("openai", "gpt-live-transcribe");
            var ok = !profile.IsStreaming && profile.SampleRate == 16000;
            checks.Add(new DiagnosticCheck("stt-profiles", ok, $"batch={profile.Transport}/{profile.SampleRate} realtime={realtime.Transport}"));
        }
        catch (Exception ex)
        {
            checks.Add(new DiagnosticCheck("stt-profiles", false, ex.Message));
        }
        return checks;
    }

    public static bool AllPassed(IReadOnlyList<DiagnosticCheck> checks) =>
        checks.Count > 0 && checks.All(c => c.Passed);
}
