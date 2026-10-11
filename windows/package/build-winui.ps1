#Requires -Version 7.0
<#
.SYNOPSIS
  Build the WinUI 3 entrypoint using Visual Studio MSBuild, which supplies
  Windows App SDK's MRT/PRI packaging tasks absent from dotnet SDK MSBuild.
#>
param(
  [string]$Configuration = "Release",
  [string]$PublishDir = "",
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Project = Join-Path $RepoRoot "windows/src/NanoDictate.App/NanoDictate.App.csproj"
$VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
if (-not (Test-Path $VsWhere)) {
  throw "Visual Studio vswhere.exe not found. Install Visual Studio Build Tools with MSBuild and WinUI tooling."
}

$Candidates = @(& $VsWhere -latest -products '*' -requires Microsoft.Component.MSBuild -find "MSBuild\Current\Bin\MSBuild.exe")
$MSBuild = $Candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $MSBuild) {
  throw "Visual Studio MSBuild.exe not found. The .NET SDK msbuild cannot compile this Windows App SDK project."
}

Write-Host "Building WinUI 3 app via $MSBuild"
$Properties = @("/p:Configuration=$Configuration", "/p:Platform=x64", "/p:RuntimeIdentifier=win-x64")
$Target = "/t:Build"
if ($PublishDir) {
  $Target = "/t:Publish"
  $FullPublishDir = [IO.Path]::GetFullPath((Join-Path (Get-Location) $PublishDir))
  New-Item -ItemType Directory -Path $FullPublishDir -Force | Out-Null
  if (-not $FullPublishDir.EndsWith([IO.Path]::DirectorySeparatorChar)) {
    $FullPublishDir += [IO.Path]::DirectorySeparatorChar
  }
  $Properties += "/p:PublishDir=$FullPublishDir"
  $Properties += "/p:WindowsPackageType=None"
  $Properties += "/p:SelfContained=true"
}
if ($Version) {
  if ($Version -notmatch '^\\d+\\.\\d+\\.\\d+
) { throw "Invalid version: $Version" }
  $Properties += "/p:Version=$Version"
}
& $MSBuild $Project /restore $Target @Properties /verbosity:minimal
if ($LASTEXITCODE -ne 0) { throw "Visual Studio MSBuild failed ($LASTEXITCODE)" }
if ($PublishDir -and -not (Test-Path (Join-Path $FullPublishDir "NanoDictate.App.exe"))) {
  throw "Publish succeeded without NanoDictate.App.exe in $FullPublishDir"
}
