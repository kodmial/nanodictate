#Requires -Version 7.0
<#
.SYNOPSIS
  Deterministic install -> upgrade -> uninstall verification for #195.
  Installs the Inno Setup EXE silently on a clean directory, launches the
  installed host (version/doctor/providers), proves config/log preservation
  across a versioned upgrade, uninstalls silently, and asserts no orphaned
  installation remains. Writes a step log for CI upload.

.DESCRIPTION
  Intended for .github/workflows/windows.yml (PR smoke) and
  windows-release.yml (release gate). Uses only per-user locations under
  $TestRoot plus an isolated install dir, so parallel runners never clash.
  Physical microphone/desktop interaction (hotkey, tray, live STT) is NOT
  proven here; those rows live in windows/VALIDATION.md with real-hardware
  evidence. Fails closed: any missing binary, version mismatch, lost user
  data, or orphaned file exits non-zero.

.EXAMPLE
  pwsh windows/package/test-installer.ps1 -Installer windows/artifacts/installer-out/NanoDictate-Setup-0.1.32-x64.exe -Version 0.1.32
#>
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$TestRoot = "",
  [string]$LogDir = "windows/artifacts/install-test-logs",
  [string]$PriorInstaller = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $RepoRoot

if (-not (Test-Path $Installer)) { throw "Installer not found: $Installer" }
$Version = ($Version -replace '^v', '' -replace '-.*$', '').Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version '$Version' is not X.Y.Z" }

if ([string]::IsNullOrWhiteSpace($TestRoot)) {
  $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("nanodictate-install-test-" + [Guid]::NewGuid().ToString("N"))
}
$InstallDir = Join-Path $TestRoot "install"
$LogDirFull = Join-Path $RepoRoot $LogDir
New-Item -ItemType Directory -Force -Path $TestRoot, $LogDirFull | Out-Null
$StepLog = Join-Path $LogDirFull "install-test-$Version.log"
"NanoDictate installer test $Version (started $(Get-Date -Format o))" | Set-Content $StepLog

function Step([string]$Message) {
  $line = "[step] $Message"
  Write-Host $line
  Add-Content $StepLog $line
}

function Fail([string]$Message) {
  Add-Content $StepLog "[FAIL] $Message"
  Write-Error $Message
  throw $Message
}

function Assert-TestPath([string]$Path, [string]$What) {
  if (-not (Test-Path $Path)) { Fail "Missing $What : $Path" }
}

# Isolate user data: point APPDATA/LOCALAPPDATA at the test root so the test
# never touches the runner's real profile. WindowsPaths honors the env vars.
$FakeAppData = Join-Path $TestRoot "appdata-roaming"
$FakeLocalData = Join-Path $TestRoot "appdata-local"
New-Item -ItemType Directory -Force -Path $FakeAppData, $FakeLocalData | Out-Null
$env:APPDATA = $FakeAppData
$env:LOCALAPPDATA = $FakeLocalData

try {
  # --- Optional prior-version install (real upgrade path) -------------------
  if (-not [string]::IsNullOrWhiteSpace($PriorInstaller) -and (Test-Path $PriorInstaller)) {
    Step "Installing prior version for upgrade test: $PriorInstaller"
    & $PriorInstaller /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /DIR="$InstallDir" /LOG="$LogDirFull\prior-install.log"
    if ($LASTEXITCODE -ne 0) { Fail "Prior installer exited with code $LASTEXITCODE" }
  }

  # --- 1. Clean silent install ----------------------------------------------
  Step "Silent install $Installer -> $InstallDir"
  & $Installer /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /DIR="$InstallDir" /LOG="$LogDirFull\install.log"
  if ($LASTEXITCODE -ne 0) { Fail "Installer exited with code $LASTEXITCODE" }

  $HostExe = Join-Path $InstallDir "nanodictate.exe"
  $AppExe = Join-Path $InstallDir "NanoDictate.App.exe"
  Assert-TestPath $HostExe "installed console host"
  Assert-TestPath $AppExe "installed WinUI app"
  Assert-TestPath (Join-Path $InstallDir "nanodictate_core.dll") "installed Rust engine DLL"
  Assert-TestPath (Join-Path $InstallDir "config.example.toml") "installed example config"
  Assert-TestPath (Join-Path $InstallDir "VERSION") "installed VERSION stamp"
  $InstalledVersion = (Get-Content (Join-Path $InstallDir "VERSION") -Raw).Trim()
  if ($InstalledVersion -ne $Version) { Fail "Installed VERSION '$InstalledVersion' != expected '$Version'" }
  Step "Installed file set validated (version $InstalledVersion)"

  # --- 2. Launch: version, doctor, providers ---------------------------------
  Step "Reading installed version"
  $VersionOut = & $HostExe version 2>&1 | Out-String
  Add-Content $StepLog $VersionOut
  if ($VersionOut -notmatch [regex]::Escape($Version)) { Fail "Installed 'version' output does not contain $Version : $VersionOut" }

  Step "Running installed doctor"
  $DoctorOut = & $HostExe doctor --config (Join-Path $InstallDir "config.example.toml") 2>&1 | Out-String
  Add-Content $StepLog $DoctorOut
  if ($LASTEXITCODE -ne 0) { Fail "Installed doctor failed (exit $LASTEXITCODE): $DoctorOut" }

  Step "Running installed providers"
  $ProvidersOut = & $HostExe providers --config (Join-Path $InstallDir "config.example.toml") 2>&1 | Out-String
  Add-Content $StepLog $ProvidersOut
  if ($LASTEXITCODE -ne 0) { Fail "Installed providers failed (exit $LASTEXITCODE)" }

  # --- 3. Seed user data, then versioned upgrade ------------------------------
  $UserConfigDir = Join-Path $FakeAppData "NanoDictate"
  $UserLogDir = Join-Path $FakeLocalData "NanoDictate\Logs"
  New-Item -ItemType Directory -Force -Path $UserConfigDir, $UserLogDir | Out-Null
  $MarkerConfig = Join-Path $UserConfigDir "config.toml"
  $MarkerState = Join-Path $UserConfigDir "mic-request-state.json"
  $MarkerLog = Join-Path $UserLogDir "nanodictate-test.log"
  "user-config-marker-$Version" | Set-Content $MarkerConfig
  "{}" | Set-Content $MarkerState
  "user-log-marker-$Version" | Set-Content $MarkerLog
  Step "Seeded user-data markers"

  Step "Versioned upgrade (reinstall $Version over existing install)"
  & $Installer /SILENT /NORESTART /SUPPRESSMSGBOXES /DIR="$InstallDir" /LOG="$LogDirFull\upgrade.log"
  if ($LASTEXITCODE -ne 0) { Fail "Upgrade reinstall exited with code $LASTEXITCODE" }
  foreach ($marker in @($MarkerConfig, $MarkerState, $MarkerLog)) {
    if (-not (Test-Path $marker)) { Fail "Upgrade deleted user data: $marker" }
  }
  if (((Get-Content $MarkerConfig -Raw).Trim()) -ne "user-config-marker-$Version") { Fail "Upgrade overwrote user config.toml" }
  $VersionOut2 = & (Join-Path $InstallDir "nanodictate.exe") version 2>&1 | Out-String
  if ($VersionOut2 -notmatch [regex]::Escape($Version)) { Fail "Post-upgrade version mismatch: $VersionOut2" }
  Step "Upgrade preserved user config and logs; version still $Version"

  # --- 4. Silent uninstall ----------------------------------------------------
  $Uninstaller = Join-Path $InstallDir "unins000.exe"
  Assert-TestPath $Uninstaller "uninstaller"
  Step "Silent uninstall"
  & $Uninstaller /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG="$LogDirFull\uninstall.log"
  if ($LASTEXITCODE -ne 0) { Fail "Uninstaller exited with code $LASTEXITCODE" }

  if (Test-Path $HostExe) { Fail "Orphaned installation: $HostExe still exists after uninstall" }
  if (Test-Path $AppExe) { Fail "Orphaned installation: $AppExe still exists after uninstall" }
  foreach ($marker in @($MarkerConfig, $MarkerState, $MarkerLog)) {
    if (-not (Test-Path $marker)) { Fail "Uninstall deleted preserved user data: $marker" }
  }
  Step "Uninstall removed program files and preserved user config/logs"

  Add-Content $StepLog "[PASS] install -> version -> upgrade -> uninstall ($Version)"
  Write-Host "Installer test PASSED for $Version"
} finally {
  $env:APPDATA = $null
}
