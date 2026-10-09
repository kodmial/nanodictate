#!/usr/bin/env bash
# packaging-smoke-incident-decision.sh — single source of truth for the
# production packaging-smoke incident decision (issue #172).
#
# Sourced (not duplicated) by scripts/test-packaging-smoke-policy.sh and
# executed by the production-incident job in
# .github/workflows/nanodictate-packaging-smoke-engine.yml, so the workflow
# and its policy test can never drift apart:
#   green        -> success/success
#   incident     -> any leg failure/timed_out
#   superseded   -> not green but no failure (cancelled/skipped)
#
# As a sourced library:
#
#   # shellcheck source=scripts/packaging-smoke-incident-decision.sh
#   source "${REPO_ROOT}/scripts/packaging-smoke-incident-decision.sh"
#   smoke_incident_decision success cancelled  # prints: superseded
#
# As an executable (used by the workflow decision step):
#
#   bash scripts/packaging-smoke-incident-decision.sh success cancelled
#
# Prints exactly one of `green`, `incident`, or `superseded` on stdout.
# Exits 0 on a decision, 2 on wrong usage.

# Map two per-leg results to the incident-handling decision. Args: homebrew
# result, macports result (each one of success/failure/timed_out/cancelled/
# skipped). Only a real leg failure (failure/timed_out) carries product
# signal; cancelled or skipped legs mean the run was superseded (or never
# produced legs) and the superseding run reports on its own.
smoke_incident_decision() {
  local hb=$1 mp=$2
  local hb_failed=0 mp_failed=0
  [[ "$hb" == "failure" || "$hb" == "timed_out" ]] && hb_failed=1
  [[ "$mp" == "failure" || "$mp" == "timed_out" ]] && mp_failed=1
  if [[ "$hb" == "success" && "$mp" == "success" ]]; then
    printf 'green'
  elif [[ $hb_failed -eq 1 || $mp_failed -eq 1 ]]; then
    printf 'incident'
  else
    printf 'superseded'
  fi
}

# CLI entrypoint: only when executed, never when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -ne 2 ]]; then
    printf 'usage: %s <homebrew-result> <macports-result>\n' "${0##*/}" >&2
    exit 2
  fi
  smoke_incident_decision "$1" "$2"
fi
