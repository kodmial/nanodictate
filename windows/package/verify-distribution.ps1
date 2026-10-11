#Requires -Version 7.0
<#
.SYNOPSIS
  Post-publication Windows distribution smoke: real published Inno Setup or
  first-party Scoop installation on a fresh GitHub-hosted Windows runner.
.DESCRIPTION
  Verifies public release bytes against SHA256SUMS, exercises install/reinstall/
  uninstall, checks self-contained payload and user-data preservation, and
  records Authenticode state separately from functional smoke.
  Does NOT claim real microphone, UI, or physical-hardware parity.
#>
param(
  [ValidateSet('inno','scoop')][string]$Channel = 'inno',
  [string]$Repository = 'kodmial/nanodictate'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Run([string]$Exe, [string[]]$Arguments) {
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE ($($Arguments -join ' '))" }
}
function Download([string]$Url, [string]$Path) {
  Invoke-WebRequest -Uri $Url -OutFile $Path -MaximumRedirection 5
  Require (Test-Path -LiteralPath $Path) "Download missing: $Url"
}
function ReleaseHash([string]$Text, [string]$Filename) {
  $pattern = '(?im)^([a-f0-9]{64})\s+\*?' + [regex]::Escape($Filename) + '\s*$'
  $hit = [regex]::Match($Text, $pattern)
  Require $hit.Success "Published SHA256SUMS.txt lacks $Filename"
  return $hit.Groups[1].Value.ToLowerInvariant()
}
function VerifyHash([string]$File, [string]$Expected) {
  $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
  Require ($actual -eq $Expected) "SHA256 mismatch for $File: expected $Expected, got $actual"
}
function VerifyPayload([string]$Dir) {
  foreach ($name in @('NanoDictate.App.exe','NanoDictate.App.dll','nanodictate_core.dll',
                       'hostfxr.dll','coreclr.dll','config.example.toml')) {
    Require (Test-Path -LiteralPath (Join-Path $Dir $name)) "Installed distribution missing $name"
  }
}
function CheckSignature([string]$Path) {
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  $status = [string]$signature.Status
  if ($status -ne 'Valid') {
    Write-Warning "WINDOWS_SIGNING=UNVERIFIED; $([IO.Path]::GetFileName($Path)) Authenticode status=$status. Functional smoke passing does NOT certify a signed Windows release."
    if ($env:GITHUB_STEP_SUMMARY) {
      "Windows signing: **UNVERIFIED** ($status). Production signing requires a verified publisher and trusted certificate/Store signing." | Add-Content $env:GITHUB_STEP_SUMMARY
    }
  } else {
    Write-Host "WINDOWS_SIGNING=VALID: $($signature.SignerCertificate.Subject)"
    if ($env:GITHUB_STEP_SUMMARY) { "Windows signing: **VALID** — $($signature.SignerCertificate.Subject)" | Add-Content $env:GITHUB_STEP_SUMMARY }
  }
}
function VerifyAutoStart([string]$Exe) {
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $actual = (Get-ItemProperty -Path $key -Name NanoDictate -ErrorAction SilentlyContinue).NanoDictate
  $expected = '"' + $Exe + '" --background'
  Require ($actual -eq $expected) "Persistent logon startup mismatch: expected $expected, got $actual"
}
function VerifyClearedAutoStart {
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $value = (Get-ItemProperty -Path $key -Name NanoDictate -ErrorAction SilentlyContinue).NanoDictate
  Require (-not $value) "Uninstall left NanoDictate logon startup registered"
}
Require ($env:OS -eq 'Windows_NT') 'Windows production smoke requires a real Windows runner.'
$headers = @{ 'User-Agent'='NanoDictate-windows-distribution-smoke'; 'Accept'='application/vnd.github+json' }
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
$version = [string]$release.tag_name
Require ($version -match '^v\d+\.\d+\.\d+$') "Unexpected stable release tag: $version"
$version = $version.Substring(1)
$root = Join-Path $env:RUNNER_TEMP ('nd-production-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
  $sumsAsset = $release.assets | Where-Object name -eq 'SHA256SUMS.txt' | Select-Object -First 1
  Require ($null -ne $sumsAsset) "Release v$version has no SHA256SUMS.txt"
  $sumsPath = Join-Path $root 'SHA256SUMS.txt'
  Download $sumsAsset.browser_download_url $sumsPath
  $sums = Get-Content -LiteralPath $sumsPath -Raw

  $exeName = "nanodictate-$version-windows-x64-setup.exe"
  $zipName = "nanodictate-$version-windows-x64.zip"
  $files = @{}
  foreach ($name in @($exeName, $zipName)) {
    $asset = $release.assets | Where-Object name -eq $name | Select-Object -First 1
    Require ($null -ne $asset) "Release v$version missing $name"
    $path = Join-Path $root $name
    Download $asset.browser_download_url $path
    VerifyHash $path (ReleaseHash $sums $name)
    $files[$name] = $path
    Write-Host "PASS: published $name matches SHA256SUMS.txt"
  }
  CheckSignature $files[$exeName]

  $zipFolder = Join-Path $root 'portable'
  Expand-Archive -LiteralPath $files[$zipName] -DestinationPath $zipFolder
  VerifyPayload $zipFolder
  CheckSignature (Join-Path $zipFolder 'NanoDictate.App.exe')
  Write-Host 'PASS: published portable ZIP contains a self-contained .NET/WinUI payload and Rust DLL'

  $marker = Join-Path $env:APPDATA 'NanoDictate\ci-production-distribution-marker.txt'
  New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
  Set-Content -LiteralPath $marker -Value 'preserve' -NoNewline
  try {
    if ($Channel -eq 'inno') {
      $installed = Join-Path $env:LOCALAPPDATA 'Programs\NanoDictate'
      $app = Join-Path $installed 'NanoDictate.App.exe'
      $args = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-')
      $p = Start-Process -FilePath $files[$exeName] -ArgumentList $args -Wait -PassThru
      Require ($p.ExitCode -eq 0) "Published Inno install failed: $($p.ExitCode)"
      VerifyPayload $installed
      VerifyAutoStart $app
      $p = Start-Process -FilePath $files[$exeName] -ArgumentList $args -Wait -PassThru
      Require ($p.ExitCode -eq 0) "Published Inno reinstall failed: $($p.ExitCode)"
      VerifyAutoStart $app
      Require ((Get-Content $marker -Raw) -eq 'preserve') 'Inno reinstall changed user configuration'
      $uninstaller = Join-Path $installed 'unins000.exe'
      Require (Test-Path $uninstaller) 'Inno uninstaller not installed'
      $p = Start-Process -FilePath $uninstaller -ArgumentList $args -Wait -PassThru
      Require ($p.ExitCode -eq 0) "Published Inno uninstall failed: $($p.ExitCode)"
      Require (-not (Test-Path $app)) 'Inno uninstall left application installed'
      VerifyClearedAutoStart
    } else {
      $manifestUrl = "https://raw.githubusercontent.com/$Repository/main/bucket/nanodictate.json"
      $manifest = $null
      # Publishing the release and syncing the Scoop bucket are separate
      # operations. Give the bounded first-party sync a chance to finish.
      for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $manifest = Invoke-RestMethod -Uri "$manifestUrl?nocache=$([guid]::NewGuid().ToString('N'))"
        if ($manifest.version -eq $version) { break }
        Write-Host "Waiting for public Scoop manifest v$version (found $($manifest.version)); attempt $($attempt + 1)/20"
        Start-Sleep -Seconds 20
      }
      Require ($manifest.version -eq $version) "Published Scoop bucket not synchronized to release v$version"
      Require ($manifest.architecture.'64bit'.hash.ToLowerInvariant() -eq (ReleaseHash $sums $zipName)) 'Scoop pinned SHA256 disagrees with release ZIP'
      Require ($manifest.architecture.'64bit'.url -eq "https://github.com/$Repository/releases/download/v$version/$zipName") 'Scoop URL is not the exact published release ZIP'

      $scoopRoot = Join-Path $root 'scoop'
      $bootstrap = Join-Path $root 'scoop-install.ps1'
      Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
      Download 'https://get.scoop.sh' $bootstrap
      & $bootstrap -RunAsAdmin -ScoopDir $scoopRoot
      Require ($LASTEXITCODE -eq 0) "Scoop bootstrap failed: $LASTEXITCODE"
      $env:SCOOP = $scoopRoot
      $env:PATH = (Join-Path $scoopRoot 'shims') + ';' + $env:PATH
      Run 'scoop' @('bucket','add','nanodictate',"https://github.com/$Repository")
      Run 'scoop' @('install','nanodictate')
      $installed = Join-Path $scoopRoot 'apps\nanodictate\current'
      VerifyPayload $installed
      VerifyAutoStart (Join-Path $installed 'NanoDictate.App.exe')
      Run 'scoop' @('uninstall','nanodictate')
      Require (-not (Test-Path (Join-Path $installed 'NanoDictate.App.exe'))) 'Scoop uninstall left product installed'
      VerifyClearedAutoStart
    }
    Require ((Get-Content -LiteralPath $marker -Raw) -eq 'preserve') 'Distribution channel deleted user configuration'
    Write-Host "PASS: v$version $Channel public install/reinstall-if-applicable/uninstall; preserved config; logon startup verified"
    if ($env:GITHUB_STEP_SUMMARY) {
      "Windows $Channel production lifecycle: **PASS** — release v$version; verified SHA256; install/uninstall and user config" | Add-Content $env:GITHUB_STEP_SUMMARY
    }
  } finally {
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
  }
} finally {
  Remove-Item -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue
}
