#Requires -Version 7.0
<#
.SYNOPSIS
  Offline tests for the one-command Windows installer release selection.
.DESCRIPTION
  Exercises the manifest -> release asset -> SHA256SUMS chain without network
  or a Windows host. The tests cover a stale Scoop manifest, a brand-new
  release whose EXE upload is incomplete, unavailable GitHub metadata, and a
  release with incomplete checksums.
#>
$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0
$script:manifest = '1.0.0'
$script:latest = '1.1.0'
$script:checksumVersions = @('1.0.0', '1.1.0')
$script:missingHeadVersions = @()

function Pass([string]$Name) {
    $script:passed++
    Write-Host "ok - $Name"
}
function Fail([string]$Name, [string]$Detail) {
    $script:failed++
    Write-Host "not ok - $Name"
    Write-Host "  $Detail"
}
function Assert-Equal([string]$Name, $Expected, $Actual) {
    if ($Expected -eq $Actual) { Pass $Name }
    else { Fail $Name "expected '$Expected', got '$Actual'" }
}
function Assert-Throws([string]$Name, [scriptblock]$Action) {
    try {
        & $Action | Out-Null
        Fail $Name 'expected an exception, but the call succeeded'
    } catch {
        Pass $Name
    }
}
function Hash([string]$Version) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Version)
    return ([BitConverter]::ToString(
        [Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').ToLowerInvariant()
}
function Get-FileName([string]$Version) {
    return "nanodictate-$Version-windows-x64-setup.exe"
}

# Test doubles shadow the web cmdlets used by the installer functions. They
# intentionally model only the shapes the real responses provide.
function Invoke-RestMethod {
    param([string]$Uri, [hashtable]$Headers, [switch]$UseBasicParsing)
    if ($Uri -match 'bucket/nanodictate\.json') {
        return [pscustomobject]@{ version = $script:manifest }
    }
    if ($Uri -match '/releases/latest$') {
        if (-not $script:latest) { throw 'GitHub API unavailable' }
        return [pscustomobject]@{ tag_name = "v$($script:latest)" }
    }
    if ($Uri -match '/download/v([0-9]+\.[0-9]+\.[0-9]+)/SHA256SUMS\.txt$') {
        $version = $Matches[1]
        if ($script:checksumVersions -notcontains $version) { throw "Checksum asset missing for $version" }
        return "$(Hash $version)  $(Get-FileName $version)`n"
    }
    throw "Unexpected Invoke-RestMethod URI: $Uri"
}
function Invoke-WebRequest {
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [switch]$UseBasicParsing,
        [int]$MaximumRedirection
    )
    if ($Method -eq 'Head' -and $Uri -match '/download/v([0-9]+\.[0-9]+\.[0-9]+)/') {
        $version = $Matches[1]
        if ($script:missingHeadVersions -contains $version) { throw "Asset not uploaded for $version" }
        return [pscustomobject]@{ StatusCode = 200 }
    }
    throw "Unexpected Invoke-WebRequest call: $Method $Uri"
}

. (Join-Path $PSScriptRoot 'install-windows.ps1')

# 1. A stale manifest must not pin the installer to an older release.
$script:manifest = '1.0.0'
$script:latest = '1.1.0'
$script:checksumVersions = @('1.0.0', '1.1.0')
$script:missingHeadVersions = @()
$selected = Get-VerifiedRelease (Get-ManifestVersion)
Assert-Equal 'newer GitHub release wins over a lagging manifest' '1.1.0' $selected.Version
Assert-Equal 'selected checksum is the exact published hash' (Hash '1.1.0').ToUpperInvariant() $selected.ExpectedHash
Assert-Equal 'selected asset name matches the release version' (Get-FileName '1.1.0') $selected.File

# 2. A manifest ahead of the latest stable metadata is the candidate.
$script:manifest = '1.2.0'
$script:latest = '1.1.0'
$script:checksumVersions = @('1.1.0', '1.2.0')
$selected = Get-VerifiedRelease (Get-ManifestVersion)
Assert-Equal 'newest complete candidate is selected' '1.2.0' $selected.Version

# 3. A brand-new release whose EXE upload is not complete falls back.
$script:manifest = '1.0.0'
$script:latest = '1.1.0'
$script:checksumVersions = @('1.0.0', '1.1.0')
$script:missingHeadVersions = @('1.1.0')
$selected = Get-VerifiedRelease (Get-ManifestVersion)
Assert-Equal 'incomplete latest asset falls back to a complete manifest release' '1.0.0' $selected.Version

# 4. A release with checksums but no matching EXE entry falls back.
$script:missingHeadVersions = @()
$script:checksumVersions = @('1.0.0')
$selected = Get-VerifiedRelease (Get-ManifestVersion)
Assert-Equal 'release missing its checksum entry is skipped' '1.0.0' $selected.Version

# 5. GitHub metadata being unavailable must not block the manifest channel.
$script:latest = $null
$script:manifest = '1.0.0'
$script:checksumVersions = @('1.0.0')
$selected = Get-VerifiedRelease (Get-ManifestVersion)
Assert-Equal 'manifest remains usable when the latest-release API is unavailable' '1.0.0' $selected.Version

# 6. No complete release means a loud failure, never an unverified install.
$script:manifest = '1.0.0'
$script:latest = '1.1.0'
$script:checksumVersions = @()
Assert-Throws 'no complete release fails loudly' { Get-VerifiedRelease (Get-ManifestVersion) }

# 7. Invalid manifest versions are ignored rather than treated as a pin.
$script:manifest = 'not-a-version'
Assert-Equal 'invalid manifest version is ignored' $null (Get-ManifestVersion)

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
