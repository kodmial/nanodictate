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
# Editor process ownership
# ---------------------------------------------------------------------------
Assert-True 'a Notepad process created by this run is owned' `
    (Test-RealDictationEditorProcessOwned -EditorProcessId 4242 -PreexistingProcessIds @(100, 200)) `
    'a new process must be cleanable'
Assert-True 'a pre-existing Notepad process is not owned' `
    (-not (Test-RealDictationEditorProcessOwned -EditorProcessId 100 -PreexistingProcessIds @(100, 200))) `
    'a shared process must never be terminated'
Assert-True 'an invalid editor process id is not owned' `
    (-not (Test-RealDictationEditorProcessOwned -EditorProcessId 0 -PreexistingProcessIds @(100))) `
    'a missing process cannot be cleaned up'

# ---------------------------------------------------------------------------
# Active editor tab verification
# ---------------------------------------------------------------------------
$activeEditorTitlePattern = [regex]::Escape('nanodictate-real-dictation-abc123')
$activeEditorForeground = [pscustomobject]@{
    Handle = 4242
    Title = 'nanodictate-real-dictation-abc123.txt - Notepad'
    ProcessId = 99
}
Assert-True 'the test-owned editor tab is active when its title is in the foreground' `
    (Test-RealDictationActiveEditorWindow -Foreground $activeEditorForeground `
        -EditorHandle 4242 -TitlePattern $activeEditorTitlePattern) `
    'a matching foreground title must verify the test tab'
Assert-True 'another Notepad tab is not treated as the test editor' `
    (-not (Test-RealDictationActiveEditorWindow -Foreground ([pscustomobject]@{
        Handle = 4242; Title = 'unrelated.txt - Notepad'; ProcessId = 99
    }) -EditorHandle 4242 -TitlePattern $activeEditorTitlePattern)) `
    'an active unrelated tab must not verify the test tab'
Assert-True 'a different foreground window is not treated as the test editor' `
    (-not (Test-RealDictationActiveEditorWindow -Foreground ([pscustomobject]@{
        Handle = 9999; Title = 'nanodictate-real-dictation-abc123.txt - Notepad'; ProcessId = 99
    }) -EditorHandle 4242 -TitlePattern $activeEditorTitlePattern)) `
    'a different foreground window must not verify the test tab'
Assert-True 'a missing foreground window is not treated as the test editor' `
    (-not (Test-RealDictationActiveEditorWindow -Foreground $null `
        -EditorHandle 4242 -TitlePattern $activeEditorTitlePattern)) `
    'a missing foreground window cannot verify the test tab'

# ---------------------------------------------------------------------------
# Editor content ownership
# ---------------------------------------------------------------------------
$editorMarker = 'nanodictate-real-dictation-marker-abc123'
Assert-True 'text carrying the test document marker is owned by this run' `
    (Test-RealDictationEditorContentOwned `
        -Text "nanodictate-real-dictation-marker-abc123`r`nquick brown fox jumps" `
        -Marker $editorMarker) `
    'the marker must bind the read to the test document'
Assert-True 'text from a tab that becomes active during the read is not owned' `
    (-not (Test-RealDictationEditorContentOwned `
        -Text 'quick brown fox jumps' -Marker $editorMarker)) `
    'a tab switch during Ctrl+A/Ctrl+C must not credit another tab'
Assert-True 'an unrelated earlier transcript is not owned' `
    (-not (Test-RealDictationEditorContentOwned `
        -Text 'nanodictate-real-dictation-marker-other quick brown fox jumps' `
        -Marker $editorMarker)) `
    'another run marker must not satisfy this run'
Assert-True 'an empty read is not owned' `
    (-not (Test-RealDictationEditorContentOwned -Text '' -Marker $editorMarker)) `
    'a failed read cannot be credited'
Assert-True 'an empty marker never binds a read' `
    (-not (Test-RealDictationEditorContentOwned -Text 'quick brown fox jumps' -Marker '')) `
    'the marker must not be optional'

$markerPhrase = 'real dictation'
$markerOnlyRead = "$editorMarker`r`n"
Assert-True 'a phrase contained in the marker still proves document ownership' `
    (Test-RealDictationEditorContentOwned -Text $markerOnlyRead -Marker $editorMarker) `
    'ownership must not depend on the phrase being absent from the marker'
$markerOnlyCompared = Remove-RealDictationEditorMarker -Text $markerOnlyRead -Marker $editorMarker
Assert-Equal 'marker removal leaves no phrase behind' `
    (ConvertTo-NormalizedDictationText -Text $markerOnlyCompared) ''
Assert-True 'a phrase contained in the marker alone is not credited as insertion' `
    (-not (Test-DictationPhraseInserted -Transcript $markerOnlyCompared -Expected $markerPhrase).Matched) `
    'the seeded marker must not satisfy the phrase assertion'
$insertedAfterMarker = "$editorMarker`r`nreal dictation"
$insertedAfterMarkerCompared = Remove-RealDictationEditorMarker -Text $insertedAfterMarker -Marker $editorMarker
Assert-True 'a real insertion beside the marker is still credited' `
    ((Test-DictationPhraseInserted -Transcript $insertedAfterMarkerCompared -Expected $markerPhrase).Matched) `
    'marker removal must leave the transcribed phrase intact'
$insertedBeforeMarker = "real dictation`r`n$editorMarker"
$insertedBeforeMarkerCompared = Remove-RealDictationEditorMarker -Text $insertedBeforeMarker -Marker $editorMarker
Assert-True 'an insertion before the marker is still credited' `
    ((Test-DictationPhraseInserted -Transcript $insertedBeforeMarkerCompared -Expected $markerPhrase).Matched) `
    'the marker position must not decide the phrase assertion'

# Regression: the harness comparison must keep the expected phrase intact.
# PowerShell variable names are case-insensitive, so a local "$phraseText"
# assignment used to overwrite the $PhraseText parameter and match the editor
# text against itself.
$insertionUnrelated = Test-RealDictationInsertion `
    -EditorText "$editorMarker`r`nhello world" `
    -Marker $editorMarker -Expected 'quick brown fox jumps'
Assert-True 'an unrelated two-word transcript is not credited as insertion' `
    (-not $insertionUnrelated.Matched) `
    'an unrelated transcript must not satisfy the expected phrase'
Assert-Equal 'the expected phrase survives the unrelated comparison' `
    $insertionUnrelated.Comparison.ExpectedNormalized 'quick brown fox jumps'
Assert-Equal 'the unrelated transcript is compared unchanged' `
    $insertionUnrelated.Comparison.TranscriptNormalized 'hello world'
Assert-True 'the unrelated transcript still belongs to this run''s document' `
    $insertionUnrelated.Owned 'the marker was present, so ownership itself is not the reason'

$insertionEmpty = Test-RealDictationInsertion `
    -EditorText "$editorMarker`r`n" `
    -Marker $editorMarker -Expected 'quick brown fox jumps'
Assert-True 'an empty transcript is not credited as insertion' `
    (-not $insertionEmpty.Matched) 'a marker-only read has no transcription to credit'
Assert-Equal 'an empty transcript compares against the expected phrase' `
    $insertionEmpty.Comparison.ExpectedNormalized 'quick brown fox jumps'

$insertionUnread = Test-RealDictationInsertion -EditorText '' `
    -Marker $editorMarker -Expected 'quick brown fox jumps'
Assert-True 'an unread editor is not owned or credited' `
    (-not $insertionUnread.Owned -and -not $insertionUnread.Matched) `
    'a failed read cannot be credited'

$insertionReal = Test-RealDictationInsertion `
    -EditorText "$editorMarker`r`nquick brown fox jumps" `
    -Marker $editorMarker -Expected 'quick brown fox jumps'
Assert-True 'a real insertion is still credited' $insertionReal.Matched `
    'the marker-aware helper must not reject a genuine insertion'

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
Assert-Contains 'published qualification starts with an unknown tested commit' `
    $harness "`$testedCommit = if (`$Source -eq 'candidate' -and `$env:GITHUB_SHA) { `$env:GITHUB_SHA } else { 'unknown' }"
Assert-Contains 'published qualification requires a validated release commit' `
    $harness "if (`$null -ne `$releaseCommit -and [string]`$releaseCommit.sha -match '^[0-9a-fA-F]{40}$')"
Assert-Contains 'workflow checkout SHA stays in environment.run.sha' `
    $harness 'sha = [string]$env:GITHUB_SHA'
Assert-Contains 'harness counts phrase tokens directly' `
    $harness 'if ((Get-DictationTokens -Text $PhraseText).Count -lt 2)'
Assert-Contains 'harness requires an interactive input desktop' $harness 'InputDesktopAvailable'
Assert-Contains 'harness enumerates real WASAPI endpoints' $harness 'Get-RealDictationAudioEndpoint'
Assert-Contains 'harness focuses Notepad' $harness "notepad.exe"
Assert-Contains 'harness tolerates packaged Notepad hosting' $harness 'Get-RealDictationWindowByTitlePattern'
Assert-Contains 'harness scopes the editor fallback to its own unique file' $harness 'nanodictate-real-dictation-'
Assert-Contains 'harness requires its unique file for initial editor discovery' `
    $harness 'Where-Object { $_.Title -match $editorTitlePattern }'
Assert-NotContains 'harness initial editor discovery does not accept any Notepad title' `
    $harness "`$_.Title -match 'Notepad'"
Assert-NotContains 'harness does not infer Notepad tab ownership from a PID' `
    $harness 'Test-RealDictationEditorProcessOwned'
Assert-NotContains 'harness never closes potentially shared Notepad windows' `
    $harness 'CloseMainWindow()'
Assert-NotContains 'harness never force-stops the Notepad launcher' `
    $harness 'Stop-Process -Id $notepadProcess.Id'
Assert-NotContains 'harness never force-stops the discovered Notepad host' `
    $harness 'Stop-Process -Id $notepadWindow.ProcessId'
Assert-NotContains 'harness never force-stops Notepad by process name' `
    $harness 'Stop-Process -Name notepad'
Assert-Contains 'harness verifies the test-owned editor tab before reading' `
    $harness 'test-owned editor tab active before reading'
Assert-Contains 'harness refuses to read an unverified editor tab' `
    $harness "Method = 'active-tab-unverified'"
Assert-Contains 'harness rechecks the test-owned editor tab after reading' `
    $harness 'test-owned editor tab active after reading'
Assert-Contains 'harness rejects text read while the editor tab changed' `
    $harness "Method = 'active-tab-changed-during-read'"
Assert-Contains 'harness seeds a run-unique marker into its test document' `
    $harness "`$editorMarker = 'nanodictate-real-dictation-marker-'"
Assert-Contains 'harness binds the read text to its test document marker' `
    $harness 'Test-RealDictationInsertion -EditorText $editorText.Text'
Assert-Contains 'harness matches against the expected phrase parameter' `
    $harness '-Marker $editorMarker -Expected $PhraseText'
Assert-NotMatch 'harness never reassigns the expected phrase variable' `
    $harness '(?s)\$phraseText\s*='
Assert-NotContains 'harness no longer reuses the expected phrase variable name' `
    $harness '$phraseText'
Assert-Contains 'harness requires marker ownership before crediting insertion' `
    $harness '$phraseInserted = [bool]($match.Matched -and $contentOwned)'
Assert-Contains 'harness sends a real Double-Alt' $harness 'Send-RealDictationDoubleAlt'
Assert-Contains 'harness observes the recording HUD phase' $harness 'RecordingObserved'
Assert-Contains 'harness routes the WAV into the virtual cable' $harness 'Invoke-RealDictationWavPlayback'
Assert-Contains 'harness asserts the inserted phrase through the marker-aware helper' `
    $harness 'Test-RealDictationInsertion'
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
