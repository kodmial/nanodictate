#Requires -Version 7.0
<#
.SYNOPSIS
  Windows-host installer lifecycle for the CI-built ZIP/EXE pair.
.DESCRIPTION
  Runs the exact user-facing install function from scripts/install-windows.ps1
  with the candidate installer, then exercises same-version reinstall, a
  versioned in-place upgrade and uninstall through the shared bounded runner.
  Every setup/uninstall phase has its own deadline and retained Inno log.
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

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'scripts/windows-installer-runner.psm1') -Force
$outRoot = if ([IO.Path]::IsPathRooted($OutDir)) {
  [IO.Path]::GetFullPath($OutDir)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $OutDir))
}
if (-not $LogDirectory) { $LogDirectory = Join-Path $outRoot 'installer-logs' }
$LogDirectory = if ([IO.Path]::IsPathRooted($LogDirectory)) {
  [IO.Path]::GetFullPath($LogDirectory)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $LogDirectory))
}
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$zip = Join-Path $outRoot "nanodictate-$Version-windows-x64.zip"
$setup = Join-Path $outRoot "nanodictate-$Version-windows-x64-setup.exe"
if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Missing Windows ZIP: $zip" }
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "Missing Windows installer: $setup" }

$root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $root ('nanodictate-ci-lifecycle-' + [guid]::NewGuid().ToString('N'))
$installed = Join-Path $work 'installed'
$unpacked = Join-Path $work 'portable'
$userConfig = Join-Path $env:APPDATA 'NanoDictate\ci-preservation-marker.txt'
$reportPath = Join-Path $outRoot 'windows-ci-lifecycle-measurements.json'
$cleanupNeeded = $false
$measurements = [ordered]@{
  version = $Version
  user_install_seconds = $null
  reinstall_seconds = $null
  upgrade_seconds = $null
  uninstall_seconds = $null
  background_agent = 'NOT_TESTED'
  user_config_preserved = $false
  first_launch = 'NOT_TESTED_HEADLESS'
  interactive_hardware = 'NOT_TESTED'
  outcome = 'incomplete'
  failure = $null
}
New-Item -ItemType Directory -Force -Path $work, $unpacked | Out-Null

function Invoke-Setup([string]$phase, [string]$path, [int]$timeoutSeconds) {
  Invoke-BoundedInstallerProcess -FilePath $path -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $installed + '"')
  ) -Phase $phase -TimeoutSeconds $timeoutSeconds -LogDirectory $LogDirectory `
    -InnoLogFileName "$phase.log" | Out-Null
}
function Assert-BackgroundAgent([string]$phase) {
  $agents = @(Wait-NanoDictateBackgroundProcess -InstallDirectory $installed -TimeoutSeconds 30)
  if ($agents.Count -ne 1) {
    throw "Expected exactly one NanoDictate background agent during $phase, found $($agents.Count)"
  }
  $measurements.background_agent = 'RUNNING'
  Write-Host ("{0}: background agent pid {1} is running." -f $phase, $agents[0].Id)
}
function Uninstall([string]$phase) {
  $uninstaller = Join-Path $installed 'unins000.exe'
  if (-not (Test-Path -LiteralPath $uninstaller)) { throw 'Missing installed Inno uninstaller' }
  [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $installed)
  Invoke-BoundedInstallerProcess -FilePath $uninstaller `
    -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Phase $phase `
    -TimeoutSeconds $script:UninstallTimeoutSeconds -LogDirectory $LogDirectory `
    -InnoLogFileName "$phase.log" | Out-Null
  if (Test-Path -LiteralPath (Join-Path $installed 'NanoDictate.App.exe')) {
    throw 'Uninstall left the application executable'
  }
  Assert-NanoDictateStartupCleared
  if (@(Get-NanoDictateProcessesUnderPath -InstallDirectory $installed).Count -ne 0) {
    throw 'Uninstall left the background agent running'
  }
}

$oldReleaseVersion = $env:ND_RELEASE_VERSION
$oldPublishDir = $env:ND_PUBLISH_DIR
$oldOutputDir = $env:ND_OUTPUT_DIR
try {
  Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
  foreach ($name in @('NanoDictate.App.exe', 'NanoDictate.App.dll',
      'NanoDictate.App.runtimeconfig.json', 'nanodictate_core.dll',
      'coreclr.dll', 'hostfxr.dll', 'config.example.toml')) {
    if (-not (Test-Path -LiteralPath (Join-Path $unpacked $name) -PathType Leaf)) {
      throw "Portable ZIP lacks $name"
    }
  }

  New-Item -ItemType Directory -Force -Path (Split-Path $userConfig) | Out-Null
  Set-Content -LiteralPath $userConfig -Value 'preserve' -NoNewline
  $cleanupNeeded = $true

  # Exercise the exact user-facing install path, not a CI-only shortcut.
  . (Join-Path $repoRoot 'scripts/install-windows.ps1')
  $userTimer = [Diagnostics.Stopwatch]::StartNew()
  $userResult = Install-NanoDictateVerified -InstallerPath (Resolve-Path $setup).Path `
    -Version $Version -Target $installed -TimeoutSeconds $InstallTimeoutSeconds `
    -LogDirectory $LogDirectory
  $userTimer.Stop()
  $measurements.user_install_seconds = [Math]::Round($userTimer.Elapsed.TotalSeconds, 2)
  if (-not $userResult.BackgroundAgentRunning) {
    throw 'User-facing install returned without a running NanoDictate background agent'
  }
  Assert-NanoDictatePayload -InstallDirectory $installed
  Assert-NanoDictateStartup -InstallDirectory $installed
  Assert-BackgroundAgent 'user-install'
  Assert-NanoDictateUserDataPreserved -Path $userConfig

  # Same-version reinstall must not fail, duplicate the agent, or touch data.
  [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $installed)
  $reinstallTimer = [Diagnostics.Stopwatch]::StartNew()
  Invoke-Setup 'ci-reinstall' (Resolve-Path $setup).Path $InstallTimeoutSeconds
  $reinstallTimer.Stop()
  $measurements.reinstall_seconds = [Math]::Round($reinstallTimer.Elapsed.TotalSeconds, 2)
  Assert-NanoDictatePayload -InstallDirectory $installed
  Assert-NanoDictateStartup -InstallDirectory $installed
  Assert-BackgroundAgent 'reinstall'
  Assert-NanoDictateUserDataPreserved -Path $userConfig

  # Repackage the already-published bits as 0.0.1 to exercise Inno's versioned
  # in-place upgrade without pretending to test two distinct app builds.
  $env:ND_RELEASE_VERSION = '0.0.1'
  $env:ND_PUBLISH_DIR = (Resolve-Path (Join-Path $outRoot 'published-win-x64')).Path
  $env:ND_OUTPUT_DIR = $outRoot
  $isccPaths = @(
    (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe'),
    (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Inno Setup 6/ISCC.exe')
  )
  $iscc = $isccPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $iscc) { throw 'Inno Setup compiler missing for versioned upgrade test' }
  & $iscc (Join-Path $repoRoot 'windows/package/NanoDictate.iss')
  if ($LASTEXITCODE -ne 0) { throw 'Upgrade installer compilation failed' }
  $upgrade = Join-Path $outRoot 'nanodictate-0.0.1-windows-x64-setup.exe'
  if (-not (Test-Path -LiteralPath $upgrade -PathType Leaf)) { throw 'Upgrade installer missing' }

  [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $installed)
  $upgradeTimer = [Diagnostics.Stopwatch]::StartNew()
  Invoke-Setup 'ci-upgrade' (Resolve-Path $upgrade).Path $InstallTimeoutSeconds
  $upgradeTimer.Stop()
  $measurements.upgrade_seconds = [Math]::Round($upgradeTimer.Elapsed.TotalSeconds, 2)
  Assert-NanoDictatePayload -InstallDirectory $installed
  Assert-NanoDictateStartup -InstallDirectory $installed
  Assert-BackgroundAgent 'upgrade'
  Assert-NanoDictateUserDataPreserved -Path $userConfig

  $uninstallTimer = [Diagnostics.Stopwatch]::StartNew()
  Uninstall 'ci-uninstall'
  $uninstallTimer.Stop()
  $measurements.uninstall_seconds = [Math]::Round($uninstallTimer.Elapsed.TotalSeconds, 2)
  $cleanupNeeded = $false
  Assert-NanoDictateUserDataPreserved -Path $userConfig
  $measurements.user_config_preserved = $true

  $measurements.outcome = 'passed'
  $measurements | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8
  Write-Host ("MEASURED: user-install={0:N1}s reinstall={1:N1}s upgrade={2:N1}s uninstall={3:N1}s" -f
    $measurements.user_install_seconds, $measurements.reinstall_seconds,
    $measurements.upgrade_seconds, $measurements.uninstall_seconds)
  if ($env:GITHUB_STEP_SUMMARY) {
    "Windows CI lifecycle ${Version}: user-install $($measurements.user_install_seconds)s, reinstall $($measurements.reinstall_seconds)s, upgrade $($measurements.upgrade_seconds)s, uninstall $($measurements.uninstall_seconds)s; persistent background agent and user config preserved." |
      Add-Content $env:GITHUB_STEP_SUMMARY
  }
  Write-Host "::notice::Windows $Version CI lifecycle passed user-facing install, reinstall, versioned upgrade, uninstall and config preservation."
} catch {
  $measurements.outcome = 'failed'
  $measurements.failure = $_.Exception.Message
  throw
} finally {
  # Persist the outcome before cleanup so a killed or stuck cleanup cannot
  # discard the failure evidence.
  $measurements | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding utf8
  if ($cleanupNeeded) {
    if (Test-Path -LiteralPath (Join-Path $installed 'unins000.exe')) {
      try { Uninstall 'ci-cleanup' } catch { Write-Warning "CI lifecycle cleanup failed: $_" }
    } else {
      try { [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $installed) } catch { Write-Warning "Agent cleanup failed: $_" }
    }
  }
  $env:ND_RELEASE_VERSION = $oldReleaseVersion
  $env:ND_PUBLISH_DIR = $oldPublishDir
  $env:ND_OUTPUT_DIR = $oldOutputDir
  Remove-Item -LiteralPath $userConfig -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
