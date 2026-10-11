using NanoDictate.Core;
using Xunit;

namespace NanoDictate.Core.Tests;

/// <summary>Installed product version used by installer smoke tests.</summary>
public sealed class ProductVersionTests
{
    [Fact]
    public void ProductVersionPrefersVersionFile()
    {
        var dir = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), $"nanodictate-version-{Guid.NewGuid():N}")).FullName;
        try
        {
            File.WriteAllText(Path.Combine(dir, "VERSION"), "0.1.32\n");
            Assert.Equal("0.1.32", HostApp.ProductVersion(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void ProductVersionExtractsSemverFromPrefixedFile()
    {
        var dir = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), $"nanodictate-version-{Guid.NewGuid():N}")).FullName;
        try
        {
            File.WriteAllText(Path.Combine(dir, "VERSION"), "v0.1.33");
            Assert.Equal("0.1.33", HostApp.ProductVersion(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void ProductVersionFallsBackWithoutVersionFile()
    {
        var dir = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), $"nanodictate-version-{Guid.NewGuid():N}")).FullName;
        try
        {
            var version = HostApp.ProductVersion(dir);
            Assert.Matches(@"^\d+\.\d+\.\d+$", version);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
