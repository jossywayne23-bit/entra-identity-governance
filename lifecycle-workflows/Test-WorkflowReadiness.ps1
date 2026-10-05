<#
================================================================================
 Test-WorkflowReadiness.ps1

 READ-ONLY. Answers the question people ask after a workflow silently does
 nothing: are the trigger attributes actually populated?

 Lifecycle Workflows fires on employeeHireDate and employeeLeaveDateTime.
 It cannot populate them. A workflow whose trigger attribute is blank shows
 as enabled, reports no errors, and never runs.

 Required scopes: User.Read.All, User-LifeCycleInfo.Read.All
================================================================================
#>

[CmdletBinding()]
param([int] $LookAheadDays = 30, [int] $LookBackDays = 30)

$ErrorActionPreference = 'Stop'
Connect-MgGraph -Scopes @("User.Read.All", "User-LifeCycleInfo.Read.All") -NoWelcome

$users = @(Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,AccountEnabled,
                                     EmployeeHireDate,EmployeeLeaveDateTime,EmployeeId)
$enabledUsers = @($users | Where-Object { $_.AccountEnabled })

Write-Output "[*] $($enabledUsers.Count) enabled account(s) of $($users.Count) total"

$withHire  = @($enabledUsers | Where-Object { $_.EmployeeHireDate })
$withLeave = @($users | Where-Object { $_.EmployeeLeaveDateTime })

$hirePct  = if ($enabledUsers.Count) { [math]::Round(($withHire.Count  / $enabledUsers.Count) * 100, 1) } else { 0 }
$leavePct = if ($users.Count) { [math]::Round(($withLeave.Count / $users.Count) * 100, 1) } else { 0 }

Write-Output ""
Write-Output "============================================="
Write-Output " Lifecycle Workflow Readiness"
Write-Output "============================================="
Write-Output (" employeeHireDate      : {0,4} of {1} enabled ({2}%)" -f $withHire.Count,  $enabledUsers.Count, $hirePct)
Write-Output (" employeeLeaveDateTime : {0,4} of {1} ({2}%)" -f $withLeave.Count, $users.Count, $leavePct)
Write-Output "============================================="
Write-Output ""

if ($withHire.Count -eq 0) {
    Write-Warning "No enabled account has employeeHireDate. A Joiner workflow can never trigger."
    Write-Output "  Something upstream must write it — a provisioning pipeline, an HR sync, or a person."
}
if ($withLeave.Count -eq 0) {
    Write-Warning "No account has employeeLeaveDateTime. A Leaver workflow can never trigger."
}

# Anything the workflow would act on inside its window. If this is empty, an
# on-demand run against a test user is the only way to prove the configuration.
$now      = Get-Date
$joiners  = @($withHire  | Where-Object { $_.EmployeeHireDate      -ge $now.AddDays(-$LookBackDays) -and $_.EmployeeHireDate      -le $now.AddDays($LookAheadDays) })
$leavers  = @($withLeave | Where-Object { $_.EmployeeLeaveDateTime -ge $now.AddDays(-$LookBackDays) -and $_.EmployeeLeaveDateTime -le $now.AddDays($LookAheadDays) })

Write-Output "In the -$LookBackDays / +$LookAheadDays day window:"
Write-Output ("  Joiners a workflow would act on : {0}" -f $joiners.Count)
Write-Output ("  Leavers a workflow would act on : {0}" -f $leavers.Count)

if ($joiners.Count -gt 0) { Write-Output ""; Write-Output " Upcoming/recent joiners:"; $joiners | Select-Object -First 10 | ForEach-Object { Write-Output ("   {0,-28} {1}" -f $_.DisplayName, $_.EmployeeHireDate) } }
if ($leavers.Count -gt 0) { Write-Output ""; Write-Output " Upcoming/recent leavers:"; $leavers | Select-Object -First 10 | ForEach-Object { Write-Output ("   {0,-28} {1}" -f $_.DisplayName, $_.EmployeeLeaveDateTime) } }

Write-Output ""
Write-Output "If both counts are zero, run each workflow ON-DEMAND against a test user."
Write-Output "On-demand is the equivalent of report-only for Conditional Access."

Disconnect-MgGraph | Out-Null
