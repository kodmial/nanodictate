# Windows hardware validation

Manual validation runbook for real Windows hardware plus the automated
contracts CI enforces on every change. Check off each item on the release
candidate; file deviations as follow-up issues. CI alone is never proof of
the physical rows below: every release needs real-hardware evidence entries
in the table at the end.

## Automated contracts (CI, no hardware)

- `windows.yml` builds the Rust DLL, the portable solution, the WinUI 3
  app, and the host; runs Rust tests, xUnit tests (including the installed
  product-version tests), the smoke executable (deterministic + synthetic
  capture + transcription planning vectors), `doctor`, `providers`, and
  `version`; runs `scripts/test-windows-distribution.sh`; stages the MSIX
  layout and portable ZIP as validation-only artifacts; builds the real
  per-user Inno Setup installer; generates and validates the WinGet
  manifests; and runs `test-installer.ps1` for install → versioned
  upgrade → uninstall with user-data preservation, asserting no orphaned
  installation. Logs upload as `nanodictate-windows-install-test-logs`.
- `windows-release.yml` repeats the same gate for the release version with
  `-RequireSigned` (fail-closed without signing credentials) and attaches
  the installer plus `.sha256` to the same GitHub Release as macOS.
- `winget-submit.yml` regenerates the manifests from the published
  installer hash and validates identifier, installer type, silent switches,
  version, and SHA before any upstream submission.
- xUnit asserts: failover/backoff/review/retry/overlay/mic-request gates
  match Rust; multipart shape and field gating; proxy rewrites; chunked
  stitching and final-pass policy; realtime resampling and fail-closed
  lifecycle; config parsing; capture readiness/undo/Enter semantics;
  installed product-version precedence and fallback.
- Smoke asserts: mean per-block cost stays far below the 100 ms block
  budget and prints activation-to-ready, callback cost, CPU/working-set,
  consumed-vs-emitted frames, copies per block (2), and auto-stop outcome.

## Manual hardware checklist

1. Clean install/first launch: install `NanoDictate-Setup-<version>-x64.exe`
   on a fresh profile (Windows 10 22H2 and Windows 11); first launch creates
   `%APPDATA%\NanoDictate\config.toml` from the example without touching an
   existing config.
2. Microphone access: deny once → privacy guidance with
   `ms-settings:privacy-microphone` appears and repeat prompts are
   throttled; allow → recording starts.
3. Repeated recording: start/stop 10 times; every session reaches
   readiness exactly once and releases COM objects (no leak, no wedge).
4. Immediate speech: speak within 200 ms of activation; the first word
   survives (no warm-up frames dropped).
5. Device change: unplug/replug the default capture device mid-session →
   session aborts with DeviceChanged; one restart resumes.
6. Global activation: double-Alt toggles from a focused editor; single
   Alt, other keys, and repeats never trigger.
7. Escape/Return: Escape cancels capture, latch, and scheduled Enter;
   Return arms the latch and stops; synthetic Enter is never re-routed.
8. Unicode insertion: Cyrillic + emoji insert correctly in direct mode;
   Backspace undo erases exactly the last insertion inside the window.
9. Clipboard mode: insert via clipboard restores the original text after
   0.5 s; overlapping inserts keep only the latest restore.
10. Normal/chunked transcription: short utterance inserts once; a
    2-minute recording in chunked mode stitches in order with no
    duplication at seams.
11. Retry/failover: airplane-mode attempt fails fast with no silent
    fallback; with two providers and auto-failover, the failed provider
    moves to the end and the second answers.
12. Restart/startup: enable startup → reboot → tray icon returns and a
    second launch exits as a duplicate instance.
13. Installer upgrade: install the previous release, configure dictation,
    upgrade with the candidate installer silently; config, mic-request
    state, and logs survive and `nanodictate version` reports the new
    version.
14. Installer uninstall: uninstall silently; program files are gone, the
    HKCU Run value is removed, and `%APPDATA%\NanoDictate` plus
    `%LOCALAPPDATA%\NanoDictate\Logs` are preserved.

## Physical evidence checklist (required per release)

CI proves the installer mechanics; it cannot press Double-Alt on real
hardware, hear a microphone, or see a tray icon. For each release, fill one
row per OS with the installer version, machine, and outcome. Link the run
or attach logs; a row left blank is a release blocker, not an implied pass.

| Release | OS (10 22H2 / 11) | Machine / mic | Installer + SHA verified | Rows 1-14 outcome | Evidence link | Tester + date |
|---|---|---|---|---|---|---|
| _example: 0.1.32_ | _Win 11 x64_ | _laptop + USB headset_ | _yes_ | _all pass_ | _<run URL>_ | _name, YYYY-MM-DD_ |
| | | | | | | |
| | | | | | | |

## Measurement comparison

Record per session: activation-to-ready (trigger→request,
request→engine-started, engine-started→first-buffer), mean/max block
callback cost, CPU time, working set, device frames vs engine samples,
and auto-stop outcome (the smoke line prints the same fields). Compare
against the macOS contracts in `docs/stt-benchmark.md` and
`docs/realtime-transcription.md`; file material regressions (missed
first word, block cost near the 100 ms budget, sample loss, or
duplicated seams) as release blockers.
