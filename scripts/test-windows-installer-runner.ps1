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
$nonElevatedLauncherSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace NanoDictate.InstallerRunner.Tests
{
    public static class NonElevatedProcess
    {
        private const uint TokenAssignPrimary = 0x0001;
        private const uint TokenQuery = 0x0008;
        private const uint TokenDuplicate = 0x0002;
        private const uint DisableMaxPrivilege = 0x0001;
        private const uint CreateNewConsole = 0x00000010;
        private const uint CreateNoWindow = 0x08000000;
        private const uint WaitObject0 = 0;
        private const int ErrorDllInitFailed = 1114;
        private const int StatusDllInitFailed = unchecked((int)0xC0000142);

        [StructLayout(LayoutKind.Sequential)]
        private struct SidAndAttributes
        {
            public IntPtr Sid;
            public uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(
            IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool ConvertStringSidToSid(string stringSid, out IntPtr sid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool CreateRestrictedToken(
            IntPtr existingTokenHandle,
            uint flags,
            uint disableSidCount,
            SidAndAttributes[] sidsToDisable,
            uint deletePrivilegeCount,
            IntPtr privilegesToDelete,
            uint restrictedSidCount,
            IntPtr sidsToRestrict,
            out IntPtr newTokenHandle);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessAsUser(
            IntPtr token,
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfo startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr memory);

        private static string Quote(string value)
        {
            if (value.Length == 0) { return "\"\""; }
            if (value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) { return value; }

            StringBuilder result = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                }
                else if (character == '"')
                {
                    result.Append('\\', (backslashes * 2) + 1);
                    result.Append('"');
                    backslashes = 0;
                }
                else
                {
                    result.Append('\\', backslashes);
                    result.Append(character);
                    backslashes = 0;
                }
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static int StartAndWait(
            IntPtr token,
            string application,
            string commandLine,
            string workingDirectory,
            uint creationFlags,
            string desktop,
            int timeoutMilliseconds)
        {
            ProcessInformation processInformation = new ProcessInformation();
            try
            {
                StartupInfo startupInfo = new StartupInfo();
                startupInfo.cb = Marshal.SizeOf(typeof(StartupInfo));
                startupInfo.lpDesktop = desktop;
                StringBuilder mutableCommandLine = new StringBuilder(commandLine);
                if (!CreateProcessAsUser(token, application, mutableCommandLine, IntPtr.Zero,
                    IntPtr.Zero, false, creationFlags, IntPtr.Zero, workingDirectory,
                    ref startupInfo, out processInformation))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "Could not start the non-elevated process.");
                }

                uint waitResult = WaitForSingleObject(
                    processInformation.hProcess, (uint)timeoutMilliseconds);
                if (waitResult != WaitObject0)
                {
                    TerminateProcess(processInformation.hProcess, 1);
                    throw new TimeoutException(
                        "The non-elevated process did not exit within the timeout.");
                }

                uint exitCode;
                if (!GetExitCodeProcess(processInformation.hProcess, out exitCode))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Could not read the non-elevated process exit code.");
                }
                return unchecked((int)exitCode);
            }
            finally
            {
                if (processInformation.hThread != IntPtr.Zero) {
                    CloseHandle(processInformation.hThread);
                }
                if (processInformation.hProcess != IntPtr.Zero) {
                    CloseHandle(processInformation.hProcess);
                }
            }
        }

        public static int Run(
            string application,
            string[] arguments,
            string workingDirectory,
            int timeoutMilliseconds)
        {
            IntPtr token = IntPtr.Zero;
            IntPtr restrictedToken = IntPtr.Zero;
            IntPtr administratorsSid = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(),
                    TokenAssignPrimary | TokenQuery | TokenDuplicate, out token))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "Could not open the current process token.");
                }
                if (!ConvertStringSidToSid("S-1-5-32-544", out administratorsSid))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "Could not resolve the Administrators SID.");
                }

                SidAndAttributes[] disabledSids = new SidAndAttributes[1];
                disabledSids[0].Sid = administratorsSid;
                if (!CreateRestrictedToken(token, DisableMaxPrivilege, 1, disabledSids, 0, IntPtr.Zero,
                    0, IntPtr.Zero, out restrictedToken))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "Could not create a non-elevated token.");
                }

                StringBuilder commandLine = new StringBuilder();
                commandLine.Append(Quote(application));
                foreach (string argument in arguments)
                {
                    commandLine.Append(' ');
                    commandLine.Append(Quote(argument));
                }

                uint[] creationFlags = new uint[]
                {
                    CreateNewConsole,
                    0,
                    CreateNewConsole,
                    CreateNoWindow
                };
                string[] desktops = new string[]
                {
                    null,
                    null,
                    "winsta0\\default",
                    null
                };

                int exitCode = StatusDllInitFailed;
                for (int attempt = 0; attempt < creationFlags.Length; attempt++)
                {
                    try
                    {
                        exitCode = StartAndWait(restrictedToken, application, commandLine.ToString(),
                            workingDirectory, creationFlags[attempt], desktops[attempt],
                            timeoutMilliseconds);
                    }
                    catch (Win32Exception exception)
                    {
                        if (exception.NativeErrorCode != ErrorDllInitFailed) { throw; }
                        exitCode = StatusDllInitFailed;
                    }
                    if (exitCode != StatusDllInitFailed) { return exitCode; }
                }
                return exitCode;
            }
            finally
            {
                if (restrictedToken != IntPtr.Zero) { CloseHandle(restrictedToken); }
                if (token != IntPtr.Zero) { CloseHandle(token); }
                if (administratorsSid != IntPtr.Zero) { LocalFree(administratorsSid); }
            }
        }
    }
}
'@

function Grant-NonElevatedWorkDirectoryAccess {
    param([string]$Path)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    # The restricted token disables the Administrators group. Hosted runner
    # temp directories can grant access only through that group, so give the
    # filtered child's remaining user identity explicit access to its scratch
    # files instead of relying on inherited elevation.
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $user,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-NonElevatedInstallerChild {
    param(
        [string]$Executable,
        [string]$FixtureScript,
        [string]$ResultPath,
        [string]$WorkDirectory
    )
    if (-not ('NanoDictate.InstallerRunner.Tests.NonElevatedProcess' -as [type])) {
        Add-Type -TypeDefinition $nonElevatedLauncherSource -Language CSharp -ErrorAction Stop
    }
    Grant-NonElevatedWorkDirectoryAccess -Path $WorkDirectory
    $childScript = Join-Path $PSScriptRoot 'fixtures/non-elevated-user-install.ps1'
    $modulePath = Join-Path $PSScriptRoot 'windows-installer-runner.psm1'
    $arguments = [string[]]@(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $childScript,
        '-RunnerModulePath', $modulePath,
        '-FixtureScript', $FixtureScript,
        '-ResultPath', $ResultPath,
        '-WorkDirectory', $WorkDirectory
    )
    $executables = @($Executable)
    $windowsPowerShell = [IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    if ((Test-Path -LiteralPath $windowsPowerShell) -and
        ([IO.Path]::GetFullPath($windowsPowerShell) -ne [IO.Path]::GetFullPath($Executable))) {
        $executables += $windowsPowerShell
    }
    $exitCode = $null
    foreach ($candidate in $executables) {
        Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
        $exitCode = [NanoDictate.InstallerRunner.Tests.NonElevatedProcess]::Run(
            $candidate, $arguments, $WorkDirectory, 240000)
        if (Test-Path -LiteralPath $ResultPath) {
            $result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
            return [pscustomobject]@{ ExitCode = $exitCode; Result = $result }
        }
        # Hosted runners have UAC disabled, so the restricted process can fail
        # before PowerShell starts. Retry with Windows PowerShell, which has a
        # smaller .NET startup surface, before reporting the launch failure.
        if ($exitCode -ne -1073741502) { break }
    }
    throw "The non-elevated installer fixture exited with code $exitCode without writing a result."
}

function Invoke-NonElevatedInstallerFixture {
    param(
        [string]$Executable,
        [string]$FixtureScript,
        [string]$PidFile,
        [int]$WorkerExitCode,
        [string]$Phase,
        [bool]$SimulateTraceFailure = $true
    )
    & $runnerModule {
        param($executable, $fixture, $pidFile, $workerExitCode, $phase, $simulateTraceFailure)
        if ($simulateTraceFailure) {
            function script:Register-CimIndicationEvent {
                throw 'simulated non-elevated trace registration failure'
            }
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
            if ($simulateTraceFailure) {
                Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
            }
        }
    } $Executable $FixtureScript $PidFile $WorkerExitCode $Phase $SimulateTraceFailure
}

$modulePath = Join-Path $PSScriptRoot 'windows-installer-runner.psm1'
$fixture = Join-Path $PSScriptRoot 'fixtures/installer-runner-fixture.ps1'
$legacyWait = Join-Path $PSScriptRoot 'fixtures/legacy-start-process-wait.ps1'
Import-Module $modulePath -Force

# Inno Setup strips quotes without backslash escaping, so the runner quotes
# whole arguments and never uses MSVCRT-style escaped quotes.
$runnerModule = Get-Module windows-installer-runner
$processTableType = & $runnerModule {
    if (-not ('NanoDictate.InstallerRunner.ProcessTable' -as [type])) {
        Add-Type -TypeDefinition $script:ProcessJobSource -Language CSharp -ErrorAction Stop
    }
    [NanoDictate.InstallerRunner.ProcessTable].FullName
}
Assert-Equal 'native process table source compiles' 'NanoDictate.InstallerRunner.ProcessTable' $processTableType
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
    if ($IsWindows) {
        # The job process-id list is pointer-sized on 64-bit Windows. Enumerate
        # a live root so a bad layout cannot silently disable job snapshots.
        $jobIds = & $runnerModule {
            param($executable)
            $job = New-ProcessJob
            if ($null -eq $job) { return $null }
            try {
                $suspended = $null
                try {
                    $suspended = $job.StartSuspended(
                        $executable,
                        '"' + $executable + '" -NoProfile -Command "Start-Sleep -Milliseconds 1500"',
                        $null)
                    $suspended.Resume()
                    Start-Sleep -Milliseconds 300
                    return [pscustomobject]@{
                        Root = [int]$suspended.ProcessId
                        Ids  = @($job.GetProcessIds() | ForEach-Object { [int]$_ })
                    }
                } finally {
                    if ($null -ne $suspended) { $suspended.Dispose() }
                }
            } finally {
                Close-ProcessJob -ProcessJob $job
            }
        } $pwshPath
        if ($null -eq $jobIds) {
            Fail 'job process id enumeration includes the live root' 'job tracking was unavailable'
        } else {
            Assert-True 'job process id enumeration includes the live root' `
                (@($jobIds.Ids) -contains [int]$jobIds.Root) `
                "root=$($jobIds.Root); ids=$($jobIds.Ids -join ',')"
        }
    }

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
                Write-Host ("non-elevated session: durable process trace available={0}" -f ($null -ne $trace))
            }
        } finally {
            & $runnerModule {
                param($processTrace)
                Stop-ProcessTrace -ProcessTrace $processTrace
            } $trace
        }

        # A non-elevated user session cannot normally register Win32 process
        # trace events. When the suite itself runs in a non-elevated session,
        # exercise the job fallback with that real token. Hosted CI runs
        # elevated, so force the same trace-registration failure there; the job
        # fallback itself does not use elevation. Either way it must track
        # zero-delay bootstrap workers and preserve their exit status for the
        # normal per-user install path.
        $simulateTraceFailure = $isElevated -or ($null -ne $trace)
        if (-not $simulateTraceFailure) {
            Write-Host 'using the actual non-elevated process token for job-fallback tests'
        }
        for ($run = 1; $run -le 5; $run++) {
            $nonElevatedFailure = Invoke-NonElevatedInstallerFixture `
                -Executable $pwshPath -FixtureScript $fixture `
                -PidFile (Join-Path $work "non-elevated-fail-$run.pid") `
                -WorkerExitCode 9 -Phase "user-install-fail-$run" `
                -SimulateTraceFailure $simulateTraceFailure
            Assert-True "non-elevated user-install fails on a zero-delay failing worker (run $run)" `
                ($nonElevatedFailure.Error -match 'exited with code 9') `
                "job fallback did not preserve the worker failure: $($nonElevatedFailure.Error)"
        }

        for ($run = 1; $run -le 3; $run++) {
            $nonElevatedSuccess = Invoke-NonElevatedInstallerFixture `
                -Executable $pwshPath -FixtureScript $fixture `
                -PidFile (Join-Path $work "non-elevated-ok-$run.pid") `
                -WorkerExitCode 0 -Phase "user-install-ok-$run" `
                -SimulateTraceFailure $simulateTraceFailure
            Assert-Equal "non-elevated user-install completes with a zero-delay worker (run $run)" `
                0 $nonElevatedSuccess.ExitCode
        }

        if ($isElevated) {
            $nonElevatedChild = Invoke-NonElevatedInstallerChild `
                -Executable $pwshPath -FixtureScript $fixture `
                -ResultPath (Join-Path $work 'non-elevated-actual.json') `
                -WorkDirectory $work
            Assert-Equal 'actual non-elevated child exits successfully' `
                0 $nonElevatedChild.ExitCode
            $childResult = $nonElevatedChild.Result
            Assert-True 'actual non-elevated child token has no administrator role' `
                (-not [bool]$childResult.is_elevated) 'child process is still elevated'
            Assert-Equal 'actual non-elevated child ran every bootstrap worker' `
                10 $childResult.worker_runs
            Assert-True 'actual non-elevated user-install fails on all zero-delay failing workers' `
                ((@($childResult.failure_errors).Count -eq 5) -and
                    (@($childResult.failure_errors | Where-Object {
                        $_ -notmatch 'exited with code 9'
                    }).Count -eq 0)) `
                "worker failures: $($childResult.failure_errors -join '; '); job_created=$($childResult.job_created); process_table_count=$($childResult.process_table_count); completion_sources=$($childResult.failure_completion_sources -join ', '); tree=$(@($childResult.masked_process_tree | ForEach-Object { "pid=$($_.pid) name=$($_.name) parent=$($_.parent_pid) ended=$($_.ended) exit=$($_.exit_code)" }) -join '; ')"
            Assert-True 'actual non-elevated user-install completes all zero-delay workers' `
                ((@($childResult.success_exit_codes).Count -eq 3) -and
                    (@($childResult.success_exit_codes | Where-Object {
                        $_ -ne 0
                    }).Count -eq 0)) `
                "worker exit codes: $($childResult.success_exit_codes -join ', '); completion_sources=$($childResult.success_completion_sources -join ', ')"
            Assert-True 'actual non-elevated child used job completion tracking' `
                ((@($childResult.failure_completion_sources | Where-Object { $_ -ne 'job' }).Count -eq 0) -and
                    (@($childResult.success_completion_sources).Count -eq 3) -and
                    (@($childResult.success_completion_sources | Where-Object { $_ -ne 'job' }).Count -eq 0) -and
                    ($null -eq $childResult.install_windows_failure_source -or
                        $childResult.install_windows_failure_source -eq 'job') -and
                    ($childResult.install_windows_success_source -eq 'job')) `
                "completion sources: failure=$($childResult.failure_completion_sources -join ', '); success=$($childResult.success_completion_sources -join ', '); install_failure=$($childResult.install_windows_failure_source); install_success=$($childResult.install_windows_success_source)"
            Assert-True 'actual non-elevated install-windows path fails on a zero-delay failing worker' `
                ($childResult.install_windows_failure_error -match 'exited with code 9') `
                "install-windows failure was: $($childResult.install_windows_failure_error); tree=$(@($childResult.install_windows_masked_tree | ForEach-Object { "pid=$($_.pid) name=$($_.name) parent=$($_.parent_pid) ended=$($_.ended) exit=$($_.exit_code)" }) -join '; ')"
            Assert-Equal 'actual non-elevated install-windows path completes a zero-delay worker' `
                0 $childResult.install_windows_success_exit_code
        }

        $untrackedMessage = & $runnerModule {
            param($executable)
            $originalNewProcessJob = [scriptblock]::Create(
                (Get-Command -Name New-ProcessJob -CommandType Function).Definition)
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
                Set-Item -Path Function:script:New-ProcessJob -Value $originalNewProcessJob
            }
        } $pwshPath
        Assert-True 'missing trace and job tracking fails closed' `
            ($untrackedMessage -match 'no reliable non-elevated process completion source') `
            "runner did not fail closed: $untrackedMessage"

        $snapshotFailureMessage = & $runnerModule {
            param($executable)
            $originalNewProcessJob = [scriptblock]::Create(
                (Get-Command -Name New-ProcessJob -CommandType Function).Definition)
            function script:Register-CimIndicationEvent {
                throw 'simulated trace registration failure'
            }
            function script:New-ProcessJob {
                $job = [pscustomobject]@{}
                $job | Add-Member -MemberType ScriptMethod -Name StartSuspended -Value {
                    param($applicationPath, $commandLine, $workingDirectory)
                    $startInfo = [Diagnostics.ProcessStartInfo]::new()
                    $startInfo.FileName = $applicationPath
                    $startInfo.UseShellExecute = $false
                    $startInfo.Arguments = '-NoProfile -Command "Start-Sleep -Milliseconds 300; exit 0"'
                    $process = [Diagnostics.Process]::Start($startInfo)
                    $suspended = [pscustomobject]@{ ProcessId = $process.Id }
                    $suspended | Add-Member -MemberType ScriptMethod -Name Resume -Value { }
                    $suspended | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
                    $process.Dispose()
                    return $suspended
                }
                $job | Add-Member -MemberType ScriptMethod -Name GetProcessIds -Value { return @() }
                $job | Add-Member -MemberType ScriptMethod -Name GetSnapshot -Value { return $null }
                $job | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
                return $job
            }
            try {
                Invoke-BoundedInstallerProcess -FilePath $executable -ArgumentList @(
                    '-NoProfile', '-Command', 'exit 0'
                ) -Phase 'user-install-snapshot-failure' -TimeoutSeconds 5 | Out-Null
                return $null
            } catch {
                return $_.Exception.Message
            } finally {
                Remove-Item -Path Function:Register-CimIndicationEvent -ErrorAction SilentlyContinue
                Set-Item -Path Function:script:New-ProcessJob -Value $originalNewProcessJob
            }
        } $pwshPath
        Assert-True 'missing job snapshot fails closed' `
            ($snapshotFailureMessage -match 'could not read the tracking job snapshot') `
            "runner did not fail closed on missing job evidence: $snapshotFailureMessage"

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
