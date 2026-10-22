#Requires -Version 7.0
<#
.SYNOPSIS
  Regression and contract tests for the shared bounded Windows installer runner.
.DESCRIPTION
  The runner must return when setup actually completes without waiting for the
  persistent NanoDictate background agent, must wait for an Inno-style bootstrap
  worker, must fail on nonzero installer/worker exit codes, and must time out
  and clean up stuck phases. Lifecycle assertion helpers are also verified for
  missing payloads and leftover registry/user-data states.

  The legacy Start-Process -Wait hang is demonstrated on Windows, where the
  documented whole-process-tree wait is observable. Other checks also run on
  Linux/macOS for local development.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:passed = 0
$script:failed = 0

function Pass([string]$Name) {
    $script:passed++
    Write-Host "ok - $Name"
}
function Fail([string]$Name, [string]$Detail) {
    $script:failed++
    Write-Host "not ok - $Name"
    Write-Host "  $Detail"
}
function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$MessagePattern = '') {
    try {
        & $Action | Out-Null
        Fail $Name 'expected an exception, but the call succeeded'
    } catch {
        if ($MessagePattern -and $_.Exception.Message -notmatch $MessagePattern) {
            Fail $Name "exception did not match '$MessagePattern': $($_.Exception.Message)"
        } else {
            Pass $Name
        }
    }
}
function Assert-Equal([string]$Name, $Expected, $Actual) {
    if ($Expected -eq $Actual) { Pass $Name }
    else { Fail $Name "expected '$Expected', got '$Actual'" }
}
function Assert-True([string]$Name, [bool]$Condition, [string]$Detail) {
    if ($Condition) { Pass $Name } else { Fail $Name $Detail }
}
function Get-ProcessByIdOrNull([int]$ProcessId) {
    try { return [Diagnostics.Process]::GetProcessById($ProcessId) } catch { return $null }
}
function Stop-ProcessByIdOrNull([int]$ProcessId) {
    $process = Get-ProcessByIdOrNull $ProcessId
    if ($null -ne $process) {
        try { $process.Kill() } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
        try { $process.Dispose() } catch { }
    }
}
function Invoke-NonElevatedInstallerFixture {
    param(
        [string]$Executable,
        [string]$FixtureScript,
        [string]$PidFile,
        [int]$WorkerExitCode,
        [string]$Phase
    )
    & $runnerModule {
        param($executable, $fixture, $pidFile, $workerExitCode, $phase)
        function script:Register-CimIndicationEvent {
            throw 'simulated non-elevated trace registration failure'
        }
        try {
            try {
                $result = Invoke-BoundedInstallerProcess -FilePath $executable -ArgumentList @(
                    '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                    '-WorkerScript', $fixture,
                    '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', [string]$workerExitCode,
                    '-BootstrapDelayMilliseconds', '0',
                    '-PidFile', $pidFile
                ) -Phase $phase -TimeoutSeconds 15
                return [pscustomobject]@{ ExitCode = $result.ExitCode; Error = $null }
            } catch {
                return [pscustomobject]@{ ExitCode = $null; Error = $_.Exception.Message }
            }
        } finally {
            Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
        }
    } $Executable $FixtureScript $PidFile $WorkerExitCode $Phase
}

$modulePath = Join-Path $PSScriptRoot 'windows-installer-runner.psm1'
$fixture = Join-Path $PSScriptRoot 'fixtures/installer-runner-fixture.ps1'
$legacyWait = Join-Path $PSScriptRoot 'fixtures/legacy-start-process-wait.ps1'
Import-Module $modulePath -Force

# Inno Setup strips quotes without backslash escaping, so the runner quotes
# whole arguments and never uses MSVCRT-style escaped quotes.
$runnerModule = Get-Module windows-installer-runner
$quoted = & $runnerModule {
    param($value)
    ConvertTo-InnoSetupCommandLineArgument $value
} '/DIR=C:\Users\A B\NanoDictate'
Assert-Equal 'Inno argument quoting wraps values containing spaces' '"/DIR=C:\Users\A B\NanoDictate"' $quoted
Assert-Throws 'installer arguments reject embedded quotes' {
    & $runnerModule {
        param($value)
        ConvertTo-InnoSetupCommandLineArgument $value
    } '/DIR="C:\Users\A B\NanoDictate"'
} 'must not contain quotes'

$durable = & $runnerModule {
    $tracked = @{
        100 = [pscustomobject]@{
            Id = 100; ParentId = 0; Name = 'setup'; Detached = $false
            Process = $null; ExitCode = $null; Ended = $false
        }
        200 = [pscustomobject]@{
            Id = 200; ParentId = 100; Name = 'setup'; Detached = $false
            Process = $null; ExitCode = 0; Ended = $true
        }
    }
    $events = @{
        200 = [pscustomobject]@{
            Id = 200; ParentId = 100; Name = 'setup'; ExitCode = 9; Ended = $true
        }
        300 = [pscustomobject]@{
            Id = 300; ParentId = 100; Name = 'setup'; ExitCode = 7; Ended = $true
        }
    }
    [void](Update-TrackedProcessEvents -Tracked $tracked -ProcessEvents $events `
        -DetachedProcessNames @())
    [pscustomobject]@{ Existing = $tracked[200]; New = $tracked[300] }
}
Assert-True 'durable completion events attach workers that never appeared in a snapshot' `
    ($null -ne $durable.New -and $durable.New.ParentId -eq 100 -and $durable.New.Ended) `
    "worker entry was $($durable.New)"
Assert-Equal 'durable completion events keep a late failure exit code' 7 $durable.New.ExitCode
Assert-Equal 'durable completion events override an unverified snapshot exit code' 9 $durable.Existing.ExitCode

$jobCompletion = & $runnerModule {
    $tracked = @{
        100 = [pscustomobject]@{
            Id = 100; ParentId = 0; Name = 'setup'; Detached = $false
            Process = $null; ExitCode = $null; Ended = $false
        }
    }
    $snapshot = [pscustomobject]@{
        Processes = @(
            [pscustomobject]@{ Id = 200; Name = 'setup'; Ended = $true; HasExitCode = $true; ExitCode = 9 }
            [pscustomobject]@{ Id = 300; Name = 'setup'; Ended = $true; HasExitCode = $false; ExitCode = 0 }
        )
        AccountingAvailable = $true
        TotalProcesses      = 3
        ActiveProcesses     = 0
        AccountingComplete  = $true
    }
    [void](Update-TrackedProcessJob -Tracked $tracked -DetachedProcessNames @() `
        -RootId 100 -Snapshot $snapshot)
    [pscustomobject]@{ Failed = $tracked[200]; Unknown = $tracked[300] }
}
Assert-Equal 'job completion records a worker exit between snapshots' 9 $jobCompletion.Failed.ExitCode
Assert-True 'job completion marks an exit-code-less worker ended' $jobCompletion.Unknown.Ended `
    'worker entry was not marked ended'
Assert-True 'job completion leaves an unverified exit code unknown' `
    ($null -eq $jobCompletion.Unknown.ExitCode) "exit code was '$($jobCompletion.Unknown.ExitCode)'"

$traceName = & $runnerModule {
    $events = @{}
    $trace = [pscustomobject]@{
        StartIdentifier = 'fake-trace-start'
        StopIdentifier  = 'fake-trace-stop'
    }
    $script:fakeTraceEvents = @{
        'fake-trace-start' = @()
        'fake-trace-stop'  = @([pscustomobject]@{
            EventIdentifier = 1
            SourceEventArgs = [pscustomobject]@{
                NewEvent = [pscustomobject]@{
                    ProcessID       = 200
                    ParentProcessID = 100
                    ProcessName     = 'NanoDictate-Set'
                    ExitStatus      = 9
                }
            }
        })
    }
    function script:Get-Event {
        param([string]$SourceIdentifier)
        if ($script:fakeTraceEvents.ContainsKey($SourceIdentifier)) {
            return $script:fakeTraceEvents[$SourceIdentifier]
        }
        return @()
    }
    try {
        [void](Read-ProcessTraceEvents -ProcessEvents $events -ProcessTrace $trace)
        $afterStop = [string]$events[200].Name
        $endedAfterStop = [bool]$events[200].Ended

        $script:fakeTraceEvents['fake-trace-stop'] = @()
        $script:fakeTraceEvents['fake-trace-start'] = @([pscustomobject]@{
            EventIdentifier = 2
            SourceEventArgs = [pscustomobject]@{
                NewEvent = [pscustomobject]@{
                    ProcessID       = 200
                    ParentProcessID = 100
                    ProcessName     = 'NanoDictate-Setup.tmp'
                }
            }
        })
        [void](Read-ProcessTraceEvents -ProcessEvents $events -ProcessTrace $trace)
        [pscustomobject]@{
            AfterStop      = $afterStop
            EndedAfterStop = $endedAfterStop
            AfterStart     = [string]$events[200].Name
            NameFromStart  = [bool]$events[200].NameFromStart
            ExitCode       = $events[200].ExitCode
        }
    } finally {
        Remove-Item -Path Function:Get-Event -ErrorAction SilentlyContinue
        Remove-Variable -Name fakeTraceEvents -Scope Script -ErrorAction SilentlyContinue
    }
}
Assert-Equal 'stop trace name is retained until a start trace is seen' `
    'NanoDictate-Set' $traceName.AfterStop
Assert-True 'stop trace still establishes completion' $traceName.EndedAfterStop `
    'stop event did not mark the process ended'
Assert-Equal 'start trace replaces a truncated stop-trace name' `
    'NanoDictate-Setup' $traceName.AfterStart
Assert-True 'start trace name is marked as authoritative' $traceName.NameFromStart `
    'start trace name was not retained'
Assert-Equal 'preferred start trace name preserves the stop exit code' 9 $traceName.ExitCode

$traceNamePropagation = & $runnerModule {
    $tracked = @{
        100 = [pscustomobject]@{
            Id = 100; ParentId = 0; Name = 'setup'; Detached = $false
            Process = $null; ExitCode = $null; Ended = $false
        }
        200 = [pscustomobject]@{
            Id = 200; ParentId = 100; Name = 'NanoDictate-Set'; Detached = $false
            Process = $null; ExitCode = $null; Ended = $true
        }
    }
    $events = @{
        200 = [pscustomobject]@{
            Id = 200; ParentId = 100; Name = 'NanoDictate-Setup'
            ExitCode = 9; Ended = $true
        }
    }
    [void](Update-TrackedProcessEvents -Tracked $tracked -ProcessEvents $events `
        -DetachedProcessNames @())
    $tracked[200]
}
Assert-Equal 'improved trace name propagates to an existing tracked worker' `
    'NanoDictate-Setup' $traceNamePropagation.Name
Assert-Equal 'propagated trace name keeps the worker failure exit code' `
    9 $traceNamePropagation.ExitCode

$unconfirmedStatus = & $runnerModule {
    ConvertFrom-ProcessTraceExitStatus ([uint32]::MaxValue)
}
$confirmedStatus = & $runnerModule {
    param($value)
    ConvertFrom-ProcessTraceExitStatus $value
} 9
Assert-True 'unconfirmed process trace status stays unknown and fails closed' `
    ($null -eq $unconfirmedStatus) "status was '$unconfirmedStatus'"
Assert-Equal 'confirmed process trace status keeps its exit code' 9 $confirmedStatus

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $tempRoot ('nd-runner-tests-' + [guid]::NewGuid().ToString('N'))
$logDir = Join-Path $work 'logs'
New-Item -ItemType Directory -Force -Path $work, $logDir | Out-Null
$pwshPath = (Get-Process -Id $PID).Path
$spawnedPids = [Collections.Generic.List[int]]::new()

try {
    # 1. Slow but successful installer.
    $slow = Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile', '-File', $fixture, '-Mode', 'sleep', '-SleepMilliseconds', '1500'
    ) -Phase 'slow-install' -TimeoutSeconds 15 -LogDirectory $logDir
    Assert-Equal 'slow installer returns root exit code' 0 $slow.ExitCode
    Assert-True 'slow installer measures actual completion' ($slow.ElapsedSeconds -ge 1) "elapsed was $($slow.ElapsedSeconds)s"
    $slowRoot = @($slow.ProcessTree | Where-Object { $_.pid -eq $slow.ProcessId })[0]
    Assert-Equal 'root tracked process records its trusted exit code' 0 $slowRoot.exit_code
    Assert-True 'successful phase writes evidence' (Test-Path -LiteralPath (Join-Path $logDir 'slow-install.json')) 'missing slow-install evidence'

    # 1b. Inno /LOG requests are passed through and recorded in evidence.
    $innoPhase = 'slow-inno'
    Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile', '-File', $fixture, '-Mode', 'sleep', '-SleepMilliseconds', '300'
    ) -Phase $innoPhase -TimeoutSeconds 15 -LogDirectory $logDir `
        -InnoLogFileName "$innoPhase.log" | Out-Null
    $innoEvidence = Get-Content -LiteralPath (Join-Path $logDir "$innoPhase.json") -Raw | ConvertFrom-Json
    Assert-Equal 'Inno log name is recorded in phase evidence' "$innoPhase.log" $innoEvidence.inno_log

    # 2. Nonzero installer error is not masked.
    Assert-Throws 'nonzero installer exit fails the phase' {
        Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
            '-NoProfile', '-File', $fixture, '-Mode', 'sleep', '-ExitCode', '7'
        ) -Phase 'nonzero-install' -TimeoutSeconds 15 -LogDirectory $logDir
    } 'exited with code 7'

    # 3. A stuck installer is bounded, killed, and reported.
    $stuckPidFile = Join-Path $work 'stuck.pid'
    $stuckTimer = [Diagnostics.Stopwatch]::StartNew()
    Assert-Throws 'stuck installer times out' {
        Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
            '-NoProfile', '-File', $fixture, '-Mode', 'sleep', '-SleepMilliseconds', '60000',
            '-PidFile', $stuckPidFile
        ) -Phase 'stuck-install' -TimeoutSeconds 2 -LogDirectory $logDir
    } 'timed out'
    $stuckTimer.Stop()
    Assert-True 'stuck installer fails before the job timeout' ($stuckTimer.Elapsed.TotalSeconds -lt 15) "took $($stuckTimer.Elapsed.TotalSeconds)s"
    if (Test-Path -LiteralPath $stuckPidFile) {
        Start-Sleep -Milliseconds 500
        $stuckPid = [int](Get-Content -LiteralPath $stuckPidFile -Raw)
        Assert-True 'timeout terminates the owned installer process' ($null -eq (Get-ProcessByIdOrNull $stuckPid)) "pid $stuckPid is still running"
    } else {
        Fail 'timeout terminates the owned installer process' 'fixture did not report its pid'
    }

    # 4. A short-lived bootstrap root must not be mistaken for completion.
    $bootstrapPidFile = Join-Path $work 'bootstrap.pid'
    $bootstrapTimer = [Diagnostics.Stopwatch]::StartNew()
    $bootstrap = Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
        '-WorkerScript', $fixture,
        '-WorkerSleepMilliseconds', '2000', '-WorkerExitCode', '0',
        '-PidFile', $bootstrapPidFile
    ) -Phase 'bootstrap-install' -TimeoutSeconds 15 -LogDirectory $logDir
    $bootstrapTimer.Stop()
    Assert-Equal 'bootstrap worker exit code is reported' 0 $bootstrap.ExitCode
    Assert-True 'bootstrap waits for the installer worker' ($bootstrapTimer.Elapsed.TotalSeconds -ge 1.5) "returned after $($bootstrapTimer.Elapsed.TotalSeconds)s"
    if (Test-Path -LiteralPath $bootstrapPidFile) {
        $workerPid = [int](Get-Content -LiteralPath $bootstrapPidFile -Raw)
        Assert-True 'bootstrap worker has exited after success' ($null -eq (Get-ProcessByIdOrNull $workerPid)) "pid $workerPid is still running"
    }

    # 5. A failing bootstrap worker is not masked by a successful root. .NET can
    # read a non-child exit code on Windows; Unix reaps the orphan itself, so the
    # assertion is Windows-only while the fixture remains shared.
    if ($IsWindows) {
        $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        $trace = & $runnerModule {
            param($phase)
            Start-ProcessTrace -Phase $phase
        } 'trace-availability'
        try {
            if ($isElevated) {
                Assert-True 'durable process trace events are available' ($null -ne $trace) 'Register-CimIndicationEvent failed'
            } else {
                Write-Host 'skip - durable process trace events require an elevated session'
            }
        } finally {
            & $runnerModule {
                param($processTrace)
                Stop-ProcessTrace -ProcessTrace $processTrace
            } $trace
        }

        # A non-elevated user session cannot register Win32 process trace
        # events. The job object must still track zero-delay bootstrap workers
        # and preserve their exit status for the normal per-user install path.
        for ($run = 1; $run -le 5; $run++) {
            $nonElevatedFailure = Invoke-NonElevatedInstallerFixture `
                -Executable $pwshPath -FixtureScript $fixture `
                -PidFile (Join-Path $work "non-elevated-fail-$run.pid") `
                -WorkerExitCode 9 -Phase "user-install-fail-$run"
            Assert-True "non-elevated user-install fails on a zero-delay failing worker (run $run)" `
                ($nonElevatedFailure.Error -match 'exited with code 9') `
                "job fallback did not preserve the worker failure: $($nonElevatedFailure.Error)"
        }

        for ($run = 1; $run -le 3; $run++) {
            $nonElevatedSuccess = Invoke-NonElevatedInstallerFixture `
                -Executable $pwshPath -FixtureScript $fixture `
                -PidFile (Join-Path $work "non-elevated-ok-$run.pid") `
                -WorkerExitCode 0 -Phase "user-install-ok-$run"
            Assert-Equal "non-elevated user-install completes with a zero-delay worker (run $run)" `
                0 $nonElevatedSuccess.ExitCode
        }

        $untrackedMessage = & $runnerModule {
            param($executable)
            function script:Register-CimIndicationEvent {
                throw 'simulated trace registration failure'
            }
            function script:New-ProcessJob {
                return $null
            }
            try {
                Invoke-BoundedInstallerProcess -FilePath $executable -ArgumentList @(
                    '-NoProfile', '-Command', 'exit 0'
                ) -Phase 'user-install' -TimeoutSeconds 5 | Out-Null
                return $null
            } catch {
                return $_.Exception.Message
            } finally {
                Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
                Remove-Item -Path Function:New-ProcessJob -ErrorAction SilentlyContinue
            }
        } $pwshPath
        Assert-True 'missing trace and job tracking fails closed' `
            ($untrackedMessage -match 'no reliable non-elevated process completion source') `
            "runner did not fail closed: $untrackedMessage"

        $failingWorkerPidFile = Join-Path $work 'bootstrap-fail.pid'
        Assert-Throws 'failing bootstrap worker fails the phase' {
            Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
                '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                '-WorkerScript', $fixture,
                '-WorkerSleepMilliseconds', '2000', '-WorkerExitCode', '9',
                '-PidFile', $failingWorkerPidFile
            ) -Phase 'bootstrap-failure' -TimeoutSeconds 15 -LogDirectory $logDir
        } 'exited with code 9'

        # .NET reports exit code 0 when it only opens a process handle after the
        # process has already exited. Verify the runner's durable handle keeps
        # the real code even when the process is observed by PID first.
        $handleStartInfo = [Diagnostics.ProcessStartInfo]::new()
        $handleStartInfo.FileName = $pwshPath
        $handleStartInfo.UseShellExecute = $false
        $handleStartInfo.CreateNoWindow = $true
        $handleStartInfo.Arguments = (@(
            '-NoProfile', '-File', $fixture, '-Mode', 'sleep',
            '-SleepMilliseconds', '2000', '-ExitCode', '9'
        ) | ForEach-Object {
            & $runnerModule { param($value) ConvertTo-InnoSetupCommandLineArgument $value } $_
        }) -join ' '
        $handleStarter = [Diagnostics.Process]::Start($handleStartInfo)
        try {
            $handleObserved = & $runnerModule {
                param($process)
                Open-TrackedProcess $process
            } ([Diagnostics.Process]::GetProcessById($handleStarter.Id))
            try {
                Assert-True 'tracked process handle is opened before exit' ($null -ne $handleObserved) 'could not open a durable process handle'
                if ($null -ne $handleObserved) {
                    Assert-True -Name 'tracked process records a cached handle' `
                        -Condition ([bool]$handleObserved.HandleCached) `
                        -Detail 'HandleCached was not set'
                    [void]$handleObserved.WaitForExit(10000)
                    Assert-Equal 'durable process handle preserves a short-lived exit code' 9 $handleObserved.ExitCode
                }
            } finally {
                if ($null -ne $handleObserved) { $handleObserved.Dispose() }
            }
        } finally {
            try { if (-not $handleStarter.HasExited) { $handleStarter.Kill() } } catch { }
            try { $handleStarter.Dispose() } catch { }
        }

        # An exit code is only trustworthy when the handle was cached while the
        # process was alive. Without that evidence .NET can report a false zero.
        $uncachedTracked = & $runnerModule {
            $process = [pscustomobject]@{
                HasExited = $true
                ExitCode = 9
                HandleCached = $false
            }
            $tracked = @{
                999999 = [pscustomobject]@{
                    Id = 999999; ParentId = 0; Name = 'setup'; Detached = $false
                    Process = $process; ExitCode = $null; Ended = $false
                }
            }
            Update-TrackedProcesses -Tracked $tracked -DetachedProcessNames @()
            $endedAfterUncached = [bool]$tracked[999999].Ended
            $exitAfterUncached = $tracked[999999].ExitCode

            $process.HandleCached = $true
            Update-TrackedProcesses -Tracked $tracked -DetachedProcessNames @()
            [pscustomobject]@{
                Ended = $endedAfterUncached
                UncachedExitCode = $exitAfterUncached
                CachedExitCode = $tracked[999999].ExitCode
            }
        }
        Assert-True 'uncached process completion still marks the entry ended' `
            $uncachedTracked.Ended 'entry was not marked ended'
        Assert-True 'uncached process exit code stays unknown' `
            ($null -eq $uncachedTracked.UncachedExitCode) "exit code was '$($uncachedTracked.UncachedExitCode)'"
        Assert-Equal 'cached process exit code is trusted' 9 $uncachedTracked.CachedExitCode

        # A process whose handle cannot be opened must stay tracked. Marking it
        # ended would let a still-running worker escape the wait and fail-closed
        # checks because completion must come from HasExited or a stop event.
        $unavailableStartInfo = [Diagnostics.ProcessStartInfo]::new()
        $unavailableStartInfo.FileName = $pwshPath
        $unavailableStartInfo.UseShellExecute = $false
        $unavailableStartInfo.CreateNoWindow = $true
        $unavailableStartInfo.Arguments = (@(
            '-NoProfile', '-File', $fixture, '-Mode', 'sleep', '-SleepMilliseconds', '5000'
        ) | ForEach-Object {
            & $runnerModule { param($value) ConvertTo-InnoSetupCommandLineArgument $value } $_
        }) -join ' '
        $unavailableStarter = [Diagnostics.Process]::Start($unavailableStartInfo)
        $unavailableProcess = $null
        try {
            $unavailableProcess = [Diagnostics.Process]::GetProcessById($unavailableStarter.Id)
            $unavailableProcess.Dispose()
            $preservedProcess = & $runnerModule {
                param($process)
                Open-TrackedProcess $process
            } $unavailableProcess
            Assert-True 'unavailable process handle is not discarded' `
                ($null -ne $preservedProcess) 'Open-TrackedProcess returned null'

            $unavailableTracked = & $runnerModule {
                param($process)
                $tracked = @{
                    65535 = [pscustomobject]@{
                        Id = 65535; ParentId = 0; Name = 'setup'; Detached = $false
                        Process = $process; ExitCode = $null; Ended = $false
                    }
                }
                Update-TrackedProcesses -Tracked $tracked -DetachedProcessNames @()
                $tracked[65535]
            } $unavailableProcess
            Assert-True 'unavailable HasExited check does not mark an entry ended' `
                (-not $unavailableTracked.Ended) 'entry was marked ended without completion evidence'
        } finally {
            try { if (-not $unavailableStarter.HasExited) { $unavailableStarter.Kill() } } catch { }
            try { $unavailableStarter.Dispose() } catch { }
            if ($null -ne $unavailableProcess) {
                try { $unavailableProcess.Dispose() } catch { }
            }
        }

        for ($run = 1; $run -le 5; $run++) {
            Assert-Throws "short-lived failing bootstrap worker fails the phase (run $run)" {
                Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
                    '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                    '-WorkerScript', $fixture,
                    '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', '9',
                    '-BootstrapDelayMilliseconds', '0',
                    '-PidFile', (Join-Path $work "bootstrap-fast-fail-$run.pid")
                ) -Phase "bootstrap-fast-fail-$run" -TimeoutSeconds 15 -LogDirectory $logDir
            } 'exited with code 9'
        }

        for ($run = 1; $run -le 3; $run++) {
            $fastSuccess = Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
                '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                '-WorkerScript', $fixture,
                '-WorkerSleepMilliseconds', '0', '-WorkerExitCode', '0',
                '-BootstrapDelayMilliseconds', '0',
                '-PidFile', (Join-Path $work "bootstrap-fast-ok-$run.pid")
            ) -Phase "bootstrap-fast-ok-$run" -TimeoutSeconds 15 -LogDirectory $logDir
            Assert-Equal "short-lived successful bootstrap worker succeeds (run $run)" 0 $fastSuccess.ExitCode
        }
    } else {
        Write-Host 'skip - bootstrap worker exit-code propagation is Windows-only'
    }

    # 6. A stuck bootstrap worker is bounded even though the root already exited.
    $stuckWorkerPidFile = Join-Path $work 'bootstrap-stuck.pid'
    $stuckWorkerTimer = [Diagnostics.Stopwatch]::StartNew()
    Assert-Throws 'stuck bootstrap worker times out' {
        Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
            '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
            '-WorkerScript', $fixture,
            '-WorkerSleepMilliseconds', '60000',
            '-PidFile', $stuckWorkerPidFile
        ) -Phase 'bootstrap-stuck' -TimeoutSeconds 2 -LogDirectory $logDir
    } 'timed out'
    $stuckWorkerTimer.Stop()
    Assert-True 'stuck bootstrap worker fails before the job timeout' ($stuckWorkerTimer.Elapsed.TotalSeconds -lt 15) "took $($stuckWorkerTimer.Elapsed.TotalSeconds)s"
    if (Test-Path -LiteralPath $stuckWorkerPidFile) {
        Start-Sleep -Milliseconds 500
        $stuckWorkerPid = [int](Get-Content -LiteralPath $stuckWorkerPidFile -Raw)
        Assert-True 'timeout terminates the owned bootstrap worker' ($null -eq (Get-ProcessByIdOrNull $stuckWorkerPid)) "pid $stuckWorkerPid is still running"
    }

    # 7. The corrected runner returns while a persistent detached child lives.
    $detachedPidFile = Join-Path $work 'detached.pid'
    $detachedTimer = [Diagnostics.Stopwatch]::StartNew()
    $detached = Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile', '-File', $fixture, '-Mode', 'detached', '-PidFile', $detachedPidFile
    ) -Phase 'detached-child' -TimeoutSeconds 15 -LogDirectory $logDir
    $detachedTimer.Stop()
    Assert-Equal 'runner succeeds when setup leaves a persistent child' 0 $detached.ExitCode
    Assert-True 'runner does not wait for the persistent child' ($detachedTimer.Elapsed.TotalSeconds -lt 15) "returned after $($detachedTimer.Elapsed.TotalSeconds)s"
    if (Test-Path -LiteralPath $detachedPidFile) {
        $detachedPid = [int](Get-Content -LiteralPath $detachedPidFile -Raw)
        $spawnedPids.Add($detachedPid)
        Assert-True 'persistent child is still running after runner success' ($null -ne (Get-ProcessByIdOrNull $detachedPid)) "pid $detachedPid exited"
    } else {
        Fail 'persistent child is still running after runner success' 'fixture did not report its child pid'
    }

    # 8. Demonstrate the legacy Start-Process -Wait hang on Windows.
    if ($IsWindows) {
        $legacyPidFile = Join-Path $work 'legacy-detached.pid'
        $legacyController = Start-Process -FilePath $pwshPath -ArgumentList @(
            '-NoProfile', '-File', $legacyWait,
            '-Fixture', $fixture, '-Mode', 'detached', '-PidFile', $legacyPidFile
        ) -PassThru
        Start-Sleep -Seconds 4
        $legacyController.Refresh()
        Assert-True 'Start-Process -Wait remains blocked by the persistent child' (-not $legacyController.HasExited) 'legacy wait exited even though the persistent child is alive'
        if (Test-Path -LiteralPath $legacyPidFile) {
            $legacyPid = [int](Get-Content -LiteralPath $legacyPidFile -Raw)
            $spawnedPids.Add($legacyPid)
        }
        Stop-ProcessByIdOrNull $legacyController.Id
    } else {
        Write-Host 'skip - legacy Start-Process -Wait hang observation is Windows-only'
    }

    # 9. Lifecycle assertion helpers detect missing payloads.
    $payloadDir = Join-Path $work 'payload'
    New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
    $payloadNames = @('NanoDictate.App.exe', 'NanoDictate.App.dll', 'NanoDictate.App.runtimeconfig.json',
        'nanodictate_core.dll', 'coreclr.dll', 'hostfxr.dll', 'config.example.toml')
    foreach ($name in $payloadNames) {
        Set-Content -LiteralPath (Join-Path $payloadDir $name) -Value 'fixture' -NoNewline
    }
    try {
        Assert-NanoDictatePayload -InstallDirectory $payloadDir
        Pass 'complete payload passes validation'
    } catch {
        Fail 'complete payload passes validation' $_.Exception.Message
    }
    Remove-Item -LiteralPath (Join-Path $payloadDir 'coreclr.dll') -Force
    Assert-Throws 'missing payload file is rejected' {
        Assert-NanoDictatePayload -InstallDirectory $payloadDir
    } 'missing coreclr.dll'
    Assert-Throws 'missing install directory is rejected' {
        Assert-NanoDictatePayload -InstallDirectory (Join-Path $work 'absent')
    } 'missing NanoDictate.App.exe'

    # 10. User-data preservation detects deletion and mutation.
    $marker = Join-Path $work 'user-config.txt'
    Set-Content -LiteralPath $marker -Value 'preserve' -NoNewline
    try {
        Assert-NanoDictateUserDataPreserved -Path $marker
        Pass 'preserved user data passes validation'
    } catch {
        Fail 'preserved user data passes validation' $_.Exception.Message
    }
    Set-Content -LiteralPath $marker -Value 'changed' -NoNewline
    Assert-Throws 'changed user data is rejected' {
        Assert-NanoDictateUserDataPreserved -Path $marker
    } 'changed user data'
    Remove-Item -LiteralPath $marker -Force
    Assert-Throws 'deleted user data is rejected' {
        Assert-NanoDictateUserDataPreserved -Path $marker
    } 'deleted user data'

    # 11. Startup registration helpers detect a wrong or leftover value.
    if ($IsWindows) {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $previous = Get-NanoDictateStartupValue
        try {
            $fakeInstall = Join-Path $work 'fake-install'
            New-Item -ItemType Directory -Force -Path $fakeInstall | Out-Null
            Set-Content -LiteralPath (Join-Path $fakeInstall 'NanoDictate.App.exe') -Value 'fixture' -NoNewline
            $expected = '"' + (Join-Path $fakeInstall 'NanoDictate.App.exe') + '" --background'
            New-Item -Path $runKey -Force | Out-Null
            Set-ItemProperty -Path $runKey -Name 'NanoDictate' -Value $expected
            try {
                Assert-NanoDictateStartup -InstallDirectory $fakeInstall
                Pass 'stable startup registration passes validation'
            } catch {
                Fail 'stable startup registration passes validation' $_.Exception.Message
            }
            Set-ItemProperty -Path $runKey -Name 'NanoDictate' -Value '"C:\wrong\NanoDictate.App.exe" --background'
            Assert-Throws 'wrong startup path is rejected' {
                Assert-NanoDictateStartup -InstallDirectory $fakeInstall
            } 'instead of the stable installed path'
            Remove-ItemProperty -Path $runKey -Name 'NanoDictate' -Force
            Assert-Throws 'missing startup registration is rejected' {
                Assert-NanoDictateStartup -InstallDirectory $fakeInstall
            } 'instead of the stable installed path'
            try {
                Assert-NanoDictateStartupCleared
                Pass 'cleared startup registration passes validation'
            } catch {
                Fail 'cleared startup registration passes validation' $_.Exception.Message
            }
            Set-ItemProperty -Path $runKey -Name 'NanoDictate' -Value $expected
            Assert-Throws 'leftover startup registration is rejected' {
                Assert-NanoDictateStartupCleared
            } 'orphaned logon startup entry'
        } finally {
            if ($previous) {
                New-Item -Path $runKey -Force | Out-Null
                Set-ItemProperty -Path $runKey -Name 'NanoDictate' -Value $previous
            } else {
                Remove-ItemProperty -Path $runKey -Name 'NanoDictate' -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host 'skip - HKCU startup registration checks are Windows-only'
    }
} finally {
    foreach ($processId in $spawnedPids) { Stop-ProcessByIdOrNull $processId }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
