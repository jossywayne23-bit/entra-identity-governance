# Walkthrough

Build order across three tracks, from a tenant with none of it in place.

**Read phase 1 completely before starting.** Every phase after it can lock somebody out.

---

## Prerequisites

| | |
|---|---|
| Entra ID **P2** | Risk conditions, access packages, PIM and access reviews all require it |
| Global Administrator | For initial configuration |
| A verified domain | For break glass UPNs |
| Offline credential storage | A safe or sealed envelope — not a password manager that depends on the tenant |
| Test users across several departments | Dynamic group rules need something to evaluate |

---

## Phase 1 — Break glass, before anything else

Two accounts, so a single account problem is not a lockout.

- Cloud-only, on the `.onmicrosoft.com` domain — not a custom domain with DNS or federation dependencies
- Names that make their purpose obvious and their exclusion auditable: `bg-emergency-01@`
- Long random passwords, generated and stored offline
- Permanently assigned Global Administrator — the one legitimate exception to eligible-only, because PIM may be the thing that failed

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","RoleManagement.ReadWrite.Directory"

$pw = @{ Password = "<generated offline, never typed here>"; ForceChangePasswordNextSignIn = $false }
$bg = New-MgUser -DisplayName "Break Glass 01" `
    -UserPrincipalName "bg-emergency-01@<tenant>.onmicrosoft.com" `
    -MailNickname "bg-emergency-01" -AccountEnabled -PasswordProfile $pw

$role = Get-MgDirectoryRole -Filter "displayName eq 'Global Administrator'"
New-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id `
    -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($bg.Id)" }
```

Never put the password in a script, a variable you echo, or your shell history.

**Restricted management AU** — protects them from tenant-wide admins:

```powershell
New-MgDirectoryAdministrativeUnit -BodyParameter @{
    displayName                  = "Protected - Break Glass"
    isMemberManagementRestricted = $true
}
```

`isMemberManagementRestricted` cannot be changed after creation.

**Verify before continuing:** sign in as break glass successfully, in a private window.

---

## Phase 2 — Conditional Access, report-only

Disable Security Defaults first — they conflict with Conditional Access and cannot coexist.

Build every policy in **report-only**. Every policy excludes break glass. Every one, without exception.

| Policy | Scope | Control |
|---|---|---|
| Require MFA | All users, all cloud apps | MFA |
| Block legacy authentication | All users, legacy clients | Block |
| Require compliant device | All users, all cloud apps | Compliant or hybrid-joined |
| MFA on sign-in risk | All users, medium and high risk | MFA |
| Password change on high user risk | All users, high user risk | Password change + MFA |
| Phishing-resistant MFA for admins | Directory roles | Authentication strength |

Verify the exclusions are actually there:

```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Select-Object DisplayName, State,
        @{N='Excluded';E={$_.Conditions.Users.ExcludeUsers -join ', '}} |
    Format-Table -AutoSize
```

A policy that forgot the exclusion is a lockout waiting for an outage.

---

## Phase 3 — Analyse, then enforce

Leave report-only running for **several days**, not hours. You need a full working week to catch weekly jobs, weekend access and the service accounts nobody remembered.

Entra admin centre → **Sign-in logs** → the Report-only tab shows what each policy *would* have done.

What to look for:

- Service accounts that would be blocked — they usually cannot do MFA
- Legacy clients still in use — find the owner before blocking
- Devices that are not compliant — a device enrolment problem, not a policy problem
- Any admin that would be locked out

Enforce **one policy at a time**, starting with the narrowest. Block legacy authentication first: it has the clearest signal in the logs and the smallest legitimate population.

---

## Phase 4 — Dynamic groups for birthright access

Attribute-driven membership that re-evaluates when the attribute changes.

Entra admin centre → **Groups** → New → Membership type **Dynamic User**.

```
(user.department -eq "Finance") and (user.accountEnabled -eq true)
```

Include `accountEnabled` so a disabled account drops out of the group. Without it, a disabled user keeps group-derived access — invisible, because they cannot sign in to reveal it.

**Test the correction, not just the population:** change a test user's department and confirm they leave one group and join the other. Membership updates are asynchronous; allow a few minutes.

---

## Phase 5 — Access packages for requestable access

Entra admin centre → **Identity Governance** → **Entitlement management** → Access packages.

| Setting | Guidance |
|---|---|
| Resources | Groups, applications, SharePoint sites |
| Who can request | A scoped population, not "all users" |
| Approval | Manager, or a named owner |
| Justification | Required |
| **Expiry** | Always. Access without an end date outlives its reason. |
| Access review on the assignment | For anything long-lived |

**Test the full cycle:** request, approve, verify access, wait for expiry, verify removal. The removal half is the one people skip and the one that matters.

---

## Phase 6 — PIM

### 6.1 Inventory first

```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","Directory.Read.All"

$roleDefinitions = @{}
foreach ($roleDefinition in Get-MgRoleManagementDirectoryRoleDefinition -All) {
    $roleDefinitions[$roleDefinition.Id] = $roleDefinition.DisplayName
}

Get-MgRoleManagementDirectoryRoleAssignment -All -ExpandProperty Principal |
    Select-Object @{N='Role';E={$roleDefinitions[$_.RoleDefinitionId]}},
                  @{N='Principal';E={$_.Principal.AdditionalProperties.displayName}} |
    Sort-Object Role | Export-Csv "standing-assignments-before.csv" -NoTypeInformation
```

This is your rollback reference and your before/after evidence.

### 6.2 Configure role settings before assigning

PIM → **Microsoft Entra roles** → Settings, per role:

| Setting | Tier 1 (Global Admin, Privileged Role Admin, Security Admin) | Tier 2 (User Admin, Helpdesk) |
|---|---|---|
| Max activation duration | 2–4 hours | 8 hours |
| MFA on activation | Yes | Yes |
| Justification | Yes | Yes |
| Approval | **Yes** | No |
| Approvers | Named individuals | — |
| Notification | Yes | Yes |

Settings before assignments, so the first activation already behaves correctly.

### 6.3 Eligible assignments

PIM → role → Add assignments → assignment type **Eligible**.

Set an expiry on the **eligibility itself**, not only on activation. Eligibility with no end date is standing access with an extra click.

### 6.4 Remove standing assignments

**Only after** an activation has been tested end to end. Leave break glass permanently assigned.

---

## Phase 7 — Access reviews, separately per plane

Entra admin centre → **Identity Governance** → Access reviews.

| | Entitlement review | Privileged review |
|---|---|---|
| Scope | Group or package membership | Entra directory roles |
| Reviewer | Manager | Security owner |
| Frequency | Quarterly | Quarterly |
| Auto-apply | Yes | Yes |
| No response | **Remove access** | **Remove access** |

Two reviews, because they ask different questions of different people. Combining them produces a review nobody is qualified to complete in full.

The "no response" setting is the one people get wrong. Defaulting to no-change certifies everything the reviewer ignored.

---

## Phase 8 — HR provisioning and Lifecycle Workflows

This phase connects BambooHR source data to Entra users and then to workflow tasks. Keep the boundaries clear: BambooHR owns employee facts, the provisioning app creates or updates Entra users, and Lifecycle Workflows reacts to the resulting Entra attributes.

### 8.1 Confirm the BambooHR source fields

Use BambooHR `/v1/meta/fields` and the custom report to verify the aliases used by the HR-Sync runbook. In this test tenant, the manager employee-reference field is `reportsTo`.

```powershell
$body = @{ fields = @('id','displayName','department','reportsTo') } | ConvertTo-Json
$report = Invoke-RestMethod -Method POST `
    -Uri "https://api.bamboohr.com/api/gateway.php/$subdomain/v1/reports/custom?format=JSON" `
    -Headers @{ Authorization = "Basic $base64Auth"; 'Content-Type' = 'application/json'; Accept = 'application/json' } `
    -Body $body

$report.employees |
    Where-Object { $_.reportsTo } |
    Select-Object -First 10 id, displayName, department, reportsTo
```

An employee-reference field may return an employee ID or a display name. Resolve IDs directly; resolve names only when they uniquely identify one person in the report. Do not guess when a name is ambiguous. Keep the actual department and manager data in BambooHR; do not create or seed Entra users manually for a demonstration.

### 8.2 Verify target matching before changing scope

The API-driven provisioning app must match an existing BambooHR record to the right Entra user. Map the stable BambooHR employee ID consistently to Entra `employeeId` and configure it as a matching property when the service supports it. If using UPN matching instead, make sure the incoming `userName` exactly equals the existing Entra UPN.

In the test tenant, after a manager was brought into scope, the provisioning log said source ID `8` would be **created** and then failed with `AzureActiveDirectoryDuplicateUserPrincipalName`. That proves the target was not matched; it is not a manager-relationship error. Correct matching first. Do not delete the existing account or keep retrying a duplicate create.

### 8.3 Include the manager record in provisioning scope

The API-driven provisioning app must be allowed to process the manager record so it can resolve `manager.value`. An Entra account can already exist and still be unusable as a manager reference when its BambooHR source record is outside the app's scope.

The observed error was:

> We were unable to assign 8 as the manager of ... Ensure that 8 is in scope for provisioning. Provision 8 on-demand and then provision ... on-demand, or restart provisioning after ensuring that 8 is in scope.

Review the app's **Scoping filters** and department allow-list. If policy permits provisioning the manager's actual department, include it and confirm the identity matching from step 8.2 before running. Do not change an Operations employee's department to Human Resources just to pass the filter. If policy excludes that department, document that the relationship cannot be provisioned through this app rather than falsifying source data.

The HR-Sync plan checks whether an Entra account with the manager's `employeeId` exists. It cannot override the provisioning app's separate source scope. The SCIM `manager.value` is resolved by the provisioning service, not by a manual Graph relationship write.

### 8.4 Provision the manager, then the employee

After matching and scope are correct:

1. Run the HR-Sync plan-only check. Review manager counts, each manager-only update, and all creates/disables. Do not proceed if a known existing manager is reported as a create or as missing from Entra.
2. Provision the manager record on-demand in the API-driven provisioning app.
3. Provision the employee on-demand, or restart provisioning after the manager is in scope, as directed by the provisioning log.
4. Inspect the provisioning log for both records. Confirm the manager source ID matched the intended existing Entra user and that the employee export completed with the manager property applied. `202 Accepted` from bulkUpload only means the request was received.
5. Check the employee's Entra user properties and confirm the **Manager** relationship points to the intended person.

### 8.5 Verify mail and lifecycle triggers separately

A manager relationship does not create a mailbox. For tasks that send manager email, confirm the manager has a real mailbox and a valid Entra `mail` value. A blank `mail` is not fixed by copying an HR address onto the user; assign and configure a real mailbox, or do not rely on that email task.

Lifecycle Workflows also require the trigger dates to be present and valid in Entra:

```powershell
Connect-MgGraph -Scopes 'User.Read.All'
Get-MgUser -UserId '<employee UPN>' -Property DisplayName,EmployeeHireDate,EmployeeLeaveDateTime |
    Select-Object DisplayName,EmployeeHireDate,EmployeeLeaveDateTime
```

The test report returned populated termination fields for 109 people, but only 3 projected-date values and 40 standard termination-date values parsed as dates. Inspect and correct unparseable BambooHR values before using them to drive live leaver actions.

Finally, run the workflow on-demand for one test identity and inspect its run history. Confirm the intended notification task is available in the tenant and succeeds before enabling a schedule. The pipeline owns account enabled/disabled state; do not add competing enable/disable workflow tasks.

---

## Verification checklist

Nothing counts until observed.

**Conditional Access**
- [ ] Break glass signs in successfully
- [ ] Break glass excluded from every enabled policy
- [ ] A sign-in is blocked for missing MFA
- [ ] A legacy client is blocked
- [ ] A non-compliant device is blocked
- [ ] A risky sign-in triggers step-up

**Entitlement**
- [ ] Dynamic group populates by rule
- [ ] Department change moves membership both ways
- [ ] Disabled user drops out of the group
- [ ] Access package request reaches an approver
- [ ] Access package expiry removes access

**Privileged**
- [ ] Standing assignments removed, break glass excepted
- [ ] Activation requires MFA and justification
- [ ] Approval reaches the approver and can be granted
- [ ] Role auto-removed at expiry, visible in audit
- [ ] AU-scoped admin **fails** outside scope
- [ ] Break glass sign-in produces an alert

**Lifecycle**
- [ ] BambooHR field aliases and sample `reportsTo` values verified
- [ ] Existing manager matches the correct Entra user; no duplicate create attempted
- [ ] Manager is in provisioning scope and manager link is applied to employee
- [ ] Manager notification task has a real mailbox recipient
- [ ] Hire/leave dates are valid on Entra user objects
- [ ] Joiner/leaver workflow tested on-demand before scheduling

**Reviews**
- [ ] Both reviews complete and apply decisions

---

## Pitfalls

**Break glass before anything else.** Two accounts, offline credentials, excluded from every policy.

**Report-only for days, not hours.** A working week catches what an afternoon does not.

**Enforce one policy at a time.** Simultaneous enforcement makes attribution impossible when something breaks.

**Never remove standing admin access before testing activation.** If PIM is misconfigured you have locked yourself out with only break glass left.

**Include `accountEnabled` in dynamic group rules.** Otherwise disabled accounts retain group-derived access.

**Always set an expiry on access packages.**

**`isMemberManagementRestricted` cannot be changed after creation.**

**Do not put normal users in a restricted management AU.** They become unmanageable by PIM, entitlement management, Lifecycle Workflows and access reviews.

**Fix granting before reviewing.** A review over an unstructured estate certifies the mess.
