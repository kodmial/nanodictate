# NanoDictate first-party Scoop bucket

This directory is the Windows equivalent of the project's first-party Homebrew tap.
For the simplest installation without Scoop, use the [one-command, verified
Windows installer](../scripts/install-windows.ps1):

```powershell
irm https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-windows.ps1 | iex
```

Both installation channels register user-logon startup automatically. Scoop
uses its stable `apps/nanodictate/current` junction across versions; uninstall
cleans up its own Run entry. After an update, NanoDictate automatically
restarts in background mode, without asking for configuration again.

It is maintained automatically after each successful **combined macOS and Windows**
GitHub Release. It is **not submitted** to any public Scoop, WinGet, Microsoft Store
or Chocolatey registry.

On Windows 10 22H2 or Windows 11 (x64), with Scoop installed:

```powershell
scoop bucket add nanodictate https://github.com/kodmial/nanodictate
scoop install nanodictate
# Later:
scoop update nanodictate
# To remove:
scoop uninstall nanodictate
```

The `bucket/nanodictate.json` manifest is created only after the first combined
release actually contains a complete `nanodictate-X.Y.Z-windows-x64.zip`.
Every manifest pins the **SHA-256 of the downloaded ZIP** from the published
GitHub Release. Do not guess hashes or publish a manifest referencing a
staging artifact. Scoop extracts the self-contained WinUI app and provides a
Start Menu shortcut; it does not compile Rust/.NET on the user's machine.

Windows users without Scoop can download
`nanodictate-X.Y.Z-windows-x64-setup.exe` from the same GitHub Release.
Unsigned installers may show a Windows SmartScreen reputation warning;
code signing is required to eliminate publisher-identity warnings.
