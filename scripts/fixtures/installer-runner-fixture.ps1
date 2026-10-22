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

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
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
        # UseShellExecute (the Start-Process default) can block under a
        # restricted token on a noninteractive window station. Create the
        # worker directly so qualification also works for a genuine
        # non-elevated child process.
        $workerArguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $WorkerScript,
            '-Mode', 'sleep',
            '-SleepMilliseconds', [string]$WorkerSleepMilliseconds,
            '-ExitCode', [string]$WorkerExitCode
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.Arguments = (@($workerArguments | ForEach-Object {
            Quote-ProcessArgument ([string]$_)
        }) -join ' ')
        $child = [Diagnostics.Process]::Start($startInfo)
        # A closed stdin keeps a mis-bound worker from blocking on a prompt.
        $child.StandardInput.Close()
        Save-Pid $child.Id
        Start-Sleep -Milliseconds ([Math]::Max(0, $BootstrapDelayMilliseconds))
        exit $ExitCode
    }
}
