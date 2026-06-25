#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Retrieves the status of a scheduled task on a list of Windows machines.

.DESCRIPTION
    Invokes remote search on specified machines to determine the presence of a scheduled task.

.PARAMETER TaskName
    Target task name for which to search (i.e. "IntuneReset-Reboot").

.PARAMETER MachineList
    List of string computer names to query for the target task name (i.e. "Spare03-V11").

.PARAMETER Remove
    [Optional] Switch to initiate removal of scheduled task on target machines.

.EXAMPLE
    Get-ScheduledTask.ps1 -TaskName "IntuneReset-Reboot" -MachineList "Spare03-V11","BFoster-V11","NDetullio-V11"

.EXAMPLE
    Get-ScheduledTask.ps1 -TaskName "IntuneReset-Reboot" -MachineList "Spare03-V11","BFoster-V11","NDetullio-V11" -Remove

.EXAMPLE
    $machines = @(
        "Spare03-V11",
        "BFoster-V11",
        "NDetullio-V11"
    )
    Get-ScheduledTask.ps1 -TaskName "IntuneReset-Reboot" -MachineList $machines
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$TaskName,

    [Parameter(Mandatory=$true)]
    [string[]]$MachineList,

    [Parameter()]
    [switch]$Remove
)

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host "Searching target machines for task named $TaskName"

$i = 1
foreach ($machine in $MachineList) {
    try {
        $result = Invoke-Command -ComputerName $machine -ScriptBlock { Get-ScheduledTask -TaskName $Using:TaskName -ErrorAction SilentlyContinue}
        $Status = [PSCustomObject]@{
            Computer   = $machine
            Status     = "Not present"
        }

        if ($result) {
            $Status.Status = "Present"
        }

        $Results.Add($Status)

        if ($Remove) {
            try {
                Write-Host "Removing '$TaskName' on $machine"
                $result = Invoke-Command -ComputerName $machine -ScriptBlock { Unregister-ScheduledTask -TaskName $Using:TaskName -ErrorAction SilentlyContinue}
                if ($result) {
                    $Status.Status = "Removed"
                }
            } catch {
                $Status.Status = "Present - not removed"
                Write-Error "Error removing task: $($_.Exception)"
            }
        }
        
    } catch {
        Write-Error $_.Exception
        Write-Host "Skipping $machine..." -ForegroundColor Yellow
    } finally {
        $percent = ($i / $MachineList.Count) * 100

        Write-Progress -Activity "Processing machines" -Status "$percent% Complete" -CurrentOperation "Machine $i of $($MachineList.Count)" -PercentComplete $percent

        $i++
    }

}

Write-Host "`r`nResults for '$TaskName':"
$Results
