<#
================================================================================
 Test-GovernancePosture.ps1

 READ-ONLY. Checks all three planes for the failures that matter.

 Run before starting for a baseline, then after each phase to confirm the
 phase did what it claimed. Nothing here writes.

 Required scopes:
   Policy.Read.All · RoleManagement.Read.Directory · Directory.Read.All
   AdministrativeUnit.Read.All · Group.Read.All
================================================================================
#>

[CmdletBinding()]
param(
    [string]   $BreakGlassPrefix = 'bg-emergency-',
    [string[]] $Tier1Roles = @('Global Administrator','Privileged Role Administrator','Security Administrator'),
    [string]   $OutputFolder = "$Home\governance-posture"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

Connect-MgGraph -Scopes "Policy.Read.All","RoleManagement.Read.Directory","Directory.Read.All",
                        "AdministrativeUnit.Read.All","Group.Read.All" -NoWelcome

$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmm'
$findings = @()

function Add-Finding {
    param([string]$Plane, [string]$Check, [ValidateSet('PASS','FAIL','WARN','INFO')][string]$Result, [string]$Detail)
    $script:findings += [PSCustomObject]@{ Plane=$Plane; Check=$Check; Result=$Result; Detail=$Detail }
    $c = switch ($Result) { 'PASS'{'Green'} 'FAIL'{'Red'} 'WARN'{'Yellow'} default{'Gray'} }
    Write-Host ("  [{0}] {1}" -f $Result, $Check) -ForegroundColor $c
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}


# ------------------------------------------------------------------------------
# Break glass — checked first because both other planes depend on it
# ------------------------------------------------------------------------------
Write-Host "`n[*] Break glass" -ForegroundColor Cyan

$bg = @(Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled |
        Where-Object { $_.UserPrincipalName -like "$BreakGlassPrefix*" })

Add-Finding 'Foundation' "Two break glass accounts exist" `
    $(if ($bg.Count -ge 2) {'PASS'} elseif ($bg.Count -eq 1) {'WARN'} else {'FAIL'}) `
    "$($bg.Count) found. One is a single point of failure in the recovery path."

$disabled = @($bg | Where-Object { -not $_.AccountEnabled })
if ($disabled.Count -gt 0) {
    Add-Finding 'Foundation' "Break glass accounts enabled" 'FAIL' "$($disabled.Count) disabled — they will not work when needed."
}


# ------------------------------------------------------------------------------
# Plane 1 — Conditional Access
# ------------------------------------------------------------------------------
Write-Host "`n[*] Plane 1 — Conditional Access" -ForegroundColor Cyan

$policies = @(Get-MgIdentityConditionalAccessPolicy -All)
$policies | Select-Object DisplayName, State |
    Export-Csv (Join-Path $OutputFolder "ca-policies-$stamp.csv") -NoTypeInformation

Add-Finding 'CA' "Policies exist" $(if ($policies.Count -gt 0) {'PASS'} else {'FAIL'}) "$($policies.Count) policy/policies."

# The failure that only surfaces during an outage: a policy that forgot the
# exclusion, discovered at the moment the account is needed.
if ($bg.Count -gt 0) {
    $bgIds = @($bg.Id)
    $missing = @()
    foreach ($p in $policies | Where-Object { $_.State -ne 'disabled' }) {
        $ex = @($p.Conditions.Users.ExcludeUsers)
        if (@($bgIds | Where-Object { $_ -notin $ex }).Count -gt 0) { $missing += $p.DisplayName }
    }
    Add-Finding 'CA' "Break glass excluded from every enabled policy" `
        $(if ($missing.Count -eq 0) {'PASS'} else {'FAIL'}) `
        $(if ($missing.Count -eq 0) { "All enabled policies exclude break glass." }
          else { "$($missing.Count) do not: $($missing -join ', ')" })
}

$reportOnly = @($policies | Where-Object { $_.State -eq 'enabledForReportingButNotEnforced' })
$enabled    = @($policies | Where-Object { $_.State -eq 'enabled' })
Add-Finding 'CA' "Enforcement state" 'INFO' "$($enabled.Count) enforced, $($reportOnly.Count) report-only."

# Legacy auth cannot do MFA, so an MFA policy does not apply to it — it has to
# be blocked separately or it bypasses the whole control set.
$legacyBlock = @($policies | Where-Object {
    $_.Conditions.ClientAppTypes -contains 'exchangeActiveSync' -or
    $_.Conditions.ClientAppTypes -contains 'other' })
Add-Finding 'CA' "Legacy authentication addressed" `
    $(if ($legacyBlock.Count -gt 0) {'PASS'} else {'FAIL'}) `
    "$($legacyBlock.Count) policy/policies target legacy clients."


# ------------------------------------------------------------------------------
# Plane 2 — Entitlement governance
# ------------------------------------------------------------------------------
Write-Host "`n[*] Plane 2 — Entitlement governance" -ForegroundColor Cyan

$groups  = @(Get-MgGroup -All -Property Id,DisplayName,GroupTypes,MembershipRule,SecurityEnabled)
$dynamic = @($groups | Where-Object { $_.GroupTypes -contains 'DynamicMembership' })

Add-Finding 'Entitlement' "Dynamic groups exist" `
    $(if ($dynamic.Count -gt 0) {'PASS'} else {'WARN'}) `
    "$($dynamic.Count) dynamic of $($groups.Count) total. Zero means all membership is manual."

# A rule without accountEnabled keeps disabled users in the group — they retain
# group-derived access invisibly, because they cannot sign in to reveal it.
$noEnabledCheck = @($dynamic | Where-Object { $_.MembershipRule -notmatch 'accountEnabled' })
if ($dynamic.Count -gt 0) {
    Add-Finding 'Entitlement' "Dynamic rules exclude disabled accounts" `
        $(if ($noEnabledCheck.Count -eq 0) {'PASS'} else {'WARN'}) `
        "$($noEnabledCheck.Count) rule(s) omit accountEnabled — disabled users retain membership."
}

$dynamic | Select-Object DisplayName, MembershipRule |
    Export-Csv (Join-Path $OutputFolder "dynamic-groups-$stamp.csv") -NoTypeInformation

# Assigned security groups are the manual-assignment surface — the residue that
# access reviews have to chase.
$assigned = @($groups | Where-Object { $_.SecurityEnabled -and $_.GroupTypes -notcontains 'DynamicMembership' })
Add-Finding 'Entitlement' "Manual-assignment surface" 'INFO' `
    "$($assigned.Count) assigned security group(s). Each is membership nothing revokes automatically."


# ------------------------------------------------------------------------------
# Plane 3 — Privileged access governance
# ------------------------------------------------------------------------------
Write-Host "`n[*] Plane 3 — Privileged access governance" -ForegroundColor Cyan

$roleDefinitions = @{}
foreach ($roleDefinition in Get-MgRoleManagementDirectoryRoleDefinition -All) {
    $roleDefinitions[$roleDefinition.Id] = $roleDefinition.DisplayName
}
$assignments = @(Get-MgRoleManagementDirectoryRoleAssignment -All -ExpandProperty Principal)
$standing = $assignments | ForEach-Object {
    [PSCustomObject]@{
        Role      = $roleDefinitions[$_.RoleDefinitionId]
        Principal = $_.Principal.AdditionalProperties.displayName
        UPN       = $_.Principal.AdditionalProperties.userPrincipalName
    }
}
$standing | Export-Csv (Join-Path $OutputFolder "standing-assignments-$stamp.csv") -NoTypeInformation

$tier1NonBg = @($standing | Where-Object { $_.Role -in $Tier1Roles -and $_.UPN -notlike "$BreakGlassPrefix*" })
Add-Finding 'Privileged' "No standing tier 1 assignments" `
    $(if ($tier1NonBg.Count -eq 0) {'PASS'} else {'FAIL'}) `
    "$($tier1NonBg.Count) non-break-glass principal(s) hold a tier 1 role permanently."
$tier1NonBg | ForEach-Object { Write-Host "           $($_.Role): $($_.Principal)" -ForegroundColor DarkGray }

try {
    $eligible = @(Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All)
    Add-Finding 'Privileged' "Eligible assignments exist" `
        $(if ($eligible.Count -gt 0) {'PASS'} else {'WARN'}) `
        "$($eligible.Count) eligible. Zero suggests PIM is not in use."

    # Eligibility with no end date is standing access with an extra click.
    $noExpiry = @($eligible | Where-Object { -not $_.ScheduleInfo.Expiration.EndDateTime })
    if ($eligible.Count -gt 0) {
        Add-Finding 'Privileged' "Eligibility has an expiry" `
            $(if ($noExpiry.Count -eq 0) {'PASS'} else {'WARN'}) `
            "$($noExpiry.Count) eligible assignment(s) never expire."
    }
}
catch {
    Add-Finding 'Privileged' "PIM readable" 'WARN' "Could not read PIM schedules: $($_.Exception.Message). Confirm Entra ID P2."
}

$aus = @(Get-MgDirectoryAdministrativeUnit -All `
    -Property Id,DisplayName,IsMemberManagementRestricted)
Add-Finding 'Privileged' "Administrative Units exist" `
    $(if ($aus.Count -gt 0) {'PASS'} else {'WARN'}) `
    "$($aus.Count) AU(s). Zero means every admin is tenant-scoped."

$restricted = @($aus | Where-Object { $_.IsMemberManagementRestricted -eq $true })
Add-Finding 'Privileged' "Restricted management AU for break glass" `
    $(if ($restricted.Count -gt 0) {'PASS'} else {'WARN'}) `
    "$($restricted.Count) restricted AU(s)."


# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
$findings | Export-Csv (Join-Path $OutputFolder "posture-findings-$stamp.csv") -NoTypeInformation

Write-Host "`n============================================="
Write-Host " Governance Posture"
Write-Host "============================================="
$findings | Group-Object Plane | ForEach-Object {
    $f = @($_.Group | Where-Object Result -eq 'FAIL').Count
    $w = @($_.Group | Where-Object Result -eq 'WARN').Count
    $p = @($_.Group | Where-Object Result -eq 'PASS').Count
    Write-Host ("  {0,-12}  pass {1}  warn {2}  fail {3}" -f $_.Name, $p, $w, $f)
}
Write-Host "============================================="
Write-Host "`nReports written to $OutputFolder"

$fails = @($findings | Where-Object Result -eq 'FAIL').Count
if ($fails -gt 0) {
    Write-Host "`nFAIL items are the ones that bite during an incident, not during an audit." -ForegroundColor Yellow
}

Disconnect-MgGraph | Out-Null
