$User = "ENace"
$UserAttributes = Get-ADUser -Identity $User -Properties Name, Title, mobile, SamAccountName

$Name = $UserAttributes.Name
$Title = $UserAttributes.Title
if ($Title -contains "Junior" -or "Senior") {
    $Title = $Title -Replace "Junior", "Jr." 
    $Title = $Title -Replace "Senior", "Sr." 
}

$Mobile = $UserAttributes.mobile.Substring(3)
$Username = $UserAttributes.SamAccountName

$Signature=@"
<br>
<p style='margin:0in;font-size:12px;font-family:"Arial",sans-serif;color:#002060'>
<strong>$Name</strong>
<br>
<strong><span style='color:gray;'>$Title</span></strong>
<br>
<span style='font-size:11px;'>399 Park Avenue</span>&nbsp;|<span style='font-size:11px;'>&nbsp;15th Floor</span>&nbsp;|<span style='font-size:11px;'>&nbsp;New York, NY 10022</span>&nbsp;
<br>
<span style='font-size:11px;'>Mobile: $Mobile&nbsp;</span>&nbsp;|<span style='font-size:11px;'>&nbsp;Fax: (212) 745 9701</span>
<br>
<a href="mailto:$Username@brigadecapital.com">
<span style='font-size:11px;color:#002060'>
$Username@brigadecapital.com
</span>
</a>
</p>
"@


Write-Output $Signature | Out-File "C:\temp\Signature$User.html" 



 