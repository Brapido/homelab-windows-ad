#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Renames the future domain controller and assigns its lab static IPv4 address.

.DESCRIPTION
    Prepares the Windows Server that will become DC01. It sets one IPv4 address,
    default gateway, and DNS server, then renames the computer if needed.

    The DNS server list must be this server's own address. Public resolvers are
    not placed on the adapter. After promotion, 02-Install-ADDSForest.ps1 can
    add them as DNS forwarders instead. If Windows has a public DNS server on
    the adapter, it will use that server whenever the domain controller is slow,
    and domain name lookups will fail.

    Run this from the VirtualBox console. Changing the address of the adapter
    you are remoted in on will drop that session.

    The script is safe to run again. If the name, address, gateway, and DNS
    already match, it makes no changes. It will not rename a computer that is
    already joined to a domain, and it will not change the IP of a domain member.

.PARAMETER ComputerName
    New computer name. Default is DC01. Maximum length is 15 characters.

.PARAMETER IPAddress
    Static IPv4 address. Default is 10.0.10.10.

.PARAMETER PrefixLength
    IPv4 prefix length. Default is 24, which is 255.255.255.0.

.PARAMETER DefaultGateway
    IPv4 gateway. Default is 10.0.10.1, the VirtualBox NAT gateway for
    10.0.10.0/24. Confirm that address on the VirtualBox Network page, or with
    VBoxManage list natnetworks, before relying on it.

.PARAMETER DnsServer
    One or more IPv4 DNS servers. Default is 10.0.10.10. The list must include
    IPAddress and must not include a public resolver.

.PARAMETER InterfaceAlias
    Adapter to configure. If omitted, the script uses the only connected adapter
    and stops when more than one adapter is up.

.PARAMETER Restart
    Reboot after a rename is applied or is already pending. IP changes do not
    require a reboot. Without this switch the script tells you to reboot and
    leaves the machine running.

.EXAMPLE
    .\01-Set-ServerBasics.ps1 -WhatIf

    Shows the rename and network changes without applying them.

.EXAMPLE
    .\01-Set-ServerBasics.ps1 -Restart

    Applies the lab defaults and reboots if the name is not yet active.

.EXAMPLE
    .\01-Set-ServerBasics.ps1 -ComputerName DC01 -IPAddress 10.0.10.10 -PrefixLength 24 -DefaultGateway 10.0.10.1 -DnsServer 10.0.10.10

.NOTES
    Author: Briccio Rapido
    Run in elevated Windows PowerShell 5.1 on the server VM.
    This script does not contain a password.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$ComputerName = 'DC01',

    [string]$IPAddress = '10.0.10.10',

    [ValidateRange(1, 32)]
    [int]$PrefixLength = 24,

    [string]$DefaultGateway = '10.0.10.1',

    [string[]]$DnsServer = @('10.0.10.10'),

    [string]$InterfaceAlias,

    [switch]$Restart
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-LabIPv4Address {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '^(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}$') {
        return $false
    }

    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)
}

function Get-LabActiveComputerName {
    return (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
}

function Get-LabPendingComputerName {
    return (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
}

function Get-LabAdapter {
    param([string]$Name)

    if ($Name) {
        $adapter = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
        if (-not $adapter) {
            throw "No network adapter named '$Name' was found."
        }
        if ($adapter.Status -ne 'Up') {
            throw "Adapter '$Name' is $($adapter.Status). Attach it to the LabNet network and try again."
        }
        return $adapter
    }

    $connected = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    if ($connected.Count -eq 0) {
        throw 'No connected network adapter was found. Attach the VM to the LabNet network and try again.'
    }
    if ($connected.Count -gt 1) {
        $names = ($connected | ForEach-Object { $_.Name }) -join ', '
        throw "More than one adapter is connected ($names). Re-run and pass -InterfaceAlias."
    }

    return $connected[0]
}

function Test-LabIPv4Configured {
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Prefix,
        [Parameter(Mandatory = $true)][string]$Gateway,
        [Parameter(Mandatory = $true)][string[]]$DnsAddresses
    )

    $interface = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    if ($interface.Dhcp -ne 'Disabled') {
        return $false
    }

    $haveIp = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Address -and $_.PrefixLength -eq $Prefix }
    if (-not $haveIp) {
        return $false
    }

    $route = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq $Gateway }
    if (-not $route) {
        return $false
    }

    # Force a real string array. A single DNS address comes back as one string,
    # and indexing that string would compare characters instead of addresses.
    $dnsConfig = Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    $dns = @()
    if ($dnsConfig.ServerAddresses) {
        $dns = @($dnsConfig.ServerAddresses | ForEach-Object { "$_" })
    }
    $wanted = @($DnsAddresses | ForEach-Object { "$_" })
    if ($dns.Count -ne $wanted.Count) {
        return $false
    }
    for ($i = 0; $i -lt $wanted.Count; $i++) {
        if ($dns[$i] -ne $wanted[$i]) {
            return $false
        }
    }

    return $true
}

if (-not (Test-LabIPv4Address -Value $IPAddress)) {
    throw "IPAddress '$IPAddress' is not an IPv4 address."
}
if (-not (Test-LabIPv4Address -Value $DefaultGateway)) {
    throw "DefaultGateway '$DefaultGateway' is not an IPv4 address."
}
if ($DnsServer.Count -lt 1) {
    throw 'Provide at least one DNS server.'
}
foreach ($server in $DnsServer) {
    if (-not (Test-LabIPv4Address -Value $server)) {
        throw "DNS server '$server' is not an IPv4 address."
    }
}

# A domain controller lists itself as DNS. Public resolvers belong in the
# forwarder list after AD DNS exists, not on the network adapter.
if ($DnsServer -notcontains $IPAddress) {
    throw "Refusing to set DNS to $($DnsServer -join ', '). $ComputerName must use its own address ($IPAddress) as a DNS server."
}

$publicResolvers = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9')
$blocked = @($DnsServer | Where-Object { $publicResolvers -contains $_ })
if ($blocked.Count -gt 0) {
    throw "Refusing to put public DNS ($($blocked -join ', ')) on the adapter. After promotion, 02-Install-ADDSForest.ps1 sets forwarders for internet names."
}

$adapter = Get-LabAdapter -Name $InterfaceAlias
$activeName = Get-LabActiveComputerName
$pendingName = Get-LabPendingComputerName
$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$domainMember = [bool]$computer.PartOfDomain
$networkReady = Test-LabIPv4Configured -Adapter $adapter -Address $IPAddress -Prefix $PrefixLength -Gateway $DefaultGateway -DnsAddresses $DnsServer

if ($domainMember -and $activeName -ne $ComputerName) {
    throw "Refusing to rename domain member '$activeName' to '$ComputerName'. This script renames the server before it joins a domain."
}
if ($domainMember -and -not $networkReady) {
    throw "Refusing to change IPv4 on domain member $($computer.Domain). The adapter does not already match $IPAddress/$PrefixLength via $DefaultGateway."
}

Write-Host "Adapter: $($adapter.Name)"
Write-Host "Active computer name: $activeName"
if ($pendingName -ne $activeName) {
    Write-Host "Pending computer name: $pendingName (reboot required)"
}

if ($networkReady) {
    Write-Host "IPv4 already matches $IPAddress/$PrefixLength, gateway $DefaultGateway, DNS $($DnsServer -join ', ')."
}
elseif ($PSCmdlet.ShouldProcess($adapter.Name, "Set IPv4 $IPAddress/$PrefixLength, gateway $DefaultGateway, DNS $($DnsServer -join ', ')")) {
    # Drop DHCP and any previous address so New-NetIPAddress does not collide
    # with an address the guest received from VirtualBox earlier.
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled

    # Remove-NetIPAddress errors if the pipeline is empty, so collect first.
    $oldAddresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' })
    if ($oldAddresses.Count -gt 0) {
        $oldAddresses | Remove-NetIPAddress -Confirm:$false
    }

    $oldRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if ($oldRoutes.Count -gt 0) {
        $oldRoutes | Remove-NetRoute -Confirm:$false
    }

    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $DefaultGateway | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServer

    Write-Host "IPv4 set to $IPAddress/$PrefixLength."
    Write-Host 'Internet names will not resolve until DNS forwarders are set after promotion. That is expected.'
}

$rebootNeeded = $false
if ($activeName -eq $ComputerName) {
    Write-Host "Computer name is already $ComputerName."
}
elseif ($pendingName -eq $ComputerName) {
    Write-Host "Rename to $ComputerName is already pending. Reboot before promoting the server."
    $rebootNeeded = $true
}
elseif ($PSCmdlet.ShouldProcess($activeName, "Rename computer to $ComputerName")) {
    Rename-Computer -NewName $ComputerName -Force | Out-Null
    Write-Host "Rename to $ComputerName is pending. Reboot before promoting the server."
    $rebootNeeded = $true
}

if ($rebootNeeded -and $Restart) {
    if ($PSCmdlet.ShouldProcess($ComputerName, 'Restart computer')) {
        Write-Host 'Restarting in 15 seconds. Press Ctrl+C to cancel.'
        Start-Sleep -Seconds 15
        Restart-Computer -Force
    }
}
elseif ($rebootNeeded) {
    Write-Host 'Next: reboot, sign in, and confirm the name and IP. Then run .\02-Install-ADDSForest.ps1'
    Write-Host 'Re-run this script with -Restart if you want the reboot to happen from here.'
}
else {
    Write-Host 'Next: run .\02-Install-ADDSForest.ps1 from an elevated Windows PowerShell window.'
}
