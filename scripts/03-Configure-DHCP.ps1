#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs and authorizes DHCP, then creates the lab client scope.

.DESCRIPTION
    Run this on DC01 after the forest exists and the server has rebooted.
    VirtualBox has its own DHCP server for a NAT Network. That server must be
    off before Windows DHCP is authorized. Two DHCP servers on LabNAT will
    fight, and a Windows DHCP server attached to a Bridged adapter could offer
    addresses to the home network. This script refuses to run unless
    -IConfirmVirtualBoxDhcpIsOff is passed. The switch is a confirmation, not
    a test the script can perform from inside the guest.

    The scope is 10.0.10.100 through 10.0.10.200 on 10.0.10.0/24. Options set
    the gateway to 10.0.10.1, DNS to the domain controller, and the DNS domain
    name to the AD domain. The script also makes sure the reverse lookup zone
    and DNS forwarders exist.

    Existing scopes are not deleted. If a scope already covers 10.0.10.0 with
    a different range, the script reports that and leaves the range alone.
    Running it again updates missing authorization, options, and zone data
    without recreating objects that already match.

.PARAMETER IConfirmVirtualBoxDhcpIsOff
    Required. Confirms that the LabNAT NAT Network has DHCP disabled in
    VirtualBox and that no VM adapter is Bridged.

.PARAMETER ScopeId
    Subnet ID of the scope. Default is 10.0.10.0.

.PARAMETER ScopeName
    Display name of the scope. Default is "Lab Clients".

.PARAMETER StartRange
    First address handed to clients. Default is 10.0.10.100.

.PARAMETER EndRange
    Last address handed to clients. Default is 10.0.10.200.

.PARAMETER SubnetMask
    Scope mask. Default is 255.255.255.0.

.PARAMETER Gateway
    DHCP router option. Default is 10.0.10.1.

.PARAMETER DnsServer
    DHCP DNS server option. Default is 10.0.10.10. A public resolver is rejected.

.PARAMETER DomainName
    Expected AD domain and the DHCP DNS domain name option. Default is lab.local.
    The script reads the real domain from AD and stops if they differ.

.PARAMETER LeaseDays
    Lease length in days. Default is 8.

.PARAMETER ServerAddress
    IPv4 address of this DHCP server. Default is 10.0.10.10.

.PARAMETER ExpectedComputerName
    Computer name this script expects. Default is DC01.

.PARAMETER NetworkId
    Reverse lookup network. Default is 10.0.10.0/24.

.PARAMETER Forwarder
    DNS forwarders. Default is 1.1.1.1 and 8.8.8.8.

.EXAMPLE
    .\03-Configure-DHCP.ps1 -WhatIf -IConfirmVirtualBoxDhcpIsOff

.EXAMPLE
    .\03-Configure-DHCP.ps1 -IConfirmVirtualBoxDhcpIsOff

.NOTES
    Author: Briccio Rapido
    Run in elevated Windows PowerShell 5.1 on DC01.
    Does not store credentials.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$IConfirmVirtualBoxDhcpIsOff,

    [string]$ScopeId = '10.0.10.0',

    [string]$ScopeName = 'Lab Clients',

    [string]$StartRange = '10.0.10.100',

    [string]$EndRange = '10.0.10.200',

    [string]$SubnetMask = '255.255.255.0',

    [string]$Gateway = '10.0.10.1',

    [string]$DnsServer = '10.0.10.10',

    [string]$DomainName = 'lab.local',

    [ValidateRange(1, 30)]
    [int]$LeaseDays = 8,

    [string]$ServerAddress = '10.0.10.10',

    [string]$ExpectedComputerName = 'DC01',

    [string]$NetworkId = '10.0.10.0/24',

    [string[]]$Forwarder = @('1.1.1.1', '8.8.8.8')
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

function Get-LabReverseZoneName {
    param([Parameter(Mandatory = $true)][string]$Id)

    $split = $Id.Split('/')
    if ($split.Count -ne 2 -or $split[1] -ne '24') {
        throw "NetworkId must be a /24. The value was '$Id'."
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

    if (($existingForwarders -join ',') -eq ($Resolver -join ',')) {
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
}

if (-not $IConfirmVirtualBoxDhcpIsOff) {
    throw 'Pass -IConfirmVirtualBoxDhcpIsOff after you disable DHCP on the LabNAT network and confirm no adapter is Bridged.'
}

foreach ($address in @($ScopeId, $StartRange, $EndRange, $SubnetMask, $Gateway, $DnsServer, $ServerAddress)) {
    if (-not (Test-LabIPv4Address -Value $address)) {
        throw "'$address' is not an IPv4 address."
    }
}

$publicResolvers = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9')
if ($publicResolvers -contains $DnsServer) {
    throw "Refusing to hand clients public DNS server $DnsServer. Clients must use the domain controller for DNS."
}

if (-not (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)) {
    throw 'Run this script on Windows Server, in Windows PowerShell 5.1.'
}

if ($env:COMPUTERNAME -ne $ExpectedComputerName) {
    throw "Computer name is '$env:COMPUTERNAME'. Expected '$ExpectedComputerName'."
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystem
if ($computer.DomainRole -lt 4) {
    throw 'This computer is not a domain controller. Promote it with .\02-Install-ADDSForest.ps1 and reboot first.'
}

$localAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $ServerAddress }
if (-not $localAddress) {
    throw "This server does not have $ServerAddress. DHCP will bind to the static lab address only after that IP exists."
}

Import-Module ActiveDirectory
$domain = Get-ADDomain
if ($domain.DNSRoot -ne $DomainName) {
    throw "AD domain is $($domain.DNSRoot), but -DomainName is '$DomainName'."
}

$feature = Get-WindowsFeature -Name DHCP
$dhcpReady = [bool]$feature.Installed
if (-not $dhcpReady) {
    if ($PSCmdlet.ShouldProcess('DHCP', 'Install the DHCP role and management tools')) {
        $install = Install-WindowsFeature -Name DHCP -IncludeManagementTools
        if ($install.RestartNeeded -eq 'Yes') {
            Write-Warning 'Windows needs a reboot before DHCP can be configured. Reboot, then run this script again.'
            return
        }
        $dhcpReady = $true
        Write-Host 'DHCP role installed.'
    }
}
else {
    Write-Host 'DHCP role is already installed.'
}

if (-not $dhcpReady) {
    # The role is not installed, so the DHCP cmdlets are not available.
    # -WhatIf still reports the rest of the plan.
    if ($WhatIfPreference) {
        $PSCmdlet.ShouldProcess($NetworkId, 'Ensure DNS forwarders and the reverse lookup zone') | Out-Null
        $PSCmdlet.ShouldProcess('DHCP Administrators and DHCP Users', 'Ensure DHCP security groups') | Out-Null
        $PSCmdlet.ShouldProcess($ServerAddress, 'Authorize this DHCP server in Active Directory') | Out-Null
        $PSCmdlet.ShouldProcess($ScopeId, "Create DHCP scope $StartRange-$EndRange") | Out-Null
        $PSCmdlet.ShouldProcess($ScopeId, "Set router $Gateway, DNS $DnsServer, domain $DomainName") | Out-Null
    }
    Write-Host 'DHCP was not installed. Scope configuration was not started.'
    return
}

Import-Module DhcpServer
Set-LabDnsSupport -Id $NetworkId -Resolver $Forwarder -WhatIf:$WhatIfPreference

# Local groups used by the DHCP console. A second run can report that the
# groups already exist; that is not a failure.
if ($PSCmdlet.ShouldProcess('DHCP Administrators and DHCP Users', 'Ensure DHCP security groups')) {
    try {
        Add-DhcpServerSecurityGroup -ErrorAction Stop
        Restart-Service -Name DHCPServer -Force
        Write-Host 'DHCP security groups are present and the DHCP Server service was restarted.'
    }
    catch {
        Write-Warning "DHCP security group setup reported: $($_.Exception.Message). Continuing if the service is running."
        $service = Get-Service -Name DHCPServer
        if ($service.Status -ne 'Running') {
            Start-Service -Name DHCPServer
        }
    }
}

$serverManagerKey = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
if (Test-Path -LiteralPath $serverManagerKey) {
    $state = (Get-ItemProperty -Path $serverManagerKey -Name ConfigurationState -ErrorAction SilentlyContinue).ConfigurationState
    if ($state -eq 2) {
        Write-Host 'Server Manager already shows DHCP post-install configuration as complete.'
    }
    elseif ($PSCmdlet.ShouldProcess($serverManagerKey, 'Mark DHCP post-install configuration complete in Server Manager')) {
        # This flag only clears the Server Manager reminder. Authorization
        # itself is the Add-DhcpServerInDC call below.
        Set-ItemProperty -Path $serverManagerKey -Name ConfigurationState -Value 2
    }
}

$fqdn = '{0}.{1}' -f $env:COMPUTERNAME, $domain.DNSRoot
$authorized = @()
try {
    $authorized = @(Get-DhcpServerInDC -ErrorAction Stop)
}
catch {
    $authorized = @()
}

$alreadyAuthorized = $false
foreach ($entry in $authorized) {
    $entryIp = ''
    $entryName = ''
    if ($entry.IPAddress) {
        $entryIp = $entry.IPAddress.ToString()
    }
    if ($entry.DnsName) {
        $entryName = $entry.DnsName.ToString().TrimEnd('.')
    }
    if ($entryIp -eq $ServerAddress -or $entryName -eq $fqdn) {
        $alreadyAuthorized = $true
    }
}

if ($alreadyAuthorized) {
    Write-Host "DHCP server $fqdn ($ServerAddress) is already authorized in Active Directory."
}
elseif ($PSCmdlet.ShouldProcess($fqdn, "Authorize DHCP server $ServerAddress in Active Directory")) {
    Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ServerAddress
    Write-Host "Authorized $fqdn ($ServerAddress)."
}

$scope = $null
try {
    $scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction Stop
}
catch {
    $scope = $null
}

$scopeReady = $null -ne $scope
if ($scope) {
    $existingStart = $scope.StartRange.ToString()
    $existingEnd = $scope.EndRange.ToString()
    if ($existingStart -ne $StartRange -or $existingEnd -ne $EndRange) {
        Write-Warning "Scope $ScopeId already exists with range $existingStart-$existingEnd. This script will not delete or resize it."
    }
    else {
        Write-Host "Scope $ScopeId already exists with range $StartRange-$EndRange."
    }

    if ($scope.State -ne 'Active') {
        if ($PSCmdlet.ShouldProcess($ScopeId, 'Activate DHCP scope')) {
            Set-DhcpServerv4Scope -ScopeId $ScopeId -State Active
            Write-Host "Scope $ScopeId activated."
        }
    }
}
elseif ($PSCmdlet.ShouldProcess($ScopeId, "Create DHCP scope $StartRange-$EndRange")) {
    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $StartRange -EndRange $EndRange -SubnetMask $SubnetMask -State Active -LeaseDuration (New-TimeSpan -Days $LeaseDays) -Description 'Clients on LabNAT. Do not attach this server to a Bridged adapter.' | Out-Null
    Write-Host "Created scope $ScopeId ($StartRange-$EndRange)."
    $scopeReady = $true
}

if ($scopeReady -or $WhatIfPreference) {
    if ($PSCmdlet.ShouldProcess($ScopeId, "Set router $Gateway, DNS $DnsServer, domain $DomainName")) {
        Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Gateway -DnsServer $DnsServer -DnsDomain $DomainName
        Write-Host 'Scope options recorded.'
    }
}

if ($PSCmdlet.ShouldProcess('DHCPServer', 'Enable one DHCP conflict-detection attempt')) {
    Set-DhcpServerSetting -ConflictDetectionAttempts 1
}

Write-Host 'Next: run .\04-New-LabOUs.ps1, then .\05-New-LabUsers.ps1.'
Write-Host "Check the scope from this server with: Get-DhcpServerv4Scope -ScopeId $ScopeId"
