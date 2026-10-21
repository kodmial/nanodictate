# Windows 10/11 x64 first-party one-command installer/update.
# Usage (normal, non-admin PowerShell):
# irm https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-windows.ps1 | iex
#
# The newest complete stable release wins even when the first-party Scoop
# manifest has not caught up yet: both the manifest version and GitHub's
# latest stable release are candidates, and a candidate is only usable when
# its EXE asset and the matching SHA256SUMS.txt entry both exist. Nothing is
# executed before the downloaded files match the published checksum.
[CmdletBinding()]
param(
    # Downloads and verifies the selected release without installing it.
    # Useful for auditing the manifest -> release asset -> checksum chain.
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$repo = 'https://github.com/kodmial/nanodictate'
$headers = @{ 'User-Agent' = 'NanoDictate-installer'; 'Accept' = 'application/vnd.github+json' }
$manifestUrl = 'https://raw.githubusercontent.com/kodmial/nanodictate/main/bucket/nanodictate.json'

function Get-ManifestVersion {
    try {
        $url = $manifestUrl + '?nocache=' + [Guid]::NewGuid().ToString('N')
        $manifest = Invoke-RestMethod -Uri $url -UseBasicParsing
        $version = [string]$manifest.version
        if ($version -match '^\d+\.\d+\.\d+$') { return $version }
    } catch {
        Write-Verbose "Scoop manifest lookup unavailable: $($_.Exception.Message)"
    }
    return $null
}

function Get-LatestReleaseVersion {
    # A stale manifest must not pin users to an older release. If the public
    # API is unavailable, the manifest remains a safe fallback.
    try {
        $release = Invoke-RestMethod -Uri "$repo/releases/latest" -Headers $headers -UseBasicParsing
        $tag = [string]$release.tag_name
        if ($tag -match '^v(\d+\.\d+\.\d+)$') { return $Matches[1] }
    } catch {
        Write-Verbose "Latest release lookup unavailable: $($_.Exception.Message)"
    }
    return $null
}

function Get-VerifiedRelease([string]$ManifestVersion) {
    $latestVersion = Get-LatestReleaseVersion
    $candidates = @($latestVersion, $ManifestVersion) |
        Where-Object { $_ -and $_ -match '^\d+\.\d+\.\d+$' } |
        Select-Object -Unique
    $candidates = @($candidates | Sort-Object { [version]$_ } -Descending)
    $errors = @()
    foreach ($version in $candidates) {
        $file = "nanodictate-$version-windows-x64-setup.exe"
        $assets = "$repo/releases/download/v$version"
        try {
            $sumText = [string](Invoke-RestMethod -Uri "$assets/SHA256SUMS.txt" -Headers $headers -UseBasicParsing)
            $match = [regex]::Match($sumText, "(?im)^([a-f0-9]{64})\s+\*?" + [regex]::Escape($file) + "\s*$")
            if (-not $match.Success) { throw "Release checksum missing for $file" }
            # Fail over to the manifest-pinned release if a brand-new latest
            # release has checksums but its EXE upload is still incomplete.
            $null = Invoke-WebRequest -Uri "$assets/$file" -Method Head -Headers $headers -UseBasicParsing -MaximumRedirection 5
            return [pscustomobject]@{
                Version      = $version
                File         = $file
                Assets       = $assets
                ExpectedHash = $match.Groups[1].Value.ToUpperInvariant()
            }
        } catch {
            $errors += "v${version}: $($_.Exception.Message)"
        }
    }
    throw "No complete published Windows release found. $($errors -join '; ')"
}

function Invoke-NanoDictateInstall {
    if (-not $VerifyOnly) {
        if (-not [Environment]::Is64BitOperatingSystem) { throw 'NanoDictate requires 64-bit Windows 10/11.' }
        if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'This installer runs on Windows only.' }
    }
    $manifestVersion = Get-ManifestVersion
    $release = Get-VerifiedRelease $manifestVersion
    $version = $release.Version
    $file = $release.File
    $assets = $release.Assets
    $expectedHash = $release.ExpectedHash
    Write-Host "Selected NanoDictate $version from the latest complete published release (manifest $manifestVersion)."

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("NanoDictate-" + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp) | Out-Null
    try {
        $installer = Join-Path $tmp $file
        $download = [Diagnostics.Stopwatch]::StartNew()
        Invoke-WebRequest -Uri "$assets/$file" -OutFile $installer -Headers $headers -UseBasicParsing
        $download.Stop()
        $sizeMb = [Math]::Round((Get-Item -LiteralPath $installer).Length / 1MB, 1)
        $actualHash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) { throw 'Download SHA-256 verification failed; refusing to install.' }
        Write-Host ("Verified SHA-256 for {0} ({1} MB, downloaded in {2:N1}s)." -f $file, $sizeMb, $download.Elapsed.TotalSeconds)
        if ($VerifyOnly) {
            Write-Host "Verify-only: manifest -> release asset -> checksum chain is complete for v$version."
            return
        }

        $target = Join-Path $env:LOCALAPPDATA 'Programs\NanoDictate'
        $exe = Join-Path $target 'NanoDictate.App.exe'
        # Inno updates the same install path and AppId; stop the previous version
        # before replacing binaries to avoid dialogs/reboots/file-in-use failures.
        $targetPrefix = $target.TrimEnd('\') + '\'
        @(Get-Process -Name 'NanoDictate.App' -ErrorAction SilentlyContinue) | Where-Object {
            try { $_.Path -and $_.Path.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase) }
            catch { $false }
        } | Stop-Process -Force -ErrorAction Stop
        $install = [Diagnostics.Stopwatch]::StartNew()
        # /DIR must stay quoted for profile paths containing spaces.
        $setup = Start-Process -FilePath $installer -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $target + '"')
        ) -Wait -PassThru
        $install.Stop()
        if ($setup.ExitCode -ne 0) { throw "NanoDictate setup failed: $($setup.ExitCode)" }
        if (-not (Test-Path $exe)) { throw 'Setup exited successfully but the application is absent.' }
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $autostart = (Get-ItemProperty -Path $key -Name 'NanoDictate' -ErrorAction SilentlyContinue).NanoDictate
        if ($autostart -ne ('"' + $exe + '" --background')) {
            # Also repairs the previously published v0.1.33 installer, which did
            # not yet register logon startup. Does not require administrator rights.
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name 'NanoDictate' -Value ('"' + $exe + '" --background')
        }
        # First install and upgrade both start exactly one quiet background agent.
        # Settings stays optional (Start Menu shortcut or a second idle launch).
        Start-Process -FilePath $exe -ArgumentList '--background'
        Write-Host ("Installed NanoDictate {0} in {1:N1}s and started it in the background." -f $version, $install.Elapsed.TotalSeconds)
        Write-Host 'It will start automatically when you sign into Windows. Double-Alt starts and stops dictation.'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Dot-sourcing exposes the selection functions for the offline chain tests;
# normal file execution and the documented irm | iex path run the install.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-NanoDictateInstall
}
