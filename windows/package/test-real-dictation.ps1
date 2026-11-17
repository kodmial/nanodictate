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
$notepadProcess = $null
$notepadProcessId = 0
$notepadWindow = $null
$editorOwned = $false
$installerSha256 = ''
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
    if ($result.Saved -and $result.NonBlankPixels -gt 0) {
        Add-EvidenceFile $result.Path
        Add-Segment $Name $true `
            ("{0} screenshot via {1} ({2}x{3}, {4} non-blank pixels)" -f
                $Kind, $result.Method, $result.Width, $result.Height, $result.NonBlankPixels)
    } elseif ($result.Saved) {
        Add-EvidenceFile $result.Path
        Add-Segment $Name $false "$Kind screenshot at $path contains no non-blank pixels"
        Add-Limitation "The $Kind screenshot for '$Name' is blank; it is not visual proof of the HUD or editor."
    } else {
        Add-Segment $Name $false "$Kind screenshot could not be saved to $path"
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
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/v$resolvedVersion" -Headers $headers
    } else {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
        $resolvedVersion = ([string]$release.tag_name).TrimStart('v')
    }
    if ($resolvedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Unexpected release tag for the published installer: $($release.tag_name)"
    }
    $releaseCommit = $null
    try {
        # Identify the source commit of the published tag, not the workflow
        # checkout: a published installer must be attributable to its release.
        $releaseCommit = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/commits/v$resolvedVersion" -Headers $headers
    } catch {
        $releaseCommit = $null
    }
    if ($null -ne $releaseCommit -and [string]$releaseCommit.sha -match '^[0-9a-fA-F]{40}$') {
        $script:testedCommit = ([string]$releaseCommit.sha).ToLowerInvariant()
        Add-Segment 'published release commit resolved' $true "v$resolvedVersion -> $($script:testedCommit)"
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
    Invoke-WebRequest -Uri $sumsAsset.browser_download_url -OutFile $sumsPath -MaximumRedirection 5
    $sums = Get-Content -LiteralPath $sumsPath -Raw
    $pattern = '(?im)^([a-f0-9]{64})\s+\*?' + [regex]::Escape($assetName) + '\s*$'
    $match = [regex]::Match($sums, $pattern)
    if (-not $match.Success) {
        throw "Published SHA256SUMS.txt does not list $assetName"
    }
    $expected = $match.Groups[1].Value.ToLowerInvariant()
    $target = Join-Path $tempRoot $assetName
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -MaximumRedirection 5
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Published installer SHA-256 mismatch: expected $expected, got $actual"
    }
    $script:testedVersion = $resolvedVersion
    $script:installerSha256 = $actual
    Add-Segment 'published release asset selected' $true "v$resolvedVersion $assetName matches SHA256SUMS.txt"
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

function Watch-RealDictationHud {
    <#
      Polls for the NanoDictate HUD and records its geometry. The recording
      panel is 178 points tall versus 150 for every other phase, so the
      observed height (scaled by the panel width) distinguishes a real
      recording HUD from a starting/error overlay without reading internals.
    #>
    param(
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )
    $observations = [System.Collections.Generic.List[object]]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $firstSeenMs = $null
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $window = Get-RealDictationWindow -Title 'NanoDictate'
        if ($null -ne $window) {
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
    param([int]$TimeoutSeconds = 10)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($null -eq (Get-RealDictationWindow -Title 'NanoDictate')) {
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
    Add-Segment 'interactive session' ([bool]$sessionProbe.InputDesktopAvailable) `
        ("session {0}, desktop '{1}', input desktop available: {2}" -f
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
    Add-Segment 'audio endpoints enumerated' ($captureNames.Count -gt 0 -or $renderNames.Count -gt 0) `
        ("capture: {0} | render: {1}" -f (($captureNames -join '; ') -replace '\|', '/'), (($renderNames -join '; ') -replace '\|', '/'))
    Add-Segment 'virtual capture endpoint present' $audioFlags.VirtualCaptureEndpointPresent $audioRoute.Reason
    if (-not $audioFlags.VirtualCaptureEndpointPresent) {
        Add-Limitation $audioRoute.Reason
        Add-Limitation 'No virtual capture endpoint means a test-owned WAV cannot enter NanoDictate''s genuine WASAPI input; loading an audio file in the harness is not microphone capture.'
    } elseif (-not $audioFlags.DefaultCaptureIsVirtual) {
        Add-Limitation $audioRoute.Reason
        Add-Limitation 'The product always opens the default console capture endpoint, so a non-default virtual cable cannot feed real WASAPI capture without changing the system default device.'
    } elseif ($null -eq $audioRoute.PairedRender) {
        Add-Limitation "Virtual capture endpoint found but no render endpoint can feed it: $($audioRoute.PairedRenderReason)"
    } else {
        Add-Segment 'virtual audio route' $true $audioRoute.PairedRenderReason
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
        Add-Segment 'exact-commit candidate selected' $true "local candidate $installer ($($script:installerSha256))"
    }

    $installedDirectory = Join-Path $env:LOCALAPPDATA 'Programs\NanoDictate'
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
        Copy-Item -LiteralPath $ConfigPath -Destination $configTarget -Force
        Add-Segment 'operator config applied' $true 'copied the supplied provider config to %APPDATA%\NanoDictate\config.toml (never uploaded)'
    }

    $agents = @(Start-NanoDictateBackgroundIfNeeded -InstallDirectory $installedDirectory -TimeoutSeconds 30)
    if ($agents.Count -ne 1) {
        throw "Expected exactly one NanoDictate background agent after install, found $($agents.Count)"
    }
    $guiFlags.AppLaunched = $true
    Add-Segment 'product installed and background agent started' $true `
        "one NanoDictate.App agent (pid $($agents[0].Id)) from $installedDirectory"

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
    Add-Segment 'real STT provider configured' ($providerLabel.Provider -ne 'unknown') `
        "active provider '$($providerLabel.Provider)', model '$($providerLabel.Model)' from the installed user config"

    # ---------------------------------------------------------------
    # Foreground editor + real Double-Alt + HUD.
    # ---------------------------------------------------------------
    $editorFileStem = 'nanodictate-real-dictation-' + [guid]::NewGuid().ToString('N')
    $editorPath = Join-Path $tempRoot ($editorFileStem + '.txt')
    $null = New-Item -ItemType File -Path $editorPath -Force
    # A uniquely named test file keeps the editor window attributable to this
    # run even when Windows hands notepad.exe to a packaged process; both
    # discovery paths require it so neither can adopt a pre-existing Notepad
    # window. A pre-existing Notepad process may be shared with unrelated
    # documents, so it is never treated as owned by this run.
    $editorTitlePattern = [regex]::Escape($editorFileStem)
    $preexistingEditorProcessIds = @(Get-Process -Name notepad -ErrorAction SilentlyContinue |
        ForEach-Object { [int]$_.Id })
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
    $notepadProcessId = [int]$notepadWindow.ProcessId
    $editorOwned = Test-RealDictationEditorProcessOwned -EditorProcessId $notepadProcessId `
        -PreexistingProcessIds $preexistingEditorProcessIds
    if (-not (Set-RealDictationForegroundWindow -Handle $notepadWindow.Handle)) {
        throw 'Could not move Notepad to the foreground; a real global hotkey test needs a focused editor.'
    }
    $foreground = Get-RealDictationForegroundWindow
    $guiFlags.EditorFocused = $null -ne $foreground -and $foreground.ProcessId -eq $notepadProcessId
    $foregroundDescription = if ($null -eq $foreground) {
        '<no foreground window>'
    } else {
        "'$($foreground.Title)' (pid $($foreground.ProcessId))"
    }
    Add-Segment 'foreground editor focused' $guiFlags.EditorFocused `
        "foreground is $foregroundDescription; expected Notepad pid $notepadProcessId"
    if (-not $guiFlags.EditorFocused) {
        Add-Limitation 'Notepad could not own the foreground; injection would not reach the intended focused editor.'
    }

    $hudBefore = Get-RealDictationWindow -Title 'NanoDictate'
    Add-Segment 'HUD hidden before activation' ($null -eq $hudBefore) `
        'no visible NanoDictate window before Double-Alt'
    Send-RealDictationDoubleAlt -GapMilliseconds 90
    # Only record delivery after SendInput actually succeeded; a thrown
    # injection is a fatal harness failure, not an observed hotkey.
    $guiFlags.DoubleAltDelivered = $true
    $hud = Watch-RealDictationHud -TimeoutSeconds $HudTimeoutSeconds
    $guiFlags.HudAppeared = $null -ne $hud.FirstSeenMilliseconds
    $guiFlags.RecordingPhase = [bool]$hud.RecordingObserved
    if ($guiFlags.HudAppeared) {
        $first = $hud.Observations[0]
        Add-Segment 'HUD appeared after Double-Alt' $true `
            ("visible NanoDictate HUD after $($hud.FirstSeenMilliseconds) ms at {0}x{1} (phases: {2})" -f
                $first.Width, $first.Height, (($hud.Phases | Select-Object -Unique) -join ', '))
        Save-EvidenceScreenshot -Name 'hud-first-visible' -Kind window -Handle $first.Handle
        Save-EvidenceScreenshot -Name 'desktop-hud' -Kind desktop
        Add-Segment 'HUD reached the recording phase' $guiFlags.RecordingPhase `
            ("observed panel heights: {0}; recording panel is 178 points tall versus 150 for starting/error" -f
                (($hud.Observations | ForEach-Object { "$($_.Width)x$($_.Height)" } | Select-Object -Unique) -join ', '))
        if (-not $guiFlags.RecordingPhase) {
            Add-Limitation 'The HUD appeared but never reached the recording phase: NanoDictate could not start capture on this runner (microphone missing, privacy denial or WASAPI failure). The authentic activation path is proven; capture is not.'
        }
    } else {
        Add-Segment 'HUD appeared after Double-Alt' $false `
            "no visible NanoDictate HUD within $HudTimeoutSeconds seconds after a real Double-Alt"
        Add-Limitation 'A real Double-Alt produced no HUD: the global hook, capture start or window rendering is blocked in this session.'
    }

    # ---------------------------------------------------------------
    # Virtual microphone -> real WASAPI capture -> real STT -> insertion.
    # ---------------------------------------------------------------
    if ($guiFlags.RecordingPhase) {
        $currentForeground = Get-RealDictationForegroundWindow
        $editorFocusedDuringRecording = $null -ne $currentForeground -and $currentForeground.ProcessId -eq $notepadProcessId
        Add-Segment 'focused editor kept the foreground' $editorFocusedDuringRecording `
            "foreground pid during recording: $(if ($currentForeground) { $currentForeground.ProcessId } else { '<none>' })"

        if (-not $audioRoute.CaptureEndpointReachable) {
            Add-Limitation 'Recording started, but no virtual capture route feeds the product, so no spoken phrase could be delivered through WASAPI.'
            Send-RealDictationKey -Key 'return'
            $hidden = Wait-RealDictationHudHidden -TimeoutSeconds 20
            Add-Segment 'dictation stopped cleanly' $hidden.Hidden `
                "HUD hidden: $($hidden.Hidden) after $($hidden.ElapsedMilliseconds) ms"
        } else {
            $wavPath = $PhraseWav
            if (-not $wavPath) {
                $wavPath = Join-Path $EvidenceDirectory 'phrase.wav'
                $phrase = New-RealDictationPhraseWav -Text $PhraseText -Path $wavPath
                Add-Segment 'test phrase audio prepared' $true `
                    "SAPI voice '$($phrase.Voice)' synthesized the test-owned phrase as $($phrase.Format)"
            } elseif (-not (Test-Path -LiteralPath $wavPath)) {
                throw "PhraseWav does not exist: $wavPath"
            }
            Add-EvidenceFile $wavPath

            $playbackSeconds = Invoke-RealDictationWavPlayback -DeviceId $audioRoute.PairedRender.Id -Path $wavPath
            $audioFlags.WavPlayed = $true
            Add-Segment 'spoken phrase routed into the virtual capture endpoint' $true `
                ("rendered {0:N2} s into '{1}'; the product captures the paired device '{2}'" -f
                    $playbackSeconds, $audioRoute.PairedRender.Name, $audioRoute.VirtualCapture.Name)
            if ($playbackSeconds -lt $AudioSeconds) {
                Start-Sleep -Milliseconds ([int](($AudioSeconds - $playbackSeconds) * 1000))
            }

            $hudDuringPlayback = Get-RealDictationWindow -Title 'NanoDictate'
            Add-Segment 'recording HUD stayed visible during speech' ($null -ne $hudDuringPlayback) `
                'the recording HUD was still visible after playback'
            if ($null -ne $hudDuringPlayback) {
                Save-EvidenceScreenshot -Name 'hud-after-speech' -Kind window -Handle $hudDuringPlayback.Handle
            }

            Send-RealDictationKey -Key 'return'
            $hidden = Wait-RealDictationHudHidden -TimeoutSeconds $ResultTimeoutSeconds
            Add-Segment 'dictation stopped and provider finished' $hidden.Hidden `
                "HUD hidden: $($hidden.Hidden) after $($hidden.ElapsedMilliseconds) ms"
            if (-not $hidden.Hidden) {
                Add-Limitation "The HUD stayed visible for $ResultTimeoutSeconds seconds after stopping; the provider request or insertion never completed."
                Send-RealDictationKey -Key 'escape'
            }

            $editorText = Get-RealDictationEditorText -Handle $notepadWindow.Handle -UseClipboardFallback
            $match = Test-DictationPhraseInserted -Transcript $editorText.Text -Expected $PhraseText
            $audioFlags.PhraseMatched = [bool]$match.Matched
            Add-Segment 'real STT phrase inserted in Notepad' $match.Matched `
                ("editor text ({0}, {1} chars): '{2}' | expected '{3}' | matched {4}/{5} tokens" -f
                    $editorText.Method, $editorText.Text.Length,
                    (ConvertTo-NormalizedDictationText -Text $editorText.Text),
                    $match.ExpectedNormalized,
                    $match.OrderedTokens, $match.ExpectedTokenCount)
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
    Add-Segment 'qualification harness' $false ($_.Exception.Message -replace '\|', '/')
    Add-Limitation "The qualification harness stopped before completing the product path: $($_.Exception.Message)"
    Write-Warning "Real-dictation qualification failed: $($_.Exception.Message)"
} finally {
    # Close only the editor window this run created. A matching window can
    # still belong to a shared process (Windows 11 Notepad hosts several
    # documents in one process and new processes may restore tabs), so the
    # editor process is never force-terminated. The ordinary WM_CLOSE path
    # prompts before discarding anything and leaves unrelated documents alone.
    if ($editorOwned -and $null -ne $notepadWindow) {
        try {
            $editorProcess = Get-Process -Id $notepadWindow.ProcessId -ErrorAction SilentlyContinue
            if ($null -ne $editorProcess -and -not $editorProcess.HasExited) {
                $null = $editorProcess.CloseMainWindow()
            }
        } catch { }
    }
    if ($null -ne $notepadProcess -and $notepadProcess.Id -ne $notepadProcessId) {
        # This launcher process was started by the harness itself; when
        # Windows handed the test file to another process it has exited.
        try {
            if (-not $notepadProcess.HasExited) {
                Stop-Process -Id $notepadProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    try {
        if ($installedDirectory) {
            $null = Stop-NanoDictateProcessesUnderPath -InstallDirectory $installedDirectory -TimeoutSeconds 15
        }
    } catch {
        Write-Warning "Could not stop the NanoDictate background agent: $_"
    }
    try {
        if ($installedDirectory -and (Test-Path -LiteralPath (Join-Path $installedDirectory 'unins000.exe'))) {
            Invoke-BoundedInstallerProcess -FilePath (Join-Path $installedDirectory 'unins000.exe') `
                -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
                -Phase 'real-dictation-uninstall' -TimeoutSeconds 120 `
                -LogDirectory $LogDirectory -InnoLogFileName 'real-dictation-uninstall.log' | Out-Null
        }
    } catch {
        Write-Warning "Qualification cleanup uninstall failed: $_"
    }
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $evidence = Write-Evidence
    $exitCode = Get-RealDictationExitCode -FullyVerified ([bool]$evidence.fullyVerified) `
        -ProbeOnly:$ProbeOnly -Failed:([bool]$fatal)
    exit $exitCode
}
