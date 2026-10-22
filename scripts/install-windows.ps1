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
$latestReleaseUrl = 'https://api.github.com/repos/kodmial/nanodictate/releases/latest'
$runnerUrl = 'https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/windows-installer-runner.psm1'

function Import-NanoDictateRunner {
    # Repo checkouts/CI import the shared module directly. The documented
    # irm | iex path has no local files, so load the same module source from
    # the same branch as this script instead of duplicating the runner.
    if (Get-Module -Name 'windows-installer-runner') { return }
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'windows-installer-runner.psm1' } else { '' }
    if ($local -and (Test-Path -LiteralPath $local -PathType Leaf)) {
        Import-Module $local -Force
        return
    }
    $runnerSource = [string](Invoke-RestMethod -Uri $runnerUrl -Headers $headers -UseBasicParsing)
    if ($runnerSource -notmatch 'function Invoke-BoundedInstallerProcess') {
        throw 'The NanoDictate installer runner could not be loaded.'
    }
    New-Module -Name 'windows-installer-runner' -ScriptBlock ([scriptblock]::Create($runnerSource)) |
        Import-Module -Force
}

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
        $release = Invoke-RestMethod -Uri $latestReleaseUrl -Headers $headers -UseBasicParsing
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

function Invoke-NanoDictateInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$Target,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 240,
        [string]$LogDirectory,
        [string]$Phase = 'user-install',
        [string[]]$ArgumentList
    )
    Import-NanoDictateRunner
    $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
    if (-not $PSBoundParameters.ContainsKey('ArgumentList')) {
        $ArgumentList = @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR=' + $Target)
        )
    }
    $runnerArgs = @{
        FilePath       = $installer
        ArgumentList   = $ArgumentList
        Phase          = $Phase
        TimeoutSeconds = $TimeoutSeconds
    }
    if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
        $runnerArgs.LogDirectory = $LogDirectory
        $runnerArgs.InnoLogFileName = "$Phase.log"
    }
    return Invoke-BoundedInstallerProcess @runnerArgs
}

function Install-NanoDictateVerified {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Target,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 240,
        [string]$LogDirectory
    )
    Import-NanoDictateRunner
    $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
    $succeeded = $false
    try {
        $exe = Join-Path $Target 'NanoDictate.App.exe'
        # Inno updates the same install path and AppId; stop only the previous
        # agent that runs from this exact target before replacing locked payloads.
        [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $Target)

        $install = [Diagnostics.Stopwatch]::StartNew()
        # The bounded runner quotes /DIR for profile paths containing spaces and
        # waits for the real Inno phase, not the persistent --background app
        # that the installer intentionally leaves running.
        $setup = Invoke-NanoDictateInstaller -InstallerPath $installer -Target $Target `
            -TimeoutSeconds $TimeoutSeconds -LogDirectory $LogDirectory -Phase 'user-install'
        $install.Stop()

        Assert-NanoDictatePayload -InstallDirectory $Target
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $expectedStartup = '"' + $exe + '" --background'
        if ((Get-NanoDictateStartupValue) -ne $expectedStartup) {
            # Also repairs the previously published v0.1.33 installer, which did
            # not yet register logon startup. Does not require administrator rights.
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name 'NanoDictate' -Value $expectedStartup
        }
        Assert-NanoDictateStartup -InstallDirectory $Target

        # Inno already launched one --background agent. Wait for it, and only
        # start the app ourselves when setup could not leave one running.
        $agents = @(Start-NanoDictateBackgroundIfNeeded -InstallDirectory $Target -TimeoutSeconds 30)
        if ($agents.Count -eq 1) {
            Write-Host ("Background agent pid {0} is running." -f $agents[0].Id)
        } else {
            Write-Warning 'NanoDictate installed successfully but no background agent is currently running.'
        }
        $succeeded = $true
        return [pscustomobject]@{
            Version                = $Version
            InstallSeconds         = [Math]::Round($install.Elapsed.TotalSeconds, 2)
            InstallerExitCode      = $setup.ExitCode
            BackgroundAgentRunning = ($agents.Count -eq 1)
            BackgroundAgentIds     = @($agents | ForEach-Object { $_.Id })
        }
    } finally {
        if (-not $succeeded) {
            # A failed or timed-out install must not leave a half-started agent
            # from this exact target. Installed files/user data are retained for
            # diagnosis; only the process this phase may have launched is stopped.
            try { [void](Stop-NanoDictateProcessesUnderPath -InstallDirectory $Target) } catch {
                Write-Warning "Could not stop a partial NanoDictate agent: $_"
            }
        }
    }
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
        # First install and upgrade both start exactly one quiet background
        # agent. Settings stays optional (Start Menu shortcut or a second idle
        # launch). The install log stays beside the downloaded installer only
        # when a caller explicitly requests retained diagnostics.
        $logDirectory = Join-Path $env:LOCALAPPDATA 'NanoDictate\installer-logs'
        $result = Install-NanoDictateVerified -InstallerPath $installer -Version $version `
            -Target $target -TimeoutSeconds 240 -LogDirectory $logDirectory
        if ($result.BackgroundAgentRunning) {
            Write-Host ("Installed NanoDictate {0} in {1:N1}s and started it in the background." -f
                $version, $result.InstallSeconds)
        } else {
            Write-Host ("Installed NanoDictate {0} in {1:N1}s. It will start at your next sign-in." -f
                $version, $result.InstallSeconds)
        }
        Write-Host ("Installer diagnostics: {0}" -f $logDirectory)
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
