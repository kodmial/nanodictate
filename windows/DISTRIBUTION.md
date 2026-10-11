# Windows distribution (installer, update, uninstall, supported versions)

Supported release vehicle for NanoDictate on Windows.

## Supported versions

- Windows 10 22H2 (build 19045) x64 or Windows 11 x64.
- No Rust toolchain, .NET SDK, PowerShell 7, or Visual Studio is required on
  the target machine. The installer ships a self-contained publish: the
  console host carries the .NET 8 runtime and the WinUI 3 entrypoint carries
  the Windows App SDK runtime (self-contained), plus the shared production
  Rust engine `nanodictate_core.dll`.
- Microphone: any WASAPI shared-mode capture endpoint (Float32 mix format).
- ARM64 is not packaged; x64 emulation is unsupported.

## Implemented (this release)

- **One real installer**: per-user Inno Setup EXE,
  `NanoDictate-Setup-<version>-x64.exe`, built by
  `windows/package/build-installer.ps1` from `windows/package/nanodictate.iss`.
  Default location `%LOCALAPPDATA%\Programs\NanoDictate`, no admin rights.
  The installer stages the self-contained host (`nanodictate.exe`), the
  WinUI 3 app (`NanoDictate.App.exe`), `nanodictate_core.dll`,
  `config.example.toml`, and a `VERSION` stamp (from
  `Sources/NanoDictateCore/Version.swift`, the single source shared with
  macOS). Every required file is verified before compilation; a missing
  DLL, executable, resource, or version mismatch fails the build instead of
  shipping a broken installer.
- **Same-release publishing**: `windows-release.yml` (tags `v*`, published
  releases, manual dispatch) rebuilds the installer for the release version,
  reruns the full install/upgrade/uninstall gate, and attaches
  `NanoDictate-Setup-<version>-x64.exe` plus its `.sha256` sidecar to the
  same GitHub Release as the macOS assets. Existing bytes are never
  overwritten (`--clobber` is forbidden); a missing asset after upload fails
  the job. The Windows hashes live in the per-installer `.sha256` sidecar,
  not in the macOS `SHA256SUMS.txt`, so macOS manifest guards are unaffected.
- **Install, upgrade, uninstall**: `windows/package/test-installer.ps1`
  proves `install -> version -> upgrade -> uninstall` on a clean Windows
  runner for every PR and every release: silent install, `nanodictate
  version` read-back, `doctor` and `providers` from the installed location,
  user-data markers, versioned reinstall preserving
  `%APPDATA%\NanoDictate` (config, mic-request state) and
  `%LOCALAPPDATA%\NanoDictate\Logs`, silent uninstall removing program
  files with no orphaned executables while preserving user data. Logs are
  uploaded as `nanodictate-windows-install-test-logs`.
- **Silent flags** (native Inno): `/SILENT`, `/VERYSILENT`, `/NORESTART`,
  `/SUPPRESSMSGBOXES`, `/DIR="..."`, `/LOG="..."`. Example:
  `NanoDictate-Setup-0.1.32-x64.exe /VERYSILENT /NORESTART /SUPPRESSMSGBOXES`.
- **Autostart lifecycle** (per-user model): the installer offers an
  `autostart` task that writes
  `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\NanoDictate` =
  `"<install>\nanodictate.exe" run --background`. The in-app
  `StartupManager` (Run key plus tray) owns runtime enable/disable; the
  installer only seeds or removes its own value on install/uninstall and
  never deletes user config or logs.
- **Direct download path** (official until WinGet is indexed): the GitHub
  Release page for the version, asset
  `NanoDictate-Setup-<version>-x64.exe`; verify with the adjacent `.sha256`
  file before running.

## Pending (explicitly NOT claimed)

- **Signed production installer**: pending credential provisioning. Stable
  releases pass `-RequireSigned` and use `WINDOWS_SIGN_PFX_B64` +
  `WINDOWS_SIGN_PASSWORD` (optional `WINDOWS_SIGN_TIMESTAMP_URL`) with
  `signtool.exe` from the Windows SDK; the certificate's publisher identity
  becomes the installer identity. No pretend trusted or self-signed
  production certificate is ever generated. Until the secrets are configured
  and a signed release is verified, PR artifacts are unsigned validation
  builds and must never be presented as signed releases. Provisioning: upload
  a code-signing PFX (base64) as `WINDOWS_SIGN_PFX_B64` and its password as
  `WINDOWS_SIGN_PASSWORD` in the repository secrets, then rerun a tag build.
- **MSIX**: not shipped. Genuine `MakeAppx` packaging, a trusted publisher
  identity with signing, and platform install/update/uninstall plus startup
  task behavior were not provisioned, and the unpackaged WinUI 3 entrypoint
  with HKCU Run startup does not map onto the MSIX container without
  rework. `windows/artifacts/msix-stage/` and the portable ZIP remain
  unsigned validation-only layouts; they are not installers and must never
  be labeled as MSIX.
- **WinGet**: manifests are prepared and validated by
  `scripts/make_winget_manifests.py` (identifier `Kodmial.NanoDictate`,
  tentative until approved; Inno silent switches `/SILENT`; version and
  SHA-256 from the published release) and `winget-submit.yml` uploads them
  as artifacts on every published release. Upstream submission to
  `microsoft/winget-pkgs` needs the `WINGET_PAT` secret and human review;
  without it only the manifests artifact plus manual PR steps are produced.
  Desired commands after acceptance:
  `winget install --id Kodmial.NanoDictate -e`,
  `winget upgrade --id Kodmial.NanoDictate -e`,
  `winget uninstall --id Kodmial.NanoDictate -e`.
  Until the catalogue PR merges, `winget install` is NOT available; use the
  direct GitHub Release download above.
- **Scoop/Chocolatey**: explicitly deferred.

## Clean install / first launch

1. Download `NanoDictate-Setup-<version>-x64.exe` from the GitHub Release
   for the version and verify the hash:
   `certutil -hashfile NanoDictate-Setup-<version>-x64.exe SHA256`
   against the `.sha256` sidecar.
2. Run the installer (double-click, or silent flags above). No SDKs needed.
3. Launch NanoDictate; on first launch the WinUI app copies its bundled
   `config.example.toml` (beside the executable) to
   `%APPDATA%\NanoDictate\config.toml` when no config exists (never
   overwrites an existing user config). The console host (`run`, `doctor`,
   `providers`, `transcribe-file`, `version`) does not copy: it uses
   `--config PATH` when given, otherwise `%APPDATA%\NanoDictate\config.toml`
   when present, otherwise `config.example.toml` from the install folder.
4. Grant microphone access when Windows prompts; if access was denied, the
   host shows the `ms-settings:privacy-microphone` guidance and throttles
   repeat prompts through the Rust cooldown.
5. Double-Alt starts dictation; the start cue fires on the first valid
   engine block, never on start alone. `nanodictate version` prints the
   installed product version and engine ABI for support.

## Update

- Run the newer `NanoDictate-Setup-<new-version>-x64.exe` (or silent
  reinstall); the installer upgrades in place (`uninstallPrevious` in the
  WinGet manifest). User config under `%APPDATA%\NanoDictate` and logs
  under `%LOCALAPPDATA%\NanoDictate\Logs` are preserved; the installer
  never overwrites `config.toml` and uninstall never deletes these folders.
- Portable ZIP updates (validation only): stop the running instance,
  replace the folder, restart. Config and logs live outside the folder and
  survive.

## Uninstall

1. Remove via Settings → Apps, Control Panel, or the installed
   `unins000.exe /VERYSILENT /NORESTART` (the installer removes its own
   HKCU Run value).
2. Optionally disable startup first (`nanodictate run` tray menu or
   `StartupManager.Disable`, which removes the HKCU Run value).
3. Optionally delete `%APPDATA%\NanoDictate` (config, mic-request state)
   and `%LOCALAPPDATA%\NanoDictate\Logs`. Uninstall never deletes them
   silently.

## Reproducibility

- The Rust engine is pinned by `rust/Cargo.lock`; the .NET graph is pinned
  by the committed package versions.
- `build-installer.ps1` fails loudly when `nanodictate_core.dll`, the
  self-contained host, the WinUI x64 executable, or any staged resource is
  missing; the installer and `VERSION` stamp derive deterministically from
  the release version, and the `.sha256` sidecar records the exact shipped
  bytes.
