#Requires -Version 7.0
<#
.SYNOPSIS
  Cross-platform policy tests for the shipped Windows first-use distribution.
.DESCRIPTION
  These are static contract tests for files that only execute on Windows. They
  guard the selected first-use behavior: one quiet background launch from the
  Inno installer, PowerShell bootstrap and Scoop manifest; verified release
  lookup; bundled keyless defaults; and documentation that does not advertise
  an unshipped MSIX, signing, WinGet or tray product.
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:passed = 0
$script:failed = 0

function Pass([string]$Name) {
    $script:passed++
    Write-Host "ok - $Name"
}
function Fail([string]$Name, [string]$Detail) {
    $script:failed++
    Write-Host "not ok - $Name"
    Write-Host "  $Detail"
}
function Read-Text([string]$RelativePath) {
    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required file: $RelativePath"
    }
    return Get-Content -LiteralPath $path -Raw
}
function Assert-Contains([string]$Name, [string]$Text, [string]$Needle) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { Pass $Name }
    else { Fail $Name "expected to contain: $Needle" }
}
function Assert-NotContains([string]$Name, [string]$Text, [string]$Needle) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { Pass $Name }
    else { Fail $Name "must not contain: $Needle" }
}
function Assert-Match([string]$Name, [string]$Text, [string]$Pattern) {
    if ([regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) { Pass $Name }
    else { Fail $Name "expected to match: $Pattern" }
}

$install = Read-Text 'scripts/install-windows.ps1'
Assert-Contains 'installer reads the first-party Scoop manifest' $install 'bucket/nanodictate.json'
Assert-Contains 'installer also resolves the latest stable release' $install 'releases/latest'
Assert-Contains 'installer verifies the published SHA256SUMS entry' $install 'SHA256SUMS.txt'
Assert-Contains 'installer refuses a checksum mismatch' $install 'Download SHA-256 verification failed'
Assert-Contains 'installer has a no-install chain audit mode' $install '[switch]$VerifyOnly'
Assert-Contains 'installer starts the first run in the background' $install "Start-Process -FilePath `$exe -ArgumentList '--background'"
Assert-NotContains 'installer never forces settings on first run' $install "Start-Process -FilePath `$exe -ArgumentList '--settings'"
Assert-Contains 'installer repairs the per-user Run entry' $install "Run'"
Assert-Contains 'installer stops the previous background process before upgrade' $install "Stop-Process -Force"
Assert-Contains 'installer quotes the per-user install directory' $install '(''/DIR="'' + $target + ''"'')'

$iss = Read-Text 'windows/package/NanoDictate.iss'
$runSection = [regex]::Match($iss, '(?ms)^\[Run\](.*?)(?=^\[|\z)').Groups[1].Value
Assert-Match 'Inno post-install launch is background' $runSection 'Parameters:\s*"--background"'
Assert-NotContains 'Inno direct silent install still starts the background agent' $runSection 'skipifsilent'
Assert-NotContains 'Inno post-install launch never forces settings' $runSection '--settings'
Assert-Match 'Start Menu shortcut opens optional settings on demand' $iss 'Parameters:\s*"--settings"'
Assert-Contains 'Inno installs per-user without administrator rights' $iss 'PrivilegesRequired=lowest'
Assert-Contains 'Inno registers persistent background startup' $iss '"NanoDictate"; ValueData: """{app}\NanoDictate.App.exe"" --background"'
Assert-Contains 'Inno preserves user data on uninstall' $iss 'User configuration and logs deliberately survive'

$bucket = Read-Text 'bucket/nanodictate.json' | ConvertFrom-Json
$postInstall = @($bucket.post_install)
if ($postInstall.Count -ge 2 -and ($postInstall -join "`n").Contains('--background') -and -not ($postInstall -join "`n").Contains('--settings')) {
    Pass 'Scoop first install and update start quietly in the background'
} else {
    Fail 'Scoop first install and update start quietly in the background' 'post_install must launch --background and never --settings'
}
$shortcutText = (@($bucket.shortcuts) | ForEach-Object { $_ -join ' ' }) -join "`n"
if ($shortcutText.Contains('--settings')) {
    Pass 'Scoop shortcut keeps settings on demand'
} else {
    Fail 'Scoop shortcut keeps settings on demand' 'shortcut must pass --settings'
}
$scoopGenerator = Read-Text 'scripts/scoop-manifest.jq'
Assert-Contains 'generated Scoop manifests launch background' $scoopGenerator "Start-Process -FilePath `$exe -ArgumentList '--background'"
Assert-NotContains 'generated Scoop manifests never force settings' $scoopGenerator "-ArgumentList '--settings'"

$config = Read-Text 'config.example.toml'
Assert-Contains 'bundled default documents both config locations' $config '%APPDATA%\NanoDictate\config.toml'
$sharedValidator = Join-Path $repoRoot 'scripts/validate-windows-config.ps1'
try {
  & $sharedValidator -ConfigPath (Join-Path $repoRoot 'config.example.toml')
  Pass 'bundled default passes shared provider-agnostic and product-default validation'
} catch {
  Fail 'bundled default passes shared provider-agnostic and product-default validation' $_.Exception.Message
}

$candidate = Read-Text 'windows/package/test-release-candidate.ps1'
Assert-Contains 'candidate smoke validates the packaged config through the shared validator' $candidate 'scripts/validate-windows-config.ps1'
Assert-Contains 'candidate smoke validates the extracted candidate config' $candidate "Join-Path `$unpacked 'config.example.toml'"
Assert-Contains 'candidate smoke records installer measurements' $candidate 'windows-candidate-measurements.json'
Assert-Contains 'candidate smoke exercises reinstall' $candidate 'Reinstall changed the stable per-user autostart entry'
Assert-Contains 'candidate smoke checks startup registration' $candidate 'did not register stable per-user auto-start'

$smoke = Read-Text 'scripts/windows-release-smoke.ps1'
Assert-Match 'published smoke serializes timing measurements on failure' $smoke '(?s)\}\s*finally\s*\{.*?\$report\.download_seconds\s*=.*?\$report\.setup_seconds\s*=.*?\$report\.uninstall_seconds\s*=.*?\$report\s*\|\s*ConvertTo-Json'

$chainTest = Read-Text 'scripts/test-windows-install-chain.ps1'
Assert-Contains 'offline chain test exercises a lagging manifest' $chainTest 'newer GitHub release wins over a lagging manifest'
Assert-Contains 'offline chain test exercises an incomplete release upload' $chainTest 'incomplete latest asset falls back'

$verify = Read-Text 'windows/package/verify-distribution.ps1'
Assert-Contains 'published smoke verifies installer checksum' $verify 'VerifyHash $path (ReleaseHash $sums $name)'
Assert-Contains 'published smoke verifies coreclr payload' $verify "'coreclr.dll'"
Assert-Contains 'published smoke verifies hostfxr payload' $verify "'hostfxr.dll'"
Assert-Contains 'published smoke reports signing separately from smoke' $verify 'WINDOWS_SIGNING=UNVERIFIED'

$makeRelease = Read-Text 'windows/package/make-release.ps1'
foreach ($required in @('NanoDictate.App.exe', 'NanoDictate.App.dll', 'nanodictate_core.dll', 'config.example.toml', 'coreclr.dll', 'hostfxr.dll')) {
    Assert-Contains "package requires $required" $makeRelease $required
}

$validation = Read-Text 'windows/VALIDATION.md'
Assert-NotContains 'validation does not require a signed MSIX' $validation 'signed MSIX'
Assert-Contains 'validation measures launch time manually' $validation 'Record launch elapsed time during the manual desktop check'
$parity = Read-Text 'windows/PARITY.md'
Assert-NotContains 'parity does not claim a macOS menu-bar app' $parity 'macOS has a menu-bar agent'
$distribution = Read-Text 'windows/DISTRIBUTION.md'
Assert-Contains 'distribution names the shipped Inno EXE' $distribution 'nanodictate-X.Y.Z-windows-x64-setup.exe'
Assert-Contains 'distribution does not advertise WinGet as available' $distribution 'No WinGet'
Assert-Contains 'distribution keeps signing limitations explicit' $distribution 'SHA256SUMS alone proves file consistency'

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
