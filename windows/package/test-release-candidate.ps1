#Requires -Version 7.0
<#
.SYNOPSIS
  Blocking Windows release candidate smoke. Runs on a clean windows-latest
  runner *before* uploading candidate artifacts to GitHub Releases.
  Validates the exact published ZIP/EXE pair from this build.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$OutDir = 'windows/artifacts'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release version' }
$zip = Join-Path $OutDir "nanodictate-$Version-windows-x64.zip"
$setup = Join-Path $OutDir "nanodictate-$Version-windows-x64-setup.exe"
if (!(Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Missing candidate ZIP: $zip" }
if (!(Test-Path -LiteralPath $setup -PathType Leaf)) { throw "Missing candidate EXE: $setup" }
$root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $root ("nanodictate-candidate-" + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $work 'installed'
$unpacked = Join-Path $work 'zip'
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$marker = Join-Path $env:APPDATA ("NanoDictate\candidate-smoke-" + [guid]::NewGuid().ToString('N') + '.txt')
$cleanupNeeded = $false
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Get-Startup {
  $properties = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
  if ($null -eq $properties) { return '' }
  $property = $properties.PSObject.Properties['NanoDictate']
  if ($null -eq $property) { return '' }
  return [string]$property.Value
}
function Invoke-Silent([string]$file, [string[]]$arguments) {
  $p = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "Installer/uninstaller failed with exit code $($p.ExitCode)" }
}
function Uninstall {
  $uninstaller = Join-Path $dir 'unins000.exe'
  if (!(Test-Path -LiteralPath $uninstaller)) { throw 'Missing installed Inno uninstaller' }
  Invoke-Silent $uninstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
  if (Test-Path (Join-Path $dir 'NanoDictate.App.exe')) { throw 'Uninstall left the application' }
  if (Get-Startup) { throw 'Uninstall left orphaned startup registration' }
}
try {
  Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
  foreach ($name in @('NanoDictate.App.exe','NanoDictate.App.dll',
     'NanoDictate.App.runtimeconfig.json','nanodictate_core.dll',
     'coreclr.dll','hostfxr.dll','config.example.toml')) {
    if (!(Test-Path -LiteralPath (Join-Path $unpacked $name) -PathType Leaf)) {
      throw "Candidate ZIP missing $name"
    }
  }
  $auth = Get-AuthenticodeSignature -LiteralPath $setup
  if ($auth.Status -eq 'NotSigned') {
    Write-Warning 'Candidate installer is unsigned: trusted code signing is a separate publisher prerequisite'
  } elseif ($auth.Status -ne 'Valid') { throw "Invalid candidate installer signature: $($auth.Status)" }
  $cleanupNeeded = $true
  Invoke-Silent (Resolve-Path $setup).Path @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$dir`"")
  $zipFiles = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File)
  if ($zipFiles.Count -eq 0) { throw 'Candidate ZIP is empty' }
  foreach ($file in $zipFiles) {
    $relative = [IO.Path]::GetRelativePath($unpacked, $file.FullName)
    $target = Join-Path $dir $relative
    if (!(Test-Path -LiteralPath $target -PathType Leaf)) { throw "Installer missing $relative" }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
      throw "Installed $relative differs from exact candidate ZIP bytes"
    }
  }
  $wanted = '"' + (Join-Path $dir 'NanoDictate.App.exe') + '" --background'
  if ((Get-Startup) -cne $wanted) { throw 'Candidate installer did not register stable per-user auto-start' }
  New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
  Set-Content -LiteralPath $marker -Value 'preserve' -NoNewline
  Uninstall
  $cleanupNeeded = $false
  if ((Get-Content -LiteralPath $marker -Raw) -cne 'preserve') { throw 'Uninstall deleted user data' }
  Write-Host "::notice::Exact Windows $Version release candidate passed ZIP/EXE identity, install, registry, uninstall and preservation smoke."
} finally {
  if ($cleanupNeeded -and (Test-Path -LiteralPath (Join-Path $dir 'unins000.exe'))) {
    try { Uninstall } catch { Write-Warning "Candidate cleanup failed: $_" }
  }
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
}
