#Requires -Version 7.0
<#
.SYNOPSIS
  Produce the user-installable, self-contained Windows x64 distributions:
  a portable Scoop ZIP and a per-user Inno Setup EXE installer.
  All outputs are derived from this checkout, not an MSIX staging directory.
#>
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$OutDir = "windows/artifacts",
  [switch]$SkipInstaller
)
$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be major.minor.patch" }
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $RepoRoot

$Output = [IO.Path]::GetFullPath((Join-Path $RepoRoot $OutDir))
$PublishDir = Join-Path $Output "published-win-x64"
New-Item -ItemType Directory -Force -Path $Output | Out-Null
if (Test-Path $PublishDir) { Remove-Item -Path $PublishDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $PublishDir | Out-Null

& cargo build --release -p nanodictate-core --manifest-path rust/Cargo.toml
if ($LASTEXITCODE -ne 0) { throw "Rust release DLL build failed" }
$RustDll = Join-Path $RepoRoot "rust/target/release/nanodictate_core.dll"
if (-not (Test-Path $RustDll)) { throw "Missing production Rust DLL" }

& pwsh windows/package/build-winui.ps1 -Configuration Release -PublishDir $PublishDir -Version $Version
if ($LASTEXITCODE -ne 0) { throw "WinUI self-contained publish failed" }
Copy-Item $RustDll (Join-Path $PublishDir "nanodictate_core.dll") -Force
$ConfigPath = Join-Path $PublishDir "config.example.toml"
if (-not (Test-Path $ConfigPath)) {
  Copy-Item "config.example.toml" $ConfigPath
}
foreach ($Required in @("NanoDictate.App.exe", "NanoDictate.App.dll", "NanoDictate.App.runtimeconfig.json", "nanodictate_core.dll", "config.example.toml")) {
  if (-not (Test-Path (Join-Path $PublishDir $Required))) {
    throw "Incomplete publish: $Required is missing"
  }
}
# Ensure this is really a self-contained deployment. A built WinUI EXE alone
# is not evidence that the app works without .NET/Windows App SDK installed.
if (-not (Test-Path (Join-Path $PublishDir "coreclr.dll"))) {
  throw "Missing coreclr.dll: publish is not .NET self-contained"
}
if (-not (Test-Path (Join-Path $PublishDir "hostfxr.dll"))) {
  throw "Missing hostfxr.dll: publish is not .NET self-contained"
}
$ZipName = "nanodictate-$Version-windows-x64.zip"
$Zip = Join-Path $Output $ZipName
if (Test-Path $Zip) { Remove-Item $Zip -Force }
Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $Zip -Force
if (-not (Test-Path $Zip)) { throw "Portable ZIP creation failed" }

if (-not $SkipInstaller) {
  $ISCC = @(
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) 'Inno Setup 6\ISCC.exe')
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $ISCC) { throw "Inno Setup 6 compiler not installed (ISCC.exe)" }
  $env:ND_RELEASE_VERSION = $Version
  $env:ND_PUBLISH_DIR = $PublishDir
  $env:ND_OUTPUT_DIR = $Output
  & $ISCC "windows/package/NanoDictate.iss"
  if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed" }
  $Setup = Join-Path $Output "nanodictate-$Version-windows-x64-setup.exe"
  if (-not (Test-Path $Setup)) { throw "Missing Windows EXE installer" }
}
Get-ChildItem $Output -File | Where-Object { $_.Name -like "nanodictate-$Version-windows-x64*" } | ForEach-Object {
  Write-Host "$($_.Name) SHA256=$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
}
