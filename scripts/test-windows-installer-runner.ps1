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

$modulePath = Join-Path $PSScriptRoot 'windows-installer-runner.psm1'
$fixture = Join-Path $PSScriptRoot 'fixtures/installer-runner-fixture.ps1'
$legacyWait = Join-Path $PSScriptRoot 'fixtures/legacy-start-process-wait.ps1'
Import-Module $modulePath -Force

# Windows PowerShell 5.1 lacks ProcessStartInfo.ArgumentList; keep the
# fallback command-line quoting covered even when tests run on PowerShell 7.
$runnerModule = Get-Module windows-installer-runner
$quoted = & $runnerModule {
    param($value)
    ConvertTo-WindowsCommandLineArgument $value
} '/DIR="C:\Users\A B\NanoDictate"'
Assert-Equal 'fallback argument quoting preserves /DIR quoting' '"/DIR=\"C:\Users\A B\NanoDictate\""' $quoted

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
        $failingWorkerPidFile = Join-Path $work 'bootstrap-fail.pid'
        Assert-Throws 'failing bootstrap worker fails the phase' {
            Invoke-BoundedInstallerProcess -FilePath $pwshPath -ArgumentList @(
                '-NoProfile', '-File', $fixture, '-Mode', 'bootstrap',
                '-WorkerScript', $fixture,
                '-WorkerSleepMilliseconds', '2000', '-WorkerExitCode', '9',
                '-PidFile', $failingWorkerPidFile
            ) -Phase 'bootstrap-failure' -TimeoutSeconds 15 -LogDirectory $logDir
        } 'exited with code 9'
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
