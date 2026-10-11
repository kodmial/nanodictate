#Requires -Version 7.0
<#
.SYNOPSIS
  Reproducible Windows packaging: builds the Rust DLL, the portable host,
  the WinUI 3 app, and stages an MSIX layout plus a portable ZIP.
  Update/uninstall semantics are documented in windows/DISTRIBUTION.md.
#>
param(
  [string]$Configuration = "Release",
  [string]$Version = "0.0.0",
  [string]$OutDir = "windows/artifacts"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $RepoRoot

Write-Host "Packaging NanoDictate $Version ($Configuration)"

& cargo build --release -p nanodictate-core --manifest-path rust/Cargo.toml
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$Dll = "rust/target/release/nanodictate_core.dll"
if (-not (Test-Path $Dll)) { throw "Missing $Dll" }

dotnet build windows/NanoDictate.sln -c $Configuration
if ($LASTEXITCODE -ne 0) { throw "dotnet build (portable solution) failed" }

# Windows App SDK 1.5 needs the MRT/PRI tasks shipped with Visual Studio
# MSBuild. Use the same build path as windows.yml rather than dotnet build.
& pwsh windows/package/build-winui.ps1 -Configuration $Configuration
if ($LASTEXITCODE -ne 0) { throw "Visual Studio MSBuild (WinUI app) failed" }

dotnet build windows/src/NanoDictate.Host/NanoDictate.Host.csproj -c $Configuration
if ($LASTEXITCODE -ne 0) { throw "dotnet build (host) failed" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stage = Join-Path $OutDir "msix-stage"
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$Stage/NanoDictate.App" | Out-Null

Copy-Item "windows/src/NanoDictate.App/bin/$Configuration/net8.0-windows10.0.19041.0/win-x64/*" "$Stage/NanoDictate.App/" -Recurse -Force
Copy-Item $Dll "$Stage/NanoDictate.App/nanodictate_core.dll" -Force
New-Item -ItemType Directory -Force -Path "$Stage/Assets" | Out-Null
$AssetSource = "windows/package/Assets"
if (-not (Test-Path $AssetSource)) { throw "Missing $AssetSource (StoreLogo.png, Square150x150Logo.png, Square44x44Logo.png)" }
foreach ($asset in @("StoreLogo.png", "Square150x150Logo.png", "Square44x44Logo.png")) {
  $src = Join-Path $AssetSource $asset
  if (-not (Test-Path $src)) { throw "Missing $src referenced by Package.appxmanifest" }
  Copy-Item $src "$Stage/Assets/$asset" -Force
}
Copy-Item "windows/package/Package.appxmanifest" "$Stage/AppxManifest.xml" -Force
Copy-Item "config.example.toml" "$Stage/config.example.toml" -Force
Copy-Item "config.example.toml" "$Stage/NanoDictate.App/config.example.toml" -Force

$Manifest = Get-Content "$Stage/AppxManifest.xml" -Raw
$Parts = $Version.Split(".")
while ($Parts.Count -lt 3) { $Parts += "0" }
$MsixVersion = "$($Parts[0]).$($Parts[1]).$($Parts[2]).0"
$Manifest = $Manifest -replace 'Version="0\.0\.0\.0"', "Version=`"$MsixVersion`""
Set-Content "$Stage/AppxManifest.xml" $Manifest -NoNewline

$Zip = Join-Path $OutDir "nanodictate-windows-x64-$Version.zip"
if (Test-Path $Zip) { Remove-Item $Zip -Force }
Compress-Archive -Path "$Stage/*" -DestinationPath $Zip -Force

Get-Item $Zip | Format-Table Name, Length
Write-Host "Packaging complete: $Zip"
Write-Host "MSIX stage: $Stage (unsigned staging layout; MakeAppx/signing is out of scope, see windows/DISTRIBUTION.md)"
