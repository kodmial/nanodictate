using NanoDictate.Core;

namespace NanoDictate.ConfigValidation;

/// <summary>
/// Deliberate first-run product policy, kept separate from generic structural
/// validation. Changing the approved default provider updates this contract
/// and its focused test only; the generic validator never names it.
/// </summary>
public static class ProductDefaultPolicy
{
    public const string ActiveProvider = "airubiz";
    public const string BaseUrl = "https://api.airubiz.site/v1/audio/transcriptions";
    public const string Model = "gigaam-v3-ctc-sherpa";
    public const bool RequiresApiKey = false;

    public static IReadOnlyList<string> ValidateFile(string path)
    {
        var config = PortableConfig.Load(path);
        var errors = new List<string>();

        if (config.ActiveProvider != ActiveProvider)
        {
            errors.Add(
                $"product default policy: active_provider is '{config.ActiveProvider}', expected '{ActiveProvider}'");
        }

        var provider = config.Providers.FirstOrDefault(item => item.Id == ActiveProvider);
        if (provider is null)
        {
            errors.Add($"product default policy: missing [providers.{ActiveProvider}] section");
            return errors;
        }

        if (provider.BaseUrl != BaseUrl)
        {
            errors.Add($"product default policy: {ActiveProvider} base_url changed");
        }
        if (provider.Model != Model)
        {
            errors.Add($"product default policy: {ActiveProvider} model changed");
        }

        var keyless = string.IsNullOrEmpty(provider.ApiKey) && string.IsNullOrEmpty(provider.ApiKeyFile);
        if (RequiresApiKey && keyless)
        {
            errors.Add($"product default policy: {ActiveProvider} must configure a credential");
        }
        if (!RequiresApiKey && !keyless)
        {
            errors.Add($"product default policy: {ActiveProvider} must stay keyless");
        }

        return errors;
    }
}
