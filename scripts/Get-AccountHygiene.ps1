<#
================================================================================
 Get-AccountHygiene.ps1

 READ-ONLY. Orphaned, stale and guest accounts in one report.

 ORPHANED AND STALE ARE NOT THE SAME THING

   Orphaned  — no owner, no HR record, nobody accountable. About ACCOUNTABILITY.
   Stale     — no sign-in for N days. About ACTIVITY.

   An account can be orphaned but active (a contractor whose sponsor left).
   It can be stale but owned (someone on parental leave). The remediation
   differs: an orphan needs an owner or removal; a stale account needs a
   confirmation that it is still needed.

   Both together is the classic leaver nobody deprovisioned.

 Required scopes: User.Read.All · AuditLog.Read.All · Directory.Read.All
================================================================================
#>

[CmdletBinding()]
param(
    [int]    $StaleDays = 90,
    [string] $OutputFolder = "$HOME\Desktop\account-hygiene"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Directory.Read.All" -NoWelcome

Write-Output "[*] Reading directory (including sign-in activity)..."

# signInActivity requires AuditLog.Read.All and is only returned when asked for
# explicitly. Omit it and lastSignInDateTime is silently null for everyone —
# every account then looks stale.
$users = @(Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,Mail,AccountEnabled,
                                     EmployeeId,Department,JobTitle,UserType,CreatedDateTime,
                                     SignInActivity,OnPremisesSyncEnabled)

Write-Output "    $($users.Count) account(s)"

$cutoff = (Get-Date).AddDays(-$StaleDays)
$now    = Get-Date

$findings = foreach ($u in $users) {
    $lastSignIn = $u.SignInActivity.LastSignInDateTime
    $daysIdle   = if ($lastSignIn) { [math]::Round(($now - $lastSignIn).TotalDays) } else { $null }
    $ageDays    = if ($u.CreatedDateTime) { [math]::Round(($now - $u.CreatedDateTime).TotalDays) } else { $null }

    # Never signed in AND recently created is onboarding in progress, not a
    # stale account. Distinguishing them stops the report crying wolf on
    # every new starter.
    $isStale = if ($lastSignIn) { $lastSignIn -lt $cutoff }
               elseif ($ageDays -and $ageDays -gt $StaleDays) { $true }
               else { $false }

    $isOrphan = -not $u.EmployeeId -and $u.UserType -ne 'Guest' -and -not $u.OnPremisesSyncEnabled

    $category =
        if ($u.UserType -eq 'Guest' -and $isStale)        { 'Guest — stale' }
        elseif ($u.UserType -eq 'Guest')                   { 'Guest — active' }
        elseif ($isOrphan -and $isStale -and $u.AccountEnabled) { 'ORPHANED + STALE + ENABLED' }
        elseif ($isOrphan -and $u.AccountEnabled)          { 'Orphaned — no employeeId, active' }
        elseif ($isStale  -and $u.AccountEnabled)          { 'Stale — owned but idle' }
        elseif (-not $u.AccountEnabled)                    { 'Disabled — retention candidate' }
        else                                               { $null }

    if (-not $category) { continue }

    [PSCustomObject]@{
        Category    = $category
        DisplayName = $u.DisplayName
        UPN         = $u.UserPrincipalName
        UserType    = $u.UserType
        Enabled     = $u.AccountEnabled
        EmployeeId  = $u.EmployeeId
        Department  = $u.Department
        LastSignIn  = $lastSignIn
        DaysIdle    = $daysIdle
        AgeDays     = $ageDays
        Action      = switch -Wildcard ($category) {
            'ORPHANED*'        { 'Highest priority. Enabled, idle, and nobody accountable — the classic missed leaver.' }
            'Orphaned*'        { 'Find an owner or an HR record. Active but unaccountable.' }
            'Stale*'           { 'Confirm still needed. Owned, so someone can answer.' }
            'Guest — stale*'   { 'Include in the next guest access review; default to deny.' }
            'Guest — active*'  { 'Confirm the sponsor is still here.' }
            'Disabled*'        { 'Retention decision, not a lifecycle one. Delete on a documented schedule.' }
        }
    }
}
$findings = @($findings)

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$path  = Join-Path $OutputFolder "account-hygiene-$stamp.csv"
if ($findings.Count -gt 0) { $findings | Sort-Object Category, DaysIdle -Descending | Export-Csv $path -NoTypeInformation }
else { "Category,DisplayName,UPN,UserType,Enabled,EmployeeId,Department,LastSignIn,DaysIdle,AgeDays,Action" | Set-Content $path }

Write-Output ""
Write-Output "============================================="
Write-Output " Account Hygiene  (stale = no sign-in in $StaleDays days)"
Write-Output "============================================="
if ($findings.Count -eq 0) {
    Write-Output "  Nothing flagged."
} else {
    $findings | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
        Write-Output ("  {0,-36} {1}" -f $_.Name, $_.Count)
    }
    $urgent = @($findings | Where-Object Category -like 'ORPHANED*')
    if ($urgent.Count -gt 0) {
        Write-Output ""
        Write-Output " Highest priority — enabled, idle, nobody accountable:"
        $urgent | Select-Object -First 10 | ForEach-Object {
            Write-Output ("   {0,-28} idle {1} day(s)" -f $_.DisplayName, $_.DaysIdle)
        }
    }
}
Write-Output "============================================="
Write-Output ""
Write-Output "Report: $path"
Write-Output ""
Write-Output "Orphaned is about accountability; stale is about activity. An account can"
Write-Output "be either without being the other, and they need different remediation."

Disconnect-MgGraph | Out-Null
