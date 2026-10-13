using System.Text.Json;

namespace NanoDictate.Core;

/// <summary>
/// Resolved STT model profile. Every field is parsed from the shared Rust
/// engine (<c>nd_stt_resolve</c>); C# never branches on provider names or
/// model names to decide transport, audio shape, or response handling.
/// </summary>
public sealed record SttProfile(
    string AdapterId,
    string Model,
    string Transport,
    uint SampleRate,
    ushort Channels,
    string UploadFormat,
    bool SupportsFlac,
    bool SupportsVerboseJson,
    bool SupportsWordTimestamps,
    bool SupportsPrompt,
    bool SupportsTemperature,
    bool SupportsVadFilter,
    string LanguageHint,
    IReadOnlyList<string> TranscriptPath)
{
    public bool IsStreaming => Transport == "streaming_session";

    public bool IsRawAudio => Transport == "batch_raw_audio";

    /// <summary>
    /// Resolves a profile through the shared engine. Unknown ids use the
    /// engine conservative fallback; this method never special-cases names.
    /// </summary>
    public static SttProfile Resolve(string adapterId, string model)
    {
        var json = NanoEngine.SttResolve(adapterId, model);
        return Parse(json);
    }

    public static SttProfile Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        string Get(string name) =>
            root.TryGetProperty(name, out var v) ? v.GetString() ?? string.Empty : string.Empty;
        var audio = root.TryGetProperty("audio", out var a) ? a : (JsonElement?)null;
        uint rate = 16000;
        ushort channels = 1;
        var upload = "wav";
        var flac = false;
        if (audio.HasValue)
        {
            if (audio.Value.TryGetProperty("sample_rate", out var r) && r.TryGetUInt32(out var rv))
            {
                rate = rv;
            }
            if (audio.Value.TryGetProperty("channels", out var c) && c.TryGetUInt16(out var cv))
            {
                channels = cv;
            }
            if (audio.Value.TryGetProperty("upload_format", out var u))
            {
                upload = u.GetString() ?? upload;
            }
            if (audio.Value.TryGetProperty("supports_flac", out var f))
            {
                flac = f.ValueKind == JsonValueKind.True;
            }
        }
        var caps = root.TryGetProperty("capabilities", out var cp) ? cp : (JsonElement?)null;
        bool Flag(string name)
        {
            if (!caps.HasValue)
            {
                return false;
            }
            return caps.Value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
        }
        var hint = string.Empty;
        if (caps.HasValue && caps.Value.TryGetProperty("language_hint", out var h))
        {
            hint = h.GetString() ?? string.Empty;
        }
        var path = new List<string>();
        if (root.TryGetProperty("transcript_path", out var p) && p.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in p.EnumerateArray())
            {
                if (item.GetString() is { } s)
                {
                    path.Add(s);
                }
            }
        }
        return new SttProfile(
            Get("adapter_id"), Get("model"), Get("transport"),
            rate, channels, upload, flac,
            Flag("supports_verbose_json"), Flag("supports_word_timestamps"),
            Flag("supports_prompt"), Flag("supports_temperature"),
            Flag("supports_vad_filter"), hint, path);
    }

    /// <summary>Dotted transcript path for <c>nd_transcript_parse</c> (empty = flat text).</summary>
    public string TranscriptPathDotted => string.Join(".", TranscriptPath);
}
