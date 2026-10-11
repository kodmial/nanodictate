# Windows distribution (installer, update, uninstall, supported versions)

Supported release vehicle for NanoDictate on Windows.

## Supported versions

- Windows 10 22H2 (build 19045) x64 or Windows 11 x64.
- .NET 8 runtime (self-contained in the MSIX; the portable ZIP needs the
  .NET 8 desktop runtime).
- Microphone: any WASAPI shared-mode capture endpoint (Float32 mix format).
- ARM64 is not packaged; x64 emulation is unsupported.

## Artifacts

`windows/package/make-msix.ps1` produces, reproducibly from a clean
checkout plus tag version:

- `nanodictate-windows-x64-<version>.zip` — portable layout (WinUI app +
  `nanodictate_core.dll` + `config.example.toml`).
- `msix-stage/` — MSIX file layout with `AppxManifest.xml` stamped with
  the release version (`<major>.<minor>.<patch>.0`).

Release CI (`windows.yml` packaging job, then `release.yml`) uploads the
ZIP as the Windows release asset and prepares the signed MSIX with the
configured certificate. Signing itself runs only in release CI, never on
developer machines.

## Clean install / first launch

1. Install the signed MSIX (or unzip the portable ZIP for evaluation).
2. Launch NanoDictate; on first launch the host copies
   `config.example.toml` to `%APPDATA%\NanoDictate\config.toml` when no
   config exists (never overwrites an existing user config).
3. Grant microphone access when Windows prompts; if access was denied,
   the host shows the `ms-settings:privacy-microphone` guidance and
   throttles repeat prompts through the Rust cooldown.
4. Double-Alt starts dictation; the start cue fires on the first valid
   engine block, never on start alone.

## Update

- MSIX installs update in place through the platform installer (version
  check only; user config under `%APPDATA%\NanoDictate` and logs under
  `%LOCALAPPDATA%\NanoDictate\Logs` are preserved).
- Portable ZIP updates: stop the running instance, replace the folder,
  restart. Config and logs live outside the folder and survive.

## Uninstall

1. Remove the package via Settings → Apps (MSIX) or delete the portable
   folder (ZIP).
2. Optionally disable startup first (`nanodictate run` tray menu or
   `StartupManager.Disable`, which removes the HKCU Run value).
3. Optionally delete `%APPDATA%\NanoDictate` (config, mic-request state)
   and `%LOCALAPPDATA%\NanoDictate\Logs`. Uninstall never deletes them
   silently.

## Reproducibility

- The Rust engine is pinned by `rust/Cargo.lock`; the .NET graph is
  pinned by the committed package versions.
- The script fails loudly when `nanodictate_core.dll` is missing or any
  `dotnet build` fails; the manifest version is stamped deterministically
  from the release tag.
