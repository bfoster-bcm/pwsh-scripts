Import-Module ExchangeOnlineManagement

if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
    Connect-ExchangeOnline -UserPrincipalName bfoster@brigadecapital.com
}


# Prompt for username/email
$user = Read-Host "Enter username or email address"

# Resolve recipient
$recipient = Get-Recipient $user

# Get all groups/shared mailboxes the user is a member of
Get-Recipient -ResultSize Unlimited |
    Where-Object {
        $_.RecipientTypeDetails -in @(
            "MailUniversalDistributionGroup",
            "MailUniversalSecurityGroup",
            "GroupMailbox",
            "SharedMailbox"
        )
    } |
    ForEach-Object {

        $obj = $_

        try {
            $members = Get-DistributionGroupMember $obj.Identity -ResultSize Unlimited -ErrorAction Stop

            if ($members.PrimarySmtpAddress -contains $recipient.PrimarySmtpAddress) {
                [PSCustomObject]@{
                    Name                 = $obj.DisplayName
                    EmailAddress         = $obj.PrimarySmtpAddress
                    RecipientTypeDetails = $obj.RecipientTypeDetails
                }
            }
        }
        catch {
            # Shared mailboxes use mailbox permissions instead
            if ($obj.RecipientTypeDetails -eq "SharedMailbox") {

                $permissions = Get-EXOMailboxPermission $obj.Identity |
                    Where-Object {
                        $_.User -eq $recipient.Name -and
                        $_.AccessRights -match "FullAccess"
                    }

                if ($permissions) {
                    [PSCustomObject]@{
                        Name                 = $obj.DisplayName
                        EmailAddress         = $obj.PrimarySmtpAddress
                        RecipientTypeDetails = $obj.RecipientTypeDetails
                    }
                }
            }
        }
    } |
    Sort-Object RecipientTypeDetails, Name