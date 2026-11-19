; Build with: ISCC.exe /DAppVersion=<version> installer\TermiNote.iss
; The release workflow stages the Tauri executable in payload\ and emits
; TermiNote-Setup-x64.exe beside this script.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

; Keep the original installer ID so upgrades preserve the user's install.
#define AppGuid "{7C4E1A92-3B6D-4F08-9A51-2D8E6B0C4F17}"

[Setup]
AppId={{#AppGuid}
AppName=TermiNote
AppVersion={#AppVersion}
AppPublisher=Sean Shaffer
AppPublisherURL=https://github.com/SeanShaffer88/TermiNote
DefaultDirName={localappdata}\Programs\TermiNote
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..
OutputBaseFilename=TermiNote-Setup-x64
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\TermiNote.exe
WizardStyle=modern

[Files]
Source: "payload\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\TermiNote"; Filename: "{app}\TermiNote.exe"
Name: "{group}\Uninstall TermiNote"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Software\TermiNote"; ValueType: string; ValueName: "InstallDir"; ValueData: "{app}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\TermiNote"; ValueType: string; ValueName: "AppId"; ValueData: "{{#AppGuid}"; Flags: uninsdeletekey

[Run]
Filename: "{app}\TermiNote.exe"; Description: "Open TermiNote"; Flags: nowait postinstall skipifsilent

[Code]
var
  WasRunning: Boolean;

function TermiNoteRunning(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('powershell.exe',
    '-NoProfile -NonInteractive -Command "if (Get-Process -Name TermiNote -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Attempts: Integer;
begin
  Result := '';
  WasRunning := TermiNoteRunning();
  Attempts := 0;
  while WasRunning and TermiNoteRunning() and (Attempts < 40) do
  begin
    Sleep(500);
    Attempts := Attempts + 1;
  end;
  if TermiNoteRunning() then
    Result := 'TermiNote is still running. Close it before installing the update.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep = ssPostInstall) and WizardSilent and WasRunning then
    Exec(ExpandConstant('{app}\TermiNote.exe'), '', '', SW_SHOW, ewNoWait, ResultCode);
end;
