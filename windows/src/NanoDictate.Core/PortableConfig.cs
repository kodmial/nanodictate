namespace NanoDictate.Core;

/// <summary>
/// Portable configuration record. This type only carries data parsed from
/// the shared TOML shape (see config.example.toml); every policy decision
/// (profile resolution, failover ordering, backoff, transcript rules) is
/// computed by the Rust engine through <see cref="NanoEngine"/>.
/// </summary>
public sealed record ProviderEntry(string Id, string Name, string BaseUrl, string Model);

public sealed class PortableConfig
{
    public string ActiveProvider { get; init; } = string.Empty;
    public string Language { get; init; } = string.Empty;
    public IReadOnlyList<ProviderEntry> Providers { get; init; } = Array.Empty<ProviderEntry>();
    public string SegmentProvider { get; init; } = string.Empty;
    public string FinalProvider { get; init; } = string.Empty;

    /// <summary>
    /// Loads the portable subset of a NanoDictate TOML config. Unknown keys
    /// and platform-specific sections are ignored; no policy is applied
    /// here.
    /// </summary>
    public static PortableConfig Load(string path)
    {
        var active = string.Empty;
        var language = string.Empty;
        var segment = string.Empty;
        var final = string.Empty;
        var providers = new List<ProviderEntry>();
        string? currentProvider = null;
        string name = string.Empty, baseUrl = string.Empty, model = string.Empty;

        void FlushProvider()
        {
            if (currentProvider is not null)
            {
                providers.Add(new ProviderEntry(currentProvider, name, baseUrl, model));
                currentProvider = null;
                name = baseUrl = model = string.Empty;
            }
        }

        string? section = null;
        foreach (var raw in File.ReadAllLines(path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
            {
                continue;
            }
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                FlushProvider();
                section = line.Substring(1, line.Length - 2).Trim();
                if (section.StartsWith("providers.", StringComparison.Ordinal))
                {
                    currentProvider = section.Substring("providers.".Length);
                }
                continue;
            }
            var eq = line.IndexOf('=');
            if (eq < 0)
            {
                continue;
            }
            var key = line.Substring(0, eq).Trim();
            var value = Unquote(line.Substring(eq + 1).Trim());
            if (currentProvider is not null)
            {
                switch (key)
                {
                    case "name": name = value; break;
                    case "base_url": baseUrl = value; break;
                    case "model": model = value; break;
                }
            }
            else if (section == "routing")
            {
                switch (key)
                {
                    case "segment_provider": segment = value; break;
                    case "final_provider": final = value; break;
                }
            }
            else if (section is null)
            {
                switch (key)
                {
                    case "active_provider": active = value; break;
                    case "language": language = value; break;
                }
            }
        }
        FlushProvider();

        return new PortableConfig
        {
            ActiveProvider = active,
            Language = language,
            Providers = providers,
            SegmentProvider = segment,
            FinalProvider = final,
        };
    }

    private static string Unquote(string value)
    {
        if (value.Length >= 2 && value.StartsWith('"') && value.EndsWith('"'))
        {
            return value.Substring(1, value.Length - 2);
        }
        if (value.Length >= 2 && value.StartsWith('\'') && value.EndsWith('\''))
        {
            return value.Substring(1, value.Length - 2);
        }
        return value;
    }

    private ProviderEntry? Find(string id) =>
        Providers.FirstOrDefault(p => p.Id == id);

    /// <summary>
    /// Resolves the active provider model profile through Rust. Unknown ids
    /// use the engine conservative fallback; this method never branches on
    /// provider names itself.
    /// </summary>
    public string ResolveActiveProfile()
    {
        var entry = Find(ActiveProvider);
        var adapter = entry?.Id ?? ActiveProvider;
        var model = entry?.Model ?? string.Empty;
        return NanoEngine.SttResolve(adapter, model);
    }

    /// <summary>
    /// Orders failover candidates through Rust. The ordering policy lives in
    /// the engine; this method only supplies the configured id list.
    /// </summary>
    public string ResolveFailoverOrder(string? failedId, bool autoFailover)
    {
        var ids = Providers.Select(p => p.Id).ToList();
        return NanoEngine.FailoverOrder(ids, failedId, autoFailover);
    }
}
