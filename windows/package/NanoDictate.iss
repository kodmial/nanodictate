#define AppVersion GetEnv("ND_RELEASE_VERSION")
#define PublishDir GetEnv("ND_PUBLISH_DIR")
#define OutputDir GetEnv("ND_OUTPUT_DIR")
#if AppVersion == ""
  #error "ND_RELEASE_VERSION must be set by make-release.ps1"
#endif
#if PublishDir == ""
  #error "ND_PUBLISH_DIR must be set by make-release.ps1"
#endif
#if OutputDir == ""
  #error "ND_OUTPUT_DIR must be set by make-release.ps1"
#endif

[Setup]
AppId=NanoDictate
AppName=NanoDictate
AppVersion={#AppVersion}
AppPublisher=NanoDictate
DefaultDirName={localappdata}\Programs\NanoDictate
DefaultGroupName=NanoDictate
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\NanoDictate.App.exe
OutputDir={#OutputDir}
OutputBaseFilename=nanodictate-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
DisableWelcomePage=yes
LicenseFile=

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\NanoDictate"; Filename: "{app}\NanoDictate.App.exe"
Name: "{autoprograms}\NanoDictate"; Filename: "{app}\NanoDictate.App.exe"

[Run]
Filename: "{app}\NanoDictate.App.exe"; Description: "Launch NanoDictate"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; User configuration and logs deliberately survive upgrades and uninstall.
