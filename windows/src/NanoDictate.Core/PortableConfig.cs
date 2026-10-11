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
    /// <summary>Insertion method (default Direct for insert_method=cgevent).</summary>
    public InsertMethod InsertMethod { get; init; } = InsertMethod.Direct;
    /// <summary>Double-Alt window in seconds (default 0.4).</summary>
    public double DoubleAltMaxInterval { get; init; } = 0.4;
    /// <summary>Undo window in seconds (default 2.0).</summary>
    public double UndoMaxInterval { get; init; } = 2.0;
    /// <summary>Review-before-insert gate (default false).</summary>
    public bool ReviewBeforeInsert { get; init; }

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
        var insertMethod = InsertMethod.Direct;
        var doubleAltMaxInterval = 0.4;
        var undoMaxInterval = 2.0;
        var reviewBeforeInsert = false;
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
            var value = Unquote(StripInlineComment(line.Substring(eq + 1).Trim()));
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
                    case "insert_method":
                        insertMethod = InsertMethodParser.Parse(value);
                        break;
                    case "double_alt_max_interval":
                        if (double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) && d > 0 && d <= 5)
                        {
                            doubleAltMaxInterval = d;
                        }
                        break;
                    case "undo_max_interval":
                        if (double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var u) && u >= 0 && u <= 60)
                        {
                            undoMaxInterval = u;
                        }
                        break;
                    case "review_before_insert":
                        reviewBeforeInsert = value.Equals("true", StringComparison.OrdinalIgnoreCase) || value == "1";
                        break;
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
            InsertMethod = insertMethod,
            DoubleAltMaxInterval = doubleAltMaxInterval,
            UndoMaxInterval = undoMaxInterval,
            ReviewBeforeInsert = reviewBeforeInsert,
        };
    }

    private static string StripInlineComment(string value)
    {
        var inDouble = false;
        var inSingle = false;
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            if (inDouble)
            {
                if (c == '\\' && i + 1 < value.Length)
                {
                    i++;
                }
                else if (c == '"')
                {
                    inDouble = false;
                }
            }
            else if (inSingle)
            {
                if (c == '\'')
                {
                    inSingle = false;
                }
            }
            else if (c == '"')
            {
                inDouble = true;
            }
            else if (c == '\'')
            {
                inSingle = true;
            }
            else if (c == '#')
            {
                return value.Substring(0, i).TrimEnd();
            }
        }
        return value;
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
