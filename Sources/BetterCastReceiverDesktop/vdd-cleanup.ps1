# Removes BetterCast's virtual displays: the Virtual Display Driver's device
# nodes (hardware ID Root\MttVDD), and optionally the driver package and its
# settings.
#
# Run by both Windows installers - Sources/BetterCastReceiverDesktop/installer.nsi
# and spike/glass-app/installer.nsi. It is a file rather than inline NSIS so the
# PowerShell is not mangled by NSIS's own $ and quote escaping.
#
#   -DisconnectedOnly  Only nodes Windows reports as not present: the leftovers
#                      that earlier installs and failed uninstalls piled up.
#                      Safe at install time; nothing currently working is touched.
#   -RemoveDriver      Also delete the MttVDD package from the driver store.
#   -RemoveSettings    Also delete the driver's vdd_settings.xml and registry key.
#
# Must run elevated, as 64-bit PowerShell. A 32-bit process resolves pnputil to
# SysWOW64, where there is no pnputil.exe - which is why the uninstaller's old
# "pnputil /delete-driver" never removed anything.

param(
    [switch]$DisconnectedOnly,
    [switch]$RemoveDriver,
    [switch]$RemoveSettings
)

$pnputil = Join-Path $env:windir 'System32\pnputil.exe'
if (-not (Test-Path $pnputil)) {
    Write-Output "pnputil.exe not found at $pnputil - is this 32-bit PowerShell?"
    exit 2
}

# 3010 is "succeeded, reboot required".
function Test-PnpUtilOk([int]$code) { return $code -eq 0 -or $code -eq 3010 }

$failed = 0

# Matched on the driver's hardware ID, not on the ROOT\DISPLAY instance path:
# other virtual display products are root-enumerated too, and they are not ours
# to remove. The friendly-name fallback covers nodes whose hardware ID Windows
# no longer reports once the driver behind them is gone.
$nodes = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object {
    ($_.HardwareID -contains 'Root\MttVDD') -or
    ($_.InstanceId -like 'ROOT\DISPLAY\*' -and $_.FriendlyName -match 'Virtual Display Driver|MttVDD')
})
if ($DisconnectedOnly) {
    $nodes = @($nodes | Where-Object { -not $_.Present })
}

Write-Output "Virtual display device nodes to remove: $($nodes.Count)"
foreach ($node in $nodes) {
    Write-Output "Removing $($node.InstanceId) (present: $($node.Present))"
    & $pnputil /remove-device "$($node.InstanceId)"
    if (-not (Test-PnpUtilOk $LASTEXITCODE)) { $failed++ }
}

# Monitor devices the virtual displays stranded. Every driver re-enumeration
# gives each virtual display a fresh DISPLAY\MTT1337\... monitor and leaves the
# old one behind, so Device Manager's Monitors list fills with disconnected
# "Generic Monitor (VDD by MTT)" entries. Only ones that are not present: a
# present monitor belongs to a working display.
$monitors = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -like 'DISPLAY\MTT1337\*' -and -not $_.Present })
Write-Output "Disconnected virtual monitor entries to remove: $($monitors.Count)"
foreach ($mon in $monitors) {
    Write-Output "Removing $($mon.InstanceId)"
    & $pnputil /remove-device "$($mon.InstanceId)"
    if (-not (Test-PnpUtilOk $LASTEXITCODE)) { $failed++ }
}

if ($RemoveDriver) {
    # /delete-driver wants the published name Windows gave the package
    # (oemNN.inf), not the path it was installed from. Find it by content,
    # which - unlike pnputil /enum-drivers output - is not translated into the
    # system language.
    $infs = @(Get-ChildItem (Join-Path $env:windir 'INF\oem*.inf') -ErrorAction SilentlyContinue |
              Where-Object { Select-String -Path $_.FullName -SimpleMatch 'Root\MttVDD' -Quiet })
    Write-Output "Driver packages to remove: $($infs.Count)"
    foreach ($inf in $infs) {
        Write-Output "Deleting driver package $($inf.Name)"
        & $pnputil /delete-driver $inf.Name /uninstall /force
        if (-not (Test-PnpUtilOk $LASTEXITCODE)) { $failed++ }
    }
}

if ($RemoveSettings) {
    # The driver reads its settings from this fixed folder, not from the folder
    # it was installed from (see vddSettingsPath() in VirtualDisplayVDD.cpp).
    $settingsDir = 'C:\VirtualDisplayDriver'
    $settings = Join-Path $settingsDir 'vdd_settings.xml'
    if (Test-Path $settings) {
        Remove-Item $settings -Force
        Write-Output "Deleted $settings"
    }
    # The folder only if nothing else lives in it.
    if ((Test-Path $settingsDir) -and -not (Get-ChildItem $settingsDir -Force)) {
        Remove-Item $settingsDir -Force
    }
    Remove-Item 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Output "$failed step(s) failed"
    exit 1
}
exit 0
