# Windows hardware validation

Manual validation runbook for real Windows hardware plus the automated
contracts CI enforces on every change. Check off each item on the release
candidate; file deviations as follow-up issues.

## Automated contracts (CI, no hardware)

- `windows.yml` builds the Rust DLL, the portable solution, the WinUI 3
  app, and the host; runs Rust tests, xUnit tests, the smoke executable
  (deterministic + synthetic capture + transcription planning vectors),
  `doctor`, and `providers`; stages the MSIX layout and uploads the ZIP.
- xUnit asserts: failover/backoff/review/retry/overlay/mic-request gates
  match Rust; multipart shape and field gating; proxy rewrites; chunked
  stitching and final-pass policy; realtime resampling and fail-closed
  lifecycle; config parsing; capture readiness/undo/Enter semantics; the
  shared HUD fixture constants, RMS/VU vectors, all ten presentation
  scenarios, generation guards, and fail-closed review without a prompt.
- Smoke asserts: mean per-block cost stays far below the 100 ms block
  budget and prints activation-to-ready, callback cost, CPU/working-set,
  consumed-vs-emitted frames, copies per block (2), and auto-stop outcome.

## Manual hardware checklist

1. Clean install/first launch: install the signed EXE on a fresh profile.
   The PowerShell bootstrap and Scoop install launch optional settings once
   (`--settings`); their upgrades resume silently (`--background`). The
   interactive EXE installer offers an optional post-install settings launch
   (`--settings`) after a fresh install or an upgrade. Logon startup always
   stays quiet and never opens settings. `%APPDATA%\NanoDictate\config.toml`
   is created from the example without touching an existing config. The Start
   Menu shortcut (`--settings`) opens settings on request.
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
12. Restart/startup: enable startup → reboot → dictation hotkey works with
    no visible window; a second launch opens optional settings only while
    idle and never creates a second hook.
13. HUD phases: fast start skips `Starting`; a slow start shows it only
    after the grace window; the timer starts on the first valid buffer;
    stop shows Processing with three dots and insert/empty/cancel hide
    within 0.8 s, errors/microphone failure within 2 s.
14. HUD placement/style: the panel appears above the UIA text caret when
    the focused editor exposes TextPattern (native caret/pointer/screen
    center fallback), is clamped on secondary/DPI-scaled monitors, respects
    light/dark/high-contrast colors and Reduce Motion, stays topmost, takes
    no focus, is click-through, and never appears in the taskbar or Alt-Tab.
15. HUD robustness: Escape during Processing hides the panel immediately
    even while Rust is still settling; a rapid restart keeps the new
    generation visible; a stale hide or late callback cannot dismiss it.
16. Review prompt: enabled review shows the transient window; missing or
    failed UI inserts nothing (fail-closed); a second launch while
    recording/transcribing does not open settings or steal focus.

## Measurement comparison

Record per session: activation-to-ready (trigger→request,
request→engine-started, engine-started→first-buffer), mean/max block
callback cost, CPU time, working set, device frames vs engine samples,
and auto-stop outcome (the smoke line prints the same fields). Compare
against the macOS contracts in `docs/stt-benchmark.md` and
`docs/realtime-transcription.md`; file material regressions (missed
first word, block cost near the 100 ms budget, sample loss, or
duplicated seams) as release blockers.
