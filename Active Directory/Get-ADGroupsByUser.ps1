<#
.SYNOPSIS
    Returns a list of AD group memberships

.DESCRIPTION
    This script is used during user onboarding and for general use. It can be used to search the security groups that a reference user is assigned.

.PARAMETER Username
    Stringified name of target user

.EXAMPLE
    Get-ADGroupByUser.ps1 -Username "BFoster"

#>

#TODO: Modify to classify each by OU (i.e. to separate security groups and distro groups)

param(
    [Parameter(Mandatory)]
    [string]$Username
)

# Get and sort AD group memberships
$groups = Get-ADUser $Username -Properties MemberOf | Select-Object -ExpandProperty MemberOf | Get-ADGroup | Sort-Object -Property Name

$secGroups = @()
$distroGroups = @()
$uncatGroups = @()

foreach ($group in $groups) {
    $parentOU = $group.DistinguishedName -replace '^CN=[^,]+,OU=([^,]+),.+', '$1'
    if ($parentOU -eq "Security Groups" -or $parentOU -eq "DB Security Groups") {
        $secGroups += $group.Name
    } elseif ($parentOU -eq "DISTRO GROUPS") {
        $distroGroups += $group.Name
    } else {
        $uncatGroups += "$($group.Name) ($parentOU)"
    }
}
Write-Output ""
Write-Output "Security groups:"
foreach ($group in $secGroups) {
    Write-Output $group
}

Write-Output ""
Write-Output "Distro groups:"
foreach ($group in $distroGroups) {
    Write-Output $group
}

Write-Output ""
Write-Output "Other groups:"
foreach ($group in $uncatGroups) {
    Write-Output "$($group)"
}