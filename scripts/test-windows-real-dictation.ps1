#Requires -Version 7.0
<#
.SYNOPSIS
  Cross-platform contract tests for the opt-in Windows real-dictation
  qualification (issue #254).
.DESCRIPTION
  Runs on Linux and Windows. It verifies the pure assertion/classification
  helpers with deterministic vectors and guards the workflow/documentation
  contract:
    * the qualification stays opt-in (workflow_dispatch only) and read-only;
    * it never fabricates a transcript or claims a run that did not happen;
    * the status vocabulary is exactly FULL/PARTIAL/NOT VERIFIED;
    * the harness actually drives the product path (real Double-Alt, HUD,
      virtual capture route, real provider assertion).
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'scripts/windows-real-dictation.psm1') -Force

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
function Read-Text([string]$RelativePath) {
    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required file: $RelativePath"
    }
    return Get-Content -LiteralPath $path -Raw
}
function Assert-Equal([string]$Name, $Actual, $Expected) {
    if ("$Actual" -eq "$Expected") { Pass $Name }
    else { Fail $Name "expected '$Expected', got '$Actual'" }
}
function Assert-True([string]$Name, [bool]$Condition, [string]$Detail) {
    if ($Condition) { Pass $Name } else { Fail $Name $Detail }
}
function Assert-Contains([string]$Name, [string]$Text, [string]$Needle) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { Pass $Name }
    else { Fail $Name "expected to contain: $Needle" }
}
function Assert-NotContains([string]$Name, [string]$Text, [string]$Needle) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { Pass $Name }
    else { Fail $Name "must not contain: $Needle" }
}
function Assert-Match([string]$Name, [string]$Text, [string]$Pattern) {
    if ([regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) { Pass $Name }
    else { Fail $Name "expected to match: $Pattern" }
}
function Assert-NotMatch([string]$Name, [string]$Text, [string]$Pattern) {
    if (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) { Pass $Name }
    else { Fail $Name "must not match: $Pattern" }
}
function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$ExpectedPattern = '') {
    try {
        & $Action | Out-Null
        Fail $Name 'expected the call to throw'
    } catch {
        if (-not $ExpectedPattern -or $_.Exception.Message -match $ExpectedPattern) { Pass $Name }
        else { Fail $Name "unexpected error: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Pure assertion helpers
# ---------------------------------------------------------------------------
$normalizationVectors = @(
    @{ Input = '  Hello, World!  '; Expected = 'hello world' },
    @{ Input = '«Привет» — мир'; Expected = 'привет мир' },
    @{ Input = "Nano-Dictate's"; Expected = 'nano dictate s' },
    @{ Input = '😀🔥'; Expected = '' },
    @{ Input = 'Café'; Expected = 'café' },
    @{ Input = "Multiple`t`nlines"; Expected = 'multiple lines' },
    @{ Input = ''; Expected = '' }
)
foreach ($vector in $normalizationVectors) {
    Assert-Equal "normalizes '$($vector.Input)'" `
        (ConvertTo-NormalizedDictationText -Text $vector.Input) $vector.Expected
}

$exact = Test-DictationPhraseInserted -Transcript 'Nano Dictate, automated check.' `
    -Expected 'nano dictate automated check'
Assert-True 'exact phrase with punctuation matches' $exact.Matched 'exact phrase'
Assert-Equal 'exact phrase reports every token' $exact.OrderedTokens 4

$ordered = Test-DictationPhraseInserted -Transcript 'So, um, Nano Dictate automated check worked.' `
    -Expected 'nano dictate automated check'
Assert-True 'ordered phrase with filler words matches' $ordered.Matched 'ordered containment'

$reordered = Test-DictationPhraseInserted -Transcript 'automated Nano Dictate check' `
    -Expected 'nano dictate automated check'
Assert-True 'reordered phrase does not match' (-not $reordered.Matched) 'order must be preserved'

$missing = Test-DictationPhraseInserted -Transcript 'Nano Dictate check' `
    -Expected 'nano dictate automated check'
Assert-True 'missing word does not match' (-not $missing.Matched) 'all tokens are required'
Assert-Equal 'missing word reports matched fraction' $missing.MatchedFraction 0.5

$emptyTranscript = Test-DictationPhraseInserted -Transcript '' -Expected 'nano dictate automated check'
Assert-True 'empty transcript does not match' (-not $emptyTranscript.Matched) 'empty transcript'

$cyrillic = Test-DictationPhraseInserted -Transcript 'Проверка нанодиктейт прошла успешно' `
    -Expected 'Проверка нанодиктейт прошла успешно'
Assert-True 'Cyrillic phrase matches' $cyrillic.Matched 'cyrillic normalization'

$loose = Test-DictationPhraseInserted -Transcript 'Nano Dictate automated' `
    -Expected 'nano dictate automated check' -MinimumMatchedFraction 0.75
Assert-True 'explicit tolerance accepts three of four tokens' $loose.Matched 'fraction tolerance'

Assert-Throws 'single-word expected phrase is rejected' {
    Test-DictationPhraseInserted -Transcript 'nano' -Expected 'nano'
} 'at least two words'

# ---------------------------------------------------------------------------
# Virtual audio endpoint heuristics and routing
# ---------------------------------------------------------------------------
$physical = @(
    [pscustomobject]@{ Id = 'cap-phys'; Name = 'Microphone Array (Realtek Audio)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-phys'; Name = 'Speakers (Realtek Audio)'; Flow = 'render'; State = 'active' }
)
Assert-True 'physical microphone is not a virtual capture endpoint' `
    ($null -eq (Find-VirtualCaptureEndpoint -Endpoints $physical)) 'physical endpoints must not count'

$disabledCable = @(
    [pscustomobject]@{ Id = 'cap-cable'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'disabled' }
)
Assert-True 'disabled virtual cable is not usable' `
    ($null -eq (Find-VirtualCaptureEndpoint -Endpoints $disabledCable)) 'state must be active'

$cable = @(
    [pscustomobject]@{ Id = 'cap-cable'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-cable'; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
    [pscustomobject]@{ Id = 'cap-phys'; Name = 'Microphone Array (Realtek Audio)'; Flow = 'capture'; State = 'active' }
)
$found = Find-VirtualCaptureEndpoint -Endpoints $cable
Assert-Equal 'virtual cable capture endpoint is found' $found.Endpoint.Id 'cap-cable'
Assert-Equal 'virtual cable match records its pattern' $found.MatchedPattern 'CABLE Output*'

$paired = Get-PairedRenderEndpoint -CaptureEndpoint $cable[0] -RenderEndpoints $cable
Assert-Equal 'CABLE Output pairs with CABLE Input' $paired.Endpoint.Id 'ren-cable'

$voicemeeter = @(
    [pscustomobject]@{ Id = 'cap-vm'; Name = 'VoiceMeeter Output (VB-Audio VoiceMeeter VAIO)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-vm'; Name = 'VoiceMeeter Input (VB-Audio VoiceMeeter VAIO)'; Flow = 'render'; State = 'active' }
)
$vmPaired = Get-PairedRenderEndpoint -CaptureEndpoint $voicemeeter[0] -RenderEndpoints $voicemeeter
Assert-Equal 'VoiceMeeter Output pairs with VoiceMeeter Input' $vmPaired.Endpoint.Id 'ren-vm'

$unpaired = Get-PairedRenderEndpoint -CaptureEndpoint $cable[0] -RenderEndpoints $physical
Assert-True 'capture without a matching render group is not reachable' `
    ($null -eq $unpaired.Endpoint) $unpaired.Reason

$routeDefault = Resolve-VirtualAudioRoute -Endpoints $cable -DefaultCaptureEndpoint $cable[0]
Assert-True 'virtual default capture is the product route' $routeDefault.DefaultCaptureIsVirtual 'default route'
Assert-True 'virtual default route is reachable' $routeDefault.CaptureEndpointReachable 'reachable'
Assert-Equal 'reachable route picks the paired render endpoint' $routeDefault.PairedRender.Id 'ren-cable'

$routeNotDefault = Resolve-VirtualAudioRoute -Endpoints $cable -DefaultCaptureEndpoint $cable[2]
Assert-True 'non-default virtual cable is not the product route' (-not $routeNotDefault.DefaultCaptureIsVirtual) 'default mismatch'
Assert-Match 'non-default route explains the product default' $routeNotDefault.Reason 'default console capture endpoint is'

$routeNone = Resolve-VirtualAudioRoute -Endpoints $physical -DefaultCaptureEndpoint $physical[0]
Assert-True 'physical-only runner has no virtual route' (-not $routeNone.DefaultCaptureIsVirtual) 'no cable'
Assert-Match 'physical-only runner reports a specific limitation' $routeNone.Reason 'no active virtual capture endpoint'

$routeByName = Resolve-VirtualAudioRoute -Endpoints @(
    [pscustomobject]@{ Id = ''; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = ''; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
) -DefaultCaptureEndpoint ([pscustomobject]@{ Id = ''; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' })
Assert-True 'name-based route works when ids are empty' $routeByName.DefaultCaptureIsVirtual 'name fallback'

$twoCableRoutes = @(
    [pscustomobject]@{ Id = 'cap-a'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-a'; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
    [pscustomobject]@{ Id = 'cap-b'; Name = 'VoiceMeeter Output (VB-Audio VoiceMeeter VAIO)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-b'; Name = 'VoiceMeeter Input (VB-Audio VoiceMeeter VAIO)'; Flow = 'render'; State = 'active' }
)
$routeSecondDefault = Resolve-VirtualAudioRoute -Endpoints $twoCableRoutes -DefaultCaptureEndpoint $twoCableRoutes[2]
Assert-Equal 'default virtual capture is selected over the first cable' $routeSecondDefault.VirtualCapture.Id 'cap-b'
Assert-True 'default virtual capture is the product route' $routeSecondDefault.DefaultCaptureIsVirtual 'default must win over enumeration order'
Assert-Equal 'default virtual capture pairs its own render endpoint' $routeSecondDefault.PairedRender.Id 'ren-b'

$routeSameNameDifferentId = Resolve-VirtualAudioRoute -Endpoints @(
    [pscustomobject]@{ Id = 'cap-a'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-a'; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
) -DefaultCaptureEndpoint ([pscustomobject]@{ Id = 'cap-b'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' })
Assert-True 'a friendly-name match does not override different nonempty ids' `
    (-not $routeSameNameDifferentId.DefaultCaptureIsVirtual) 'ids must decide identity'

$defaultPhraseTokens = (Get-DictationTokens -Text 'quick brown fox jumps').Count
Assert-Equal 'default qualification phrase has four tokens' $defaultPhraseTokens 4
Assert-True 'default qualification phrase passes the harness token guard' `
    ($defaultPhraseTokens -ge 2) 'the default phrase must satisfy the minimum-two-token guard'

# ---------------------------------------------------------------------------
# Verdict vocabulary
# ---------------------------------------------------------------------------
$guiPass = [pscustomobject]@{
    AppLaunched = $true; EditorFocused = $true; DoubleAltDelivered = $true
    HudAppeared = $true; RecordingPhase = $true
}
$audioPass = [pscustomobject]@{
    VirtualCaptureEndpointPresent = $true; DefaultCaptureIsVirtual = $true
    WavPlayed = $true; PhraseMatched = $true
}
$guiFail = [pscustomobject]@{
    AppLaunched = $false; EditorFocused = $false; DoubleAltDelivered = $false
    HudAppeared = $false; RecordingPhase = $false
}
$audioFail = [pscustomobject]@{
    VirtualCaptureEndpointPresent = $false; DefaultCaptureIsVirtual = $false
    WavPlayed = $false; PhraseMatched = $false
}

$full = Get-RealDictationVerdict -Gui $guiPass -Audio $audioPass
Assert-Equal 'complete evidence is FULL E2E VERIFIED' $full.Status 'FULL E2E VERIFIED'
Assert-True 'FULL has no unverified segments' ($full.UnverifiedSegments.Count -eq 0) 'unverified list'

$guiOnly = Get-RealDictationVerdict -Gui $guiPass -Audio $audioFail
Assert-Equal 'GUI-only evidence is PARTIAL VERIFIED' $guiOnly.Status 'PARTIAL VERIFIED'
Assert-Equal 'GUI-only evidence names the four audio segments' $guiOnly.UnverifiedSegments.Count 4

$guiWithoutRecording = [pscustomobject]@{
    AppLaunched = $true; EditorFocused = $true; DoubleAltDelivered = $true
    HudAppeared = $true; RecordingPhase = $false
}
$activationOnly = Get-RealDictationVerdict -Gui $guiWithoutRecording -Audio $audioFail
Assert-Equal 'activation without a recording HUD is not a partial leg' `
    $activationOnly.Status 'NOT VERIFIED / HOSTED RUNNER BLOCKED'
Assert-True 'activation without recording names the missing recording phase' `
    ($activationOnly.UnverifiedSegments -contains 'recording HUD phase reached') 'recording phase must be required'

$audioOnly = Get-RealDictationVerdict -Gui $guiFail -Audio $audioPass
Assert-Equal 'audio-only evidence is PARTIAL VERIFIED' $audioOnly.Status 'PARTIAL VERIFIED'

$blocked = Get-RealDictationVerdict -Gui $guiFail -Audio $audioFail
Assert-Equal 'no evidence is NOT VERIFIED / HOSTED RUNNER BLOCKED' $blocked.Status 'NOT VERIFIED / HOSTED RUNNER BLOCKED'

$probe = Get-RealDictationVerdict -Gui $guiFail -Audio $audioFail -ProbeOnly
Assert-Equal 'probe-only run is reported separately' $probe.Status 'NOT VERIFIED / PROBE ONLY'

Assert-Equal 'fatal harness failure exits 1' (Get-RealDictationExitCode -Failed) 1
Assert-Equal 'full verification exits 0' `
    (Get-RealDictationExitCode -FullyVerified $true) 0
Assert-Equal 'a non-full qualification exits 2' `
    (Get-RealDictationExitCode -FullyVerified $false) 2
Assert-Equal 'a completed probe-only run exits 0' `
    (Get-RealDictationExitCode -FullyVerified $false -ProbeOnly) 0
Assert-Equal 'a failed probe-only run exits 1' `
    (Get-RealDictationExitCode -FullyVerified $false -ProbeOnly -Failed) 1

# ---------------------------------------------------------------------------
# Summary rendering
# ---------------------------------------------------------------------------
$summary = Format-RealDictationSummary -Evidence ([pscustomobject]@{
    status = 'PARTIAL VERIFIED'
    tested = [pscustomobject]@{
        source = 'published'; version = '0.1.46'; commit = 'abc123'; installerSha256 = 'deadbeef'
    }
    environment = [pscustomobject]@{
        runnerImage = 'win22 20261101'
        run = [pscustomobject]@{ runUrl = 'https://github.com/example/actions/runs/1' }
        session = [pscustomobject]@{ sessionId = 1; desktopName = 'Default'; inputDesktopAvailable = $true }
    }
    segments = @(
        [pscustomobject]@{ name = 'HUD appeared after Double-Alt'; observed = $true; detail = 'visible after 240 ms' }
        [pscustomobject]@{ name = 'virtual capture endpoint present'; observed = $false; detail = 'no active virtual capture endpoint' }
    )
    limitations = @('no active virtual capture endpoint is installed on this runner')
    evidenceFiles = @('windows/artifacts/real-dictation/evidence.json')
})
Assert-Contains 'summary states the verdict' $summary '**Status: PARTIAL VERIFIED**'
Assert-Contains 'summary links the Actions run' $summary 'https://github.com/example/actions/runs/1'
Assert-Contains 'summary lists the observed limitation' $summary 'no active virtual capture endpoint is installed'
Assert-Contains 'summary warns that a segment pass is not verification' $summary 'A per-segment PASS only means that step was observed'

$summaryWithoutProbe = Format-RealDictationSummary -Evidence ([pscustomobject]@{
    status = 'NOT VERIFIED / HOSTED RUNNER BLOCKED'
    tested = [pscustomobject]@{
        source = 'published'; version = 'unknown'; commit = 'unknown'; installerSha256 = ''
    }
    environment = [pscustomobject]@{
        runnerImage = ''; session = $null
    }
    segments = @()
    limitations = @('the session probe failed')
    evidenceFiles = @()
})
Assert-Contains 'summary survives a failed session probe' $summaryWithoutProbe 'probe unavailable'
Assert-Contains 'summary states a blocked verdict' $summaryWithoutProbe '**Status: NOT VERIFIED / HOSTED RUNNER BLOCKED**'

# ---------------------------------------------------------------------------
# Workflow and harness contracts
# ---------------------------------------------------------------------------
$workflow = Read-Text '.github/workflows/windows-real-dictation.yml'
Assert-Contains 'qualification workflow is manually dispatched' $workflow 'workflow_dispatch:'
Assert-Match 'qualification workflow is read-only' $workflow '(?m)^permissions:\s*\r?\n\s+contents: read\s*$'
Assert-NotContains 'qualification workflow has no pull_request trigger' $workflow 'pull_request'
Assert-NotMatch 'qualification workflow has no push trigger' $workflow '(?m)^\s{2}push:'
Assert-NotMatch 'qualification workflow has no schedule' $workflow '(?m)^\s{2}schedule:'
Assert-NotContains 'qualification workflow uses no secrets' $workflow 'secrets.'
Assert-Contains 'qualification job uses the hosted Windows runner' $workflow 'runs-on: windows-latest'
Assert-Contains 'qualification runs its own contract tests first' $workflow 'scripts/test-windows-real-dictation.ps1'
Assert-Contains 'qualification runs the real harness' $workflow 'windows/package/test-real-dictation.ps1'
Assert-Contains 'qualification accepts a probe-only feasibility run' $workflow 'ND_PROBE_ONLY'
Assert-Contains 'qualification accepts a test-owned phrase WAV' $workflow 'ND_PHRASE_WAV'
Assert-Contains 'qualification accepts a non-secret provider config' $workflow 'ND_CONFIG_PATH'
Assert-Contains 'qualification can test the published installer' $workflow 'source:'
Assert-Contains 'qualification can test an exact-commit candidate' $workflow 'candidate'
Assert-Contains 'qualification retains evidence on failure' $workflow 'if: always()'
Assert-Contains 'qualification uploads evidence artifacts' $workflow 'windows/artifacts/real-dictation/**'
Assert-Contains 'qualification documents default-branch dispatch registration' $workflow 'not found on the default branch'

$harness = Read-Text 'windows/package/test-real-dictation.ps1'
Assert-Contains 'harness installs the actual installer' $harness 'Invoke-BoundedInstallerProcess'
Assert-Contains 'harness verifies the published SHA-256' $harness 'SHA256SUMS.txt'
Assert-Contains 'harness resolves the tested published release commit' $harness 'commits/v$resolvedVersion'
Assert-Contains 'harness records an unknown tested commit when release resolution fails' `
    $harness "`$script:testedCommit = 'unknown'"
Assert-Contains 'harness counts phrase tokens directly' `
    $harness 'if ((Get-DictationTokens -Text $PhraseText).Count -lt 2)'
Assert-Contains 'harness requires an interactive input desktop' $harness 'InputDesktopAvailable'
Assert-Contains 'harness enumerates real WASAPI endpoints' $harness 'Get-RealDictationAudioEndpoint'
Assert-Contains 'harness focuses Notepad' $harness "notepad.exe"
Assert-Contains 'harness tolerates packaged Notepad hosting' $harness 'Get-RealDictationWindowByTitlePattern'
Assert-Contains 'harness scopes the editor fallback to its own unique file' $harness 'nanodictate-real-dictation-'
Assert-Contains 'harness only terminates an editor it owns' $harness 'if ($editorOwned -and $null -ne $notepadWindow)'
Assert-Contains 'harness sends a real Double-Alt' $harness 'Send-RealDictationDoubleAlt'
Assert-Contains 'harness observes the recording HUD phase' $harness 'RecordingObserved'
Assert-Contains 'harness routes the WAV into the virtual cable' $harness 'Invoke-RealDictationWavPlayback'
Assert-Contains 'harness asserts the inserted phrase' $harness 'Test-DictationPhraseInserted'
Assert-Contains 'harness stops dictation through the product hotkey' $harness "Send-RealDictationKey -Key 'return'"
Assert-Contains 'harness applies an operator provider config' $harness 'config.toml'
Assert-Contains 'harness never uploads the user config' $harness 'never uploaded'
Assert-Contains 'harness records the observed limitation list' $harness 'Add-Limitation'
Assert-Contains 'harness documents that limitations never become passes' $harness 'never converted into a pass'
Assert-Contains 'harness fails a non-full qualification run' $harness 'Get-RealDictationExitCode'
Assert-Contains 'harness captures screenshot evidence' $harness 'Save-EvidenceScreenshot'

$module = Read-Text 'scripts/windows-real-dictation.psm1'
Assert-Contains 'module exposes the three-status verdict' $module "FULL E2E VERIFIED"
Assert-Contains 'module exposes the blocked status' $module 'NOT VERIFIED / HOSTED RUNNER BLOCKED'
Assert-Contains 'module keeps a specific no-cable reason' $module 'no active virtual capture endpoint is installed on this runner'
Assert-Contains 'module does not mock the product' $module 'Nothing here mocks a transcript'
Assert-Contains 'module synthesizes the phrase as 16 kHz 16-bit mono PCM' $module '$stream.Format.Type = 18'
Assert-Match 'module sets the PCM format before opening the WAV stream' `
    $module '(?s)\$stream\.Format\.Type = 18.*?\$stream\.Open\('

$interop = Read-Text 'scripts/windows-real-dictation-interop.cs'
Assert-Contains 'interop injects real keyboard input' $interop 'SendInput(1, new[] { input }'
Assert-Contains 'interop sizes the x64 INPUT union' $interop 'private struct MouseInput'
Assert-Match 'interop sizes PROPVARIANT for the native x64 layout' `
    $interop '(?s)StructLayout\(LayoutKind\.Explicit, Size = 24\).*?struct PropVariant'
Assert-Contains 'interop renders into a real WASAPI endpoint' $interop 'PlayWavToDevice'
Assert-Contains 'interop probes the interactive desktop' $interop 'OpenInputDesktop'

$validation = Read-Text 'windows/VALIDATION.md'
Assert-Contains 'validation documents the opt-in workflow' $validation 'windows-real-dictation.yml'
Assert-Contains 'validation uses the accepted status vocabulary' $validation 'FULL E2E VERIFIED'
Assert-Contains 'validation names the unverified state' $validation 'NOT VERIFIED'
Assert-Match 'validation states the current hosted evidence status' $validation 'no hosted real-dictation qualification run\s+has been observed'
Assert-Contains 'validation records the default-branch dispatch blocker' $validation 'not found on the default branch'
Assert-Contains 'validation does not call the registration blocker a runner limitation' $validation 'workflow-registration blocker'
Assert-NotContains 'validation does not claim a passed hosted dictation run' $validation 'FULL E2E VERIFIED on'

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
