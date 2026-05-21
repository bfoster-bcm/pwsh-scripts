<#
.SYNOPSIS
    Programatically generate email body for change management email

.DESCRIPTION
    This script generates the HTML body for a change management email based on a pre-configured application deployment in SCCM

.PARAMETER SiteCode
    (Optional) Defines the Configuration Manager site code targeted in the script
    Default: "BCM"

.PARAMETER ProviderMachineName
    (Optional) Defines the Configuration Manager Provider machine name targeted in the script
    Default: "NJINFRA-SCCM01.corp.brigadecapital.com"

.PARAMETER Apps
    List of strings for applications to search for in the deployment search

.PARAMETER AdminName
    List of strings for applications to search for in the deployment search


.EXAMPLE
    AppDeploymentEmailComputerV2.ps1 -Apps "7-Zip 26.01" -AdminName "B. Foster"

.EXAMPLE
    AppDeploymentEmailComputerV2.ps1 -Apps "7-Zip 26.01","Adobe Acrobat Reader DC 26.001.21431 Upd" -AdminName "B. Foster"
#>

param(
    [string]$SiteCode = "BCM",
    [string]$ProviderMachineName = "NJINFRA-SCCM01.corp.brigadecapital.com",
    [string[]]$Apps,
    [string]$AdminName
)

Import-Module ConfigurationManager

$OriginalLocation = (Get-Location).Path

if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName | Out-Null
}

Set-Location "$SiteCode`:"

Function Get-Clients {
    param(
		    [Parameter(Mandatory)]
		    [string]$Collection
        )	
        $CollectionRules = Get-CMCollection -Name $Collection | Select-Object -ExpandProperty CollectionRules
        if($CollectionRules.ResourceClassName.contains("SMS_R_UserGroup")){
            $CollectionADName = (Get-CMCollectionMember -Collectionname $Collection | Select-Object -expandproperty name).Split("\")[1]
            $Users = Get-ADGroupMember -Identity $CollectionADName | Select-Object -ExpandProperty SamAccountName | Sort-Object
            foreach ($User in $Users){
                get-cmuserdeviceaffinity -username "brigade\$($User)" | Select-Object -First 1 -ExpandProperty ResourceName
            }
        }
        elseif ($CollectionRules.ResourceClassName.contains("SMS_R_User")) {
            $Users = Get-CMCollectionMember -CollectionName $Collection | Select-Object -expandproperty SMSID | Sort-Object
            foreach ($User in $Users){
                get-cmuserdeviceaffinity -username $User | Select-Object -First 1 -ExpandProperty ResourceName
            }
        }
        else {
            (Get-CMCollectionMember -CollectionName $Collection | Select-Object -ExpandProperty Name) | Sort-Object
        }
}

Foreach($App in $Apps) {

    #Declare variables null
    $ClientHtml = $null
    $PatchHtml = $null

    #Get upcoming Sunday's date in MM/dd/yyyy format
    $MaintanenceSunday = (Get-Date -hour 0 -Minute 0 -Second 0).AddDays(7-((Get-Date).DayOfWeek.value__))
    $MaintenanceEnd = $MaintanenceSunday.AddHours(6)
    $MaintenenceSunday

    #Get upcoming Sunday's Application Deployment Object Authentic8 Silo 2.9.16.8 Adobe Acrobat Reader DC 21.005.20058 Upd
    $ApplicationDeployment = Get-CMDeployment -SoftwareName $App  | Where-Object {$_.EnforcementDeadline -gt $MaintenanceSunday -and $_.EnforcementDeadline -lt $MaintenanceEnd}

    # If a matching application deployment is not found, continue...
    if ($null -eq $ApplicationDeployment) {
        Write-Output "No application with the name '$App' found. Skipping..."
        continue
    }
    

    #Get deployment's collection 
    $CollectionName = $ApplicationDeployment.CollectionName

    #Another way to get collection member count
    $CollectionMemberCount = Get-CMCollection -Name $CollectionName | Select-object -ExpandProperty LocalMemberCount

    #Get deployments's application name, in this case the Software update group name
    $DeploymentName = $ApplicationDeployment.ApplicationName

    $DeploymentTime = $ApplicationDeployment.EnforcementDeadline.ToString("MM/dd/yyyy hh:mm:ss tt")

    $DeploymentTargets = $ApplicationDeployment.NumberTargeted
    #Get client names belonging to the collection
    $Clients = Get-Clients $ApplicationDeployment.CollectionName

    #Don't provide a full collection client output if collection has more than 30 clients 
    if($Clients.Count -gt 30) {
        $Clients = $PatchTuesdayDeployment.CollectionName     #TODO: Rectify this issue...no PatchTuesdayDeployment variable defined...will cause error if executed
    }else {    
        foreach ($Client in $Clients){$ClientHtml += "<br>$Client"}
    }


$Email=@"
<html> 
<body>
<b>What</b>: Deploy $DeploymentName to $CollectionName 
<br> <b>Why</b>: Software Distribution
<br> <b>When</b>: $DeploymentTime
<br> <b>Who</b>: $AdminName
<br>
<br><b>Collection: $CollectionName </b>($CollectionMemberCount)
$ClientHtml
</body>
</html>
"@

    #Create HTML file in below location
    Write-Output $Email | Out-File "C:\temp\$DeploymentName $App $(get-date -f MM-dd-yyyy).html"

    #"changecontrol@brigadecapital.com"
    #Send the Email
    #Send-mailmessage -to "changecontrol@brigadecapital.com"  -from "KMui@brigadecapital.com" -SmtpServer "relay.corp.brigadecapital.com" -Subject "Deploy $DeploymentName to $CollectionName" -body $Email -BodyAsHtml
}

Set-Location $OriginalLocation