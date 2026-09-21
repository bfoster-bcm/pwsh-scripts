<#
.SYNOPSIS
    SCCM-compatible uninstall of the VirtualHere USB client: stops and removes
    the Windows service, deletes the install directory (binary + config.ini),
    sweeps up per-user/SYSTEM-profile vhui.ini fallback files, and removes the
    Start Menu shortcut.

.NOTES
    Mirrors Install-VirtualHereClient-SCCM.ps1's conventions:
    - No #Requires -RunAsAdministrator: that directive fails at parse time
      with an opaque, uncatchable error. Elevation is checked at runtime and
      reported through normal logging with an explicit exit code. SCCM's
      default "Install for System" context (SYSTEM) satisfies this.
    - Every step is best-effort and idempotent: if a given piece (service,
      folder, shortcut, fallback ini) is already gone, that step is logged
      and skipped rather than treated as an error, so this is safe to re-run
      and safe to use as both the uninstall AND a "repair by reinstalling"
      precursor.
    - Every status/warning/error line goes to both the console (captured by
      AppEnforce.log/execmgr.log for a script deployment type) and a
      persistent CMTrace-style log file at
      $env:ProgramData\VirtualHere\Logs\Uninstall-VirtualHereClient-SCCM.log

    Exit codes:
      0    - Success, nothing left behind
      1    - Not running elevated
      50   - Completed, but one or more steps failed (see log) -- e.g. a
             file was in use, or the service is pending deletion until a
             held handle is released
      99   - Unexpected/unhandled error (see log for details)

    Suggested SCCM Deployment Type settings:
      - Uninstall program:
          powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-VirtualHereClient-SCCM.ps1
      - Run script in 64-bit PowerShell host.
      - Uninstall behavior: Install for System.

.EXAMPLE
    .\Uninstall-VirtualHereClient-SCCM.ps1
#>

[CmdletBinding()]
param(
    [string]$InstallDir              = "C:\Program Files\VirtualHere",
    [string]$ShortcutName            = "VirtualHere Client",
    [string]$ServiceNamePattern      = "vhclient*",
    [string]$SystemProfileConfigPath = "C:\Windows\System32\config\systemprofile\AppData\Roaming\vhui.ini",
    [switch]$SkipUserConfigSweep
)

$LogDir  = Join-Path $env:ProgramData "VirtualHere\Logs"
$LogFile = Join-Path $LogDir "Uninstall-VirtualHereClient-SCCM.log"
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

$script:hadWarnings = $false

function Invoke-UninstallStep {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    try {
        & $Action
    } catch {
        Write-Log -Level WARN -Message "$Description failed: $($_.Exception.Message)"
        $script:hadWarnings = $true
    }
}

try {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log -Level ERROR -Message "Not running elevated. SCCM's default 'Install for System' context runs as SYSTEM and satisfies this; if testing manually, launch an elevated PowerShell session."
        exit 1
    }

    # --- Stop and remove the Windows service --------------------------------
    Write-Log -Level INFO -Message "Checking for VirtualHere service ('$ServiceNamePattern')..."
    $svc = Get-Service -Name $ServiceNamePattern -ErrorAction SilentlyContinue
    if ($svc) {
        $serviceName = $svc.Name
        Write-Log -Level INFO -Message "Found service '$serviceName' (Status: $($svc.Status)). Stopping..."

        Invoke-UninstallStep -Description "Stop-Service '$serviceName'" -Action {
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
            }
        }

        $wmiSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($wmiSvc) {
            $deleteResult = Invoke-CimMethod -InputObject $wmiSvc -MethodName Delete
            if ($deleteResult.ReturnValue -ne 0) {
                Write-Log -Level WARN -Message "Win32_Service.Delete() for '$serviceName' returned code $($deleteResult.ReturnValue). It may be marked pending deletion until all handles are released."
                $script:hadWarnings = $true
            }
        }

        $stillPresent = $false
        for ($i = 0; $i -lt 5; $i++) {
            Start-Sleep -Seconds 1
            if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
                $stillPresent = $false
                break
            }
            $stillPresent = $true
        }
        if ($stillPresent) {
            Write-Log -Level WARN -Message "Service '$serviceName' still listed after Delete() -- likely pending deletion until other handles to it are released, or after a reboot."
            $script:hadWarnings = $true
        } else {
            Write-Log -Level INFO -Message "Service '$serviceName' removed."
        }
    } else {
        Write-Log -Level INFO -Message "No VirtualHere service found - already removed, skipping."
    }

    # --- Remove install directory (binary + config.ini) ---------------------
    Write-Log -Level INFO -Message "Checking install directory: $InstallDir"
    if (Test-Path -LiteralPath $InstallDir) {
        Invoke-UninstallStep -Description "Remove install directory '$InstallDir'" -Action {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
            Write-Log -Level INFO -Message "Removed $InstallDir"
        }
    } else {
        Write-Log -Level INFO -Message "Install directory not present - already removed, skipping."
    }

    # --- Remove the SYSTEM-profile fallback config ---------------------------
    Write-Log -Level INFO -Message "Checking SYSTEM-profile fallback config: $SystemProfileConfigPath"
    if (Test-Path -LiteralPath $SystemProfileConfigPath) {
        Invoke-UninstallStep -Description "Remove SYSTEM-profile fallback config" -Action {
            Remove-Item -LiteralPath $SystemProfileConfigPath -Force -ErrorAction Stop
            Write-Log -Level INFO -Message "Removed $SystemProfileConfigPath"
        }
    } else {
        Write-Log -Level INFO -Message "No SYSTEM-profile fallback config present, skipping."
    }

    # --- Sweep per-user vhui.ini fallback files ------------------------------
    if (-not $SkipUserConfigSweep) {
        Write-Log -Level INFO -Message "Sweeping per-user vhui.ini fallback files under C:\Users..."
        $userConfigs = Get-ChildItem -Path "C:\Users\*\AppData\Roaming\vhui.ini" -Force -ErrorAction SilentlyContinue
        if ($userConfigs) {
            foreach ($cfg in $userConfigs) {
                Invoke-UninstallStep -Description "Remove '$($cfg.FullName)'" -Action {
                    Remove-Item -LiteralPath $cfg.FullName -Force -ErrorAction Stop
                    Write-Log -Level INFO -Message "Removed $($cfg.FullName)"
                }
            }
        } else {
            Write-Log -Level INFO -Message "No per-user vhui.ini files found, skipping."
        }
    }

    # --- Remove Start Menu shortcut ------------------------------------------
    $shortcutPath = Join-Path (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs") "$ShortcutName.lnk"
    Write-Log -Level INFO -Message "Checking Start Menu shortcut: $shortcutPath"
    if (Test-Path -LiteralPath $shortcutPath) {
        Invoke-UninstallStep -Description "Remove Start Menu shortcut" -Action {
            Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
            Write-Log -Level INFO -Message "Removed $shortcutPath"
        }
    } else {
        Write-Log -Level INFO -Message "No Start Menu shortcut present, skipping."
    }

    if ($script:hadWarnings) {
        Write-Log -Level WARN -Message "Uninstall completed with warnings - see above for which step(s) failed."
        exit 50
    } else {
        Write-Log -Level INFO -Message "Uninstall complete. VirtualHere client service, files, and shortcut removed."
        exit 0
    }
}
catch {
    Write-Log -Level ERROR -Message "Unhandled error: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    exit 99
}
