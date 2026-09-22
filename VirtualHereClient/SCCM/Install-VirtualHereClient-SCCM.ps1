<#
.SYNOPSIS
    SCCM-compatible variant of Install-VirtualHereClient.ps1. Copies the
    VirtualHere USB client from the SCCM package content directory, installs
    it as a Windows service (Auto-Find off, via -b), pins the service to a
    specific config.ini, points it at the USB server, enables Auto-Use, and
    adds a Start Menu shortcut.

.NOTES
    Differences from Install-VirtualHereClient.ps1 (interactive version):
    - Assumes vhui64.exe is already staged in the SCCM package content
      directory alongside this script (i.e. $PSScriptRoot\vhui64.exe) and
      copies it to -InstallDir, rather than requiring it pre-installed on
      the target machine.
    - No #Requires -RunAsAdministrator: that directive fails at parse time
      with an opaque, uncatchable error, which is painful to diagnose from
      AppEnforce.log/execmgr.log. Elevation is instead checked at runtime
      and reported through normal logging with an explicit exit code.
      SCCM's default "Install for System" context already runs as SYSTEM,
      which satisfies this.
    - All failures go through try/catch and exit with a distinct, documented
      non-zero code instead of an uncaught `throw`, so SCCM's success/failure
      determination (based on process exit code) is reliable and so a
      specific code can be traced back to a specific failure point below.
    - Every status/warning/error line is written to both the console (so it
      shows up in AppEnforce.log/execmgr.log, which capture stdout/stderr
      for a script-based deployment type) and to a persistent CMTrace-style
      log file at $env:ProgramData\VirtualHere\Logs\Install-VirtualHereClient-SCCM.log
      for post-deployment troubleshooting.

    Exit codes:
      0    - Success
      1    - Not running elevated
      2    - Source binary not found in package content directory
      3    - VirtualHere service not found after -b install
      10   - Win32_Service.Change() failed to update binPath
      11   - Service failed to start on the new binPath (rolled back)
      20   - IPC pipe unreachable after service (re)start
      99   - Unexpected/unhandled error (see log for details)

    Suggested SCCM Deployment Type settings:
      - Installation program:
          powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-VirtualHereClient-SCCM.ps1 -ServerAddress "192.168.15.159:7575"
      - Run script in 64-bit PowerShell host (vhui64.exe and its install
        path are both native 64-bit; avoid WOW64 ambiguity).
      - Detection method: registry value
          HKLM\SYSTEM\CurrentControlSet\Services\vhclient\ImagePath
        contains "-c " (confirms the config pointer actually took), or a
        simpler "service vhclient exists" check for a coarser signal.
      - Install behavior: Install for System.

.EXAMPLE
    .\Install-VirtualHereClient-SCCM.ps1 -ServerAddress "it-rpi1.corp.brigadecapital.com:7575"
#>

[CmdletBinding()]
param(
    [string]$PackageSourceDir = $PSScriptRoot,
    [string]$InstallDir       = "C:\Program Files\VirtualHere",
    [string]$ConfigPath       = "C:\Program Files\VirtualHere\config.ini",
    [string]$ServerAddress    = "192.168.15.159:7575",  # host:port or EasyFind ID
    [string]$DeviceAddress    = $null                    # e.g. "it-rpi1.4" from LIST; leave blank to auto-use the whole hub
)

if ([string]::IsNullOrWhiteSpace($PackageSourceDir)) {
    # $PSScriptRoot/$PSCommandPath have been observed to come back empty
    # under some SCCM client execution paths for the Installation Program,
    # even when invoked with "-File .\thisscript.ps1". The CM client does
    # reliably set the process's working directory to the content cache
    # folder before running the install command, so fall back to that.
    $PackageSourceDir = (Get-Location).Path
}

$VHExePath = Join-Path $InstallDir "vhui64.exe"

$LogDir  = Join-Path $env:ProgramData "VirtualHere\Logs"
$LogFile = Join-Path $LogDir "Install-VirtualHereClient-SCCM.log"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "{0} `t{1}`t{2}" -f (Get-Date -Format 'MM-dd-yyyy HH:mm:ss.fff'), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Output "ERROR: $Message" }
        default { Write-Output $Message }
    }
}

function Invoke-VHCommand {
    param([string[]]$CommandArgs)
    # vhui64.exe pops a native message box with the result of a "-t" command
    # (e.g. "USB server added") unless the result is redirected to a file with
    # "-r" instead - since this runs unattended under SCCM, there's no one to
    # dismiss that box. See https://www.virtualhere.com/node/660.
    $outFile = Join-Path $env:TEMP "vh_$([guid]::NewGuid().ToString('N')).out"
    Write-Log -Level INFO -Message "Running: `"$VHExePath`" $($CommandArgs -join ' ') -r `"$outFile`""
    & $VHExePath @CommandArgs -r $outFile 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    $result = if (Test-Path -LiteralPath $outFile) { (Get-Content -LiteralPath $outFile -Raw).Trim() } else { '' }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) {
        Write-Log -Level WARN -Message "Command '$($CommandArgs -join ' ')' returned exit code $exitCode : $result"
    }
    return $result
}

Write-Log -Level INFO -Message "PSScriptRoot='$PSScriptRoot' PSCommandPath='$PSCommandPath' PWD='$((Get-Location).Path)' PackageSourceDir(resolved)='$PackageSourceDir'"

try {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log -Level ERROR -Message "Not running elevated. SCCM's default 'Install for System' context runs as SYSTEM and satisfies this; if testing manually, launch an elevated PowerShell session."
        exit 1
    }

    # --- Stage the binary from the SCCM package content directory ----------
    $sourceExe = Join-Path $PackageSourceDir "vhui64.exe"
    if (-not (Test-Path $sourceExe)) {
        Write-Log -Level ERROR -Message "Expected VirtualHere binary at '$sourceExe' (alongside this script in the package content) but it was not found. Confirm vhui64.exe is included in the Deployment Type's content."
        exit 2
    }
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    Copy-Item -Path $sourceExe -Destination $VHExePath -Force
    Write-Log -Level INFO -Message "Copied $sourceExe -> $VHExePath"

    # Make sure the config directory/file exist so -c has something to point at.
    $configDir = Split-Path $ConfigPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    if (-not (Test-Path $ConfigPath)) {
        New-Item -ItemType File -Path $ConfigPath -Force | Out-Null
    }

    # --- Install the service ------------------------------------------------
    $existingSvc = Get-Service -Name "vhclient*" -ErrorAction SilentlyContinue
    if (-not $existingSvc) {
        Write-Log -Level INFO -Message "Installing VirtualHere client as a service (Auto-Find off)..."
        & $VHExePath -b
        Start-Sleep -Seconds 10
    } else {
        Write-Log -Level INFO -Message "VirtualHere service already installed as '$($existingSvc.Name)' - skipping -b install."
    }

    $svc = Get-Service -Name "vhclient*" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log -Level ERROR -Message "VirtualHere service not found after -b install. Check Event Viewer > Windows Logs > Application for errors."
        exit 3
    }
    $serviceName = $svc.Name
    Write-Log -Level INFO -Message "Service name: $serviceName | Status: $($svc.Status)"

    # --- Re-point the service at our config file, WITHOUT dropping whatever
    #     else -b put in binPath ---------------------------------------------
    $wmiSvc      = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'"
    $currentPath = $wmiSvc.PathName
    Write-Log -Level INFO -Message "Current service binPath: $currentPath"

    # vhui64.exe's own -b self-install can leave paths single-quoted, which
    # Windows CreateProcess/SCM does not recognize as a quote delimiter (only
    # " is), leaving the exe path unresolved. Treat single quotes anywhere in
    # binPath as broken, not just a missing -c, so an already-installed but
    # still-broken service gets repaired on re-run instead of left alone.
    if ($currentPath -match "'" -or $currentPath -notmatch '-c\s') {
        $exePattern = [regex]::Escape($VHExePath)
        if ($currentPath -match "^[`"']?$exePattern[`"']?\s*(.*)$") {
            $existingFlags = $matches[1].Trim()
        } else {
            $existingFlags = ''
            Write-Log -Level WARN -Message "Could not parse existing binPath to extract flags (e.g. -n -e); they may be lost. Original was: $currentPath"
        }
        # Drop any pre-existing -c <path> (single- or double-quoted, or bare)
        # from the leftover flags so we don't end up with two -c arguments.
        $existingFlags = ($existingFlags -replace "-c\s+(?:'[^']*'|""[^""]*""|\S+)", '').Trim()

        $quotedExe    = "`"$VHExePath`""
        $quotedConfig = "`"$ConfigPath`""
        $newPath = ("$quotedExe $existingFlags -c $quotedConfig" -replace '\s+', ' ').Trim()
        Write-Log -Level INFO -Message "New service binPath will be: $newPath"

        # Use the WMI Change() method rather than shelling out to sc.exe.
        # $newPath starts with an embedded, literal `"` character (not a
        # PowerShell quote delimiter), and PowerShell's native-command
        # argument passing does not reliably preserve embedded double quotes
        # -- sc.exe can silently receive a mangled binPath= value with no
        # reliable exit code to detect it. Change() takes PathName as a real
        # parameter (no command-line re-quoting) and returns an explicit status.
        Stop-Service -Name $serviceName -Force
        $changeResult = Invoke-CimMethod -InputObject $wmiSvc -MethodName Change -Arguments @{ PathName = $newPath }
        if ($changeResult.ReturnValue -ne 0) {
            Write-Log -Level ERROR -Message "Win32_Service.Change() failed to set the new binPath (ReturnValue=$($changeResult.ReturnValue)). Service left on original binPath: $currentPath."
            exit 10
        }
        Start-Service -Name $serviceName
        Start-Sleep -Seconds 5

        $svcAfter = Get-Service -Name $serviceName
        if ($svcAfter.Status -ne 'Running') {
            Write-Log -Level WARN -Message "Service is '$($svcAfter.Status)' after binPath change, not 'Running'. Rolling back."
            $wmiSvcNow = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'"
            Invoke-CimMethod -InputObject $wmiSvcNow -MethodName Change -Arguments @{ PathName = $currentPath } | Out-Null
            Start-Service -Name $serviceName
            Write-Log -Level ERROR -Message "Service failed to start with the new binPath. Reverted to original binPath: $currentPath. Check Event Viewer > Application log for the failure reason before retrying."
            exit 11
        }

        # Verify against the registry directly -- WMI's own PathName can lag.
        $registryPath = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" -Name ImagePath).ImagePath
        if ($registryPath -ne $newPath) {
            Write-Log -Level WARN -Message "Registry ImagePath ('$registryPath') does not match the intended binPath ('$newPath') even though Change() reported success and the service is running. Investigate before assuming -c took effect."
        }
    } else {
        Write-Log -Level INFO -Message "Service binPath already includes -c, leaving as-is."
    }

    # --- Sanity-check the IPC pipe is actually reachable --------------------
    Write-Log -Level INFO -Message "Verifying IPC connectivity..."
    $listCheck = Invoke-VHCommand -CommandArgs @('-t', 'LIST')
    Write-Log -Level INFO -Message "$listCheck"
    if ($listCheck -match 'No response from IPC server' -or $listCheck -match 'IPC stat failed') {
        Write-Log -Level ERROR -Message "Cannot reach the VirtualHere service over IPC. The service is registered but not listening on the pipe - check Event Viewer > Application log for a crash/startup error before proceeding."
        exit 20
    }

    # --- Point the running client at the USB server -------------------------
    Write-Log -Level INFO -Message "Adding hub: $ServerAddress"
    $addResult = Invoke-VHCommand -CommandArgs @('-t', "MANUAL HUB ADD,$ServerAddress")
    Write-Log -Level INFO -Message "  -> $addResult"
    Start-Sleep -Seconds 2

    # Confirm it was actually registered, not just that the command returned OK
    $manualHubs = Invoke-VHCommand -CommandArgs @('-t', 'MANUAL HUB LIST')
    Write-Log -Level INFO -Message "Manual hubs currently configured: $manualHubs"
    if ($manualHubs -notmatch [regex]::Escape($ServerAddress)) {
        Write-Log -Level WARN -Message "MANUAL HUB ADD returned '$addResult' but '$ServerAddress' does not appear in MANUAL HUB LIST. Check network reachability to that host:port (firewall / Palo Alto policy) rather than assuming this is a script issue."
    }

    # --- Enable Auto-Use ------------------------------------------------------
    if ($DeviceAddress) {
        Write-Log -Level INFO -Message "Enabling Auto-Use for device: $DeviceAddress"
        $autoResult = Invoke-VHCommand -CommandArgs @('-t', "AUTO USE DEVICE,$DeviceAddress")
    } else {
        Write-Log -Level INFO -Message "Enabling Auto-Use for entire hub: $ServerAddress"
        $autoResult = Invoke-VHCommand -CommandArgs @('-t', "AUTO USE HUB,$ServerAddress")
    }
    Write-Log -Level INFO -Message "  -> $autoResult"

    $finalState = Invoke-VHCommand -CommandArgs @('-t', 'LIST')
    Write-Log -Level INFO -Message "Current client state: $finalState"

    # --- Create a Start Menu shortcut so users can open the tray/status UI --
    # (the service itself runs headless via -n -e; this launches vhui64.exe in
    # its normal GUI mode, which talks to the already-running service over IPC.)
    $startMenuProgramsDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
    $shortcutPath = Join-Path $startMenuProgramsDir "VirtualHere Client.lnk"
    Write-Log -Level INFO -Message "Creating Start Menu shortcut: $shortcutPath"
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $VHExePath
    $shortcut.WorkingDirectory = Split-Path $VHExePath -Parent
    $shortcut.Description = "VirtualHere USB Client"
    $shortcut.Save()

    Write-Log -Level INFO -Message "Done. Confirm the loaded config path in Event Viewer > Windows Logs > Application (look for 'Using config at ...') to verify the service is actually reading $ConfigPath."
    exit 0
}
catch {
    Write-Log -Level ERROR -Message "Unhandled error: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    exit 99
}
