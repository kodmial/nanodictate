#!/usr/bin/env bash
# Canonical release-note renderer and publication gate for NanoDictate.
#
# This file is a SOURCEABLE library (like scripts/release-policy.sh), not only
# an executable:
#
#   source scripts/release-notes.sh
#
# When executed directly it offers a small CLI:
#
#   bash scripts/release-notes.sh render < entries.tsv
#   bash scripts/release-notes.sh extract <version> < CHANGELOG.md
#   bash scripts/release-notes.sh normalize < section.md
#   bash scripts/release-notes.sh gate --version <v> --swift-version <v> \
#       --releasable <n> [--body-file <release-body.md>] < CHANGELOG.md
#   bash scripts/release-notes.sh first-version < CHANGELOG.md
#
# Design (single source of truth):
#
#   merged PR metadata (conventional subject + `Release note:` footer)
#     -> rendered canonical version section
#     -> CHANGELOG.md `## [<version>]` section (reviewed on the Release PR)
#     -> GitHub Release body (byte-for-byte or normalized-equal to the section)
#
# Nothing is scraped from free-form PR prose at publication time, and the
# release body is never generated independently: publication consumes the
# already-reviewed canonical section. See docs/release-notes.md for the full
# pipeline and the PR input contract.
#
# Entry input format (render): one entry per line, `|`-separated, 5 fields:
#
#   sha|conventional-subject|release-note|pr-number|labels
#
#   sha                  commit SHA (short or full) identifying the change.
#   conventional-subject full conventional-commit subject, e.g.
#                        "fix(audio): reuse buffers, cut locks".
#   release-note         human-readable user/developer-facing description.
#                        Empty means "fall back to the cleaned subject".
#                        "None" (any case, surrounding whitespace allowed)
#                        means "intentionally no user-facing note" and the
#                        entry is excluded from the rendered notes.
#   pr-number            merged PR number, may be empty.
#   labels               comma-separated PR labels, may be empty. An entry
#                        labelled `skip-release` is always excluded.
#
# `|` is the field separator and must not appear inside the subject or the
# release-note: producers must sanitize it (e.g. replace with `/`) before
# emitting entries. A line that does not contain exactly five `|`-separated
# fields is malformed and is skipped so a stray `|` can never shift fields
# or corrupt the `skip-release` check.
#
# Only the subject and the explicit release-note footer ever reach the notes:
# full PR bodies, review threads, Co-authored-by lines and automation chatter
# are never dumped into release notes.

# Canonical Keep a Changelog section order. Only sections that contain entries
# are rendered.
RELEASE_NOTES_SECTIONS="Added Changed Deprecated Removed Fixed Security"

# release_notes_section_for_type <type>
#
# stdout: the Keep a Changelog section for a conventional-commit type.
# Exits 1 (no output) for internal-only types that must never appear as
# user-facing changes. Unknown types map to Changed so nothing is silently
# lost; add an explicit hidden mapping below if a new noise type appears.
release_notes_section_for_type() {
  local t=${1:-}
  t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  case "$t" in
    feat) printf 'Added\n' ;;
    fix) printf 'Fixed\n' ;;
    security) printf 'Security\n' ;;
    perf | refactor | revert) printf 'Changed\n' ;;
    deprecate) printf 'Deprecated\n' ;;
    remove) printf 'Removed\n' ;;
    docs | style | test | build | ci | chore) return 1 ;;
    *) printf 'Changed\n' ;;
  esac
}

# release_notes_parse_subject <subject>
#
# stdout: `type|scope|breaking|description`. `type` is lowercased; `scope` may
# be empty; `breaking` is 1 when the subject carries a `!` marker, else 0.
# A subject without a conventional `type:` prefix yields type `other` with the
# full trimmed subject as description (it still renders, under Changed).
release_notes_parse_subject() {
  local subject=${1:-}
  # Trim surrounding whitespace without touching inner spacing.
  subject=$(printf '%s' "$subject" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [[ "$subject" =~ ^([A-Za-z]+)(\(([^\)]*)\))?(!)?:[[:space:]]*(.+)$ ]]; then
    local type scope breaking desc
    type=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    scope=${BASH_REMATCH[3]:-}
    breaking=0
    [[ -n "${BASH_REMATCH[4]:-}" ]] && breaking=1
    desc=${BASH_REMATCH[5]}
    printf '%s|%s|%s|%s\n' "$type" "$scope" "$breaking" "$desc"
  else
    printf 'other||0|%s\n' "$subject"
  fi
}

# release_notes_entry_text <subject> <release-note>
#
# stdout: the human-readable entry text, or nothing (exit 1) when the entry
# is intentionally internal-only (`Release note: None`). An absent note falls
# back to the cleaned conventional subject; the full PR body is never used.
release_notes_entry_text() {
  local subject=${1:-} note=${2:-}
  local trimmed
  trimmed=$(printf '%s' "$note" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  local lowered
  lowered=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')
  if [[ "$lowered" == "none" ]]; then
    return 1
  fi
  if [[ -n "$trimmed" ]]; then
    printf '%s\n' "$trimmed"
    return 0
  fi
  local parsed
  parsed=$(release_notes_parse_subject "$subject")
  # Strip the first three `|`-separated fields so a `|` inside the
  # description itself is preserved.
  local desc=${parsed#*|*|*|}
  desc=$(printf '%s' "$desc" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [[ -n "$desc" ]] || return 1
  printf '%s\n' "$desc"
}

# release_notes_has_skip_release <labels>
#
# Exit 0 when the comma-separated label list carries exactly `skip-release`.
release_notes_has_skip_release() {
  local labels=${1:-}
  [[ -n "$labels" ]] || return 1
  local IFS=','
  local part
  for part in $labels; do
    part=$(printf '%s' "$part" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ "$part" == "skip-release" ]] && return 0
  done
  return 1
}

# release_notes_render
#
# stdin:  `|`-separated entry lines (see header).
# stdout: the canonical version-section body: `### <Section>` groups in
#         canonical order, one `- <text> (<refs>)` bullet per entry.
#         Groups without entries are omitted.
#
# Deterministic and idempotent: the same entry set always renders the same
# body; a repeated sha renders once (first occurrence wins); previously
# rendered entries keep their relative order when new entries accumulate.
release_notes_render() {
  local line sha subject note pr labels
  local -a seen_shas=()
  local added="" changed="" deprecated="" removed="" fixed="" security=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    # Fail closed on malformed entries: exactly five `|`-separated fields
    # (four separators) are required. A `|` inside the subject or note
    # would otherwise shift fields — the remainder lands in `labels` and
    # the `skip-release` check reads the wrong field — so such lines are
    # skipped instead of rendered with truncated or misattributed notes.
    local pipes=${line//[^|]/}
    [[ "${#pipes}" -eq 4 ]] || continue
    # `|` is a non-whitespace IFS character, so empty middle fields are
    # preserved (a TAB separator would collapse them as IFS whitespace).
    IFS='|' read -r sha subject note pr labels <<< "$line"
    sha=$(printf '%s' "${sha:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    subject=${subject:-}
    note=${note:-}
    pr=$(printf '%s' "${pr:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    labels=${labels:-}
    [[ -n "$sha" ]] || continue
    # Deduplicate by sha: reruns and overlapping Release PR updates must not
    # publish the same change twice.
    local s already=0
    for s in "${seen_shas[@]:-}"; do
      [[ "$s" == "$sha" ]] && { already=1; break; }
    done
    [[ "$already" -eq 1 ]] && continue
    seen_shas+=("$sha")
    # skip-release PRs never reach user-facing notes.
    if release_notes_has_skip_release "$labels"; then
      continue
    fi
    local parsed type scope scope_lower
    parsed=$(release_notes_parse_subject "$subject")
    type=${parsed%%|*}
    scope=${parsed#*|}
    scope=${scope%%|*}
    scope=$(printf '%s' "$scope" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    scope_lower=$(printf '%s' "$scope" | tr '[:upper:]' '[:lower:]')
    # `release` scope is internal plumbing (manifest syncs, version bumps):
    # without an explicit non-`None` user-facing note it never renders, even
    # for otherwise visible types such as `fix`. An explicit note renders
    # normally so a visible release-process change stays describable.
    if [[ "$scope_lower" == "release" ]]; then
      local scope_note_trimmed scope_note_lowered
      scope_note_trimmed=$(printf '%s' "$note" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      scope_note_lowered=$(printf '%s' "$scope_note_trimmed" | tr '[:upper:]' '[:lower:]')
      if [[ -z "$scope_note_trimmed" || "$scope_note_lowered" == "none" ]]; then
        continue
      fi
    fi
    local text
    if ! text=$(release_notes_entry_text "$subject" "$note"); then
      continue
    fi
    local section
    if ! section=$(release_notes_section_for_type "$type"); then
      # `build` is hidden by default, but a user-visible packaging or
      # installation change carries an explicit non-`None` note and renders
      # under Changed. Other hidden types stay excluded even with a note.
      [[ "$type" == "build" && -n "${note//[[:space:]]/}" ]] || continue
      section=Changed
    fi
    # One-line bullets: embedded newlines/carriage returns would break the
    # section shape, so collapse them to spaces.
    text=$(printf '%s' "$text" | tr '\n\r' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    [[ -n "$text" ]] || continue
    local refs="[\`${sha}\`](https://github.com/kodmial/nanodictate/commit/${sha})"
    if [[ -n "$pr" ]]; then
      refs="${refs}, [#${pr}](https://github.com/kodmial/nanodictate/pull/${pr})"
    fi
    local bullet="- ${text} (${refs})"
    case "$section" in
      Added) added+="${bullet}"$'\n' ;;
      Changed) changed+="${bullet}"$'\n' ;;
      Deprecated) deprecated+="${bullet}"$'\n' ;;
      Removed) removed+="${bullet}"$'\n' ;;
      Fixed) fixed+="${bullet}"$'\n' ;;
      Security) security+="${bullet}"$'\n' ;;
    esac
  done
  local out=""
  [[ -n "$added" ]] && out+="### Added"$'\n\n'"${added}"$'\n'
  [[ -n "$changed" ]] && out+="### Changed"$'\n\n'"${changed}"$'\n'
  [[ -n "$deprecated" ]] && out+="### Deprecated"$'\n\n'"${deprecated}"$'\n'
  [[ -n "$removed" ]] && out+="### Removed"$'\n\n'"${removed}"$'\n'
  [[ -n "$fixed" ]] && out+="### Fixed"$'\n\n'"${fixed}"$'\n'
  [[ -n "$security" ]] && out+="### Security"$'\n\n'"${security}"$'\n'
  # Trailing blank line separates the body from the next header; strip it so
  # the body is exactly comparable (awk, portable across GNU/BSD).
  out=$(printf '%s\n' "$out" | awk '{ lines[NR] = $0 } END { last = 0; for (i = NR; i >= 1; i--) if (lines[i] !~ /^[[:space:]]*$/) { last = i; break } for (i = 1; i <= last; i++) print lines[i] }')
  printf '%s' "$out"
  [[ -z "$out" ]] || printf '\n'
}

# release_notes_extract_section <version>
#
# stdin:  the whole CHANGELOG.md.
# stdout: the exact `## [<version>]` section, header line included, up to (not
#         including) the next `## ` header or the trailing link-definition
#         block. Exits 1 when the version section is missing.
release_notes_extract_section() {
  local version=${1:-}
  if [[ -z "$version" ]]; then
    echo "release_notes_extract_section: <version> is required" >&2
    return 1
  fi
  awk -v version="$version" '
    $0 == "## [" version "]" || index($0, "## [" version "] - ") == 1 { capture = 1; print; next }
    capture && /^## / { exit }
    capture && /^\[[^]]+\]:/ { exit }
    capture { print }
    END { if (!capture) exit 1 }
  '
}

# release_notes_first_version
#
# stdin:  the whole CHANGELOG.md.
# stdout: the first `## [<semver>]` header after `## [Unreleased]` — the same
#         header Tests/NanoDictateCoreTests/VersionTests.swift compares
#         NanoDictateVersion.string against.
release_notes_first_version() {
  awk '
    /^## \[Unreleased\]$/ { after = 1; next }
    after && /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ {
      header = $0
      sub(/^## \[/, "", header)
      sub(/\].*$/, "", header)
      print header
      exit
    }
  '
}

# release_notes_normalize
#
# stdin:  a rendered section or release body.
# stdout: the normalized form used for equivalence checks: CRLF -> LF,
#         trailing whitespace stripped per line, leading/trailing blank lines
#         removed. The GitHub Release body is accepted when it is byte-for-byte
#         OR normalization-equivalent to the canonical section.
release_notes_normalize() {
  sed -E -e 's/\r$//' -e 's/[[:space:]]+$//' | awk '
    { lines[NR] = $0 }
    END {
      first = 1; last = 0
      for (i = 1; i <= NR; i++) if (lines[i] !~ /^[[:space:]]*$/) { first = i; break }
      for (i = NR; i >= 1; i--) if (lines[i] !~ /^[[:space:]]*$/) { last = i; break }
      if (last < first) exit 0
      for (i = first; i <= last; i++) print lines[i]
    }
  '
}

# release_notes_section_is_empty
#
# stdin:  an extracted `## [<version>]` section (header included).
# Exit 0 when the section carries no releasable content (only the header,
# blank lines, bare `###` group headers, HTML comments and/or placeholder
# text without a list entry), 1 otherwise. A releasable entry is a bullet
# (`-`, `*` or ordered-list marker) under a changelog category. This is the
# guard against the v0.1.7 empty-section failure mode recurring.
release_notes_section_is_empty() {
  local body stripped bullet
  body=$(grep -vE '^## \[' || true)
  # HTML comments must not count as release notes. Strip complete
  # `<!-- ... -->` spans, including multiline comments, before checking
  # for entries so a bullet hidden inside a comment cannot pass the gate.
  stripped=$(printf '%s\n' "$body" | awk '
    {
      line = $0
      out = ""
      while (length(line) > 0) {
        if (in_comment) {
          end = index(line, "-->")
          if (end == 0) { line = ""; break }
          else { line = substr(line, end + 3); in_comment = 0 }
        } else {
          start = index(line, "<!--")
          if (start == 0) { out = out line; line = ""; break }
          else {
            out = out substr(line, 1, start - 1)
            line = substr(line, start + 4)
            end = index(line, "-->")
            if (end == 0) { in_comment = 1; line = ""; break }
            else { line = substr(line, end + 3) }
          }
        }
      }
      print out
    }
  ' | grep -vE '^[[:space:]]*$' | grep -vE '^###[[:space:]]+[A-Za-z]+[[:space:]]*$' || true)
  [[ -z "${stripped//[[:space:]]/}" ]] && return 0
  # Placeholders such as a bare TODO without a bullet do not count: require
  # an actual list entry.
  bullet=$(printf '%s\n' "$stripped" | grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+[^[:space:]]' || true)
  [[ -z "$bullet" ]]
}

# release_notes_gate_publish
#
# Fail-closed publication gate. CHANGELOG.md on stdin.
#
#   release_notes_gate_publish <version> <swift-version> <releasable-count> [body-file]
#
# Fails (exit 1) when:
#   - <releasable-count> is omitted (pass 0 explicitly for a no-change release);
#   - the `## [<version>]` section is missing;
#   - the section is empty while <releasable-count> > 0;
#   - <version> disagrees with <swift-version> (Sources/NanoDictateCore/Version.swift);
#   - [body-file] is given and its content is neither byte-for-byte nor
#     normalization-equivalent to the canonical section.
release_notes_gate_publish() {
  local version=${1:-} swift_version=${2:-} releasable=${3:-} body_file=${4:-}
  if [[ -z "$releasable" ]]; then
    echo "release_notes_gate_publish: <releasable-count> is required" >&2
    return 1
  fi
  if [[ -z "$version" || -z "$swift_version" ]]; then
    echo "release_notes_gate_publish: <version> and <swift-version> are required" >&2
    return 1
  fi
  if [[ "$version" != "$swift_version" ]]; then
    echo "release_notes_gate_publish: version $version disagrees with Version.swift ($swift_version)" >&2
    return 1
  fi
  local content section
  content=$(cat; printf 'x') || return 1
  content=${content%x}
  if ! section=$(release_notes_extract_section "$version" <<< "$content"); then
    echo "release_notes_gate_publish: CHANGELOG.md has no '## [$version]' section" >&2
    return 1
  fi
  if printf '%s' "$section" | release_notes_section_is_empty; then
    if [[ "$releasable" != "0" ]]; then
      echo "release_notes_gate_publish: '## [$version]' is empty but $releasable releasable change(s) exist — refusing to publish without notes" >&2
      return 1
    fi
  fi
  if [[ -n "$body_file" ]]; then
    local body_norm section_norm body
    [[ -f "$body_file" ]] || {
      echo "release_notes_gate_publish: body file '$body_file' not found" >&2
      return 1
    }
    body=$(cat "$body_file")
    if [[ "$body" == "$section" ]]; then
      return 0
    fi
    body_norm=$(printf '%s' "$body" | release_notes_normalize)
    section_norm=$(printf '%s' "$section" | release_notes_normalize)
    if [[ "$body_norm" != "$section_norm" ]]; then
      echo "release_notes_gate_publish: release body differs from canonical '## [$version]' section" >&2
      return 1
    fi
  fi
  return 0
}

# --- CLI -------------------------------------------------------------------
release_notes_cli() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    render) release_notes_render ;;
    extract)
      release_notes_extract_section "${1:-}" ;;
    normalize) release_notes_normalize ;;
    first-version) release_notes_first_version ;;
    gate)
      local version="" swift_version="" releasable="" body_file=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --version)
            if [[ $# -lt 2 ]]; then echo "gate: --version requires a value" >&2; return 1; fi
            version=$2; shift 2 ;;
          --swift-version)
            if [[ $# -lt 2 ]]; then echo "gate: --swift-version requires a value" >&2; return 1; fi
            swift_version=$2; shift 2 ;;
          --releasable)
            if [[ $# -lt 2 ]]; then echo "gate: --releasable requires a value" >&2; return 1; fi
            releasable=$2; shift 2 ;;
          --body-file)
            if [[ $# -lt 2 ]]; then echo "gate: --body-file requires a value" >&2; return 1; fi
            body_file=$2; shift 2 ;;
          *) echo "unknown gate flag: $1" >&2; return 1 ;;
        esac
      done
      release_notes_gate_publish "$version" "$swift_version" "$releasable" "$body_file" ;;
    *)
      echo "usage: release-notes.sh {render|extract <version>|normalize|first-version|gate --version V --swift-version S --releasable N [--body-file F]}" >&2
      return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  set -uo pipefail
  release_notes_cli "$@"
fi
