#Requires -RunAsAdministrator

param(
    [string]$CsvPath
)

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
    [string] $M365License
    [string] $VdiPool

    static [string[]] $ValidLicenses = @("M365 E3 Licenses", "M365 E5 Unified License")
    static [string[]] $ValidVdiPools = @("ViewPool_PROD-PD01", "ViewPool_PROD-PD03")

    NewUserDetails(
        [string] $firstName,
        [string] $lastName
    ) {
        $ou = "OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com"
        $this.Init($firstName, $lastName, $ou, "", "")
    }

    NewUserDetails(
        [string] $firstName,
        [string] $lastName,
        [string] $OrgUnit
    ) {
        $this.Init($firstName, $lastName, $OrgUnit, "", "")
    }

    NewUserDetails(
        [string] $firstName,
        [string] $lastName,
        [string] $OrgUnit,
        [string] $m365License,
        [string] $vdiPool
    ) {
        $this.Init($firstName, $lastName, $OrgUnit, $m365License, $vdiPool)
    }

    hidden Init(
        [string] $firstName,
        [string] $lastName,
        [string] $OrgUnit,
        [string] $m365License,
        [string] $vdiPool
    ) {
        if ($m365License -and $m365License -notin [NewUserDetails]::ValidLicenses) {
            throw "Invalid M365_license '$m365License'. Must be one of: $([NewUserDetails]::ValidLicenses -join ', ')"
        }
        if ($vdiPool -and $vdiPool -notin [NewUserDetails]::ValidVdiPools) {
            throw "Invalid VDI_pool '$vdiPool'. Must be one of: $([NewUserDetails]::ValidVdiPools -join ', ')"
        }

        $formattedFirst = $firstName[0].ToString().ToUpper() + $firstName.Substring(1)
        $formattedLast = $lastName[0].ToString().ToUpper() + $lastName.Substring(1)

        $this.FirstName                = $formattedFirst
        $this.LastName                 = $formattedLast
        $this.DisplayName              = "$formattedFirst $formattedLast"
        $this.UserName                 = "$($formattedFirst[0])$formattedLast"
        $this.OrgUnit                  = $OrgUnit
        $this.Upn                      = "$($this.UserName)@$($this.Domain)"
        $this.RemoteRoutingAddress     = "$($this.UserName)@$($this.RemoteRouteDomain)"
        $this.M365License              = $m365License
        $this.VdiPool                  = $vdiPool
    }
}

function Get-NewPassword {
    [OutputType([string])]
    $pass = Read-Host -Prompt "Enter password for $($Details.DisplayName)" -AsSecureString
    return $pass
}


function Get-UserDetails {
    [OutputType([NewUserDetails])]
    $rawFirst = Read-Host -Prompt "Enter user's first name"
    $rawLast = Read-Host -Prompt "Enter user's last name"
    $OrgUnit = Read-Host "Enter OU [Default: OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com]"
    if (-not $OrgUnit) { $OrgUnit = "OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com" }

    $licensePrompt = "Enter M365 license [$([NewUserDetails]::ValidLicenses -join ' | ')]"
    do {
        $m365License = Read-Host $licensePrompt
    } while ($m365License -notin [NewUserDetails]::ValidLicenses)

    $poolPrompt = "Enter VDI pool [$([NewUserDetails]::ValidVdiPools -join ' | ')]"
    do {
        $vdiPool = Read-Host $poolPrompt
    } while ($vdiPool -notin [NewUserDetails]::ValidVdiPools)

    $user = [NewUserDetails]::new($rawFirst, $rawLast, $OrgUnit, $m365License, $vdiPool)

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

    try {
        if ($Details.M365License) {
            Add-ADGroupMember -Identity $Details.M365License -Members $Details.UserName
        } else {
            Write-Warning "M365 license not set for $($Details.DisplayName) - skipping license group assignment."
        }
        if ($Details.VdiPool) {
            Add-ADGroupMember -Identity $Details.VdiPool -Members $Details.UserName
        } else {
            Write-Warning "VDI pool not set for $($Details.DisplayName) - skipping VDI pool group assignment."
        }
    } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        Write-Warning "AD object for $($Details.DisplayName) not found yet - group memberships skipped. Assign manually once sync completes."
    }

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

    if ($CsvPath) {
        if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
            throw "CSV file not found: $CsvPath"
        }
        $csvUsers = Import-Csv -Path $CsvPath
        foreach ($row in $csvUsers) {
            try {
                $m365Lic = $row.M365_license.Trim()
                $vdiPool = $row.VDI_pool.Trim()
                $userDetails = [NewUserDetails]::new($row.firstName, $row.lastName, "OU=Users,OU=NY,OU=Brigade,DC=corp,DC=brigadecapital,DC=com", $m365Lic, $vdiPool)
                $newMailbox = New-BCMUser -Details $userDetails
                Write-Host "Successfully created mailbox for $($userDetails.DisplayName)" -ForegroundColor Green
                $newMailbox
            } catch {
                Write-Warning "Skipping $($row.firstName) $($row.lastName): $_"
            }
        }
    }
    else {
        # Collect new user details interactively
        $NewUserDetails = Get-UserDetails

        $newMailbox = New-BCMUser -Details $NewUserDetails

        Write-Host "Successfully created new user mailbox" -ForegroundColor Green
        $newMailbox
    }

    
}
catch {
    throw
}
finally {
    Remove-PSSession -Id $ExchangeSession.Id
}

