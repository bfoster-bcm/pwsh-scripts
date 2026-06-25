#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Retrieves a file from the same path on multiple remote computers via UNC admin share.

.DESCRIPTION
    Iterates a list of target computers, constructs a UNC path to the source file,
    and copies it to a local destination folder. Results are summarized at the end.

.NOTES
    Requires admin$ / C$ share access on target computers (typically domain admin or
    local admin rights). Run from a host with network access to all targets.
#>



# Computers to target
$Computers = @(
    "KAronson-V11",
    "LineData4-V11",
    "LineData8-V11",
    "LineData9-V11",
    "LineData11-V11",
    "LineData12-V11",
    "LineData13-V11",
    "LineData14-V11",
    "LineData15-V11",
    "LineData16-V11"
)

# Remote file path — the part after the drive letter.
# Example: "Windows\System32\drivers\etc\hosts"
# This will be accessed as \\COMPUTER\C$\Windows\System32\drivers\etc\hosts
$RemoteDrive    = "C$"
$RemoteFilePath = "temp\intune-reset-logs.log"

# Local folder to copy files into (created if it doesn't exist)
$Destination    = "C:\Temp\RemoteFileCollection"

# Optional: alternate credentials (leave as $null to use current session credentials)
$Credential     = $null
# To prompt: $Credential = Get-Credential



$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Write-Host "Created destination folder: $Destination" -ForegroundColor Cyan
}

foreach ($Computer in $Computers) {
    $UNC    = "\\$Computer\$RemoteDrive\$RemoteFilePath"
    $Status = [PSCustomObject]@{
        Computer   = $Computer
        UNCPath    = $UNC
        Result     = $null
        Error      = $null
        Copied     = $null
    }

    Write-Host "`n[$Computer] Checking $UNC ..." -ForegroundColor Cyan

    try {
        # Rename the destination file to include the computer name, avoiding collisions
        $FileName      = [System.IO.Path]::GetFileNameWithoutExtension($RemoteFilePath)
        $Extension     = [System.IO.Path]::GetExtension($RemoteFilePath)
        $DestFile      = Join-Path $Destination "$FileName`_$Computer$Extension"

        $CopyParams = @{
            Path        = $UNC
            Destination = $DestFile
            Force       = $true
            ErrorAction = "Stop"
        }
        if ($Credential) { $CopyParams.Credential = $Credential }

        Copy-Item @CopyParams

        Write-Host "  [OK] Copied to $DestFile" -ForegroundColor Green
        $Status.Result = "Success"
        $Status.Copied = $DestFile

    } catch [System.IO.IOException] {
        $Msg = "File not found or inaccessible: $_"
        Write-Warning "  [FAIL] $Msg"
        $Status.Result = "Failed"
        $Status.Error  = $Msg

    } catch [System.UnauthorizedAccessException] {
        $Msg = "Access denied: $_"
        Write-Warning "  [FAIL] $Msg"
        $Status.Result = "Failed"
        $Status.Error  = $Msg

    } catch {
        $Msg = $_.Exception.Message
        Write-Warning "  [FAIL] $Msg"
        $Status.Result = "Failed"
        $Status.Error  = $Msg
    }

    $Results.Add($Status)
}



$Succeeded = $Results | Where-Object { $_.Result -eq "Success" }
$Failed    = $Results | Where-Object { $_.Result -eq "Failed" }

Write-Host "`n#### Summary ####" -ForegroundColor White
Write-Host "  Total   : $($Results.Count)"
Write-Host "  Success : $($Succeeded.Count)" -ForegroundColor Green
Write-Host "  Failed  : $($Failed.Count)"    -ForegroundColor $(if ($Failed.Count -gt 0) { "Red" } else { "White" })

if ($Failed.Count -gt 0) {
    Write-Host "`nFailed computers:" -ForegroundColor Red
    $Failed | ForEach-Object { Write-Host "  $($_.Computer) - $($_.Error)" -ForegroundColor Red }
}

Write-Host "`nFiles saved to: $Destination" -ForegroundColor Cyan
