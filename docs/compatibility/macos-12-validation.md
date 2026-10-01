# macOS 12 compatibility validation

NanoDictate declares support for macOS **12 Monterey or later**
(`Package.swift` → `.macOS(.v12)`, `LSMinimumSystemVersion 12.0`,
Homebrew `depends_on macos: :monterey`).
Deployment-target compilation catches API-availability mistakes but **not**
runtime behavior in TCC, AVAudioEngine/HAL, Accessibility insertion,
LaunchAgent registration, or packaging flows. A newer runner is **not**
equivalent to macOS 12, and this gate never pretends otherwise.

## Strategy: self-hosted macOS 12 runner + static floor gate

GitHub-hosted `macos-12` runners are retired, so there is no hosted
equivalent. The repeatable gate is:

1. **Static floor gate (always runs, hosted `macos-15`).**
   Verifies the declared floor is intact and the deployment-target build
   passes: `Package.swift` platform, `Info.NanoDictateApp.plist`
   `LSMinimumSystemVersion`, Homebrew formula/cask `:monterey` floor,
   `MACOSX_DEPLOYMENT_TARGET=12.0 swift build`, `--version`/`--help`
   sanity, and linked `minos 12.x`. This catches accidental floor bumps
   and availability errors on every PR. It makes **no runtime claim**.
2. **Runtime gate (self-hosted macOS 12 machine).**
   Runs `scripts/macos12-compat-check.sh --full` on **actual macOS 12
   execution**. This is the only pass that validates install/startup,
   LaunchAgent registration, best-effort audio HAL enumeration, and basic
   dictation plumbing on the oldest supported major version. Microphone
   capture, Accessibility insertion, and package installation are **manual
   checklist items** (below), not automated phases.

### Runner strategy (explicitly selected)

- One persistent (or ephemeral-VM) **self-hosted runner** on real macOS 12
  hardware (Intel or Apple Silicon; Apple Silicon preferred because
  release assets are arch-matched), registered with the labels
  `self-hosted`, `macos-12`.
- The runner is maintained by the project owner (currently `@kodmial`).
  Until it is registered, the runtime job waits/skips visibly — releases
  must not ship without either a green runtime run or an explicit manual
  checklist sign-off (see below).
- If sustained macOS 12 validation becomes impossible (no hardware, no
  maintainer capacity), the minimum supported OS is **bumped** (e.g. to
  macOS 13) instead of being left unverified. The trigger rule: no green
  macOS 12 runtime run for 30 days → file a `priority:p1` issue titled
  `macOS 12 validation lapsed` and either restore the runner or raise the
  floor in `Package.swift`, plists, and packaging metadata together.

### Security model for the self-hosted machine

- The runtime job requests **no secrets** (`permissions: contents: read`,
  no `secrets: inherit`, no env credentials). Packaging smoke already
  avoids secrets; the compat script additionally uses an isolated `HOME`
  and performs no STT network calls.
- **Fork PR code never executes on the self-hosted runner.** The runtime
  job runs only for same-repo PRs, `main` pushes, tags, schedules, and
  `workflow_dispatch` (`if: github.event.pull_request.head.repo.full_name
  == github.repository`). Fork PRs get the static gate plus a visible
  `skipped-fork` note; a maintainer re-runs validation via
  `workflow_dispatch` after review.
- The self-hosted host holds no repository tokens beyond the ephemeral
  runner token, no Apple credentials, and no STT API keys.

## Critical compatibility checklist

Automated by `scripts/macos12-compat-check.sh --full` on macOS 12:

| # | Flow | Automated probe | Why macOS 12 matters |
|---|------|-----------------|----------------------|
| 1 | Declared floor | `Package.swift` `.v12`, plist `12.0`, brew `:monterey` | Floor drift silently drops 12 |
| 2 | Deployment-target build | `MACOSX_DEPLOYMENT_TARGET=12.0 swift build` | Availability errors surface here |
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

Full gate (only meaningful on actual macOS 12):

```sh
scripts/macos12-compat-check.sh --full
```

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

## Failure visibility before release

- `.github/workflows/macos-12-compat.yml` runs the static gate on every PR
  touching `Sources/`, `Package.swift`, `packaging/`, `scripts/`,
  `Resources/`, or `config.example.toml`, plus nightly and on tags.
- The runtime job runs on the `macos-12` self-hosted runner for trusted
  events and uploads `environment.txt`, `result.txt`, and the version
  probe as artifacts, plus a job summary stating the macOS build.
- Release rule: do not publish a release when the static gate is red, when
  the runtime gate is red, or when the runtime gate has not produced a
  `full-green` on the release bytes — attach the manual checklist instead
  and note it in the release notes. A missing runner is a visible gap,
  not a silent pass.
