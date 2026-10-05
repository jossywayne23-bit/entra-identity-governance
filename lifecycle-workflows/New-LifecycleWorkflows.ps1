<#
================================================================================
 New-LifecycleWorkflows.ps1

 Creates Joiner and Leaver workflows that respect the ownership boundary this
 repository sets: the PROVISIONING PIPELINE owns account state, Lifecycle
 Workflows owns everything around it.

 ──────────────────────────────────────────────────────────────────────────────
 THE OWNERSHIP BOUNDARY, AND WHY IT IS ENFORCED HERE
 ──────────────────────────────────────────────────────────────────────────────

   Lifecycle Workflows CAN enable and disable accounts. So can a provisioning
   pipeline. Both running on independent schedules against the same account is
   a race condition in the identity layer — it surfaces as "the account keeps
   re-enabling itself" and is genuinely hard to diagnose.

   With -PipelineOwnsAccountState (the DEFAULT), this script omits:
     · "Enable User Account"  from the joiner workflow
     · "Disable User Account" from the leaver workflow

   Pass -PipelineOwnsAccountState:$false only if nothing else writes
   accountEnabled. Verify that before you do.

 ──────────────────────────────────────────────────────────────────────────────
 WHY TASK IDS ARE RESOLVED AT RUNTIME
 ──────────────────────────────────────────────────────────────────────────────

   Task definition IDs are GUIDs. A wrong one either fails loudly or — worse —
   silently attaches the wrong task. Rather than hardcode a list, this script
   reads the tenant's own task definitions and resolves each by display name,
   then FAILS if any cannot be found. Nothing is created from a guess.

   Four IDs are documented by Microsoft and used as a cross-check:
     Enable User Account       6fc52c9d-398b-4305-9763-15f42c1676fc
     Send Welcome Email        70b29d51-b59a-4773-9280-8841dfd3f2ea
     Send Onboarding Reminder  3C860712-2D37-42A4-928F-5C93935D26A1
     Add User To Groups        22085229-5809-45e8-97fd-270d28d66910

 ──────────────────────────────────────────────────────────────────────────────
 SAFETY
 ──────────────────────────────────────────────────────────────────────────────

    Dry-run is the DEFAULT. Tenant changes require -Execute without -WhatIf.
    Workflow definition JSON files are written locally in either mode.
   Workflows are created DISABLED with scheduling OFF. Run them on-demand
   against a test user first — on-demand is the equivalent of report-only
   for Conditional Access.

 Required scope: LifecycleWorkflows.ReadWrite.All
 Module: Microsoft.Graph.Identity.Governance
================================================================================
#>

[CmdletBinding()]
param(
    [switch]  $Execute,
    [switch]  $WhatIf,
    [bool]    $PipelineOwnsAccountState = $true,
    [string]  $JoinerScopeRule = "(department ne null)",
    [string]  $LeaverScopeRule = "(department ne null)",
    [int]     $JoinerOffsetDays = 0,      # 0 = on the hire date
    [int]     $LeaverOffsetDays = -1,     # -1 = the day BEFORE the leave date
    [string]  $OutputFolder = "C:\Users\nicol\OneDrive\Documents\audit\lifecycle-workflows"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

Connect-MgGraph -Scopes "LifecycleWorkflows.ReadWrite.All" -NoWelcome

$apply = $Execute -and -not $WhatIf
$mode = if ($apply) { 'EXECUTE' } else { 'WHATIF' }
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " Lifecycle Workflows — mode: $mode" -ForegroundColor Yellow
Write-Host " Pipeline owns account state: $PipelineOwnsAccountState" -ForegroundColor Yellow
if (-not $apply) { Write-Host " No tenant changes will be made. Local JSON definitions will still be written." -ForegroundColor Yellow }
Write-Host "=============================================" -ForegroundColor Yellow


# ==============================================================================
# 1 — Resolve task definitions from the tenant
# ==============================================================================
Write-Host "`n[1] Resolving task definitions" -ForegroundColor Cyan

try {
    $definitions = @(Get-MgIdentityGovernanceLifecycleWorkflowTaskDefinition -All)
}
catch {
    Write-Error "Could not read task definitions: $($_.Exception.Message). Confirm the Microsoft.Graph.Identity.Governance module is installed and LifecycleWorkflows.ReadWrite.All is granted."
    return
}

Write-Host "    $($definitions.Count) task definition(s) available in this tenant"

# Cross-check against the IDs Microsoft documents. A mismatch does not stop the
# run — the tenant is authoritative — but it is worth surfacing, because it
# means either the docs or this script is out of date.
$documented = @{
    'Enable User Account'      = '6fc52c9d-398b-4305-9763-15f42c1676fc'
    'Send Welcome Email'       = '70b29d51-b59a-4773-9280-8841dfd3f2ea'
    'Send Onboarding Reminder' = '3c860712-2d37-42a4-928f-5c93935d26a1'
    'Add User To Groups'       = '22085229-5809-45e8-97fd-270d28d66910'
}

function Resolve-Task {
    param([string[]] $NamePattern, [switch] $Optional)

    $match = @($definitions | Where-Object {
        $displayName = $_.DisplayName
        @($NamePattern | Where-Object { $displayName -like $_ }).Count -gt 0
    })

    if ($match.Count -eq 1) {
        $d = $match[0]
        # Surface a drift between the docs and the tenant rather than hiding it.
        foreach ($k in $documented.Keys) {
            if ($d.DisplayName -like "*$k*" -and $d.Id.ToLower() -ne $documented[$k].ToLower()) {
                Write-Warning "    '$($d.DisplayName)' has ID $($d.Id) — Microsoft's documentation says $($documented[$k]). Using the tenant's value."
            }
        }
        Write-Host ("    [OK]   {0,-46} {1}" -f $d.DisplayName, $d.Id) -ForegroundColor Green
        return $d
    }

    if ($match.Count -eq 0) {
        if ($Optional) {
            Write-Host ("    [SKIP] {0,-46} not found among tenant task definitions" -f ($NamePattern -join ' OR ')) -ForegroundColor Yellow
            return $null
        }
        throw "Required task '$($NamePattern -join ' OR ')' not found among $($definitions.Count) definitions. Refusing to create a workflow with a missing task."
    }

    throw "Task pattern '$NamePattern' matched $($match.Count) definitions: $($match.DisplayName -join ', '). Narrow the pattern."
}


# ==============================================================================
# 2 — Joiner workflow
# ==============================================================================
Write-Host "`n[2] Joiner workflow" -ForegroundColor Cyan

$joinerTasks = @()
$seq = 1

# Enable User Account — ONLY if nothing else owns account state.
if (-not $PipelineOwnsAccountState) {
    $t = Resolve-Task -NamePattern '*Enable User Account*'
    $joinerTasks += @{
        continueOnError = $false; displayName = $t.DisplayName
        description = 'Enable the account on the hire date'
        isEnabled = $true; taskDefinitionId = $t.Id; executionSequence = $seq++; arguments = @()
    }
} else {
    Write-Host "    [OMIT] Enable User Account — the provisioning pipeline owns account state" -ForegroundColor Cyan
}

# Temporary Access Pass. The reason a joiner workflow is worth having at all:
# nothing else bootstraps a first credential for someone with no password yet.
$tap = Resolve-Task -NamePattern @('*Temporary Access Pass*', '*TAP*Email*', '*Pass*email*') -Optional
if ($tap) {
    $joinerTasks += @{
        continueOnError = $false; displayName = $tap.DisplayName
        description = 'Generate a Temporary Access Pass and send it to the manager'
        isEnabled = $true; taskDefinitionId = $tap.Id; executionSequence = $seq++
        arguments = @(
            @{ name = 'tapLifetimeMinutes'; value = '480' }   # one working day
            @{ name = 'tapIsUsableOnce';    value = 'true' }  # single use — a reusable TAP is a standing credential
        )
    }
}

$welcome = Resolve-Task -NamePattern '*Welcome Email*' -Optional
if ($welcome) {
    $joinerTasks += @{
        continueOnError = $true; displayName = $welcome.DisplayName
        description = 'Send the welcome email'
        isEnabled = $true; taskDefinitionId = $welcome.Id; executionSequence = $seq++; arguments = @()
    }
}

$joinerBody = @{
    category            = 'joiner'
    displayName         = 'Joiner — onboarding tasks'
    description         = 'Credential bootstrap and notifications on the hire date. Account creation and state are owned by the provisioning pipeline.'
    isEnabled           = $false     # created OFF — run on-demand first
    isSchedulingEnabled = $false
    executionConditions = @{
        '@odata.type' = '#microsoft.graph.identityGovernance.triggerAndScopeBasedConditions'
        scope   = @{ '@odata.type' = '#microsoft.graph.identityGovernance.ruleBasedSubjectSet'; rule = $JoinerScopeRule }
        trigger = @{ '@odata.type' = '#microsoft.graph.identityGovernance.timeBasedAttributeTrigger'
                     timeBasedAttribute = 'employeeHireDate'; offsetInDays = $JoinerOffsetDays }
    }
    tasks = $joinerTasks
}

Write-Host "    $($joinerTasks.Count) task(s), trigger: employeeHireDate offset $JoinerOffsetDays day(s), scope: $JoinerScopeRule"


# ==============================================================================
# 3 — Leaver workflow
# ==============================================================================
Write-Host "`n[3] Leaver workflow" -ForegroundColor Cyan

$leaverTasks = @()
$seq = 1

# Notify the manager BEFORE the last day. Offset is negative for that reason —
# a leaver workflow that fires on the day is too late to be useful.
$mgrEmail = Resolve-Task -NamePattern @('*manager*last day*', '*before*last day*') -Optional
if ($mgrEmail) {
    # This task does not send to a raw BambooHR email string. It resolves the manager
    # in Entra and sends to the manager user's mailbox. If the manager user does not
    # exist in Entra, or exists without a valid mail property, the task fails even when
    # BambooHR contains manager data. A valid Entra manager record is a prerequisite.
    $leaverTasks += @{
        continueOnError = $true; displayName = $mgrEmail.DisplayName
        description = 'Notify the manager ahead of the last working day'
        isEnabled = $true; taskDefinitionId = $mgrEmail.Id; executionSequence = $seq++; arguments = @()
    }
}

# Licence removal is cost, not security — safe for a workflow to own, because
# nothing else is competing for it.
$licences = Resolve-Task -NamePattern '*Remove all license*' -Optional
if ($licences) {
    $leaverTasks += @{
        continueOnError = $true; displayName = $licences.DisplayName
        description = 'Reclaim licence assignments'
        isEnabled = $true; taskDefinitionId = $licences.Id; executionSequence = $seq++; arguments = @()
    }
}

# Disable User Account — OMITTED when the pipeline owns account state.
# This is the single most important line in this script.
if (-not $PipelineOwnsAccountState) {
    $disable = Resolve-Task -NamePattern '*Disable User Account*'
    $leaverTasks += @{
        continueOnError = $false; displayName = $disable.DisplayName
        description = 'Disable the account'
        isEnabled = $true; taskDefinitionId = $disable.Id; executionSequence = $seq++; arguments = @()
    }
} else {
    Write-Host "    [OMIT] Disable User Account — the provisioning pipeline sets active:false" -ForegroundColor Cyan
    Write-Host "           Two systems disabling the same account on independent schedules is" -ForegroundColor DarkGray
    Write-Host "           a race condition. The pipeline owns state; this owns everything else." -ForegroundColor DarkGray
}

# Group removal is deliberately NOT included. Where access is attribute-driven,
# dynamic groups already drop a disabled user — and a workflow stripping groups
# in parallel competes with that. Add it only if nothing else owns membership.
Write-Host "    [OMIT] Remove from all groups — dynamic groups drop disabled users automatically" -ForegroundColor Cyan

if ($leaverTasks.Count -eq 0) {
    Write-Warning "    Leaver workflow has NO tasks. With the pipeline owning account state and"
    Write-Warning "    dynamic groups owning membership, there may be nothing left for it to do."
    Write-Warning "    That is a legitimate outcome — skip the leaver workflow rather than create an empty one."
}

$leaverBody = @{
    category            = 'leaver'
    displayName         = 'Leaver — offboarding tasks'
    description         = 'Notifications and licence reclamation ahead of the last day. Account state is owned by the provisioning pipeline.'
    isEnabled           = $false
    isSchedulingEnabled = $false
    executionConditions = @{
        '@odata.type' = '#microsoft.graph.identityGovernance.triggerAndScopeBasedConditions'
        scope   = @{ '@odata.type' = '#microsoft.graph.identityGovernance.ruleBasedSubjectSet'; rule = $LeaverScopeRule }
        trigger = @{ '@odata.type' = '#microsoft.graph.identityGovernance.timeBasedAttributeTrigger'
                     timeBasedAttribute = 'employeeLeaveDateTime'; offsetInDays = $LeaverOffsetDays }
    }
    tasks = $leaverTasks
}

Write-Host "    $($leaverTasks.Count) task(s), trigger: employeeLeaveDateTime offset $LeaverOffsetDays day(s), scope: $LeaverScopeRule"


# ==============================================================================
# 4 — Create
# ==============================================================================
Write-Host "`n[4] Creating" -ForegroundColor Cyan

$existing = @(Get-MgIdentityGovernanceLifecycleWorkflow -All)
$created  = @()

foreach ($wf in @(
    @{ Name = $joinerBody.displayName; Body = $joinerBody }
    @{ Name = $leaverBody.displayName; Body = $leaverBody }
)) {
    if ($wf.Body.tasks.Count -eq 0) {
        Write-Host "    [SKIP] $($wf.Name) — no tasks to run" -ForegroundColor Yellow
        continue
    }
    if ($existing.DisplayName -contains $wf.Name) {
        Write-Host "    [SKIP] $($wf.Name) — already exists, leaving alone" -ForegroundColor Yellow
        continue
    }
    if ($apply) {
        $new = New-MgIdentityGovernanceLifecycleWorkflow -BodyParameter $wf.Body
        Write-Host "    [OK]   $($wf.Name) — created DISABLED, id $($new.Id)" -ForegroundColor Green
        $created += $new
    }
    else {
        Write-Host "    [WOULD] Create $($wf.Name) with $($wf.Body.tasks.Count) task(s), disabled" -ForegroundColor Cyan
    }
}

# Keep the definitions regardless of mode — the dry run is the review artefact.
$joinerBody | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputFolder "joiner-workflow.json")
$leaverBody | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputFolder "leaver-workflow.json")


# ==============================================================================
# Summary
# ==============================================================================
Write-Host ""
Write-Host "============================================="
Write-Host " Next steps"
Write-Host "============================================="
Write-Host " 1. Confirm the trigger attributes are populated:"
Write-Host "      .\Test-WorkflowReadiness.ps1"
Write-Host "    A workflow whose trigger attribute is blank shows as enabled,"
Write-Host "    reports no errors, and never runs."
Write-Host ""
Write-Host " 2. Run each workflow ON-DEMAND against one test user."
Write-Host "    On-demand is the equivalent of report-only for Conditional Access."
Write-Host ""
Write-Host " 3. Read the run history. A workflow reporting success having done"
Write-Host "    nothing is the failure mode to watch for."
Write-Host ""
Write-Host " 4. Only then enable it and turn scheduling on."
Write-Host "============================================="
Write-Host ""
Write-Host "Definitions written to $OutputFolder"
if (-not $apply) { Write-Host ""; Write-Host "This was a dry run. Re-run with -Execute and without -WhatIf to apply." -ForegroundColor Cyan }

Disconnect-MgGraph | Out-Null
