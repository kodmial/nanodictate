#Requires -Version 7.0
<#
.SYNOPSIS
  Shared helpers for the opt-in Windows real-dictation qualification.

.DESCRIPTION
  This module is test infrastructure, not product code. It provides:

  * pure classification/assertion helpers that run (and are unit-tested) on
    any platform: phrase normalization, virtual-endpoint heuristics, paired
    render routing and the FULL/PARTIAL/NOT VERIFIED verdict;
  * thin wrappers over scripts/windows-real-dictation-interop.cs that only
    load on Windows and fail loudly elsewhere.

  Nothing here mocks a transcript, substitutes a provider response or claims
  that a missing microphone worked. A qualification run reports exactly what
  the product and the runner did.
#>
Set-StrictMode -Version Latest

$script:InteropSourcePath = Join-Path $PSScriptRoot 'windows-real-dictation-interop.cs'
$script:InteropLoaded = $false

# Friendly-name patterns that identify a virtual capture endpoint. Physical
# arrays ("Microphone Array", "Microphone (Realtek ...)") are deliberately not
# included: routing a synthetic WAV into a real microphone input is impossible.
$script:VirtualAudioNamePatterns = @(
    'CABLE Output*'
    '*VB-Audio*'
    '*VB-Cable*'
    '*Virtual Audio Cable*'
    '*VoiceMeeter*'
    '*Virtual Desktop Audio*'
    '*Virtual Microphone*'
    '*Virtual Mic*'
    '*BlackHole*'
    '*Loopback*'
    '*Remote Audio*'
)

function Test-RealDictationPlatform {
    <# Returns $true on Windows. Pure; safe on every platform. #>
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Initialize-RealDictationInterop {
    <# Compiles the harness interop on first use. Windows only. #>
    if (-not (Test-RealDictationPlatform)) {
        throw 'Real-dictation interop requires Windows.'
    }
    if ('NanoDictate.RealDictation.Native' -as [type]) {
        $script:InteropLoaded = $true
        return
    }
    if (-not (Test-Path -LiteralPath $script:InteropSourcePath)) {
        throw "Missing real-dictation interop source: $script:InteropSourcePath"
    }
    $source = Get-Content -LiteralPath $script:InteropSourcePath -Raw
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    $script:InteropLoaded = $true
}

function ConvertTo-NormalizedDictationText {
    <#
      Normalizes text for a spoken-phrase assertion: Unicode Form C, letters
      and digits only, whitespace collapsed, invariant lowercase. Punctuation,
      quotes and hyphenation differences therefore never decide pass/fail.
    #>
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormC)
    $normalized = [regex]::Replace($normalized, '[^\p{L}\p{N}]+', ' ')
    if ($normalized.Length -eq 0) {
        return ''
    }
    return ($normalized.ToLowerInvariant().Trim() -replace '\s+', ' ')
}

function Get-DictationTokens {
    <# Splits normalized text into tokens; empty text yields an empty array. #>
    param([AllowNull()][string]$Text)

    $normalized = ConvertTo-NormalizedDictationText -Text $Text
    if ($normalized.Length -eq 0) {
        return ,@()
    }
    return ,@($normalized -split ' ')
}

function Test-DictationPhraseInserted {
    <#
      Ordered spoken-phrase assertion. Returns matched/ordered/ratio plus the
      normalized values so the evidence shows exactly what was compared.
      MinimumMatchedFraction defaults to 1.0: every expected token must appear
      in order, so a partial or unrelated transcript never passes.
    #>
    param(
        [AllowNull()][string]$Transcript,
        [string]$Expected,
        [ValidateRange(0.0, 1.0)][double]$MinimumMatchedFraction = 1.0
    )

    if ([string]::IsNullOrWhiteSpace($Expected)) {
        throw 'An expected phrase is required.'
    }
    $expectedTokens = Get-DictationTokens -Text $Expected
    if ($expectedTokens.Count -lt 2) {
        throw "The expected phrase must contain at least two words; got '$Expected'."
    }
    $transcriptTokens = Get-DictationTokens -Text $Transcript

    $ordered = 0
    foreach ($token in $transcriptTokens) {
        if ($ordered -lt $expectedTokens.Count -and $token -eq $expectedTokens[$ordered]) {
            $ordered++
        }
    }
    $ratio = [double]$ordered / [double]$expectedTokens.Count
    $requiredTokens = [int][math]::Ceiling($MinimumMatchedFraction * $expectedTokens.Count)
    $matched = $transcriptTokens.Count -gt 0 -and
        $ordered -ge $requiredTokens -and
        $ratio -ge $MinimumMatchedFraction - 0.000001

    return [pscustomobject]@{
        Matched           = [bool]$matched
        OrderedTokens     = [int]$ordered
        ExpectedTokenCount = [int]$expectedTokens.Count
        TranscriptTokenCount = [int]$transcriptTokens.Count
        MatchedFraction   = [math]::Round($ratio, 4)
        MinimumFraction   = [double]$MinimumMatchedFraction
        ExpectedNormalized = ConvertTo-NormalizedDictationText -Text $Expected
        TranscriptNormalized = ConvertTo-NormalizedDictationText -Text $Transcript
    }
}

function Find-VirtualCaptureEndpointMatch {
    <#
      Returns every active capture endpoint whose friendly name identifies a
      virtual audio device. Pure: takes endpoint objects with
      Flow/Name/State/Id properties.
    #>
    param($Endpoints)

    if ($null -eq $Endpoints) {
        return
    }
    foreach ($endpoint in @($Endpoints)) {
        if ($null -eq $endpoint) {
            continue
        }
        if ([string]$endpoint.Flow -ne 'capture') {
            continue
        }
        if ([string]$endpoint.State -ne 'active') {
            continue
        }
        foreach ($pattern in $script:VirtualAudioNamePatterns) {
            if ([string]$endpoint.Name -like $pattern) {
                [pscustomobject]@{
                    Endpoint = $endpoint
                    MatchedPattern = $pattern
                }
                break
            }
        }
    }
}

function Find-VirtualCaptureEndpoint {
    <#
      Returns the first active capture endpoint whose friendly name identifies
      a virtual audio device, or $null.
    #>
    param($Endpoints)

    $found = @(Find-VirtualCaptureEndpointMatch -Endpoints $Endpoints)
    if ($found.Count -eq 0) {
        return $null
    }
    return $found[0]
}

function Test-EndpointIdentityMatch {
    <#
      Compares two audio endpoints. Stable device ids decide identity when both
      sides expose one; the friendly name is only a fallback for backends that
      do not return ids.
    #>
    param($Candidate, $Reference)

    if ($null -eq $Candidate -or $null -eq $Reference) {
        return $false
    }
    $candidateId = [string]$Candidate.Id
    $referenceId = [string]$Reference.Id
    if (-not [string]::IsNullOrEmpty($candidateId) -and -not [string]::IsNullOrEmpty($referenceId)) {
        return $candidateId -eq $referenceId
    }
    $candidateName = [string]$Candidate.Name
    $referenceName = [string]$Reference.Name
    if ([string]::IsNullOrEmpty($candidateName) -or [string]::IsNullOrEmpty($referenceName)) {
        return $false
    }
    return $candidateName -eq $referenceName
}

function Get-EndpointNameGroup {
    <# Returns the parenthesized adapter name of an endpoint ('' when absent). #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    $match = [regex]::Match($Name, '\(([^()]+)\)\s*$')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim().ToLowerInvariant()
    }
    return ''
}

function Get-EndpointNameBase {
    <# Returns the friendly name without its parenthesized adapter suffix. #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    return ([regex]::Replace($Name, '\s*\([^()]+\)\s*$', '')).Trim().ToLowerInvariant()
}

function Get-PairedRenderEndpoint {
    <#
      Finds the render endpoint that feeds a virtual capture endpoint. A cable
      typically exposes "CABLE Input" (render) and "CABLE Output" (capture) on
      the same adapter, so pairing prefers Input/Output or Render/Capture name
      swaps inside the same adapter group, then the only render endpoint of
      that group. When more than one active endpoint matches at the winning
      rank there is no way to know which cable feeds the capture endpoint, so
      the pairing is rejected as ambiguous instead of picking the first one
      (sending the phrase into the wrong cable would look like a pass).
      Returns an object with Endpoint (or $null) and Reason.
    #>
    param($CaptureEndpoint, $RenderEndpoints)

    if ($null -eq $CaptureEndpoint) {
        return [pscustomobject]@{ Endpoint = $null; Reason = 'no virtual capture endpoint' }
    }
    $captureName = [string]$CaptureEndpoint.Name
    $group = Get-EndpointNameGroup -Name $captureName
    $base = Get-EndpointNameBase -Name $captureName

    $active = @()
    if ($null -ne $RenderEndpoints) {
        $active = @(@($RenderEndpoints) | Where-Object {
            $null -ne $_ -and [string]$_.Flow -eq 'render' -and [string]$_.State -eq 'active'
        })
    }
    if ($active.Count -eq 0) {
        return [pscustomobject]@{ Endpoint = $null; Reason = 'no active render endpoint to feed the virtual capture endpoint' }
    }

    $groupMatches = @($active | Where-Object {
        $candidateGroup = Get-EndpointNameGroup -Name ([string]$_.Name)
        $group.Length -gt 0 -and $candidateGroup -eq $group
    })
    if ($groupMatches.Count -eq 0) {
        return [pscustomobject]@{
            Endpoint = $null
            Reason = "no render endpoint shares the capture adapter group '$group'"
        }
    }

    $swapped = $base
    $swapped = $swapped -replace 'output$', 'input'
    $swapped = $swapped -replace 'capture$', 'render'
    $swapped = $swapped -replace 'microphone$', 'speaker'
    $swappedMatches = @($groupMatches | Where-Object {
        (Get-EndpointNameBase -Name ([string]$_.Name)) -eq $swapped
    })
    if ($swappedMatches.Count -eq 1) {
        return [pscustomobject]@{
            Endpoint = $swappedMatches[0]
            Reason = "render endpoint '$($swappedMatches[0].Name)' feeds '$captureName'"
        }
    }
    if ($swappedMatches.Count -gt 1) {
        return [pscustomobject]@{
            Endpoint = $null
            Reason = "ambiguous render endpoints in adapter group '$group': $($swappedMatches.Count) active endpoints match '$swapped'"
        }
    }
    $inputMatches = @($groupMatches | Where-Object {
        (Get-EndpointNameBase -Name ([string]$_.Name)) -like '*input*'
    })
    if ($inputMatches.Count -eq 1) {
        return [pscustomobject]@{
            Endpoint = $inputMatches[0]
            Reason = "render input endpoint '$($inputMatches[0].Name)' feeds '$captureName'"
        }
    }
    if ($inputMatches.Count -gt 1) {
        return [pscustomobject]@{
            Endpoint = $null
            Reason = "ambiguous render endpoints in adapter group '$group': $($inputMatches.Count) active endpoints contain 'input'"
        }
    }
    if ($groupMatches.Count -eq 1) {
        return [pscustomobject]@{
            Endpoint = $groupMatches[0]
            Reason = "only render endpoint '$($groupMatches[0].Name)' shares the capture adapter group"
        }
    }
    return [pscustomobject]@{
        Endpoint = $null
        Reason = "ambiguous render endpoints in adapter group '$group'"
    }
}

function Resolve-VirtualAudioRoute {
    <#
      Combines endpoint discovery with NanoDictate's actual capture contract:
      the product always opens the default console capture endpoint. A virtual
      cable only proves the path when it is that exact endpoint.
    #>
    param($Endpoints, $DefaultCaptureEndpoint)

    $virtualEndpoints = @(Find-VirtualCaptureEndpointMatch -Endpoints $Endpoints)
    if ($virtualEndpoints.Count -eq 0) {
        return [pscustomobject]@{
            VirtualCapture = $null
            PairedRender = $null
            DefaultCapture = $DefaultCaptureEndpoint
            DefaultCaptureIsVirtual = $false
            CaptureEndpointReachable = $false
            Reason = 'no active virtual capture endpoint is installed on this runner'
        }
    }

    # The product opens the default console capture endpoint, so prefer that
    # exact endpoint when it is one of the active virtual captures instead of
    # always taking the first cable the enumerator returned.
    $selected = $virtualEndpoints[0]
    $isDefault = $false
    if ($null -ne $DefaultCaptureEndpoint) {
        foreach ($candidate in $virtualEndpoints) {
            if (Test-EndpointIdentityMatch -Candidate $candidate.Endpoint -Reference $DefaultCaptureEndpoint) {
                $selected = $candidate
                $isDefault = $true
                break
            }
        }
    }
    $capture = $selected.Endpoint
    $paired = Get-PairedRenderEndpoint -CaptureEndpoint $capture -RenderEndpoints $Endpoints
    $reason = if ($isDefault) {
        "the product's default console capture endpoint is the virtual device '$($capture.Name)'"
    } else {
        $defaultName = if ($null -eq $DefaultCaptureEndpoint) { '<none>' } else { [string]$DefaultCaptureEndpoint.Name }
        "a virtual capture endpoint exists ('$($capture.Name)') but the product's default console capture endpoint is '$defaultName'"
    }
    return [pscustomobject]@{
        VirtualCapture = $capture
        VirtualCapturePattern = $selected.MatchedPattern
        PairedRender = $paired.Endpoint
        PairedRenderReason = $paired.Reason
        DefaultCapture = $DefaultCaptureEndpoint
        DefaultCaptureIsVirtual = [bool]$isDefault
        CaptureEndpointReachable = [bool]$isDefault -and $null -ne $paired.Endpoint
        Reason = $reason
    }
}

function Get-RealDictationHudPhase {
    <#
      Classifies a NanoDictate HUD window from its geometry. The recording
      panel is 178 points tall versus 150 for the starting/error overlay; the
      observed width scales both thresholds so a DPI change does not change
      the phase.
    #>
    param([Parameter(Mandatory)]$Window)

    $width = [int]$Window.Width
    $height = [int]$Window.Height
    $scale = if ($width -gt 0) { $width / 220.0 } else { 1.0 }
    if ([math]::Abs($height - (178.0 * $scale)) -le (4.0 * $scale)) {
        return 'recording'
    }
    if ([math]::Abs($height - (150.0 * $scale)) -le (4.0 * $scale)) {
        return 'starting-or-error'
    }
    return 'unknown'
}

function Test-RealDictationHudChanged {
    <#
      A HUD is attributable to the activation only when no HUD owned by the
      agent was visible in the baseline. A pre-existing starting/error panel
      can advance to recording when an earlier capture delivers its first
      audio block, and a recording panel can be resized for a different
      monitor DPI; neither proves that this Double-Alt was handled. Requiring
      a hidden baseline makes the post-hotkey appearance unambiguous.
    #>
    param(
        [Parameter(Mandatory)]$Window,
        [object[]]$Baseline = @()
    )

    $observedHandle = [long]$Window.Handle
    return [bool]($observedHandle -ne 0 -and @($Baseline | Where-Object { $null -ne $_ }).Count -eq 0)
}

function Get-RealDictationVerdict {
    <#
      Maps observed leg outcomes to the qualification status. FULL requires
      every segment; PARTIAL requires one complete observable leg (the whole
      GUI path or the whole audio path); everything else is NOT VERIFIED. The
      unverified list names the exact missing segments so no green step implies
      real dictation. A probe run is reported separately because it never
      attempted the product path.
    #>
    param($Gui, $Audio, [switch]$ProbeOnly)

    if ($ProbeOnly) {
        return [pscustomobject]@{
            Status = 'NOT VERIFIED / PROBE ONLY'
            FullyVerified = $false
            GuiSegmentVerified = $false
            AudioSegmentVerified = $false
            UnverifiedSegments = [string[]]@(
                'app installed and started',
                'foreground editor focused',
                'real Double-Alt delivered',
                'HUD appeared after Double-Alt',
                'recording HUD phase reached',
                'virtual capture endpoint present',
                'product default capture is virtual',
                'WAV rendered into the virtual cable',
                'real STT phrase inserted in editor'
            )
        }
    }

    $flags = [ordered]@{
        'app installed and started'          = [bool]$Gui.AppLaunched
        'foreground editor focused'          = [bool]$Gui.EditorFocused
        'real Double-Alt delivered'          = [bool]$Gui.DoubleAltDelivered
        'HUD appeared after Double-Alt'      = [bool]$Gui.HudAppeared
        'recording HUD phase reached'        = [bool]$Gui.RecordingPhase
        'virtual capture endpoint present'   = [bool]$Audio.VirtualCaptureEndpointPresent
        'product default capture is virtual' = [bool]$Audio.DefaultCaptureIsVirtual
        'WAV rendered into the virtual cable' = [bool]$Audio.WavPlayed
        'real STT phrase inserted in editor' = [bool]$Audio.PhraseMatched
    }
    $unverified = @()
    foreach ($key in $flags.Keys) {
        if (-not $flags[$key]) {
            $unverified += $key
        }
    }

    $full = $unverified.Count -eq 0
    # The GUI leg is only complete when the panel actually reached the
    # recording phase. A starting/error panel proves the hook fired but not
    # that NanoDictate captured audio, so it must not be reported as a
    # competing leg on its own.
    $guiSegment = [bool]($Gui.AppLaunched -and $Gui.EditorFocused -and
        $Gui.DoubleAltDelivered -and $Gui.HudAppeared -and $Gui.RecordingPhase)
    $audioSegment = [bool]($Audio.VirtualCaptureEndpointPresent -and $Audio.DefaultCaptureIsVirtual -and
        $Audio.WavPlayed -and $Audio.PhraseMatched)
    $status = if ($full) {
        'FULL E2E VERIFIED'
    } elseif ($guiSegment -or $audioSegment) {
        'PARTIAL VERIFIED'
    } else {
        'NOT VERIFIED / HOSTED RUNNER BLOCKED'
    }

    return [pscustomobject]@{
        Status = $status
        FullyVerified = [bool]$full
        GuiSegmentVerified = [bool]$guiSegment
        AudioSegmentVerified = [bool]$audioSegment
        UnverifiedSegments = [string[]]$unverified
    }
}

function Test-RealDictationEditorProcessOwned {
    <#
      An editor process may be terminated only when it did not exist before
      this run launched its own editor. Windows 11 Notepad can host several
      files in one process, so a pre-existing process may contain unrelated
      unsaved documents even when the window title matches this run's file.
    #>
    param(
        [Parameter(Mandatory)][int]$EditorProcessId,
        [int[]]$PreexistingProcessIds = @()
    )

    if ($EditorProcessId -le 0) {
        return $false
    }
    return ($PreexistingProcessIds -notcontains $EditorProcessId)
}

function Test-RealDictationActiveEditorWindow {
    <#
      Confirms the foreground window is the discovered editor and its title
      still names this run's unique test file. Windows 11 Notepad hosts
      several tabs in one window and titles the active document, so this
      prevents Ctrl+A/Ctrl+C from reading a different tab that merely shares
      the editor window.
    #>
    param(
        [AllowNull()]$Foreground = $null,
        [Parameter(Mandatory)][long]$EditorHandle,
        [Parameter(Mandatory)][string]$TitlePattern
    )

    if ($null -eq $Foreground -or $EditorHandle -le 0) {
        return $false
    }
    if ([long]$Foreground.Handle -ne $EditorHandle) {
        return $false
    }
    $title = [string]$Foreground.Title
    if ([string]::IsNullOrEmpty($title)) {
        return $false
    }
    return [regex]::IsMatch($title, $TitlePattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-RealDictationEditorContentOwned {
    <#
      Confirms read editor text still carries this run's unique marker. A tab
      title can change only around the Ctrl+A/Ctrl+C read, so title checks on
      both sides cannot prove which tab supplied the clipboard text. The
      marker is written only to the test-owned document, so text from any other
      tab (even one holding an earlier transcript) can never be credited.
    #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Marker
    )

    if ([string]::IsNullOrEmpty($Marker) -or [string]::IsNullOrEmpty($Text)) {
        return $false
    }
    return $Text.IndexOf($Marker, [StringComparison]::Ordinal) -ge 0
}

function Remove-RealDictationEditorMarker {
    <#
      Removes this run's seeded marker from the text used for the phrase
      assertion. Ownership still requires the marker, but the marker itself
      can contain the expected phrase (for example, "real dictation" appears
      in "nanodictate-real-dictation-marker-..."), so matching the unstripped
      text could credit an insertion that never happened.
    #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Marker
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    if ([string]::IsNullOrEmpty($Marker)) {
        return $Text
    }
    return $Text.Replace($Marker, [string]::Empty)
}

function Test-RealDictationInsertion {
    <#
      Runs the harness insertion assertion in one place: bind the read to this
      run's document through the unique marker, strip that marker so it cannot
      satisfy the expected phrase, then require the ordered spoken phrase.
      The parameters are never reassigned, so the expected phrase cannot be
      replaced by the marker-stripped editor text (PowerShell variable names are
      case-insensitive). Only a read owned by this run can be credited.
    #>
    param(
        [AllowNull()][string]$EditorText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Marker,
        [Parameter(Mandatory)][string]$Expected
    )

    $owned = Test-RealDictationEditorContentOwned -Text $EditorText -Marker $Marker
    $transcript = Remove-RealDictationEditorMarker -Text $EditorText -Marker $Marker
    $comparison = Test-DictationPhraseInserted -Transcript $transcript -Expected $Expected
    return [pscustomobject]@{
        Owned            = [bool]$owned
        Matched          = [bool]($comparison.Matched -and $owned)
        TranscriptText   = $transcript
        Comparison       = $comparison
    }
}

function Get-RealDictationExitCode {
    <#
      Maps a finished qualification to the process exit code. Probe-only runs
      are diagnostics, so completing them is success; a full run is successful
      only when every segment was observed. A non-full full run exits 2 so a
      green job can never be mistaken for real dictation, even though the
      evidence artifact and summary are still written.
    #>
    param(
        [bool]$FullyVerified = $false,
        [switch]$ProbeOnly,
        [switch]$Failed
    )

    if ($Failed) {
        return 1
    }
    if ($ProbeOnly) {
        return 0
    }
    if ($FullyVerified) {
        return 0
    }
    return 2
}

function Resolve-RealDictationCanonicalPath {
    <#
      Resolves symbolic links and junctions in every existing path component so
      containment checks cannot be bypassed by a directory alias. Components
      that do not exist yet are appended unchanged.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 0
    )

    if ($Depth -gt 40) {
        throw "Too many directory links while resolving $Path."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $relative = $fullPath.Substring($root.Length)
    $parts = @($relative -split '[\\/]' | Where-Object { $_ })
    $current = $root
    foreach ($part in $parts) {
        $next = Join-Path $current $part
        $item = Get-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and $item.LinkType) {
            $target = $item.LinkTarget
            if ($target) {
                if (-not [System.IO.Path]::IsPathRooted($target)) {
                    $target = Join-Path (Split-Path -Parent $next) $target
                }
                $next = Resolve-RealDictationCanonicalPath -Path $target -Depth ($Depth + 1)
            }
        }
        $current = $next
    }
    return [System.IO.Path]::GetFullPath($current)
}

function Test-RealDictationPathInside {
    <# Returns $true when Path equals or is nested under Directory. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Directory
    )

    $comparison = if (Test-RealDictationPlatform) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    $separators = @(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $normalizedPath = (Resolve-RealDictationCanonicalPath -Path $Path).TrimEnd($separators)
    $normalizedDirectory = (Resolve-RealDictationCanonicalPath -Path $Directory).TrimEnd($separators)
    if ($normalizedPath.Equals($normalizedDirectory, $comparison)) {
        return $true
    }
    $prefix = $normalizedDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($prefix, $comparison)
}

function Resolve-RealDictationConfigBackupDirectory {
    <#
      Chooses a writable directory for a preserved provider config that is not
      inside any excluded (uploaded) directory. When the preferred temporary
      directory is inside an excluded directory, walks up to the nearest safe
      ancestor before creating a unique backup directory.
    #>
    param(
        [string[]]$ExcludedDirectory = @(),
        [string[]]$CandidateDirectory = @()
    )

    $excluded = @($ExcludedDirectory | Where-Object { $_ } | ForEach-Object {
        Resolve-RealDictationCanonicalPath -Path $_
    })
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidatePool = @($CandidateDirectory) + @([System.IO.Path]::GetTempPath()) +
        @($env:LOCALAPPDATA, $env:USERPROFILE, $env:HOME)
    foreach ($candidate in $candidatePool) {
        if ($candidate -and -not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    foreach ($candidate in $candidates) {
        $current = Resolve-RealDictationCanonicalPath -Path $candidate
        while ($true) {
            $contained = $false
            foreach ($directory in $excluded) {
                if (Test-RealDictationPathInside -Path $current -Directory $directory) {
                    $contained = $true
                    break
                }
            }
            if (-not $contained) {
                break
            }
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if (-not $parent -or $parent -eq $current) {
                $current = $null
                break
            }
            $current = $parent
        }
        if (-not $current) {
            continue
        }
        $backupDirectory = Join-Path $current (
            'nanodictate-real-dictation-backup-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Force -Path $backupDirectory -ErrorAction Stop | Out-Null
            return $backupDirectory
        } catch {
            continue
        }
    }
    throw 'Could not create a provider config backup directory outside the uploaded evidence directories.'
}

function Backup-RealDictationProviderConfig {
    <#
      Preserves an existing provider config in a directory chosen outside the
      uploaded evidence directories. Returns the backup path, or $null when no
      config existed before.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$BackupDirectory
    )

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        return $null
    }
    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    $backupPath = Join-Path $BackupDirectory (
        'config-' + [guid]::NewGuid().ToString('N') + '.toml')
    Copy-Item -LiteralPath $TargetPath -Destination $backupPath -Force
    return $backupPath
}

function Get-RealDictationProviderConfigState {
    <#
      Captures the pre-run state of the user provider config before the
      installer can create or replace it. The installer starts the product,
      which may bootstrap a default config; recording ExistedBefore only after
      installation would misclassify that run-created default as a user config.
      Returns whether the config existed and a backup path for an existing one.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$BackupDirectory
    )

    $existedBefore = Test-Path -LiteralPath $TargetPath -PathType Leaf
    $backupPath = $null
    if ($existedBefore) {
        $backupPath = Backup-RealDictationProviderConfig `
            -TargetPath $TargetPath -BackupDirectory $BackupDirectory
    }
    return [pscustomobject]@{
        ExistedBefore = [bool]$existedBefore
        BackupPath    = $backupPath
    }
}

function Set-RealDictationProviderConfig {
    <#
      Copies a supplied provider config over the user config. Callers must mark
      the replacement as applied before calling this function so a copy that
      fails after touching the target still restores the preserved backup.
      CopyItem is replaceable so tests can simulate a partial replacement.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$SourcePath,
        [scriptblock]$CopyItem = {
            param($From, $To)
            Copy-Item -LiteralPath $From -Destination $To -Force
        }
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "ConfigPath does not exist: $SourcePath"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TargetPath) | Out-Null
    & $CopyItem $SourcePath $TargetPath
}

function Restore-RealDictationProviderConfig {
    <#
      Restores a provider config replaced by the qualification. When a config
      existed before, the preserved backup must still be present and is copied
      back; when none existed, only the test copy is removed. Throws when the
      backup cannot be restored so the caller can retain it and report failure.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$BackupPath,
        [bool]$ExistedBefore
    )

    if ($ExistedBefore) {
        if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            throw "The preserved provider config backup is missing; cannot restore $TargetPath."
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TargetPath) | Out-Null
        Copy-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
    } elseif (Test-Path -LiteralPath $TargetPath) {
        Remove-Item -LiteralPath $TargetPath -Force
    }
}

function Complete-RealDictationProviderConfigCleanup {
    <#
      Restores the user config and removes the backup only when restoration
      succeeded. A failed restoration retains the backup so the user's config
      can still be recovered manually; never delete the only remaining copy.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$BackupPath,
        [bool]$ExistedBefore
    )

    $restoreFailed = $false
    $errorMessage = $null
    try {
        Restore-RealDictationProviderConfig -TargetPath $TargetPath `
            -BackupPath $BackupPath -ExistedBefore $ExistedBefore
    } catch {
        $restoreFailed = $true
        $errorMessage = $_.Exception.Message
    }
    $backupRetained = $false
    if ($BackupPath -and (Test-Path -LiteralPath $BackupPath)) {
        if ($restoreFailed) {
            $backupRetained = $true
        } else {
            Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]@{
        RestoreFailed  = [bool]$restoreFailed
        BackupRetained = [bool]$backupRetained
        ErrorMessage   = $errorMessage
    }
}

function Format-RealDictationSummary {
    <# Renders the markdown job summary for one qualification run. #>
    param($Evidence)

    if ($null -eq $Evidence) {
        throw 'Evidence is required.'
    }
    $session = $Evidence.environment.session
    $sessionId = if ($null -ne $session) { $session.sessionId } else { '<probe unavailable>' }
    $desktopName = if ($null -ne $session) { $session.desktopName } else { '<probe unavailable>' }
    $inputDesktop = if ($null -ne $session) { $session.inputDesktopAvailable } else { '<probe unavailable>' }
    $run = if ($null -ne $Evidence.environment.PSObject.Properties['run']) { $Evidence.environment.run } else { $null }
    $runUrl = if ($null -ne $run -and $run.runUrl) { $run.runUrl } else { '<not an Actions run>' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## NanoDictate Windows real-dictation qualification")
    $lines.Add('')
    $lines.Add("**Status: $($Evidence.status)**")
    $lines.Add('')
    $lines.Add('| Field | Value |')
    $lines.Add('| --- | --- |')
    $lines.Add("| Tested source | $($Evidence.tested.source) |")
    $lines.Add("| Version | $($Evidence.tested.version) |")
    $lines.Add("| Commit / ref | $($Evidence.tested.commit) |")
    $lines.Add("| Installer SHA-256 | $($Evidence.tested.installerSha256) |")
    $lines.Add("| Actions run | $runUrl |")
    $lines.Add("| Runner | $($Evidence.environment.runnerImage) |")
    $lines.Add("| Session / desktop | $sessionId / $desktopName |")
    $lines.Add("| Input desktop available | $inputDesktop |")
    $lines.Add('')
    $lines.Add('| Segment | Observed | Detail |')
    $lines.Add('| --- | --- | --- |')
    foreach ($segment in @($Evidence.segments)) {
        $observed = if ($segment.observed) { 'PASS' } else { 'FAIL' }
        $detail = ([string]$segment.detail) -replace '\|', '/'
        $lines.Add("| $($segment.name) | $observed | $detail |")
    }
    $lines.Add('')
    if (@($Evidence.limitations).Count -gt 0) {
        $lines.Add('### Observed limitations')
        $lines.Add('')
        foreach ($limitation in @($Evidence.limitations)) {
            $lines.Add("- $limitation")
        }
        $lines.Add('')
    }
    $lines.Add('A per-segment PASS only means that step was observed. Real dictation is')
    $lines.Add('verified only by the status above and the uploaded evidence artifact.')
    $lines.Add('')
    $lines.Add('### Evidence files')
    $lines.Add('')
    foreach ($file in @($Evidence.evidenceFiles)) {
        $lines.Add("- ``$file``")
    }
    return ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Windows-only wrappers over the compiled interop.
# ---------------------------------------------------------------------------

function Get-RealDictationSessionProbe {
    Initialize-RealDictationInterop
    $probe = [NanoDictate.RealDictation.Native]::ProbeSession()
    return [pscustomobject]@{
        ProcessId = [int]$probe.ProcessId
        SessionId = [int]$probe.SessionId
        ActiveConsoleSessionId = [int]$probe.ActiveConsoleSessionId
        UserInteractive = [bool]$probe.UserInteractive
        DesktopName = [string]$probe.DesktopName
        InputDesktopAvailable = [bool]$probe.InputDesktopAvailable
        InputDesktopName = [string]$probe.InputDesktopName
    }
}

function Get-RealDictationAudioEndpoint {
    <# Returns every MMDevice endpoint plus the default console capture one. #>
    param([ValidateSet('capture', 'render', 'console')][string]$DefaultFlow = 'capture')

    Initialize-RealDictationInterop
    $endpoints = @([NanoDictate.RealDictation.Native]::EnumerateAudioEndpoints() | ForEach-Object {
        [pscustomobject]@{
            Id = [string]$_.Id
            Name = [string]$_.Name
            Flow = [string]$_.Flow
            State = [string]$_.State
            FormatTag = [int]$_.FormatTag
            Channels = [int]$_.Channels
            SampleRate = [int]$_.SampleRate
            BitsPerSample = [int]$_.BitsPerSample
        }
    })
    $default = [NanoDictate.RealDictation.Native]::GetDefaultAudioEndpoint($DefaultFlow, 'console')
    $defaultInfo = if ($null -eq $default) {
        $null
    } else {
        [pscustomobject]@{
            Id = [string]$default.Id
            Name = [string]$default.Name
            Flow = [string]$default.Flow
            State = [string]$default.State
            FormatTag = [int]$default.FormatTag
            Channels = [int]$default.Channels
            SampleRate = [int]$default.SampleRate
            BitsPerSample = [int]$default.BitsPerSample
        }
    }
    return [pscustomobject]@{
        Endpoints = $endpoints
        DefaultCapture = $defaultInfo
    }
}

function Send-RealDictationDoubleAlt {
    param([ValidateRange(10, 300)][int]$GapMilliseconds = 90)

    Initialize-RealDictationInterop
    [NanoDictate.RealDictation.Native]::SendDoubleAlt($GapMilliseconds)
}

function Send-RealDictationKey {
    param([ValidateSet('return', 'escape', 'ctrl-a', 'ctrl-c')][string]$Key)

    Initialize-RealDictationInterop
    switch ($Key) {
        'return' { [NanoDictate.RealDictation.Native]::SendReturnKey() }
        'escape' { [NanoDictate.RealDictation.Native]::SendEscapeKey() }
        'ctrl-a' { [NanoDictate.RealDictation.Native]::SendControlShortcut(0x41) }
        'ctrl-c' { [NanoDictate.RealDictation.Native]::SendControlShortcut(0x43) }
        default { throw "Unknown key: $Key" }
    }
}

function Get-RealDictationWindow {
    <# Finds a visible top-level window by exact title. #>
    param([Parameter(Mandatory)][string]$Title)

    Initialize-RealDictationInterop
    $window = [NanoDictate.RealDictation.Native]::FindWindowByTitle($Title)
    if ($null -eq $window) {
        return $null
    }
    return ConvertTo-RealDictationWindow -Window $window
}

function Get-RealDictationWindowByTitlePattern {
    <# Finds the first visible top-level window whose title matches a regex. #>
    param([Parameter(Mandatory)][string]$Pattern)

    Initialize-RealDictationInterop
    $window = [NanoDictate.RealDictation.Native]::FindWindowByTitlePattern($Pattern)
    if ($null -eq $window) {
        return $null
    }
    return ConvertTo-RealDictationWindow -Window $window
}

function Get-RealDictationForegroundWindow {
    Initialize-RealDictationInterop
    $window = [NanoDictate.RealDictation.Native]::GetForegroundWindowInfo()
    if ($null -eq $window) {
        return $null
    }
    return ConvertTo-RealDictationWindow -Window $window
}

function Get-RealDictationProcessWindow {
    param([Parameter(Mandatory)][int]$ProcessId)

    Initialize-RealDictationInterop
    return @([NanoDictate.RealDictation.Native]::FindProcessWindows($ProcessId) |
        ForEach-Object { ConvertTo-RealDictationWindow -Window $_ })
}

function ConvertTo-RealDictationWindow {
    param($Window)

    return [pscustomobject]@{
        Handle = [long]$Window.Handle
        Title = [string]$Window.Title
        ClassName = [string]$Window.ClassName
        Visible = [bool]$Window.Visible
        ProcessId = [int]$Window.ProcessId
        Left = [int]$Window.Left
        Top = [int]$Window.Top
        Width = [int]$Window.Width
        Height = [int]$Window.Height
    }
}

function Set-RealDictationForegroundWindow {
    param(
        [Parameter(Mandatory)][long]$Handle,
        [ValidateRange(100, 30000)][int]$TimeoutMilliseconds = 5000
    )

    Initialize-RealDictationInterop
    return [bool][NanoDictate.RealDictation.Native]::FocusWindow($Handle, $TimeoutMilliseconds)
}

function Get-RealDictationEditorText {
    <#
      Reads the focused editor's text. Prefers the classic Edit child text and
      falls back to a clipboard round-trip (Ctrl+A/Ctrl+C) so both classic and
      modern Notepad builds can be asserted.
    #>
    param(
        [Parameter(Mandatory)][long]$Handle,
        [switch]$UseClipboardFallback
    )

    Initialize-RealDictationInterop
    $text = [NanoDictate.RealDictation.Native]::GetChildEditText($Handle)
    $method = 'edit-control'
    if ([string]::IsNullOrWhiteSpace($text) -and $UseClipboardFallback) {
        if (-not (Set-RealDictationForegroundWindow -Handle $Handle)) {
            # Ctrl+A/Ctrl+C would target whatever window owns the foreground;
            # without focus the clipboard cannot be attributed to this editor.
            return [pscustomobject]@{
                Text = [string]::Empty
                Method = 'clipboard-focus-unavailable'
                Read = $false
            }
        }
        # Clear first so a failed copy can never leave stale clipboard text
        # behind and turn an unrelated string into a false pass. If the clear
        # still fails after bounded retries, reject the observation.
        $cleared = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Set-Clipboard -Value ([string]::Empty) -ErrorAction Stop
                if ([string]::IsNullOrEmpty([string](Get-Clipboard -Raw -ErrorAction Stop))) {
                    $cleared = $true
                    break
                }
            } catch {
                Write-Verbose "Clipboard clear attempt $attempt failed: $($_.Exception.Message)"
            }
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds 100
            }
        }
        if (-not $cleared) {
            return [pscustomobject]@{
                Text = [string]::Empty
                Method = 'clipboard-clear-failed'
                Read = $false
            }
        }
        Send-RealDictationKey -Key 'ctrl-a'
        Send-RealDictationKey -Key 'ctrl-c'
        Start-Sleep -Milliseconds 250
        try {
            $text = Get-Clipboard -Raw -ErrorAction Stop
            $method = 'clipboard'
        } catch {
            $text = $null
            $method = 'clipboard-unavailable'
        }
    }
    return [pscustomobject]@{
        Text = [string]$text
        Method = $method
        Read = ($null -ne $text)
    }
}

function Save-RealDictationScreenshot {
    param(
        [Parameter(Mandatory)][ValidateSet('window', 'desktop')][string]$Kind,
        [long]$Handle = 0,
        [Parameter(Mandatory)][string]$Path
    )

    Initialize-RealDictationInterop
    $result = if ($Kind -eq 'window') {
        [NanoDictate.RealDictation.Native]::SaveWindowScreenshot($Handle, $Path)
    } else {
        [NanoDictate.RealDictation.Native]::SaveDesktopScreenshot($Path)
    }
    return [pscustomobject]@{
        Saved = [bool]$result.Saved
        Path = [string]$result.Path
        Method = [string]$result.Method
        WindowEvidence = [bool]$result.WindowEvidence
        Width = [int]$result.Width
        Height = [int]$result.Height
        NonBlankPixels = [int]$result.NonBlankPixels
    }
}

function Invoke-RealDictationWavPlayback {
    <# Renders a 16-bit PCM WAV into one render endpoint and blocks until drained. #>
    param(
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$Path
    )

    Initialize-RealDictationInterop
    return [double][NanoDictate.RealDictation.Native]::PlayWavToDevice($DeviceId, $Path)
}

function New-RealDictationPhraseWav {
    <#
      Synthesizes the qualification phrase with the runner's installed SAPI
      voice when no prerecorded WAV is supplied. The phrase is test-owned; no
      human or private audio is involved. Uses the SAPI COM automation objects
      so it works from PowerShell 7 without the .NET Framework-only
      System.Speech assembly.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-RealDictationPlatform)) {
        throw 'SAPI phrase synthesis requires Windows.'
    }
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $voice = $null
    $stream = $null
    $voiceName = ''
    try {
        $voice = New-Object -ComObject SAPI.SpVoice
        $stream = New-Object -ComObject SAPI.SpFileStream
        $tokenCount = [int]$voice.GetVoices().Count
        if ($tokenCount -eq 0) {
            throw 'No SAPI voice is installed on this runner; supply -PhraseWav with a prerecorded test-owned phrase.'
        }
        $voiceName = [string]$voice.Voice.GetDescription()
        # SSFMCreateForWrite = 3; SAFT16kHz16BitMono = 18, the 16-bit PCM
        # format the harness WAV reader accepts. Set the format before Open:
        # SpFileStream applies Format when the file is opened.
        $stream.Format.Type = 18
        $stream.Open($Path, 3, $false)
        $voice.AudioOutputStream = $stream
        $null = $voice.Speak($Text)
        $stream.Close()
    } finally {
        if ($stream) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream)
        }
        if ($voice) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($voice)
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "SAPI did not produce a phrase WAV at $Path"
    }
    return [pscustomobject]@{
        Path = $Path
        Voice = $voiceName
        Text = $Text
        Format = '16000 Hz mono 16-bit PCM'
    }
}

Export-ModuleMember -Function @(
    'Test-RealDictationPlatform'
    'Initialize-RealDictationInterop'
    'ConvertTo-NormalizedDictationText'
    'Get-DictationTokens'
    'Test-DictationPhraseInserted'
    'Find-VirtualCaptureEndpoint'
    'Get-PairedRenderEndpoint'
    'Resolve-VirtualAudioRoute'
    'Test-EndpointIdentityMatch'
    'Get-RealDictationHudPhase'
    'Test-RealDictationHudChanged'
    'Get-RealDictationVerdict'
    'Test-RealDictationEditorProcessOwned'
    'Test-RealDictationActiveEditorWindow'
    'Test-RealDictationEditorContentOwned'
    'Remove-RealDictationEditorMarker'
    'Test-RealDictationInsertion'
    'Get-RealDictationExitCode'
    'Test-RealDictationPathInside'
    'Resolve-RealDictationConfigBackupDirectory'
    'Backup-RealDictationProviderConfig'
    'Get-RealDictationProviderConfigState'
    'Set-RealDictationProviderConfig'
    'Restore-RealDictationProviderConfig'
    'Complete-RealDictationProviderConfigCleanup'
    'Format-RealDictationSummary'
    'Get-RealDictationSessionProbe'
    'Get-RealDictationAudioEndpoint'
    'Send-RealDictationDoubleAlt'
    'Send-RealDictationKey'
    'Get-RealDictationWindow'
    'Get-RealDictationWindowByTitlePattern'
    'Get-RealDictationForegroundWindow'
    'Get-RealDictationProcessWindow'
    'Set-RealDictationForegroundWindow'
    'Get-RealDictationEditorText'
    'Save-RealDictationScreenshot'
    'Invoke-RealDictationWavPlayback'
    'New-RealDictationPhraseWav'
)
