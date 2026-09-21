#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs the VirtualHere USB Client and creates a Start Menu shortcut.
.NOTES
    Run elevated (writes to Program Files and the All Users Start Menu).
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\Program Files\VirtualHere",
    [string]$SourceUrl  = "https://www.virtualhere.com/sites/default/files/usbclient/vhui64.exe",
    [string]$ExeName    = "vhui64.exe",
    [string]$ShortcutName = "VirtualHere Client"
)

$ErrorActionPreference = "Stop"

# Enforce TLS 1.2 (avoids handshake failures behind SSL-decrypting proxies/firewalls)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    # 1. Ensure install directory exists
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Write-Verbose "Created directory: $InstallDir"
    }

    $exePath = Join-Path $InstallDir $ExeName

    # 2. Download the client
    Write-Verbose "Downloading $SourceUrl to $exePath"
    Invoke-WebRequest -Uri $SourceUrl -OutFile $exePath -UseBasicParsing

    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Download failed - file not found at $exePath"
    }

    # 3. Create Start Menu shortcut (All Users)
    $startMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    $shortcutPath = Join-Path $startMenuDir "$ShortcutName.lnk"

    $wshShell  = New-Object -ComObject WScript.Shell
    $shortcut  = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $exePath
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Description      = "VirtualHere USB Client"
    $shortcut.IconLocation     = "$exePath,0"
    $shortcut.Save()

    Write-Host "VirtualHere Client installed to: $exePath"
    Write-Host "Start Menu shortcut created at: $shortcutPath"

    #TODO: Connect to USB Server (Raspberry Hub: 192.168.15.159:7575)

    #TODO:  Set auto-connect to specific device (optional)
}
catch {
    Write-Error "Installation failed: $_"
    exit 1
}