#Requires -RunAsAdministrator

#TODO: definitely need some logging mechanism


$date = Get-Date -Format "yyyyMMdd"

# Back up registry
Write-Host "Backing up Windows HKLM before modifications"
$bu_dir = New-Item -Path "C:\temp\RegistryBackups\$date" -ItemType Directory -Force

reg export HKLM "$bu_dir\HKLM_Backup.reg" /y | Out-Null

# Remove scheduled tasks for enrollments
$tasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*"
$taskPaths = $tasks.TaskPath
$taskset = [System.Collections.Generic.HashSet[string]]::new([string[]]$taskPaths) # need to cast $taskPaths to string array in order to get set to work
$taskset.Remove("\Microsoft\Windows\EnterpriseMgmt\") | Out-Null # do not remove the parent EnterpriseMgmt level

# Prompt for confirmation key removal confirmation
Write-Host ""
Write-Host "The following Intune Enrollment task folders found in Task scheduler. These folders and all child tasks will be deleted:"-ForegroundColor Yellow
foreach ($task in $taskset) {
    Write-Host $task
}
$taskresult = Read-Host -Prompt "`r`nType [y] to remove parent and all children tasks (any other key will end script)"
if ($taskresult.ToLower() -ne "y") {
    Write-Host "Canceling script execution..."
    exit 0
}

foreach ($task in $taskset) {
    try {
        # Remove tasks in folder
        Write-Host "Removing tasks at $task"
        Get-ScheduledTask -TaskPath $task | Unregister-ScheduledTask -Confirm:$False -WhatIf

        # Remove empty folder
        $folder_guid = Split-Path -Path $task -Leaf
        $sc = New-Object -ComObject Schedule.Service
        $sc.Connect()
        $root = $sc.GetFolder("\Microsoft\Windows\EnterpriseMgmt")
        ($root.GetTasks(1)).Path # comment this line out after testing - this line proves we're connected to the right tasks folder
        #$root.DeleteFolder($folder_guid, 0) # uncomment for production use
    } catch {
        Write-Error "Error: $($_.Exception)"
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
                Remove-Item -Path $keyPath -Recurse -WhatIf
            }
        } catch {
            Write-Error "Error removing registry key: $($_.Exception)."
        }
        
    }
}


# Remove certificates pertaining to Intune Enrollment
$certs = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Issuer -like "CN=Microsoft Intune MDM Device CA" -or $_.Issuer -like "CN=Microsoft Intune Device Management Device CA"  }

foreach ($cert in $certs) {
	Write-Host "Deleting certificate $($cert.Thumbprint) from issuer: $($cert.Issuer)"
	try {
		Remove-Item -Path $cert.PSPath -WhatIf
        Write-Host "Successfully deleted certificate $($cert.Thumbprint) from issuer: $($cert.Issuer)"
	} catch {
		Write-Error "Error deleting certificate $($cert.Thumbprint) from issuer: $($cert.Issuer): $($_.Exception)." 
	}
}

Write-Host "Be sure to manually remove tasks, registry keys, and certificates that may have failed." -ForegroundColor Yellow
Write-Host "Script complete! Please reboot at your earliest convenience. Once rebooted, run 'dsregcmd /join' from an elevated prompt."