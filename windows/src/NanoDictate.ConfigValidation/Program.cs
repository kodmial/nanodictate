namespace NanoDictate.ConfigValidation;

internal static class Program
{
    private static int Main(string[] args)
    {
        string? configPath = null;
        var skipProductDefault = false;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--config" or "-c" when i + 1 < args.Length:
                    configPath = args[++i];
                    break;
                case "--skip-product-default":
                    skipProductDefault = true;
                    break;
                case "--help" or "-h":
                    return Usage();
                default:
                    Console.Error.WriteLine($"config validation: unknown argument '{args[i]}'");
                    return Usage();
            }
        }

        if (string.IsNullOrWhiteSpace(configPath))
        {
            return Usage();
        }

        ConfigValidationResult result;
        try
        {
            result = WindowsConfigValidator.ValidateFile(configPath);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"config validation: {ex.GetType().Name}");
            return 1;
        }

        foreach (var error in result.Errors)
        {
            Console.Error.WriteLine($"config validation: {error}");
        }
        if (!result.IsValid)
        {
            return 1;
        }

        if (!skipProductDefault)
        {
            IReadOnlyList<string> policyErrors;
            try
            {
                policyErrors = ProductDefaultPolicy.ValidateFile(configPath);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"config validation: product default policy could not be evaluated ({ex.GetType().Name})");
                return 1;
            }
            foreach (var error in policyErrors)
            {
                Console.Error.WriteLine($"config validation: {error}");
            }
            if (policyErrors.Count > 0)
            {
                return 1;
            }
        }

        Console.WriteLine($"config validation: ok: provider={result.ActiveProvider}");
        return 0;
    }

    private static int Usage()
    {
        Console.Error.WriteLine("usage: NanoDictate.ConfigValidation --config PATH [--skip-product-default]");
        return 2;
    }
}
