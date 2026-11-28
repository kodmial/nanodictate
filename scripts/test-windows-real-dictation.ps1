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
function New-TestDirectoryLink([string]$Path, [string]$Target) {
    if (Test-RealDictationPlatform) {
        New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    }
}
function Get-WorkflowTriggerNames {
    <#
      Minimal YAML-aware extraction of the top-level `on:` mapping keys.
      PowerShell ships no YAML parser, so this walks the block structurally:
      it only accepts an `on` key at column zero, so a nested `on:` (including
      one inside a block scalar) cannot be mistaken for the top-level mapping.
      It accepts a quoted `"on"` key, quoted event keys (for example
      `"workflow_call":`), explicit mapping keys (`? workflow_call` followed
      by `:`) and comments, and stops at the next top-level key. Comparing the
      complete parsed key set keeps an extra trigger from hiding behind quoting
      or explicit key syntax, which a spelling-based regex missed. Unsupported
      event-level YAML, including inline flow mappings such as
      `on: {workflow_call: null}`, is rejected instead of silently returning
      an incomplete key set.
    #>
    param([string]$Text)

    $events = [System.Collections.Generic.List[string]]::new()
    $onIndent = $null
    $eventIndent = $null
    $explicitKeyPending = $false
    foreach ($line in ($Text -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $indent = $line.Length - $line.TrimStart().Length
        if ($null -eq $onIndent) {
            # A top-level mapping key starts at column zero. This ignores an
            # `on:` nested in another key's value, including block scalars.
            $match = [regex]::Match($line, '^(?:"on"|''on''|on)\s*:\s*(?<inline>.*)$')
            if ($match.Success) {
                $onIndent = $indent
                $inline = $match.Groups['inline'].Value.Trim()
                if ($inline -match '^\[(?<items>[^\[\]{}]*)\]$') {
                    foreach ($item in ($Matches['items'] -split ',')) {
                        $name = $item.Trim().Trim('"', "'")
                        if ($name) { $events.Add($name) }
                    }
                } elseif ($inline -and -not $inline.StartsWith('#')) {
                    # An inline flow mapping can hide an extra trigger on the
                    # `on:` line (or continue on later lines). Reject it rather
                    # than parse only part of the event set.
                    throw "Unsupported YAML syntax in the 'on:' mapping: $trimmed"
                }
            }
            continue
        }
        if ($indent -le $onIndent) { break }
        if ($null -eq $eventIndent) { $eventIndent = $indent }
        if ($indent -ne $eventIndent) { continue }
        if ($explicitKeyPending) {
            if ($trimmed.StartsWith(':')) {
                $explicitKeyPending = $false
                continue
            }
            # An explicit key may omit its value indicator on the same line.
            $explicitKeyPending = $false
        }
        if ($trimmed.StartsWith('?')) {
            $keyText = $trimmed.Substring(1).Trim()
            $inlineValue = [regex]::Match($keyText, '^(?<key>.*?)\s+:\s*(?<value>.*)$')
            if ($inlineValue.Success) {
                $keyText = $inlineValue.Groups['key'].Value.Trim()
            } else {
                $explicitKeyPending = $true
            }
            $key = [regex]::Match($keyText, '^(?:"(?<dq>[^"]+)"|''(?<sq>[^'']+)''|(?<plain>[^:#\s][^:]*?))\s*$')
            if (-not $key.Success) {
                throw "Unsupported YAML explicit key in the 'on:' mapping: $trimmed"
            }
            $name = if ($key.Groups['dq'].Success) {
                $key.Groups['dq'].Value
            } elseif ($key.Groups['sq'].Success) {
                $key.Groups['sq'].Value
            } else {
                $key.Groups['plain'].Value.Trim()
            }
            $events.Add($name)
            continue
        }
        if ($trimmed.StartsWith(':')) {
            throw "Unexpected YAML value indicator in the 'on:' mapping: $trimmed"
        }
        $key = [regex]::Match($line, '^\s*(?:"(?<dq>[^"]+)"|''(?<sq>[^'']+)''|(?<plain>[^:#\s][^:]*?))\s*:')
        if ($key.Success) {
            $name = if ($key.Groups['dq'].Success) {
                $key.Groups['dq'].Value
            } elseif ($key.Groups['sq'].Success) {
                $key.Groups['sq'].Value
            } else {
                $key.Groups['plain'].Value.Trim()
            }
            $events.Add($name)
        } else {
            throw "Unsupported YAML syntax in the 'on:' mapping: $trimmed"
        }
    }
    if ($explicitKeyPending) {
        throw "Unsupported YAML explicit key in the 'on:' mapping: missing value indicator"
    }
    return @($events)
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

$duplicateCable = @(
    [pscustomobject]@{ Id = 'cap-cable'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-cable-a'; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-cable-b'; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
)
$ambiguousPair = Get-PairedRenderEndpoint -CaptureEndpoint $duplicateCable[0] -RenderEndpoints $duplicateCable
Assert-True 'ambiguous duplicate render endpoints are not paired' `
    ($null -eq $ambiguousPair.Endpoint) 'the first duplicate must not be selected'
Assert-Match 'ambiguous pairing reports the duplicate endpoints' `
    $ambiguousPair.Reason 'ambiguous render endpoints'
$ambiguousRoute = Resolve-VirtualAudioRoute -Endpoints $duplicateCable `
    -DefaultCaptureEndpoint $duplicateCable[0]
Assert-True 'ambiguous render pairing blocks the reachable route' `
    (-not $ambiguousRoute.CaptureEndpointReachable) `
    'a reachable route requires one unambiguous render endpoint'

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

$routeExactIdFirst = Resolve-VirtualAudioRoute -Endpoints @(
    [pscustomobject]@{ Id = ''; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'cap-default'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-default'; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
) -DefaultCaptureEndpoint ([pscustomobject]@{ Id = 'cap-default'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' })
Assert-Equal 'an exact capture id wins over an earlier same-named candidate' `
    $routeExactIdFirst.VirtualCapture.Id 'cap-default'
Assert-True 'the exact id candidate is the product default' `
    $routeExactIdFirst.DefaultCaptureIsVirtual 'the id match must win'

$routeAmbiguousName = Resolve-VirtualAudioRoute -Endpoints @(
    [pscustomobject]@{ Id = ''; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = ''; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = 'ren-cable'; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
) -DefaultCaptureEndpoint ([pscustomobject]@{ Id = ''; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' })
Assert-True 'an ambiguous friendly-name fallback is not the product default' `
    (-not $routeAmbiguousName.DefaultCaptureIsVirtual) 'a name must identify exactly one candidate'

$routeNoRenderId = Resolve-VirtualAudioRoute -Endpoints @(
    [pscustomobject]@{ Id = 'cap-cable'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' }
    [pscustomobject]@{ Id = ''; Name = 'CABLE Input (VB-Audio Virtual Cable)'; Flow = 'render'; State = 'active' }
) -DefaultCaptureEndpoint ([pscustomobject]@{ Id = 'cap-cable'; Name = 'CABLE Output (VB-Audio Virtual Cable)'; Flow = 'capture'; State = 'active' })
Assert-True 'a render endpoint without a usable device id is not reachable' `
    (-not $routeNoRenderId.CaptureEndpointReachable) 'playback needs a device id'
Assert-Match 'an unusable render id is explained' `
    $routeNoRenderId.PairedRenderReason 'no usable device id'

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
# HUD attribution
# ---------------------------------------------------------------------------
$recordingHud = [pscustomobject]@{ Handle = 11; Width = 220; Height = 178 }
$recordingBaseline = @([pscustomobject]@{ Handle = 11; Width = 220; Height = 178; Phase = 'recording' })
Assert-Equal 'HUD geometry classifies the recording panel' `
    (Get-RealDictationHudPhase -Window $recordingHud) 'recording'
Assert-Equal 'HUD phase scales with the observed width' `
    (Get-RealDictationHudPhase -Window ([pscustomobject]@{ Handle = 14; Width = 440; Height = 356 })) 'recording'
Assert-True 'an unchanged pre-existing recording HUD is not a new activation' `
    (-not (Test-RealDictationHudChanged -Window $recordingHud -Baseline $recordingBaseline)) `
    'a baseline window that never changes must not credit activation'
Assert-True 'a resize of a pre-existing recording HUD is not a new activation' `
    (-not (Test-RealDictationHudChanged -Window ([pscustomobject]@{ Handle = 11; Width = 440; Height = 356 }) -Baseline $recordingBaseline)) `
    'recording-to-recording geometry changes must not credit activation'
$idleBaseline = @([pscustomobject]@{ Handle = 12; Width = 220; Height = 150; Phase = 'starting-or-error' })
Assert-True 'a pre-existing starting HUD that reaches recording without the test hotkey is not a new activation' `
    (-not (Test-RealDictationHudChanged -Window ([pscustomobject]@{ Handle = 12; Width = 220; Height = 178 }) -Baseline $idleBaseline)) `
    'an earlier capture can advance starting to recording when its first audio block arrives'
Assert-True 'a new HUD handle is not credited while a pre-existing HUD is visible' `
    (-not (Test-RealDictationHudChanged -Window ([pscustomobject]@{ Handle = 13; Width = 220; Height = 178 }) -Baseline $recordingBaseline)) `
    'HUD attribution requires a hidden baseline'
Assert-True 'a HUD that appears after a hidden baseline is attributable' `
    (Test-RealDictationHudChanged -Window ([pscustomobject]@{ Handle = 13; Width = 220; Height = 178 }) -Baseline @()) `
    'a window observed while no agent HUD was visible is a post-hotkey appearance'

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
# Parse the `on:` mapping structurally and assert its complete event set.
# Workflow_run, workflow_call or any other extra trigger must fail this, even
# when the key is quoted, not only push and schedule.
$triggerNames = @(Get-WorkflowTriggerNames -Text $workflow)
Assert-Equal 'qualification workflow declares exactly the workflow_dispatch trigger' `
    ($triggerNames -join ',') 'workflow_dispatch'
Assert-Equal 'trigger parsing includes a quoted extra event' `
    ((Get-WorkflowTriggerNames -Text "`"on`":`n  workflow_dispatch:`n  `"workflow_call`":`n    inputs: {}`n") -join ',') `
    'workflow_dispatch,workflow_call'
Assert-Equal 'trigger parsing reads an explicit mapping key' `
    ((Get-WorkflowTriggerNames -Text "on:`n  workflow_dispatch:`n  ? workflow_call`n  :`n") -join ',') `
    'workflow_dispatch,workflow_call'
Assert-Equal 'trigger parsing reads a flow sequence' `
    ((Get-WorkflowTriggerNames -Text "on: [workflow_dispatch]`n") -join ',') 'workflow_dispatch'
Assert-Throws 'trigger parsing rejects an inline flow mapping' {
    Get-WorkflowTriggerNames -Text "on: {workflow_call: null,`n  workflow_dispatch: null}`n"
} 'Unsupported YAML'
Assert-Throws 'trigger parsing rejects a single-line inline flow mapping' {
    Get-WorkflowTriggerNames -Text "on: {workflow_dispatch: null}`n"
} 'Unsupported YAML'
Assert-Equal 'trigger parsing ignores an on key inside a block scalar' `
    ((Get-WorkflowTriggerNames -Text "name: |`n  on:`n    workflow_dispatch:`non:`n  workflow_dispatch:`n  workflow_call:`n") -join ',') `
    'workflow_dispatch,workflow_call'
Assert-Equal 'trigger parsing ignores an indented on key' `
    ((Get-WorkflowTriggerNames -Text "jobs:`n  build:`n    on: ignored`non:`n  workflow_dispatch:`n") -join ',') `
    'workflow_dispatch'
Assert-Throws 'trigger parsing rejects unsupported event-level YAML' {
    Get-WorkflowTriggerNames -Text "on:`n  - workflow_dispatch`n"
} 'Unsupported YAML'
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
Assert-Contains 'qualification artifact name includes the run attempt' $workflow '${{ github.run_attempt }}'
Assert-Match 'qualification requires a descendant path at a directory boundary' `
    $workflow 'StartsWith\(\$prefix, \[StringComparison\]::OrdinalIgnoreCase\)'
Assert-Contains 'qualification rejects a config inside uploaded evidence' `
    $workflow 'ND_CONFIG_PATH must not point into an uploaded evidence directory'
Assert-Match 'qualification gates candidate setup on a non-probe full run' `
    $workflow "inputs\.source == 'candidate' && !inputs\.probe_only"
Assert-Match 'qualification keeps the candidate installer out of probe-only runs' `
    $workflow "ND_PROBE_ONLY -ne 'true'"
Assert-Match 'qualification skips fixture resolution in probe-only runs' `
    $workflow '(?s)if \(\$env:ND_PROBE_ONLY -ne ''true''\) \{\s*foreach \(\$option'

# The qualification workflow is dispatch-only, so its focused contract tests
# also run there. A separate non-required pull-request check gives them a
# passing result without becoming a new pass condition on the required Windows
# host job (issue #254 keeps CI gates unchanged).
$windowsHostWorkflow = Read-Text '.github/workflows/windows.yml'
Assert-NotContains 'required Windows host CI does not run the qualification contract tests' `
    $windowsHostWorkflow 'pwsh -NoProfile -File scripts/test-windows-real-dictation.ps1'
$contractWorkflow = Read-Text '.github/workflows/windows-real-dictation-contracts.yml'
Assert-Match 'a separate non-required check runs on pull requests' `
    $contractWorkflow '(?m)^  pull_request:'
Assert-Contains 'the separate check runs the qualification contract tests' `
    $contractWorkflow 'pwsh -NoProfile -File scripts/test-windows-real-dictation.ps1'

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
# PowerShell variable names are case-insensitive, so a differently cased
# assignment (for example $PHRASETEXT = $insertion.TranscriptText) must also be
# rejected. A case-sensitive regex misses it, and a case-insensitive one would
# also match the parameter default, so inspect real assignment targets with the
# PowerShell parser.
$harnessTokens = $null
$harnessParseErrors = $null
$harnessAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'windows/package/test-real-dictation.ps1'), [ref]$harnessTokens, [ref]$harnessParseErrors)
Assert-True 'harness parses without syntax errors' ($harnessParseErrors.Count -eq 0) `
    ($harnessParseErrors -join '; ')
$phraseReassignments = @($harnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'PhraseText'
}, $true))
Assert-Equal 'harness never reassigns the expected phrase variable' $phraseReassignments.Count 0
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
Assert-Contains 'harness requires window evidence for a window screenshot' `
    $harness '$result.WindowEvidence'
Assert-Contains 'harness records screenshot capture failures instead of aborting' `
    $harness 'was not captured because the capture call failed'
Assert-Match 'harness catches screenshot capture exceptions and continues' `
    $harness '(?s)try \{\s*\$result = Save-RealDictationScreenshot.*?\}\s*catch \{.*?return'
Assert-Contains 'harness restores a replaced provider config' $harness '$configExistedBefore'
Assert-Contains 'harness resolves a config backup outside evidence directories' `
    $harness 'Resolve-RealDictationConfigBackupDirectory'
Assert-Contains 'harness excludes both evidence directories from the config backup' `
    $harness '-ExcludedDirectory @($EvidenceDirectory, $LogDirectory)'
Assert-NotContains 'harness does not use the raw temp path for the config backup' `
    $harness 'Join-Path ([System.IO.Path]::GetTempPath())'
Assert-Contains 'harness captures the pre-install config state' `
    $harness 'Get-RealDictationProviderConfigState'
Assert-Match 'harness snapshots the config before invoking setup' `
    $harness '(?s)\$configTarget = Join-Path \$env:APPDATA.*?Get-RealDictationProviderConfigState.*?Invoke-BoundedInstallerProcess -FilePath \$installer'
Assert-Match 'harness requires cleanup before setup can create the config' `
    $harness '(?s)\$configCleanupRequired = \$true.*?Invoke-BoundedInstallerProcess -FilePath \$installer'
Assert-Contains 'harness delegates config restoration and retention' `
    $harness 'Complete-RealDictationProviderConfigCleanup'
Assert-Match 'harness keeps the backup directory when restoration fails' `
    $harness '(?s)if \(-not \$configRestoreFailed.*?Remove-Item -LiteralPath \$configBackupDirectory'
Assert-Contains 'harness reports a failed config restoration' `
    $harness 'Could not restore the provider config'
Assert-Contains 'harness detects a registered installation before setup' `
    $harness 'Get-RealDictationRegisteredInstallation'
Assert-Match 'harness refuses a registered installation before invoking setup' `
    $harness '(?s)Get-RealDictationRegisteredInstallation.*?throw "A registered NanoDictate installation'
Assert-Contains 'harness refuses a non-empty installation directory before setup' `
    $harness 'already contains files'
Assert-Match 'harness removes partial setup files when no uninstaller exists' `
    $harness '(?s)unins000\.exe.*?Remove-Item -LiteralPath \$installedDirectory -Recurse -Force'
Assert-Contains 'harness records an audio probe error instead of aborting' `
    $harness "'audio endpoint probe'"
Assert-Contains 'harness keeps the GUI leg when the audio probe fails' $harness '$audioProbeError'
Assert-Contains 'harness refuses an existing NanoDictate startup entry' `
    $harness 'existing NanoDictate startup entry already exists'
Assert-Contains 'harness rechecks the test tab before requesting transcription' `
    $harness 'test-owned editor tab active before requesting transcription'
Assert-Contains 'harness cancels instead of transcribing into another editor' `
    $harness 'the recording was cancelled so the transcript cannot be inserted into another document'
Assert-Contains 'harness records the activation-time default capture flag' `
    $harness '$audioFlags.DefaultCaptureIsVirtual = $routeReachableAtActivation'
Assert-Contains 'harness preserves the uninstaller when uninstallation is unconfirmed' `
    $harness '$uninstallConfirmed'
Assert-Contains 'harness removes only unregistered partial installations' `
    $harness '$partialInstallation'
Assert-Contains 'harness exits nonzero when the provider config cannot be restored' `
    $harness '-Failed:([bool]$fatal -or $configRestoreFailed -or $cleanupFailed)'

$uninstallKeys = @(Get-RealDictationUninstallRegistryPaths -AppId 'NanoDictate')
Assert-Equal 'uninstall registration probes three registry scopes' $uninstallKeys.Count 3
Assert-True 'uninstall registration probes the per-user key' `
    ($uninstallKeys -contains 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NanoDictate_is1') `
    'the per-user uninstall key is missing'
Assert-True 'uninstall registration probes the machine-wide key' `
    ($uninstallKeys -contains 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NanoDictate_is1') `
    'the machine-wide uninstall key is missing'
Assert-True 'uninstall registration probes the 32-bit machine-wide key' `
    ($uninstallKeys -contains 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\NanoDictate_is1') `
    'the 32-bit machine-wide uninstall key is missing'
$guidAppId = '{12345678-1234-1234-1234-123456789012}'
$guidKeys = @(Get-RealDictationUninstallRegistryPaths -AppId $guidAppId)
Assert-True 'a GUID AppId also receives the Inno Setup suffix' `
    ($guidKeys -contains "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\${guidAppId}_is1") `
    'the suffixed GUID uninstall key is missing'
if (-not (Test-RealDictationPlatform)) {
    Assert-True 'registered installation lookup is empty off Windows' `
        ($null -eq (Get-RealDictationRegisteredInstallation)) `
        'a non-Windows host must not probe the Windows registry'
}

$configRestoreRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('nd-config-restore-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $configRestoreRoot | Out-Null
try {
    $restoreTarget = Join-Path $configRestoreRoot 'config.toml'
    $restoreBackup = Join-Path $configRestoreRoot 'config.backup.toml'
    Set-Content -LiteralPath $restoreTarget -Value 'test-copy'
    Set-Content -LiteralPath $restoreBackup -Value 'original'
    Restore-RealDictationProviderConfig -TargetPath $restoreTarget -BackupPath $restoreBackup -ExistedBefore $true
    Assert-Equal 'restores the preserved provider config' `
        (Get-Content -LiteralPath $restoreTarget -Raw).Trim() 'original'

    Set-Content -LiteralPath $restoreTarget -Value 'test-copy'
    Restore-RealDictationProviderConfig -TargetPath $restoreTarget -BackupPath '' -ExistedBefore $false
    Assert-True 'removes only the config created by the test' `
        (-not (Test-Path -LiteralPath $restoreTarget)) `
        'a test-created config must not remain after cleanup'

    Assert-Throws 'a missing config backup fails restoration' {
        Restore-RealDictationProviderConfig -TargetPath $restoreTarget `
            -BackupPath (Join-Path $configRestoreRoot 'missing.toml') -ExistedBefore $true
    } 'backup is missing'

    $snapshotRoot = Join-Path $configRestoreRoot 'snapshot'
    $snapshotTarget = Join-Path $snapshotRoot 'config.toml'
    $snapshotBackupDirectory = Join-Path $snapshotRoot 'backup'
    New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
    $missingSnapshot = Get-RealDictationProviderConfigState `
        -TargetPath $snapshotTarget -BackupDirectory $snapshotBackupDirectory
    Assert-True 'a missing config is recorded as absent before installation' `
        (-not $missingSnapshot.ExistedBefore) 'config must be recorded as absent'
    Assert-True 'a missing config has no backup' `
        ($null -eq $missingSnapshot.BackupPath) 'a missing config must not produce a backup'
    Set-Content -LiteralPath $snapshotTarget -Value 'installer-default'
    $missingCleanup = Complete-RealDictationProviderConfigCleanup `
        -TargetPath $snapshotTarget -BackupPath $missingSnapshot.BackupPath `
        -ExistedBefore $missingSnapshot.ExistedBefore
    Assert-True 'cleanup removes a config created after the pre-install snapshot' `
        (-not (Test-Path -LiteralPath $snapshotTarget)) `
        'a config created by the installer must be removed'

    Set-Content -LiteralPath $snapshotTarget -Value 'original'
    $existingSnapshot = Get-RealDictationProviderConfigState `
        -TargetPath $snapshotTarget -BackupDirectory $snapshotBackupDirectory
    Assert-True 'an existing config is recorded before installation' `
        $existingSnapshot.ExistedBefore 'config must be recorded as present'
    Assert-True 'an existing config is preserved before installation' `
        ($existingSnapshot.BackupPath -and
            (Test-Path -LiteralPath $existingSnapshot.BackupPath -PathType Leaf)) `
        'backup was not created'
    Set-Content -LiteralPath $snapshotTarget -Value 'installer-replacement'
    $existingCleanup = Complete-RealDictationProviderConfigCleanup `
        -TargetPath $snapshotTarget -BackupPath $existingSnapshot.BackupPath `
        -ExistedBefore $existingSnapshot.ExistedBefore
    Assert-True 'cleanup after a pre-install snapshot does not fail' `
        (-not $existingCleanup.RestoreFailed) $existingCleanup.ErrorMessage
    Assert-Equal 'cleanup restores the config captured before installation' `
        (Get-Content -LiteralPath $snapshotTarget -Raw).Trim() 'original'

    $evidenceRoot = Join-Path $configRestoreRoot 'evidence'
    $logRoot = Join-Path $configRestoreRoot 'logs'
    $nestedEvidence = Join-Path $evidenceRoot 'nested'
    New-Item -ItemType Directory -Force -Path $nestedEvidence, $logRoot | Out-Null
    $backupDirectory = Resolve-RealDictationConfigBackupDirectory `
        -ExcludedDirectory @($evidenceRoot, $logRoot) `
        -CandidateDirectory @($nestedEvidence)
    Assert-True 'config backup directory is outside the evidence directory' `
        (-not (Test-RealDictationPathInside -Path $backupDirectory -Directory $evidenceRoot)) `
        "resolved inside $evidenceRoot"
    Assert-True 'config backup directory is outside the log directory' `
        (-not (Test-RealDictationPathInside -Path $backupDirectory -Directory $logRoot)) `
        "resolved inside $logRoot"
    Assert-True 'config backup directory exists' `
        (Test-Path -LiteralPath $backupDirectory -PathType Container) `
        "missing $backupDirectory"
    Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue

    $scratchEvidence = Join-Path $configRestoreRoot 'scratch-evidence'
    $nestedScratchEvidence = Join-Path $scratchEvidence 'nested'
    New-Item -ItemType Directory -Force -Path $nestedScratchEvidence | Out-Null
    $scratchDirectory = Resolve-RealDictationScratchDirectory `
        -ExcludedDirectory @($scratchEvidence) `
        -CandidateDirectory @($nestedScratchEvidence)
    Assert-True 'scratch staging stays outside the uploaded evidence directory' `
        (-not (Test-RealDictationPathInside -Path $scratchDirectory -Directory $scratchEvidence)) `
        "resolved inside $scratchEvidence"
    Assert-True 'scratch staging creates a writable directory' `
        (Test-Path -LiteralPath $scratchDirectory -PathType Container) `
        "missing $scratchDirectory"
    Remove-Item -LiteralPath $scratchDirectory -Recurse -Force -ErrorAction SilentlyContinue

    $aliasReal = Join-Path $configRestoreRoot 'alias-real'
    $aliasLink = Join-Path $configRestoreRoot 'alias-link'
    $aliasNested = Join-Path $aliasReal 'nested'
    New-Item -ItemType Directory -Force -Path $aliasNested | Out-Null
    New-TestDirectoryLink -Path $aliasLink -Target $aliasReal
    Assert-True 'path containment resolves a directory alias' `
        (Test-RealDictationPathInside -Path (Join-Path $aliasLink 'nested') -Directory $aliasReal) `
        "alias $aliasLink must resolve under $aliasReal"
    Assert-True 'path containment resolves an aliased directory' `
        (Test-RealDictationPathInside -Path $aliasNested -Directory $aliasLink) `
        "alias $aliasLink must resolve under $aliasReal"

    $aliasEvidence = Join-Path $configRestoreRoot 'alias-evidence'
    New-TestDirectoryLink -Path $aliasEvidence -Target $aliasReal
    $aliasedBackupDirectory = Resolve-RealDictationConfigBackupDirectory `
        -ExcludedDirectory @($aliasEvidence) `
        -CandidateDirectory @($aliasReal)
    Assert-True 'config backup avoids a directory alias to the candidate' `
        (-not (Test-RealDictationPathInside -Path $aliasedBackupDirectory -Directory $aliasEvidence)) `
        "resolved inside $aliasEvidence"
    Assert-True 'config backup avoids the aliased candidate directory' `
        (-not (Test-RealDictationPathInside -Path $aliasedBackupDirectory -Directory $aliasReal)) `
        "resolved inside $aliasReal"
    Remove-Item -LiteralPath $aliasedBackupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $aliasEvidence -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $aliasLink -Force -ErrorAction SilentlyContinue

    $partialTarget = Join-Path $configRestoreRoot 'partial-config.toml'
    $partialSource = Join-Path $configRestoreRoot 'operator-config.toml'
    $partialBackupDirectory = Join-Path $configRestoreRoot 'partial-backup'
    Set-Content -LiteralPath $partialTarget -Value 'original'
    Set-Content -LiteralPath $partialSource -Value 'replacement'
    $partialBackup = Backup-RealDictationProviderConfig `
        -TargetPath $partialTarget -BackupDirectory $partialBackupDirectory
    Assert-True 'preserves the existing config before replacement' `
        ($partialBackup -and (Test-Path -LiteralPath $partialBackup -PathType Leaf)) `
        'backup was not created'
    Assert-Throws 'a partial replacement failure is surfaced' {
        Set-RealDictationProviderConfig -TargetPath $partialTarget -SourcePath $partialSource `
            -CopyItem {
                param($From, $To)
                Set-Content -LiteralPath $To -Value 'partial'
                throw 'simulated partial replacement failure'
            }
    } 'simulated partial replacement failure'
    Assert-Equal 'a partial replacement writes partial content before failing' `
        (Get-Content -LiteralPath $partialTarget -Raw).Trim() 'partial'
    Assert-Equal 'a partial replacement leaves the original backup intact' `
        (Get-Content -LiteralPath $partialBackup -Raw).Trim() 'original'
    $partialCleanup = Complete-RealDictationProviderConfigCleanup `
        -TargetPath $partialTarget -BackupPath $partialBackup -ExistedBefore $true
    Assert-True 'a partial replacement failure does not fail cleanup' `
        (-not $partialCleanup.RestoreFailed) $partialCleanup.ErrorMessage
    Assert-Equal 'a partial replacement failure restores the original config immediately' `
        (Get-Content -LiteralPath $partialTarget -Raw).Trim() 'original'
    Assert-True 'a partial replacement failure removes the restored backup' `
        (-not (Test-Path -LiteralPath $partialBackup)) 'backup must not remain'
    Set-RealDictationProviderConfig -TargetPath $partialTarget -SourcePath $partialSource
    Assert-Equal 'applies the supplied provider config' `
        (Get-Content -LiteralPath $partialTarget -Raw).Trim() 'replacement'

    $blockedParent = Join-Path $configRestoreRoot 'not-a-directory'
    Set-Content -LiteralPath $blockedParent -Value 'blocks directory creation'
    $retainedTarget = Join-Path $blockedParent 'config.toml'
    $retainedBackupDirectory = Join-Path $configRestoreRoot 'retained-backup'
    New-Item -ItemType Directory -Force -Path $retainedBackupDirectory | Out-Null
    $retainedBackup = Join-Path $retainedBackupDirectory 'config.toml'
    Set-Content -LiteralPath $retainedBackup -Value 'original'
    $retained = Complete-RealDictationProviderConfigCleanup `
        -TargetPath $retainedTarget -BackupPath $retainedBackup -ExistedBefore $true
    Assert-True 'a failed restoration is reported' $retained.RestoreFailed 'restoration should fail'
    Assert-True 'a failed restoration retains the backup' $retained.BackupRetained 'backup must be retained'
    Assert-True 'the retained backup still exists' `
        (Test-Path -LiteralPath $retainedBackup -PathType Leaf) 'backup was deleted'

    $cleanTarget = Join-Path $configRestoreRoot 'clean-config.toml'
    $cleanBackupDirectory = Join-Path $configRestoreRoot 'clean-backup'
    New-Item -ItemType Directory -Force -Path $cleanBackupDirectory | Out-Null
    $cleanBackup = Join-Path $cleanBackupDirectory 'config.toml'
    Set-Content -LiteralPath $cleanTarget -Value 'test-copy'
    Set-Content -LiteralPath $cleanBackup -Value 'original'
    $cleanup = Complete-RealDictationProviderConfigCleanup `
        -TargetPath $cleanTarget -BackupPath $cleanBackup -ExistedBefore $true
    Assert-True 'successful cleanup reports no restore failure' `
        (-not $cleanup.RestoreFailed) 'unexpected restore failure'
    Assert-Equal 'successful cleanup restores the original config' `
        (Get-Content -LiteralPath $cleanTarget -Raw).Trim() 'original'
    Assert-True 'successful cleanup removes the backup' `
        (-not (Test-Path -LiteralPath $cleanBackup)) 'backup must not remain'

    # Run the real harness with stub modules so setup fails after creating or
    # replacing the user config. This exercises the harness finally block, not
    # just the cleanup helper, and proves a failed installation still restores
    # an existing config or removes one the installer created.
    $failureRoot = Join-Path $configRestoreRoot 'installer-failure'
    $harnessRoot = Join-Path $failureRoot 'repo'
    $harnessPackage = Join-Path $harnessRoot 'windows/package'
    $stubScripts = Join-Path $harnessRoot 'scripts'
    New-Item -ItemType Directory -Force -Path $harnessPackage, $stubScripts | Out-Null
    $harnessCopy = Join-Path $harnessPackage 'test-real-dictation.ps1'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'windows/package/test-real-dictation.ps1') `
        -Destination $harnessCopy -Force
    $realModulePath = Join-Path $repoRoot 'scripts/windows-real-dictation.psm1'
    $moduleStub = @'
Import-Module '__REAL_MODULE__' -Force
function Test-RealDictationPlatform { return $true }
function Get-RealDictationSessionProbe {
    return [pscustomobject]@{
        SessionId = 1
        DesktopName = 'Default'
        InputDesktopAvailable = $true
        UserInteractive = $true
    }
}
function Get-RealDictationAudioEndpoint {
    param([string]$DefaultFlow = 'capture')
    return [pscustomobject]@{ Endpoints = @(); DefaultCapture = $null }
}
function Resolve-VirtualAudioRoute {
    param($Endpoints, $DefaultCaptureEndpoint)
    return [pscustomobject]@{
        VirtualCapture = $null
        DefaultCaptureIsVirtual = $false
        PairedRender = $null
        Reason = 'simulated missing virtual capture endpoint'
        PairedRenderReason = 'simulated missing paired render endpoint'
    }
}
function Get-RealDictationRegisteredInstallation {
    param([string]$AppId = 'NanoDictate')
    if ($env:ND_TEST_REGISTERED_INSTALL_LOCATION) {
        return [pscustomobject]@{
            KeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NanoDictate_is1'
            InstallLocation = $env:ND_TEST_REGISTERED_INSTALL_LOCATION
        }
    }
    return $null
}
Export-ModuleMember -Function *
'@
    $moduleStub = $moduleStub.Replace('__REAL_MODULE__', $realModulePath.Replace("'", "''"))
    Set-Content -LiteralPath (Join-Path $stubScripts 'windows-real-dictation.psm1') `
        -Value $moduleStub -Encoding utf8
    $runnerStub = @'
function Invoke-BoundedInstallerProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Phase,
        [int]$TimeoutSeconds,
        [string]$LogDirectory,
        [string]$InnoLogFileName
    )
    if ($env:ND_TEST_INSTALLER_MARKER) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $env:ND_TEST_INSTALLER_MARKER) | Out-Null
        Set-Content -LiteralPath $env:ND_TEST_INSTALLER_MARKER -Value 'invoked' -Encoding utf8
    }
    if ($env:ND_TEST_INSTALLER_PARTIAL) {
        $partialDirectory = Join-Path $env:LOCALAPPDATA 'Programs\NanoDictate'
        New-Item -ItemType Directory -Force -Path $partialDirectory | Out-Null
        Set-Content -LiteralPath (Join-Path $partialDirectory 'partial-install.tmp') -Value 'partial' -Encoding utf8
        if ($env:ND_TEST_INSTALLER_PARTIAL_MARKER) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $env:ND_TEST_INSTALLER_PARTIAL_MARKER) | Out-Null
            Set-Content -LiteralPath $env:ND_TEST_INSTALLER_PARTIAL_MARKER -Value 'payload-created' -Encoding utf8
        }
    }
    $target = $env:ND_TEST_INSTALLER_CONFIG
    if ($target) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Set-Content -LiteralPath $target -Value 'installer-created' -Encoding utf8
    }
    throw 'simulated installer failure after creating the user config'
}
function Stop-NanoDictateProcessesUnderPath {
    param([string]$InstallDirectory, [int]$TimeoutSeconds = 15)
    return 0
}
Export-ModuleMember -Function 'Invoke-BoundedInstallerProcess', 'Stop-NanoDictateProcessesUnderPath'
'@
    Set-Content -LiteralPath (Join-Path $stubScripts 'windows-installer-runner.psm1') `
        -Value $runnerStub -Encoding utf8
    $fakeInstaller = Join-Path $failureRoot 'setup.exe'
    Set-Content -LiteralPath $fakeInstaller -Value 'simulated installer payload' -Encoding utf8
    $operatorConfig = Join-Path $failureRoot 'operator-config.toml'
    Set-Content -LiteralPath $operatorConfig -Value 'operator-config' -Encoding utf8
    $pwshPath = (Get-Process -Id $PID).Path
    $savedEnvironment = @{
        APPDATA = $env:APPDATA
        LOCALAPPDATA = $env:LOCALAPPDATA
        RUNNER_TEMP = $env:RUNNER_TEMP
        TMPDIR = $env:TMPDIR
        TMP = $env:TMP
        TEMP = $env:TEMP
        ND_TEST_INSTALLER_CONFIG = $env:ND_TEST_INSTALLER_CONFIG
        ND_TEST_INSTALLER_MARKER = $env:ND_TEST_INSTALLER_MARKER
        ND_TEST_INSTALLER_PARTIAL = $env:ND_TEST_INSTALLER_PARTIAL
        ND_TEST_INSTALLER_PARTIAL_MARKER = $env:ND_TEST_INSTALLER_PARTIAL_MARKER
        ND_TEST_REGISTERED_INSTALL_LOCATION = $env:ND_TEST_REGISTERED_INSTALL_LOCATION
    }
    try {
        $failureScenarios = @(
            @{ Name = 'installer failure restores the pre-existing config'; Existing = 'original'; NoRunnerTemp = $false }
            @{ Name = 'installer failure removes a config it created'; Existing = $null; NoRunnerTemp = $false }
            @{ Name = 'installer failure without RUNNER_TEMP keeps scratch outside evidence'; Existing = $null; NoRunnerTemp = $true }
        )
        foreach ($scenario in $failureScenarios) {
            $scenarioRoot = Join-Path $failureRoot ([guid]::NewGuid().ToString('N'))
            $appData = Join-Path $scenarioRoot 'appdata'
            $localAppData = Join-Path $scenarioRoot 'localappdata'
            $tempDirectory = Join-Path $scenarioRoot 'temp'
            $evidenceDirectory = Join-Path $scenarioRoot 'evidence'
            $logDirectory = Join-Path $scenarioRoot 'logs'
            New-Item -ItemType Directory -Force -Path `
                $appData, $localAppData, $tempDirectory, $evidenceDirectory, $logDirectory | Out-Null
            $target = Join-Path $appData 'NanoDictate\config.toml'
            if ($null -ne $scenario.Existing) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                Set-Content -LiteralPath $target -Value $scenario.Existing -Encoding utf8
            }
            $env:APPDATA = $appData
            $env:LOCALAPPDATA = $localAppData
            if ($scenario.NoRunnerTemp) {
                Remove-Item -Path 'Env:RUNNER_TEMP' -ErrorAction SilentlyContinue
            } else {
                $env:RUNNER_TEMP = $tempDirectory
            }
            $env:TMPDIR = $tempDirectory
            $env:TMP = $tempDirectory
            $env:TEMP = $tempDirectory
            $env:ND_TEST_INSTALLER_CONFIG = $target
            $env:ND_TEST_INSTALLER_MARKER = ''
            $env:ND_TEST_INSTALLER_PARTIAL = ''
            $env:ND_TEST_INSTALLER_PARTIAL_MARKER = ''
            $env:ND_TEST_REGISTERED_INSTALL_LOCATION = ''
            & $pwshPath -NoProfile -File $harnessCopy `
                -Source candidate -InstallerPath $fakeInstaller -ConfigPath $operatorConfig `
                -PhraseText 'two words' -EvidenceDirectory $evidenceDirectory `
                -LogDirectory $logDirectory *> (Join-Path $scenarioRoot 'harness.log')
            $exitCode = $LASTEXITCODE
            Assert-Equal "$($scenario.Name): harness reports the installer failure" $exitCode 1
            $evidencePath = Join-Path $evidenceDirectory 'evidence.json'
            Assert-True "$($scenario.Name): harness writes evidence after the failure" `
                (Test-Path -LiteralPath $evidencePath -PathType Leaf) 'evidence.json is missing'
            if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
                $failureEvidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
                $fatalSegments = @($failureEvidence.segments | Where-Object { $_.name -eq 'qualification harness' })
                Assert-True "$($scenario.Name): evidence records the simulated installer failure" `
                    ($fatalSegments.Count -eq 1 -and
                        $fatalSegments[0].detail -match 'simulated installer failure') `
                    'the failure segment did not describe the installer failure'
            }
            if ($scenario.NoRunnerTemp) {
                Assert-True "$($scenario.Name): no temp staging remains inside the evidence directory" `
                    (-not (Test-Path -LiteralPath (Join-Path $evidenceDirectory '.tmp'))) `
                    'the harness staged local temp inside the uploaded evidence directory'
            }
            if ($null -ne $scenario.Existing) {
                Assert-True "$($scenario.Name): restored config still exists" `
                    (Test-Path -LiteralPath $target -PathType Leaf) 'restored config is missing'
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    Assert-Equal "$($scenario.Name): config content is restored" `
                        (Get-Content -LiteralPath $target -Raw).Trim() $scenario.Existing
                }
            } else {
                Assert-True "$($scenario.Name): created config is removed" `
                    (-not (Test-Path -LiteralPath $target)) `
                    'an installer-created config must not remain after a failed setup'
            }
        }

        # A registered installation in another directory must stop the harness
        # before Inno Setup's UsePreviousAppDir can reuse and modify it.
        $registeredRoot = Join-Path $failureRoot ('registered-' + [guid]::NewGuid().ToString('N'))
        $registeredAppData = Join-Path $registeredRoot 'appdata'
        $registeredLocalAppData = Join-Path $registeredRoot 'localappdata'
        $registeredTemp = Join-Path $registeredRoot 'temp'
        $registeredEvidence = Join-Path $registeredRoot 'evidence'
        $registeredLogs = Join-Path $registeredRoot 'logs'
        New-Item -ItemType Directory -Force -Path `
            $registeredAppData, $registeredLocalAppData, $registeredTemp, `
            $registeredEvidence, $registeredLogs | Out-Null
        $registeredInstall = Join-Path $registeredRoot 'elsewhere/NanoDictate'
        New-Item -ItemType Directory -Force -Path $registeredInstall | Out-Null
        $registeredSentinel = Join-Path $registeredInstall 'NanoDictate.App.exe'
        Set-Content -LiteralPath $registeredSentinel -Value 'pre-existing' -Encoding utf8
        $installerMarker = Join-Path $registeredRoot 'installer-invoked.txt'
        $env:APPDATA = $registeredAppData
        $env:LOCALAPPDATA = $registeredLocalAppData
        $env:RUNNER_TEMP = $registeredTemp
        $env:TMPDIR = $registeredTemp
        $env:TMP = $registeredTemp
        $env:TEMP = $registeredTemp
        $env:ND_TEST_INSTALLER_CONFIG = ''
        $env:ND_TEST_INSTALLER_MARKER = $installerMarker
        $env:ND_TEST_INSTALLER_PARTIAL = ''
        $env:ND_TEST_INSTALLER_PARTIAL_MARKER = ''
        $env:ND_TEST_REGISTERED_INSTALL_LOCATION = $registeredInstall
        & $pwshPath -NoProfile -File $harnessCopy `
            -Source candidate -InstallerPath $fakeInstaller `
            -PhraseText 'two words' -EvidenceDirectory $registeredEvidence `
            -LogDirectory $registeredLogs *> (Join-Path $registeredRoot 'harness.log')
        $registeredExitCode = $LASTEXITCODE
        Assert-Equal 'registered installation: harness refuses the run' $registeredExitCode 1
        Assert-True 'registered installation: setup is never invoked' `
            (-not (Test-Path -LiteralPath $installerMarker)) `
            'the installer ran despite a registered installation'
        Assert-True 'registered installation: the pre-existing payload is untouched' `
            (Test-Path -LiteralPath $registeredSentinel -PathType Leaf) `
            'the pre-existing installation was modified'
        $registeredEvidencePath = Join-Path $registeredEvidence 'evidence.json'
        Assert-True 'registered installation: harness writes evidence after refusing' `
            (Test-Path -LiteralPath $registeredEvidencePath -PathType Leaf) 'evidence.json is missing'
        if (Test-Path -LiteralPath $registeredEvidencePath -PathType Leaf) {
            $registeredEvidenceJson = Get-Content -LiteralPath $registeredEvidencePath -Raw | ConvertFrom-Json
            $registeredFatal = @($registeredEvidenceJson.segments | Where-Object { $_.name -eq 'qualification harness' })
            Assert-True 'registered installation: evidence names the registration guard' `
                ($registeredFatal.Count -eq 1 -and
                    $registeredFatal[0].detail -match 'registered NanoDictate installation') `
                'the failure segment did not describe the registered installation'
        }

        # A failed setup that leaves payload files without unins000.exe must
        # still be cleaned up because the directory is test-owned.
        $partialRoot = Join-Path $failureRoot ('partial-' + [guid]::NewGuid().ToString('N'))
        $partialAppData = Join-Path $partialRoot 'appdata'
        $partialLocalAppData = Join-Path $partialRoot 'localappdata'
        $partialTemp = Join-Path $partialRoot 'temp'
        $partialEvidence = Join-Path $partialRoot 'evidence'
        $partialLogs = Join-Path $partialRoot 'logs'
        New-Item -ItemType Directory -Force -Path `
            $partialAppData, $partialLocalAppData, $partialTemp, `
            $partialEvidence, $partialLogs | Out-Null
        $env:APPDATA = $partialAppData
        $env:LOCALAPPDATA = $partialLocalAppData
        $env:RUNNER_TEMP = $partialTemp
        $env:TMPDIR = $partialTemp
        $env:TMP = $partialTemp
        $env:TEMP = $partialTemp
        $env:ND_TEST_INSTALLER_CONFIG = ''
        $partialMarker = Join-Path $partialRoot 'installer-invoked.txt'
        $partialPayloadMarker = Join-Path $partialRoot 'installer-payload-created.txt'
        $env:ND_TEST_INSTALLER_MARKER = $partialMarker
        $env:ND_TEST_INSTALLER_PARTIAL = '1'
        $env:ND_TEST_INSTALLER_PARTIAL_MARKER = $partialPayloadMarker
        $env:ND_TEST_REGISTERED_INSTALL_LOCATION = ''
        & $pwshPath -NoProfile -File $harnessCopy `
            -Source candidate -InstallerPath $fakeInstaller `
            -PhraseText 'two words' -EvidenceDirectory $partialEvidence `
            -LogDirectory $partialLogs *> (Join-Path $partialRoot 'harness.log')
        $partialExitCode = $LASTEXITCODE
        Assert-Equal 'partial setup: harness reports the installer failure' $partialExitCode 1
        # Prove the installer stub actually ran and created the partial payload:
        # an early harness exit would also leave no install directory and look clean.
        Assert-True 'partial setup: the installer stub ran before cleanup' `
            (Test-Path -LiteralPath $partialMarker -PathType Leaf) `
            'the installer marker is missing, so the cleanup assertion is meaningless'
        Assert-True 'partial setup: the installer stub created the partial payload' `
            (Test-Path -LiteralPath $partialPayloadMarker -PathType Leaf) `
            'the payload marker is missing, so the cleanup assertion is meaningless'
        $partialInstallDirectory = Join-Path $partialLocalAppData 'Programs\NanoDictate'
        Assert-True 'partial setup: leftovers are removed without an uninstaller' `
            (-not (Test-Path -LiteralPath $partialInstallDirectory)) `
            'partial installation files remained after cleanup'
    } finally {
        foreach ($name in $savedEnvironment.Keys) {
            if ($null -eq $savedEnvironment[$name]) {
                Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path "Env:$name" -Value $savedEnvironment[$name]
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $configRestoreRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Assert-Contains 'harness verifies the test-owned editor before activation' `
    $harness 'test-owned editor tab active before activation'
Assert-Match 'harness verifies the test tab after collecting the HUD baseline' `
    $harness '(?s)\$hudBaseline = @\(Get-RealDictationHudBaseline.*?\$activationStillReady = Test-RealDictationActiveEditorWindow'
Assert-Match 'harness aborts instead of sending Double-Alt when the test tab changed' `
    $harness "(?s)\`$activationStillReady = Test-RealDictationActiveEditorWindow.*?if \(-not \`$activationStillReady\) \{\s*throw 'Refusing to send Double-Alt:.*?\}\s*Send-RealDictationDoubleAlt"
Assert-Contains 'harness rechecks the capture route at activation' $harness '$routeReachableAtActivation'
Assert-Contains 'harness separates rendering from capture evidence' `
    $harness 'rendering alone is not evidence of capture'
Assert-Contains 'harness withholds editor text when ownership fails' `
    $harness 'editor text withheld because document ownership failed'
Assert-NotContains 'harness never captures the desktop' $harness '-Kind desktop'
Assert-Contains 'harness resolves scratch staging outside uploaded evidence' `
    $harness '$tempRoot = Resolve-RealDictationScratchDirectory -ExcludedDirectory @($EvidenceDirectory, $LogDirectory)'
Assert-Contains 'harness falls back to the system temp path when RUNNER_TEMP is absent' `
    $harness 'if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }'
Assert-NotContains 'harness never stages local temp inside the evidence directory' `
    $harness "Join-Path `$EvidenceDirectory '.tmp'"
Assert-Match 'harness stages screenshots outside the uploaded evidence directory' `
    $harness '(?s)\$capturePath = Join-Path \$tempRoot.*?Save-RealDictationScreenshot -Kind \$Kind -Handle \$Handle -Path \$capturePath'
Assert-Match 'harness discards screen-region fallback captures' `
    $harness "(?s)elseif \(\`$result\.Saved -and \`$result\.NonBlankPixels -gt 0\) \{.*?Remove-Item -LiteralPath \`$result\.Path.*?was discarded"
Assert-Contains 'harness publishes only verified window screenshots' `
    $harness 'Move-Item -LiteralPath $result.Path -Destination $path -Force -ErrorAction Stop'
Assert-Match 'harness records a failed screenshot publication instead of aborting' `
    $harness "(?s)Move-Item -LiteralPath \`$result\.Path.*?catch \{.*?could not be published as evidence"
Assert-NotContains 'harness never adds a screen-region fallback to evidence' `
    $harness "Add-EvidenceFile `$result.Path"
Assert-Contains 'harness uninstalls only an installation it created' $harness '$installationOwned'
Assert-Contains 'harness refuses a pre-existing local installation' `
    $harness 'pre-existing NanoDictate installation exists'
Assert-Contains 'harness bounds release requests with deadlines' $harness '-TimeoutSec'
Assert-Contains 'harness scopes HUD probes to the launched agent' $harness 'AgentProcessIds'
Assert-Contains 'harness only credits a HUD when the baseline was hidden' `
    $harness 'Test-RealDictationHudChanged -Window $window -Baseline $Baseline'
Assert-Contains 'harness records the HUD phase in its activation baseline' `
    $harness 'Phase = Get-RealDictationHudPhase -Window $window'
Assert-Contains 'harness classifies observed HUD phases through the shared helper' `
    $harness 'Get-RealDictationHudPhase -Window $observation'

$module = Read-Text 'scripts/windows-real-dictation.psm1'
Assert-Contains 'module exposes the three-status verdict' $module "FULL E2E VERIFIED"
Assert-Contains 'module exposes the blocked status' $module 'NOT VERIFIED / HOSTED RUNNER BLOCKED'
Assert-Contains 'module keeps a specific no-cable reason' $module 'no active virtual capture endpoint is installed on this runner'
Assert-Contains 'module does not mock the product' $module 'Nothing here mocks a transcript'
Assert-Contains 'module synthesizes the phrase as 16 kHz 16-bit mono PCM' $module '$stream.Format.Type = 18'
Assert-Match 'module sets the PCM format before opening the WAV stream' `
    $module '(?s)\$stream\.Format\.Type = 18.*?\$stream\.Open\('
Assert-Contains 'module accepts only capture and render default flows' `
    $module '[ValidateSet(''capture'', ''render'')][string]$DefaultFlow'
Assert-Contains 'module requires a usable render id for a reachable route' `
    $module '$pairedRenderUsable'

$interop = Read-Text 'scripts/windows-real-dictation-interop.cs'
Assert-Contains 'interop injects real keyboard input' $interop 'SendInput(1, new[] { input }'
Assert-Contains 'interop sizes the x64 INPUT union' $interop 'private struct MouseInput'
Assert-Match 'interop sizes PROPVARIANT for the native x64 layout' `
    $interop '(?s)StructLayout\(LayoutKind\.Explicit, Size = 24\).*?struct PropVariant'
Assert-Contains 'interop renders into a real WASAPI endpoint' $interop 'PlayWavToDevice'
Assert-Contains 'interop probes the interactive desktop' $interop 'OpenInputDesktop'
Assert-Contains 'interop reads classic editor text with a bounded WM_GETTEXT' $interop 'SendMessageTimeout'
Assert-Contains 'interop bounds PrintWindow capture' $interop 'TryPrintWindowPixels'
Assert-Contains 'interop reports screen-region captures separately' $interop 'Method = "screen-region"'
Assert-Contains 'interop marks only PrintWindow captures as window evidence' `
    $interop 'WindowEvidence = true'
Assert-Contains 'interop enforces a playback deadline' $interop 'playbackBudgetMilliseconds'
Assert-Contains 'interop rejects overlong WAV input' $interop 'MaxPlaybackSeconds'
Assert-Contains 'interop rejects WAVs without complete PCM frames' $interop 'dataLength % bytesPerFrame'
Assert-Match 'interop checks the default-endpoint HRESULT before absence' `
    $interop '(?s)GetDefaultAudioEndpoint\(ParseFlow\(flow\), ParseRole\(role\), out device\);\s*if \(hr == ElementNotFound\)\s*\{\s*return null;\s*\}.*?ThrowIfFailed'
Assert-Match 'interop checks the enumeration HRESULT before absence' `
    $interop '(?s)EnumAudioEndpoints\(flow, StateAll, out collection\);\s*if \(hr == ElementNotFound\)\s*\{\s*return;\s*\}\s*ThrowIfFailed'
Assert-Contains 'interop restores the target window asynchronously' `
    $interop 'ShowWindowAsync(target, SwRestore)'
Assert-NotContains 'interop never blocks on synchronous ShowWindow' `
    $interop 'ShowWindow(target, SwRestore)'
Assert-Contains 'interop bounds the focus retry with the worker join' $interop 'worker.Join(budget)'
Assert-Contains 'interop drains the render buffer before crediting playback' `
    $interop 'frames remain queued'

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
