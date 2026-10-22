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

$workerProcessSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace NanoDictate.InstallerRunner.Fixture
{
    public static class WorkerProcess
    {
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
        private static extern bool CreateProcessW(
            string lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static int Start(string applicationPath, string commandLine)
        {
            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
            PROCESS_INFORMATION info;
            StringBuilder mutableCommandLine = new StringBuilder(commandLine);
            if (!CreateProcessW(applicationPath, mutableCommandLine, IntPtr.Zero, IntPtr.Zero,
                false, 0, IntPtr.Zero, null, ref startup, out info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try
            {
                return info.dwProcessId;
            }
            finally
            {
                if (info.hThread != IntPtr.Zero) { CloseHandle(info.hThread); }
                if (info.hProcess != IntPtr.Zero) { CloseHandle(info.hProcess); }
            }
        }
    }
}
'@

function Start-BootstrapWorker {
    param([string]$ApplicationPath, [string[]]$Arguments)

    $quotedArguments = @($Arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) })
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # A restricted token can reject .NET's inherited stdin pipe. Launch the
        # worker like the production runner does: CreateProcessW without handle
        # inheritance or shell execution.
        if (-not ('NanoDictate.InstallerRunner.Fixture.WorkerProcess' -as [type])) {
            Add-Type -TypeDefinition $workerProcessSource -Language CSharp -ErrorAction Stop
        }
        $commandLine = '"' + $ApplicationPath + '"'
        if ($quotedArguments.Count -gt 0) {
            $commandLine += ' ' + ($quotedArguments -join ' ')
        }
        return [NanoDictate.InstallerRunner.Fixture.WorkerProcess]::Start(
            $ApplicationPath, $commandLine)
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ApplicationPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.Arguments = $quotedArguments -join ' '
    $child = [Diagnostics.Process]::Start($startInfo)
    # A closed stdin keeps a mis-bound worker from blocking on a prompt.
    $child.StandardInput.Close()
    return $child.Id
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
        $workerArguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $WorkerScript,
            '-Mode', 'sleep',
            '-SleepMilliseconds', [string]$WorkerSleepMilliseconds,
            '-ExitCode', [string]$WorkerExitCode
        )
        # The worker writes its own pid so the qualification fixture can prove
        # it actually ran instead of only seeing the bootstrap's launch record.
        if ($PidFile) { $workerArguments += @('-PidFile', "$PidFile.worker") }
        try {
            $workerPid = Start-BootstrapWorker -ApplicationPath $pwshPath `
                -Arguments $workerArguments
        } catch {
            throw "Could not start the bootstrap worker: $($_.Exception.Message)"
        }
        Save-Pid $workerPid
        Start-Sleep -Milliseconds ([Math]::Max(0, $BootstrapDelayMilliseconds))
        exit $ExitCode
    }
}
