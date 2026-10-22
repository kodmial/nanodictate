#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunnerModulePath,
    [Parameter(Mandatory = $true)][string]$FixtureScript,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$WorkDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Save-Result {
    param($Result)
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}

$result = [ordered]@{
    is_elevated        = $null
    trace_available    = $null
    failure_errors     = @()
    success_exit_codes = @()
    error              = $null
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $result.is_elevated = [bool]$principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    Import-Module $RunnerModulePath -Force
    $runnerModule = Get-Module windows-installer-runner
    $pwshPath = (Get-Process -Id $PID).Path

    $trace = & $runnerModule {
        param($phase)
        Start-ProcessTrace -Phase $phase
    } 'non-elevated-trace'
    try {
        $result.trace_available = $null -ne $trace
    } finally {
        & $runnerModule {
            param($processTrace)
            Stop-ProcessTrace -ProcessTrace $processTrace
        } $trace
    }

    New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null

    for ($run = 1; $run -le 5; $run++) {
        $errorMessage = & $runnerModule {
            param($executable, $fixture, $pidFile, $phase)
            function script:Register-CimIndicationEvent {
                throw 'simulated non-elevated trace registration failure'
            }
            try {
                try {
                    Invoke-BoundedInstallerProcess -FilePath $executable -ArgumentList @(
                        '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                        '-WorkerScript', $fixture,
                        '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', '9',
                        '-BootstrapDelayMilliseconds', '0',
                        '-PidFile', $pidFile
                    ) -Phase $phase -TimeoutSeconds 15 | Out-Null
                    return 'the bootstrap worker failure was masked'
                } catch {
                    return $_.Exception.Message
                }
            } finally {
                Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
            }
        } $pwshPath $FixtureScript (Join-Path $WorkDirectory "non-elevated-fail-$run.pid") `
            "non-elevated-fail-$run"
        $result.failure_errors += $errorMessage
    }

    for ($run = 1; $run -le 3; $run++) {
        $exitCode = & $runnerModule {
            param($executable, $fixture, $pidFile, $phase)
            function script:Register-CimIndicationEvent {
                throw 'simulated non-elevated trace registration failure'
            }
            try {
                try {
                    $bounded = Invoke-BoundedInstallerProcess -FilePath $executable -ArgumentList @(
                        '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                        '-WorkerScript', $fixture,
                        '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', '0',
                        '-BootstrapDelayMilliseconds', '0',
                        '-PidFile', $pidFile
                    ) -Phase $phase -TimeoutSeconds 15
                    return [int]$bounded.ExitCode
                } catch {
                    return "error: $($_.Exception.Message)"
                }
            } finally {
                Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
            }
        } $pwshPath $FixtureScript (Join-Path $WorkDirectory "non-elevated-ok-$run.pid") `
            "non-elevated-ok-$run"
        $result.success_exit_codes += $exitCode
    }
} catch {
    $result.error = $_.Exception.Message
} finally {
    try { Save-Result $result } catch { }
}

if ($null -ne $result.error) { exit 1 }
if ($result.is_elevated) { exit 1 }
if (@($result.failure_errors).Count -ne 5) { exit 1 }
if (@($result.failure_errors | Where-Object { $_ -notmatch 'exited with code 9' }).Count -ne 0) { exit 1 }
if (@($result.success_exit_codes).Count -ne 3) { exit 1 }
if (@($result.success_exit_codes | Where-Object { $_ -ne 0 }).Count -ne 0) { exit 1 }
exit 0
