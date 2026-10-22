# Windows validation and evidence status

Runbook for the shipped Windows product plus the contracts CI enforces on
every change. Check off physical items on a release candidate; file deviations
as follow-up issues.

## Shipped first-use path

1. Download `nanodictate-X.Y.Z-windows-x64-setup.exe` from the stable GitHub
   Release (or run `scripts/install-windows.ps1`).
2. The per-user installer starts one `NanoDictate.App.exe --background`. No
   settings window, console or developer dashboard appears on first use.
3. On first launch the app copies the bundled `config.example.toml` to
   `%APPDATA%\NanoDictate\config.toml` if absent. The default keyless Airubiz
   provider and model make an immediate first dictation possible.
4. Double-Alt shows the transient microphone HUD only; release audio, STT and
   insertion follow the shared session contract, then the HUD hides.
5. Settings remains optional via the Start Menu shortcut or a second launch
   while idle. Closing settings leaves the background agent running.

## Installer process-tree incident (issue #234)

The Windows host run
[39684741385 / job 119516008970](https://github.com/kodmial/nanodictate/actions/runs/39684741385/job/119516008970)
at HEAD `ccb8dee403fe5f89830bc5d5cb5487720ff8c83b` started step 19
`Verify portable files and silent install/upgrade/uninstall` at
2026-10-21 22:16:23 UTC. The step emitted its inline script and `##[endgroup]`
at 22:16:23, then produced no further output and was cancelled at 23:12:42
UTC (56m19s) when the job reached its 60-minute limit. During job finalization,
GitHub logged:

```
Terminate orphan process: pid (5632) (NanoDictate.App)
```

The finalization log identifies the persistent product agent (pid 5632) as the
surviving process, not the setup root. No setup process remained at cleanup,
consistent with Setup having completed before the outer wait blocked. GitHub
did not serve the live job log while the step was running and the step logged
no subphase entry/exit, so neither the exact live stack nor which of the four
phases was stalled could be observed. The end-of-job log above is the strongest
available process detail; the orphan's final exit state was not recorded because
GitHub terminated it during job finalization. The step's inline script contained
four unbounded `Start-Process ... -Wait` calls for first install, same-version
reinstall, versioned upgrade and uninstall. Microsoft documents `Start-Process -Wait` as
waiting for the whole process tree, while Inno `[Run] ... nowait postinstall`
intentionally starts `NanoDictate.App.exe --background` and leaves it running.
Setup could therefore complete while the outer tree wait remained blocked for
the lifetime of the background agent.

The regression harness in `scripts/test-windows-installer-runner.ps1` proves
both halves deterministically on Windows: legacy `Start-Process -Wait` stays
blocked by a short-lived launcher's persistent child, while the shared runner
returns after the installer root completes and leaves that independent child
alive.

The repair is `scripts/windows-installer-runner.psm1`. It waits for the direct
installer, then for Inno-style bootstrap/worker descendants, but never for
`NanoDictate.App`. The module supports Windows PowerShell 5.1 and PowerShell 7
by constructing Inno Setup-compatible command lines with whole-argument quoting
instead of `ProcessStartInfo.ArgumentList` or MSVCRT backslash escaping. Every
install/reinstall/upgrade/uninstall phase has a deadline, writes phase evidence
and retains `/LOG` output; timeouts terminate only processes owned by that test
phase. The workflows upload `windows/artifacts/installer-logs/**` with
`if: always()` so a failed validation still leaves the useful diagnostic. The CI lifecycle also runs the exact
user-facing `Install-NanoDictateVerified` path, checks one background agent and
preserves user configuration across reinstall, versioned upgrade and uninstall.
The first successful Windows run records the actual phase durations in
`windows-ci-lifecycle-measurements.json`; the 240-second setup and 120-second
uninstall caps leave headroom for runner variability while failing long before
the 45-minute job budget.

## Automated evidence (headless)

- `windows.yml` builds the Rust DLL, portable solution, WinUI 3 app and host;
  runs Rust tests, xUnit tests, the smoke executable (deterministic, synthetic
  capture and transcription planning), `doctor` and `providers`; builds the
  real self-contained ZIP and Inno EXE; and exercises silent install,
  same-version reinstall, versioned upgrade, uninstall, startup registration
  and config preservation.
- `test-windows-distribution.ps1` guards the first-use launch contracts and
  `test-windows-install-chain.ps1` exercises the offline manifest -> release
  asset -> SHA256SUMS selection, including a lagging manifest and an
  incomplete release upload.
- `test-release-candidate.ps1` checks exact ZIP/EXE payload identity, the
  bundled keyless Airubiz defaults, install/reinstall/uninstall, exactly one
  persistent background agent and records the measured installer/ZIP size and
  elapsed times. It reports the actual candidate, not an unsupported
  performance target.
- `test-ci-installer-lifecycle.ps1` exercises the user-facing install function
  against the candidate EXE, then same-version reinstall, a versioned in-place
  upgrade and uninstall. Every phase uses the shared bounded runner, retains
  Inno logs and fails closed with a per-operation deadline.
- xUnit asserts first-use config bootstrap (copy once, never overwrite,
  keyless Airubiz defaults), single-instance ownership/recovery, failover/
  backoff/review/retry/overlay/mic-request gates, multipart/transport shape,
  chunked stitching, synthetic capture readiness/undo/Enter semantics, and
  the shared HUD fixture constants, RMS/VU vectors, presentation scenarios,
  generation guards and fail-closed review.
- Smoke asserts mean per-block cost stays well below the 100 ms block budget
  and prints activation-to-ready, callback cost, CPU/working-set,
  consumed-vs-emitted frames, copies per block and auto-stop outcome.
- Published-release smoke (`windows-release-smoke.yml`,
  `windows-distribution-smoke.yml`) downloads public assets, checks them
  against `SHA256SUMS.txt`, installs/upgrades/uninstalls and preserves user
  configuration. Authenticode is reported separately as `VALID` or
  `UNVERIFIED`; a passing install never implies a signed build.

## Evidence status by stage

| Stage | Automated evidence | Physical Windows status |
| --- | --- | --- |
| Release selection, asset, SHA-256 | PowerShell/static scripts plus published smoke; verified by CI when release assets exist | Not applicable (no physical Windows check) |
| Inno install/upgrade/uninstall, startup, config retention | Candidate and published smoke; verified headless | **Outstanding physical install/upgrade/uninstall check** |
| First-run config from bundled example, keyless Airubiz | xUnit bootstrap + candidate payload check | Not separately re-run on real desktop |
| One quiet background launch, no forced settings | Installer/script/manifest contract tests | **Outstanding interactive check** |
| Second launch / single instance | xUnit mutex + existing idle-settings routing tests | WinUI relaunch on real desktop **outstanding** |
| Double-Alt hook, Escape/Return | Deterministic routing tests | **Outstanding real keyboard check** |
| HUD phases, meter, placement, theme | Shared fixture, xUnit, synthetic capture | **Outstanding real HUD/caret check** |
| WASAPI microphone, privacy denial, device loss | Classifier and synthetic pipeline tests | **Outstanding real device/privacy check** |
| STT request/response and failover | Mock transport and Rust policy vectors | Live provider over real network **outstanding** |
| Unicode/Russian/emoji insertion, undo, clipboard | Sender/chunk/undo tests | **Outstanding real focused-app check** |

Do not infer supported hardware behavior from `doctor`, the ZIP smoke, a
virtual audio device or a hosted runner. Record a real Windows 10 and Windows
11 desktop run before claiming it.

## Manual hardware checklist

1. Clean install/first launch: install the published EXE on a fresh profile.
   Confirm exactly one `NanoDictate.App.exe` starts in the background, no
   settings window or console appears, and `%APPDATA%\NanoDictate\config.toml`
   is created from the example without touching any pre-existing config.
2. Silent upgrade: install a previous published version, edit the config, then
   run the newer EXE (and separately `install-windows.ps1`). Confirm one
   background agent, preserved config and unchanged logon startup path.
3. Microphone access: deny once -> privacy guidance with
   `ms-settings:privacy-microphone` appears and repeat prompts are throttled;
   allow -> recording starts. Unplug the only microphone -> actionable
   no-device/disconnect message.
4. Repeated recording: start/stop 10 times; every session reaches readiness
   exactly once and releases COM objects (no leak, no wedge).
5. Immediate speech: speak within 200 ms of activation; the first word
   survives (no warm-up frames dropped).
6. Device change: unplug/replug the default capture device mid-session ->
   session aborts with DeviceChanged; one restart resumes.
7. Global activation: double-Alt toggles from a focused editor; single Alt,
   other keys, and repeats never trigger.
8. Escape/Return: Escape cancels capture, latch, and scheduled Enter; Return
   arms the latch and stops; synthetic Enter is never re-routed.
9. Unicode insertion: Cyrillic + emoji insert correctly in direct mode;
   Backspace undo erases exactly the last insertion inside the window.
10. Clipboard mode: insert via clipboard restores the original text after
    0.5 s; overlapping inserts keep only the latest restore.
11. Normal/chunked transcription: short utterance inserts once; a 2-minute
    recording in chunked mode stitches in order with no duplication at seams.
12. Retry/failover: airplane-mode attempt fails fast with no silent fallback;
    with two providers and auto-failover, the failed provider moves to the end
    and the second answers.
13. Restart/startup: sign out and back in -> dictation hotkey works with no
    visible window; a second launch opens optional settings only while idle
    and never creates a second hook or process.
14. HUD phases: fast start skips `Starting`; a slow start shows it only after
    the grace window; the timer starts on the first valid buffer; stop shows
    Processing with three dots and insert/empty/cancel hide within 0.8 s,
    errors/microphone failure within 2 s.
15. HUD placement/style: the panel appears above the UIA text caret when the
    focused editor exposes TextPattern (native caret/pointer/screen center
    fallback), is clamped on secondary/DPI-scaled monitors, respects
    light/dark/high-contrast colors and Reduce Motion, stays topmost, takes no
    focus, is click-through, and never appears in the taskbar or Alt-Tab.
16. HUD robustness: Escape during Processing hides the panel immediately even
    while Rust is still settling; a rapid restart keeps the new generation
    visible; a stale hide or late callback cannot dismiss it.
17. Review prompt: enabled review shows the transient window; missing or
    failed UI inserts nothing (fail-closed); a second launch while
    recording/transcribing does not open settings or steal focus.
18. Uninstall: use the Inno uninstaller and Scoop's uninstall separately.
    Confirm the application and its own Run value are removed while
    `%APPDATA%\NanoDictate\config.toml` and logs remain.

## Measurement comparison

Record per session: activation-to-ready (trigger->request,
request->engine-started, engine-started->first-buffer), mean/max block
callback cost, CPU time, working set, device frames vs engine samples,
and auto-stop outcome (the smoke line prints the same fields). Use the actual
candidate or published smoke for installer size and the download/install
timings it records. Record launch elapsed time during the manual desktop check
before proposing a performance change. Compare
against the macOS contracts in `docs/stt-benchmark.md` and
`docs/realtime-transcription.md`; file material regressions (missed first
word, block cost near the 100 ms budget, sample loss, duplicated seams, or a
clearly redundant transfer) as release blockers.
