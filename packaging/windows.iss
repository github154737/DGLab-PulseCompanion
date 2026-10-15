; Independently authored current-user installer. Requires an existing Inno Setup compiler.
#ifndef AppVersion
  #define AppVersion "0.5.0"
#endif
#ifndef BundleRoot
  #error BundleRoot must point to the verified portable Windows bundle
#endif
#ifndef ArtifactRoot
  #error ArtifactRoot is required
#endif
[Setup]
AppId=AIHapticsLab.Local
AppName=AI Haptics Lab
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\AIHapticsLab
DefaultGroupName=AI Haptics Lab
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
OutputDir={#ArtifactRoot}
OutputBaseFilename=AIHapticsLab-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\haptics_lab.exe
CloseApplications=no
RestartApplications=no
[Files]
Source: "{#BundleRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\AI Haptics Lab"; Filename: "{app}\haptics_lab.exe"
[Run]
Filename: "{app}\haptics_lab.exe"; Description: "Open AI Haptics Lab"; Flags: postinstall nowait skipifsilent unchecked
