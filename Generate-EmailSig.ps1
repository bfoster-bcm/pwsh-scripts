$User = "rpierce"
$UserAttributes = Get-ADUser -Identity $User -Properties Name, Title, telephoneNumber, SamAccountName

$Name = $UserAttributes.Name
$Title = $UserAttributes.Title
if ($Title -contains "Junior" -or "Senior") {
    $Title = $Title -Replace "Junior", "Jr." 
    $Title = $Title -Replace "Senior", "Sr." 
}

$Extension = $UserAttributes.telephoneNumber.Substring($UserAttributes.telephoneNumber.Length-3, 3)
$Username = $UserAttributes.SamAccountName

$Signature=@"
<br>
<p style='margin:0in;font-size:12px;font-family:"Arial",sans-serif;color:#002060'>
<strong>$Name</strong>
<br>
<strong><span style='color:gray;'>$Title</span></strong>
<br>
<span style='font-size:11px;'>399 Park Avenue</span>&nbsp;|<span style='font-size:11px;'>&nbsp;16th Floor</span>&nbsp;|<span style='font-size:11px;'>&nbsp;New York, NY 10022</span>&nbsp;
<br>
<span style='font-size:11px;'>Work: (212) 745 9$Extension&nbsp;</span>&nbsp;|<span style='font-size:11px;'>&nbsp;Fax: (212) 745 9701</span>
<br>
<a href="mailto:$Username@brigadecapital.com">
<span style='font-size:11px;color:#002060'>
$Username@brigadecapital.com
</span>
</a>
</p>
"@


Write-Output $Signature | Out-File "C:\temp\Signature$User.html" 



 