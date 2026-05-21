function Get-Name {
    $rawFirst = Read-Host -Prompt "Enter user's first name"
    $rawLast = Read-Host -Prompt "Enter user's last name"

    $firstName = $rawFirst[0].ToString().ToUpper() + $rawFirst.Substring(1)
    $lastName = $rawLast[0].ToString().ToUpper() + $rawLast.Substring(1)


    $domain = "brigadecapital.com"

    $userName = "$($firstName[0])$lastName@$domain"

    return $userName
}
