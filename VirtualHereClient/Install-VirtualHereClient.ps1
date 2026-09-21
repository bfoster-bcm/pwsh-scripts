#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the VirtualHere USB client as a Windows service (Auto-Find off, via -b),
    pins the service to a specific config.ini, points it at the USB server, and
    enables Auto-Use.

.NOTES
    - Must be run from an elevated PowerShell session.
    - By default, a VirtualHere client running AS A SERVICE runs under the SYSTEM
      account, and if you don't explicitly wire a config path into the service's
      own start command, it silently falls back to:
        C:\Windows\system32\config\systemprofile\AppData\Roaming\vhui.ini
      This script re-points the service's binPath to include -c and your chosen
      config file so that fallback doesn't happen silently.
    - IMPORTANT: the -b installer may embed additional flags in binPath beyond
      the bare exe path (VirtualHere's own support forum shows examples with
      extra flags needed for the process to behave correctly as a service).
      This script therefore APPENDS -c to whatever binPath -b actually set,
      rather than replacing it outright -- overwriting it wholesale can leave
      the service registered but not actually listening on the IPC pipe.
    - VirtualHere logs which config file it actually loaded to the Windows
      Application Event Log on every service start (look for "Using config at ...").
      ALWAYS check that after running this script to confirm it's reading the
      file you intended.

.EXAMPLE
    .\Install-VirtualHereClient.ps1 -ServerAddress "it-rpi1.brigadecapital.com:7575"
#>

[CmdletBinding()]
param(
    [string]$VHExePath     = "C:\Program Files\VirtualHere\vhui64.exe",
    [string]$ConfigPath    = "C:\Program Files\VirtualHere\config.ini",
    [string]$ServerAddress = "192.168.15.159:7575",  # host:port or EasyFind ID
    [string]$DeviceAddress = $null                    # e.g. "it-rpi1.4" from LIST; leave blank to auto-use the whole hub
)

function Invoke-VHCommand {
    param([string[]]$CommandArgs)
    Write-Verbose "Running: `"$VHExePath`" $($CommandArgs -join ' ')"
    $result = & $VHExePath @CommandArgs 2>&1
    $exitCode = $LASTEXITCODE
    Write-Verbose "Exit code: $exitCode | Result: $result"
    if ($exitCode -ne 0) {
        Write-Warning "Command '$($CommandArgs -join ' ')' returned exit code $exitCode : $result"
    }
    return $result
}

if (-not (Test-Path $VHExePath)) {
    throw "VirtualHere client binary not found at '$VHExePath'. Update -VHExePath and retry."
}

# Make sure the config directory/file exist so -c has something to point at.
$configDir = Split-Path $ConfigPath -Parent
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}
if (-not (Test-Path $ConfigPath)) {
    New-Item -ItemType File -Path $ConfigPath -Force | Out-Null
}

# --- Install the service ---------------------------------------------------
$existingSvc = Get-Service -Name "vhclient*" -ErrorAction SilentlyContinue
if (-not $existingSvc) {
    Write-Host "Installing VirtualHere client as a service (Auto-Find off)..."
    & $VHExePath -b
    Start-Sleep -Seconds 10
} else {
    Write-Host "VirtualHere service already installed as '$($existingSvc.Name)' - skipping -b install."
}

$svc = Get-Service -Name "vhclient*" -ErrorAction SilentlyContinue
if (-not $svc) {
    throw "VirtualHere service not found after -b install. Check Event Viewer > Windows Logs > Application for errors."
}
$serviceName = $svc.Name
Write-Host "Service name: $serviceName | Status: $($svc.Status)"

# --- Re-point the service at our config file, WITHOUT dropping whatever
#     else -b put in binPath -------------------------------------------------
$wmiSvc      = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'"
$currentPath = $wmiSvc.PathName
Write-Host "Current service binPath: $currentPath"

# vhui64.exe's own -b self-install wraps paths in single quotes (valid on
# Linux/macOS, NOT recognized by Windows CreateProcess/SCM). With the exe
# path left effectively unquoted because of that, the SCM's path-resolution
# walk can't find a match at the space in "Program Files" and the service
# fails to start with a generic "can't find the file" error even though
# vhui64.exe is present. Treat single quotes anywhere in binPath as broken,
# not just a missing -c, so a previously "fixed" (but still single-quoted)
# service gets repaired on re-run instead of being left alone.
if ($currentPath -match "'" -or $currentPath -notmatch '-c\s') {
    $exePattern = [regex]::Escape($VHExePath)
    if ($currentPath -match "^[`"']?$exePattern[`"']?\s*(.*)$") {
        $existingFlags = $matches[1].Trim()
    } else {
        $existingFlags = ''
        Write-Warning "Could not parse existing binPath to extract flags (e.g. -n -e); they may be lost. Original was: $currentPath"
    }
    # Drop any pre-existing -c <path> (single- or double-quoted, or bare) from
    # the leftover flags so we don't end up with two -c arguments.
    $existingFlags = ($existingFlags -replace "-c\s+(?:'[^']*'|""[^""]*""|\S+)", '').Trim()

    $quotedExe    = "`"$VHExePath`""
    $quotedConfig = "`"$ConfigPath`""
    $newPath = ("$quotedExe $existingFlags -c $quotedConfig" -replace '\s+', ' ').Trim()
    Write-Host "New service binPath will be: $newPath"

    # Use the WMI Change() method rather than shelling out to sc.exe. $newPath
    # starts with an embedded, literal `"` character (not a PowerShell quote
    # delimiter), and PowerShell's native-command argument passing does not
    # reliably preserve embedded double quotes -- sc.exe can silently receive
    # a mangled binPath= value. sc.exe also gives no reliable exit code here,
    # so a failure was going undetected. Change() takes PathName as a real
    # parameter (no command-line re-quoting) and returns an explicit status.
    Stop-Service -Name $serviceName -Force
    $changeResult = Invoke-CimMethod -InputObject $wmiSvc -MethodName Change -Arguments @{ PathName = $newPath }
    if ($changeResult.ReturnValue -ne 0) {
        throw "Win32_Service.Change() failed to set the new binPath (ReturnValue=$($changeResult.ReturnValue)). Service left on original binPath: $currentPath."
    }
    Start-Service -Name $serviceName
    Start-Sleep -Seconds 5

    $svcAfter = Get-Service -Name $serviceName
    if ($svcAfter.Status -ne 'Running') {
        Write-Warning "Service is '$($svcAfter.Status)' after binPath change, not 'Running'. Rolling back."
        $wmiSvcNow = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'"
        Invoke-CimMethod -InputObject $wmiSvcNow -MethodName Change -Arguments @{ PathName = $currentPath } | Out-Null
        Start-Service -Name $serviceName
        throw "Service failed to start with the new binPath. Reverted to original binPath: $currentPath. Check Event Viewer > Application log for the failure reason before retrying."
    }

    # Verify against the registry directly -- WMI's own PathName can lag.
    $registryPath = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" -Name ImagePath).ImagePath
    if ($registryPath -ne $newPath) {
        Write-Warning "Registry ImagePath ('$registryPath') does not match the intended binPath ('$newPath') even though Change() reported success and the service is running. Investigate before assuming -c took effect."
    }
} else {
    Write-Host "Service binPath already includes -c, leaving as-is."
}

# --- Sanity-check the IPC pipe is actually reachable before doing anything else
Write-Host "`nVerifying IPC connectivity..."
$listCheck = Invoke-VHCommand -CommandArgs @('-t', 'LIST')
Write-Host $listCheck
if ($listCheck -match 'No response from IPC server' -or $listCheck -match 'IPC stat failed') {
    throw "Cannot reach the VirtualHere service over IPC. The service is registered but not listening on the pipe - check Event Viewer > Application log for a crash/startup error before proceeding."
}

# --- Point the running client at the USB server -----------------------------
Write-Host "`nAdding hub: $ServerAddress"
$addResult = Invoke-VHCommand -CommandArgs @('-t', "MANUAL HUB ADD,$ServerAddress")
Write-Host "  -> $addResult"
Start-Sleep -Seconds 2

# Confirm it was actually registered, not just that the command returned OK
$manualHubs = Invoke-VHCommand -CommandArgs @('-t', 'MANUAL HUB LIST')
Write-Host "Manual hubs currently configured:`n$manualHubs"
if ($manualHubs -notmatch [regex]::Escape($ServerAddress)) {
    Write-Warning "MANUAL HUB ADD returned '$addResult' but '$ServerAddress' does not appear in MANUAL HUB LIST. Check network reachability to that host:port (firewall / Palo Alto policy) rather than assuming this is a script issue."
}

# --- Enable Auto-Use ---------------------------------------------------------
if ($DeviceAddress) {
    Write-Host "`nEnabling Auto-Use for device: $DeviceAddress"
    $autoResult = Invoke-VHCommand -CommandArgs @('-t', "AUTO USE DEVICE,$DeviceAddress")
} else {
    Write-Host "`nEnabling Auto-Use for entire hub: $ServerAddress"
    $autoResult = Invoke-VHCommand -CommandArgs @('-t', "AUTO USE HUB,$ServerAddress")
}
Write-Host "  -> $autoResult"

Write-Host "`nCurrent client state:"
Invoke-VHCommand -CommandArgs @('-t', 'LIST')

# --- Create a Start Menu shortcut so users can open the tray/status UI ------
# (the service itself runs headless via -n -e; this launches vhui64.exe in its
# normal GUI mode, which talks to the already-running service over IPC.)
$startMenuProgramsDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
$shortcutPath = Join-Path $startMenuProgramsDir "VirtualHere Client.lnk"
Write-Host "`nCreating Start Menu shortcut: $shortcutPath"
$wshShell = New-Object -ComObject WScript.Shell
$shortcut = $wshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $VHExePath
$shortcut.WorkingDirectory = Split-Path $VHExePath -Parent
$shortcut.Description = "VirtualHere USB Client"
$shortcut.Save()

Write-Host "`nDone. Confirm the loaded config path in Event Viewer > Windows Logs > Application" `
    "(look for 'Using config at ...') to verify the service is actually reading $ConfigPath."