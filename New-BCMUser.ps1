class NewUserDetails {
    [string] $FirstName
    [string] $LastName
    [string] $DisplayName
    [string] $UserName

    NewUserDetails(
        [string] $firstName,
        [string] $lastName
    ) {
        $formattedFirst = $firstName[0].ToString().ToUpper() + $firstName.Substring(1)
        $formattedLast = $lastName[0].ToString().ToUpper() + $lastName.Substring(1)

        $this.FirstName        = $formattedFirst
        $this.LastName         = $formattedLast
        $this.DisplayName      = "$formattedFirst $formattedLast"
        $this.UserName         = "$($formattedFirst[0])$formattedLast"
    }
}


function Get-UserDetails {
    [OutputType([NewUserDetails])]
    $rawFirst = Read-Host -Prompt "Enter user's first name"
    $rawLast = Read-Host -Prompt "Enter user's last name"

    $user = [NewUserDetails]::new($rawFirst, $rawLast)

    return $user
}

function Is-ExistingUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Username
    )

    $existing = Get-Recipient -Identity $Username -ErrorAction SilentlyContinue

    if ($existing) {
        return $true
    }

    return $false
}

function New-BCMUser {
    param(
        [Parameter(Mandatory = $true)]
        [NewUserDetails]$Details
    )

    $newUpn = "$($Details.UserName)@brigadecapital.com"
    $newRemoteRoutingAddress = "$($Details.UserName)@brigadecapital.mail.onmicrosoft.com"
    $ou = "OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com"
    # If user with the same UPN already exists, exit. Otherwise, create new user in Exchange
    $IsExistingUser = Is-ExistingUser -Username $newUpn
    if ($IsExistingUser) {
        throw "User with UPN of '$newUpn' already exists"
    }
    Write-Host "Creating user object for '$($Details.DisplayName)':"
    Write-Host "Name: $($Details.DisplayName)"
    Write-Host "UPN: $newUpn"
    Write-Host "OU: $ou"
    Write-Host "Remote routing address: $newRemoteRoutingAddress"
    Write-Host "Reset pwd on next login: $false"
    
    $mailbox = New-RemoteMailbox -Name "Test User" `
        -FirstName $Details.FirstName `
        -LastName $Details.LastName `
        -DisplayName $Details.DisplayName `
        -UserPrincipalName $newUpn `
        -OnPremisesOrganizationalUnit $ou `
        -Password (ConvertTo-SecureString "HelloHappyLine26!" -AsPlainText -Force) `
        -ResetPasswordOnNextLogon $false `
        -RemoteRoutingAddress $newRemoteRoutingAddress
    
    return $mailbox
}

# MAIN EXECUTION

# Enforce execution from elevated prompt
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "You must run this script from an elevated prompt as an Exchange-privileged admin..." -ForegroundColor Red
        exit
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

    $newMailbox
    
}
catch {
    throw
}
finally {
    Remove-PSSession -Id $ExchangeSession.Id
}

