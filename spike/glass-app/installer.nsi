; BetterCast — Windows installer (NSIS)
;
; Modelled on Sources/BetterCastReceiverDesktop/installer.nsi, which has already
; been through the mistakes: devcon adding a device node per run, an uninstaller
; testing for a filename the driver package never shipped, and driver packages
; deleted while nodes still referenced them. The VDD handling below is that
; script's, kept in step with it deliberately.
;
; Everything the user sees says BetterCast, because that is the name of the app.
;
; It installs into the same C:\Program Files\BetterCast as the older Qt build,
; deliberately: the display driver lives there, the app already looks for it
; there, and one machine should not carry two copies of a kernel driver. The
; consequence is that uninstalling removes that folder, and an older Qt build
; sitting in it goes too.
;
; The registry key and the firewall rule names below still carry "Glass". They
; are never shown as a product name — they exist so that installing or removing
; this does not overwrite the older build's Add/Remove entry or delete firewall
; rules it still needs.

!include "MUI2.nsh"
!include "FileFunc.nsh"

; ─── Configuration ──────────────────────────────────────────────────────────────

!define PRODUCT_NAME "BetterCast"
!define PRODUCT_EXE "BetterCast.exe"
!define PRODUCT_PUBLISHER "BetterCast"
!define PRODUCT_WEB_SITE "https://github.com/StephenLovino/BetterCast"
!define PRODUCT_DIR_REGKEY "Software\Microsoft\Windows\CurrentVersion\App Paths\${PRODUCT_EXE}"
!define PRODUCT_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\BetterCastGlass"

; Version is passed from CI via /DPRODUCT_VERSION=x.y.z
!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "1.0.0"
!endif

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "BetterCast-Setup-${PRODUCT_VERSION}.exe"
InstallDir "$PROGRAMFILES64\BetterCast"
InstallDirRegKey HKLM "${PRODUCT_DIR_REGKEY}" ""
RequestExecutionLevel admin  ; the display driver needs it
ShowInstDetails show

; ─── Modern UI ──────────────────────────────────────────────────────────────────

!define MUI_ABORTWARNING
!define MUI_ICON "appicon.ico"
!define MUI_UNICON "appicon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Launch BetterCast"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ─── Install ────────────────────────────────────────────────────────────────────

Section "BetterCast (required)" SecCore
    SectionIn RO

    SetOutPath "$INSTDIR"

    ; Everything CI collected: the exe, the Qt runtime, FFmpeg, the fonts and
    ; the logo the welcome splash draws.
    File /r "artifact\*.*"

    CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\BetterCast.lnk" "$INSTDIR\${PRODUCT_EXE}"
    CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall.lnk" "$INSTDIR\uninstall.exe"
    CreateShortCut "$DESKTOP\BetterCast.lnk" "$INSTDIR\${PRODUCT_EXE}"

    WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "" "$INSTDIR\${PRODUCT_EXE}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "UninstallString" "$INSTDIR\uninstall.exe"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayIcon" "$INSTDIR\${PRODUCT_EXE}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
    WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoModify" 1
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoRepair" 1

    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "EstimatedSize" $0

    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Rule names carry "Glass" so that uninstalling this does not delete the
    ; rules the older Qt build installed under the plain names, and vice versa.
    ; Not a product name - nobody reads these outside the firewall list.
    DetailPrint "Adding firewall rules..."
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="BetterCast Glass mDNS" dir=in action=allow protocol=UDP localport=5353'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="BetterCast Glass Streaming" dir=in action=allow protocol=TCP localport=51820'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="BetterCast Glass App" dir=in action=allow program="$INSTDIR\${PRODUCT_EXE}"'
SectionEnd

Section "Virtual Display Driver (VDD)" SecVDD
    SetOutPath "$INSTDIR\VirtualDisplayDriver"

    File /nonfatal /r "vdd\*.*"
    File "vdd-cleanup.ps1"

    ; Disconnected nodes left by earlier installs and by uninstallers that could
    ; not remove them. Present, working nodes are left for "devcon update".
    ; Sysnative, because this installer is 32-bit and pnputil is not in SysWOW64.
    DetailPrint "Removing disconnected virtual displays left by earlier installs..."
    nsExec::ExecToLog '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\VirtualDisplayDriver\vdd-cleanup.ps1" -DisconnectedOnly'
    Pop $0
    DetailPrint "Leftover cleanup exit code: $0"

    IfFileExists "$INSTDIR\VirtualDisplayDriver\MttVDD.inf" 0 try_generic_inf
    IfFileExists "$INSTDIR\VirtualDisplayDriver\devcon.exe" 0 try_pnputil

    ; "devcon install" always creates a new root-enumerated node — it never checks
    ; for an existing one, so running the installer N times leaves N virtual
    ; monitors. "devcon update" targets what is already there, so it goes first.
    DetailPrint "Updating any existing VDD device node..."
    nsExec::ExecToLog '"$INSTDIR\VirtualDisplayDriver\devcon.exe" update "$INSTDIR\VirtualDisplayDriver\MttVDD.inf" Root\MttVDD'
    Pop $0
    DetailPrint "devcon update exit code: $0"
    StrCmp $0 "0" vdd_done
    StrCmp $0 "1" vdd_done

    DetailPrint "No existing device node — installing VDD driver via devcon..."
    nsExec::ExecToLog '"$INSTDIR\VirtualDisplayDriver\devcon.exe" install "$INSTDIR\VirtualDisplayDriver\MttVDD.inf" Root\MttVDD'
    Pop $0
    DetailPrint "devcon exit code: $0"
    StrCmp $0 "0" vdd_done

    try_pnputil:
    DetailPrint "Installing VDD driver via pnputil..."
    nsExec::ExecToLog '"$WINDIR\Sysnative\pnputil.exe" /add-driver "$INSTDIR\VirtualDisplayDriver\MttVDD.inf" /install'
    Pop $0
    DetailPrint "pnputil exit code: $0"
    StrCmp $0 "0" vdd_done
    Goto vdd_manual

    try_generic_inf:
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
    nsExec::ExecToLog '"$WINDIR\Sysnative\pnputil.exe" /add-driver "$INSTDIR\VirtualDisplayDriver\$2" /install'
    Pop $0
    StrCmp $0 "0" vdd_done
    Goto vdd_manual

    try_exe:
    IfFileExists "$INSTDIR\VirtualDisplayDriver\*.exe" 0 vdd_not_found
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
    DetailPrint "Install VDD manually from github.com/VirtualDrivers/Virtual-Display-Driver"
    Goto vdd_skip_registry

    vdd_done:
    ; Software\BetterCast, not Software\BetterCastGlass. This is not a product
    ; identity - it is the value VirtualDisplayVDD.cpp reads as Method 0 of its
    ; driver detection, and it looks under Software\BetterCast. Writing it
    ; anywhere else means the app reports "VDD: Not installed" on a machine
    ; where this installer just installed it, which is exactly what happened.
    ;
    ; And the 64-bit view, which is where the 64-bit app reads it. From this
    ; 32-bit installer without SetRegView it went to WOW6432Node instead.
    SetRegView 64
    WriteRegStr HKLM "Software\BetterCast" "VDDPath" "$INSTDIR\VirtualDisplayDriver"
    SetRegView 32

    vdd_skip_registry:
SectionEnd

; ─── Section descriptions ───────────────────────────────────────────────────────

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecCore} \
    "BetterCast. Send this PC's screen to any device, extend onto it, or receive a screen from one."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecVDD} \
    "Virtual Display Driver — creates virtual monitors so your desktop can extend onto a phone or tablet without a physical screen. Required for extending."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ─── Uninstall ──────────────────────────────────────────────────────────────────

Section "Uninstall"
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="BetterCast Glass mDNS"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="BetterCast Glass Streaming"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="BetterCast Glass App"'

    ; Every virtual display node, present or disconnected, then the driver
    ; package, its settings file and registry key. Same script and same reasons
    ; as the Qt installer's uninstaller: the old block depended on files in
    ; $INSTDIR, skipped disconnected nodes, and called pnputil through SysWOW64
    ; where it does not exist. Embedded, so it runs even if $INSTDIR is damaged.
    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File "vdd-cleanup.ps1"
    DetailPrint "Removing virtual displays and the Virtual Display Driver..."
    nsExec::ExecToLog '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\vdd-cleanup.ps1" -RemoveDriver -RemoveSettings'
    Pop $0
    DetailPrint "Virtual display cleanup exit code: $0"
    SetOutPath "$TEMP"

    RMDir /r "$INSTDIR"

    Delete "$DESKTOP\BetterCast.lnk"
    RMDir /r "$SMPROGRAMS\${PRODUCT_NAME}"

    DeleteRegKey HKLM "${PRODUCT_UNINST_KEY}"
    DeleteRegKey HKLM "${PRODUCT_DIR_REGKEY}"
    DeleteRegKey HKLM "Software\BetterCast"   ; WOW6432Node, from older installers
    SetRegView 64
    DeleteRegKey HKLM "Software\BetterCast"
    SetRegView 32
SectionEnd
