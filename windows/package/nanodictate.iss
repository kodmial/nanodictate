; NanoDictate per-user installer (Inno Setup 6).
;
; Initial Windows distribution vehicle for kodmial/nanodictate#195.
; MSIX is deliberately NOT shipped: genuine MakeAppx packaging, a trusted
; publisher identity with signing, and platform startup-task behavior are not
; provisioned, and the WinUI 3 entrypoint ships unpackaged with an HKCU Run
; background host. This script is the one real installer; msix-stage/ remains
; an unsigned validation-only layout and must never be presented as MSIX.
;
; Build with windows/package/build-installer.ps1, which stamps MyAppVersion
; (from Sources/NanoDictateCore/Version.swift), SourceDir (self-contained
; publish staging), and OutputDir. Never hand-edit the version here.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "publish-stage"
#endif
#ifndef OutputDir
  #define OutputDir "installer-out"
#endif

#define MyAppName "NanoDictate"
#define MyAppPublisher "Kodmial"
#define MyAppURL "https://github.com/kodmial/nanodictate"
#define MyAppExeName "NanoDictate.App.exe"
#define MyConsoleExeName "nanodictate.exe"

[Setup]
AppId={{7A3B1C9D-4E2F-4A5B-8C6D-1A2B3C4D5E01}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19045
OutputDir={#OutputDir}
OutputBaseFilename=NanoDictate-Setup-{#MyAppVersion}-x64
SetupIconFile=
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#MyAppName} {#MyAppVersion}
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} voice dictation on the shared Rust engine
VersionInfoProductName={#MyAppName}
; Per-user install: no admin rights, no machine-wide changes. Silent modes
; (/SILENT, /VERYSILENT, /NORESTART, /SUPPRESSMSGBOXES) are native Inno flags.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Start NanoDictate in the background at logon"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
; Self-contained publish output (Host + WinUI app + Rust DLL + VERSION +
; config.example.toml). The build script fails closed when any required file
; is missing, so a broken installer can never be produced silently.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autoprograms}\NanoDictate Console"; Filename: "{app}\{#MyConsoleExeName}"

[Registry]
; Autostart for the per-user packaging model: HKCU Run entry invoking the
; console host background verb. Written only when the autostart task is
; selected; removed on uninstall. User config and logs are never touched.
Root: HKCU; Subkey: "SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "NanoDictate"; ValueData: """{app}\{#MyConsoleExeName}"" run --background"; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyConsoleExeName}"; Parameters: "doctor --config ""{app}\config.example.toml"""; StatusMsg: "Running first-launch diagnostics..."; Flags: runhidden waituntilterminated; Check: WizardSilent

[UninstallRun]
; No custom actions: uninstall removes the installed files and the Run value
; above. %APPDATA%\NanoDictate (config, mic-request state) and
; %LOCALAPPDATA%\NanoDictate\Logs are deliberately preserved (see
; windows/DISTRIBUTION.md); the user deletes them explicitly.

[Code]
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
