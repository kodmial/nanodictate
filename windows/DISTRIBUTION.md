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

## Installation (Windows)

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

Alternatively, download the versioned
`nanodictate-X.Y.Z-windows-x64-setup.exe` from the GitHub Release and run it.
The Inno Setup installer installs per-user (no administrator privileges or
.NET SDK required). To update a direct installation, run a newer EXE installer.
Inno supports quiet `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` install
and uninstall operations. Keep one installation channel per user instead
of mixing Scoop and the classic EXE installer.

Windows application configuration is under
`%APPDATA%\NanoDictate\config.toml`; logs are under
`%LOCALAPPDATA%\NanoDictate\Logs`. Updates and uninstall deliberately
do not remove personal configuration or logs.

**Code signing:** a generated EXE is not automatically Authenticode-signed.
Without an organization certificate and trusted signing configuration Windows
SmartScreen can warn about the installer/app. CI must never call an unsigned
installer signed. Hardware microphone privacy, Double-Alt global hooks, text
insertion and startup on real Windows 10 and 11 still require explicit manual
functional qualification in addition to headless Actions runners.

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
