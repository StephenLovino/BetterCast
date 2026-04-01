; BetterCast Windows Installer (NSIS)
; Bundles BetterCast Receiver + Virtual Display Driver (VDD)

!include "MUI2.nsh"
!include "FileFunc.nsh"

; ─── Configuration ──────────────────────────────────────────────────────────────

!define PRODUCT_NAME "BetterCast"
!define PRODUCT_PUBLISHER "BetterCast"
!define PRODUCT_WEB_SITE "https://github.com/StephenLovino/BetterCast"
!define PRODUCT_DIR_REGKEY "Software\Microsoft\Windows\CurrentVersion\App Paths\BetterCastReceiver.exe"
!define PRODUCT_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"

; Version is passed from CI via /DPRODUCT_VERSION=x.y.z
!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "1.0.0"
!endif

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "BetterCast-Setup-${PRODUCT_VERSION}.exe"
InstallDir "$PROGRAMFILES64\${PRODUCT_NAME}"
InstallDirRegKey HKLM "${PRODUCT_DIR_REGKEY}" ""
RequestExecutionLevel admin  ; Needed for driver installation
ShowInstDetails show

; ─── Modern UI Settings ─────────────────────────────────────────────────────────

!define MUI_ABORTWARNING
!define MUI_ICON "appicon.ico"
!define MUI_UNICON "appicon.ico"

; Welcome page
!insertmacro MUI_PAGE_WELCOME

; Components page (lets user choose VDD)
!insertmacro MUI_PAGE_COMPONENTS

; Directory page
!insertmacro MUI_PAGE_DIRECTORY

; Install page
!insertmacro MUI_PAGE_INSTFILES

; Finish page — offer to launch
!define MUI_FINISHPAGE_RUN "$INSTDIR\BetterCastReceiver.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch BetterCast"
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; Language
!insertmacro MUI_LANGUAGE "English"

; ─── Installer Sections ─────────────────────────────────────────────────────────

Section "BetterCast (required)" SecCore
    SectionIn RO  ; Required, cannot deselect

    SetOutPath "$INSTDIR"

    ; Main application files (populated by CI into artifact/ directory)
    File /r "artifact\*.*"

    ; Create Start Menu shortcuts
    CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\BetterCast.lnk" "$INSTDIR\BetterCastReceiver.exe"
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall.lnk" "$INSTDIR\uninstall.exe"

    ; Desktop shortcut
    CreateShortCut "$DESKTOP\BetterCast.lnk" "$INSTDIR\BetterCastReceiver.exe"

    ; Write registry keys
    WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "" "$INSTDIR\BetterCastReceiver.exe"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "UninstallString" "$INSTDIR\uninstall.exe"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayIcon" "$INSTDIR\BetterCastReceiver.exe"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoModify" 1
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoRepair" 1

    ; Calculate install size
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "EstimatedSize" $0

    ; Create uninstaller
    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Add firewall rules
    DetailPrint "Adding firewall rules..."
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="BetterCast mDNS" dir=in action=allow protocol=UDP localport=5353'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="BetterCast Streaming" dir=in action=allow protocol=TCP localport=51820'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="BetterCast App" dir=in action=allow program="$INSTDIR\BetterCastReceiver.exe"'
SectionEnd

Section "Virtual Display Driver (VDD)" SecVDD
    ; VDD enables extending your desktop with virtual monitors
    ; Files are placed by CI into vdd/ directory

    SetOutPath "$INSTDIR\VirtualDisplayDriver"

    ; Copy VDD files (/nonfatal = don't fail if no files bundled)
    File /nonfatal /r "vdd\*.*"

    ; Check if any VDD driver files were actually copied
    IfFileExists "$INSTDIR\VirtualDisplayDriver\MttVDD.inf" 0 try_generic_inf

    ; Install MttVDD driver using devcon (creates device node for IDD drivers)
    IfFileExists "$INSTDIR\VirtualDisplayDriver\devcon.exe" 0 try_pnputil
    DetailPrint "Installing VDD driver via devcon..."
    nsExec::ExecToLog '"$INSTDIR\VirtualDisplayDriver\devcon.exe" install "$INSTDIR\VirtualDisplayDriver\MttVDD.inf" Root\MttVDD'
    Pop $0
    DetailPrint "devcon exit code: $0"
    StrCmp $0 "0" vdd_done

    try_pnputil:
    ; Fallback: add driver to store via pnputil
    DetailPrint "Installing VDD driver via pnputil..."
    nsExec::ExecToLog 'pnputil /add-driver "$INSTDIR\VirtualDisplayDriver\MttVDD.inf" /install'
    Pop $0
    DetailPrint "pnputil exit code: $0"
    StrCmp $0 "0" vdd_done
    Goto vdd_manual

    try_generic_inf:
    ; Check for any other .inf files
    IfFileExists "$INSTDIR\VirtualDisplayDriver\*.inf" 0 try_exe
    FindFirst $1 $2 "$INSTDIR\VirtualDisplayDriver\*.inf"
    StrCmp $2 "" try_exe
    DetailPrint "Found driver: $2"
    IfFileExists "$INSTDIR\VirtualDisplayDriver\devcon.exe" 0 generic_pnputil
    nsExec::ExecToLog '"$INSTDIR\VirtualDisplayDriver\devcon.exe" install "$INSTDIR\VirtualDisplayDriver\$2" Root\MttVDD'
    FindClose $1
    Pop $0
    StrCmp $0 "0" vdd_done
    generic_pnputil:
    nsExec::ExecToLog 'pnputil /add-driver "$INSTDIR\VirtualDisplayDriver\$2" /install'
    Pop $0
    StrCmp $0 "0" vdd_done
    Goto vdd_manual

    try_exe:
    ; Try VDD Control exe to install driver
    IfFileExists "$INSTDIR\VirtualDisplayDriver\*.exe" 0 vdd_not_found
    DetailPrint "Running VDD installer..."
    FindFirst $1 $2 "$INSTDIR\VirtualDisplayDriver\*.exe"
    StrCmp $2 "" vdd_manual
    DetailPrint "Running: $2"
    nsExec::ExecToLog '"$INSTDIR\VirtualDisplayDriver\$2" /S'
    FindClose $1
    Goto vdd_done

    vdd_manual:
    DetailPrint "VDD driver files copied. You may need to install manually from $INSTDIR\VirtualDisplayDriver"
    Goto vdd_done

    vdd_not_found:
    DetailPrint "VDD files not bundled in this build"
    DetailPrint "Install VDD manually from github.com/itsmikethetech/Virtual-Display-Driver"
    Goto vdd_skip_registry

    vdd_done:

    ; Write VDD install path to registry for BetterCast to detect
    WriteRegStr HKLM "Software\${PRODUCT_NAME}" "VDDPath" "$INSTDIR\VirtualDisplayDriver"

    vdd_skip_registry:
SectionEnd

; ─── Section Descriptions ────────────────────────────────────────────────────────

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecCore} \
    "BetterCast receiver and sender application. Stream your screen to any device."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecVDD} \
    "Virtual Display Driver — creates virtual monitors to extend your desktop without a physical display. Required for sender mode screen extension."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ─── Uninstaller ─────────────────────────────────────────────────────────────────

Section "Uninstall"
    ; Remove firewall rules
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="BetterCast mDNS"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="BetterCast Streaming"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="BetterCast App"'

    ; Remove VDD driver (best effort)
    IfFileExists "$INSTDIR\VirtualDisplayDriver\VirtualDisplayDriver.inf" 0 skip_vdd_remove
    DetailPrint "Removing Virtual Display Driver..."
    nsExec::ExecToLog 'pnputil /delete-driver "$INSTDIR\VirtualDisplayDriver\VirtualDisplayDriver.inf" /uninstall'
    skip_vdd_remove:

    ; Remove files
    RMDir /r "$INSTDIR"

    ; Remove shortcuts
    Delete "$DESKTOP\BetterCast.lnk"
    RMDir /r "$SMPROGRAMS\${PRODUCT_NAME}"

    ; Remove registry keys
    DeleteRegKey HKLM "${PRODUCT_UNINST_KEY}"
    DeleteRegKey HKLM "${PRODUCT_DIR_REGKEY}"
    DeleteRegKey HKLM "Software\${PRODUCT_NAME}"
SectionEnd
