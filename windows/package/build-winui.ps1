#Requires -Version 7.0
<#
.SYNOPSIS
  Build the WinUI 3 entrypoint using Visual Studio MSBuild, which supplies
  Windows App SDK's MRT/PRI packaging tasks absent from dotnet SDK MSBuild.
#>
param(
  [string]$Configuration = "Release"
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
& $MSBuild $Project /restore /t:Build "/p:Configuration=$Configuration" "/p:Platform=x64" "/p:RuntimeIdentifier=win-x64" /verbosity:minimal
if ($LASTEXITCODE -ne 0) { throw "Visual Studio MSBuild failed ($LASTEXITCODE)" }
