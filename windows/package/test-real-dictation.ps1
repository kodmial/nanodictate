#Requires -Version 7.0
<#
.SYNOPSIS
  Opt-in qualification of real NanoDictate dictation on a Windows desktop.

.DESCRIPTION
  Proves (or disproves) the real Windows product path on the machine that runs
  it: install the actual NanoDictate distribution, start the background agent,
  focus Notepad, inject a real Double-Alt, observe the HUD, route a test-owned
  spoken WAV through a virtual capture endpoint into the product's genuine
  WASAPI capture, let the configured real STT provider answer, and assert the
  resulting text in Notepad.

  The script never mocks a transcript or calls the provider itself. Every
  segment is reported as observed PASS/FAIL, and the run ends with exactly one
  of the statuses required by issue #254:
    FULL E2E VERIFIED / PARTIAL VERIFIED / NOT VERIFIED / HOSTED RUNNER BLOCKED

  A missing virtual microphone, a provider failure or a headless session is
  recorded as an observed limitation; it is never converted into a pass.

.PARAMETER ProbeOnly
  Bounded feasibility probe: records the session, desktop and audio-endpoint
  facts without installing or launching the product. Useful to decide whether a
  full qualification is even meaningful on a runner.

.PARAMETER PhraseText
  The test-owned phrase the WAV says and the text asserted in Notepad. Use at
  least two unambiguous ordinary words: the assertion requires every
  normalized token to appear in order, so a brand name that a model may split
  into several words makes a good run look like a failure.

.PARAMETER PhraseWav
  Optional prerecorded 16-bit PCM WAV with the phrase. When empty the script
  synthesizes the phrase with the runner's SAPI voice.

.PARAMETER ConfigPath
  Optional provider config copied to %APPDATA%\NanoDictate\config.toml before
  launch. It is never uploaded or printed; use it to supply an already
  configured real provider without committing credentials.
#>
[CmdletBinding()]
param(
    [ValidateSet('published', 'candidate')][string]$Source = 'published',
    [string]$Version = '',
    [string]$Repository = 'kodmial/nanodictate',
    [string]$InstallerPath = '',
    [switch]$ProbeOnly,
    [string]$PhraseText = 'quick brown fox jumps',
    [string]$PhraseWav = '',
    [string]$ConfigPath = '',
    [ValidateRange(10, 600)][int]$AppLaunchTimeoutSeconds = 60,
    [ValidateRange(1, 60)][int]$HudTimeoutSeconds = 10,
    [ValidateRange(5, 600)][int]$ResultTimeoutSeconds = 180,
    [ValidateRange(1, 30)][int]$AudioSeconds = 4,
    [string]$EvidenceDirectory = '',
    [string]$LogDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repoRoot 'scripts/windows-installer-runner.psm1') -Force
Import-Module (Join-Path $repoRoot 'scripts/windows-real-dictation.psm1') -Force
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $repoRoot 'windows/artifacts/real-dictation'
}
if (-not $LogDirectory) {
    $LogDirectory = Join-Path $repoRoot 'windows/artifacts/installer-logs'
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$startedAt = [DateTime]::UtcNow
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { Join-Path $EvidenceDirectory '.tmp' }
$tempRoot = Join-Path $tempBase ('nd-real-dictation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$segments = [System.Collections.Generic.List[object]]::new()
$limitations = [System.Collections.Generic.List[string]]::new()
$evidenceFiles = [System.Collections.Generic.List[string]]::new()
$installedDirectory = $null
$installationOwned = $false
$notepadProcess = $null
$notepadProcessId = 0
$notepadWindow = $null
$installerSha256 = ''
$configTarget = $null
$configBackupPath = $null
$configExistedBefore = $false
$configApplied = $false
$agentProcessIds = @()
$testedVersion = $Version
# A candidate installer is built from the workflow checkout, so that SHA is
# the tested commit. A published installer must be attributed to its own
# release commit, which is resolved later; never fall back to the checkout.
$testedCommit = if ($Source -eq 'candidate' -and $env:GITHUB_SHA) { $env:GITHUB_SHA } else { 'unknown' }
$providerLabel = [pscustomobject]@{ Provider = 'unknown'; Model = 'unknown' }
$audioInventory = $null
$audioRoute = $null
$sessionProbe = $null
$guiFlags = [pscustomobject]@{
    AppLaunched = $false
    EditorFocused = $false
    DoubleAltDelivered = $false
    HudAppeared = $false
    RecordingPhase = $false
}
$audioFlags = [pscustomobject]@{
    VirtualCaptureEndpointPresent = $false
    DefaultCaptureIsVirtual = $false
    WavPlayed = $false
    PhraseMatched = $false
}
$fatal = $null

function Add-Segment {
    param([string]$Name, [bool]$Observed, [string]$Detail)
    $segments.Add([pscustomobject]@{
        name = $Name
        observed = [bool]$Observed
        detail = $Detail
    })
}

function Add-Limitation {
    param([string]$Detail)
    if (-not $limitations.Contains($Detail)) {
        $limitations.Add($Detail)
    }
}

function Add-EvidenceFile {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path) -and -not $evidenceFiles.Contains($Path)) {
        $evidenceFiles.Add($Path)
    }
}

function Save-EvidenceScreenshot {
    <# Captures a BMP and records both the evidence file and the observation. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('window', 'desktop')][string]$Kind,
        [long]$Handle = 0
    )
    $path = Join-Path $EvidenceDirectory ("$Name.bmp")
    $result = Save-RealDictationScreenshot -Kind $Kind -Handle $Handle -Path $path
    $windowEvidence = if ($Kind -eq 'window') { [bool]$result.WindowEvidence } else { $true }
    if ($result.Saved -and $result.NonBlankPixels -gt 0 -and $windowEvidence) {
        Add-EvidenceFile $result.Path
        Add-Segment -Name $Name -Observed $true -Detail (
            "{0} screenshot via {1} ({2}x{3}, {4} non-blank pixels)" -f
                $Kind, $result.Method, $result.Width, $result.Height, $result.NonBlankPixels)
    } elseif ($result.Saved -and $result.NonBlankPixels -gt 0) {
        # A BitBlt fallback can capture whatever covers the window, so it is
        # kept as screen-region evidence but never as verified window content.
        Add-EvidenceFile $result.Path
        Add-Segment -Name $Name -Observed $false -Detail (
            "screen-region capture via {0} ({1}x{2}); a PrintWindow capture was unavailable, so this is not window evidence" -f
                $result.Method, $result.Width, $result.Height)
        Add-Limitation "The $Kind screenshot for '$Name' is a screen-region copy because PrintWindow did not complete; it can show an overlapping window and is not proof of the HUD content."
    } elseif ($result.Saved) {
        Add-EvidenceFile $result.Path
        Add-Segment -Name $Name -Observed $false -Detail "$Kind screenshot at $path contains no non-blank pixels"
        Add-Limitation "The $Kind screenshot for '$Name' is blank; it is not visual proof of the HUD or editor."
    } else {
        Add-Segment -Name $Name -Observed $false -Detail "$Kind screenshot could not be saved to $path"
        Add-Limitation "The $Kind screenshot for '$Name' was not captured; visual evidence is missing."
    }
}

function Write-Evidence {
    $verdict = Get-RealDictationVerdict -Gui $guiFlags -Audio $audioFlags -ProbeOnly:$ProbeOnly
    $evidence = [pscustomobject]@{
        schema = 'nanodictate.windows-real-dictation/1'
        generatedAt = [DateTime]::UtcNow.ToString('o')
        startedAt = $startedAt.ToString('o')
        status = $verdict.Status
        fullyVerified = $verdict.FullyVerified
        unverifiedSegments = $verdict.UnverifiedSegments
        tested = [pscustomobject]@{
            source = $Source
            repository = $Repository
            version = if ($testedVersion) { $testedVersion } else { 'unknown' }
            commit = $testedCommit
            installer = if ($InstallerPath) { $InstallerPath } else { '' }
            installerSha256 = $installerSha256
            phraseText = $PhraseText
            phraseWav = $PhraseWav
            provider = $providerLabel.Provider
            model = $providerLabel.Model
        }
        environment = [pscustomobject]@{
            osDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
            osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            powershell = $PSVersionTable.PSVersion.ToString()
            runnerImage = if ($env:ImageOS) { "$($env:ImageOS) $($env:ImageVersion)" } else { '' }
            runnerOs = [string]$env:RUNNER_OS
            processorCount = [Environment]::ProcessorCount
            run = [pscustomobject]@{
                runId = [string]$env:GITHUB_RUN_ID
                runAttempt = [string]$env:GITHUB_RUN_ATTEMPT
                runUrl = if ($env:GITHUB_RUN_ID -and $env:GITHUB_REPOSITORY) {
                    "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
                } else { '' }
                workflow = [string]$env:GITHUB_WORKFLOW
                job = [string]$env:GITHUB_JOB
                ref = [string]$env:GITHUB_REF
                sha = [string]$env:GITHUB_SHA
            }
            session = $sessionProbe
            audio = [pscustomobject]@{
                defaultCapture = if ($audioInventory) { $audioInventory.DefaultCapture } else { $null }
                endpoints = @(if ($audioInventory) { $audioInventory.Endpoints })
                route = $audioRoute
            }
        }
        segments = @($segments)
        limitations = @($limitations)
        evidenceFiles = @($evidenceFiles)
    }
    $evidencePath = Join-Path $EvidenceDirectory 'evidence.json'
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $summary = Format-RealDictationSummary -Evidence $evidence
    $summaryPath = Join-Path $EvidenceDirectory 'summary.md'
    Set-Content -LiteralPath $summaryPath -Value $summary -Encoding utf8
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
    if ($env:GITHUB_OUTPUT) {
        "status=$($evidence.status)" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
    }
    Write-Host ''
    Write-Host "REAL_DICTATION_STATUS=$($evidence.status)"
    foreach ($segment in @($segments)) {
        $label = if ($segment.observed) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1}: {2}" -f $label, $segment.name, $segment.detail)
    }
    foreach ($limitation in @($limitations)) {
        Write-Host "LIMITATION: $limitation"
    }
    if (-not $verdict.FullyVerified) {
        Write-Host "::warning title=Windows real dictation not fully verified::$($evidence.status)"
    }
    return $evidence
}

function Get-InstalledPayload {
    param([string]$Directory)
    foreach ($name in @('NanoDictate.App.exe', 'NanoDictate.App.dll', 'NanoDictate.App.runtimeconfig.json',
                        'nanodictate_core.dll', 'config.example.toml', 'coreclr.dll', 'hostfxr.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $name))) {
            throw "Installed NanoDictate payload is missing $name under $Directory"
        }
    }
}

function Resolve-InstallerAsset {
    $resolvedVersion = $Version
    $headers = @{
        'User-Agent' = 'NanoDictate-windows-real-dictation'
        'Accept' = 'application/vnd.github+json'
    }
    if ($resolvedVersion) {
        if ($resolvedVersion -notmatch '^v?(\d+\.\d+\.\d+)$') {
            throw "Version must be a stable semver like 0.1.46; got '$resolvedVersion'"
        }
        $resolvedVersion = $Matches[1]
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/v$resolvedVersion" `
            -Headers $headers -TimeoutSec 60
    } else {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" `
            -Headers $headers -TimeoutSec 60
        $resolvedVersion = ([string]$release.tag_name).TrimStart('v')
    }
    if ($resolvedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Unexpected release tag for the published installer: $($release.tag_name)"
    }
    $releaseCommit = $null
    try {
        # Identify the source commit of the published tag, not the workflow
        # checkout: a published installer must be attributable to its release.
        $releaseCommit = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/commits/v$resolvedVersion" `
            -Headers $headers -TimeoutSec 60
    } catch {
        $releaseCommit = $null
    }
    if ($null -ne $releaseCommit -and [string]$releaseCommit.sha -match '^[0-9a-fA-F]{40}$') {
        $script:testedCommit = ([string]$releaseCommit.sha).ToLowerInvariant()
        Add-Segment -Name 'published release commit resolved' -Observed $true -Detail "v$resolvedVersion -> $($script:testedCommit)"
    } else {
        # An unresolved or malformed release commit must stay unknown rather
        # than borrowing the workflow checkout SHA recorded in run.sha.
        $script:testedCommit = 'unknown'
        Add-Limitation "Could not resolve the commit for published release v$resolvedVersion; evidence records the tested commit as unknown and the workflow checkout only under environment.run.sha."
    }
    $assetName = "nanodictate-$resolvedVersion-windows-x64-setup.exe"
    $asset = @($release.assets) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if ($null -eq $asset) {
        throw "Release v$resolvedVersion does not publish $assetName"
    }
    $sumsAsset = @($release.assets) | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if ($null -eq $sumsAsset) {
        throw "Release v$resolvedVersion does not publish SHA256SUMS.txt"
    }
    $sumsPath = Join-Path $tempRoot 'SHA256SUMS.txt'
    Invoke-WebRequest -Uri $sumsAsset.browser_download_url -OutFile $sumsPath -MaximumRedirection 5 -TimeoutSec 120
    $sums = Get-Content -LiteralPath $sumsPath -Raw
    $pattern = '(?im)^([a-f0-9]{64})\s+\*?' + [regex]::Escape($assetName) + '\s*$'
    $match = [regex]::Match($sums, $pattern)
    if (-not $match.Success) {
        throw "Published SHA256SUMS.txt does not list $assetName"
    }
    $expected = $match.Groups[1].Value.ToLowerInvariant()
    $target = Join-Path $tempRoot $assetName
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -MaximumRedirection 5 -TimeoutSec 300
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Published installer SHA-256 mismatch: expected $expected, got $actual"
    }
    $script:testedVersion = $resolvedVersion
    $script:installerSha256 = $actual
    Add-Segment -Name 'published release asset selected' -Observed $true -Detail "v$resolvedVersion $assetName matches SHA256SUMS.txt"
    return $target
}

function Get-ProviderLabel {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Provider = 'unknown'; Model = 'unknown' }
    }
    $text = Get-Content -LiteralPath $Path -Raw
    $active = [regex]::Match($text, '(?m)^\s*active_provider\s*=\s*"([^"]+)"')
    $provider = if ($active.Success) { $active.Groups[1].Value } else { 'unknown' }
    $model = 'unknown'
    if ($provider -ne 'unknown') {
        $section = [regex]::Match($text,
            '(?ms)^\s*\[providers\.' + [regex]::Escape($provider) + '\]\s*(.*?)(?=^\s*\[|\z)')
        if ($section.Success) {
            $modelMatch = [regex]::Match($section.Groups[1].Value, '(?m)^\s*model\s*=\s*"([^"]*)"')
            if ($modelMatch.Success -and $modelMatch.Groups[1].Value) {
                $model = $modelMatch.Groups[1].Value
            }
        }
    }
    return [pscustomobject]@{ Provider = $provider; Model = $model }
}

function Find-RealDictationHudWindow {
    <#
      Finds the visible NanoDictate HUD only among the launched agent's
      processes, so an unrelated NanoDictate window cannot stand in for the
      product under test.
    #>
    param([Parameter(Mandatory)][int[]]$ProcessIds)

    foreach ($processId in $ProcessIds) {
        $window = @(Get-RealDictationProcessWindow -ProcessId $processId |
            Where-Object { $_.Visible -and $_.Title -eq 'NanoDictate' } |
            Select-Object -First 1)
        if ($window.Count -gt 0) {
            return $window[0]
        }
    }
    return $null
}

function Get-RealDictationHudBaseline {
    <# Snapshots the launched agent's HUD windows before activation. #>
    param([Parameter(Mandatory)][int[]]$ProcessIds)

    $windows = [System.Collections.Generic.List[object]]::new()
    foreach ($processId in $ProcessIds) {
        foreach ($window in @(Get-RealDictationProcessWindow -ProcessId $processId |
                Where-Object { $_.Visible -and $_.Title -eq 'NanoDictate' })) {
            $windows.Add([pscustomobject]@{
                Handle = [long]$window.Handle
                Width = [int]$window.Width
                Height = [int]$window.Height
            })
        }
    }
    return @($windows)
}

function Test-RealDictationHudChanged {
    <#
      A HUD counts as observed only when it appears after the baseline or
      changes geometry relative to it. A pre-existing window that never
      changes cannot credit activation.
    #>
    param(
        [Parameter(Mandatory)]$Window,
        [object[]]$Baseline = @()
    )

    $baselineMatch = @($Baseline | Where-Object { $null -ne $_ -and [long]$_.Handle -eq [long]$Window.Handle })
    if ($baselineMatch.Count -eq 0) {
        return $true
    }
    return ([int]$baselineMatch[0].Width -ne [int]$Window.Width -or
        [int]$baselineMatch[0].Height -ne [int]$Window.Height)
}

function Watch-RealDictationHud {
    <#
      Polls for the launched agent's NanoDictate HUD and records its geometry.
      The recording panel is 178 points tall versus 150 for every other phase,
      so the observed height (scaled by the panel width) distinguishes a real
      recording HUD from a starting/error overlay without reading internals.
      Only a post-hotkey appearance or transition from the baseline counts.
    #>
    param(
        [Parameter(Mandatory)][int[]]$AgentProcessIds,
        [object[]]$Baseline = @(),
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )
    $observations = [System.Collections.Generic.List[object]]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $firstSeenMs = $null
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $window = Find-RealDictationHudWindow -ProcessIds $AgentProcessIds
        if ($null -ne $window -and (Test-RealDictationHudChanged -Window $window -Baseline $Baseline)) {
            if ($null -eq $firstSeenMs) {
                $firstSeenMs = [int]$stopwatch.ElapsedMilliseconds
            }
            $observations.Add($window)
            # Stop as soon as the recording panel is observed so the spoken
            # phrase is fed immediately instead of after an arbitrary delay.
            $scale = if ($window.Width -gt 0) { $window.Width / 220.0 } else { 1.0 }
            if ([math]::Abs($window.Height - (178.0 * $scale)) -le (4.0 * $scale)) {
                break
            }
        }
        Start-Sleep -Milliseconds 50
    }
    $recording = $false
    $phases = @()
    foreach ($observation in $observations) {
        $scale = if ($observation.Width -gt 0) { $observation.Width / 220.0 } else { 1.0 }
        $recordingHeight = 178.0 * $scale
        $idleHeight = 150.0 * $scale
        $phase = if ([math]::Abs($observation.Height - $recordingHeight) -le (4.0 * $scale)) {
            $recording = $true
            'recording'
        } elseif ([math]::Abs($observation.Height - $idleHeight) -le (4.0 * $scale)) {
            'starting-or-error'
        } else {
            'unknown'
        }
        $phases += $phase
    }
    return [pscustomobject]@{
        FirstSeenMilliseconds = $firstSeenMs
        Observations = @($observations)
        Phases = @($phases)
        RecordingObserved = [bool]$recording
        LastSeen = if ($observations.Count -gt 0) { $observations[$observations.Count - 1] } else { $null }
    }
}

function Wait-RealDictationHudHidden {
    param(
        [Parameter(Mandatory)][int[]]$ProcessIds,
        [int]$TimeoutSeconds = 10
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($null -eq (Find-RealDictationHudWindow -ProcessIds $ProcessIds)) {
            return [pscustomobject]@{ Hidden = $true; ElapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds }
        }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Hidden = $false; ElapsedMilliseconds = [int]$stopwatch.ElapsedMilliseconds }
}

try {
    if (-not (Test-RealDictationPlatform)) {
        throw 'The real-dictation qualification requires Windows.'
    }
    if ((Get-DictationTokens -Text $PhraseText).Count -lt 2) {
        throw "PhraseText must contain at least two words so the assertion cannot pass on an unrelated transcript; got '$PhraseText'."
    }

    # ---------------------------------------------------------------
    # Environment, session and audio feasibility (always recorded).
    # ---------------------------------------------------------------
    $sessionProbe = Get-RealDictationSessionProbe
    Add-Segment -Name 'interactive session' -Observed ([bool]$sessionProbe.InputDesktopAvailable) -Detail (
        "session {0}, desktop '{1}', input desktop available: {2}" -f
            $sessionProbe.SessionId, $sessionProbe.DesktopName, $sessionProbe.InputDesktopAvailable)
    if (-not $sessionProbe.InputDesktopAvailable) {
        Add-Limitation 'OpenInputDesktop failed: the job is not attached to an interactive input desktop, so real keyboard injection and UI observation cannot be performed in this session.'
    }
    if (-not $sessionProbe.UserInteractive) {
        Add-Limitation 'Environment.UserInteractive is false; the runner process is not attached to an interactive window station.'
    }

    $audioInventory = Get-RealDictationAudioEndpoint -DefaultFlow capture
    $audioRoute = Resolve-VirtualAudioRoute -Endpoints $audioInventory.Endpoints -DefaultCaptureEndpoint $audioInventory.DefaultCapture
    $audioFlags.VirtualCaptureEndpointPresent = [bool]($null -ne $audioRoute.VirtualCapture)
    $audioFlags.DefaultCaptureIsVirtual = [bool]$audioRoute.DefaultCaptureIsVirtual

    $captureNames = @($audioInventory.Endpoints | Where-Object { $_.Flow -eq 'capture' } | ForEach-Object { "$($_.Name) [$($_.State)]" })
    $renderNames = @($audioInventory.Endpoints | Where-Object { $_.Flow -eq 'render' } | ForEach-Object { "$($_.Name) [$($_.State)]" })
    Add-Segment -Name 'audio endpoints enumerated' -Observed ($captureNames.Count -gt 0 -or $renderNames.Count -gt 0) -Detail (
        "capture: {0} | render: {1}" -f (($captureNames -join '; ') -replace '\|', '/'), (($renderNames -join '; ') -replace '\|', '/'))
    Add-Segment -Name 'virtual capture endpoint present' -Observed $audioFlags.VirtualCaptureEndpointPresent -Detail $audioRoute.Reason
    if (-not $audioFlags.VirtualCaptureEndpointPresent) {
        Add-Limitation $audioRoute.Reason
        Add-Limitation 'No virtual capture endpoint means a test-owned WAV cannot enter NanoDictate''s genuine WASAPI input; loading an audio file in the harness is not microphone capture.'
    } elseif (-not $audioFlags.DefaultCaptureIsVirtual) {
        Add-Limitation $audioRoute.Reason
        Add-Limitation 'The product always opens the default console capture endpoint, so a non-default virtual cable cannot feed real WASAPI capture without changing the system default device.'
    } elseif ($null -eq $audioRoute.PairedRender) {
        Add-Limitation "Virtual capture endpoint found but no render endpoint can feed it: $($audioRoute.PairedRenderReason)"
    } else {
        Add-Segment -Name 'virtual audio route' -Observed $true -Detail $audioRoute.PairedRenderReason
    }

    if ($ProbeOnly) {
        Add-Limitation 'Probe-only run: no installer, app, hotkey, microphone or provider action was attempted.'
        exit 0
    }

    # ---------------------------------------------------------------
    # Install the actual distribution.
    # ---------------------------------------------------------------
    if ($Source -eq 'published') {
        $installer = Resolve-InstallerAsset
    } else {
        if (-not $InstallerPath -or -not (Test-Path -LiteralPath $InstallerPath)) {
            throw "Candidate source requires -InstallerPath pointing at the exact-commit setup.exe; got '$InstallerPath'"
        }
        $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
        $script:installerSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        $testedVersion = if ($Version) { $Version } else { '0.0.0' }
        Add-Segment -Name 'exact-commit candidate selected' -Observed $true -Detail "local candidate $installer ($($script:installerSha256))"
    }

    $installedDirectory = Join-Path $env:LOCALAPPDATA 'Programs\NanoDictate'
    # A local qualification must never replace or uninstall an installation it
    # does not own. Refuse before stopping anything; the hosted workflow runs
    # on a disposable VM, so a fresh directory there is expected.
    $preexistingInstallation = @('NanoDictate.App.exe', 'unins000.exe') | Where-Object {
        Test-Path -LiteralPath (Join-Path $installedDirectory $_)
    } | Select-Object -First 1
    if ($preexistingInstallation) {
        throw "A pre-existing NanoDictate installation exists at $installedDirectory. The qualification only installs and uninstalls an installation it created; remove the existing installation first."
    }
    $installationOwned = $true
    $null = Stop-NanoDictateProcessesUnderPath -InstallDirectory $installedDirectory -TimeoutSeconds 15
    Invoke-BoundedInstallerProcess -FilePath $installer `
        -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') `
        -Phase 'real-dictation-install' -TimeoutSeconds 240 `
        -LogDirectory $LogDirectory -InnoLogFileName 'real-dictation-install.log' | Out-Null
    Get-InstalledPayload -Directory $installedDirectory

    $configTarget = Join-Path $env:APPDATA 'NanoDictate\config.toml'
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "ConfigPath does not exist: $ConfigPath"
        }
        # The application reads the user config only at launch, so stop the
        # installer-started agent before replacing it, then start exactly one.
        $null = Stop-NanoDictateProcessesUnderPath -InstallDirectory $installedDirectory -TimeoutSeconds 15
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configTarget) | Out-Null
        if (Test-Path -LiteralPath $configTarget) {
            # Preserve the local user config outside every uploaded directory
            # and restore it in the finally block on success and failure.
            $configBackupPath = Join-Path ([System.IO.Path]::GetTempPath()) (
                'nanodictate-real-dictation-config-' + [guid]::NewGuid().ToString('N') + '.toml')
            Copy-Item -LiteralPath $configTarget -Destination $configBackupPath -Force
            $configExistedBefore = $true
        }
        Copy-Item -LiteralPath $ConfigPath -Destination $configTarget -Force
        $configApplied = $true
        Add-Segment -Name 'operator config applied' -Observed $true -Detail 'copied the supplied provider config to %APPDATA%\NanoDictate\config.toml (never uploaded; any previous file is restored after the run)'
    }

    $agents = @(Start-NanoDictateBackgroundIfNeeded -InstallDirectory $installedDirectory -TimeoutSeconds 30)
    if ($agents.Count -ne 1) {
        throw "Expected exactly one NanoDictate background agent after install, found $($agents.Count)"
    }
    $agentProcessIds = @($agents | ForEach-Object { [int]$_.Id })
    $guiFlags.AppLaunched = $true
    Add-Segment -Name 'product installed and background agent started' -Observed $true -Detail (
        "one NanoDictate.App agent (pid $($agents[0].Id)) from $installedDirectory")

    if (-not (Test-Path -LiteralPath $configTarget)) {
        # First-use bootstrap happens just after the agent starts; allow the
        # documented copy to land before treating a missing config as fatal.
        $configDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $configTarget) -and [DateTime]::UtcNow -lt $configDeadline) {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not (Test-Path -LiteralPath $configTarget)) {
        throw "First-use config was not created at $configTarget"
    }
    $providerLabel = Get-ProviderLabel -Path $configTarget
    Add-Segment -Name 'real STT provider configured' -Observed ($providerLabel.Provider -ne 'unknown') -Detail (
        "active provider '$($providerLabel.Provider)', model '$($providerLabel.Model)' from the installed user config")

    # ---------------------------------------------------------------
    # Foreground editor + real Double-Alt + HUD.
    # ---------------------------------------------------------------
    $editorFileStem = 'nanodictate-real-dictation-' + [guid]::NewGuid().ToString('N')
    $editorPath = Join-Path $tempRoot ($editorFileStem + '.txt')
    # Seed the document with a run-unique marker. Title checks before and
    # after Ctrl+A/Ctrl+C cannot prove which tab supplied the clipboard text,
    # so the read itself must carry this marker; no other tab can contain it.
    $editorMarker = 'nanodictate-real-dictation-marker-' + [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($editorPath, $editorMarker + "`r`n")
    # A unique test filename scopes both window-discovery paths. Windows 11
    # Notepad can still host the file inside a window with unrelated tabs.
    $editorTitlePattern = [regex]::Escape($editorFileStem)
    $notepadProcess = Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $editorPath) -PassThru
    $notepadWindow = $null
    $notepadProcessId = [int]$notepadProcess.Id
    $startedUtc = [DateTime]::UtcNow
    $deadline = $startedUtc.AddSeconds($AppLaunchTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $windows = @(Get-RealDictationProcessWindow -ProcessId $notepadProcessId |
            Where-Object { $_.Title -match $editorTitlePattern })
        if ($windows.Count -gt 0) {
            $notepadWindow = $windows[0]
            break
        }
        # Windows 11 may hand notepad.exe to a packaged process, so the
        # launched pid can exit before its editor window appears. Fall back to
        # the editor window opened for this run's unique test file and use its
        # owning process from then on.
        if ([DateTime]::UtcNow -gt $startedUtc.AddSeconds(5)) {
            $fallback = Get-RealDictationWindowByTitlePattern -Pattern $editorTitlePattern
            if ($null -ne $fallback) {
                $notepadWindow = $fallback
                break
            }
        }
        Start-Sleep -Milliseconds 200
    }
    if ($null -eq $notepadWindow) {
        throw "Notepad did not expose a visible top-level window within $AppLaunchTimeoutSeconds seconds."
    }
    if (-not (Set-RealDictationForegroundWindow -Handle $notepadWindow.Handle)) {
        throw 'Could not move Notepad to the foreground; a real global hotkey test needs a focused editor.'
    }
    $foreground = Get-RealDictationForegroundWindow
    $guiFlags.EditorFocused = Test-RealDictationActiveEditorWindow -Foreground $foreground `
        -EditorHandle $notepadWindow.Handle -TitlePattern $editorTitlePattern
    $foregroundDescription = if ($null -eq $foreground) {
        '<no foreground window>'
    } else {
        "'$($foreground.Title)' (handle $($foreground.Handle), pid $($foreground.ProcessId))"
    }
    Add-Segment -Name 'foreground editor focused' -Observed $guiFlags.EditorFocused -Detail (
        "foreground is $foregroundDescription; expected this run's unique file '$editorFileStem' in window handle $($notepadWindow.Handle)")
    if (-not $guiFlags.EditorFocused) {
        Add-Limitation 'Notepad could not own the foreground; injection would not reach the intended focused editor.'
    }

    # A different Notepad tab can become active after the focus call while the
    # process id still matches, so verify the exact foreground handle and title
    # immediately before the hotkey and refuse to activate anything else.
    $activationForeground = Get-RealDictationForegroundWindow
    $activationTargetReady = Test-RealDictationActiveEditorWindow -Foreground $activationForeground `
        -EditorHandle $notepadWindow.Handle -TitlePattern $editorTitlePattern
    if (-not $activationTargetReady) {
        $null = Set-RealDictationForegroundWindow -Handle $notepadWindow.Handle
        $activationForeground = Get-RealDictationForegroundWindow
        $activationTargetReady = Test-RealDictationActiveEditorWindow -Foreground $activationForeground `
            -EditorHandle $notepadWindow.Handle -TitlePattern $editorTitlePattern
    }
    Add-Segment -Name 'test-owned editor tab active before activation' -Observed $activationTargetReady -Detail (
        "foreground is '{0}' (handle {1}, pid {2}); expected this run's unique file '{3}' in window handle {4}" -f
            $(if ($activationForeground) { $activationForeground.Title } else { '<none>' }),
            $(if ($activationForeground) { $activationForeground.Handle } else { 0 }),
            $(if ($activationForeground) { $activationForeground.ProcessId } else { 0 }),
            $editorFileStem, $notepadWindow.Handle)
    if (-not $activationTargetReady) {
        throw 'Refusing to send Double-Alt: the foreground handle/title is no longer this run''s test editor.'
    }

    $hudBaseline = @(Get-RealDictationHudBaseline -ProcessIds $agentProcessIds)
    Add-Segment -Name 'HUD hidden before activation' -Observed ($hudBaseline.Count -eq 0) -Detail (
        'no visible NanoDictate HUD owned by the launched agent before Double-Alt')
    Send-RealDictationDoubleAlt -GapMilliseconds 90
    # Only record delivery after SendInput actually succeeded; a thrown
    # injection is a fatal harness failure, not an observed hotkey.
    $guiFlags.DoubleAltDelivered = $true
    $hud = Watch-RealDictationHud -AgentProcessIds $agentProcessIds -Baseline $hudBaseline `
        -TimeoutSeconds $HudTimeoutSeconds
    $guiFlags.HudAppeared = $null -ne $hud.FirstSeenMilliseconds
    $guiFlags.RecordingPhase = [bool]$hud.RecordingObserved
    if ($guiFlags.HudAppeared) {
        $first = $hud.Observations[0]
        Add-Segment -Name 'HUD appeared after Double-Alt' -Observed $true -Detail (
            "agent-owned NanoDictate HUD appeared after $($hud.FirstSeenMilliseconds) ms at {0}x{1} (phases: {2})" -f
                $first.Width, $first.Height, (($hud.Phases | Select-Object -Unique) -join ', '))
        Save-EvidenceScreenshot -Name 'hud-first-visible' -Kind window -Handle $first.Handle
        Save-EvidenceScreenshot -Name 'desktop-hud' -Kind desktop
        Add-Segment -Name 'HUD reached the recording phase' -Observed $guiFlags.RecordingPhase -Detail (
            "observed panel heights: {0}; recording panel is 178 points tall versus 150 for starting/error" -f
                (($hud.Observations | ForEach-Object { "$($_.Width)x$($_.Height)" } | Select-Object -Unique) -join ', '))
        if (-not $guiFlags.RecordingPhase) {
            Add-Limitation 'The HUD appeared but never reached the recording phase: NanoDictate could not start capture on this runner (microphone missing, privacy denial or WASAPI failure). The authentic activation path is proven; capture is not.'
        }
    } else {
        Add-Segment -Name 'HUD appeared after Double-Alt' -Observed $false -Detail (
            "no agent-owned NanoDictate HUD appeared or changed within $HudTimeoutSeconds seconds after a real Double-Alt")
        Add-Limitation 'A real Double-Alt produced no attributable HUD: the global hook, capture start or window rendering is blocked in this session.'
    }

    # ---------------------------------------------------------------
    # Virtual microphone -> real WASAPI capture -> real STT -> insertion.
    # ---------------------------------------------------------------
    if ($guiFlags.RecordingPhase) {
        $currentForeground = Get-RealDictationForegroundWindow
        $editorFocusedDuringRecording = Test-RealDictationActiveEditorWindow -Foreground $currentForeground `
            -EditorHandle $notepadWindow.Handle -TitlePattern $editorTitlePattern
        Add-Segment -Name 'focused editor kept the foreground' -Observed $editorFocusedDuringRecording -Detail (
            "foreground is '{0}' (handle {1}, pid {2}); expected this run's unique file '{3}'" -f
                $(if ($currentForeground) { $currentForeground.Title } else { '<none>' }),
                $(if ($currentForeground) { $currentForeground.Handle } else { 0 }),
                $(if ($currentForeground) { $currentForeground.ProcessId } else { 0 }),
                $editorFileStem)

        # The route was recorded before the installer ran. The product opens
        # whatever the default capture endpoint is when recording starts, so
        # re-resolve it now and reject a changed or unresolved route instead of
        # playing into the endpoint that used to be the default.
        $activationInventory = Get-RealDictationAudioEndpoint -DefaultFlow capture
        $activationRoute = Resolve-VirtualAudioRoute -Endpoints $activationInventory.Endpoints `
            -DefaultCaptureEndpoint $activationInventory.DefaultCapture
        $routeUnchanged = $null -ne $activationRoute.VirtualCapture -and
            (Test-EndpointIdentityMatch -Candidate $activationRoute.VirtualCapture -Reference $audioRoute.VirtualCapture) -and
            (Test-EndpointIdentityMatch -Candidate $activationRoute.PairedRender -Reference $audioRoute.PairedRender)
        $routeReachableAtActivation = [bool]($routeUnchanged -and $activationRoute.DefaultCaptureIsVirtual -and
            $null -ne $activationRoute.PairedRender)
        $activationDefaultName = if ($null -eq $activationInventory.DefaultCapture) {
            '<none>'
        } else {
            [string]$activationInventory.DefaultCapture.Name
        }
        $expectedDefaultName = if ($null -eq $audioRoute.VirtualCapture) {
            '<none>'
        } else {
            [string]$audioRoute.VirtualCapture.Name
        }
        Add-Segment -Name 'capture route unchanged at activation' -Observed $routeReachableAtActivation -Detail (
            "default console capture is '$activationDefaultName'; expected '$expectedDefaultName' to remain the default virtual route")
        if (-not $routeReachableAtActivation) {
            Add-Limitation "The pre-install audio route could not be confirmed at recording start, so a rendered phrase cannot be attributed to the product's capture path. $($activationRoute.Reason)"
        }

        if (-not $routeReachableAtActivation) {
            Send-RealDictationKey -Key 'return'
            $hidden = Wait-RealDictationHudHidden -ProcessIds $agentProcessIds -TimeoutSeconds 20
            Add-Segment -Name 'dictation stopped cleanly' -Observed $hidden.Hidden -Detail (
                "HUD hidden: $($hidden.Hidden) after $($hidden.ElapsedMilliseconds) ms")
        } else {
            $wavPath = $PhraseWav
            if (-not $wavPath) {
                $wavPath = Join-Path $EvidenceDirectory 'phrase.wav'
                $phrase = New-RealDictationPhraseWav -Text $PhraseText -Path $wavPath
                Add-Segment -Name 'test phrase audio prepared' -Observed $true -Detail (
                    "SAPI voice '$($phrase.Voice)' synthesized the test-owned phrase as $($phrase.Format)")
            } elseif (-not (Test-Path -LiteralPath $wavPath)) {
                throw "PhraseWav does not exist: $wavPath"
            }
            Add-EvidenceFile $wavPath

            $playbackSeconds = Invoke-RealDictationWavPlayback -DeviceId $activationRoute.PairedRender.Id -Path $wavPath
            $audioFlags.WavPlayed = $true
            # Rendering proves the cable received audio. It does not prove the
            # product captured it; only the insertion assertion below does.
            Add-Segment -Name 'spoken phrase rendered into the virtual cable' -Observed $true -Detail (
                "rendered {0:N2} s into '{1}'; the product is expected to capture the paired device '{2}', but rendering alone is not evidence of capture" -f
                    $playbackSeconds, $activationRoute.PairedRender.Name, $activationRoute.VirtualCapture.Name)
            if ($playbackSeconds -lt $AudioSeconds) {
                Start-Sleep -Milliseconds ([int](($AudioSeconds - $playbackSeconds) * 1000))
            }

            $hudDuringPlayback = Find-RealDictationHudWindow -ProcessIds $agentProcessIds
            Add-Segment -Name 'recording HUD stayed visible during speech' -Observed ($null -ne $hudDuringPlayback) -Detail (
                'the launched agent''s recording HUD was still visible after playback')
            if ($null -ne $hudDuringPlayback) {
                Save-EvidenceScreenshot -Name 'hud-after-speech' -Kind window -Handle $hudDuringPlayback.Handle
            }

            Send-RealDictationKey -Key 'return'
            $hidden = Wait-RealDictationHudHidden -ProcessIds $agentProcessIds -TimeoutSeconds $ResultTimeoutSeconds
            Add-Segment -Name 'dictation stopped and provider finished' -Observed $hidden.Hidden -Detail (
                "HUD hidden: $($hidden.Hidden) after $($hidden.ElapsedMilliseconds) ms")
            if (-not $hidden.Hidden) {
                Add-Limitation "The HUD stayed visible for $ResultTimeoutSeconds seconds after stopping; the provider request or insertion never completed."
                Send-RealDictationKey -Key 'escape'
            }

            # Re-focus the editor and verify that its active tab still names
            # this run's unique file before reading. Windows 11 Notepad hosts
            # several files in one window, and the clipboard fallback would
            # otherwise read whichever tab is active. An unverified tab must
            # leave the assertion uncredited instead of reading unrelated text.
            $editorRefocused = Set-RealDictationForegroundWindow -Handle $notepadWindow.Handle
            $activeBeforeRead = Get-RealDictationForegroundWindow
            $tabActiveBeforeRead = $editorRefocused -and
                (Test-RealDictationActiveEditorWindow -Foreground $activeBeforeRead `
                    -EditorHandle $notepadWindow.Handle -TitlePattern $editorTitlePattern)
            Add-Segment -Name 'test-owned editor tab active before reading' `
                -Observed $tabActiveBeforeRead `
                -Detail ("foreground is '{0}' (pid {1}); expected this run's unique file '{2}'" -f
                    $(if ($activeBeforeRead) { $activeBeforeRead.Title } else { '<none>' }),
                    $(if ($activeBeforeRead) { $activeBeforeRead.ProcessId } else { 0 }),
                    $editorFileStem)
            if (-not $tabActiveBeforeRead) {
                $editorText = [pscustomobject]@{
                    Text = [string]::Empty
                    Method = 'active-tab-unverified'
                    Read = $false
                }
                Add-Limitation 'The active Notepad tab could not be verified as this run''s unique test file; the editor text was not read, so the insertion assertion is unverified.'
            } else {
                $editorText = Get-RealDictationEditorText -Handle $notepadWindow.Handle -UseClipboardFallback
                # Recheck after the read. Title checks alone cannot prove which
                # tab supplied Ctrl+A/Ctrl+C (a tab can be active only during
                # the read), so the unique document marker below is the
                # authoritative ownership gate.
                $activeAfterRead = Get-RealDictationForegroundWindow
                $tabActiveAfterRead = Test-RealDictationActiveEditorWindow -Foreground $activeAfterRead `
                    -EditorHandle $notepadWindow.Handle -TitlePattern $editorTitlePattern
                Add-Segment -Name 'test-owned editor tab active after reading' `
                    -Observed $tabActiveAfterRead `
                    -Detail ("foreground is '{0}' (pid {1}); expected this run's unique file '{2}'" -f
                        $(if ($activeAfterRead) { $activeAfterRead.Title } else { '<none>' }),
                        $(if ($activeAfterRead) { $activeAfterRead.ProcessId } else { 0 }),
                        $editorFileStem)
                if (-not $tabActiveAfterRead) {
                    $editorText = [pscustomobject]@{
                        Text = [string]::Empty
                        Method = 'active-tab-changed-during-read'
                        Read = $false
                    }
                    Add-Limitation 'The active Notepad tab changed while the editor text was read; the insertion assertion cannot be credited.'
                }
            }
            $insertion = Test-RealDictationInsertion -EditorText $editorText.Text `
                -Marker $editorMarker -Expected $PhraseText
            $match = $insertion.Comparison
            $contentOwned = [bool]($editorText.Read -and $insertion.Owned)
            Add-Segment -Name 'editor text belongs to this run''s test document' -Observed $contentOwned -Detail (
                "read via {0}; unique document marker '{1}' {2}" -f
                    $editorText.Method, $editorMarker, $(if ($contentOwned) { 'present' } else { 'missing' }))
            if ($editorText.Read -and -not $contentOwned) {
                Add-Limitation 'The read editor text did not contain this run''s unique document marker: another Notepad tab was active during the read, so the insertion assertion cannot be credited.'
            }
            # Test-RealDictationInsertion strips the marker before matching, so
            # it can never satisfy the expected phrase (for example "real
            # dictation" appears in the marker name).
            $phraseInserted = [bool]($match.Matched -and $contentOwned)
            $audioFlags.PhraseMatched = $phraseInserted
            # Publish the editor/transcript text only for a document this run
            # owns. When ownership fails the text may belong to another tab, so
            # record the method and failure without copying it into the console,
            # JSON evidence or job summary.
            if ($contentOwned) {
                $insertionDetail = "editor text ({0}, {1} chars): '{2}' | expected '{3}' | matched {4}/{5} tokens" -f
                    $editorText.Method, $insertion.TranscriptText.Length,
                    $match.TranscriptNormalized,
                    $match.ExpectedNormalized,
                    $match.OrderedTokens, $match.ExpectedTokenCount
            } else {
                $insertionDetail = "editor text withheld because document ownership failed (read via {0}); expected '{1}' | matched {2}/{3} tokens" -f
                    $editorText.Method,
                    $match.ExpectedNormalized,
                    $match.OrderedTokens, $match.ExpectedTokenCount
            }
            Add-Segment -Name 'real STT phrase inserted in Notepad' -Observed $phraseInserted -Detail $insertionDetail
            if (-not $match.Matched) {
                Add-Limitation 'The focused editor did not contain the expected phrase. A provider/network failure, empty transcript or insertion failure must be treated as unverified, not as a passing transcription.'
            }
            if (-not $editorText.Read) {
                Add-Limitation "The editor text could not be read ($($editorText.Method)); the phrase assertion cannot be credited."
            }
            Save-EvidenceScreenshot -Name 'desktop-after-insertion' -Kind desktop
        }
    }
} catch {
    $fatal = $_
    Add-Segment -Name 'qualification harness' -Observed $false -Detail ($_.Exception.Message -replace '\|', '/')
    Add-Limitation "The qualification harness stopped before completing the product path: $($_.Exception.Message)"
    Write-Warning "Real-dictation qualification failed: $($_.Exception.Message)"
} finally {
    # Do not close or kill Notepad here: even a new launcher PID can hand this
    # test file to a process/window containing unrelated user documents.
    # The disposable GitHub-hosted runner cleans up the editor after this job.
    # Local runs intentionally leave the editor untouched rather than risk
    # destroying another tab or unsaved work.
    try {
        if ($installedDirectory -and $installationOwned) {
            $null = Stop-NanoDictateProcessesUnderPath -InstallDirectory $installedDirectory -TimeoutSeconds 15
        }
    } catch {
        Write-Warning "Could not stop the NanoDictate background agent: $_"
    }
    try {
        # Only an installation this run created may be uninstalled. A
        # pre-existing installation is refused before setup, so its uninstaller
        # can never be invoked from here.
        if ($installationOwned -and $installedDirectory -and
            (Test-Path -LiteralPath (Join-Path $installedDirectory 'unins000.exe'))) {
            Invoke-BoundedInstallerProcess -FilePath (Join-Path $installedDirectory 'unins000.exe') `
                -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
                -Phase 'real-dictation-uninstall' -TimeoutSeconds 120 `
                -LogDirectory $LogDirectory -InnoLogFileName 'real-dictation-uninstall.log' | Out-Null
        }
    } catch {
        Write-Warning "Qualification cleanup uninstall failed: $_"
    }
    # Restore the user's provider config after uninstall so the test copy can
    # never be mistaken for the local configuration.
    if ($configApplied) {
        try {
            if ($configExistedBefore -and $configBackupPath -and
                (Test-Path -LiteralPath $configBackupPath)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configTarget) | Out-Null
                Copy-Item -LiteralPath $configBackupPath -Destination $configTarget -Force
            } elseif (-not $configExistedBefore -and (Test-Path -LiteralPath $configTarget)) {
                Remove-Item -LiteralPath $configTarget -Force
            }
        } catch {
            Write-Warning "Could not restore the provider config at ${configTarget}: $_"
        }
    }
    if ($configBackupPath -and (Test-Path -LiteralPath $configBackupPath)) {
        Remove-Item -LiteralPath $configBackupPath -Force -ErrorAction SilentlyContinue
    }
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $evidence = Write-Evidence
    $exitCode = Get-RealDictationExitCode -FullyVerified ([bool]$evidence.fullyVerified) `
        -ProbeOnly:$ProbeOnly -Failed:([bool]$fatal)
    exit $exitCode
}
