<#
.SYNOPSIS
    Copy existing user's security group memberships to new user.

.DESCRIPTION
    This script is used during user onboarding. It directly copies all security groups from an existing user's account to a new user.

.PARAMETER NewUser
    Represents the new user's AD object

.PARAMETER ExistingUser
    Represents the existing user's AD object

.EXAMPLE
    $newUser = Get-ADUser "NUser"
    $existingUser = Get-ADUser "EUser"
    Match-ADSecGroups.ps1 -NewUser $newUser -ExistingUser $existingUser

#>
#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory)]
    [Microsoft.ActiveDirectory.Management.ADUser]$NewUser,

    [Parameter(Mandatory)]
    [Microsoft.ActiveDirectory.Management.ADUser]$ExistingUser
)

Import-Module ActiveDirectory -ErrorAction Stop

$existingUserGroups = Get-ADPrincipalGroupMembership -Identity $ExistingUser |
    Where-Object {
        $_.GroupCategory -eq 'Security' -and
        $_.Name -ne 'Domain Users'-and
        $_.DistinguishedName -notlike '*DISTRO GROUPS*'
    }

foreach ($group in $existingUserGroups) {
    try {
        Add-ADGroupMember `
            -Identity $group.DistinguishedName `
            -Members $NewUser.DistinguishedName `
            -ErrorAction Stop

        Write-Host "Added $($NewUser.SamAccountName) to $($group.Name)"
    }
    catch {
        Write-Warning "Failed to add $($NewUser.SamAccountName) to $($group.Name): $($_.Exception.Message)"
    }
}
