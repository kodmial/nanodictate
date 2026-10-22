using System.Text;
using NanoDictate.ConfigValidation;
using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>
/// Executable coverage for the shared Windows config predicate used by both
/// the CI distribution contract test and the release candidate smoke.
/// </summary>
public sealed class WindowsConfigValidationTests
{
    private const string OpenAiKeyless = """
        active_provider = "openai"
        [providers.openai]
        name = "OpenAI"
        base_url = ""
        model = ""
        api_key = ""
        """;

    private const string GroqWithKey = """
        active_provider = "groq"
        [providers.groq]
        name = "Groq"
        base_url = ""
        model = ""
        api_key = "dummy-key"
        """;

    private const string ProductDefault = """
        active_provider = "airubiz"
        [providers.airubiz]
        name = "Airubiz"
        base_url = "https://api.airubiz.site/v1/audio/transcriptions"
        model = "gigaam-v3-ctc-sherpa"
        api_key = ""
        """;

    [Fact]
    public void OfficialEndpointWithoutCredentialFailsWithLfAndNoFinalNewline()
    {
        var path = WriteConfig(OpenAiKeyless.TrimEnd('\n'));
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.False(result.IsValid);
            Assert.Contains(
                result.Errors,
                error => error.Contains(
                    "selected provider requires a declared api_key or api_key_file",
                    StringComparison.Ordinal));
            Assert.Equal("openai", result.ActiveProvider);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData("custom")]
    [InlineData("openai")]
    public void KeylessCustomEndpointRemainsValid(string adapter)
    {
        var config = $"""
            active_provider = "{adapter}"
            [providers.{adapter}]
            name = "Custom"
            base_url = "https://example.test/v1/audio/transcriptions"
            model = "m"
            api_key = ""
            """;
        AssertValid(config);
    }

    [Fact]
    public void GroqOfficialEndpointWithoutCredentialFails()
    {
        const string config = """
            active_provider = "groq"
            [providers.groq]
            base_url = ""
            model = ""
            api_key = ""
            """;
        AssertInvalid(config, "selected provider requires a declared api_key or api_key_file");
    }

    [Fact]
    public void CredentialAcceptingProviderPassesWithCrlfAndBom()
    {
        var path = WriteConfig(GroqWithKey, crlf: true, bom: true);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.True(result.IsValid, string.Join("; ", result.Errors));
            Assert.Equal("groq", result.ActiveProvider);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CrlfBytesRegressTheOldLineAnchoredPredicateButPassStructuredValidation()
    {
        // Release run 39590249896, job 119189176806 (SHA 42a1e3d) failed the
        // old line-anchored smoke predicate. That job skipped upload, so the
        // exact candidate ZIP bytes are unavailable; this reproduces the
        // predicate failure with the repository config converted to CRLF.
        // .NET leaves the CR before LF, so (?m)^...$ never matches that file.
        var crlf = ProductDefault.Replace("\r\n", "\n").Replace("\n", "\r\n");
        Assert.DoesNotMatch("(?m)^active_provider = \"airubiz\"$", crlf);
        Assert.DoesNotMatch("(?m)^\\[providers\\.airubiz\\]$", crlf);

        var path = WriteConfig(ProductDefault, crlf: true);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.True(result.IsValid, string.Join("; ", result.Errors));
            Assert.Empty(ProductDefaultPolicy.ValidateFile(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CommentsSpacingAndTwoProviderChoicesDoNotConfuseSelection()
    {
        const string config = """
            # active_provider = "airubiz" is only a comment here.
            active_provider = "openai" # deliberately OpenAI
            [providers.openai]
            name = "OpenAI"
            base_url = ""       # adapter default
            model = ""          # adapter default
            api_key = "dummy-key" # official endpoint requires a declared credential

            [providers.airubiz]
            name = "Airubiz"
            base_url = "https://api.airubiz.site/v1/audio/transcriptions"
            model = "gigaam-v3-ctc-sherpa"
            api_key = ""
            """;
        var path = WriteConfig(config);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.True(result.IsValid, string.Join("; ", result.Errors));
            Assert.Equal("openai", result.ActiveProvider);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void PortableDialectFailoverArrayCoexistsWithProviderTables()
    {
        const string config = """
            active_provider = "openai"
            providers = ["groq", "openai", "missing"]
            [providers.openai]
            base_url = ""
            model = ""
            api_key = "dummy-key"
            [providers.groq]
            base_url = ""
            model = ""
            api_key = "dummy-key"
            """;
        AssertValid(config);
    }

    [Fact]
    public void ProviderHeaderCommentsAreAcceptedLikeTheApplicationParser()
    {
        const string config = """
            active_provider = "airubiz" # explicit default
            [providers.airubiz] # canonical keyless section
            name = "Airubiz"
            base_url = "https://api.airubiz.site/v1/audio/transcriptions"
            model = "gigaam-v3-ctc-sherpa"
            api_key = ""
            """;
        var path = WriteConfig(config);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.True(result.IsValid, string.Join("; ", result.Errors));
            Assert.Empty(ProductDefaultPolicy.ValidateFile(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void MissingConfigFileFailsWithoutThrowing()
    {
        var missing = Path.Combine(
            Path.GetTempPath(),
            $"nanodictate-config-validation-missing-{Guid.NewGuid():N}.toml");
        var result = WindowsConfigValidator.ValidateFile(missing);
        Assert.False(result.IsValid);
        Assert.Contains(result.Errors, error => error.Contains("does not exist", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("language = \"en\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n")]
    [InlineData("active_provider = \"\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n")]
    [InlineData("# active_provider = \"airubiz\"\n[providers.airubiz]\nbase_url = \"https://api.airubiz.site/v1/audio/transcriptions\"\nmodel = \"gigaam-v3-ctc-sherpa\"\n")]
    public void OmittedOrEmptyActiveProviderUsesFirstProviderSection(string config)
    {
        var path = WriteConfig(config);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.True(result.IsValid, string.Join("; ", result.Errors));
            Assert.False(string.IsNullOrEmpty(result.ActiveProvider));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData("active_provider = \"missing\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "active_provider has no matching provider table")]
    [InlineData("active_provider = 42\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "top-level active_provider must be a string")]
    [InlineData("base_url = \"https://legacy.test\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "ambiguous config")]
    public void UnresolvableSelectionFails(string config, string expected)
    {
        AssertInvalid(config, expected);
    }

    [Theory]
    [InlineData("active_provider = \"a\"\nproviders = \"not-a-table\"\n", "missing top-level [providers.*] table")]
    [InlineData("active_provider = \"a\"\n[providers]\na = \"not-a-table\"\n", "provider entry must be a table")]
    [InlineData("active_provider = \"a\"\n[providers.a\n", "invalid TOML")]
    [InlineData("active_provider = \"a\"\nactive_provider = \"b\"\n[providers.a]\n", "invalid TOML")]
    [InlineData("active_provider = \"a\"\n[providers.a]\n[providers.a]\n", "invalid TOML")]
    [InlineData("active_provider = \"a\"\nproviders = [\"a\"]\nproviders = [\"b\"]\n[providers.a]\n", "invalid TOML")]
    [InlineData("active_provider = \"a\"\nproviders = \"not-an-array\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "top-level providers failover order must be an array of strings")]
    public void MalformedOrDuplicateStructureFails(string config, string expected)
    {
        AssertInvalid(config, expected);
    }

    [Fact]
    public void DuplicateSecretValuesAreNotEchoedInErrors()
    {
        const string config = """
            active_provider = "a"
            [providers.a]
            api_key = "super-secret-value"
            api_key = "other-secret-value"
            """;
        var path = WriteConfig(config);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.False(result.IsValid);
            Assert.DoesNotContain(result.Errors, error => error.Contains("secret", StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ConfigControlledIdentifiersAreNotEchoedInErrors()
    {
        const string secret = "super-secret-value";
        var unresolved = WriteConfig($"""
            active_provider = "{secret}"
            [providers.a]
            base_url = "https://example.test"
            model = "m"
            api_key = "{secret}"
            """);
        var policyMismatch = WriteConfig($"""
            active_provider = "{secret}"
            [providers.{secret}]
            base_url = "https://example.test"
            model = "m"
            api_key = ""
            """);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(unresolved);
            Assert.False(result.IsValid);
            Assert.Contains(result.Errors,
                error => error.Contains("active_provider has no matching provider table", StringComparison.Ordinal));
            Assert.DoesNotContain(result.Errors,
                error => error.Contains(secret, StringComparison.OrdinalIgnoreCase));

            Assert.True(WindowsConfigValidator.ValidateFile(policyMismatch).IsValid);
            var policyErrors = ProductDefaultPolicy.ValidateFile(policyMismatch);
            Assert.Contains(policyErrors,
                error => error.Contains("active_provider", StringComparison.Ordinal));
            Assert.DoesNotContain(policyErrors,
                error => error.Contains(secret, StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            File.Delete(unresolved);
            File.Delete(policyMismatch);
        }
    }

    [Theory]
    [InlineData("timeout_seconds = \"slow\"\nactive_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "top-level timeout_seconds must be a number")]
    [InlineData("sounds_enabled = \"yes\"\nactive_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "top-level sounds_enabled must be a boolean")]
    [InlineData("vocabulary = [1]\nactive_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "top-level vocabulary must be an array of strings")]
    [InlineData("active_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\nupload_format = \"bogus\"\n",
        "provider upload_format has an unsupported value")]
    [InlineData("insert_method = \"bogus\"\nactive_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "top-level insert_method has an unsupported value")]
    [InlineData("chunked_final_pass = \"bogus\"\nactive_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n",
        "top-level chunked_final_pass has an unsupported value")]
    public void KnownEnumValuesMatchTheParser(string config, string expected)
    {
        AssertInvalid(config, expected);
    }

    [Theory]
    [InlineData("active_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\nupload_format = \"opus\"\n")]
    [InlineData("insert_method = \"clipboard\"\nactive_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n")]
    [InlineData("chunked_final_pass = \"on_uncertainty\"\nactive_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = \"m\"\n")]
    public void KnownEnumAliasesAreAccepted(string config)
    {
        AssertValid(config);
    }

    [Theory]
    [InlineData("active_provider = \"a\"\n[providers.a]\nmodel = 42\n",
        "provider field must be a string")]
    [InlineData("active_provider = \"a\"\n[providers.a]\napi_key = 42\n",
        "provider field must be a string")]
    [InlineData("active_provider = \"a\"\n[providers.a]\napi_key_file = true\n",
        "provider field must be a string")]
    public void ProviderSchemaTypesAreEnforced(string config, string expected)
    {
        AssertInvalid(config, expected);
    }

    [Fact]
    public void SelectedProviderFieldTypesAreReportedOnce()
    {
        var path = WriteConfig(
            "active_provider = \"a\"\n[providers.a]\nbase_url = \"https://example.test\"\nmodel = 42\n");
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.False(result.IsValid);
            Assert.Single(
                result.Errors,
                error => error.Contains("provider field must be a string", StringComparison.Ordinal));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData("active_provider = \"custom\"\n[providers.custom]\nmodel = \"m\"\n",
        "selected provider has no base_url and no default endpoint")]
    [InlineData("active_provider = \"custom\"\n[providers.custom]\nbase_url = \"https://example.test/v1/audio/transcriptions\"\n",
        "selected provider has no model and no default model")]
    [InlineData("active_provider = \"custom\"\n[providers.custom]\nbase_url = \"not a URL\"\nmodel = \"m\"\n",
        "invalid base_url")]
    [InlineData("active_provider = \"cloudflare\"\n[providers.cloudflare]\nbase_url = \"\"\nmodel = \"\"\n",
        "selected provider has no base_url and no default endpoint")]
    public void EffectiveRequiredFieldsAreEnforced(string config, string expected)
    {
        AssertInvalid(config, expected);
    }

    [Fact]
    public void CloudflareModelInEndpointDoesNotRequireASeparateModelDefault()
    {
        const string config = """
            active_provider = "cloudflare"
            [providers.cloudflare]
            base_url = "https://api.cloudflare.com/client/v4/accounts/example/ai/run/@cf/openai/whisper-large-v3-turbo"
            model = ""
            api_key = "dummy-key"
            """;
        AssertValid(config);
    }

    [Fact]
    public void DeclaredKeyFileSatisfiesOfficialEndpointWithoutReadingContents()
    {
        const string config = """
            active_provider = "groq"
            [providers.groq]
            base_url = ""
            model = ""
            api_key = ""
            api_key_file = "~/.config/nanodictate/keys/does-not-exist.txt"
            """;
        AssertValid(config);
    }

    [Fact]
    public void ProductDefaultPolicyProtectsTheApprovedFirstRunContract()
    {
        Assert.Equal("airubiz", ProductDefaultPolicy.ActiveProvider);
        Assert.Equal("https://api.airubiz.site/v1/audio/transcriptions", ProductDefaultPolicy.BaseUrl);
        Assert.Equal("gigaam-v3-ctc-sherpa", ProductDefaultPolicy.Model);
        Assert.False(ProductDefaultPolicy.RequiresApiKey);

        var path = WriteConfig(ProductDefault);
        try
        {
            Assert.True(WindowsConfigValidator.ValidateFile(path).IsValid);
            Assert.Empty(ProductDefaultPolicy.ValidateFile(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ChangingTheDefaultProviderFailsPolicyButNotGenericValidation()
    {
        var path = WriteConfig(GroqWithKey);
        try
        {
            Assert.True(WindowsConfigValidator.ValidateFile(path).IsValid);
            var errors = ProductDefaultPolicy.ValidateFile(path);
            Assert.Contains(errors, error => error.Contains("active_provider", StringComparison.Ordinal));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ProductDefaultPolicyChecksModelAndKeylessnessSeparately()
    {
        var wrongModel = WriteConfig(ProductDefault.Replace(
            "gigaam-v3-ctc-sherpa",
            "some-other-model",
            StringComparison.Ordinal));
        var withKey = WriteConfig(ProductDefault.Replace(
            "api_key = \"\"",
            "api_key = \"unexpected\"",
            StringComparison.Ordinal));
        try
        {
            Assert.True(WindowsConfigValidator.ValidateFile(wrongModel).IsValid);
            Assert.Contains(ProductDefaultPolicy.ValidateFile(wrongModel),
                error => error.Contains("model changed", StringComparison.Ordinal));

            Assert.True(WindowsConfigValidator.ValidateFile(withKey).IsValid);
            Assert.Contains(ProductDefaultPolicy.ValidateFile(withKey),
                error => error.Contains("must stay keyless", StringComparison.Ordinal));
        }
        finally
        {
            File.Delete(wrongModel);
            File.Delete(withKey);
        }
    }

    [Fact]
    public void RepositoryExamplePassesGenericAndProductDefaultValidation()
    {
        var example = FindExampleConfig();
        var result = WindowsConfigValidator.ValidateFile(example);
        Assert.True(result.IsValid, string.Join("; ", result.Errors));
        Assert.Equal("airubiz", result.ActiveProvider);
        Assert.Empty(ProductDefaultPolicy.ValidateFile(example));
    }

    [Fact]
    public void ManagedAdapterDefaultsMatchTheSharedEngine()
    {
        foreach (var adapter in new[] { "openai", "groq", "cloudflare", "custom-provider" })
        {
            Assert.Equal(NanoEngine.SttDefaultBaseUrl(adapter), AdapterDefaults.BaseUrl(adapter));
            Assert.Equal(NanoEngine.SttDefaultModel(adapter), AdapterDefaults.Model(adapter));
        }

        Assert.True(AdapterDefaults.DefaultEndpointRequiresCredential("openai"));
        Assert.True(AdapterDefaults.DefaultEndpointRequiresCredential("groq"));
        Assert.False(AdapterDefaults.DefaultEndpointRequiresCredential("cloudflare"));
        Assert.False(AdapterDefaults.DefaultEndpointRequiresCredential("custom-provider"));
    }

    private static void AssertValid(string config)
    {
        var path = WriteConfig(config);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.True(result.IsValid, string.Join("; ", result.Errors));
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static void AssertInvalid(string config, string expected)
    {
        var path = WriteConfig(config);
        try
        {
            var result = WindowsConfigValidator.ValidateFile(path);
            Assert.False(result.IsValid);
            Assert.Contains(result.Errors, error => error.Contains(expected, StringComparison.Ordinal));
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string WriteConfig(string content, bool crlf = false, bool bom = false)
    {
        if (crlf)
        {
            content = content.Replace("\r\n", "\n").Replace("\n", "\r\n");
        }
        var path = Path.Combine(
            Path.GetTempPath(),
            $"nanodictate-config-validation-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, content, new UTF8Encoding(bom));
        return path;
    }

    private static string FindExampleConfig()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "config.example.toml");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        throw new FileNotFoundException("config.example.toml not found");
    }
}
