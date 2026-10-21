# Windows 10/11 x64 first-party one-command installer/update.
# Usage (normal, non-admin PowerShell):
# irm https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-windows.ps1 | iex
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'NanoDictate requires 64-bit Windows 10/11.' }
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'This installer runs on Windows only.' }
$repo = 'https://github.com/kodmial/nanodictate'
$raw = 'https://raw.githubusercontent.com/kodmial/nanodictate/main/bucket/nanodictate.json'
$manifest = Invoke-RestMethod -Uri $raw -UseBasicParsing
$version = [string]$manifest.version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'No published Windows version in the first-party bucket.' }
$file = "nanodictate-$version-windows-x64-setup.exe"
$assets = "$repo/releases/download/v$version"
$sumText = [string](Invoke-RestMethod -Uri "$assets/SHA256SUMS.txt" -UseBasicParsing)
$match = [regex]::Match($sumText, "(?im)^([a-f0-9]{64})\s+\*?"+[regex]::Escape($file)+"\s*$")
if (-not $match.Success) { throw "Release checksum missing for $file" }
$expectedHash = $match.Groups[1].Value.ToUpperInvariant()

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("NanoDictate-" + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tmp) | Out-Null
try {
    $installer = Join-Path $tmp $file
    Invoke-WebRequest -Uri "$assets/$file" -OutFile $installer -UseBasicParsing
    $actualHash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) { throw 'Download SHA-256 verification failed; refusing to install.' }
    $target = Join-Path $env:LOCALAPPDATA 'Programs\NanoDictate'
    $exe = Join-Path $target 'NanoDictate.App.exe'
    $previousInstall = Test-Path $exe
    # Inno updates the same install path and AppId; stop the previous version
    # before replacing binaries to avoid dialogs/reboots/file-in-use failures.
    $targetPrefix = $target.TrimEnd('\') + '\'
    @(Get-Process -Name 'NanoDictate.App' -ErrorAction SilentlyContinue) | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase) }
        catch { $false }
    } | Stop-Process -Force -ErrorAction Stop
    $install = Start-Process -FilePath $installer -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$target"
    ) -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "NanoDictate setup failed: $($install.ExitCode)" }
    if (-not (Test-Path $exe)) { throw 'Setup exited successfully but the application is absent.' }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $autostart = (Get-ItemProperty -Path $key -Name 'NanoDictate' -ErrorAction SilentlyContinue).NanoDictate
    if ($autostart -ne ('"' + $exe + '" --background')) {
        # Also repairs the previously published v0.1.33 installer, which did
        # not yet register logon startup. Does not require administrator rights.
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name 'NanoDictate' -Value ('"' + $exe + '" --background')
    }
    # First use opens optional settings; subsequent upgrades resume silently.
    if (-not $previousInstall) {
        Start-Process -FilePath $exe -ArgumentList '--settings'
    } else {
        Start-Process -FilePath $exe -ArgumentList '--background'
    }
    Write-Host "NanoDictate $version installed and running. It will start automatically when you sign into Windows."
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
