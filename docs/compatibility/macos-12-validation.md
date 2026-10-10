# macOS 12 compatibility validation

NanoDictate declares support for macOS **12 Monterey or later**
(`Package.swift` → `.macOS(.v12)`, `LSMinimumSystemVersion 12.0`,
Homebrew `depends_on macos: :monterey`).
Deployment-target compilation catches API-availability mistakes but **not**
runtime behavior in TCC, AVAudioEngine/HAL, Accessibility insertion,
LaunchAgent registration, or packaging flows. A newer runner is **not**
equivalent to macOS 12, and this gate never pretends otherwise.

## Strategy: supported Actions hosts + isolated macOS 12 execution

GitHub-hosted `macos-12` runners are retired, and since September 23, 2026
GitHub Actions runners use Node 24 for JavaScript actions (the Node 20
opt-out is gone). Node 24 is incompatible with macOS 13.4 and earlier, so no
JavaScript action (`actions/checkout`, `actions/upload-artifact`, ...) can
execute on a macOS 12 host, and self-hosted macOS 12 runners are no longer
supported. Updating action versions alone does not fix the host
incompatibility. The repeatable gate is therefore split:

1. **Static floor gate (always runs, hosted `macos-15`).**
   Verifies the declared floor is intact and the deployment-target build
   passes: `Package.swift` platform, `Info.NanoDictateApp.plist`
   `LSMinimumSystemVersion`, Homebrew formula/cask `:monterey` floor,
   the canonical `scripts/build-rust-core.sh --release` archive preparation,
   `MACOSX_DEPLOYMENT_TARGET=12.0` Swift build linked to that archive, `--version`/`--help`
   sanity, and linked `minos 12.x`. This catches accidental floor bumps
   and availability errors on every PR. It makes **no runtime claim**.
2. **Runtime gate (isolated macOS 12 machine or VM, out-of-band).**
   Runs `scripts/macos12-compat-check.sh --full` on **actual macOS 12
   execution** outside GitHub Actions. This is the only pass that validates
   install/startup, LaunchAgent registration, and best-effort audio HAL
   enumeration on the oldest supported major version. Dictation,
   microphone capture, Accessibility insertion, and package
   installation are **manual checklist items** (below), not automated phases.
   The Actions `runtime handoff` job runs on hosted `macos-15`, records a
   `needs-macos12-host` marker, and uploads it from the supported runner so
   artifact collection itself never depends on macOS 12 execution.

### Runner strategy (explicitly selected)

- Every GitHub Actions job runs on a **supported hosted runner**
  (`macos-15` with Node 24 actions: `actions/checkout@v5`,
  `actions/upload-artifact@v6`). No workflow job targets macOS 12 execution,
  so there is no hosted fallback gap to misread as equivalence.
- Actual macOS 12 validation runs on one **isolated macOS 12 machine or VM**
  (Intel or Apple Silicon; Apple Silicon preferred because release assets
  are arch-matched). No GitHub Actions runner is required there — and a
  macOS 12 self-hosted runner must not be relied on for `uses:` steps,
  because JavaScript actions cannot start on that OS after the Node 24
  migration. Copy the repository (git clone, USB, or `scp` bundle) to the
  isolated host, run `--full` there, and copy
  `.opencode-tmp/macos12-compat-results/` back to a supported machine for
  artifact collection and release evidence.
- The isolated host is maintained by the project owner (currently `@kodmial`).
  The absence of evidence leaves macOS 12 runtime compatibility UNVERIFIED.
  It must not block automated development or GitHub Release publication.
- If sustained macOS 12 validation becomes impossible (no hardware, no
  maintainer capacity), the minimum supported OS is **bumped** (e.g. to
  macOS 13) instead of being left unverified. The trigger rule: no green
  macOS 12 runtime run for 30 days → file a `priority:p1` issue titled
  `macOS 12 validation lapsed` and either restore the runner or raise the
  floor in `Package.swift`, plists, and packaging metadata together.

### Security model for the isolated machine

- The Actions workflow requests **no secrets** (`permissions: contents: read`,
  no `secrets: inherit`, no env credentials). Packaging smoke already
  avoids secrets; the compat script additionally uses an isolated `HOME`
  and performs no STT network calls.
- **No workflow job executes on the isolated macOS 12 host.** Every Actions
  job runs on hosted runners, so fork PRs are safe by construction: there is
  no self-hosted execution to gate and no `if:` exclusion to maintain. The
  isolated `--full` run uses a reviewed checkout transferred out-of-band
  (never an unreviewed fork push executed blindly).
- The isolated host holds no repository tokens beyond what the operator
  explicitly provides for the transfer, no Apple credentials, and no STT API
  keys.

## Critical compatibility checklist

Automated by `scripts/macos12-compat-check.sh --full` on macOS 12:

| # | Flow | Automated probe | Why macOS 12 matters |
|---|------|-----------------|----------------------|
| 1 | Declared floor | `Package.swift` `.v12`, plist `12.0`, brew `:monterey` | Floor drift silently drops 12 |
| 2 | Deployment-target build | Canonical Rust archive + `MACOSX_DEPLOYMENT_TARGET=12.0` Swift build with `-Xlinker <archive>` | Availability and Rust-link drift surface here |
| 3 | CLI sanity | `--version`, `--help`, `minos 12.x` linkage | Wrong SDK/minos ships wrong floor |
| 4 | Install/startup | `config init` in isolated HOME | First-launch paths differ by OS |
| 5 | LaunchAgent lifecycle | `start` → live `launchctl print gui/$UID` + PID → `stop` → gone → restart | `launchctl`/`gui` domain behavior varies |
| 6 | Audio HAL | Best-effort `system_profiler SPAudioDataType` enumeration, no capture (non-fatal when the probe is unavailable) | AVAudioEngine/HAL quirks are version-specific |
| 7 | Accessibility | Status recorded as `accessibility=manual-check-required`; no trust query and no insertion | Granting needs manual TCC approval |

Package installation (Homebrew formula/cask, MacPorts), microphone capture,
and Accessibility insertion are deliberately **not** automated: they need
install privileges, TCC grants, or UI interaction. They live in the manual
checklist below.

Manual-only checks (TCC/UI constraints prevent full automation):

- [ ] Grant **Microphone** to the 12-built `NanoDictateAgent`, record 10 s,
      stop, restart, record again — no hang, no stray TCC re-prompt.
- [ ] Grant **Accessibility**, insert dictation into TextEdit and a browser
      field; undo (`Double-Alt`) restores the prior text.
- [ ] Fresh `brew install --cask` / formula / MacPorts install on macOS 12,
      `nanodictate start`, reboot, agent auto-starts with grants intact.
- [ ] One-shot `nanodictate transcribe FILE` against the default provider
      (uses network; keep keys in the local keychain, never in CI logs).

Record manual results as a PR comment or release-checklist attachment with
the macOS build number (`sw_vers`), arch, and app version.

## How to run

Static gate (any macOS runner, including `macos-15`):

```sh
scripts/macos12-compat-check.sh --static-only
```

Full gate (only meaningful on actual macOS 12, out-of-band):

```sh
scripts/macos12-compat-check.sh --full
```

Run it on the isolated macOS 12 machine or VM after transferring a reviewed
checkout there (for example `git clone` the pinned commit, or copy a bundle
from a supported machine). Then collect the results back on a supported
machine — artifact upload itself must run where JavaScript actions work:

```sh
# On the isolated macOS 12 host:
scripts/macos12-compat-check.sh --full
# Then copy .opencode-tmp/macos12-compat-results/ back, e.g.:
# scp -r .opencode-tmp/macos12-compat-results user@supported-mac:/tmp/macos12-results
```

### Owner-only evidence intake (after the real macOS 12 run)

Run the `--full` probe from the **exact commit** being qualified on an
isolated macOS 12 machine. Complete and record all manual checklist items.
Transfer its `result.txt` and `environment.txt` to a supported machine.
Both files contain `source_sha`; the intake rejects mismatched revisions.

From a trusted, authenticated GitHub CLI on the supported machine (not on the
isolated macOS 12 host), with the project owner account:

```sh
# Run from the tested checkout after transferring the two evidence files:
TARGET_SHA="$(git rev-parse HEAD)"
RESULT_B64="$(base64 < .opencode-tmp/macos12-compat-results/result.txt | tr -d '\n')"
ENV_B64="$(base64 < .opencode-tmp/macos12-compat-results/environment.txt | tr -d '\n')"
gh workflow run macos12-runtime-evidence.yml --repo kodmial/nanodictate --ref main \
  -f source_sha="$TARGET_SHA" \
  -f result_base64="$RESULT_B64" \
  -f environment_base64="$ENV_B64" \
  -f manual_checklist=PASS
```

Only use `manual_checklist=PASS` if **every required** manual check actually
passed. Review the evidence-intake Actions run and immutable uploaded artifact.
Then rerun the PR `macOS 12 compat` check on the **same SHA** so it reads
the `macos12/runtime-attested` status. Any new PR commit invalidates the attestation
for that PR HEAD and requires a new real-host run.

The Release workflow separately requires a tested candidate, release integrity
checks and artifacts. This optional runtime attestation does not gate publication.
Do not claim macOS 12 runtime compatibility PASS without genuine evidence.

Attach `environment.txt` and `result.txt` (`result=full-green`,
`runtime_claim=macos-12`) as PR or release evidence. The Actions
`runtime handoff` job uploads its own `needs-macos12-host` marker from
`macos-15` on every run; it never claims a pass on behalf of the isolated
host.

Diagnostics on a newer host without claiming a pass (`--full` still refuses a
non-12 host before the build unless this flag is given, and the run never
records a runtime claim):

```sh
scripts/macos12-compat-check.sh --full --allow-non12-runtime
```

Skip the build when iterating on checklist docs (`--static-only` only; `--full
--skip-build` exits 2 because it could still print `result=full-green` without
the build, CLI probes, or LaunchAgent lifecycle):

```sh
scripts/macos12-compat-check.sh --static-only --skip-build
```

Results land in `.opencode-tmp/macos12-compat-results/` (never committed).

## CI status is not a runtime pass

The macOS 12 compat workflow reports two distinct results. The required
static-floor check runs automatically on a hosted macOS runner and fails for
real deployment-target/build defects. The runtime-evidence reporting job
records UNVERIFIED if there is no exact-SHA macOS 12 runtime result; that
status is not certification and is not an unrelated CI publication blocker.

To satisfy runtime qualification, execute `--full` on a real macOS 12 host
using the exact source revision under evaluation and provide its
`result.txt` (`result=full-green`, `runtime_claim=macos-12`) and
`environment.txt` (`macos_major=12`) to the trusted verification runner.
The release-critical manual TCC, microphone, text insertion and packaging
checklist must also be signed off separately; `full-green` by itself does
not establish those checks.

The hosted handoff job always produces `needs-macos12-host` and cannot
self-certify a runtime pass. The protected-main workflow
`.github/workflows/macos12-runtime-evidence.yml` accepts a **repository-owner
attestation only**, after the real host results are transferred to a supported
machine. It verifies the original `--full` outputs, macOS major 12, source
SHA, and operator's `PASS` for every manual checklist item, stores an immutable
Actions artifact, and adds the `macos12/runtime-attested` success commit
status linking to that workflow run. The PR runtime job checks this status
on the **exact current HEAD**, not an older reviewed version.

This is an explicit trusted-operator attestation, **not** a cryptographic
remote-execution proof. The owner must actually run on macOS 12 and inspect
the transferred evidence. The intake workflow does not execute untrusted PR
code or grant credentials to the macOS 12 host. No attestations currently
exist for an untested revision. Until genuine results are submitted the
runtime evidence remains UNVERIFIED; neither CI retries nor a macOS 15
static build can close the gap. Never waive it via `--allow-non12-runtime`.

## Failure visibility before release

- `.github/workflows/macos-12-compat.yml` runs the static gate on every PR
  touching `Sources/`, `rust/`, `Package.swift`, `packaging/`, `scripts/`,
  `Resources/`, or `config.example.toml`, plus weekly and on tags.
- The runtime handoff job runs on the hosted `macos-15` runner for every
  event (including forks) and uploads `result.txt` (`needs-macos12-host`)
  as an artifact, plus a job summary with the handoff instructions. Actual
  macOS 12 `full-green` evidence (`environment.txt`, `result.txt`, version
  probe) is produced on the isolated host and attached back to the PR or
  release from a supported machine, because artifact upload cannot execute
  on macOS 12.
- Release rule: existing exact-SHA packaging, signing and release-integrity
  checks remain mandatory. Missing separate macOS 12 runtime evidence is
  disclosed as UNVERIFIED; it does not halt unrelated development or a
  release, and it is never silently treated as a runtime PASS.
