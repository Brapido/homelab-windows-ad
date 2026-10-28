#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs AD DS and promotes this server to the first domain controller of a new forest.

.DESCRIPTION
    Installs the AD DS role and management tools, then creates a new forest.
    The Directory Services Restore Mode password is collected with
    Read-Host -AsSecureString and is confirmed before promotion. It is not a
    parameter, it is not written to disk by this script, and it is not the
    password you use to sign in.

    After you reboot and promotion finishes, sign in as the domain administrator
    with the password you set when Windows was installed. The DSRM password is
    only for Directory Services Restore Mode.

    The forest and domain functional level is Windows Server 2016. The parameter
    name is WinThreshold. Windows Server 2022 does not have a newer functional
    level.

    On success the script also sets DNS forwarders and creates the lab reverse
    lookup zone, then reboots. Pass -NoReboot to leave the reboot to you.
    -WhatIf does not install the role, does not prompt for a password, and does
    not promote the server.

    Run this only on the workgroup server that 01-Set-ServerBasics.ps1 prepared.
    Running it again after a successful promotion skips promotion and checks the
    forwarders and reverse zone.

.PARAMETER DomainName
    DNS name of the new forest. Default is lab.local.

.PARAMETER DomainNetbiosName
    NetBIOS name. When omitted, the first label of DomainName is used, uppercased.
    lab.local becomes LAB.

.PARAMETER ExpectedComputerName
    Active computer name required before promotion. Default is DC01.

.PARAMETER ExpectedIP
    IPv4 address that must already be configured. Default is 10.0.10.10.

.PARAMETER NetworkId
    Network used for the reverse lookup zone. Default is 10.0.10.0/24.
    Only a /24 is supported.

.PARAMETER Forwarder
    DNS forwarders for names outside the lab. Default is 1.1.1.1 and 8.8.8.8.
    These are not placed on the adapter.

.PARAMETER NoReboot
    Do not reboot after a successful promotion. The directory is not finished
    until the server reboots.

.EXAMPLE
    .\02-Install-ADDSForest.ps1 -WhatIf

    Shows the feature install and promotion. Does not ask for the DSRM password.

.EXAMPLE
    .\02-Install-ADDSForest.ps1

    Prompts for the DSRM password, creates lab.local, and reboots.

.EXAMPLE
    .\02-Install-ADDSForest.ps1 -DomainName corp.homelab.local -NoReboot

    Creates a different forest name. Decide this before the first promotion.
    The NetBIOS name defaults to CORP.

.NOTES
    Author: Briccio Rapido
    Run in elevated Windows PowerShell 5.1 on DC01, from the VirtualBox console.
    Promotion writes C:\Windows\debug\dcpromo.log. That log does not contain the
    DSRM password. Do not copy the password into a screenshot or into git.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$')]
    [string]$DomainName = 'lab.local',

    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$DomainNetbiosName,

    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$ExpectedComputerName = 'DC01',

    [string]$ExpectedIP = '10.0.10.10',

    [string]$NetworkId = '10.0.10.0/24',

    [string[]]$Forwarder = @('1.1.1.1', '8.8.8.8'),

    [switch]$NoReboot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Read-ConfirmedSecureString {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    $first = Read-Host -AsSecureString -Prompt $Prompt
    $second = Read-Host -AsSecureString -Prompt 'Confirm the password'

    $bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
    $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
    try {
        $text1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr1)
        $text2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
        $matches = $text1 -ceq $text2
        $length = $text1.Length
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
    }

    if (-not $matches) {
        throw 'The passwords did not match. Run the script again. Nothing was saved.'
    }
    if ($length -lt 8) {
        throw 'Use at least 8 characters. Directory Services will also enforce its complexity rules. Nothing was saved.'
    }

    return $first
}

function Get-LabReverseZoneName {
    param([Parameter(Mandatory = $true)][string]$Id)

    $split = $Id.Split('/')
    if ($split.Count -ne 2 -or $split[1] -ne '24') {
        throw "NetworkId must be a /24, for example 10.0.10.0/24. The value was '$Id'."
    }

    $octets = $split[0].Split('.')
    if ($octets.Count -ne 4) {
        throw "NetworkId '$Id' is not an IPv4 network."
    }

    return ('{0}.{1}.{2}.in-addr.arpa' -f $octets[2], $octets[1], $octets[0])
}

function Set-LabDnsSupport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string[]]$Resolver
    )

    Import-Module DnsServer
    $zoneName = Get-LabReverseZoneName -Id $Id

    $existingForwarders = @()
    $forwarderConfig = Get-DnsServerForwarder
    if ($forwarderConfig.IPAddress) {
        $existingForwarders = @($forwarderConfig.IPAddress | ForEach-Object { $_.ToString() })
    }

    $forwardersMatch = ($existingForwarders -join ',') -eq ($Resolver -join ',')
    if ($forwardersMatch) {
        Write-Host "DNS forwarders already set: $($Resolver -join ', ')"
    }
    elseif ($PSCmdlet.ShouldProcess(($Resolver -join ', '), 'Set DNS forwarders')) {
        Set-DnsServerForwarder -IPAddress $Resolver | Out-Null
        Write-Host "DNS forwarders set to $($Resolver -join ', ')."
    }

    $zone = Get-DnsServerZone | Where-Object { $_.ZoneName -eq $zoneName }
    if ($zone) {
        Write-Host "Reverse lookup zone already exists: $zoneName"
    }
    elseif ($PSCmdlet.ShouldProcess($zoneName, 'Create AD-integrated reverse lookup zone')) {
        Add-DnsServerPrimaryZone -NetworkID $Id -ReplicationScope Forest -DynamicUpdate Secure | Out-Null
        Write-Host "Created reverse lookup zone $zoneName."
    }

    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Register DNS records for this server')) {
        & ipconfig.exe /registerdns | Out-Null
        Write-Host 'Registered this server in DNS. The PTR record can take a moment to appear.'
    }
}

if (-not $PSBoundParameters.ContainsKey('DomainNetbiosName')) {
    $DomainNetbiosName = $DomainName.Split('.')[0].ToUpper()
}
else {
    $DomainNetbiosName = $DomainNetbiosName.ToUpper()
}

if ($DomainNetbiosName.Length -gt 15) {
    throw "NetBIOS name '$DomainNetbiosName' is longer than 15 characters."
}

if (-not (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)) {
    throw 'Get-WindowsFeature is not available. Run this script on Windows Server, in Windows PowerShell 5.1.'
}

$activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
$pendingName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
if ($activeName -ne $ExpectedComputerName) {
    if ($pendingName -eq $ExpectedComputerName) {
        throw "The rename to $ExpectedComputerName is still pending. Reboot, sign in, and run this script again."
    }
    throw "Computer name is '$activeName'. Run .\01-Set-ServerBasics.ps1 so the active name is $ExpectedComputerName, then reboot."
}

$haveIp = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $ExpectedIP })
if ($haveIp.Count -eq 0) {
    throw "This server does not have $ExpectedIP yet. Run .\01-Set-ServerBasics.ps1 first."
}

$ipInterface = Get-NetIPInterface -InterfaceIndex $haveIp[0].InterfaceIndex -AddressFamily IPv4
if ($ipInterface.Dhcp -ne 'Disabled') {
    throw "The adapter that holds $ExpectedIP is still using DHCP. Run .\01-Set-ServerBasics.ps1 first."
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystem
if ($computer.DomainRole -ge 4) {
    if ($computer.Domain -ne $DomainName) {
        throw "This host is already a domain controller for $($computer.Domain), not for $DomainName."
    }

    Write-Host "Already a domain controller for $DomainName. Checking DNS forwarders and the reverse zone."
    Set-LabDnsSupport -Id $NetworkId -Resolver $Forwarder -WhatIf:$WhatIfPreference
    Write-Host 'Next: run .\03-Configure-DHCP.ps1 after you have turned VirtualBox DHCP off.'
    return
}

if ($computer.PartOfDomain) {
    throw "This server is joined to $($computer.Domain) as a member. This script only creates a new forest on a workgroup server."
}

$feature = Get-WindowsFeature -Name AD-Domain-Services
$featureReady = [bool]$feature.Installed
if (-not $featureReady) {
    if ($PSCmdlet.ShouldProcess('AD-Domain-Services', 'Install the AD DS role and management tools')) {
        $install = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        if ($install.RestartNeeded -eq 'Yes') {
            Write-Warning 'Windows needs a reboot before promotion. Reboot, then run this script again.'
            return
        }
        $featureReady = $true
        Write-Host 'AD DS role installed.'
    }
}
else {
    Write-Host 'AD DS role is already installed.'
}

$promoted = $false
$promote = $PSCmdlet.ShouldProcess($DomainName, "Create forest $DomainName ($DomainNetbiosName) and promote $ExpectedComputerName")
if ($featureReady -and $promote) {
    Write-Host 'Enter a Directory Services Restore Mode password. This is not your sign-in password, and it will not be stored in the repo.'
    $dsrmPassword = Read-ConfirmedSecureString -Prompt 'DSRM password'

    # WinThreshold is the Windows Server 2016 functional level, the highest
    # level Server 2022 can use. -Force answers the cmdlet confirmation. It
    # does not skip the promotion health checks.
    $forestParams = @{
        DomainName                    = $DomainName
        DomainNetbiosName             = $DomainNetbiosName
        DomainMode                    = 'WinThreshold'
        ForestMode                    = 'WinThreshold'
        InstallDns                    = $true
        CreateDnsDelegation           = $false
        DatabasePath                  = 'C:\Windows\NTDS'
        LogPath                       = 'C:\Windows\NTDS'
        SysvolPath                    = 'C:\Windows\SYSVOL'
        SafeModeAdministratorPassword = $dsrmPassword
        NoRebootOnCompletion          = $true
        Force                         = $true
    }

    try {
        Install-ADDSForest @forestParams
    }
    catch {
        throw "Promotion failed. Review C:\Windows\debug\dcpromo.log. $($_.Exception.Message)"
    }

    $promoted = $true
    Write-Host "Forest $DomainName was created. A reboot is required before the domain controller is usable."
    Write-Host "After the reboot, sign in as $DomainNetbiosName\Administrator with the Windows administrator password from setup. Do not use the DSRM password for that sign-in."
}

if ($promoted) {
    try {
        Set-LabDnsSupport -Id $NetworkId -Resolver $Forwarder -WhatIf:$WhatIfPreference
    }
    catch {
        Write-Warning "Promotion succeeded, but DNS forwarders or the reverse zone could not be set before reboot. Run this script again after reboot. $($_.Exception.Message)"
    }
}

if (-not $featureReady) {
    Write-Host 'Promotion was not started.'
    return
}

if ($promoted -and -not $NoReboot) {
    if ($PSCmdlet.ShouldProcess($ExpectedComputerName, 'Restart to finish domain controller promotion')) {
        Write-Host 'Restarting in 15 seconds. Press Ctrl+C to cancel.'
        Start-Sleep -Seconds 15
        Restart-Computer -Force
    }
}
elseif ($promoted) {
    Write-Host 'Reboot this server before you run .\03-Configure-DHCP.ps1. -NoReboot left that reboot to you.'
}
else {
    Write-Host 'No promotion was performed.'
}
