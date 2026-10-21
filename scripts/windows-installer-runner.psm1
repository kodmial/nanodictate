#Requires -Version 5.1
<#
.SYNOPSIS
  Shared bounded runner for NanoDictate's Inno Setup installers and uninstaller.

.DESCRIPTION
  PowerShell's Start-Process -Wait waits for the whole process tree. Inno Setup
  starts the persistent NanoDictate background agent with a nowait [Run] entry,
  so a tree wait can remain blocked long after Setup itself succeeded.

  This runner starts the installer directly with System.Diagnostics.Process,
  waits for the installer root (and any Inno bootstrap/worker process) with a
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

function Get-ProcessTable {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $rows = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop
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

function ConvertTo-WindowsCommandLineArgument {
    param([string]$Argument)

    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            [void]$builder.Append([char]'\', ($backslashes * 2) + 1)
            [void]$builder.Append([char]'"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]'\', $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]'\', $backslashes * 2)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Update-TrackedProcesses {
    param(
        [hashtable]$Tracked,
        [string[]]$DetachedProcessNames
    )

    $table = @(Get-ProcessTable)
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
                try { $process = [Diagnostics.Process]::GetProcessById([int]$child.Id) } catch { }
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
        if ($null -eq $process) {
            try {
                $process = [Diagnostics.Process]::GetProcessById([int]$entry.Id)
                $entry.Process = $process
            } catch {
                $entry.Ended = $true
            }
        }
        if ($null -ne $process) {
            try {
                if ($process.HasExited) {
                    $entry.Ended = $true
                    if ($null -eq $entry.ExitCode) { $entry.ExitCode = [int]$process.ExitCode }
                }
            } catch {
                $entry.Ended = $true
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
        $ArgumentList = @($ArgumentList) + @("/LOG=`"$innoLogPath`"")
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolved
    $startInfo.UseShellExecute = $false
    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in @($ArgumentList)) {
            if ($null -ne $argument) { $startInfo.ArgumentList.Add([string]$argument) }
        }
    } else {
        # Windows PowerShell 5.1 runs on .NET Framework, which has no
        # ProcessStartInfo.ArgumentList. Quote arguments with the standard
        # Windows command-line rules instead of passing one unescaped string.
        $startInfo.Arguments = (@($ArgumentList | ForEach-Object {
            ConvertTo-WindowsCommandLineArgument ([string]$_)
        }) -join ' ')
    }

    $logLabel = if ($innoLogPath) { [IO.Path]::GetFileName($innoLogPath) } else { 'none' }
    Write-Host ("[installer:{0}] start exe={1} timeout={2}s log={3}" -f
        $Phase, [IO.Path]::GetFileName($resolved), $TimeoutSeconds, $logLabel)

    $rootPid = 0
    $rootName = ''
    $tracked = @{}
    $rootExitCode = $null
    $snapshot = @()
    $outcome = 'unknown'
    $timedOut = $false
    $deadline = $startedUtc.AddSeconds($TimeoutSeconds)

    try {
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
            Process  = $process
            ExitCode = $null
            Ended    = $false
        }

        while (-not $process.HasExited) {
            Update-TrackedProcesses -Tracked $tracked `
                -DetachedProcessNames $DetachedProcessNames
            if ([DateTime]::UtcNow -ge $deadline) {
                $timedOut = $true
                throw [TimeoutException]::new(
                    "Installer phase '$Phase' timed out after $TimeoutSeconds seconds while the installer root was still running.")
            }
            [void]$process.WaitForExit(200)
        }

        $rootExitCode = [int]$process.ExitCode

        # A bootstrap can exit before the real setup worker. Wait only for
        # installer-like descendants; never for the persistent product agent.
        while ($true) {
            Update-TrackedProcesses -Tracked $tracked `
                -DetachedProcessNames $DetachedProcessNames
            $remaining = @($tracked.Values | Where-Object {
                $_.Id -ne $rootPid -and -not $_.Detached -and -not $_.Ended -and
                ($_.Name -eq $rootName -or $_.Name -match $InstallerProcessNamePattern)
            })
            if ($remaining.Count -eq 0) { break }
            if ([DateTime]::UtcNow -ge $deadline) {
                $timedOut = $true
                throw [TimeoutException]::new(
                    "Installer phase '$Phase' timed out after $TimeoutSeconds seconds waiting for installer worker process(es): $((($remaining | ForEach-Object { "$($_.Name)[$($_.Id)]" }) -join ', ')).")
            }
            Start-Sleep -Milliseconds 150
        }

        Update-TrackedProcesses -Tracked $tracked `
            -DetachedProcessNames $DetachedProcessNames

        if ($rootExitCode -ne 0) {
            throw "Installer phase '$Phase' exited with code $rootExitCode."
        }

        $workerFailures = @($tracked.Values | Where-Object {
            $_.Id -ne $rootPid -and -not $_.Detached -and $_.Ended -and
            $null -ne $_.ExitCode -and $_.ExitCode -ne 0 -and
            ($_.Name -eq $rootName -or $_.Name -match $InstallerProcessNamePattern)
        })
        if ($workerFailures.Count -gt 0) {
            $first = $workerFailures[0]
            throw "Installer worker '$($first.Name)' (pid $($first.Id)) exited with code $($first.ExitCode)."
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
            Update-TrackedProcesses -Tracked $tracked `
                -DetachedProcessNames $DetachedProcessNames
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
