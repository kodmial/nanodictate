# Production Windows published-release smoke

The normal [Windows host](../.github/workflows/windows.yml) CI builds the
Rust DLL, C#/WinUI product, self-contained ZIP and per-user Inno Setup EXE,
then tests a **locally built** installer, upgrades, autostart registration
and uninstall. The release pipeline builds the corresponding candidate.

[Windows published distribution smoke](../.github/workflows/windows-release-smoke.yml)
is deliberately separate: it runs on a fresh `windows-2022` GitHub-hosted VM
after a successful Release workflow (and daily or on demand). It downloads
the **already published** installer and ZIP, checks both against the release's
`SHA256SUMS.txt`, expands and checks the portable app, installs the last
published Windows version when available, upgrades using the new public EXE,
checks installed files, HKCU Run startup and exactly one persistent background
agent, then silently uninstalls and verifies per-user configuration survived.
Install and uninstall use the shared bounded runner with per-phase timeouts and
retained Inno `/LOG` files; diagnostics are uploaded even on failure. The JSON
evidence records the published installer/ZIP size, download time and
install/uninstall durations.
This catches releases whose real public assets differ from the CI-tested
build. It also verifies the current Scoop bucket's pinned URL and ZIP hash
when its version matches the release, and warns instead of failing while the
first-party manifest is briefly behind a fresh release.

The canary is not a GUI or microphone hardware test: a headless runner does
not validate the WinUI message loop, double-Alt keys, WASAPI device capture,
SmartScreen prompts or a full clean Windows 10/11 desktop session. These
need interactive qualification with genuine Windows hardware. The report
records this explicitly as `NOT_TESTED`.

It reports the actual Authenticode status of the public installer.
An unsigned installer produces a visible warning, **not** a false signed
status. To make the installer trusted for production, configure an approved
publisher identity through Microsoft Artifact Signing, a CA-issued
Authenticode certificate, or Microsoft Store distribution. Do not store
private keys in the source tree or silently accept self-signed development
certificates as production trust.

Local invocation (GitHub CLI authenticated, PowerShell 7, Windows):

```powershell
$env:GH_TOKEN = gh auth token
$env:GITHUB_REPOSITORY = 'kodmial/nanodictate'
pwsh -NoProfile -File scripts/windows-release-smoke.ps1 -Version 0.1.34
```
