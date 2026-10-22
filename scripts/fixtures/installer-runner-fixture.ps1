#Requires -Version 5.1
<#
  Deterministic lifecycle fixture used by test-windows-installer-runner.ps1.
  It is deliberately a plain console process, not a product binary.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('sleep', 'detached', 'bootstrap')]
    [string]$Mode,
    [int]$SleepMilliseconds = 0,
    [int]$ExitCode = 0,
    [int]$WorkerSleepMilliseconds = 0,
    [int]$WorkerExitCode = 0,
    [int]$BootstrapDelayMilliseconds = 500,
    [string]$PidFile = '',
    [string]$WorkerScript = '',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$IgnoredArguments = @()
)

$ErrorActionPreference = 'Stop'
$pwshPath = (Get-Process -Id $PID).Path

function Save-Pid([int]$ProcessId) {
    if ($PidFile) { Set-Content -LiteralPath $PidFile -Value $ProcessId -NoNewline }
}

switch ($Mode) {
    'sleep' {
        Save-Pid $PID
        Start-Sleep -Milliseconds $SleepMilliseconds
        exit $ExitCode
    }
    'detached' {
        $child = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ping.exe') `
                -ArgumentList @('-n', '120', '127.0.0.1') -PassThru
        } else {
            Start-Process -FilePath '/bin/sleep' -ArgumentList @('120') -PassThru
        }
        Save-Pid $child.Id
        Start-Sleep -Milliseconds ([Math]::Max(500, $SleepMilliseconds))
        exit $ExitCode
    }
    'bootstrap' {
        if (-not $WorkerScript) { throw 'WorkerScript is required for bootstrap mode.' }
        $child = Start-Process -FilePath $pwshPath -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $WorkerScript,
            '-Mode', 'sleep',
            '-SleepMilliseconds', [string]$WorkerSleepMilliseconds,
            '-ExitCode', [string]$WorkerExitCode
        ) -PassThru
        Save-Pid $child.Id
        Start-Sleep -Milliseconds ([Math]::Max(0, $BootstrapDelayMilliseconds))
        exit $ExitCode
    }
}
