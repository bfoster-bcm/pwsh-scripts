<#
.SYNOPSIS
    Programatically diagnoses and restarts the Brigade Toolbar.

.DESCRIPTION
    This script looks to see if the Brigade Toolbar is already running and restarts it as necessary.

.PARAMETER Force
    Force restart regardless of current status.

.EXAMPLE
    Reset-BrigadeToolbar.ps1

.EXAMPLE
    Reset-BrigadeToolbar.ps1 -Force
#>

Param (
    [Parameter()]
    [switch]$Force
)

$toolbarPath = "S:\D IT\projects\ClickOnce\_InScopeApps\_BrigadeToolbar\v2.4\Brigade.Toolbar.exe"

class ForcedException : System.Exception {
    ForcedException() : base("Forced exception") {}
}

try {
    if ($Force) {
        throw [ForcedException]::new()
    }
    $proc = Get-Process -Name "Brigade.Toolbar" -ErrorAction Stop
    Write-Host "Brigade Toolbar already running (PID: $($proc.Id))" -ForegroundColor Green
} catch [ForcedException] {
    Write-Host "Forcing restart of Brigade Toolbar at $toolbarPath..."
    Stop-Process -Name "ProcessName" -Force -ErrorAction SilentlyContinue
    try {
        Start-Process "S:\D IT\projects\ClickOnce\_InScopeApps\_BrigadeToolbar\v2.4\Brigade.Toolbar.exe" -ErrorAction Stop
        $proc = Get-Process -Name "Brigade.Toolbar"
        Write-Host "Successfully started Brigade Toolbar (PID: $($proc.Id))" -ForegroundColor Green
        Write-Host "Don't forget to pin to taskbar as necessary."
    } catch {
        Write-Host "Error starting Brigade Toolbard: $($_.Exception.Message)" -ForegroundColor Red
    }
} catch {
    Write-Host "Brigade Toolbar not running" -ForegroundColor Yellow
    Write-Host "Attempting to restart Brigade Toolbar at $toolbarPath..."
    try {
        Start-Process "S:\D IT\projects\ClickOnce\_InScopeApps\_BrigadeToolbar\v2.4\Brigade.Toolbar.exe" -ErrorAction Stop
        $proc = Get-Process -Name "Brigade.Toolbar"
        Write-Host "Successfully started Brigade Toolbar (PID: $($proc.Id))" -ForegroundColor Green
        Write-Host "Don't forget to pin to taskbar as necessary."
    } catch {
        Write-Host "Error starting Brigade Toolbard: $($_.Exception.Message)" -ForegroundColor Red
    }
}