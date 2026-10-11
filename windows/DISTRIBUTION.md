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

Release CI (the `windows.yml` packaging job) uploads the portable ZIP
and the unsigned MSIX staging layout as a GitHub Actions artifact for
validation only. This change does not implement store signing, MSIX
signing in `release.yml`, or tag-triggered releases: the manifest
version is stamped from the `-Version` passed to `make-msix.ps1`. In CI
the version comes from `github.ref_name` with no tag trigger, so branch
and pull-request refs fall back to `0.0.0`; only refs starting with
`<major>.<minor>.<patch>` produce a stamped version (a leading `v`
falls back to `0.0.0`, and any `-suffix` is stripped).

## Clean install / first launch

1. Unzip the portable ZIP for evaluation (`nanodictate-windows-x64-<version>.zip`).
   `msix-stage/` is an unsigned staging layout for validation only: MSIX
   installation requires separate package creation (`MakeAppx`) and signing
   steps that this change does not implement.
2. Launch NanoDictate; on first launch the WinUI app copies its bundled
   `config.example.toml` (beside the executable, also staged at the
   package root) to `%APPDATA%\NanoDictate\config.toml` when no
   config exists (never overwrites an existing user config). The console
   host (`run`, `doctor`, `providers`, `transcribe-file`) does not copy:
   it uses `--config PATH` when given, otherwise
   `%APPDATA%\NanoDictate\config.toml` when present, otherwise
   `config.example.toml` from the working directory.
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
