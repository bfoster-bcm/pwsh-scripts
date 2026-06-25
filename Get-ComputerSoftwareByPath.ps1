#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Reports if software exists based on path provided by user for collection of machines

.DESCRIPTION
    One may need to query a collection of computers for the existence of software based on that software's link. Use this script to do so

.PARAMETER MachineNames
    string: Array of machine names of which to query

.PARAMETER SoftwarePath
    string: Absolute path for software

.EXAMPLE
    Get-ComputerSoftwareByPath -MachineNames "BFoster-V11", "KMui-V11", "MJoung-V11" -SoftwarePath "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Bloomberg\Install Office Add-Ins.lnk"

#>

param (
    [Parameter(Mandatory)]
    [string[]]$MachineNames,
    [Parameter(Mandatory)]
    [string]$SoftwarePath
)

$results = foreach ($machine in $MachineNames) {
    $status = [PSCustomObject]@{
        MachineName = $machine
        FileExists  = $false
        Error       = $null
    }

    try {
        $session = New-PSSession -ComputerName $machine -ErrorAction Stop

        $exists = Invoke-Command -Session $session -ScriptBlock {
            Test-Path $using:SoftwarePath
        }

        $status.FileExists = $exists
        Remove-PSSession $session
    }
    catch {
        $status.Error = $_.Exception.Message
    }

    $status
}

return $results