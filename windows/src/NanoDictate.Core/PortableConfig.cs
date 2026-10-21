namespace NanoDictate.Core;

/// <summary>
/// Portable configuration record. This type only carries data parsed from
/// the shared TOML shape (see config.example.toml); every policy decision
/// (profile resolution, failover ordering, backoff, transcript rules) is
/// computed by the Rust engine through <see cref="NanoEngine"/>.
/// </summary>
public sealed record ProviderEntry(
    string Id,
    string Name,
    string BaseUrl,
    string Model,
    string ApiKey = "",
    string? ApiKeyFile = null)
{
    /// <summary>
    /// Redacts configured secrets from diagnostic/object output. Request
    /// headers are the only place a resolved key may be materialized.
    /// </summary>
    public override string ToString() =>
        $"ProviderEntry {{ Id = {Id}, Name = {Name}, BaseUrl = {BaseUrl}, Model = {Model}, "
        + $"ApiKey = {(string.IsNullOrEmpty(ApiKey) ? "empty" : "redacted")}, "
        + $"ApiKeyFile = {(string.IsNullOrEmpty(ApiKeyFile) ? "none" : "configured")} }}";
}

public sealed class PortableConfig
{
    public string ActiveProvider { get; set; } = string.Empty;
    public string Language { get; init; } = string.Empty;
    public IReadOnlyList<ProviderEntry> Providers { get; init; } = Array.Empty<ProviderEntry>();
    /// <summary>Explicit top-level failover order (`providers = [...]`); empty uses section order.</summary>
    public IReadOnlyList<string> ProvidersOrder { get; init; } = Array.Empty<string>();
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
    /// <summary>STT transport mode (default direct).</summary>
    public TransportConfig Transport { get; init; } = TransportConfig.Direct;
    /// <summary>Proxy/gateway secret (never logged).</summary>
    public string ProxyKey { get; init; } = string.Empty;
    /// <summary>Chunked long-form mode (default false).</summary>
    public bool Chunked { get; init; }
    /// <summary>Chunked final-pass policy (default on-uncertainty).</summary>
    public ChunkedFinalPass ChunkedFinalPass { get; init; } = ChunkedFinalPass.OnUncertainty;
    /// <summary>STT request timeout in seconds (default 120).</summary>
    public double TimeoutSeconds { get; init; } = 120;
    /// <summary>Automatic provider failover (default false).</summary>
    public bool AutoFailover { get; init; }
    /// <summary>Prompt/context bias for STT (default empty).</summary>
    public string Prompt { get; init; } = string.Empty;
    /// <summary>Realtime model id (default gpt-live-transcribe).</summary>
    public string RealtimeModel { get; init; } = "gpt-live-transcribe";

    /// <summary>
    /// Repairs an unknown <see cref="ActiveProvider"/> by selecting the first
    /// configured provider. An omitted active provider stays empty so the
    /// shared parity contract remains intact; routing and environment-key
    /// resolution already treat an empty id as the first provider. A
    /// provider-less config is left as-is so startup can still surface an
    /// unconfigured HUD and settings.
    /// </summary>
    public void NormalizeProviderSelection()
    {
        if (Providers.Count == 0 || string.IsNullOrEmpty(ActiveProvider))
        {
            return;
        }
        if (Providers.All(p => p.Id != ActiveProvider))
        {
            ActiveProvider = Providers[0].Id;
        }
    }

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
        var transportMode = SttTransportMode.Direct;
        var httpProxy = string.Empty;
        var proxyUser = string.Empty;
        var proxyPassword = string.Empty;
        var proxyKey = string.Empty;
        var proxyKeyHeader = "X-Proxy-Key";
        var chunked = false;
        var finalPass = ChunkedFinalPass.OnUncertainty;
        var timeoutSeconds = 120.0;
        var autoFailover = false;
        var prompt = string.Empty;
        var realtimeModel = "gpt-live-transcribe";
        var providers = new List<ProviderEntry>();
        var providersOrder = new List<string>();
        string? currentProvider = null;
        string name = string.Empty, baseUrl = string.Empty, model = string.Empty;
        string apiKey = string.Empty;
        string? apiKeyFile = null;

        void FlushProvider()
        {
            if (currentProvider is not null)
            {
                providers.Add(new ProviderEntry(
                    currentProvider, name, baseUrl, model, apiKey, apiKeyFile));
                currentProvider = null;
                name = baseUrl = model = string.Empty;
                apiKey = string.Empty;
                apiKeyFile = null;
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
                    case "api_key": apiKey = value; break;
                    case "api_key_file":
                        apiKeyFile = string.IsNullOrEmpty(value) ? null : value;
                        break;
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
                    case "prompt": prompt = value; break;
                    case "providers":
                        providersOrder = ParseStringArray(value);
                        break;
                    case "realtime_model": realtimeModel = value; break;
                    case "transport":
                        transportMode = TransportConfig.ParseMode(value.ToLowerInvariant());
                        break;
                    case "http_proxy": httpProxy = value; break;
                    case "proxy_user": proxyUser = value; break;
                    case "proxy_password": proxyPassword = value; break;
                    case "proxy_key": proxyKey = value; break;
                    case "proxy_key_header":
                        if (!string.IsNullOrEmpty(value))
                        {
                            proxyKeyHeader = value;
                        }
                        break;
                    case "chunked":
                        chunked = value.Equals("true", StringComparison.OrdinalIgnoreCase) || value == "1";
                        break;
                    case "chunked_final_pass":
                        finalPass = ChunkedTranscriber.ParseFinalPass(value.ToLowerInvariant());
                        break;
                    case "timeout_seconds":
                        if (double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var t) && t > 0 && t <= 600)
                        {
                            timeoutSeconds = t;
                        }
                        break;
                    case "auto_failover":
                        autoFailover = value.Equals("true", StringComparison.OrdinalIgnoreCase) || value == "1";
                        break;
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
            ProvidersOrder = providersOrder,
            SegmentProvider = segment,
            FinalProvider = final,
            InsertMethod = insertMethod,
            DoubleAltMaxInterval = doubleAltMaxInterval,
            UndoMaxInterval = undoMaxInterval,
            ReviewBeforeInsert = reviewBeforeInsert,
            Transport = new TransportConfig(transportMode, httpProxy, proxyUser, proxyPassword, proxyKey, proxyKeyHeader),
            ProxyKey = proxyKey,
            Chunked = chunked,
            ChunkedFinalPass = finalPass,
            TimeoutSeconds = timeoutSeconds,
            AutoFailover = autoFailover,
            Prompt = prompt,
            RealtimeModel = realtimeModel,
        };
    }

    /// <summary>
    /// Parses a TOML string array (<c>providers = ["groq", "local"]</c>).
    /// Commas inside quoted entries stay part of the entry; malformed arrays
    /// are treated as absent so existing configs keep loading.
    /// </summary>
    private static List<string> ParseStringArray(string value)
    {
        var result = new List<string>();
        var trimmed = value.Trim();
        if (trimmed.Length < 2 || !trimmed.StartsWith('[') || !trimmed.EndsWith(']'))
        {
            return result;
        }
        var current = new System.Text.StringBuilder();
        var inQuotes = false;
        void Add()
        {
            var item = Unquote(current.ToString().Trim());
            if (item.Length > 0)
            {
                result.Add(item);
            }
            current.Clear();
        }
        for (var i = 1; i < trimmed.Length - 1; i++)
        {
            var c = trimmed[i];
            if (c == '"')
            {
                inQuotes = !inQuotes;
                current.Append(c);
            }
            else if (c == ',' && !inQuotes)
            {
                Add();
            }
            else
            {
                current.Append(c);
            }
        }
        Add();
        return result;
    }

    /// <summary>
    /// Reads a provider key from an <c>api_key_file</c> path: the first
    /// non-empty, non-comment line, with surrounding double quotes removed
    /// (same contract as macOS Config.readAPIKeyFile). Home and environment
    /// variables are expanded; unreadable or missing files yield an empty
    /// key rather than failing the host. The content is never logged.
    /// </summary>
    public static string ReadApiKeyFile(string path)
    {
        try
        {
            var expanded = ExpandKeyFilePath(path);
            if (string.IsNullOrEmpty(expanded))
            {
                return string.Empty;
            }
            foreach (var raw in File.ReadLines(expanded))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith('#'))
                {
                    continue;
                }
                if (line.Length >= 2 && line.StartsWith('"') && line.EndsWith('"'))
                {
                    return line.Substring(1, line.Length - 2);
                }
                return line;
            }
        }
        catch (Exception ex) when (IsExpectedFileError(ex))
        {
            // Missing/unreadable key files are a normal keyless configuration.
        }
        return string.Empty;
    }

    /// <summary>
    /// Expands <c>~</c>, environment variables, and normalizes the key path.
    /// Returns an empty string for invalid paths so callers never partially
    /// resolve a secret path.
    /// </summary>
    public static string ExpandKeyFilePath(string path)
    {
        var trimmed = path.Trim();
        if (trimmed.Length == 0)
        {
            return string.Empty;
        }
        if (trimmed == "~" || trimmed.StartsWith("~/", StringComparison.Ordinal)
            || trimmed.StartsWith("~\\", StringComparison.Ordinal))
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (string.IsNullOrEmpty(home))
            {
                return string.Empty;
            }
            trimmed = trimmed.Length == 1 ? home : Path.Combine(home, trimmed.Substring(2));
        }
        trimmed = Environment.ExpandEnvironmentVariables(trimmed);
        try
        {
            return Path.GetFullPath(trimmed);
        }
        catch (Exception ex) when (IsExpectedFileError(ex))
        {
            return string.Empty;
        }
    }

    private static bool IsExpectedFileError(Exception ex) =>
        ex is IOException
            or UnauthorizedAccessException
            or ArgumentException
            or NotSupportedException
            or System.Security.SecurityException;

    /// <summary>
    /// Persists the two user-editable selection settings without reserializing
    /// the file, so provider sections, comments, and unrelated values stay
    /// intact. The file is replaced atomically after both keys are updated.
    /// </summary>
    public static void SaveSettings(string path, string activeProvider, bool reviewBeforeInsert)
    {
        var content = File.Exists(path) ? File.ReadAllText(path) : string.Empty;
        content = UpdateRootKey(content, "active_provider", Quote(activeProvider));
        content = UpdateRootKey(content, "review_before_insert", reviewBeforeInsert ? "true" : "false");
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, content);
        File.Move(temporary, path, overwrite: true);
    }

    private static string Quote(string value) =>
        "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    private static string UpdateRootKey(string content, string key, string value)
    {
        var newline = content.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var lines = content.Replace("\r\n", "\n").Split('\n').ToList();
        var firstSection = -1;
        var replaced = false;
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            var leading = 0;
            while (leading < line.Length && (line[leading] == ' ' || line[leading] == '\t'))
            {
                leading++;
            }
            var stripped = line.Substring(leading);
            var header = stripped;
            var comment = header.IndexOf('#');
            if (comment >= 0)
            {
                header = header.Substring(0, comment);
            }
            header = header.Trim();
            if (header.StartsWith('[') && header.EndsWith(']'))
            {
                firstSection = i;
                break;
            }
            var equals = stripped.IndexOf('=');
            if (equals < 0 || stripped.Substring(0, equals).Trim() != key)
            {
                continue;
            }
            var equalsInLine = leading + equals;
            var valueStart = equalsInLine + 1;
            while (valueStart < line.Length && (line[valueStart] == ' ' || line[valueStart] == '\t'))
            {
                valueStart++;
            }
            if (valueStart < line.Length && line[valueStart] == '"')
            {
                var close = FindClosingQuote(line, valueStart + 1);
                if (close >= 0)
                {
                    lines[i] = line.Substring(0, valueStart) + value + line.Substring(close + 1);
                    replaced = true;
                    break;
                }
            }
            var searchFrom = valueStart;
            if (valueStart < line.Length && line[valueStart] == '\'')
            {
                var closeSingle = line.IndexOf('\'', valueStart + 1);
                searchFrom = closeSingle >= 0 ? closeSingle + 1 : line.Length;
            }
            var hash = line.IndexOf('#', searchFrom);
            var trailing = hash >= 0 ? " " + line.Substring(hash) : string.Empty;
            lines[i] = line.Substring(0, valueStart).TrimEnd() + " " + value + trailing;
            replaced = true;
            break;
        }

        if (!replaced && firstSection >= 0)
        {
            lines.Insert(firstSection, $"{key} = {value}");
        }
        var result = string.Join(newline, lines);
        if (!replaced && firstSection < 0)
        {
            if (!string.IsNullOrEmpty(result) && !result.EndsWith(newline, StringComparison.Ordinal))
            {
                result += newline;
            }
            result += $"{key} = {value}{newline}";
        }
        return result;
    }

    private static int FindClosingQuote(string line, int start)
    {
        for (var i = start; i < line.Length; i++)
        {
            if (line[i] == '\\')
            {
                i++;
            }
            else if (line[i] == '"')
            {
                return i;
            }
        }
        return -1;
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
    /// Effective failover id order: the explicit top-level <c>providers</c>
    /// list when present, otherwise section order. Unknown ids are skipped and
    /// duplicates collapse (macOS failoverProviders contract).
    /// </summary>
    public IReadOnlyList<string> FailoverOrderIds
    {
        get
        {
            var source = ProvidersOrder.Count == 0
                ? Providers.Select(p => p.Id)
                : ProvidersOrder;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var result = new List<string>();
            foreach (var id in source)
            {
                if (Find(id) is not null && seen.Add(id))
                {
                    result.Add(id);
                }
            }
            return result;
        }
    }

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
        if (string.IsNullOrEmpty(model))
        {
            model = NanoEngine.SttDefaultModel(adapter);
        }
        return NanoEngine.SttResolve(adapter, model);
    }

    /// <summary>
    /// Orders failover candidates through Rust. The ordering policy lives in
    /// the engine; this method only supplies the configured id list.
    /// </summary>
    public string ResolveFailoverOrder(string? failedId, bool autoFailover)
    {
        return NanoEngine.FailoverOrder(FailoverOrderIds, failedId, autoFailover);
    }
}
