#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Uninstalls the VirtualHere USB Client, its Start Menu shortcut, and relevant configuration files
.NOTES
    Run elevated (requires access to Program Files and the All Users Start Menu).
#>

# Remove Start Menu Program link at C:\ProgramData\Microsoft\Windows\Start Menu\Programs\VirtualHere Client.lnk

# Remove executable at C:\Program Files\VirtualHere\vhui64.exe

# Remove user-level configuration file at C:\Users\<username>\AppData\Roaming\vhui.ini

# Remove windows service
# Get windows service name
$ServiceName = $(Get-Service -Name "vhclient").Name

# Delete Service
sc.exe delete $ServiceName

# Remove Windows service configuration file at C:\Windows\System32\config\systemprofile\AppData\Roaming\vhui.ini