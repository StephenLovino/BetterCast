; BetterCast Windows Installer (NSIS)
; ==========================================================================
; Bundles BetterCast Receiver + Virtual Display Driver (VDD).
;
; Inputs (passed by CI via /D flags):
;   PRODUCT_VERSION         e.g. "1.0.0"   — display version
;   PRODUCT_NUMERIC_VERSION e.g. "1.0.0.0" — VS_VERSION_INFO 4-part numeric
;
; Both flags are required. The installer fails to compile without them — there
; is no fallback hardcoded version. Single source of truth lives in
; Sources/BetterCastReceiverDesktop/VERSION (read by CI, by CMake, and passed
; here).
; ==========================================================================

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

; ─── Required compile-time inputs ──────────────────────────────────────────────

!ifndef PRODUCT_VERSION
  !error "PRODUCT_VERSION not defined. CI must pass /DPRODUCT_VERSION=X.Y.Z (read from VERSION file)."
!endif
!ifndef PRODUCT_NUMERIC_VERSION
  !error "PRODUCT_NUMERIC_VERSION not defined. CI must pass /DPRODUCT_NUMERIC_VERSION=X.Y.Z.0."
!endif

; ─── Product metadata ──────────────────────────────────────────────────────────

!define PRODUCT_NAME       "BetterCast"
!define PRODUCT_PUBLISHER  "BetterCast"
!define PRODUCT_WEB_SITE   "https://bettercast.online"
!define PRODUCT_HELP_LINK  "https://github.com/StephenLovino/BetterCast/issues"
!define PRODUCT_EXE        "BetterCastReceiver.exe"

!define PRODUCT_DIR_REGKEY    "Software\Microsoft\Windows\CurrentVersion\App Paths\${PRODUCT_EXE}"
!define PRODUCT_UNINST_KEY    "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
!define PRODUCT_SETTINGS_KEY  "Software\${PRODUCT_NAME}"

; Firewall rule names — kept in one place for matching install/uninstall
!define FW_RULE_MDNS      "BetterCast mDNS"
!define FW_RULE_STREAMING "BetterCast Streaming"
!define FW_RULE_APP       "BetterCast App"

; VDD bundling
!define VDD_SUBDIR "VirtualDisplayDriver"
!define VDD_INF    "MttVDD.inf"

; ─── Installer attributes ──────────────────────────────────────────────────────

Name              "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile           "BetterCast-Setup-${PRODUCT_VERSION}.exe"
InstallDir        "$PROGRAMFILES64\${PRODUCT_NAME}"
InstallDirRegKey  HKLM "${PRODUCT_DIR_REGKEY}" ""
RequestExecutionLevel admin
ShowInstDetails   show
ShowUninstDetails show
SetCompressor     /SOLID lzma
Unicode           true

; Installer EXE properties (visible in File Properties → Details)
VIProductVersion "${PRODUCT_NUMERIC_VERSION}"
VIAddVersionKey  "ProductName"      "${PRODUCT_NAME}"
VIAddVersionKey  "ProductVersion"   "${PRODUCT_VERSION}"
VIAddVersionKey  "FileVersion"      "${PRODUCT_VERSION}"
VIAddVersionKey  "CompanyName"      "${PRODUCT_PUBLISHER}"
VIAddVersionKey  "FileDescription"  "${PRODUCT_NAME} Installer"
VIAddVersionKey  "LegalCopyright"   "Copyright (C) ${PRODUCT_PUBLISHER}"
VIAddVersionKey  "OriginalFilename" "BetterCast-Setup-${PRODUCT_VERSION}.exe"

; ─── Modern UI ──────────────────────────────────────────────────────────────────

!define MUI_ABORTWARNING
!define MUI_ICON   "appicon.ico"
!define MUI_UNICON "appicon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_RUN          "$INSTDIR\${PRODUCT_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT     "Launch ${PRODUCT_NAME}"
!define MUI_FINISHPAGE_LINK         "Visit ${PRODUCT_WEB_SITE}"
!define MUI_FINISHPAGE_LINK_LOCATION "${PRODUCT_WEB_SITE}"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ─── Helpers ───────────────────────────────────────────────────────────────────

; Stop a running instance of the app so files aren't locked during upgrade.
; Tries a graceful close first, then force-kills. Best-effort — never aborts.
!macro StopRunningApp
    DetailPrint "Checking for running ${PRODUCT_NAME} instance..."
    nsExec::ExecToLog 'taskkill /IM "${PRODUCT_EXE}" /T'
    Pop $0
    Sleep 500
    nsExec::ExecToLog 'taskkill /F /IM "${PRODUCT_EXE}" /T'
    Pop $0
!macroend

; If a previous version is installed, run its uninstaller silently in-place
; before laying down new files. This is the NSIS equivalent of WiX MajorUpgrade.
!macro UninstallPrevious
    ReadRegStr $0 HKLM "${PRODUCT_UNINST_KEY}" "UninstallString"
    ${If} $0 != ""
        ReadRegStr $1 HKLM "${PRODUCT_UNINST_KEY}" "InstallLocation"
        ${If} $1 == ""
            ; Older installers didn't write InstallLocation — fall back to $INSTDIR
            StrCpy $1 "$INSTDIR"
        ${EndIf}
        DetailPrint "Uninstalling previous version from $1..."
        ; _?=<dir> tells the uninstaller to run synchronously (don't self-copy
        ; to %TEMP% and exit early). /S = silent.
        ExecWait '"$0" /S _?=$1' $2
        DetailPrint "Previous uninstaller exit code: $2"
    ${EndIf}
!macroend

; ─── Install ───────────────────────────────────────────────────────────────────

Function .onInit
    ${IfNot} ${RunningX64}
        MessageBox MB_ICONSTOP|MB_OK "${PRODUCT_NAME} requires 64-bit Windows."
        Abort
    ${EndIf}
    SetRegView 64
FunctionEnd

Section "BetterCast" SecCore
    SectionIn RO

    !insertmacro StopRunningApp
    !insertmacro UninstallPrevious

    SetOutPath "$INSTDIR"
    SetOverwrite on

    ; Application files (CI populates artifact/ next to this .nsi)
    File /r "artifact\*.*"

    ; Shortcuts
    CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
    CreateShortCut  "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}"
    CreateShortCut  "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall.lnk"      "$INSTDIR\uninstall.exe"
    CreateShortCut  "$DESKTOP\${PRODUCT_NAME}.lnk"                   "$INSTDIR\${PRODUCT_EXE}"

    ; App Paths (lets users launch via Run dialog)
    WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" ""         "$INSTDIR\${PRODUCT_EXE}"
    WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "Path"     "$INSTDIR"

    ; Add/Remove Programs entry
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "DisplayName"     "${PRODUCT_NAME}"
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "DisplayVersion"  "${PRODUCT_VERSION}"
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${PRODUCT_EXE},0"
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "Publisher"       "${PRODUCT_PUBLISHER}"
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "URLInfoAbout"    "${PRODUCT_WEB_SITE}"
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "HelpLink"        "${PRODUCT_HELP_LINK}"
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr   HKLM "${PRODUCT_UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoModify"        1
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoRepair"        1

    ; Install size (KB) for ARP
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "EstimatedSize" $0

    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Firewall rules
    DetailPrint "Adding firewall rules..."
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="${FW_RULE_MDNS}" dir=in action=allow protocol=UDP localport=5353'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="${FW_RULE_STREAMING}" dir=in action=allow protocol=TCP localport=51820'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="${FW_RULE_APP}" dir=in action=allow program="$INSTDIR\${PRODUCT_EXE}"'
SectionEnd

Section "-VirtualDisplayDriver" SecVDD
    ; Required, hidden from UI (leading "-" in name + no description).
    ; Extending the desktop is the headline feature; making this optional was a
    ; support liability — users opted out and then reported "extension broken."
    SectionIn RO

    SetOutPath "$INSTDIR\${VDD_SUBDIR}"

    ; CI guarantees vdd/ contains MttVDD.inf — fail loud if not.
    File /r "vdd\*.*"

    ${IfNot} ${FileExists} "$INSTDIR\${VDD_SUBDIR}\${VDD_INF}"
        MessageBox MB_ICONSTOP|MB_OK "Installer is missing the Virtual Display Driver. This is a build packaging error — please report it at ${PRODUCT_HELP_LINK}."
        Abort
    ${EndIf}

    ; Install the driver via pnputil (Microsoft-supported on Win10+).
    ; devcon is legacy and inconsistently available; we don't fall back to it.
    DetailPrint "Installing Virtual Display Driver..."
    nsExec::ExecToLog 'pnputil /add-driver "$INSTDIR\${VDD_SUBDIR}\${VDD_INF}" /install'
    Pop $0
    DetailPrint "pnputil exit code: $0"

    ; pnputil exit codes:
    ;   0   = success
    ;   259 = ERROR_NO_MORE_ITEMS (already installed, treat as success)
    ;   3010 = success, reboot recommended
    ${If} $0 != 0
    ${AndIf} $0 != 259
    ${AndIf} $0 != 3010
        MessageBox MB_ICONEXCLAMATION|MB_OKCANCEL \
            "Virtual Display Driver install failed (exit code $0).$\n$\nYou can continue without screen extension support, or cancel and report at ${PRODUCT_HELP_LINK}." \
            IDOK vdd_install_continue
        Abort
        vdd_install_continue:
    ${EndIf}

    ; Capture the published OEM*.inf name so the uninstaller can remove the
    ; right driver later. pnputil republishes our INF under a new name like
    ; oem42.inf — the original filename is no longer authoritative.
    DetailPrint "Recording published driver name for clean uninstall..."

    ; Write a PowerShell helper to disk to avoid NSIS-escaping a multi-quote
    ; one-liner. The script finds the pnputil block whose Original Name is
    ; mttvdd.inf and emits its Published Name.
    StrCpy $R9 "$PLUGINSDIR\find-vdd-oem.ps1"
    FileOpen  $9 "$R9" w
    FileWrite $9 '$$blocks = (pnputil /enum-drivers | Out-String) -split "(?ms)^\s*$$"$\r$\n'
    FileWrite $9 '$$ours = $$blocks | Where-Object { $$_ -match "Original Name:\s*mttvdd\.inf" } | Select-Object -First 1$\r$\n'
    FileWrite $9 'if ($$ours -match "Published Name:\s*(\S+)") { $$matches[1] }$\r$\n'
    FileClose $9

    nsExec::ExecToStack 'powershell -NoProfile -ExecutionPolicy Bypass -File "$R9"'
    Pop $0   ; exit code
    Pop $1   ; stdout (e.g. "oem42.inf")
    ${If} $0 == 0
    ${AndIf} $1 != ""
        Push $1
        Call TrimNewlines
        Pop $1
        DetailPrint "Published driver name: $1"
        WriteRegStr HKLM "${PRODUCT_SETTINGS_KEY}" "VDDOemInf" "$1"
    ${Else}
        DetailPrint "Could not determine published VDD driver name (exit=$0). Uninstall may leave driver behind."
    ${EndIf}
    WriteRegStr HKLM "${PRODUCT_SETTINGS_KEY}" "VDDInstallPath" "$INSTDIR\${VDD_SUBDIR}"
    WriteRegStr HKLM "${PRODUCT_SETTINGS_KEY}" "VDDVersion"     "${PRODUCT_VERSION}"
SectionEnd

; Trim CR/LF/spaces from $1 -> $1
Function TrimNewlines
    Exch $R0
    Push $R1
    Push $R2
    StrCpy $R2 0
    loop:
        IntOp $R2 $R2 + 1
        StrCpy $R1 $R0 1 -$R2
        ${If} $R1 == "$\r"
        ${OrIf} $R1 == "$\n"
        ${OrIf} $R1 == "$\t"
        ${OrIf} $R1 == " "
            Goto loop
        ${EndIf}
        IntOp $R2 $R2 - 1
        StrCpy $R0 $R0 -$R2
    Pop $R2
    Pop $R1
    Exch $R0
FunctionEnd

; ─── Uninstall ─────────────────────────────────────────────────────────────────

Function un.onInit
    SetRegView 64
FunctionEnd

Section "Uninstall"
    !insertmacro StopRunningApp

    ; Remove firewall rules
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${FW_RULE_MDNS}"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${FW_RULE_STREAMING}"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${FW_RULE_APP}"'

    ; Remove VDD driver using the published OEM name we stored at install time.
    ; Falling back to the original INF filename does not work — pnputil only
    ; accepts the published name (oemNN.inf).
    ReadRegStr $0 HKLM "${PRODUCT_SETTINGS_KEY}" "VDDOemInf"
    ${If} $0 != ""
        DetailPrint "Removing Virtual Display Driver ($0)..."
        nsExec::ExecToLog 'pnputil /delete-driver "$0" /uninstall /force'
        Pop $1
        DetailPrint "pnputil delete-driver exit code: $1"
    ${Else}
        DetailPrint "No published VDD driver name recorded — skipping driver removal"
    ${EndIf}

    ; Remove files
    RMDir /r "$INSTDIR"

    ; Remove shortcuts
    Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
    RMDir /r "$SMPROGRAMS\${PRODUCT_NAME}"

    ; Remove registry
    DeleteRegKey HKLM "${PRODUCT_UNINST_KEY}"
    DeleteRegKey HKLM "${PRODUCT_DIR_REGKEY}"
    DeleteRegKey HKLM "${PRODUCT_SETTINGS_KEY}"
SectionEnd
