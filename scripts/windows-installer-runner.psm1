#Requires -Version 5.1
<#
.SYNOPSIS
  Shared bounded runner for NanoDictate's Inno Setup installers and uninstaller.

.DESCRIPTION
  PowerShell's Start-Process -Wait waits for the whole process tree. Inno Setup
  starts the persistent NanoDictate background agent with a nowait [Run] entry,
  so a tree wait can remain blocked long after Setup itself succeeded.

  This runner starts the installer directly without a whole-tree wait, using
  System.Diagnostics.Process or a suspended Windows job-tracked launch. It
  tracks the installer root and any Inno bootstrap/worker process with a
  per-operation deadline, and never waits for the independent product agent.
  Every phase writes bounded diagnostics, including the safe process tree and
  the Inno /LOG file when one is requested.
#>
Set-StrictMode -Version Latest

$script:DefaultDetachedProcessNames = @('NanoDictate.App')
$script:NanoDictatePayloadNames = @(
    'NanoDictate.App.exe'
    'NanoDictate.App.dll'
    'NanoDictate.App.runtimeconfig.json'
    'nanodictate_core.dll'
    'coreclr.dll'
    'hostfxr.dll'
    'config.example.toml'
)
$script:ProcessJobSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace NanoDictate.InstallerRunner
{
    public sealed class JobProcessRecord
    {
        public int Id { get; set; }
        public string Name { get; set; }
        public bool Ended { get; set; }
        public bool HasExitCode { get; set; }
        public int ExitCode { get; set; }
    }

    public sealed class JobProcessSnapshot
    {
        public JobProcessRecord[] Processes { get; set; }
        public bool AccountingAvailable { get; set; }
        public int TotalProcesses { get; set; }
        public int ActiveProcesses { get; set; }
        public int TotalTerminatedProcesses { get; set; }
        public bool AccountingComplete { get; set; }
    }

    public sealed class SuspendedProcess : IDisposable
    {
        private IntPtr processHandle;
        private IntPtr threadHandle;
        private int disposed;
        private bool resumed;

        public int ProcessId { get; private set; }

        internal SuspendedProcess(int processId, IntPtr process, IntPtr thread)
        {
            ProcessId = processId;
            processHandle = process;
            threadHandle = thread;
        }

        public void Resume()
        {
            if (threadHandle == IntPtr.Zero) { return; }
            uint result = ResumeThread(threadHandle);
            if (result == uint.MaxValue)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            resumed = true;
            CloseHandle(threadHandle);
            threadHandle = IntPtr.Zero;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) { return; }
            if (!resumed && processHandle != IntPtr.Zero)
            {
                TerminateProcess(processHandle, 1);
            }
            if (threadHandle != IntPtr.Zero)
            {
                CloseHandle(threadHandle);
                threadHandle = IntPtr.Zero;
            }
            if (processHandle != IntPtr.Zero)
            {
                CloseHandle(processHandle);
                processHandle = IntPtr.Zero;
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }

    public sealed class ProcessJob : IDisposable
    {
        private const int JobObjectBasicAccountingInformation = 1;
        private const int JobObjectBasicProcessIdList = 3;
        private const int JobObjectAssociateCompletionPortInformation = 7;
        private const uint JobObjectMsgNewProcess = 6;
        private const uint JobObjectMsgExitProcess = 7;
        private const uint JobObjectMsgAbnormalExitProcess = 8;
        private const uint CreateSuspended = 0x00000004;
        private const int CaptureIntervalMilliseconds = 250;

        private readonly object gate = new object();
        private readonly Dictionary<int, JobProcessRecord> records = new Dictionary<int, JobProcessRecord>();
        private readonly Dictionary<int, Process> liveProcesses = new Dictionary<int, Process>();
        private IntPtr handle;
        private IntPtr completionPort;
        private Thread monitorThread;
        private int disposed;
        private volatile bool stopping;
        private int captureMilliseconds;

        private ProcessJob(IntPtr job, IntPtr port)
        {
            handle = job;
            completionPort = port;
        }

        public static ProcessJob Create()
        {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            IntPtr port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
            if (port == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new Win32Exception(error);
            }

            ProcessJob result = new ProcessJob(job, port);
            try
            {
                result.AssociateCompletionPort();
                result.StartMonitor();
                return result;
            }
            catch
            {
                result.Dispose();
                throw;
            }
        }

        public SuspendedProcess StartSuspended(string applicationPath, string commandLine, string workingDirectory)
        {
            if (handle == IntPtr.Zero) { throw new InvalidOperationException("The process job is closed."); }
            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
            PROCESS_INFORMATION info;
            StringBuilder mutableCommandLine = new StringBuilder(commandLine);
            if (!CreateProcessW(applicationPath, mutableCommandLine, IntPtr.Zero, IntPtr.Zero, false,
                CreateSuspended, IntPtr.Zero, workingDirectory, ref startup, out info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            if (!AssignProcessToJobObject(handle, info.hProcess))
            {
                int error = Marshal.GetLastWin32Error();
                TerminateProcess(info.hProcess, 1);
                CloseHandle(info.hThread);
                CloseHandle(info.hProcess);
                throw new Win32Exception(error);
            }
            return new SuspendedProcess(info.dwProcessId, info.hProcess, info.hThread);
        }

        public int[] GetProcessIds()
        {
            if (handle == IntPtr.Zero) { return new int[0]; }

            int capacity = 1024;
            while (true)
            {
                int size = 8 + (IntPtr.Size * capacity);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.WriteInt32(buffer, 0, capacity);
                    Marshal.WriteInt32(buffer, 4, 0);
                    if (!QueryInformationJobObject(handle, JobObjectBasicProcessIdList, buffer, (uint)size, IntPtr.Zero))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }

                    int assigned = Marshal.ReadInt32(buffer, 0);
                    int count = Marshal.ReadInt32(buffer, 4);
                    if (count >= capacity)
                    {
                        capacity = Math.Max(capacity * 2, assigned);
                        continue;
                    }

                    int[] ids = new int[count];
                    for (int index = 0; index < count; index++)
                    {
                        ids[index] = Marshal.ReadIntPtr(buffer, 8 + (index * IntPtr.Size)).ToInt32();
                    }
                    return ids;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        public JobProcessSnapshot GetSnapshot()
        {
            CaptureActiveProcesses();
            CheckLiveProcesses();

            JobProcessRecord[] copies;
            lock (gate)
            {
                copies = new JobProcessRecord[records.Count];
                int index = 0;
                foreach (JobProcessRecord record in records.Values)
                {
                    JobProcessRecord copy = new JobProcessRecord();
                    copy.Id = record.Id;
                    copy.Name = record.Name;
                    copy.Ended = record.Ended;
                    copy.HasExitCode = record.HasExitCode;
                    copy.ExitCode = record.ExitCode;
                    copies[index++] = copy;
                }
            }

            bool accountingAvailable = false;
            int totalProcesses = 0;
            int activeProcesses = 0;
            int terminatedProcesses = 0;
            try
            {
                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting =
                    new JOBOBJECT_BASIC_ACCOUNTING_INFORMATION();
                int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    if (!QueryInformationJobObject(handle, JobObjectBasicAccountingInformation,
                        buffer, (uint)size, IntPtr.Zero))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    accounting = (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(
                        buffer, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                    accountingAvailable = true;
                    totalProcesses = (int)accounting.TotalProcesses;
                    activeProcesses = (int)accounting.ActiveProcesses;
                    terminatedProcesses = (int)accounting.TotalTerminatedProcesses;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            catch { }

            JobProcessSnapshot snapshot = new JobProcessSnapshot();
            snapshot.Processes = copies;
            snapshot.AccountingAvailable = accountingAvailable;
            snapshot.TotalProcesses = totalProcesses;
            snapshot.ActiveProcesses = activeProcesses;
            snapshot.TotalTerminatedProcesses = terminatedProcesses;
            snapshot.AccountingComplete = accountingAvailable && copies.Length >= totalProcesses;
            return snapshot;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) { return; }
            stopping = true;
            if (completionPort != IntPtr.Zero)
            {
                PostQueuedCompletionStatus(completionPort, 0, UIntPtr.Zero, new IntPtr(-1));
            }
            Thread thread = monitorThread;
            if (thread != null)
            {
                try { thread.Join(5000); } catch { }
            }
            lock (gate)
            {
                foreach (Process process in liveProcesses.Values)
                {
                    try { process.Dispose(); } catch { }
                }
                liveProcesses.Clear();
            }
            if (completionPort != IntPtr.Zero)
            {
                CloseHandle(completionPort);
                completionPort = IntPtr.Zero;
            }
            if (handle != IntPtr.Zero)
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
            }
        }

        private void AssociateCompletionPort()
        {
            JOBOBJECT_ASSOCIATE_COMPLETION_PORT info = new JOBOBJECT_ASSOCIATE_COMPLETION_PORT();
            info.CompletionKey = new IntPtr(1);
            info.CompletionPort = completionPort;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_ASSOCIATE_COMPLETION_PORT));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(handle, JobObjectAssociateCompletionPortInformation,
                    buffer, (uint)size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private void StartMonitor()
        {
            monitorThread = new Thread(Monitor);
            monitorThread.IsBackground = true;
            monitorThread.Name = "NanoDictate installer job monitor";
            monitorThread.Start();
        }

        private void Monitor()
        {
            while (!stopping)
            {
                uint message;
                UIntPtr completionKey;
                IntPtr overlapped;
                bool ok = GetQueuedCompletionStatus(completionPort, out message, out completionKey,
                    out overlapped, 50);
                if (ok)
                {
                    int processId = (int)overlapped.ToInt64();
                    if (processId > 0)
                    {
                        HandleMessage(message, processId);
                    }
                }

                captureMilliseconds += 50;
                if (captureMilliseconds >= CaptureIntervalMilliseconds)
                {
                    captureMilliseconds = 0;
                    CaptureActiveProcesses();
                }
                CheckLiveProcesses();
            }
        }

        private void HandleMessage(uint message, int processId)
        {
            if (message == JobObjectMsgNewProcess)
            {
                HandleNewProcess(processId);
            }
            else if (message == JobObjectMsgExitProcess || message == JobObjectMsgAbnormalExitProcess)
            {
                HandleExitProcess(processId);
            }
        }

        private void HandleNewProcess(int processId)
        {
            Process process = null;
            string name = null;
            try
            {
                process = Process.GetProcessById(processId);
                if (process.Handle == IntPtr.Zero) { throw new InvalidOperationException(); }
                name = process.ProcessName;
            }
            catch
            {
                if (process != null)
                {
                    try { process.Dispose(); } catch { }
                }
                process = null;
            }

            lock (gate)
            {
                JobProcessRecord record = EnsureRecord(processId);
                if (!string.IsNullOrEmpty(name) &&
                    (string.IsNullOrEmpty(record.Name) || name.Length > record.Name.Length))
                {
                    record.Name = name;
                }
                if (process != null)
                {
                    Process previous;
                    if (liveProcesses.TryGetValue(processId, out previous) &&
                        !object.ReferenceEquals(previous, process))
                    {
                        try { previous.Dispose(); } catch { }
                    }
                    liveProcesses[processId] = process;
                }
            }
            CheckLiveProcess(processId, process);
        }

        private void HandleExitProcess(int processId)
        {
            Process process = null;
            lock (gate)
            {
                JobProcessRecord record = EnsureRecord(processId);
                record.Ended = true;
                Process live;
                if (liveProcesses.TryGetValue(processId, out live))
                {
                    liveProcesses.Remove(processId);
                    process = live;
                }
            }
            if (process == null) { return; }

            int exitCode = 0;
            bool hasExitCode = false;
            try
            {
                process.WaitForExit(1000);
                exitCode = process.ExitCode;
                hasExitCode = true;
            }
            catch { }

            lock (gate)
            {
                JobProcessRecord record = EnsureRecord(processId);
                record.Ended = true;
                if (hasExitCode)
                {
                    record.ExitCode = exitCode;
                    record.HasExitCode = true;
                }
            }
            try { process.Dispose(); } catch { }
        }

        private void CheckLiveProcesses()
        {
            List<KeyValuePair<int, Process>> copy = new List<KeyValuePair<int, Process>>();
            lock (gate)
            {
                foreach (KeyValuePair<int, Process> entry in liveProcesses)
                {
                    copy.Add(entry);
                }
            }
            foreach (KeyValuePair<int, Process> entry in copy)
            {
                CheckLiveProcess(entry.Key, entry.Value);
            }
        }

        private void CheckLiveProcess(int processId, Process process)
        {
            if (process == null) { return; }
            bool exited;
            try { exited = process.HasExited; } catch { return; }
            if (!exited) { return; }

            int exitCode = 0;
            bool hasExitCode = false;
            try
            {
                exitCode = process.ExitCode;
                hasExitCode = true;
            }
            catch { }

            lock (gate)
            {
                JobProcessRecord record = EnsureRecord(processId);
                record.Ended = true;
                if (hasExitCode)
                {
                    record.ExitCode = exitCode;
                    record.HasExitCode = true;
                }
                Process live;
                if (liveProcesses.TryGetValue(processId, out live) &&
                    object.ReferenceEquals(live, process))
                {
                    liveProcesses.Remove(processId);
                }
            }
            try { process.Dispose(); } catch { }
        }

        private void CaptureActiveProcesses()
        {
            int[] ids;
            try { ids = GetProcessIds(); } catch { return; }

            foreach (int processId in ids)
            {
                if (processId <= 0) { continue; }
                bool known;
                lock (gate)
                {
                    known = records.ContainsKey(processId) && liveProcesses.ContainsKey(processId);
                }
                if (known) { continue; }

                Process process = null;
                string name = null;
                try
                {
                    process = Process.GetProcessById(processId);
                    if (process.Handle == IntPtr.Zero) { throw new InvalidOperationException(); }
                    name = process.ProcessName;
                }
                catch
                {
                    if (process != null)
                    {
                        try { process.Dispose(); } catch { }
                    }
                    process = null;
                }
                if (process == null) { continue; }

                lock (gate)
                {
                    JobProcessRecord record = EnsureRecord(processId);
                    if (!string.IsNullOrEmpty(name) &&
                        (string.IsNullOrEmpty(record.Name) || name.Length > record.Name.Length))
                    {
                        record.Name = name;
                    }
                    Process previous;
                    if (liveProcesses.TryGetValue(processId, out previous) &&
                        !object.ReferenceEquals(previous, process))
                    {
                        try { previous.Dispose(); } catch { }
                    }
                    liveProcesses[processId] = process;
                }
                CheckLiveProcess(processId, process);
            }
        }

        private JobProcessRecord EnsureRecord(int processId)
        {
            JobProcessRecord record;
            if (!records.TryGetValue(processId, out record))
            {
                record = new JobProcessRecord();
                record.Id = processId;
                records[processId] = record;
            }
            return record;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_ASSOCIATE_COMPLETION_PORT
        {
            public IntPtr CompletionKey;
            public IntPtr CompletionPort;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public uint cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public ushort wShowWindow;
            public ushort cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr hJob, int jobObjectInformationClass,
            IntPtr lpJobObjectInformation, uint cbJobObjectInformationLength, IntPtr lpReturnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int jobObjectInformationClass,
            IntPtr lpJobObjectInformation, uint cbJobObjectInformationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateIoCompletionPort(IntPtr fileHandle, IntPtr existingCompletionPort,
            UIntPtr completionKey, uint numberOfConcurrentThreads);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetQueuedCompletionStatus(IntPtr completionPort, out uint numberOfBytes,
            out UIntPtr completionKey, out IntPtr overlapped, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool PostQueuedCompletionStatus(IntPtr completionPort, uint numberOfBytes,
            UIntPtr completionKey, IntPtr overlapped);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
            uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    }
}
'@

function Get-ProcessTable {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $rows = Get-CimInstance -Query "SELECT ProcessId, ParentProcessId, Name FROM Win32_Process" -ErrorAction Stop
        foreach ($row in $rows) {
            [pscustomobject]@{
                Id       = [int]$row.ProcessId
                ParentId = [int]$row.ParentProcessId
                Name     = [IO.Path]::GetFileNameWithoutExtension([string]$row.Name)
            }
        }
        return
    }

    $rows = & ps -eo pid=,ppid=,comm= 2>$null
    foreach ($row in $rows) {
        if ($row -match '^\s*(\d+)\s+(\d+)\s+(.+?)\s*$') {
            [pscustomobject]@{
                Id       = [int]$Matches[1]
                ParentId = [int]$Matches[2]
                Name     = [IO.Path]::GetFileName($Matches[3])
            }
        }
    }
}

function Open-TrackedProcess {
    param([Diagnostics.Process]$Process)

    if ($null -eq $Process) { return $null }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $Process }

    # Process.ExitCode returns 0 when .NET could not open a handle before the
    # process exited. Open and cache the handle while the process is alive so
    # the real exit code survives a short-lived worker.
    try {
        $null = $Process.Handle
        $Process | Add-Member -NotePropertyName HandleCached -NotePropertyValue $true -Force | Out-Null
        return $Process
    } catch {
        return $Process
    }
}

function New-ProcessJob {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $null }
    try {
        if (-not ('NanoDictate.InstallerRunner.ProcessJob' -as [type])) {
            Add-Type -TypeDefinition $script:ProcessJobSource -Language CSharp -ErrorAction Stop
        }
        return [NanoDictate.InstallerRunner.ProcessJob]::Create()
    } catch {
        Write-Verbose "Could not create a Windows job object for installer tracking: $_"
        return $null
    }
}

function Get-ProcessJobIds {
    param($ProcessJob)

    if ($null -eq $ProcessJob) { return @() }
    try {
        return @($ProcessJob.GetProcessIds())
    } catch {
        Write-Verbose "Could not enumerate the installer tracking job: $_"
        return @()
    }
}

function Get-ProcessJobSnapshot {
    param($ProcessJob)

    if ($null -eq $ProcessJob) { return $null }
    try {
        return $ProcessJob.GetSnapshot()
    } catch {
        Write-Verbose "Could not read the installer tracking job snapshot: $_"
        return $null
    }
}

function Close-ProcessJob {
    param($ProcessJob)

    if ($null -eq $ProcessJob) { return }
    try { $ProcessJob.Dispose() } catch {
        Write-Verbose "Could not close the installer tracking job: $_"
    }
}

function Get-ProcessTraceEventValue {
    param($EventInstance, [string]$Name)

    if ($null -eq $EventInstance) { return $null }
    try {
        $property = $EventInstance.CimInstanceProperties[$Name]
        if ($null -ne $property) { return $property.Value }
    } catch { }
    try {
        $property = $EventInstance.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    } catch { }
    return $null
}

function ConvertFrom-ProcessTraceExitStatus {
    param($ExitStatus)

    if ($null -eq $ExitStatus) { return $null }
    try {
        $value = [int64]$ExitStatus
    } catch {
        return $null
    }
    # Win32_ProcessStopTrace reports UInt32.MaxValue when Windows cannot
    # confirm the status. Keep it unknown so the caller fails closed.
    if ($value -eq [int64][uint32]::MaxValue) { return $null }
    return $value
}

function Start-ProcessTrace {
    param([string]$Phase)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $null }
    $safePhase = $Phase -replace '[^A-Za-z0-9]', ''
    $prefix = "NanoDictateRunner-$safePhase-$([guid]::NewGuid().ToString('N'))"
    $startIdentifier = "$prefix-start"
    $stopIdentifier = "$prefix-stop"
    try {
        Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace `
            -SourceIdentifier $startIdentifier -ErrorAction Stop | Out-Null
        try {
            Register-CimIndicationEvent -ClassName Win32_ProcessStopTrace `
                -SourceIdentifier $stopIdentifier -ErrorAction Stop | Out-Null
        } catch {
            Unregister-Event -SourceIdentifier $startIdentifier -ErrorAction SilentlyContinue
            throw
        }
        return [pscustomobject]@{
            StartIdentifier = $startIdentifier
            StopIdentifier  = $stopIdentifier
        }
    } catch {
        # Win32 process trace events require an elevated session on Windows.
        # The caller falls back to a non-elevated job object so a normal
        # per-user install can still track its worker processes.
        Write-Verbose "Durable process trace events are unavailable for installer phase '$Phase': $($_.Exception.Message)"
        return $null
    }
}

function Stop-ProcessTrace {
    param($ProcessTrace)

    if ($null -eq $ProcessTrace) { return }
    foreach ($identifier in @($ProcessTrace.StartIdentifier, $ProcessTrace.StopIdentifier)) {
        if ([string]::IsNullOrWhiteSpace($identifier)) { continue }
        Unregister-Event -SourceIdentifier $identifier -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $identifier -ErrorAction SilentlyContinue |
            Remove-Event -ErrorAction SilentlyContinue
    }
}

function Read-ProcessTraceEvents {
    param(
        [hashtable]$ProcessEvents,
        $ProcessTrace
    )

    if ($null -eq $ProcessTrace) { return 0 }
    $read = 0
    $subscriptions = @(
        [pscustomobject]@{ Identifier = $ProcessTrace.StartIdentifier; IsStop = $false }
        [pscustomobject]@{ Identifier = $ProcessTrace.StopIdentifier; IsStop = $true }
    )
    foreach ($subscription in $subscriptions) {
        foreach ($event in @(Get-Event -SourceIdentifier $subscription.Identifier -ErrorAction SilentlyContinue)) {
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
            $newEvent = $event.SourceEventArgs.NewEvent
            if ($null -eq $newEvent) { continue }
            $processId = [int](Get-ProcessTraceEventValue $newEvent 'ProcessID')
            if ($processId -le 0) { continue }
            $parentId = [int](Get-ProcessTraceEventValue $newEvent 'ParentProcessID')
            $name = [IO.Path]::GetFileNameWithoutExtension(
                [string](Get-ProcessTraceEventValue $newEvent 'ProcessName'))
            $entry = $ProcessEvents[$processId]
            if ($null -eq $entry) {
                $entry = [pscustomobject]@{
                    Id            = $processId
                    ParentId      = $parentId
                    Name          = $name
                    NameFromStart = -not $subscription.IsStop
                    ExitCode      = $null
                    Ended         = $false
                }
                $ProcessEvents[$processId] = $entry
            } elseif (-not $subscription.IsStop -and -not $entry.NameFromStart) {
                # Win32_ProcessStopTrace truncates ProcessName. Prefer the full
                # name from the process start event even if the stop arrived first.
                if ($name.Length -ge ([string]$entry.Name).Length) {
                    $entry.Name = $name
                }
                $entry.NameFromStart = $true
            }
            if ($subscription.IsStop) {
                $exitCode = ConvertFrom-ProcessTraceExitStatus `
                    (Get-ProcessTraceEventValue $newEvent 'ExitStatus')
                if ($null -ne $exitCode) { $entry.ExitCode = $exitCode }
                $entry.Ended = $true
            }
            $read++
        }
    }
    return $read
}

function Update-TrackedProcessEvents {
    param(
        [hashtable]$Tracked,
        [hashtable]$ProcessEvents,
        [string[]]$DetachedProcessNames
    )

    if ($ProcessEvents.Count -eq 0) { return 0 }

    $children = @{}
    foreach ($eventEntry in $ProcessEvents.Values) {
        if (-not $children.ContainsKey($eventEntry.ParentId)) {
            $children[$eventEntry.ParentId] = [Collections.Generic.List[object]]::new()
        }
        $children[$eventEntry.ParentId].Add($eventEntry)
    }

    $changes = 0
    $queue = [Collections.Generic.Queue[int]]::new()
    foreach ($id in @($Tracked.Keys)) { $queue.Enqueue([int]$id) }

    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        if (-not $children.ContainsKey($parentId)) { continue }
        $parentEntry = $Tracked[$parentId]
        if ($null -eq $parentEntry) { continue }

        foreach ($eventEntry in $children[$parentId]) {
            $detached = [bool]$parentEntry.Detached -or
                ($DetachedProcessNames -contains [string]$eventEntry.Name)
            $existing = $Tracked[$eventEntry.Id]
            if ($null -eq $existing) {
                $process = $null
                if (-not $eventEntry.Ended) {
                    try {
                        $process = Open-TrackedProcess ([Diagnostics.Process]::GetProcessById([int]$eventEntry.Id))
                    } catch { }
                }
                $Tracked[$eventEntry.Id] = [pscustomobject]@{
                    Id       = [int]$eventEntry.Id
                    ParentId = [int]$parentId
                    Name     = [string]$eventEntry.Name
                    Detached = [bool]$detached
                    Process  = $process
                    ExitCode = $eventEntry.ExitCode
                    Ended    = [bool]$eventEntry.Ended
                }
                $queue.Enqueue([int]$eventEntry.Id)
                $changes++
            } else {
                if ($eventEntry.Name.Length -gt ([string]$existing.Name).Length) {
                    $existing.Name = [string]$eventEntry.Name
                    $changes++
                }
                if ($detached -and -not $existing.Detached) {
                    $existing.Detached = $true
                    $queue.Enqueue([int]$existing.Id)
                    $changes++
                }
                if ($eventEntry.Ended -and -not $existing.Ended) {
                    $existing.Ended = $true
                    $changes++
                }
                if ($null -ne $eventEntry.ExitCode -and $existing.ExitCode -ne $eventEntry.ExitCode) {
                    $existing.ExitCode = $eventEntry.ExitCode
                    $changes++
                }
            }
        }
    }
    return $changes
}

function Update-TrackedProcessJob {
    param(
        [hashtable]$Tracked,
        [string[]]$DetachedProcessNames,
        $ProcessJob,
        [int]$RootId = 0,
        $Snapshot
    )

    if ($null -eq $Snapshot) {
        if ($null -eq $ProcessJob) { return 0 }
        $Snapshot = Get-ProcessJobSnapshot -ProcessJob $ProcessJob
    }
    if ($null -eq $Snapshot) { return 0 }

    $changes = 0
    foreach ($record in @($Snapshot.Processes)) {
        $id = [int]$record.Id
        if ($id -le 0) { continue }
        $name = [string]$record.Name
        $ended = [bool]$record.Ended
        $exitCode = if ([bool]$record.HasExitCode) { [int]$record.ExitCode } else { $null }
        $existing = $Tracked[$id]
        if ($null -eq $existing) {
            $process = $null
            if (-not $ended) {
                try {
                    $process = Open-TrackedProcess ([Diagnostics.Process]::GetProcessById($id))
                } catch { }
            }
            $parentId = if ($RootId -gt 0) { $RootId } else { 0 }
            $Tracked[$id] = [pscustomobject]@{
                Id       = $id
                ParentId = $parentId
                Name     = $name
                Detached = [bool]($DetachedProcessNames -contains $name)
                Process  = $process
                ExitCode = $exitCode
                Ended    = $ended
            }
            $changes++
            continue
        }

        if ($name.Length -gt ([string]$existing.Name).Length) {
            $existing.Name = $name
            $changes++
        }
        $detached = [bool]$existing.Detached -or ($DetachedProcessNames -contains $name)
        if ($detached -and -not $existing.Detached) {
            $existing.Detached = $true
            $changes++
        }
        if ($ended -and -not $existing.Ended) {
            $existing.Ended = $true
            $changes++
        }
        if ($null -ne $exitCode -and $existing.ExitCode -ne $exitCode) {
            $existing.ExitCode = $exitCode
            $changes++
        }
    }
    return $changes
}

function Update-TrackedState {
    param(
        [hashtable]$Tracked,
        [string[]]$DetachedProcessNames,
        [hashtable]$ProcessEvents,
        $ProcessTrace,
        $ProcessJob,
        [int]$RootId = 0
    )

    $read = Read-ProcessTraceEvents -ProcessEvents $ProcessEvents -ProcessTrace $ProcessTrace
    Update-TrackedProcesses -Tracked $Tracked -DetachedProcessNames $DetachedProcessNames `
        -ProcessJob $ProcessJob -RootId $RootId
    $changes = Update-TrackedProcessEvents -Tracked $Tracked -ProcessEvents $ProcessEvents `
        -DetachedProcessNames $DetachedProcessNames
    $changes += Update-TrackedProcessJob -Tracked $Tracked `
        -DetachedProcessNames $DetachedProcessNames -ProcessJob $ProcessJob -RootId $RootId
    return ($read + $changes)
}

function ConvertTo-InnoSetupCommandLineArgument {
    param([string]$Argument)

    # Inno Setup parses its command line with Delphi ParamStr rules: quotes
    # group text and are removed, while backslashes are literal. Do not use
    # MSVCRT/.NET backslash escaping, which Inno would keep as path characters.
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument.Contains('"')) {
        throw "Installer argument must not contain quotes: $Argument"
    }
    if ($Argument -match '\s') { return '"' + $Argument + '"' }
    return $Argument
}

function Update-TrackedProcesses {
    param(
        [hashtable]$Tracked,
        [string[]]$DetachedProcessNames,
        $ProcessJob,
        [int]$RootId = 0
    )

    $table = @(Get-ProcessTable)
    if ($null -ne $ProcessJob) {
        $knownIds = @{}
        foreach ($row in $table) { $knownIds[[int]$row.Id] = $true }
        foreach ($jobId in @(Get-ProcessJobIds -ProcessJob $ProcessJob)) {
            $id = [int]$jobId
            if ($id -le 0 -or $knownIds.ContainsKey($id)) { continue }
            $name = ''
            $jobProcess = $null
            try {
                $jobProcess = [Diagnostics.Process]::GetProcessById($id)
                $name = [string]$jobProcess.ProcessName
            } catch {
                Write-Verbose "Could not inspect job process $id`: $_"
            } finally {
                if ($null -ne $jobProcess) {
                    try { $jobProcess.Dispose() } catch {
                        Write-Verbose "Could not dispose job process $id`: $_"
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $parentId = if ($RootId -gt 0) { $RootId } else { 0 }
            $table += [pscustomobject]@{
                Id       = $id
                ParentId = $parentId
                Name     = $name
            }
            $knownIds[$id] = $true
        }
    }
    $children = @{}
    foreach ($row in $table) {
        if (-not $children.ContainsKey($row.ParentId)) {
            $children[$row.ParentId] = [Collections.Generic.List[object]]::new()
        }
        $children[$row.ParentId].Add($row)
    }

    $queue = [Collections.Generic.Queue[int]]::new()
    foreach ($id in @($Tracked.Keys)) { $queue.Enqueue([int]$id) }

    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        if (-not $children.ContainsKey($parentId)) { continue }

        $parentEntry = $Tracked[$parentId]
        foreach ($child in $children[$parentId]) {
            $detached = [bool]$parentEntry.Detached -or
                ($DetachedProcessNames -contains [string]$child.Name)
            $existing = $Tracked[$child.Id]
            if ($null -eq $existing) {
                $process = $null
                try {
                    $process = Open-TrackedProcess ([Diagnostics.Process]::GetProcessById([int]$child.Id))
                } catch { }
                $Tracked[$child.Id] = [pscustomobject]@{
                    Id       = [int]$child.Id
                    ParentId = [int]$parentId
                    Name     = [string]$child.Name
                    Detached = [bool]$detached
                    Process  = $process
                    ExitCode = $null
                    Ended    = $false
                }
                $queue.Enqueue([int]$child.Id)
            } elseif ($detached -and -not $existing.Detached) {
                $existing.Detached = $true
                $queue.Enqueue([int]$child.Id)
            }
        }
    }

    foreach ($entry in @($Tracked.Values)) {
        $process = $entry.Process
        if ($null -eq $process -and -not $entry.Ended) {
            try {
                $process = Open-TrackedProcess ([Diagnostics.Process]::GetProcessById([int]$entry.Id))
                $entry.Process = $process
                if ($null -eq $process) { $entry.Ended = $true }
            } catch {
                if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
                    $entry.Ended = $true
                }
            }
        }
        if ($null -ne $process) {
            try {
                if ($process.HasExited) {
                    $entry.Ended = $true
                    $canTrustExit = [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
                        ($process.PSObject.Properties['HandleCached'] -and $process.HandleCached)
                    if ($null -eq $entry.ExitCode -and $canTrustExit) {
                        $entry.ExitCode = [int]$process.ExitCode
                    }
                }
            } catch {
                if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
                    $entry.Ended = $true
                }
            }
        }
    }
}

function Get-TrackedSnapshot {
    param([hashtable]$Tracked)
    @($Tracked.Values | Sort-Object Id | ForEach-Object {
        [ordered]@{
            pid        = $_.Id
            parent_pid = $_.ParentId
            name       = $_.Name
            detached   = [bool]$_.Detached
            ended      = [bool]$_.Ended
            exit_code  = $_.ExitCode
        }
    })
}

function Write-InstallerPhaseEvidence {
    param(
        [string]$LogDirectory,
        [string]$Phase,
        [hashtable]$Tracked,
        [double]$ElapsedSeconds,
        [datetime]$StartedUtc,
        [string]$Executable,
        [int]$ProcessId,
        [int]$TimeoutSeconds,
        $ExitCode,
        [bool]$TimedOut,
        [string]$Outcome,
        [string]$InnoLogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) { return }
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $safePhase = $Phase -replace '[^A-Za-z0-9._-]', '-'
    $evidence = [ordered]@{
        phase           = $Phase
        outcome         = $Outcome
        started_utc     = $StartedUtc.ToString('o')
        finished_utc    = [DateTime]::UtcNow.ToString('o')
        elapsed_seconds = [Math]::Round($ElapsedSeconds, 2)
        timeout_seconds = $TimeoutSeconds
        timed_out       = $TimedOut
        executable      = [IO.Path]::GetFileName($Executable)
        process_id      = $ProcessId
        exit_code       = $ExitCode
        inno_log        = if ($InnoLogPath) { [IO.Path]::GetFileName($InnoLogPath) } else { $null }
        processes       = @(Get-TrackedSnapshot -Tracked $Tracked)
    }
    $evidence | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $LogDirectory "$safePhase.json") -Encoding utf8
}

function Format-TrackedSummary {
    param([hashtable]$Tracked)
    @(Get-TrackedSnapshot -Tracked $Tracked | ForEach-Object {
        "pid=$($_.pid) name=$($_.name) parent=$($_.parent_pid) detached=$($_.detached) ended=$($_.ended) exit=$($_.exit_code)"
    }) -join '; '
}

function Invoke-BoundedInstallerProcess {
    <#
    .SYNOPSIS
      Start an installer/uninstaller and wait for its completion with a deadline.
    .DESCRIPTION
      Waits for the process that was started, then for installer bootstrap or
      worker descendants that can outlive a short-lived root. Descendants in
      DetachedProcessNames (the product's persistent background agent) are
      never awaited. A nonzero root or installer-worker exit code fails the
      phase. On timeout only the tracked, non-detached processes are killed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$Phase,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 240,
        [string[]]$DetachedProcessNames = $script:DefaultDetachedProcessNames,
        [string]$InstallerProcessNamePattern = '(?i)(setup|unins)',
        [string]$LogDirectory,
        [string]$InnoLogFileName
    )

    $startedUtc = [DateTime]::UtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $resolved = (Resolve-Path -LiteralPath $FilePath -ErrorAction Stop).Path
    if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = [IO.Path]::GetFullPath($LogDirectory)
        New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    }

    $innoLogPath = $null
    if (-not [string]::IsNullOrWhiteSpace($InnoLogFileName)) {
        if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
            throw 'LogDirectory is required when InnoLogFileName is set.'
        }
        $innoLogPath = Join-Path $LogDirectory ([IO.Path]::GetFileName($InnoLogFileName))
        $ArgumentList = @($ArgumentList) + @("/LOG=$innoLogPath")
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolved
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = (@($ArgumentList | Where-Object { $null -ne $_ } | ForEach-Object {
        ConvertTo-InnoSetupCommandLineArgument ([string]$_)
    }) -join ' ')

    $logLabel = if ($innoLogPath) { [IO.Path]::GetFileName($innoLogPath) } else { 'none' }
    Write-Host ("[installer:{0}] start exe={1} timeout={2}s log={3}" -f
        $Phase, [IO.Path]::GetFileName($resolved), $TimeoutSeconds, $logLabel)

    $rootPid = 0
    $rootName = ''
    $tracked = @{}
    $processEvents = @{}
    $processTrace = $null
    $processJob = $null
    $rootExitCode = $null
    $snapshot = @()
    $outcome = 'unknown'
    $timedOut = $false
    $deadline = $startedUtc.AddSeconds($TimeoutSeconds)

    try {
        $processTrace = Start-ProcessTrace -Phase $Phase
        $processJob = New-ProcessJob
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
            $null -eq $processTrace -and $null -eq $processJob) {
            throw "Installer phase '$Phase' has no reliable non-elevated process completion source because process traces are unavailable and the tracking job could not be created."
        }

        $process = $null
        $suspended = $null
        if ($null -ne $processJob) {
            try {
                $commandLine = '"' + $resolved + '"'
                if (-not [string]::IsNullOrWhiteSpace([string]$startInfo.Arguments)) {
                    $commandLine += ' ' + [string]$startInfo.Arguments
                }
                $suspended = $processJob.StartSuspended($resolved, $commandLine, $null)
                $rootPid = [int]$suspended.ProcessId
                $process = [Diagnostics.Process]::GetProcessById($rootPid)
                $rootTrackedProcess = Open-TrackedProcess $process
                if ($null -eq $rootTrackedProcess) {
                    throw "Could not open a durable handle for installer root pid $rootPid."
                }
                try { $rootName = [string]$process.ProcessName } catch {
                    $rootName = [IO.Path]::GetFileNameWithoutExtension($resolved)
                }
                $tracked[$rootPid] = [pscustomobject]@{
                    Id       = $rootPid
                    ParentId = 0
                    Name     = $rootName
                    Detached = $false
                    Process  = $rootTrackedProcess
                    ExitCode = $null
                    Ended    = $false
                }
                $suspended.Resume()
            } catch {
                $startFailure = $_
                if ($null -ne $suspended) { try { $suspended.Dispose() } catch { } }
                if ($null -ne $process) { try { $process.Dispose() } catch { } }
                $process = $null
                $suspended = $null
                if ($null -eq $processTrace) { throw $startFailure }
                Write-Verbose "Could not start installer under job tracking; falling back to process traces: $($startFailure.Exception.Message)"
                Close-ProcessJob -ProcessJob $processJob
                $processJob = $null
                $tracked.Clear()
                $rootPid = 0
            } finally {
                if ($null -ne $suspended) { try { $suspended.Dispose() } catch { } }
            }
        }
        if ($null -eq $process) {
            $process = [Diagnostics.Process]::Start($startInfo)
            if ($null -eq $process) { throw "Failed to start installer for phase '$Phase'." }
            $rootPid = [int]$process.Id
            try { $rootName = [string]$process.ProcessName } catch {
                $rootName = [IO.Path]::GetFileNameWithoutExtension($resolved)
            }
            $tracked[$rootPid] = [pscustomobject]@{
                Id       = $rootPid
                ParentId = 0
                Name     = $rootName
                Detached = $false
                Process  = (Open-TrackedProcess $process)
                ExitCode = $null
                Ended    = $false
            }
        }

        $pollInterval = 50
        $maxFastPolls = 40
        $pollCount = 0

        while (-not $process.HasExited) {
            [void](Update-TrackedState -Tracked $tracked `
                -DetachedProcessNames $DetachedProcessNames `
                -ProcessEvents $processEvents -ProcessTrace $processTrace `
                -ProcessJob $processJob -RootId $rootPid)
            if ([DateTime]::UtcNow -ge $deadline) {
                $timedOut = $true
                throw [TimeoutException]::new(
                    "Installer phase '$Phase' timed out after $TimeoutSeconds seconds while the installer root was still running.")
            }
            [void]$process.WaitForExit($pollInterval)
            $pollCount++
            if ($pollCount -ge $maxFastPolls) { $pollInterval = 200 }
        }

        $rootExitCode = [int]$process.ExitCode

        # A bootstrap can exit before the real setup worker. Wait only for
        # installer-like descendants; never for the persistent product agent.
        # Poll aggressively at first to catch short-lived workers before they exit.
        $workerPollInterval = 50
        $workerFastPolls = 40
        $workerPollCount = 0
        $processTraceSettleMilliseconds = 500

        while ($true) {
            [void](Update-TrackedState -Tracked $tracked `
                -DetachedProcessNames $DetachedProcessNames `
                -ProcessEvents $processEvents -ProcessTrace $processTrace `
                -ProcessJob $processJob -RootId $rootPid)
            $remaining = @($tracked.Values | Where-Object {
                $_.Id -ne $rootPid -and -not $_.Detached -and -not $_.Ended -and
                ([string]::IsNullOrWhiteSpace([string]$_.Name) -or
                    $_.Name -eq $rootName -or $_.Name -match $InstallerProcessNamePattern)
            })
            if ($remaining.Count -eq 0) {
                if ($null -eq $processTrace -and $null -eq $processJob) { break }
                $settleUntil = [DateTime]::UtcNow.AddMilliseconds($processTraceSettleMilliseconds)
                while ([DateTime]::UtcNow -lt $settleUntil) {
                    Start-Sleep -Milliseconds 50
                    [void](Update-TrackedState -Tracked $tracked `
                        -DetachedProcessNames $DetachedProcessNames `
                        -ProcessEvents $processEvents -ProcessTrace $processTrace `
                        -ProcessJob $processJob -RootId $rootPid)
                    $remaining = @($tracked.Values | Where-Object {
                        $_.Id -ne $rootPid -and -not $_.Detached -and -not $_.Ended -and
                        ([string]::IsNullOrWhiteSpace([string]$_.Name) -or
                            $_.Name -eq $rootName -or $_.Name -match $InstallerProcessNamePattern)
                    })
                    if ($remaining.Count -gt 0) { break }
                }
                if ($remaining.Count -eq 0) { break }
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                $timedOut = $true
                throw [TimeoutException]::new(
                    "Installer phase '$Phase' timed out after $TimeoutSeconds seconds waiting for installer worker process(es): $((($remaining | ForEach-Object { "$($_.Name)[$($_.Id)]" }) -join ', ')).")
            }
            Start-Sleep -Milliseconds $workerPollInterval
            $workerPollCount++
            if ($workerPollCount -ge $workerFastPolls) { $workerPollInterval = 150 }
        }

        [void](Update-TrackedState -Tracked $tracked `
            -DetachedProcessNames $DetachedProcessNames `
            -ProcessEvents $processEvents -ProcessTrace $processTrace `
            -ProcessJob $processJob -RootId $rootPid)
        $jobSnapshot = Get-ProcessJobSnapshot -ProcessJob $processJob
        if ($null -ne $jobSnapshot) {
            [void](Update-TrackedProcessJob -Tracked $tracked `
                -DetachedProcessNames $DetachedProcessNames -ProcessJob $processJob `
                -RootId $rootPid -Snapshot $jobSnapshot)
        }

        if ($rootExitCode -ne 0) {
            throw "Installer phase '$Phase' exited with code $rootExitCode."
        }

        if ($null -eq $processTrace -and $null -ne $jobSnapshot) {
            if (-not [bool]$jobSnapshot.AccountingAvailable) {
                throw "Installer phase '$Phase' could not verify job completion accounting. Fail closed."
            }
            if (-not [bool]$jobSnapshot.AccountingComplete) {
                throw "Installer phase '$Phase' observed $(@($jobSnapshot.Processes).Count) tracked job process(es) but Windows reported $($jobSnapshot.TotalProcesses). Completion evidence is incomplete. Fail closed."
            }
        }

        $workerFailures = @($tracked.Values | Where-Object {
            $_.Id -ne $rootPid -and -not $_.Detached -and $_.Ended -and
            $null -ne $_.ExitCode -and $_.ExitCode -ne 0 -and
            ([string]::IsNullOrWhiteSpace([string]$_.Name) -or
                $_.Name -eq $rootName -or $_.Name -match $InstallerProcessNamePattern)
        })
        if ($workerFailures.Count -gt 0) {
            $first = $workerFailures[0]
            throw "Installer worker '$($first.Name)' (pid $($first.Id)) exited with code $($first.ExitCode)."
        }

        $unknownExitWorkers = @($tracked.Values | Where-Object {
            $_.Id -ne $rootPid -and -not $_.Detached -and $_.Ended -and
            $null -eq $_.ExitCode -and
            ([string]::IsNullOrWhiteSpace([string]$_.Name) -or
                $_.Name -eq $rootName -or $_.Name -match $InstallerProcessNamePattern)
        })
        if ($unknownExitWorkers.Count -gt 0) {
            $first = $unknownExitWorkers[0]
            throw "Installer worker '$($first.Name)' (pid $($first.Id)) exited but its exit code could not be determined (process handle lost). Fail closed."
        }

        $outcome = 'success'
        $snapshot = @(Get-TrackedSnapshot -Tracked $tracked)
        $timer.Stop()
        Write-Host ("[installer:{0}] finish exit={1} elapsed={2:N1}s" -f
            $Phase, $rootExitCode, $timer.Elapsed.TotalSeconds)
        Write-InstallerPhaseEvidence -LogDirectory $LogDirectory -Phase $Phase `
            -Tracked $tracked -ElapsedSeconds $timer.Elapsed.TotalSeconds `
            -StartedUtc $startedUtc -Executable $resolved -ProcessId $rootPid `
            -TimeoutSeconds $TimeoutSeconds -ExitCode $rootExitCode `
            -TimedOut $false -Outcome $outcome -InnoLogPath $innoLogPath

        return [pscustomobject]@{
            Phase          = $Phase
            ExitCode       = $rootExitCode
            ElapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
            TimedOut       = $false
            InnoLogPath    = $innoLogPath
            ProcessId      = $rootPid
            ProcessTree    = $snapshot
        }
    } catch {
        $timer.Stop()
        $outcome = if ($timedOut) { 'timeout' } else { 'failed' }
        # Capture any installer worker that started since the last poll so the
        # timeout cleanup does not orphan it.
        try {
            [void](Update-TrackedState -Tracked $tracked `
                -DetachedProcessNames $DetachedProcessNames `
                -ProcessEvents $processEvents -ProcessTrace $processTrace `
                -ProcessJob $processJob -RootId $rootPid)
        } catch {
            Write-Verbose "Could not refresh the process tree after failure: $_"
        }
        $snapshot = @(Get-TrackedSnapshot -Tracked $tracked)
        Write-Warning ("[installer:{0}] {1} after {2:N1}s. {3}" -f
            $Phase, $outcome, $timer.Elapsed.TotalSeconds, (Format-TrackedSummary -Tracked $tracked))

        # Fail closed, but terminate only processes this phase started. The
        # detached product agent is intentionally left to the caller's cleanup.
        foreach ($entry in @($tracked.Values)) {
            if ($entry.Detached -or $entry.Ended) { continue }
            try {
                $owned = $entry.Process
                if ($null -eq $owned) { $owned = [Diagnostics.Process]::GetProcessById([int]$entry.Id) }
                if (-not $owned.HasExited) { $owned.Kill() }
            } catch {
                Write-Verbose "Could not terminate phase-owned pid $($entry.Id): $_"
            }
        }

        Write-InstallerPhaseEvidence -LogDirectory $LogDirectory -Phase $Phase `
            -Tracked $tracked -ElapsedSeconds $timer.Elapsed.TotalSeconds `
            -StartedUtc $startedUtc -Executable $resolved -ProcessId $rootPid `
            -TimeoutSeconds $TimeoutSeconds -ExitCode $rootExitCode `
            -TimedOut $timedOut -Outcome $outcome -InnoLogPath $innoLogPath
        throw
    } finally {
        Stop-ProcessTrace -ProcessTrace $processTrace
        Close-ProcessJob -ProcessJob $processJob
        foreach ($entry in @($tracked.Values)) {
            if ($null -ne $entry.Process) {
                try { $entry.Process.Dispose() } catch { }
            }
        }
    }
}

function Get-NanoDictateProcessesUnderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [string[]]$ProcessNames = @('NanoDictate.App')
    )

    $full = [IO.Path]::GetFullPath($InstallDirectory)
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $full.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
    $found = @()
    foreach ($name in $ProcessNames) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                $path = $process.Path
                if (-not [string]::IsNullOrWhiteSpace($path) -and
                    [IO.Path]::GetFullPath($path).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $found += $process
                }
            } catch {
                # A process that exits while inspected must not fail cleanup.
            }
        }
    }
    return $found
}

function Stop-NanoDictateProcessesUnderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $stopped = 0
    foreach ($process in @(Get-NanoDictateProcessesUnderPath -InstallDirectory $InstallDirectory)) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $stopped++
        } catch {
            Write-Verbose "Could not stop NanoDictate pid $($process.Id): $_"
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $remaining = @(Get-NanoDictateProcessesUnderPath -InstallDirectory $InstallDirectory)
        if ($remaining.Count -eq 0) { return $stopped }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "NanoDictate process(es) under '$InstallDirectory' did not exit within $TimeoutSeconds seconds: $(($remaining | ForEach-Object { $_.Id }) -join ', ')"
        }
        Start-Sleep -Milliseconds 100
    } while ($true)
}

function Wait-NanoDictateBackgroundProcess {
    <#
    .SYNOPSIS
      Wait for the installed background agent and reject duplicate instances.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30,
        [ValidateRange(0, 30000)][int]$SettleMilliseconds = 1500
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $seen = @(Get-NanoDictateProcessesUnderPath -InstallDirectory $InstallDirectory)
        if ($seen.Count -gt 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { return @() }
        Start-Sleep -Milliseconds 200
    } while ($true)

    if ($SettleMilliseconds -gt 0) { Start-Sleep -Milliseconds $SettleMilliseconds }
    $seen = @(Get-NanoDictateProcessesUnderPath -InstallDirectory $InstallDirectory)
    if ($seen.Count -gt 1) {
        throw "Expected exactly one NanoDictate background agent under '$InstallDirectory', found $($seen.Count) (pids: $(($seen | ForEach-Object { $_.Id }) -join ', '))."
    }
    return $seen
}

function Start-NanoDictateBackgroundIfNeeded {
    <#
    .SYNOPSIS
      Ensure the installed background agent runs exactly once after setup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $existing = @(Wait-NanoDictateBackgroundProcess -InstallDirectory $InstallDirectory `
        -TimeoutSeconds ([Math]::Min($TimeoutSeconds, 10)) -SettleMilliseconds 0)
    if ($existing.Count -gt 0) {
        return @(Wait-NanoDictateBackgroundProcess -InstallDirectory $InstallDirectory `
            -TimeoutSeconds $TimeoutSeconds)
    }

    $exe = Join-Path $InstallDirectory 'NanoDictate.App.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Cannot start NanoDictate because the installed executable is missing: $exe"
    }
    Start-Process -FilePath $exe -ArgumentList '--background' | Out-Null
    return @(Wait-NanoDictateBackgroundProcess -InstallDirectory $InstallDirectory `
        -TimeoutSeconds $TimeoutSeconds)
}

function Assert-NanoDictatePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [string[]]$RequiredNames = $script:NanoDictatePayloadNames
    )

    foreach ($name in $RequiredNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDirectory $name) -PathType Leaf)) {
            throw "Installed NanoDictate payload is missing $name."
        }
    }
}

function Get-NanoDictateStartupValue {
    [CmdletBinding()]
    param()

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $properties = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($null -eq $properties) { return '' }
    $entry = $properties.PSObject.Properties['NanoDictate']
    if ($null -eq $entry) { return '' }
    return [string]$entry.Value
}

function Assert-NanoDictateStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)

    $expected = '"' + (Join-Path $InstallDirectory 'NanoDictate.App.exe') + '" --background'
    $actual = Get-NanoDictateStartupValue
    if ($actual -ne $expected) {
        throw "NanoDictate logon startup is '$actual' instead of the stable installed path '$expected'."
    }
}

function Assert-NanoDictateStartupCleared {
    [CmdletBinding()]
    param()

    $actual = Get-NanoDictateStartupValue
    if ($actual) {
        throw "NanoDictate uninstall left an orphaned logon startup entry: $actual"
    }
}

function Assert-NanoDictateUserDataPreserved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Expected = 'preserve'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "NanoDictate lifecycle deleted user data: $Path"
    }
    if ((Get-Content -LiteralPath $Path -Raw) -cne $Expected) {
        throw "NanoDictate lifecycle changed user data: $Path"
    }
}

Export-ModuleMember -Function @(
    'Invoke-BoundedInstallerProcess'
    'Get-NanoDictateProcessesUnderPath'
    'Stop-NanoDictateProcessesUnderPath'
    'Wait-NanoDictateBackgroundProcess'
    'Start-NanoDictateBackgroundIfNeeded'
    'Assert-NanoDictatePayload'
    'Get-NanoDictateStartupValue'
    'Assert-NanoDictateStartup'
    'Assert-NanoDictateStartupCleared'
    'Assert-NanoDictateUserDataPreserved'
)
