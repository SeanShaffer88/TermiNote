; TermiNote installer - Inno Setup, per-user, no administrator rights.
; Build with: ISCC.exe /DAppVersion=<version> installer\TermiNote.iss
; Expects the Flutter Windows build output staged in a "payload" folder
; beside this script (TermiNote.exe, flutter_windows.dll, data\ folder -
; i.e. the contents of build\windows\x64\runner\Release). The release
; workflow stages it; see .github\workflows\release.yml.
;
; Silent auto-update (the MuseDesktop pattern, ported): the app checks
; for a newer release at launch, downloads this installer, and runs it
; with /VERYSILENT after saving its work and exiting. PrepareToInstall
; below waits for the running program to be gone before any file is
; copied, remembers that it was running, and reopens it afterwards -
; so an update lands with no clicks and the program comes back on its
; own. A hand-run install behaves like a normal installer.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

; AppId GUID for TermiNote (the same GUID the earlier installers used;
; do not change it, or upgrades stop being upgrades).
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
OutputDir=..
OutputBaseFilename=TermiNote-Setup-x64
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
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

{ True while a TermiNote process is alive. Name lookup is done through
  PowerShell's process list, which is the detection that actually
  fires (the lesson the MuseDesktop installer recorded). }
function TermiNoteRunning(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec('powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -Command "if (Get-Process -Name TermiNote -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

{ Before any file is copied: note whether the program was running
  (so it can be reopened after a silent update), then wait for it to
  be gone. For an auto-update the program exits by itself once it has
  launched this installer; for a hand-run install over a running copy,
  CloseApplications (Restart Manager) asks it to close. Either way,
  files are never swapped under a live process. }
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
end;

{ After a silent install that replaced a running copy, reopen the
  program so the update feels like nothing happened. Interactive
  installs get the finish-page Run entry instead ([Run], skipped when
  silent). }
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep = ssPostInstall) and WizardSilent and WasRunning then
    Exec(ExpandConstant('{app}\TermiNote.exe'), '', '', SW_SHOW,
      ewNoWait, ResultCode);
end;
