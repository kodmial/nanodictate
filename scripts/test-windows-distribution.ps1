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
function Assert-NotMatch([string]$Name, [string]$Text, [string]$Pattern) {
    if (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) { Pass $Name }
    else { Fail $Name "must not match: $Pattern" }
}

$install = Read-Text 'scripts/install-windows.ps1'
Assert-Contains 'installer reads the first-party Scoop manifest' $install 'bucket/nanodictate.json'
Assert-Contains 'installer also resolves the latest stable release' $install 'releases/latest'
Assert-Contains 'installer verifies the published SHA256SUMS entry' $install 'SHA256SUMS.txt'
Assert-Contains 'installer refuses a checksum mismatch' $install 'Download SHA-256 verification failed'
Assert-Contains 'installer has a no-install chain audit mode' $install '[switch]$VerifyOnly'
Assert-Contains 'installer uses the shared bounded runner' $install 'Invoke-BoundedInstallerProcess'
Assert-Contains 'installer starts the first run in the background exactly once' $install 'Start-NanoDictateBackgroundIfNeeded'
Assert-NotContains 'installer never forces settings on first run' $install "-ArgumentList '--settings'"
Assert-Contains 'installer repairs the per-user Run entry' $install 'Assert-NanoDictateStartup'
Assert-Contains 'installer stops only the exact installed background agent before upgrade' $install 'Stop-NanoDictateProcessesUnderPath'
Assert-Contains 'installer delegates /DIR quoting to the shared runner' $install '(''/DIR='' + $Target)'
Assert-NotContains 'installer never uses an uncapped tree wait' $install 'Start-Process -Wait'
Assert-NotContains 'installer never unconditionally re-launches a duplicate agent' $install "Start-Process -FilePath `$exe -ArgumentList '--background'"
Assert-Contains 'installer exposes a testable verified install function' $install 'function Install-NanoDictateVerified'
Assert-Contains 'installer falls back to the shared runner source for irm | iex' $install 'windows-installer-runner.psm1'
Assert-Contains 'installer retains per-user installer diagnostics' $install "Join-Path `$env:LOCALAPPDATA 'NanoDictate\installer-logs'"
Assert-Contains 'installer records the diagnostic location' $install 'Installer diagnostics: {0}'

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
Assert-Contains 'candidate smoke skips the product-default policy' $candidate '-SkipProductDefault'
Assert-Contains 'candidate smoke compares the ZIP config to the repository copy' $candidate 'Get-FileHash -LiteralPath $repoConfig -Algorithm SHA256'
Assert-Contains 'candidate smoke rejects packaged config drift' $candidate 'differs from the policy-validated repository file'
Assert-Contains 'candidate smoke records installer measurements' $candidate 'windows-candidate-measurements.json'
Assert-Contains 'candidate smoke exercises reinstall' $candidate "Invoke-Silent 'reinstall'"
Assert-Contains 'candidate smoke checks startup registration' $candidate 'Assert-NanoDictateStartup'
Assert-Contains 'candidate smoke checks the persistent background agent' $candidate 'Assert-BackgroundAgent'
Assert-Contains 'candidate smoke uses the shared bounded runner' $candidate 'Invoke-BoundedInstallerProcess'
Assert-Contains 'candidate smoke persists failure evidence' $candidate "outcome = 'failed'"
Assert-NotContains 'candidate smoke never uses an uncapped tree wait' $candidate 'Start-Process -Wait'

$smoke = Read-Text 'scripts/windows-release-smoke.ps1'
Assert-Match 'published smoke serializes timing measurements on failure' $smoke '(?s)\}\s*finally\s*\{.*?\$report\.download_seconds\s*=.*?\$report\.setup_seconds\s*=.*?\$report\.uninstall_seconds\s*=.*?\$report\s*\|\s*ConvertTo-Json'
Assert-Contains 'published smoke uses the shared bounded runner' $smoke 'Invoke-BoundedInstallerProcess'
Assert-Contains 'published smoke checks the persistent background agent' $smoke 'Assert-BackgroundAgent'
Assert-NotContains 'published smoke never uses an uncapped tree wait' $smoke 'Start-Process -Wait'

$chainTest = Read-Text 'scripts/test-windows-install-chain.ps1'
Assert-Contains 'offline chain test exercises a lagging manifest' $chainTest 'newer GitHub release wins over a lagging manifest'
Assert-Contains 'offline chain test exercises an incomplete release upload' $chainTest 'incomplete latest asset falls back'

$verify = Read-Text 'windows/package/verify-distribution.ps1'
Assert-Contains 'published smoke verifies installer checksum' $verify 'VerifyHash $path (ReleaseHash $sums $name)'
Assert-Contains 'published smoke verifies coreclr payload' $verify "'coreclr.dll'"
Assert-Contains 'published smoke verifies hostfxr payload' $verify "'hostfxr.dll'"
Assert-Contains 'published smoke reports signing separately from smoke' $verify 'WINDOWS_SIGNING=UNVERIFIED'
Assert-Contains 'published distribution uses the shared bounded runner' $verify 'Invoke-BoundedInstallerProcess'
Assert-NotContains 'published distribution never uses an uncapped tree wait' $verify 'Start-Process -Wait'

$runner = Read-Text 'scripts/windows-installer-runner.psm1'
Assert-Contains 'shared runner prevents whole-tree waits' $runner 'System.Diagnostics.Process'
Assert-Contains 'shared runner has a per-operation deadline' $runner 'TimeoutSeconds'
Assert-Contains 'shared runner ignores the persistent product agent' $runner 'DetachedProcessNames'
Assert-Contains 'shared runner waits for Inno bootstrap workers' $runner 'InstallerProcessNamePattern'
Assert-Contains 'shared runner retains Inno logs' $runner 'InnoLogFileName'
Assert-Contains 'shared runner normalizes the log directory' $runner '$LogDirectory = [IO.Path]::GetFullPath($LogDirectory)'
Assert-Contains 'shared runner supports Windows PowerShell 5.1' $runner '#Requires -Version 5.1'
Assert-NotContains 'shared runner does not use ProcessStartInfo.ArgumentList' $runner "PSObject.Properties['ArgumentList']"
Assert-Contains 'shared runner builds Inno-compatible command lines' $runner 'ConvertTo-InnoSetupCommandLineArgument'
Assert-Contains 'shared runner rejects embedded installer quotes' $runner 'Installer argument must not contain quotes'
Assert-Contains 'shared runner writes process-tree evidence' $runner 'Write-InstallerPhaseEvidence'
Assert-Contains 'shared runner captures durable process completion events' $runner 'Win32_ProcessStopTrace'
Assert-Contains 'shared runner records workers that exit between snapshots' $runner 'Read-ProcessTraceEvents'
Assert-Contains 'shared runner opens durable process handles' $runner 'Open-TrackedProcess'
Assert-Contains 'shared runner trusts only cached process handles' $runner 'HandleCached'
Assert-Contains 'shared runner tracks workers without elevation' $runner 'AssignProcessToJobObject'
Assert-Contains 'shared runner falls back when process traces are unavailable' $runner 'trace events are unavailable'
Assert-Contains 'shared runner fails closed when job evidence is unavailable' $runner 'could not read the tracking job snapshot'
Assert-Contains 'shared runner terminates only owned processes on timeout' $runner 'Kill()'
$runnerTests = Read-Text 'scripts/test-windows-installer-runner.ps1'
Assert-Contains 'runner tests prove the legacy tree-wait hang' $runnerTests 'legacy Start-Process -Wait hang'
Assert-Contains 'runner tests cover stubborn child timeouts' $runnerTests 'stuck bootstrap worker times out'
Assert-Contains 'runner tests cover premature bootstrap exit' $runnerTests 'bootstrap waits for the installer worker'
Assert-Contains 'runner tests repeat short-lived worker races' $runnerTests 'short-lived failing bootstrap worker fails the phase'
Assert-Contains 'runner tests preserve exit codes across short-lived processes' $runnerTests 'durable process handle preserves a short-lived exit code'
Assert-Contains 'runner tests cover workers missing from every snapshot' $runnerTests 'durable completion events attach workers that never appeared in a snapshot'
Assert-Contains 'runner tests require durable trace availability on Windows' $runnerTests 'durable process trace events are available'
Assert-Contains 'runner tests cover non-elevated user installs' $runnerTests 'non-elevated user-install'
Assert-Contains 'runner tests lower privileges for non-elevated installs' $runnerTests 'CreateRestrictedToken'
Assert-Contains 'runner tests fail closed on missing job evidence' $runnerTests 'missing job snapshot fails closed'
Assert-Contains 'runner tests cover missing payload failures' $runnerTests 'missing payload file is rejected'
Assert-Contains 'runner tests cover leftover startup registration' $runnerTests 'leftover startup registration is rejected'
Assert-Contains 'runner tests cover user-data mutation' $runnerTests 'changed user data is rejected'
$ciLifecycle = Read-Text 'windows/package/test-ci-installer-lifecycle.ps1'
Assert-Contains 'CI lifecycle exercises the user-facing install function' $ciLifecycle 'Install-NanoDictateVerified'
Assert-Contains 'CI lifecycle runs a versioned upgrade' $ciLifecycle "Invoke-Setup 'ci-upgrade'"
Assert-Contains 'CI lifecycle checks one background agent' $ciLifecycle 'Assert-BackgroundAgent'
Assert-Contains 'CI lifecycle preserves user configuration' $ciLifecycle 'Assert-NanoDictateUserDataPreserved'
Assert-Contains 'CI lifecycle persists failure evidence' $ciLifecycle "outcome = 'failed'"
$windowsWorkflow = Read-Text '.github/workflows/windows.yml'
Assert-Contains 'Windows host job uses the 45-minute budget' $windowsWorkflow 'timeout-minutes: 45'
Assert-Contains 'Windows workflow retains installer diagnostics on failure' $windowsWorkflow 'if: always()'
Assert-Contains 'Windows workflow uploads Inno logs' $windowsWorkflow 'windows/artifacts/installer-logs/**'
Assert-Contains 'Windows workflow runs the runner regression harness' $windowsWorkflow 'scripts/test-windows-installer-runner.ps1'
Assert-Contains 'Windows CI lifecycle runs before the candidate smoke' $windowsWorkflow 'test-ci-installer-lifecycle.ps1 -Version 0.0.0'
$releaseEngine = Read-Text '.github/workflows/nanodictate-release-engine.yml'
Assert-Contains 'release candidate host job uses the 45-minute budget' $releaseEngine 'timeout-minutes: 45'
Assert-Contains 'release candidate job retains installer diagnostics on failure' $releaseEngine 'windows/artifacts/installer-logs/**'

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
