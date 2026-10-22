#Requires -Version 7.0
<#
  Reproduces the old unsafe pattern: Start-Process -Wait, which on Windows
  waits for the whole process tree. Used only by the installer-runner regression
  harness to prove the pre-fix hang with a short-lived launcher and persistent
  child.
#>
param(
    [Parameter(Mandatory = $true)][string]$Fixture,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$PidFile
)

$ErrorActionPreference = 'Stop'
$pwshPath = (Get-Process -Id $PID).Path
$process = Start-Process -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', $Fixture,
    '-Mode', $Mode,
    '-PidFile', $PidFile
) -Wait -PassThru
exit $process.ExitCode
