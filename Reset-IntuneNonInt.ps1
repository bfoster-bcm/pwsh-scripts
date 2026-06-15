#Requires -RunAsAdministrator

param (
    [Parameter(Mandatory)]
    [string]$LogPath
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    if ($LogPath) {
        $dir = Split-Path -Path $LogPath -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $line
    } else {
        Write-Host $line
    }
}

$date = Get-Date -Format "yyyyMMdd"

# Back up registry
Write-Log "Backing up Windows HKLM before modifications"
$bu_dir = New-Item -Path "C:\temp\RegistryBackups\$date" -ItemType Directory -Force

reg export HKLM "$bu_dir\HKLM_Backup.reg" /y | Out-Null

# Remove scheduled tasks for enrollments
$tasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*"
$taskPaths = $tasks.TaskPath
$taskset = [System.Collections.Generic.HashSet[string]]::new([string[]]$taskPaths) # need to cast $taskPaths to string array in order to get set to work
$taskset.Remove("\Microsoft\Windows\EnterpriseMgmt\") | Out-Null # do not remove the parent EnterpriseMgmt level

Write-Log "The following Intune Enrollment task folders found in Task Scheduler. These folders and all child tasks will be deleted:"
foreach ($task in $taskset) {
    Write-Log $task
}

foreach ($task in $taskset) {
    try {
        # Remove tasks in folder
        Write-Log "Removing tasks at $task"
        Get-ScheduledTask -TaskPath $task | Unregister-ScheduledTask -Confirm:$False

        # Remove empty folder
        $folder_guid = Split-Path -Path $task -Leaf
        $sc = New-Object -ComObject Schedule.Service
        $sc.Connect()
        $root = $sc.GetFolder("\Microsoft\Windows\EnterpriseMgmt")
        #($root.GetTasks(1)).Path # comment this line out after testing - this line proves we're connected to the right tasks folder
        $root.DeleteFolder($folder_guid, 0) # uncomment for production use
    } catch {
        Write-Log "Error: $($_.Exception)" -Level "ERROR"
    }
}

# Get array of enrollment ids from the Enrollment GUIDs captured in the previous steps
$enrollmentIds = @()
foreach ($task_path in $taskset) {
    $Id = Split-Path -Path $task_path -Leaf
    $enrollmentIds += $Id
}


$registryPathTemplates = @(
    "HKLM:\SOFTWARE\Microsoft\Enrollments\{0}"
    "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\{0}"
    "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\{0}"
    "HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled\{0}"
    "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\{0}"
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\{0}"
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\{0}"
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\{0}"
)

foreach ($id in $enrollmentIds) {
    foreach ($template in $registryPathTemplates) {
        try {
            $keyPath = $template -f $id
            if (Test-Path $keyPath) {
                Remove-Item -Path $keyPath -Recurse
                Write-Log "Successfully removed key at $keyPath"
            }
        } catch {
            Write-Log "Error removing registry key: $($_.Exception)." -Level "ERROR"
        }

    }
}


# Remove certificates pertaining to Intune Enrollment
$certs = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Issuer -like "CN=Microsoft Intune MDM Device CA" -or $_.Issuer -like "CN=Microsoft Intune Device Management Device CA"  }

foreach ($cert in $certs) {
    Write-Log "Deleting certificate $($cert.Thumbprint) from issuer: $($cert.Issuer)"
    try {
        Remove-Item -Path $cert.PSPath
        Write-Log "Successfully deleted certificate $($cert.Thumbprint) from issuer: $($cert.Issuer)"
    } catch {
        Write-Log "Error deleting certificate $($cert.Thumbprint) from issuer: $($cert.Issuer): $($_.Exception)." -Level "ERROR"
    }
}

# Schedule automatic reboot 30 minutes from now
Write-Log "Scheduling automatic reboot in 30 minutes"
try {
    $rebootTime = (Get-Date).AddMinutes(30)
    $rebootAction    = New-ScheduledTaskAction -Execute "shutdown.exe" -Argument "/r /t 0"
    $rebootTrigger   = New-ScheduledTaskTrigger -Once -At $rebootTime
    $rebootPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
    $rebootSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit "00:05:00"
    Register-ScheduledTask -TaskName "IntuneReset-Reboot" -Action $rebootAction -Trigger $rebootTrigger -Principal $rebootPrincipal -Settings $rebootSettings -Force -ErrorAction Stop | Out-Null
    Write-Log "Reboot task registered — system will restart at $rebootTime"
} catch {
    Write-Log "Failed to schedule reboot task: $($_.Exception)" -Level "ERROR"
}

# Schedule dsregcmd /join to run as SYSTEM at next logon (self-deletes after running)
Write-Log "Scheduling dsregcmd /join task to run at next logon"
try {
    $joinTaskName = "IntuneReset-DsregJoin"
    $joinArg      = "/c dsregcmd /join & schtasks /Delete /TN $joinTaskName /F"
    $joinAction   = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $joinArg
    $joinTrigger  = New-ScheduledTaskTrigger -AtLogOn
    $joinPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest -LogonType ServiceAccount
    $joinSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit "00:05:00"
    Register-ScheduledTask -TaskName $joinTaskName -Action $joinAction -Trigger $joinTrigger -Principal $joinPrincipal -Settings $joinSettings -Force -ErrorAction Stop | Out-Null
    Write-Log "dsregcmd /join task registered — will run as SYSTEM at next logon and self-delete"
} catch {
    Write-Log "Failed to schedule dsregcmd /join task: $($_.Exception)" -Level "ERROR"
}

Write-Log "Be sure to manually remove any tasks, registry keys, and certificates that may have failed."
Write-Log "Script complete! System will reboot automatically in 30 minutes. After reboot, dsregcmd /join will run automatically at next logon."
