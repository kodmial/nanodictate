namespace NanoDictate.ConfigValidation;

/// <summary>
/// Managed mirror of the shared Rust adapter defaults. The validator is a
/// static packaging gate and must not require a live provider, network, or
/// credentials, so it resolves the same built-in defaults as the application
/// before deciding whether a provider has a usable endpoint/model.
/// </summary>
public static class AdapterDefaults
{
    private static readonly IReadOnlyDictionary<string, AdapterDefault> Known =
        new Dictionary<string, AdapterDefault>(StringComparer.Ordinal)
        {
            ["openai"] = new(
                "https://api.openai.com/v1/audio/transcriptions",
                "gpt-transcribe",
                ModelEmbeddedInEndpoint: false,
                RequiresCredentialForDefaultEndpoint: true),
            ["groq"] = new(
                "https://api.groq.com/openai/v1/audio/transcriptions",
                "whisper-large-v3",
                ModelEmbeddedInEndpoint: false,
                RequiresCredentialForDefaultEndpoint: true),
            ["cloudflare"] = new(
                string.Empty,
                string.Empty,
                ModelEmbeddedInEndpoint: true,
                RequiresCredentialForDefaultEndpoint: false),
        };

    public static string BaseUrl(string adapterId) =>
        Known.TryGetValue(adapterId, out var value) ? value.BaseUrl : string.Empty;

    public static string Model(string adapterId) =>
        Known.TryGetValue(adapterId, out var value) ? value.Model : string.Empty;

    /// <summary>
    /// Cloudflare embeds the model in the Workers AI URL instead of a model
    /// field, matching the shared STT registry.
    /// </summary>
    public static bool ModelEmbeddedInEndpoint(string adapterId) =>
        Known.TryGetValue(adapterId, out var value) && value.ModelEmbeddedInEndpoint;

    /// <summary>
    /// Whether the adapter's built-in endpoint requires an authentication
    /// credential. Custom endpoints stay keyless even for these adapters.
    /// </summary>
    public static bool DefaultEndpointRequiresCredential(string adapterId) =>
        Known.TryGetValue(adapterId, out var value)
        && value.RequiresCredentialForDefaultEndpoint;

    private sealed record AdapterDefault(
        string BaseUrl,
        string Model,
        bool ModelEmbeddedInEndpoint,
        bool RequiresCredentialForDefaultEndpoint);
}
