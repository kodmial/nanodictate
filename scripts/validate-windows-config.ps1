#Requires -Version 7.0
<#
.SYNOPSIS
  Validate one NanoDictate Windows TOML file through the shared structured
  validator used by both CI contract tests and the release candidate smoke.
.PARAMETER ConfigPath
  Config file to validate. The release candidate passes the file extracted
  from the exact ZIP being shipped.
.PARAMETER SkipProductDefault
  Run only provider-agnostic structural validation. Product policy checks are
  separate and enabled by default for the shipped config.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ConfigPath,
  [switch]$SkipProductDefault
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$project = Join-Path $repoRoot 'windows/src/NanoDictate.ConfigValidation/NanoDictate.ConfigValidation.csproj'
if (!(Test-Path -LiteralPath $project -PathType Leaf)) {
  throw "Missing shared Windows config validator: $project"
}
if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  throw "Missing Windows config file: $ConfigPath"
}
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnet) {
  throw 'dotnet is required to validate the Windows configuration'
}

$arguments = @(
  'run',
  '--project', $project,
  '--configuration', 'Release',
  '--no-launch-profile',
  '--verbosity', 'quiet',
  '--',
  '--config', $resolvedConfig
)
if ($SkipProductDefault) {
  $arguments += '--skip-product-default'
}

& dotnet @arguments
if ($LASTEXITCODE -ne 0) {
  throw "Windows config validation failed for '$resolvedConfig'"
}
