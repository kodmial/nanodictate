#Requires -Version 7.0
<#
.SYNOPSIS
  Fresh Windows-runner smoke of the *published* GitHub Release, not CI build
  outputs. Checks pinned public checksums, portable contents, actual Inno
  per-user install, upgrade, startup registration, uninstall and data retention.
  Does not claim interactive microphone/WinUI or trusted signing qualification.
#>
[CmdletBinding()]
param(
  [string]$Version = "",
  [string]$Repository = $env:GITHUB_REPOSITORY
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') {
  throw "Pass -Repository owner/name or set GITHUB_REPOSITORY"
}
if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must be major.minor.patch (without v)"
}
if (-not $env:GH_TOKEN) { throw "GH_TOKEN is required to query and download release assets" }

$root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $root ("nanodictate-release-smoke-" + [guid]::NewGuid().ToString('N'))
$installDir = Join-Path $work 'installed'
$repoRoot = Split-Path -Parent $PSScriptRoot
$reportFile = Join-Path $repoRoot 'windows/artifacts/windows-published-smoke.json'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$configFile = Join-Path $env:APPDATA 'NanoDictate\config.toml'
$configSentinel = 'keep-config-' + [guid]::NewGuid().ToString('N')
$configBackup = Join-Path $work 'config.toml.backup'
$hadPriorConfig = $false
$report = [ordered]@{
  repository = $Repository
  version = $null
  release = $null
  portable_checksums = $false
  portable_layout = $false
  installer_checksum = $false
  authenticode = 'unchecked'
  install = $false
  upgrade_or_reinstall = $false
  uninstall = $false
  user_data_preserved = $false
  interactive_hardware = 'NOT_TESTED'
}
New-Item -ItemType Directory -Path $work, (Split-Path $reportFile) -Force | Out-Null

function Invoke-GhJson([string]$route) {
  $raw = & gh api $route | Out-String
  if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) { throw "GitHub API request failed: $route" }
  return ($raw | ConvertFrom-Json)
}
function Get-Release([string]$tag) {
  if ($tag) { return (Invoke-GhJson "repos/$Repository/releases/tags/$tag") }
  return (Invoke-GhJson "repos/$Repository/releases/latest")
}
function Assert-Asset([object]$release, [string]$name) {
  if (-not @($release.assets | Where-Object { $_.name -ceq $name }).Count) {
    throw "Published release $($release.tag_name) is missing $name"
  }
}
function Get-VerifiedAssets([object]$release, [string]$folder, [string[]]$names) {
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  foreach ($name in @('SHA256SUMS.txt') + $names) { Assert-Asset $release $name }
  $ghArgs = @('release','download',$release.tag_name,'--repo',$Repository,'--dir',$folder,'--clobber')
  foreach ($name in @('SHA256SUMS.txt') + $names) { $ghArgs += @('--pattern',$name) }
  & gh @ghArgs
  if ($LASTEXITCODE -ne 0) { throw "Failed to download $($release.tag_name) from GitHub Releases" }
  $sumFile = Join-Path $folder 'SHA256SUMS.txt'
  $expected = @{}
  foreach ($line in Get-Content -LiteralPath $sumFile) {
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$') {
      $expected[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }
  }
  foreach ($name in $names) {
    $file = Join-Path $folder $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Downloaded asset missing: $name" }
    if (-not $expected.ContainsKey($name)) { throw "SHA256SUMS.txt does not pin $name" }
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected[$name]) { throw "SHA256 mismatch for $name" }
    Write-Host "SHA256 verified: $name"
  }
  return $expected
}
function Invoke-Setup([string]$path) {
  $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installDir`"")
  $proc = Start-Process -FilePath $path -ArgumentList $arguments -Wait -PassThru
  if ($proc.ExitCode -ne 0) { throw "Installer $path exited $($proc.ExitCode)" }
}
function Get-RunValue {
  $properties = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
  if ($null -eq $properties) { return '' }
  $entry = $properties.PSObject.Properties['NanoDictate']
  if ($null -eq $entry) { return '' }
  return [string]$entry.Value
}
function Assert-Installed([bool]$RequireStartup = $true) {
  foreach ($name in @('NanoDictate.App.exe','NanoDictate.App.dll',
      'NanoDictate.App.runtimeconfig.json','nanodictate_core.dll',
      'coreclr.dll','hostfxr.dll','config.example.toml')) {
    if (-not (Test-Path -LiteralPath (Join-Path $installDir $name) -PathType Leaf)) {
      throw "Installed app lacks $name"
    }
  }
  if ($RequireStartup) {
    $expectedRun = '"' + (Join-Path $installDir 'NanoDictate.App.exe') + '" --background'
    $actualRun = Get-RunValue
    if ($actualRun -cne $expectedRun) { throw "Run-key registration mismatch: $actualRun" }
  }
}
function Uninstall {
  $uninstaller = Join-Path $installDir 'unins000.exe'
  if (-not (Test-Path -LiteralPath $uninstaller)) { throw "Inno uninstaller missing" }
  $proc = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru
  if ($proc.ExitCode -ne 0) { throw "Uninstaller exited $($proc.ExitCode)" }
  if (Test-Path -LiteralPath (Join-Path $installDir 'NanoDictate.App.exe')) { throw 'Uninstall left the application executable' }
  $run = Get-RunValue
  if ($run) { throw 'Uninstall left the application auto-start registry entry' }
}

try {
  $tag = if ($Version) { "v$Version" } else { '' }
  $release = Get-Release $tag
  if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') {
    throw "Not a stable semantic-version GitHub Release: $($release.tag_name)"
  }
  $versionText = $release.tag_name.Substring(1)
  $report.version = $versionText
  $report.release = $release.html_url
  $zipName = "nanodictate-$versionText-windows-x64.zip"
  $setupName = "nanodictate-$versionText-windows-x64-setup.exe"
  $latestDir = Join-Path $work 'latest'
  $sums = Get-VerifiedAssets $release $latestDir @($zipName,$setupName)
  $report.portable_checksums = $true
  $report.installer_checksum = $true

  $zipDir = Join-Path $work 'portable'
  Expand-Archive -LiteralPath (Join-Path $latestDir $zipName) -DestinationPath $zipDir -Force
  foreach ($name in @('NanoDictate.App.exe','NanoDictate.App.dll',
      'NanoDictate.App.runtimeconfig.json','nanodictate_core.dll',
      'coreclr.dll','hostfxr.dll','config.example.toml')) {
    if (-not (Test-Path -LiteralPath (Join-Path $zipDir $name) -PathType Leaf)) {
      throw "Published portable ZIP is not self-contained: $name missing"
    }
  }
  $report.portable_layout = $true

  $setup = Join-Path $latestDir $setupName
  $signature = Get-AuthenticodeSignature -LiteralPath $setup
  $report.authenticode = $signature.Status.ToString()
  if ($signature.Status -eq 'NotSigned') {
    Write-Warning "Unsigned public Windows installer: verified SHA256 does NOT provide trusted publisher identity or remove SmartScreen warnings."
  } elseif ($signature.Status -ne 'Valid') {
    throw "Windows installer Authenticode signature is invalid: $($signature.Status)"
  }

  # Exercise a real published previous-version upgrade when available.
  $releases = @(Invoke-GhJson "repos/$Repository/releases?per_page=50")
  $candidates = @()
  foreach ($candidate in $releases) {
    if ($candidate.draft -or $candidate.prerelease) { continue }
    if ($candidate.tag_name -notmatch '^v\d+\.\d+\.\d+$') { continue }
    $parsed = $null
    if (-not [version]::TryParse($candidate.tag_name.Substring(1), [ref]$parsed)) { continue }
    if ($parsed -ge [version]$versionText) { continue }
    $assetName = 'nanodictate-' + $candidate.tag_name.Substring(1) + '-windows-x64-setup.exe'
    if (@($candidate.assets | Where-Object { $_.name -ceq $assetName }).Count -gt 0) { $candidates += $candidate }
  }
  $previous = $candidates | Sort-Object { [version]$_.tag_name.Substring(1) } -Descending | Select-Object -First 1
  if ($previous) {
    $oldVersion = $previous.tag_name.Substring(1)
    $oldName = "nanodictate-$oldVersion-windows-x64-setup.exe"
    $oldDir = Join-Path $work 'previous'
    [void](Get-VerifiedAssets $previous $oldDir @($oldName))
    Invoke-Setup (Join-Path $oldDir $oldName)
    Write-Host "Installed actual previous Windows release $oldVersion"
  } else {
    Invoke-Setup $setup
    Write-Warning 'No previous Windows installer found: exercising same-version reinstall rather than versioned upgrade'
  }
  # v0.1.33 predates the persistent Run-key registration. Assert the
  # installed file layout for the old version; require startup only after
  # upgrading to the current release.
  Assert-Installed (-not [bool]$previous)
  $report.install = $true
  New-Item -ItemType Directory -Path (Split-Path $configFile) -Force | Out-Null
  if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    $hadPriorConfig = $true
    Copy-Item -LiteralPath $configFile -Destination $configBackup -Force
  }
  Set-Content -LiteralPath $configFile -Value $configSentinel -NoNewline

  Invoke-Setup $setup
  Assert-Installed
  if ((Get-Content -LiteralPath $configFile -Raw) -cne $configSentinel) { throw 'Upgrade destroyed user configuration' }
  $report.upgrade_or_reinstall = $true

  # Installing published binaries on a hosted service account does not prove
  # a WinUI desktop launches, captures microphone input or handles Alt keys.
  Uninstall
  $report.uninstall = $true
  if ((Get-Content -LiteralPath $configFile -Raw) -cne $configSentinel) { throw 'Uninstall deleted user configuration' }
  $report.user_data_preserved = $true

  # Prove the tested installer registers startup on a clean machine. A Run
  # value left by the previous release can survive the upgrade, so the
  # upgrade-time Assert-Installed above cannot prove the new EXE creates it.
  # Uninstall removes the value marked uninsdeletevalue, so reinstalling now
  # verifies first-time registration before leaving the runner clean again.
  Invoke-Setup $setup
  Assert-Installed
  Uninstall
  if ((Get-Content -LiteralPath $configFile -Raw) -cne $configSentinel) { throw 'Uninstall deleted user configuration' }

  $bucketPath = Join-Path $repoRoot 'bucket/nanodictate.json'
  if (Test-Path -LiteralPath $bucketPath) {
    $bucket = Get-Content -LiteralPath $bucketPath -Raw | ConvertFrom-Json
    if ($bucket.version -eq $versionText) {
      if ($bucket.architecture.'64bit'.hash -cne $sums[$zipName]) {
        throw "Scoop manifest hash differs from published ZIP SHA256"
      }
      $expectedUrl = "https://github.com/$Repository/releases/download/v$versionText/$zipName"
      if ($bucket.architecture.'64bit'.url -cne $expectedUrl) {
        throw 'Scoop manifest URL does not identify the published ZIP'
      }
    } else {
      Write-Warning "Scoop manifest version $($bucket.version) differs from tested $versionText (manifest sync may be pending)"
    }
  }
  Write-Host "::notice::Published Windows $($release.tag_name) passed checksum, portable, install, upgrade/reinstall, uninstall and data-retention smoke."
} finally {
  $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportFile -Encoding utf8
  if ($hadPriorConfig) {
    if (Test-Path -LiteralPath $configBackup -PathType Leaf) {
      Copy-Item -LiteralPath $configBackup -Destination $configFile -Force
    }
  } elseif (Test-Path -LiteralPath $configFile -PathType Leaf) {
    $current = Get-Content -LiteralPath $configFile -Raw -ErrorAction SilentlyContinue
    if ($current -ceq $configSentinel) { Remove-Item -LiteralPath $configFile -Force }
  }
  if ((Test-Path -LiteralPath (Join-Path $installDir 'unins000.exe'))) {
    Write-Warning 'Cleaning up installed application after an incomplete smoke'
    try { Uninstall } catch { Write-Warning "Cleanup failed: $_" }
  }
}
