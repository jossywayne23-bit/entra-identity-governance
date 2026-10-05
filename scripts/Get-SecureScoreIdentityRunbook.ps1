<#
================================================================================
 Get-SecureScoreIdentityRunbook.ps1

 READ-ONLY. Pulls Microsoft Secure Score, keeps the identity controls, and
 produces a remediation runbook ordered by points-per-effort — each finding
 mapped to the control plane that owns it.

 WHICH SECURE SCORE THIS IS
   Microsoft Secure Score, via the Graph Security API. It covers identity,
   devices, apps and data.

   It is NOT Defender for Cloud Secure Score, which scores Azure resource
   configuration and is a different product with a different API. The names
   are almost identical and the confusion is common — if a recommendation
   concerns a storage account or a VM, you are reading the wrong score.

 WHY THIS SITS IN THIS REPOSITORY
   Secure Score's identity controls span all three planes:
     Conditional Access  — MFA coverage, legacy auth, risk policies
     Entitlement         — guest access, stale accounts
     Privileged          — admin MFA, administrator count, PIM use
   It answers "where do we stand", which is the question the walkthrough's
   "here is how to build it" assumes you have already asked.

 Required scope: SecurityEvents.Read.All
 Module: Microsoft.Graph.Security
================================================================================
#>

[CmdletBinding()]
param(
    [string] $OutputFolder = "$Home\secure-score-identity",
    [switch] $IncludeCompleted
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

Connect-MgGraph -Scopes "SecurityEvents.Read.All" -NoWelcome


# ------------------------------------------------------------------------------
# Plane mapping
# ------------------------------------------------------------------------------
# Secure Score groups controls by its own categories, which do not line up with
# how the work is actually owned. Mapping each control to a plane turns a flat
# list into a set of assignments.
function Get-ControlPlane {
    param([string] $ControlName, [string] $Title)

    $t = "$ControlName $Title".ToLower()

    if ($t -match 'legacy auth|conditional access|sign.?in risk|user risk|block.*access|device.*complian|mfa.*all users|authentication strength') {
        return 'Conditional Access'
    }
    if ($t -match 'admin|privileg|global administrator|role|pim|just.?in.?time') {
        return 'Privileged'
    }
    if ($t -match 'guest|external|stale|inactive|dormant|group|shar') {
        return 'Entitlement'
    }
    if ($t -match 'mfa|multifactor|password|self.?service|authenticat') {
        return 'Conditional Access'
    }
    return 'Other identity'
}


# ------------------------------------------------------------------------------
# 1 — Current score
# ------------------------------------------------------------------------------
Write-Output "[*] Reading Microsoft Secure Score..."

try {
    $scores = @(Get-MgSecuritySecureScore -Top 1)
}
catch {
    Write-Error "Could not read Secure Score: $($_.Exception.Message). Confirm the Microsoft.Graph.Security module is installed and SecurityEvents.Read.All is granted."
    return
}

if ($scores.Count -eq 0) {
    Write-Error "Secure Score returned no data. It can take up to 24 hours to populate in a new tenant."
    return
}

$score   = $scores[0]
$pct     = if ($score.MaxScore) { [math]::Round(($score.CurrentScore / $score.MaxScore) * 100, 1) } else { 0 }

Write-Output "    Overall: $([math]::Round($score.CurrentScore,1)) of $([math]::Round($score.MaxScore,1))  ($pct%)"
Write-Output "    As of  : $($score.CreatedDateTime)"


# ------------------------------------------------------------------------------
# 2 — Control profiles
# ------------------------------------------------------------------------------
# The score object carries current state per control; the profiles carry the
# titles, remediation text and max points. Both are needed.
Write-Output "[*] Reading control profiles..."

$profiles = @{}
foreach ($p in Get-MgSecuritySecureScoreControlProfile -All) {
    $profiles[$p.Id] = $p
}
Write-Output "    $($profiles.Count) control profile(s)"


# ------------------------------------------------------------------------------
# 3 — Identity controls only
# ------------------------------------------------------------------------------
$identity = foreach ($c in $score.ControlScores) {
    $name    = $c.ControlName
    $scoreControl = $profiles[$name]

    # Keep identity controls only. Devices, apps and data have their own owners.
    $category = if ($scoreControl) { $scoreControl.ControlCategory } else { $c.AdditionalProperties.controlCategory }
    if ($category -ne 'Identity') { continue }

    $current = [double]($c.Score)
    $max     = if ($scoreControl) { [double]$scoreControl.MaxScore } else { 0 }
    $gap     = [math]::Max(0, $max - $current)

    # Implementation cost as reported by Microsoft, used for the effort ranking.
    $userImpact = if ($scoreControl) { $scoreControl.UserImpact } else { $null }
    $effortRank = switch ($userImpact) { 'Low' {1} 'Moderate' {2} 'High' {3} default {2} }

    [PSCustomObject]@{
        Control       = $name
        Title         = if ($scoreControl) { $scoreControl.Title } else { $name }
        Plane         = Get-ControlPlane -ControlName $name -Title $(if ($scoreControl) { $scoreControl.Title } else { '' })
        Current       = [math]::Round($current, 1)
        Max           = [math]::Round($max, 1)
        PointsGap     = [math]::Round($gap, 1)
        UserImpact    = $userImpact
        EffortRank    = $effortRank
        # Points per unit of effort. A three-point control that inconveniences
        # nobody outranks a five-point control that needs a rollout programme.
        Value         = if ($effortRank) { [math]::Round($gap / $effortRank, 2) } else { 0 }
        State         = $c.AdditionalProperties.implementationStatus
        Remediation   = if ($profile) { ($profile.Remediation -replace '<[^>]+>','' -replace '\s+',' ').Trim() } else { '' }
    }
}
$identity = @($identity)

if (-not $IncludeCompleted) {
    $identity = @($identity | Where-Object { $_.PointsGap -gt 0 })
}

Write-Output "    $($identity.Count) identity control(s) with points outstanding"


# ------------------------------------------------------------------------------
# 4 — The runbook
# ------------------------------------------------------------------------------
$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmm'
$csvPath  = Join-Path $OutputFolder "identity-controls-$stamp.csv"
$mdPath   = Join-Path $OutputFolder "remediation-runbook-$stamp.md"

$ordered = $identity | Sort-Object Value -Descending

$ordered | Select-Object Plane, Title, Current, Max, PointsGap, UserImpact, Value, State |
    Export-Csv $csvPath -NoTypeInformation

$md = @()
$md += "# Identity Remediation Runbook"
$md += ""
$md += "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') from Microsoft Secure Score."
$md += ""
$md += "**Overall score:** $([math]::Round($score.CurrentScore,1)) / $([math]::Round($score.MaxScore,1)) ($pct%)"
$md += "**Identity controls with points outstanding:** $($identity.Count)"
$md += "**Identity points available:** $([math]::Round((($identity | Measure-Object PointsGap -Sum).Sum), 1))"
$md += ""
$md += "Ordered by points per unit of effort, not by points alone. A three-point"
$md += "control that inconveniences nobody outranks a five-point control that"
$md += "needs a rollout programme."
$md += ""
$md += "## By plane"
$md += ""
$md += "| Plane | Controls | Points available |"
$md += "|---|---|---|"
foreach ($g in $identity | Group-Object Plane | Sort-Object { ($_.Group | Measure-Object PointsGap -Sum).Sum } -Descending) {
    $sum = [math]::Round((($g.Group | Measure-Object PointsGap -Sum).Sum), 1)
    $md += "| $($g.Name) | $($g.Count) | $sum |"
}
$md += ""
$md += "## Remediation order"
$md += ""

$i = 0
foreach ($c in $ordered) {
    $i++
    $md += "### $i. $($c.Title)"
    $md += ""
    $md += "**Plane:** $($c.Plane) · **Points:** $($c.PointsGap) of $($c.Max) · **User impact:** $($c.UserImpact) · **Status:** $($c.State)"
    $md += ""
    if ($c.Remediation) { $md += $c.Remediation; $md += "" }
    $md += "- [ ] Implemented"
    $md += "- [ ] Verified in tenant"
    $md += "- [ ] Evidence captured"
    $md += ""
}

$md += "---"
$md += ""
$md += "## What this does not tell you"
$md += ""
$md += "Secure Score measures configuration against Microsoft's recommended baseline."
$md += "It does not measure whether a control is *working*, whether anyone reads its"
$md += "alerts, or whether an exception list has quietly grown to cover everyone."
$md += ""
$md += "A tenant can score well and still have a Conditional Access policy excluding"
$md += "half the workforce. Use the score to find gaps, not to conclude there are none."

$md -join "`n" | Set-Content $mdPath -Encoding UTF8


# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
Write-Output ""
Write-Output "============================================="
Write-Output " Identity Controls by Plane"
Write-Output "============================================="
foreach ($g in $identity | Group-Object Plane | Sort-Object { ($_.Group | Measure-Object PointsGap -Sum).Sum } -Descending) {
    $sum = [math]::Round((($g.Group | Measure-Object PointsGap -Sum).Sum), 1)
    Write-Output ("  {0,-20} {1,2} control(s)  {2,6} points" -f $g.Name, $g.Count, $sum)
}
Write-Output "============================================="
Write-Output ""
Write-Output "Top 5 by points-per-effort:"
$ordered | Select-Object -First 5 | ForEach-Object {
    Write-Output ("  [{0,-18}] {1}  ({2} pts, {3} impact)" -f $_.Plane, $_.Title, $_.PointsGap, $_.UserImpact)
}
Write-Output ""
Write-Output "Runbook : $mdPath"
Write-Output "Data    : $csvPath"

Disconnect-MgGraph | Out-Null
