#Requires -Version 5.1
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

function Get-WorkerStartError {
    param([string]$PidFile, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($PidFile)) {
        return "$Label did not provide a worker pid file"
    }
    $workerPidFile = "$PidFile.worker"
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
        return "$Label did not record the bootstrap worker pid"
    }
    if (-not (Test-Path -LiteralPath $workerPidFile -PathType Leaf)) {
        return "$Label worker did not run"
    }
    $launchedPid = (Get-Content -LiteralPath $PidFile -Raw).Trim()
    $workerPid = (Get-Content -LiteralPath $workerPidFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($launchedPid) -or $launchedPid -ne $workerPid) {
        return "$Label worker pid mismatch (launched '$launchedPid', ran '$workerPid')"
    }
    return $null
}

$result = [ordered]@{
    is_elevated                       = $null
    trace_available                   = $null
    failure_errors                    = @()
    failure_completion_sources        = @()
    masked_process_tree               = @()
    success_exit_codes                = @()
    success_completion_sources        = @()
    install_windows_failure_error     = $null
    install_windows_failure_source    = $null
    install_windows_masked_tree       = @()
    install_windows_success_exit_code = $null
    install_windows_success_source    = $null
    worker_runs                       = 0
    job_created                       = $null
    process_table_count               = $null
    error                             = $null
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $result.is_elevated = [bool]$principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    Import-Module $RunnerModulePath -Force
    $runnerModule = Get-Module windows-installer-runner
    $pwshPath = (Get-Process -Id $PID).Path
    $scriptsDirectory = Split-Path -Parent $RunnerModulePath
    . (Join-Path $scriptsDirectory 'install-windows.ps1')

    $jobProbe = & $runnerModule { New-ProcessJob }
    $result.job_created = $null -ne $jobProbe
    & $runnerModule {
        param($job)
        Close-ProcessJob -ProcessJob $job
    } $jobProbe
    try {
        $result.process_table_count = @(& $runnerModule { Get-ProcessTable }).Count
    } catch {
        $result.process_table_count = "error: $($_.Exception.Message)"
    }

    if ($result.is_elevated) {
        $trace = & $runnerModule {
            param($phase)
            Start-ProcessTrace -Phase $phase
        } 'elevated-trace'
        try {
            $result.trace_available = $null -ne $trace
        } finally {
            & $runnerModule {
                param($processTrace)
                Stop-ProcessTrace -ProcessTrace $processTrace
            } $trace
        }
    } else {
        # A normal per-user install must not depend on elevation-only trace
        # registration; the shared runner tracks its workers with a job object.
        $result.trace_available = $false
    }

    New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
    # Keep transient files inside the dedicated directory whose ACL was opened
    # to the filtered token instead of the elevated runner's temp directory.
    $env:TEMP = $WorkDirectory
    $env:TMP = $WorkDirectory

    for ($run = 1; $run -le 5; $run++) {
        $pidFile = Join-Path $WorkDirectory "non-elevated-fail-$run.pid"
        $failure = & $runnerModule {
            param($executable, $fixture, $pidFile, $phase)
            function script:Register-CimIndicationEvent {
                throw 'simulated non-elevated trace registration failure'
            }
            try {
                try {
                    $bounded = Invoke-BoundedInstallerProcess -FilePath $executable -ArgumentList @(
                        '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                        '-WorkerScript', $fixture,
                        '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', '9',
                        '-BootstrapDelayMilliseconds', '0',
                        '-PidFile', $pidFile
                    ) -Phase $phase -TimeoutSeconds 15
                    return [pscustomobject]@{
                        Error            = 'the bootstrap worker failure was masked'
                        CompletionSource = [string]$bounded.CompletionSource
                        ProcessTree      = @($bounded.ProcessTree)
                    }
                } catch {
                    return [pscustomobject]@{
                        Error            = $_.Exception.Message
                        CompletionSource = $null
                        ProcessTree      = @()
                    }
                }
            } finally {
                Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
            }
        } $pwshPath $FixtureScript $pidFile "non-elevated-fail-$run"
        $result.failure_errors += $failure.Error
        if ($failure.CompletionSource) {
            $result.failure_completion_sources += $failure.CompletionSource
            $result.masked_process_tree = @($failure.ProcessTree)
        }
        $workerError = Get-WorkerStartError -PidFile $pidFile -Label "non-elevated-fail-$run"
        if ($workerError) { $result.failure_errors += $workerError }
        else { $result.worker_runs++ }
    }

    for ($run = 1; $run -le 3; $run++) {
        $pidFile = Join-Path $WorkDirectory "non-elevated-ok-$run.pid"
        $success = & $runnerModule {
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
                    return [pscustomobject]@{
                        ExitCode         = [int]$bounded.ExitCode
                        CompletionSource = [string]$bounded.CompletionSource
                    }
                } catch {
                    return [pscustomobject]@{
                        ExitCode         = "error: $($_.Exception.Message)"
                        CompletionSource = $null
                    }
                }
            } finally {
                Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
            }
        } $pwshPath $FixtureScript $pidFile "non-elevated-ok-$run"
        $result.success_exit_codes += $success.ExitCode
        if ($success.CompletionSource) {
            $result.success_completion_sources += $success.CompletionSource
        }
        $workerError = Get-WorkerStartError -PidFile $pidFile -Label "non-elevated-ok-$run"
        if ($workerError) { $result.success_exit_codes += "error: $workerError" }
        else { $result.worker_runs++ }
    }

    # Exercise the same user-install helper that scripts/install-windows.ps1
    # invokes, so the qualification covers the documented per-user entry point
    # rather than only the shared runner module.
    $installLogDirectory = Join-Path $WorkDirectory 'install-windows-logs'
    New-Item -ItemType Directory -Force -Path $installLogDirectory | Out-Null

    $installFailurePidFile = Join-Path $WorkDirectory 'install-windows-fail.pid'
    & $runnerModule {
        function script:Register-CimIndicationEvent {
            throw 'simulated non-elevated trace registration failure'
        }
    }
    try {
        try {
            $install = Invoke-NanoDictateInstaller -InstallerPath $pwshPath -Target $WorkDirectory `
                -ArgumentList @(
                    '-NoProfile', '-File', $FixtureScript, '-Mode', 'bootstrap',
                    '-WorkerScript', $FixtureScript,
                    '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', '9',
                    '-BootstrapDelayMilliseconds', '0',
                    '-PidFile', $installFailurePidFile
                ) -Phase 'non-elevated-install-windows-fail' -TimeoutSeconds 15 `
                -LogDirectory $installLogDirectory
            $result.install_windows_failure_error = 'the bootstrap worker failure was masked'
            $result.install_windows_failure_source = [string]$install.CompletionSource
            $result.install_windows_masked_tree = @($install.ProcessTree)
        } catch {
            $result.install_windows_failure_error = $_.Exception.Message
        }
    } finally {
        & $runnerModule {
            Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
        }
    }
    $workerError = Get-WorkerStartError -PidFile $installFailurePidFile `
        -Label 'non-elevated-install-windows-fail'
    if ($workerError) { $result.failure_errors += $workerError }
    else { $result.worker_runs++ }

    $installSuccessPidFile = Join-Path $WorkDirectory 'install-windows-ok.pid'
    & $runnerModule {
        function script:Register-CimIndicationEvent {
            throw 'simulated non-elevated trace registration failure'
        }
    }
    try {
        try {
            $install = Invoke-NanoDictateInstaller -InstallerPath $pwshPath -Target $WorkDirectory `
                -ArgumentList @(
                    '-NoProfile', '-File', $FixtureScript, '-Mode', 'bootstrap',
                    '-WorkerScript', $FixtureScript,
                    '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', '0',
                    '-BootstrapDelayMilliseconds', '0',
                    '-PidFile', $installSuccessPidFile
                ) -Phase 'non-elevated-install-windows-ok' -TimeoutSeconds 15 `
                -LogDirectory $installLogDirectory
            $result.install_windows_success_exit_code = [int]$install.ExitCode
            $result.install_windows_success_source = [string]$install.CompletionSource
        } catch {
            $result.install_windows_success_exit_code = "error: $($_.Exception.Message)"
        }
    } finally {
        & $runnerModule {
            Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
        }
    }
    $workerError = Get-WorkerStartError -PidFile $installSuccessPidFile `
        -Label 'non-elevated-install-windows-ok'
    if ($workerError) {
        $result.install_windows_success_exit_code = "error: $workerError"
    } else {
        $result.worker_runs++
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
if (@($result.failure_completion_sources | Where-Object { $_ -ne 'job' }).Count -ne 0) { exit 1 }
if (@($result.success_completion_sources).Count -ne 3) { exit 1 }
if (@($result.success_completion_sources | Where-Object { $_ -ne 'job' }).Count -ne 0) { exit 1 }
if ($result.install_windows_failure_error -notmatch 'exited with code 9') { exit 1 }
if ($result.install_windows_failure_source -and $result.install_windows_failure_source -ne 'job') { exit 1 }
if ($result.install_windows_success_exit_code -ne 0) { exit 1 }
if ($result.install_windows_success_source -ne 'job') { exit 1 }
if ($result.worker_runs -ne 10) { exit 1 }
exit 0
