namespace NanoDictate.ConfigValidation;

/// <summary>Outcome of one strict configuration validation pass.</summary>
public sealed class ConfigValidationResult
{
    public ConfigValidationResult(string activeProvider, IEnumerable<string> errors)
    {
        ActiveProvider = activeProvider;
        Errors = errors.ToArray();
    }

    /// <summary>Selected provider id, or an empty string when selection failed.</summary>
    public string ActiveProvider { get; }

    /// <summary>Human-readable failures that never contain credential values.</summary>
    public IReadOnlyList<string> Errors { get; }

    public bool IsValid => Errors.Count == 0;
}
