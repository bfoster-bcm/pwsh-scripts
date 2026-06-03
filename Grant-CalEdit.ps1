#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Adds user as an editor to target calendar

.DESCRIPTION
    Grant editor access to a target calendar.

.PARAMETER Calendar
    Calendar address for target calendar (i.e. "hjones@brigadecapital.com:\Calendar")

.PARAMETER Grantee
    Email address of the user you're granting editor access to (i.e. "cpakenham@brigadecapital.com").

.EXAMPLE
    Grant-CalEdit.ps1 -Calendar "hjones@brigadecapital.com:\Calendar" -Grantee "cpakenham@brigadecapital.com"
#>


# calendar"hjones@brigadecapital.com:\Calendar"
# grantee: "cpakenham@brigadecapital.com"

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]
    $Calendar,

    [Parameter(Mandatory=$true)]
    [string]
    $Grantee
)

try {
    # Set up connection to on-prem exchange server.
    $AdminUsername = $env:USERNAME
    $AdminUserCred = Get-Credential $AdminUsername
    $ExchangeConnectionUri = "http://njinf-exch01.corp.brigadecapital.com/PowerShell/"
    try {
        $ExchangeSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri $ExchangeConnectionUri -Credential $AdminUserCred -Authentication Kerberos -ErrorAction Stop
        Import-PSSession $ExchangeSession -DisableNameChecking | Out-Null
    }
    catch {
        Write-Host "An error occurred. Stopping script..." -ForegroundColor Red
        throw 
    }

    Add-MailboxFolderPermission -Identity $Calendar -User $Grantee -AccessRights Editor
} catch {
    Write-Error "Error: $($_.Exception)"
} finally {
    Remove-PSSession -Id $ExchangeSession.Id
}