#Requires -Version 7.0
<#
.SYNOPSIS
  Blocking Windows release candidate smoke. Runs on a clean windows-latest
  runner *before* uploading candidate artifacts to GitHub Releases.
  Validates the exact published ZIP/EXE pair from this build.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$OutDir = 'windows/artifacts',
  [ValidateRange(1, 3600)][int]$InstallTimeoutSeconds = 240,
  [ValidateRange(1, 3600)][int]$UninstallTimeoutSeconds = 120,
  [string]$LogDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release version' }
Import-Module (Join-Path $PSScriptRoot '../../scripts/windows-installer-runner.psm1') -Force
if (-not $LogDirectory) { $LogDirectory = Join-Path $OutDir 'installer-logs' }
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$zip = Join-Path $OutDir "nanodictate-$Version-windows-x64.zip"
$setup = Join-Path $OutDir "nanodictate-$Version-windows-x64-setup.exe"
if (!(Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Missing candidate ZIP: $zip" }
if (!(Test-Path -LiteralPath $setup -PathType Leaf)) { throw "Missing candidate EXE: $setup" }
$root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $root ("nanodictate-candidate-" + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $work 'installed'
$unpacked = Join-Path $work 'zip'
$marker = Join-Path $env:APPDATA ("NanoDictate\candidate-smoke-" + [guid]::NewGuid().ToString('N') + '.txt')
$cleanupNeeded = $false
$reportPath = Join-Path $OutDir 'windows-candidate-measurements.json'
$measurements = [ordered]@{
  version = $Version
  installer_bytes = (Get-Item -LiteralPath $setup).Length
  portable_zip_bytes = (Get-Item -LiteralPath $zip).Length
  install_seconds = $null
  reinstall_seconds = $null
  uninstall_seconds = $null
  background_agent = 'NOT_TESTED'
  first_launch = 'NOT_TESTED_HEADLESS'
  interactive_hardware = 'NOT_TESTED'
  outcome = 'incomplete'
  failure = $null
}
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-Silent([string]$phase, [string]$file, [string[]]$arguments, [int]$timeoutSeconds) {
  Invoke-BoundedInstallerProcess -FilePath $file -ArgumentList $arguments -Phase $phase `
    -TimeoutSeconds $timeoutSeconds -LogDirectory $LogDirectory `
    -InnoLogFileName "$phase.log" | Out-Null
}
function Assert-BackgroundAgent {
  $agents = @(Wait-NanoDictateBackgroundProcess -InstallDirectory $dir -TimeoutSeconds 30)
  if ($agents.Count -ne 1) {
    throw "Expected exactly one background NanoDictate agent after install, found $($agents.Count)"
  }
  $script:measurements.background_agent = 'RUNNING'
  Write-Host ("Background agent pid {0} is running." -f $agents[0].Id)
}
function Uninstall([int]$timeoutSeconds = 120, [string]$phase = 'uninstall') {
  $uninstaller = Join-Path $dir 'unins000.exe'
  if (!(Test-Path -LiteralPath $uninstaller)) { throw 'Missing installed Inno uninstaller' }
  [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $dir)
  Invoke-Silent $phase $uninstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') $timeoutSeconds
  if (Test-Path (Join-Path $dir 'NanoDictate.App.exe')) { throw 'Uninstall left the application' }
  Assert-NanoDictateStartupCleared
  if (@(Get-NanoDictateProcessesUnderPath -InstallDirectory $dir).Count -ne 0) {
    throw 'Uninstall left the background agent running'
  }
}
try {
  Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
  foreach ($name in @('NanoDictate.App.exe','NanoDictate.App.dll',
     'NanoDictate.App.runtimeconfig.json','nanodictate_core.dll',
     'coreclr.dll','hostfxr.dll','config.example.toml')) {
    if (!(Test-Path -LiteralPath (Join-Path $unpacked $name) -PathType Leaf)) {
      throw "Candidate ZIP missing $name"
    }
  }
  $example = Get-Content -LiteralPath (Join-Path $unpacked 'config.example.toml') -Raw
  if ($example -notmatch '(?m)^active_provider = "airubiz"$') {
    throw 'Bundled config.example.toml does not select the keyless Airubiz default'
  }
  if ($example -notmatch '(?m)^\[providers\.airubiz\]$' -or $example -notmatch 'gigaam-v3-ctc-sherpa') {
    throw 'Bundled config.example.toml lacks the Airubiz provider/model defaults'
  }
  $auth = Get-AuthenticodeSignature -LiteralPath $setup
  if ($auth.Status -eq 'NotSigned') {
    Write-Warning 'Candidate installer is unsigned: trusted code signing is a separate publisher prerequisite'
  } elseif ($auth.Status -ne 'Valid') { throw "Invalid candidate installer signature: $($auth.Status)" }
  $cleanupNeeded = $true
  $installTimer = [Diagnostics.Stopwatch]::StartNew()
  Invoke-Silent 'install' (Resolve-Path $setup).Path @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$dir`"") $InstallTimeoutSeconds
  $installTimer.Stop()
  $measurements.install_seconds = [Math]::Round($installTimer.Elapsed.TotalSeconds, 2)
  $zipFiles = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File)
  if ($zipFiles.Count -eq 0) { throw 'Candidate ZIP is empty' }
  foreach ($file in $zipFiles) {
    $relative = [IO.Path]::GetRelativePath($unpacked, $file.FullName)
    $target = Join-Path $dir $relative
    if (!(Test-Path -LiteralPath $target -PathType Leaf)) { throw "Installer missing $relative" }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
      throw "Installed $relative differs from exact candidate ZIP bytes"
    }
  }
  Assert-NanoDictateStartup -InstallDirectory $dir
  Assert-BackgroundAgent
  New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
  Set-Content -LiteralPath $marker -Value 'preserve' -NoNewline
  # Same-version reinstall must be resilient, keep startup pointed at the
  # installed EXE, and preserve user files exactly like a versioned upgrade.
  [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $dir)
  $reinstallTimer = [Diagnostics.Stopwatch]::StartNew()
  Invoke-Silent 'reinstall' (Resolve-Path $setup).Path @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$dir`"") $InstallTimeoutSeconds
  $reinstallTimer.Stop()
  $measurements.reinstall_seconds = [Math]::Round($reinstallTimer.Elapsed.TotalSeconds, 2)
  Assert-NanoDictateStartup -InstallDirectory $dir
  Assert-BackgroundAgent
  Assert-NanoDictateUserDataPreserved -Path $marker
  $uninstallTimer = [Diagnostics.Stopwatch]::StartNew()
  Uninstall $UninstallTimeoutSeconds
  $uninstallTimer.Stop()
  $measurements.uninstall_seconds = [Math]::Round($uninstallTimer.Elapsed.TotalSeconds, 2)
  $cleanupNeeded = $false
  Assert-NanoDictateUserDataPreserved -Path $marker
  $measurements.outcome = 'passed'
  $measurements | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8
  Write-Host ("MEASURED: installer={0:N1} MB zip={1:N1} MB install={2:N1}s reinstall={3:N1}s uninstall={4:N1}s" -f (
    $measurements.installer_bytes / 1MB), ($measurements.portable_zip_bytes / 1MB),
    $measurements.install_seconds, $measurements.reinstall_seconds, $measurements.uninstall_seconds)
  if ($env:GITHUB_STEP_SUMMARY) {
    "Windows candidate ${Version}: installer $([Math]::Round($measurements.installer_bytes / 1MB, 1)) MB, install $($measurements.install_seconds)s, reinstall $($measurements.reinstall_seconds)s, uninstall $($measurements.uninstall_seconds)s. Interactive first launch/microphone/HUD: **NOT_TESTED_HEADLESS**." | Add-Content $env:GITHUB_STEP_SUMMARY
  }
  Write-Host "::notice::Exact Windows $Version release candidate passed ZIP/EXE identity, config defaults, install, reinstall, registry, uninstall and preservation smoke."
} catch {
  $measurements.outcome = 'failed'
  $measurements.failure = $_.Exception.Message
  throw
} finally {
  # Persist the outcome before cleanup so a killed or stuck cleanup cannot
  # discard the failure evidence.
  $measurements | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8
  try { [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $dir) } catch {
    Write-Warning "Candidate agent cleanup failed: $_"
  }
  if ($cleanupNeeded -and (Test-Path -LiteralPath (Join-Path $dir 'unins000.exe'))) {
    try { Uninstall $UninstallTimeoutSeconds 'candidate-cleanup' } catch { Write-Warning "Candidate cleanup failed: $_" }
  }
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
