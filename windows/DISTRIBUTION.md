# Windows distribution and synchronized multi-platform releases

## Decision

NanoDictate uses GitHub Releases as the authoritative binary archive and release
version source for **both macOS and Windows**. Homebrew is served from the
first-party `kodmial/homebrew-nanodictate` tap; Windows is served from the
first-party Scoop bucket in `bucket/nanodictate.json` of this same repository.
No WinGet, Microsoft Store, public Scoop registry or Chocolatey submission.

**Windows target:** Windows 10 22H2 (build 19045), Windows 11, x64. Native
ARM64 builds and physical hardware parity checks are not yet demonstrated.
The Windows executable uses the shared production Rust core, WinUI 3 and
Windows App SDK, published as an **unpackaged self-contained x64 app**.

## Preferred install: the published EXE

Ordinary users download the versioned
`nanodictate-X.Y.Z-windows-x64-setup.exe` from the latest stable
[GitHub Release](https://github.com/kodmial/nanodictate/releases) and run it.
The Inno Setup installer installs per user, requires no administrator rights,
.NET SDK, Rust/Visual Studio tooling or Scoop, registers logon startup and
starts one background agent. It does not force a settings window.

To update a direct installation, run a newer EXE installer; Inno upgrades the
same `%LOCALAPPDATA%\Programs\NanoDictate` installation in place. Quiet
install and uninstall use `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`.
Keep one installation channel per user instead of mixing Scoop and the classic
EXE installer.

Windows application configuration is under
`%APPDATA%\NanoDictate\config.toml`; logs are under
`%LOCALAPPDATA%\NanoDictate\Logs`. A missing config is copied once from the
bundled `config.example.toml`; the default provider is keyless Airubiz.
Existing configuration is never replaced by an install, upgrade or uninstall.

## Alternative one-command install and update (no Scoop prerequisite)

In a **regular non-admin PowerShell window**, run:

```powershell
irm https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-windows.ps1 | iex
```

The bootstrap considers both the first-party Scoop manifest version and the
latest stable GitHub Release, so a temporarily stale bucket cannot pin users
to an older build. It selects only a release whose EXE asset and matching
`SHA256SUMS.txt` entry both exist, downloads that EXE, verifies its SHA-256,
silently installs it per user, repairs the persistent
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry and starts one
background agent. The same command upgrades the installation in place without
overwriting configuration. A release that is still uploading is skipped until
its assets and checksums are complete.

`install-windows.ps1 -VerifyOnly` downloads and verifies the selected release
without installing it; use it to audit the manifest -> release asset ->
checksum chain. SHA-256 proves that the file matches the published release; it
does **not** prove publisher identity (see code signing below).

NanoDictate starts with Windows at **interactive user logon** (not before the
user signs in). Logon startup, the EXE installer, PowerShell and Scoop all pass
`--background`: the WinUI message loop, global Double-Alt hook and STT engine
run with no visible window. The Start Menu shortcut passes `--settings`, and a
second launch while dictation is idle opens optional settings on demand; a
second launch during an active session does not steal focus or interrupt it.
Closing settings leaves dictation running; use its Quit button to stop the
background process intentionally. There is no mandatory first-run wizard, and
a fresh profile needs no provider setup because the bundled keyless default is
usable immediately.

For ordinary unpackaged desktop applications Windows manages microphone
access via the OS-wide desktop-app microphone toggle; there is no dedicated
per-app dialog that NanoDictate may reliably force. If microphone access is
disabled in Windows privacy settings or by an organization, the user must
permit it in Windows. Install/upgrade logic does not modify those settings.
Windows App SDK self-contained deployment and persistent config do not imply
or simulate a remembered permission grant.

## Optional Scoop channel

With Scoop already installed, two commands:

```powershell
scoop bucket add nanodictate https://github.com/kodmial/nanodictate
scoop install nanodictate
```

To update or uninstall:

```powershell
scoop update nanodictate
scoop uninstall nanodictate
```

Scoop uses its stable `apps/nanodictate/current` path, registers the same
per-user Run entry, starts the fresh install and updates in the background,
and removes its own startup entry on uninstall. The bucket intentionally pins
a single published ZIP; after a release it can lag briefly behind the GitHub
Release, which is why the PowerShell bootstrap also checks the latest release
before choosing an asset.

**Code signing:** a generated EXE is not automatically Authenticode-signed.
Without an organization certificate and trusted signing configuration Windows
SmartScreen can warn about the installer/app. CI must never call an unsigned
installer signed. SHA-256 from `SHA256SUMS.txt` proves that the downloaded bytes
match the GitHub release, **not** who published them. WinGet and a signed MSIX
are not available release channels.

## Verification and measurements

Headless CI verifies exact candidate and published bytes, the ZIP/EXE payload
(`NanoDictate.App.exe`, `NanoDictate.App.dll`, the Rust DLL, self-contained
`coreclr.dll`/`hostfxr.dll` and `config.example.toml`), install, same-version
reinstall, a versioned upgrade, startup registration, config preservation and
uninstall. The candidate smoke reports the actual installer/ZIP size and
install/reinstall/uninstall durations to the workflow summary and a
`windows-candidate-measurements.json` artifact; it does not assert unsupported
performance targets or claim that a hosted runner proved interactive UI.

Real microphone privacy prompts, Double-Alt keyboard hooks, HUD placement and
caret focus, Russian/emoji insertion and Windows 10 versus Windows 11 desktop
behavior still require an interactive hardware session. Their status is listed
in [VALIDATION.md](VALIDATION.md); treat them as outstanding until a genuine
desktop run is recorded.

## Combined release contract

The main `Release` pipeline computes a single version and waits for:

1. Existing exact-source macOS candidate tests and packaging smoke for
   arm64 and Intel.
2. A successful Windows x64 native build and actual self-contained publish.
3. A ZIP and real EXE setup generated from the same Windows publish directory.

It then publishes one GitHub Release with the macOS tarballs and ZIPs,
Windows ZIP and EXE, and one SHA256SUMS.txt listing **all binaries**. The
release cannot publish if Windows package creation fails or Windows
assets are missing. The Windows artifact is not `msix-stage` and no
unsigned directory is described as an MSIX installer.

After publication the Scoop manifest generator **downloads the published
Windows ZIP and EXE**, verifies them against the release SHA256SUMS.txt,
generates a hash-pinned Scoop manifest and writes it to `main`, without
creating a PR. The existing macOS tap sync continues separately.
A Scoop manifest must never reference a missing or unfinished release.

## Windows CI coverage

`.github/workflows/windows.yml` runs Rust core tests, C# unit and ABI
tests, WinUI compilation, diagnostics, and tests of the actual release
packaging plus silent EXE installation/reinstallation/uninstallation and
config preservation on a Windows runner. A hosted Windows runner does
**not** prove microphone and keyboard-hook operation on physical Windows
10/11 hardware, interactive UI or compatibility with every STT provider.
Do not mark these unobserved hardware tests as passed.

Build a Windows package locally on a developer machine with Rust MSVC,
.NET 8 SDK, Visual Studio Build Tools with WinUI support, PowerShell 7,
and Inno Setup 6:

```powershell
pwsh windows/package/make-release.ps1 -Version 0.1.33 -OutDir windows/artifacts
```

The version above illustrates the command syntax; it is not a claim that
v0.1.33 has been published.


## Post-publication Windows distribution smoke

The separate **Windows distribution smoke** workflow runs on two fresh
`windows-latest` runners after every successful Release, nightly, and when
its scripts change. The Inno Setup leg downloads the *public* Windows EXE and
ZIP, compares both to the release SHA256SUMS.txt, inspects the self-contained
payload, silently installs/reinstalls/uninstalls the EXE, verifies per-user
logon startup and config preservation. The Scoop leg verifies the manifest's
version, pinned SHA256 and public URL, then uses **real Scoop** to add the
first-party bucket, install and uninstall the published ZIP, checking the same
product layout and registry ownership. A bounded 20x20s poll handles the
publisher-to-bucket sync race and fails if it never converges.

The canary does **not** make microphone, interactive GUI, dictation, hotkey,
SmartScreen reputation, or real Windows 10/11 hardware claims. Authenticode
is checked on downloaded installer and application EXE, with an explicit
**UNVERIFIED** report when absent; a passed installation smoke never claims
signing. Enable trusted publisher signing (Azure Artifact Signing or a
publicly trusted code-signing certificate) separately and require
signature-valid artifacts before claiming a signed Windows release. The
experimental MSIX staging scripts are not a signed Store channel.
SHA256SUMS alone proves file consistency with the GitHub release, **not**
publisher authenticity.
