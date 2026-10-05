<#
================================================================================
 Find-DuplicateIdentities.ps1

 READ-ONLY. Finds accounts that probably represent the same human.

 WHY THIS EXISTS

   HR-driven provisioning matches on an identifier. When the match fails —
   the employeeId was never seeded, the email changed, the name is recorded
   differently — the record reads as a new hire and a second account is
   created for someone who already has one.

   Every upstream control reduces that risk. None eliminates it. This is the
   check that runs afterwards and asks whether it happened anyway.

 WHY IT IS NOT JUST "SAME NAME"

   Two people named John Williams are not a duplicate. The signal is name
   collision PLUS the absence of anything distinguishing them. So findings
   are tiered by how confident the evidence is, and only the top tier is
   worth acting on without a human looking.

 Required scope: User.Read.All
================================================================================
#>

[CmdletBinding()]
param(
    [string]   $OutputFolder   = "$HOME\Desktop\duplicate-identities",
    [string[]] $KnownDistinct  = @(),
    [switch]   $IncludeDisabled
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

Connect-MgGraph -Scopes "User.Read.All" -NoWelcome


# ------------------------------------------------------------------------------
# Normalisation — must match the reconciliation tool exactly
# ------------------------------------------------------------------------------
# Punctuation stripped, lowercased, parts sorted so word order stops mattering:
# "Okafor, Chidi" and "Chidi Okafor" both become "chidi okafor". If this diverges
# from reconciliation's version, the two tools disagree about the same person.
function Get-NormalizedName {
    param([string] $Name)
    if (-not $Name) { return $null }
    $clean = ($Name -replace "[^\p{L}\s]", " ") -replace "\s+", " "
    $parts = $clean.Trim().ToLower() -split " " | Where-Object { $_.Length -gt 1 }
    return ($parts | Sort-Object) -join " "
}

function Get-EmailLocalPart {
    param([string] $Email)
    if (-not $Email) { return $null }
    return ($Email -split "@")[0].ToLower()
}


# ------------------------------------------------------------------------------
# 1 — Read the directory
# ------------------------------------------------------------------------------
Write-Output "[*] Reading directory..."

$users = @(Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,Mail,EmployeeId,
                                     Department,JobTitle,AccountEnabled,UserType,CreatedDateTime |
           Where-Object { $_.UserType -ne 'Guest' })

if (-not $IncludeDisabled) {
    $users = @($users | Where-Object { $_.AccountEnabled })
}

Write-Output "    $($users.Count) account(s) in scope"


# ------------------------------------------------------------------------------
# 2 — Group by normalised name
# ------------------------------------------------------------------------------
$byName = @{}
foreach ($u in $users) {
    $n = Get-NormalizedName $u.DisplayName
    if (-not $n) { continue }
    if (-not $byName.ContainsKey($n)) { $byName[$n] = @() }
    $byName[$n] += $u
}

$collisions = @($byName.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
Write-Output "    $($collisions.Count) name collision(s)"


# ------------------------------------------------------------------------------
# 3 — Classify by confidence
# ------------------------------------------------------------------------------
# The question is not "do these share a name" but "is there anything that
# distinguishes them". Two employeeIds is evidence of two people. Two blanks
# is evidence of nothing, which is what makes it suspicious.
$findings = foreach ($c in $collisions) {
    $accounts = @($c.Value)
    $name     = $c.Key

    if ($name -in $KnownDistinct) {
        $tier = "0 - ACKNOWLEDGED"
        $note = "On the known-distinct list. Confirmed as separate people."
    }
    else {
        $ids        = @($accounts | Where-Object { $_.EmployeeId } | ForEach-Object { $_.EmployeeId })
        $distinctId = @($ids | Sort-Object -Unique)
        $localParts = @($accounts | ForEach-Object { Get-EmailLocalPart $_.UserPrincipalName } | Sort-Object -Unique)

        $tier, $note =
            if ($distinctId.Count -gt 1 -and $distinctId.Count -eq $accounts.Count) {
                # Every account carries a different employeeId. Strongest evidence
                # available that these are genuinely different humans.
                "4 - LIKELY DISTINCT", "Each account has its own employeeId. Probably two people with the same name. Add to -KnownDistinct to silence."
            }
            elseif ($ids.Count -eq 0) {
                # Nothing distinguishes them at all. This is the shape a
                # provisioning duplicate leaves behind.
                "1 - PROBABLE DUPLICATE", "Same name, no employeeId on any account. Nothing distinguishes these. Investigate before the next sync."
            }
            elseif ($ids.Count -lt $accounts.Count) {
                # One linked, one not — exactly what happens when a match fails
                # and a second account is created alongside the original.
                "2 - LIKELY DUPLICATE", "Same name; $($ids.Count) of $($accounts.Count) account(s) have an employeeId. Consistent with a failed match creating a second account."
            }
            elseif ($distinctId.Count -eq 1) {
                # Same employeeId on multiple accounts. Worse than a duplicate —
                # provisioning cannot tell which one to update.
                "0 - ID COLLISION", "Multiple accounts share employeeId '$($distinctId[0])'. Provisioning cannot determine which to update. Resolve immediately."
            }
            else {
                "3 - REVIEW", "Same name, mixed identifier state. Human review required."
            }
    }

    foreach ($a in $accounts) {
        [PSCustomObject]@{
            Tier         = $tier
            NormalisedName = $name
            DisplayName  = $a.DisplayName
            UPN          = $a.UserPrincipalName
            EmployeeId   = $a.EmployeeId
            Department   = $a.Department
            JobTitle     = $a.JobTitle
            Enabled      = $a.AccountEnabled
            Created      = $a.CreatedDateTime
            Action       = $note
        }
    }
}
$findings = @($findings)


# ------------------------------------------------------------------------------
# 4 — Output
# ------------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$path  = Join-Path $OutputFolder "duplicate-identities-$stamp.csv"

if ($findings.Count -gt 0) {
    $findings | Sort-Object Tier, NormalisedName | Export-Csv $path -NoTypeInformation
} else {
    # Always produce the artefact. An empty file with headers proves the check
    # ran; a missing file is indistinguishable from a check that never happened.
    "Tier,NormalisedName,DisplayName,UPN,EmployeeId,Department,JobTitle,Enabled,Created,Action" | Set-Content $path
}

Write-Output ""
Write-Output "============================================="
Write-Output " Duplicate Identity Report"
Write-Output "============================================="
Write-Output " Accounts scanned : $($users.Count)"
Write-Output " Name collisions  : $($collisions.Count)"
Write-Output ""

if ($findings.Count -gt 0) {
    $findings | Group-Object Tier | Sort-Object Name | ForEach-Object {
        $people = @($_.Group | Select-Object -ExpandProperty NormalisedName -Unique).Count
        Write-Output ("  {0,-24} {1} name(s), {2} account(s)" -f $_.Name, $people, $_.Count)
    }
    Write-Output ""

    $urgent = @($findings | Where-Object { $_.Tier -like '0 - ID*' -or $_.Tier -like '1 - *' -or $_.Tier -like '2 - *' })
    if ($urgent.Count -gt 0) {
        Write-Output " NEEDS ACTION:"
        $urgent | Select-Object -ExpandProperty NormalisedName -Unique | ForEach-Object {
            $rows = @($urgent | Where-Object NormalisedName -eq $_)
            Write-Output ("   [{0}] {1}" -f $rows[0].Tier, $rows[0].DisplayName)
            $rows | ForEach-Object { Write-Output ("       {0}  employeeId=[{1}]" -f $_.UPN, $_.EmployeeId) }
        }
    }
} else {
    Write-Output "  No name collisions found."
}

Write-Output "============================================="
Write-Output ""
Write-Output "Report: $path"
Write-Output ""
Write-Output "Tier 4 findings are probably two real people sharing a name. Confirm once,"
Write-Output "then pass them to -KnownDistinct so the check stops flagging them. A control"
Write-Output "that reports the same known-good finding every run trains people to ignore it."

Disconnect-MgGraph | Out-Null
