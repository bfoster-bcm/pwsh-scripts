#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstalls the VirtualHere USB client: stops and removes the Windows
    service, deletes the install directory (binary + config.ini), sweeps up
    any per-user/SYSTEM-profile vhui.ini fallback files, and removes the
    Start Menu shortcut.

.NOTES
    - Must be run from an elevated PowerShell session.
    - Every step is best-effort and idempotent: if a given piece (service,
      folder, shortcut, fallback ini) is already gone, that step is skipped
      with a status message rather than treated as an error, so this script
      is safe to re-run.
    - Mirrors Install-VirtualHereClient.ps1's install locations/paths.

.EXAMPLE
    .\Uninstall-VirtualHereClient.ps1
#>

[CmdletBinding()]
param(
    [string]$InstallDir              = "C:\Program Files\VirtualHere",
    [string]$ShortcutName            = "VirtualHere Client",
    [string]$ServiceNamePattern      = "vhclient*",
    [string]$SystemProfileConfigPath = "C:\Windows\System32\config\systemprofile\AppData\Roaming\vhui.ini",
    [switch]$SkipUserConfigSweep
)

$hadWarnings = $false

# --- Stop and remove the Windows service ------------------------------------
Write-Host "Checking for VirtualHere service ('$ServiceNamePattern')..."
$svc = Get-Service -Name $ServiceNamePattern -ErrorAction SilentlyContinue
if ($svc) {
    $serviceName = $svc.Name
    Write-Host "Found service '$serviceName' (Status: $($svc.Status)). Stopping..."
    try {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
        }
    } catch {
        Write-Warning "Could not stop service '$serviceName' cleanly: $($_.Exception.Message). Attempting deletion anyway."
        $hadWarnings = $true
    }

    $wmiSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
    if ($wmiSvc) {
        $deleteResult = Invoke-CimMethod -InputObject $wmiSvc -MethodName Delete
        if ($deleteResult.ReturnValue -ne 0) {
            Write-Warning "Win32_Service.Delete() for '$serviceName' returned code $($deleteResult.ReturnValue). It may be marked pending deletion until all handles (e.g. an open services.msc) are released."
            $hadWarnings = $true
        }
    }

    # Deletion can be deferred until the last handle closes (e.g. Services
    # console open elsewhere) -- poll briefly rather than assuming it's gone.
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
        Write-Warning "Service '$serviceName' is still listed after Delete() -- likely marked pending deletion. It will disappear once other handles to it (e.g. an open Services console) are closed, or after a reboot."
        $hadWarnings = $true
    } else {
        Write-Host "Service '$serviceName' removed."
    }
} else {
    Write-Host "No VirtualHere service found - already removed, skipping."
}

# --- Remove install directory (binary + config.ini) -------------------------
Write-Host "`nRemoving install directory: $InstallDir"
if (Test-Path -LiteralPath $InstallDir) {
    try {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        Write-Host "Removed $InstallDir"
    } catch {
        Write-Warning "Failed to remove '$InstallDir': $($_.Exception.Message). It may be in use by a still-running vhui64.exe process -- close it and re-run this script."
        $hadWarnings = $true
    }
} else {
    Write-Host "Install directory not present - already removed, skipping."
}

# --- Remove the SYSTEM-profile fallback config (used when -c wasn't wired) --
Write-Host "`nChecking for SYSTEM-profile fallback config: $SystemProfileConfigPath"
if (Test-Path -LiteralPath $SystemProfileConfigPath) {
    try {
        Remove-Item -LiteralPath $SystemProfileConfigPath -Force -ErrorAction Stop
        Write-Host "Removed $SystemProfileConfigPath"
    } catch {
        Write-Warning "Failed to remove '$SystemProfileConfigPath': $($_.Exception.Message)"
        $hadWarnings = $true
    }
} else {
    Write-Host "No SYSTEM-profile fallback config present, skipping."
}

# --- Sweep per-user vhui.ini files (created by the interactive GUI mode) ----
if (-not $SkipUserConfigSweep) {
    Write-Host "`nSweeping per-user vhui.ini fallback files under C:\Users\..."
    $userConfigs = Get-ChildItem -Path "C:\Users\*\AppData\Roaming\vhui.ini" -Force -ErrorAction SilentlyContinue
    if ($userConfigs) {
        foreach ($cfg in $userConfigs) {
            try {
                Remove-Item -LiteralPath $cfg.FullName -Force -ErrorAction Stop
                Write-Host "Removed $($cfg.FullName)"
            } catch {
                Write-Warning "Failed to remove '$($cfg.FullName)': $($_.Exception.Message)"
                $hadWarnings = $true
            }
        }
    } else {
        Write-Host "No per-user vhui.ini files found, skipping."
    }
}

# --- Remove Start Menu shortcut ----------------------------------------------
$shortcutPath = Join-Path (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs") "$ShortcutName.lnk"
Write-Host "`nChecking for Start Menu shortcut: $shortcutPath"
if (Test-Path -LiteralPath $shortcutPath) {
    try {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
        Write-Host "Removed $shortcutPath"
    } catch {
        Write-Warning "Failed to remove '$shortcutPath': $($_.Exception.Message)"
        $hadWarnings = $true
    }
} else {
    Write-Host "No Start Menu shortcut present, skipping."
}

if ($hadWarnings) {
    Write-Warning "`nUninstall completed with warnings - review the messages above before considering this machine fully clean."
} else {
    Write-Host "`nUninstall complete. VirtualHere client service, files, and shortcut removed."
}
