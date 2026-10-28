#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Creates fictional lab users from data/lab-users.csv and adds them to department groups.

.DESCRIPTION
    Reads the CSV, checks every row, then creates accounts that do not already
    exist. One initial password is typed at runtime with Read-Host -AsSecureString
    and is used for every new account in that run. Each new account is enabled
    and must change the password at the next sign-in.

    The password is not a script parameter, so it does not land in the command
    line or in this repository. The script never writes the password to the CSV.
    Accounts that already exist are not modified and their passwords are not
    reset. They are added to the department group if that membership is missing.

    Departments in the CSV must be IT, HR, Lab Operations, or Finance, matching
    the OUs from 04-New-LabOUs.ps1. The department group sAMAccountName is the
    department name with spaces removed.

    -WhatIf lists the accounts and group memberships it would create and does
    not prompt for a password.

.PARAMETER CsvPath
    Path to the user CSV. When omitted, the script uses data\lab-users.csv
    next to the scripts folder.

.PARAMETER CompanyName
    Top-level OU created by 04-New-LabOUs.ps1. Default is Company.

.PARAMETER DomainName
    Expected AD domain. Default is lab.local. The script stops if the live
    domain does not match.

.EXAMPLE
    .\05-New-LabUsers.ps1 -WhatIf

.EXAMPLE
    .\05-New-LabUsers.ps1

    Prompts once, then creates any missing fictional users.

.EXAMPLE
    .\05-New-LabUsers.ps1 -CsvPath D:\homelab\data\lab-users.csv

.NOTES
    Author: Briccio Rapido
    Run in elevated Windows PowerShell 5.1 on DC01, after 04-New-LabOUs.ps1.
    The CSV people are invented. Do not replace them with real people, patients,
    or coworker names.

    Using one bootstrap password for a lab import is not how you issue
    passwords in production. ChangePasswordAtLogon is what makes that bootstrap
    temporary. Do not put the password in a screenshot.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CsvPath,

    [ValidatePattern('^[A-Za-z][A-Za-z ]{0,62}$')]
    [string]$CompanyName = 'Company',

    [string]$DomainName = 'lab.local'
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
        throw 'Use at least 8 characters. The domain password policy still applies. Nothing was saved.'
    }

    return $first
}

function Test-LabOuExists {
    param([Parameter(Mandatory = $true)][string]$DistinguishedName)

    # Do not use a typed catch. PowerShell resolves catch types while parsing,
    # before #Requires has loaded the ActiveDirectory module.
    try {
        Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        $errors = @($_.Exception, $_.Exception.InnerException)
        foreach ($candidate in $errors) {
            if (-not $candidate) {
                continue
            }
            if ($candidate.GetType().FullName -eq 'Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException') {
                return $false
            }
            if ($candidate.Message -match 'Cannot find an object with identity') {
                return $false
            }
        }
        throw
    }
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'data\lab-users.csv'
}
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$allowedDepartments = @('IT', 'HR', 'Lab Operations', 'Finance')
$reservedAccounts = @('administrator', 'guest', 'krbtgt', 'defaultaccount', 'wdagutilityaccount')
$requiredColumns = @('FirstName', 'LastName', 'SamAccountName', 'Department', 'Title')

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) {
    throw "The CSV has no user rows: $CsvPath"
}

$columns = @($rows[0].PSObject.Properties.Name)
foreach ($column in $requiredColumns) {
    if ($columns -notcontains $column) {
        throw "CSV is missing the $column column."
    }
}

$planned = New-Object System.Collections.Generic.List[object]
$seen = @{}

foreach ($row in $rows) {
    $first = ([string]$row.FirstName).Trim()
    $last = ([string]$row.LastName).Trim()
    $sam = ([string]$row.SamAccountName).Trim()
    $department = ([string]$row.Department).Trim()
    $title = ([string]$row.Title).Trim()

    if ($first -notmatch "^[A-Za-z][A-Za-z' .-]{0,40}$") {
        throw "First name '$first' is empty or has characters this script will not use."
    }
    if ($last -notmatch "^[A-Za-z][A-Za-z' .-]{0,40}$") {
        throw "Last name '$last' is empty or has characters this script will not use."
    }
    if ($sam -notmatch '^[A-Za-z][A-Za-z0-9-]{0,19}$') {
        throw "SamAccountName '$sam' must be 1-20 letters, digits, or hyphens, and must start with a letter."
    }
    if ($reservedAccounts -contains $sam.ToLower()) {
        throw "SamAccountName '$sam' is reserved. Pick a different lab account."
    }
    if ($allowedDepartments -notcontains $department) {
        throw "Department '$department' for $sam is not one of: $($allowedDepartments -join ', '). Create that OU first if you intend to add a department."
    }
    if ($title -notmatch '^[A-Za-z0-9][A-Za-z0-9 /-]{0,60}$') {
        throw "Title '$title' for $sam is empty or has characters this script will not use."
    }
    if ($seen.ContainsKey($sam.ToLower())) {
        throw "SamAccountName '$sam' appears more than once in $CsvPath."
    }

    $seen[$sam.ToLower()] = $true
    $planned.Add([pscustomobject]@{
            FirstName  = $first
            LastName   = $last
            Sam        = $sam
            Department = $department
            Title      = $title
            GroupSam   = ($department -replace '\s', '')
        }) | Out-Null
}

$domain = Get-ADDomain
if ($domain.DNSRoot -ne $DomainName) {
    throw "AD domain is $($domain.DNSRoot), but -DomainName is '$DomainName'."
}

$domainDn = $domain.DistinguishedName

foreach ($user in $planned) {
    $ou = "OU=Users,OU=$($user.Department),OU=$CompanyName,$domainDn"
    if (-not (Test-LabOuExists -DistinguishedName $ou)) {
        throw "Missing $ou. Run .\04-New-LabOUs.ps1 before creating users."
    }

    $group = Get-ADGroup -LDAPFilter "(sAMAccountName=$($user.GroupSam))" -ErrorAction SilentlyContinue
    if (-not $group) {
        throw "Missing group $($user.GroupSam). Run .\04-New-LabOUs.ps1 before creating users."
    }
}

$missing = New-Object System.Collections.Generic.List[string]
foreach ($user in $planned) {
    $existing = Get-ADUser -LDAPFilter "(sAMAccountName=$($user.Sam))" -ErrorAction SilentlyContinue
    if (-not $existing) {
        $missing.Add($user.Sam) | Out-Null
    }
}

$password = $null
if ($missing.Count -gt 0 -and -not $WhatIfPreference) {
    Write-Host "Enter one initial password for the $($missing.Count) new lab account(s)."
    Write-Host 'It is held in memory for this run only. Each new account must change it at first sign-in.'
    Write-Host 'It must meet the domain password policy. The script cannot show the policy rejection until Active Directory refuses the password.'
    $password = Read-ConfirmedSecureString -Prompt 'Initial password for new lab users'
}

$created = 0
$skipped = 0
$addedToGroup = 0
$alreadyInGroup = 0

foreach ($user in $planned) {
    $display = '{0} {1}' -f $user.FirstName, $user.LastName
    $upn = '{0}@{1}' -f $user.Sam, $DomainName
    $ou = "OU=Users,OU=$($user.Department),OU=$CompanyName,$domainDn"
    $existing = Get-ADUser -LDAPFilter "(sAMAccountName=$($user.Sam))" -ErrorAction SilentlyContinue
    $accountReady = $false

    if ($existing) {
        Write-Host "User already exists: $($user.Sam). Password was not changed."
        $skipped++
        $accountReady = $true
    }
    elseif ($PSCmdlet.ShouldProcess($user.Sam, "Create user $display in $ou")) {
        New-ADUser -Name $display -GivenName $user.FirstName -Surname $user.LastName -DisplayName $display -SamAccountName $user.Sam -UserPrincipalName $upn -EmailAddress $upn -Department $user.Department -Title $user.Title -Description 'Fictional lab account for a portfolio home lab. Not a real person.' -AccountPassword $password -ChangePasswordAtLogon $true -Enabled $true -Path $ou | Out-Null
        Write-Host "Created user: $($user.Sam)"
        $created++
        $accountReady = $true
    }

    if ($accountReady) {
        $membership = @(Get-ADPrincipalGroupMembership -Identity $user.Sam | ForEach-Object { $_.SamAccountName })
        if ($membership -contains $user.GroupSam) {
            Write-Host "Already in group: $($user.Sam) -> $($user.GroupSam)"
            $alreadyInGroup++
        }
        elseif ($PSCmdlet.ShouldProcess("$($user.Sam) -> $($user.GroupSam)", 'Add group member')) {
            Add-ADGroupMember -Identity $user.GroupSam -Members $user.Sam
            Write-Host "Added to group: $($user.Sam) -> $($user.GroupSam)"
            $addedToGroup++
        }
    }
    elseif ($WhatIfPreference) {
        $PSCmdlet.ShouldProcess("$($user.Sam) -> $($user.GroupSam)", 'Add group member') | Out-Null
    }
}

Write-Host "Users created: $created. Users already present: $skipped. Group memberships added: $addedToGroup. Memberships already present: $alreadyInGroup."
Write-Host 'First sign-in for a new account happens from a domain-joined client and will demand a new password.'
