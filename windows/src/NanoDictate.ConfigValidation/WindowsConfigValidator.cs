using NanoDictate.Core;
using Tomlyn;
using Tomlyn.Model;

namespace NanoDictate.ConfigValidation;

/// <summary>
/// Provider-agnostic validation for the shipped Windows TOML configuration.
/// TOML syntax, duplicate keys, table relationships, and provider field types
/// are checked structurally; effective endpoint/model defaults are resolved
/// through the same adapter contract the application uses. This type never
/// names the product default provider and never requires credentials from a
/// keyless provider.
/// </summary>
public static class WindowsConfigValidator
{
    // The application's portable dialect uses the top-level `providers`
    // array for failover order even when `[providers.*]` tables exist. Strict
    // TOML treats those as one conflicting key, so the array key is renamed
    // only for syntax parsing and then validated as a string array.
    private const string ProvidersOrderSentinel = "__nanodictate_validation_providers_order__";

    private static readonly HashSet<string> StringProviderFields = new(StringComparer.Ordinal)
    {
        "name",
        "base_url",
        "model",
        "api_key",
        "api_key_file",
        "transport",
        "http_proxy",
        "proxy_user",
        "proxy_password",
        "proxy_key",
        "proxy_key_header",
        "upload_format",
    };

    private static readonly HashSet<string> TopLevelStringFields = new(StringComparer.Ordinal)
    {
        "base_url",
        "model",
        "api_key",
        "api_key_file",
        "proxy_key",
        "proxy_key_header",
        "transport",
        "http_proxy",
        "proxy_user",
        "proxy_password",
        "log_level",
        "language",
        "ui_language",
        "prompt",
        "realtime_model",
    };

    private static readonly HashSet<string> TopLevelNumberFields = new(StringComparer.Ordinal)
    {
        "timeout_seconds",
        "double_alt_max_interval",
        "undo_max_interval",
    };

    private static readonly HashSet<string> TopLevelBooleanFields = new(StringComparer.Ordinal)
    {
        "sounds_enabled",
        "undo_sound_enabled",
        "auto_failover",
        "review_before_insert",
        "chunked",
    };

    private static readonly HashSet<string> TopLevelStringArrayFields = new(StringComparer.Ordinal)
    {
        "vocabulary",
        "extra_languages",
    };

    private static readonly HashSet<string> UploadFormats = new(StringComparer.OrdinalIgnoreCase)
    {
        string.Empty,
        "auto",
        "wav",
        "flac",
        "opus",
        "opus-experimental",
    };

    private static readonly HashSet<string> InsertMethods = new(StringComparer.OrdinalIgnoreCase)
    {
        string.Empty,
        "cgevent",
        "clipboard",
        "direct",
        "sendinput",
    };

    private static readonly HashSet<string> FinalPassPolicies = new(StringComparer.OrdinalIgnoreCase)
    {
        string.Empty,
        "always",
        "on-uncertainty",
        "onuncertainty",
        "auto",
        "uncertainty",
        "never",
        "off",
        "none",
    };

    public static ConfigValidationResult ValidateFile(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return new ConfigValidationResult(string.Empty, new[] { "config path must not be empty" });
        }
        if (!File.Exists(path))
        {
            return new ConfigValidationResult(string.Empty, new[] { "config file does not exist" });
        }

        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new ConfigValidationResult(
                string.Empty,
                new[] { $"config file cannot be read ({ex.GetType().Name})" });
        }
        return ValidateText(text, path);
    }

    private static ConfigValidationResult ValidateText(string text, string path)
    {
        var errors = new List<string>();
        var activeProvider = string.Empty;

        if (text.Length > 0 && text[0] == '\uFEFF')
        {
            text = text[1..];
        }
        text = PreparePortableDialect(text);

        if (!Toml.TryToModel<TomlTable>(text, out var root, out var diagnostics) || root is null)
        {
            if (diagnostics is not null)
            {
                foreach (var diagnostic in diagnostics)
                {
                    // Diagnostic.Message may echo duplicate raw values, including
                    // api_key material. Location-only diagnostics stay safe in CI.
                    errors.Add($"invalid TOML at {diagnostic.Span}");
                }
            }
            if (errors.Count == 0)
            {
                errors.Add("invalid TOML");
            }
            return new ConfigValidationResult(activeProvider, errors);
        }

        if (root.TryGetValue(ProvidersOrderSentinel, out var providersOrder)
            && (providersOrder is not TomlArray orderArray
                || orderArray.Any(item => item is not string)))
        {
            errors.Add("top-level providers failover order must be an array of strings");
        }

        ValidateTopLevelTypes(root, errors);
        ValidateTopLevelOption(
            root, "upload_format", value => UploadFormats.Contains(value.Trim()), errors);
        ValidateTopLevelOption(
            root, "insert_method", value => InsertMethods.Contains(value.Trim()), errors);
        ValidateTopLevelOption(
            root,
            "chunked_final_pass",
            value => FinalPassPolicies.Contains(value.Trim().Replace('_', '-')),
            errors);

        if (root.TryGetValue("active_provider", out var activeValue))
        {
            if (activeValue is not string activeText)
            {
                errors.Add("top-level active_provider must be a string");
            }
            else
            {
                activeProvider = activeText;
            }
        }

        if (!root.TryGetValue("providers", out var providersValue) || providersValue is not TomlTable providers)
        {
            errors.Add("missing top-level [providers.*] table");
            return new ConfigValidationResult(activeProvider, errors);
        }

        foreach (var provider in providers)
        {
            if (provider.Value is not TomlTable providerTable)
            {
                errors.Add("provider entry must be a table");
                continue;
            }
            ValidateProviderFieldTypes(providerTable, errors);
        }

        PortableConfig config;
        try
        {
            config = PortableConfig.Load(path);
        }
        catch (Exception ex)
        {
            errors.Add($"application config parser rejected the file ({ex.GetType().Name})");
            return new ConfigValidationResult(activeProvider, errors);
        }

        if (string.IsNullOrWhiteSpace(activeProvider))
        {
            if (HasLegacySttKeys(root))
            {
                errors.Add(
                    "ambiguous config: top-level legacy STT keys and provider sections require active_provider");
            }
            // The application treats an omitted/empty active provider as the
            // first declared [providers.*] section. Keep that documented
            // fallback instead of demanding a redundant explicit key.
            var first = config.Providers.FirstOrDefault();
            if (first is null)
            {
                errors.Add("no provider sections are configured");
                return new ConfigValidationResult(activeProvider, errors);
            }
            activeProvider = first.Id;
        }

        if (!providers.TryGetValue(activeProvider, out var selectedValue))
        {
            errors.Add("active_provider has no matching provider table");
            return new ConfigValidationResult(activeProvider, errors);
        }
        if (selectedValue is not TomlTable)
        {
            errors.Add("active_provider must refer to a provider table");
            return new ConfigValidationResult(activeProvider, errors);
        }

        var entry = config.Providers.FirstOrDefault(provider => provider.Id == activeProvider);
        if (entry is null)
        {
            errors.Add("active_provider is not a supported provider section");
            return new ConfigValidationResult(activeProvider, errors);
        }

        var usesDefaultBaseUrl = string.IsNullOrWhiteSpace(entry.BaseUrl);
        var effectiveBaseUrl = usesDefaultBaseUrl
            ? AdapterDefaults.BaseUrl(entry.Id)
            : entry.BaseUrl;
        if (string.IsNullOrWhiteSpace(effectiveBaseUrl))
        {
            errors.Add("selected provider has no base_url and no default endpoint");
        }
        else if (!Uri.TryCreate(effectiveBaseUrl, UriKind.Absolute, out var endpoint)
            || (endpoint.Scheme != Uri.UriSchemeHttp && endpoint.Scheme != Uri.UriSchemeHttps))
        {
            errors.Add("selected provider has an invalid base_url");
        }

        var effectiveModel = string.IsNullOrWhiteSpace(entry.Model)
            ? AdapterDefaults.Model(entry.Id)
            : entry.Model;
        if (string.IsNullOrWhiteSpace(effectiveModel)
            && !AdapterDefaults.ModelEmbeddedInEndpoint(entry.Id))
        {
            errors.Add("selected provider has no model and no default model");
        }

        if (usesDefaultBaseUrl
            && AdapterDefaults.DefaultEndpointRequiresCredential(entry.Id)
            && string.IsNullOrEmpty(entry.ApiKey)
            && string.IsNullOrEmpty(entry.ApiKeyFile))
        {
            errors.Add("selected provider requires a declared api_key or api_key_file");
        }

        return new ConfigValidationResult(activeProvider, errors);
    }

    private static string PreparePortableDialect(string text)
    {
        var lines = text.Split('\n');
        var topLevel = true;
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var content = line.TrimStart();
            if (content.Length == 0 || content[0] == '#')
            {
                continue;
            }
            if (content[0] == '[')
            {
                topLevel = false;
                continue;
            }
            if (!topLevel || !content.StartsWith("providers", StringComparison.Ordinal))
            {
                continue;
            }
            var suffix = content["providers".Length..];
            var index = 0;
            while (index < suffix.Length && (suffix[index] == ' ' || suffix[index] == '\t'))
            {
                index++;
            }
            if (index >= suffix.Length || suffix[index] != '=')
            {
                continue;
            }
            var indent = line[..(line.Length - content.Length)];
            lines[i] = indent + ProvidersOrderSentinel + suffix;
        }
        return string.Join('\n', lines);
    }

    private static void ValidateProviderFieldTypes(
        TomlTable table,
        ICollection<string> errors)
    {
        foreach (var field in table)
        {
            if (!StringProviderFields.Contains(field.Key))
            {
                continue;
            }
            if (field.Value is not string textValue)
            {
                errors.Add("provider field must be a string");
                continue;
            }
            if (field.Key == "upload_format" && !UploadFormats.Contains(textValue.Trim()))
            {
                errors.Add("provider upload_format has an unsupported value");
            }
        }
    }

    private static void ValidateTopLevelTypes(TomlTable root, ICollection<string> errors)
    {
        foreach (var (key, value) in root)
        {
            if (TopLevelStringFields.Contains(key) && value is not string)
            {
                errors.Add($"top-level {key} must be a string");
            }
            else if (TopLevelNumberFields.Contains(key) && value is not (long or double))
            {
                errors.Add($"top-level {key} must be a number");
            }
            else if (TopLevelBooleanFields.Contains(key) && value is not bool)
            {
                errors.Add($"top-level {key} must be a boolean");
            }
            else if (TopLevelStringArrayFields.Contains(key)
                && (value is not TomlArray array || array.Any(item => item is not string)))
            {
                errors.Add($"top-level {key} must be an array of strings");
            }
        }
    }

    private static bool HasLegacySttKeys(TomlTable root) =>
        root.ContainsKey("base_url")
        || root.ContainsKey("model")
        || root.ContainsKey("api_key")
        || root.ContainsKey("api_key_file")
        || root.ContainsKey("proxy_key");

    private static void ValidateTopLevelOption(
        TomlTable root,
        string key,
        Func<string, bool> isValid,
        ICollection<string> errors)
    {
        if (!root.TryGetValue(key, out var value))
        {
            return;
        }
        if (value is not string textValue)
        {
            errors.Add($"top-level {key} must be a string");
        }
        else if (!isValid(textValue))
        {
            errors.Add($"top-level {key} has an unsupported value");
        }
    }
}
