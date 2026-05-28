#Requires -RunAsAdministrator

#TODO: Implement contact information data (street, city, zip, work phone, personal phone, etc.)
#TODO: Incorporate organizational data input like title, department, company, etc.)
class NewUserDetails {
    hidden [string] $FirstName
    hidden [string] $LastName
    [string] $DisplayName
    [string] $UserName
    hidden [string] $OrgUnit
    hidden [string] $Domain = "brigadecapital.com"
    hidden [string] $RemoteRouteDomain = "brigadecapital.mail.onmicrosoft.com"
    [string] $Upn
    [string] $RemoteRoutingAddress
    

    NewUserDetails(
        [string] $firstName,
        [string] $lastName
    ) {
        $ou = "OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com"
        $this.Init($firstName, $lastName, $ou)
    }

    NewUserDetails(
        [string] $firstName,
        [string] $lastName,
        [string] $OrgUnit
    ) {
        $this.Init($firstName, $lastName, $OrgUnit)
    }

    hidden Init(
        [string] $firstName,
        [string] $lastName,
        [string] $OrgUnit
    ) {
        $formattedFirst = $firstName[0].ToString().ToUpper() + $firstName.Substring(1)
        $formattedLast = $lastName[0].ToString().ToUpper() + $lastName.Substring(1)

        $this.FirstName                = $formattedFirst
        $this.LastName                 = $formattedLast
        $this.DisplayName              = "$formattedFirst $formattedLast"
        $this.UserName                 = "$($formattedFirst[0])$formattedLast"
        $this.OrgUnit                  = $OrgUnit
        $this.Upn                      = "$($this.UserName)@$($this.Domain)"
        $this.RemoteRoutingAddress     = "$($this.UserName)@$($this.RemoteRouteDomain)"
    }
}

function Get-NewPassword {
    [OutputType([string])]
    $pass = Read-Host -Prompt "Enter password for $($Details.DisplayName)" -AsSecureString
    return $pass
}


function Get-UserDetails {
    [OutputType([NewUserDetails])]
    $rawFirst = Read-Host -Prompt "Enter user's first namde"
    $rawLast = Read-Host -Prompt "Enter user's last name"
    $OrgUnit = Read-Host "Enter OU [Default: OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com]"
    if (-not $OrgUnit) { $OrgUnit = "OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com" }

    $user = [NewUserDetails]::new($rawFirst, $rawLast, $OrgUnit)

    return $user
}


function New-BCMUser {
    param(
        [Parameter(Mandatory = $true)]
        [NewUserDetails]$Details
    )
    
    $pass = Get-NewPassword

    $mailbox = New-RemoteMailbox -Name $Details.DisplayName `
        -FirstName $Details.FirstName `
        -LastName $Details.LastName `
        -DisplayName $Details.DisplayName `
        -UserPrincipalName $Details.Upn `
        -OnPremisesOrganizationalUnit $Details.OrgUnit `
        -Password $pass `
        -ResetPasswordOnNextLogon $false `
        -RemoteRoutingAddress $Details.RemoteRoutingAddress
    
    return $mailbox
}


try {
    # Set up connection to 
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

    # Collect new user details
    $NewUserDetails = Get-UserDetails

    $newMailbox = New-BCMUser -Details $NewUserDetails

    # print success message; if mailbox creation fails, it will be handled by the catch
    Write-Host "Successfully created new user mailbox" -ForegroundColor Green
    $newMailbox

    
}
catch {
    throw
}
finally {
    Remove-PSSession -Id $ExchangeSession.Id
}

