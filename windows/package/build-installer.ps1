#Requires -Version 7.0
<#
.SYNOPSIS
  Builds the real per-user Windows installer (Inno Setup EXE) for #195.
  Stages self-contained publish output, validates every required bit,
  optionally Authenticode-signs, compiles the installer, and writes SHA-256.
  Fails closed on any missing dependency so a broken installer never ships.

.DESCRIPTION
  Route decision (see windows/DISTRIBUTION.md): MSIX is not shipped because
  genuine MakeAppx packaging, a trusted publisher identity with signing, and
  platform startup-task behavior are not provisioned, and the WinUI 3
  entrypoint ships unpackaged with an HKCU Run background host. This script
  produces the one real installer: a per-user Inno Setup EXE that runs with
  no Rust toolchain, .NET SDK, PowerShell 7, or Visual Studio on the target.
  The .NET and Windows App SDK runtimes travel inside the self-contained
  publish output staged here.

  Version source: Sources/NanoDictateCore/Version.swift (single source with
  macOS). -Version overrides it but must still match the file when given.

  Signing: stable releases must use configured credentials
  (WINDOWS_SIGN_PFX_B64 + WINDOWS_SIGN_PASSWORD, optional
  WINDOWS_SIGN_TIMESTAMP_URL). This script never generates a pretend
  trusted/self-signed production certificate. PR builds run unsigned and are
  labeled as such; pass -RequireSigned on tag/release builds to fail closed
  when the credentials are absent.

.EXAMPLE
  pwsh windows/package/build-installer.ps1 -Version 0.1.32
  pwsh windows/package/build-installer.ps1 -Version 0.1.32 -RequireSigned
#>
param(
  [string]$Version = "",
  [string]$Configuration = "Release",
  [string]$OutDir = "windows/artifacts",
  [switch]$RequireSigned
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $RepoRoot

function Fail([string]$Message) {
  Write-Error $Message
  throw $Message
}

function Read-ProductVersion {
  $swift = Get-Content "Sources/NanoDictateCore/Version.swift" -Raw
  $m = [regex]::Match($swift, '\d+\.\d+\.\d+')
  if (-not $m.Success) { Fail "Cannot extract semver from Sources/NanoDictateCore/Version.swift" }
  return $m.Value
}

$FileVersion = Read-ProductVersion
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = $FileVersion
} else {
  $Version = $Version.Trim() -replace '^v', '' -replace '-.*$', ''
  if ($Version -ne $FileVersion) {
    Fail "Input version $Version does not match Sources/NanoDictateCore/Version.swift ($FileVersion). Bump Version.swift in the Release PR first."
  }
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  Fail "Version '$Version' is not a plain X.Y.Z semver."
}
Write-Host "Building Windows installer for NanoDictate $Version ($Configuration)"

# --- 1. Rust engine (shared production core, MSVC cdylib) -------------------
& cargo build --release -p nanodictate-core --manifest-path rust/Cargo.toml
if ($LASTEXITCODE -ne 0) { Fail "cargo build failed" }
$Dll = "rust/target/release/nanodictate_core.dll"
if (-not (Test-Path $Dll)) { Fail "Missing $Dll (shared Rust engine did not produce the MSVC DLL)" }

# --- 2. Portable C# product --------------------------------------------------
dotnet build windows/NanoDictate.sln -c $Configuration
if ($LASTEXITCODE -ne 0) { Fail "dotnet build (portable solution) failed" }

# --- 3. Self-contained console host publish (no .NET SDK on target) ---------
$PublishHost = "windows/artifacts/publish-host"
if (Test-Path $PublishHost) { Remove-Item $PublishHost -Recurse -Force }
& dotnet publish windows/src/NanoDictate.Host/NanoDictate.Host.csproj -c $Configuration -r win-x64 --self-contained true -o $PublishHost
if ($LASTEXITCODE -ne 0) { Fail "dotnet publish (self-contained host, win-x64) failed" }
$HostExe = Join-Path $PublishHost "nanodictate.exe"
if (-not (Test-Path $HostExe)) { Fail "Missing self-contained host $HostExe" }

# --- 4. WinUI 3 entrypoint (Visual Studio MSBuild supplies MRT/PRI tasks) ---
& pwsh windows/package/build-winui.ps1 -Configuration $Configuration
if ($LASTEXITCODE -ne 0) { Fail "Visual Studio MSBuild (WinUI app) failed" }
$AppOutputCandidates = @(
  "windows/src/NanoDictate.App/bin/x64/$Configuration/net8.0-windows10.0.19041.0/win-x64",
  "windows/src/NanoDictate.App/bin/$Configuration/net8.0-windows10.0.19041.0/win-x64"
)
$AppOutput = $AppOutputCandidates | Where-Object { Test-Path (Join-Path $_ "NanoDictate.App.exe") } | Select-Object -First 1
if (-not $AppOutput) { Fail "Missing published WinUI x64 executable in: $($AppOutputCandidates -join ', ')" }

# --- 5. Stage installer source ----------------------------------------------
$Stage = Join-Path $OutDir "installer-stage"
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item "$PublishHost/*" $Stage -Recurse -Force
Copy-Item "$AppOutput/*" $Stage -Recurse -Force
Copy-Item $Dll (Join-Path $Stage "nanodictate_core.dll") -Force
Copy-Item "config.example.toml" (Join-Path $Stage "config.example.toml") -Force
Set-Content (Join-Path $Stage "VERSION") "$Version`n" -NoNewline

# --- 6. Fail-closed content validation --------------------------------------
$Required = @("nanodictate.exe", "NanoDictate.App.exe", "nanodictate_core.dll", "config.example.toml", "VERSION")
foreach ($name in $Required) {
  $p = Join-Path $Stage $name
  if (-not (Test-Path $p)) { Fail "Installer stage is missing required file: $name" }
  if ((Get-Item $p).Length -eq 0) { Fail "Installer stage file is empty: $name" }
}
$StagedVersion = (Get-Content (Join-Path $Stage "VERSION") -Raw).Trim()
if ($StagedVersion -ne $Version) { Fail "Staged VERSION '$StagedVersion' != requested '$Version'" }
$DllBytes = (Get-Item (Join-Path $Stage "nanodictate_core.dll")).Length
if ($DllBytes -lt 100KB) { Fail "nanodictate_core.dll is suspiciously small ($DllBytes bytes); refusing to ship." }
Write-Host "Installer stage validated:"
Get-ChildItem $Stage | Format-Table Name, Length

# --- 7. Optional Authenticode signing of staged binaries --------------------
$PfxB64 = $env:WINDOWS_SIGN_PFX_B64
$PfxPass = $env:WINDOWS_SIGN_PASSWORD
$TimestampUrl = $env:WINDOWS_SIGN_TIMESTAMP_URL
if ([string]::IsNullOrWhiteSpace($TimestampUrl)) { $TimestampUrl = "http://timestamp.digicert.com" }
$DidSign = $false
if (-not [string]::IsNullOrWhiteSpace($PfxB64) -and -not [string]::IsNullOrWhiteSpace($PfxPass)) {
  $SignTool = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe",
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe",
    "${env:ProgramFiles}\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $SignTool) { Fail "Signing credentials are configured but signtool.exe was not found (install the Windows SDK)." }
  $PfxPath = Join-Path $OutDir "signing.pfx"
  [IO.File]::WriteAllBytes($PfxPath, [Convert]::FromBase64String($PfxB64))
  try {
    foreach ($target in @($HostExe, (Join-Path $Stage "NanoDictate.App.exe"), (Join-Path $Stage "nanodictate.exe"))) {
      if (Test-Path $target) {
        & $SignTool sign /f $PfxPath /p $PfxPass /fd SHA256 /tr $TimestampUrl /td SHA256 $target
        if ($LASTEXITCODE -ne 0) { Fail "signtool failed for $target" }
      }
    }
    $DidSign = $true
    Write-Host "Authenticode signing applied (publisher from configured certificate)."
  } finally {
    Remove-Item $PfxPath -Force -ErrorAction SilentlyContinue
  }
} elseif ($RequireSigned) {
  Fail "Stable release requires signing credentials (WINDOWS_SIGN_PFX_B64 + WINDOWS_SIGN_PASSWORD), which are not configured. Refusing to produce a release installer without them; see windows/DISTRIBUTION.md."
} else {
  Write-Warning "No signing credentials configured: producing an UNSIGNED installer for validation only. Never present this artifact as a signed release."
}

# --- 8. Compile the Inno Setup installer ------------------------------------
$Iscc = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Iscc) { Fail "ISCC.exe not found. Install Inno Setup 6 (choco install innosetup -y) before running this script." }
$InstallerOut = Join-Path $OutDir "installer-out"
New-Item -ItemType Directory -Force -Path $InstallerOut | Out-Null
& $Iscc "/DMyAppVersion=$Version" "/DSourceDir=$RepoRoot\$Stage" "/DOutputDir=$RepoRoot\$InstallerOut" "$RepoRoot\windows\package\nanodictate.iss"
if ($LASTEXITCODE -ne 0) { Fail "Inno Setup compilation failed" }

$Installer = Join-Path $InstallerOut "NanoDictate-Setup-$Version-x64.exe"
if (-not (Test-Path $Installer)) { Fail "Expected installer missing: $Installer" }
if ((Get-Item $Installer).Length -lt 1MB) { Fail "Installer is suspiciously small ($((Get-Item $Installer).Length) bytes); refusing to ship." }

# Sign the installer itself when credentials are present.
if ($DidSign) {
  $SignTool = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe",
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($SignTool) {
    $PfxPath = Join-Path $OutDir "signing.pfx"
    [IO.File]::WriteAllBytes($PfxPath, [Convert]::FromBase64String($PfxB64))
    try {
      & $SignTool sign /f $PfxPath /p $PfxPass /fd SHA256 /tr $TimestampUrl /td SHA256 $Installer
      if ($LASTEXITCODE -ne 0) { Fail "signtool failed for installer $Installer" }
    } finally {
      Remove-Item $PfxPath -Force -ErrorAction SilentlyContinue
    }
  }
}

# --- 9. SHA-256 sidecar (release automation consumes this exact file) --------
$Hash = (Get-FileHash $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$Hash  $(Split-Path $Installer -Leaf)" | Set-Content "$Installer.sha256" -NoNewline
Write-Host "Installer: $Installer"
Write-Host "SHA-256: $Hash"
if ($DidSign) { Write-Host "Signature: Authenticode (configured certificate)" }
else { Write-Host "Signature: UNSIGNED (validation build; not a signed release)" }
Write-Host "Installer build complete."
