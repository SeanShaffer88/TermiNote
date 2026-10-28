; TermiNote installer - per-user, no administrator rights needed.
; Build with: makensis installer\TermiNote.nsi
; Expects the Flutter Windows build output staged in a "payload" folder
; beside this script (TermiNote.exe, flutter_windows.dll, data\ folder -
; i.e. the contents of build\windows\x64\runner\Release). The release
; workflow stages it; see .github\workflows\release.yml.

Unicode true
RequestExecutionLevel user

!define APPNAME "TermiNote"
!define APPVERSION "0.2.0"
; AppId GUID for TermiNote (same GUID as the 0.1.x installer; do not reuse
; elsewhere and do not change it, or upgrades stop being upgrades).
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
  File /r "payload\*.*"

  WriteRegStr HKCU "Software\TermiNote" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${APPVERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\TermiNote.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "Sean Shaffer"
  WriteRegStr HKCU "${UNINSTKEY}" "URLInfoAbout" "https://github.com/SeanShaffer88/TermiNote"
  WriteRegStr HKCU "Software\TermiNote" "AppId" "${APPGUID}"

  CreateDirectory "$SMPROGRAMS\TermiNote"
  CreateShortcut "$SMPROGRAMS\TermiNote\TermiNote.lnk" "$INSTDIR\TermiNote.exe"
  CreateShortcut "$SMPROGRAMS\TermiNote\Uninstall TermiNote.lnk" "$INSTDIR\Uninstall.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  ; Remove the installed payload (program files only). The Flutter build
  ; ships a data folder and DLLs next to the exe, so clear them all.
  Delete "$INSTDIR\TermiNote.exe"
  Delete "$INSTDIR\flutter_windows.dll"
  Delete "$INSTDIR\LICENSE"
  RMDir /r "$INSTDIR\data"
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
