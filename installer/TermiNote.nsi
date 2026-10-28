; TermiNote installer - per-user, no administrator rights needed.
; Build with: makensis installer\TermiNote.nsi
; Expects TermiNote.exe beside this script (the release workflow copies it in).

Unicode true
RequestExecutionLevel user

!define APPNAME "TermiNote"
!define APPVERSION "0.1.0"
; AppId GUID for TermiNote (invented for this program; do not reuse elsewhere).
!define APPGUID "{7C4E1A92-3B6D-4F08-9A51-2D8E6B0C4F17}"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

Name "${APPNAME} ${APPVERSION}"
OutFile "..\TermiNote-Setup-x64.exe"
InstallDir "$LOCALAPPDATA\Programs\TermiNote"
InstallDirRegKey HKCU "Software\TermiNote" "InstallDir"
SetCompressor /SOLID lzma

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File "TermiNote.exe"
  File "..\LICENSE"

  WriteRegStr HKCU "Software\TermiNote" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${APPVERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\TermiNote.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "Sean Shaffer"
  WriteRegStr HKCU "${UNINSTKEY}" "URLInfoAbout" "https://github.com/SeanShaffer88/TermiNote"
  ; App Paths / app-id registration keyed by the GUID, for stable identity.
  WriteRegStr HKCU "Software\TermiNote" "AppId" "${APPGUID}"

  CreateDirectory "$SMPROGRAMS\TermiNote"
  CreateShortcut "$SMPROGRAMS\TermiNote\TermiNote.lnk" "$INSTDIR\TermiNote.exe"
  CreateShortcut "$SMPROGRAMS\TermiNote\Uninstall TermiNote.lnk" "$INSTDIR\Uninstall.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\TermiNote.exe"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\TermiNote\TermiNote.lnk"
  Delete "$SMPROGRAMS\TermiNote\Uninstall TermiNote.lnk"
  RMDir "$SMPROGRAMS\TermiNote"

  DeleteRegKey HKCU "${UNINSTKEY}"
  DeleteRegKey HKCU "Software\TermiNote"
  ; Note: the user's notes in %LOCALAPPDATA%\TermiNote are kept on
  ; uninstall - uninstalling a program should not delete its data.
SectionEnd
