#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Creates the lab organizational units and one security group per department.

.DESCRIPTION
    Creates this OU tree under the domain root:

        Company
            IT
                Users
                Computers
                Groups
            HR
                Users
                Computers
                Groups
            Lab Operations
                Users
                Computers
                Groups
            Finance
                Users
                Computers
                Groups

    Each department gets a global security group in its Groups OU. The group
    name matches the department. The sAMAccountName is the department name with
    spaces removed, so "Lab Operations" becomes LabOperations.

    Objects that already exist are left in place. Nothing is deleted, moved,
    or unprotected. New OUs are protected from accidental deletion. Run the
    script again after a partial failure; it only fills in what is missing.

    These are organizational units, not the built-in Users and Computers
    containers. Group Policy can be linked to them later. New domain computers
    still land in the built-in Computers container until that is changed.

.PARAMETER CompanyName
    Top-level OU. Default is Company.

.PARAMETER Department
    Department OUs to create. Default is IT, HR, Lab Operations, and Finance.

.PARAMETER DomainName
    Expected DNS name of the domain. Default is lab.local. The script reads
    the domain from Active Directory and stops if the names differ.

.EXAMPLE
    .\04-New-LabOUs.ps1 -WhatIf

.EXAMPLE
    .\04-New-LabOUs.ps1

.NOTES
    Author: Briccio Rapido
    Run in elevated Windows PowerShell 5.1 on DC01, after promotion.
    Does not create users and does not set passwords. Run 05-New-LabUsers.ps1
    after this script.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z][A-Za-z ]{0,62}$')]
    [string]$CompanyName = 'Company',

    [string[]]$Department = @('IT', 'HR', 'Lab Operations', 'Finance'),

    [string]$DomainName = 'lab.local'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

function New-LabOuIfMissing {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ParentDn,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][bool]$ParentReady
    )

    $dn = "OU=$Name,$ParentDn"
    if (Test-LabOuExists -DistinguishedName $dn) {
        Write-Host "OU already exists: $dn"
        return $true
    }

    if (-not $ParentReady) {
        if ($WhatIfPreference) {
            $PSCmdlet.ShouldProcess($dn, 'Create organizational unit') | Out-Null
            return $false
        }
        throw "Cannot create $dn because the parent OU does not exist."
    }

    if ($PSCmdlet.ShouldProcess($dn, 'Create organizational unit')) {
        New-ADOrganizationalUnit -Name $Name -Path $ParentDn -Description $Description -ProtectedFromAccidentalDeletion $true | Out-Null
        Write-Host "Created OU: $dn"
        return $true
    }

    return $false
}

function New-LabDepartmentGroupIfMissing {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$DepartmentName,
        [Parameter(Mandatory = $true)][string]$ParentDn,
        [Parameter(Mandatory = $true)][bool]$ParentReady
    )

    $sam = $DepartmentName -replace '\s', ''
    $existing = Get-ADGroup -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Group already exists: $sam"
        if ($existing.DistinguishedName -notlike "*,$ParentDn") {
            Write-Warning "Group $sam is at $($existing.DistinguishedName), not in $ParentDn. It was not moved."
        }
        return
    }

    if (-not $ParentReady) {
        if ($WhatIfPreference) {
            $PSCmdlet.ShouldProcess($sam, "Create global security group in $ParentDn") | Out-Null
            return
        }
        throw "Cannot create group $sam because $ParentDn does not exist."
    }

    if ($PSCmdlet.ShouldProcess($sam, "Create global security group in $ParentDn")) {
        New-ADGroup -Name $DepartmentName -SamAccountName $sam -GroupScope Global -GroupCategory Security -Path $ParentDn -Description "Fictional department group for $DepartmentName lab users. Not a production group." | Out-Null
        Write-Host "Created group: $sam"
    }
}

foreach ($name in $Department) {
    if ($name -notmatch '^[A-Za-z][A-Za-z ]{0,62}$') {
        throw "Department '$name' contains characters this script will not use in an OU name."
    }
}

$domain = Get-ADDomain
if ($domain.DNSRoot -ne $DomainName) {
    throw "AD domain is $($domain.DNSRoot), but -DomainName is '$DomainName'."
}

$domainDn = $domain.DistinguishedName
Write-Host "Domain: $($domain.DNSRoot) ($domainDn)"

$companyReady = New-LabOuIfMissing -Name $CompanyName -ParentDn $domainDn -Description 'Top-level OU for fictional lab objects.' -ParentReady $true -WhatIf:$WhatIfPreference

if (-not $companyReady -and -not $WhatIfPreference) {
    throw "The $CompanyName OU was not created. No department OUs were attempted."
}

$companyDn = "OU=$CompanyName,$domainDn"
$childNames = @('Users', 'Computers', 'Groups')

foreach ($departmentName in $Department) {
    $departmentReady = New-LabOuIfMissing -Name $departmentName -ParentDn $companyDn -Description "Fictional $departmentName department." -ParentReady $companyReady -WhatIf:$WhatIfPreference
    $departmentDn = "OU=$departmentName,$companyDn"
    $groupsReady = $false

    foreach ($childName in $childNames) {
        $description = "Fictional $departmentName $childName."
        $childReady = New-LabOuIfMissing -Name $childName -ParentDn $departmentDn -Description $description -ParentReady $departmentReady -WhatIf:$WhatIfPreference
        if ($childName -eq 'Groups') {
            $groupsReady = $childReady
        }
    }

    $groupsDn = "OU=Groups,$departmentDn"
    New-LabDepartmentGroupIfMissing -DepartmentName $departmentName -ParentDn $groupsDn -ParentReady $groupsReady -WhatIf:$WhatIfPreference
}

Write-Host 'Next: run .\05-New-LabUsers.ps1'
Write-Host 'New computers still go to the built-in Computers container until you move them or change the default with redircmp.'
