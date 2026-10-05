# Architecture

Design decisions across three control planes, and the reasoning behind each.

---

## Why three planes rather than one

They are separable because they answer different questions at different moments, and because a failure in one does not compensate for a failure in another.

Conditional Access on a tenant where everyone holds Global Administrator is a stronger door on a building with no internal walls. PIM on a tenant with no Conditional Access is a borrowed key that anyone with a stolen password can request.

The planes are independent in what they enforce and dependent in what they're worth.

| | Fails open as | Fails closed as |
|---|---|---|
| Conditional Access | Password-only access from anywhere | Everyone locked out, including admins |
| Entitlement governance | Access accretion over years | Nobody can reach the tools they need |
| Privileged access | Standing admin rights | No one can administer during an incident |

Break glass exists because two of those failure modes lock out the people who would fix them.

---

## Plane 1 — Conditional Access

### Why report-only first, without exception

A Conditional Access policy targeting all users can lock out all users, and one targeting directory roles can lock out every administrator simultaneously.

Report-only evaluates the policy and records what *would* have happened without enforcing it. Several days of sign-in logs tell you the real blast radius, including the service accounts and legacy clients nobody remembered.

The cost of report-only is a few days. The cost of skipping it is a tenant-wide outage with no administrative path back in.

### Why break glass is excluded from every policy, always

Conditional Access depends on services that can fail: the MFA service, device compliance evaluation, the identity provider's own availability. A policy requiring compliant devices is unenforceable during an Intune outage, and it fails closed.

Break glass accounts exist for exactly that, which means they cannot depend on the systems that might have failed.

**The trade-off, stated plainly:** these accounts are deliberately the weakest authentication path in the tenant. That is defensible only with long random credentials stored offline, sign-in alerting a human actually receives, and quarterly verification that they still work. Without the monitoring, the exclusion is just a hole.

### Why block legacy authentication separately

Legacy protocols — IMAP, POP, SMTP AUTH, older Office clients — cannot perform multi-factor authentication. A policy requiring MFA simply does not apply to them, so they bypass the entire control set rather than failing it.

It is a separate policy because it is a separate decision: MFA policies can be tuned, and legacy auth should be off.

### Why authentication strength, not just "require MFA"

"Require MFA" accepts SMS and voice call, both of which are phishable and both of which are defeated by SIM swap.

Authentication strength lets you demand phishing-resistant methods — FIDO2, Windows Hello for Business, certificate-based. For administrative roles that is the difference between a control and a speed bump.

For the general population it is usually a rollout problem rather than a policy problem, which is why the admin policy and the all-users policy are separate.

---

## Plane 2 — Entitlement governance

### Why dynamic groups for birthright access

Attribute-driven membership self-corrects. When a department attribute changes, the user leaves the old group and joins the new one without a script deciding what to remove.

The alternative — a mover workflow manipulating group membership — has to remember everything it granted. Miss one and you get permission accretion, which is precisely what access reviews exist to find. Attribute-driven access strips itself, and the residue that still needs manual handling becomes small enough to actually review.

This is why the provisioning pipeline upstream writes **attributes only** and never touches group membership.

### Why access packages for anything requestable

Birthright access is what everyone in a role gets. Access packages are for what somebody has to ask for.

The difference matters because a request creates three things a group membership does not: a business justification, an approver's decision, and an expiry date. Those are the artefacts an auditor asks for, and a group membership cannot produce them.

### Why an expiry rather than a permanent grant

Access without an end date outlives its reason. The project finishes, the secondment ends, the vendor engagement closes — and the access remains because nobody's job was to remove it.

An expiry inverts the default: access ends unless someone actively extends it. That converts a reactive cleanup task into a scheduled decision.

### Why dynamic group evaluation latency matters

Membership updates are asynchronous. After a department change there is a window — usually minutes — where the old access persists.

It is short, it is real, and it should be stated rather than discovered. For genuinely sensitive transitions, membership change is not a substitute for an explicit revocation step.

---

## Plane 3 — Privileged access governance

### Why eligible assignments rather than active ones

An active assignment is permanent access. An eligible assignment is permission to *request* access.

The difference is the exposure window. A permanently-assigned Global Administrator is a valid target every hour of every day. An eligible one is a target only during the minutes they are activated — and that activation leaves a record of who, when and why.

It also produces the artefact permanent assignment cannot: an audit trail of *use*, not just of *grant*.

### Why require justification if nobody reads it

Two reasons, and the second matters more.

The obvious one is the audit trail — when somebody asks why a change was made at 2am, the justification is the answer.

The less obvious one: typing a reason creates a pause. Elevation stops being reflexive. Small enough not to obstruct real work, large enough to make casual elevation feel like a decision.

Justifications going unread is a real failure mode. It is addressed by reading them during access reviews, not by dropping the requirement.

### Why approval on some roles and not all

Approval blocks work until somebody responds. Applied everywhere it gets bypassed with standing approvers, or it slows every routine task until people route around it.

Applied to roles where a single activation compromises the tenant — Global Administrator, Privileged Role Administrator, Security Administrator — the cost is paid rarely and buys a second human in the loop for the actions that matter.

**The rule:** approval where a mistake is tenant-wide and irreversible. Notification only where it is bounded and recoverable.

### Why MFA at activation when MFA already happened at sign-in

Because the sign-in may have been hours ago, and a stolen session token carries its authentication state with it.

MFA at activation proves the human is present *at the moment privilege is requested*, closing the gap where a hijacked session silently elevates itself.

### Why Administrative Units

Role assignment defaults to the whole tenant. A User Administrator assigned normally can reset any password in the organisation, including other administrators'.

An AU-scoped assignment confines that to a defined population. It is the difference between an admin who can affect their own users and one who can affect everyone.

**A caveat:** a service principal or guest cannot use an AU-scoped role assignment unless it also holds directory read permissions, because neither receives directory read by default. Without it the scoped role silently does nothing, producing 403s that look like a broken assignment.

### Why break glass sits in a restricted management AU

A normal AU scopes what an admin *can* manage. A restricted management AU also protects its members *from* tenant-wide admins.

For break glass that is the right property: a compromised Global Administrator cannot modify or disable the accounts that exist to recover from a compromised Global Administrator.

**Two constraints:** `isMemberManagementRestricted` must be set at creation and cannot be changed afterwards. And members are excluded from PIM, entitlement management, Lifecycle Workflows and access reviews — acceptable for break glass, unacceptable for anyone else.

---

## Lifecycle Workflows — the bridge, not a fourth plane

### Where it fits

Lifecycle Workflows is not a fourth control plane. It is **event-driven orchestration** sitting between provisioning and the planes: it reacts to lifecycle attributes and runs tasks, some of which are access changes and some of which are not.

```
HR PROVISIONING PIPELINE
  writes attributes
        │
        ├─ department, jobTitle ──────► dynamic groups · access packages
        │                                (entitlement plane — self-correcting)
        │
        └─ employeeHireDate,           ► LIFECYCLE WORKFLOWS
           employeeLeaveDateTime         (orchestration — notify · TAP · licences)
```

Dynamic groups react to *what someone is*. Lifecycle Workflows react to *a moment in their employment*. Those are different triggers and they belong to different mechanisms.

### What it does that nothing else does

| Task | Why no other plane covers it |
|---|---|
| Generate a Temporary Access Pass for a new starter | Not access governance — credential bootstrapping |
| Notify a manager before a last working day | Not access at all — a communication |
| Remove licence assignments on a leaver | Cost, not security |
| Run a custom task extension | Anything the built-in catalogue does not cover |

### The ownership boundary, and why it matters

Lifecycle Workflows **can** disable an account. So can a provisioning pipeline. Both running on independent schedules against the same account is how you get behaviour nobody can explain — a race condition in the identity layer, surfacing as "the account keeps re-enabling itself".

Pick one owner and document it.

| | Owns | Does not touch |
|---|---|---|
| **Provisioning pipeline** | Account creation · attributes · enabled/disabled state | Groups · licences · notifications |
| **Lifecycle Workflows** | TAP · notifications · licence removal · custom tasks | Enabled/disabled state |
| **Entitlement plane** | Group and package membership | Everything above |

The rule: **the pipeline owns account state; Lifecycle Workflows owns everything around it.** If a leaver workflow is configured with a "Disable user account" task while the pipeline is also setting `active: false`, remove the task from the workflow.

### The dependency people miss

Lifecycle Workflows triggers on `employeeHireDate` and `employeeLeaveDateTime`. It cannot create a user, and it cannot populate those attributes — something upstream must write them.

**A provisioning pipeline that does not send those dates means the workflows never fire.** The configuration looks correct, the workflow shows as enabled, and nothing ever happens. Verify the attributes are populated on a real user before concluding a workflow is broken.

Checking is one line:

```powershell
Get-MgUser -UserId <upn> -Property employeeHireDate,employeeLeaveDateTime |
    Select-Object DisplayName, EmployeeHireDate, EmployeeLeaveDateTime
```

Blank means the workflow can never trigger, whatever the portal says.

### Manager relationships are provisioned, not inferred by the workflow

The BambooHR employee-reference field `reportsTo` is source data. In this implementation it may contain an employee ID or a display name; the HR sync resolves the value to a unique BambooHR employee record and emits that employee's ID as SCIM `manager.value` in the Enterprise User extension. Ambiguous names are omitted rather than guessed. Lifecycle Workflows does not read BambooHR and cannot repair a missing manager relationship.

For the provisioning service to apply that reference, two independent conditions must hold:

1. **The manager source record is in provisioning scope.** An Entra account can already exist and still be unavailable to the provisioning service when its BambooHR record is excluded by the app's scoping filters. Process the manager before the employee, or rerun the employee after the manager is in scope.
2. **The manager source record matches the intended Entra user.** Map a stable employee ID consistently and use it as a matching property where supported. If matching falls back to UPN, the incoming value must match the existing Entra UPN exactly. A duplicate-UPN create error means matching failed; it is not fixed by changing the manager's department or deleting the existing user.

Keep HR attributes truthful. Do not manually create or seed an Entra manager to make a demonstration work, and do not change a real department solely to bypass scope. If policy excludes the manager's department, the relationship cannot be established by that provisioning app until an approved scope decision is made.

The manager relationship is also distinct from the manager's mailbox. A populated `mail` string does not create an Exchange mailbox. Manager-notification tasks require both a resolved Entra manager relationship and a real, usable mailbox; missing mail is a mailbox/licensing issue, not something to paper over by copying an HR value.

In the test tenant, provisioning reported that source employee `8` was out of scope when referenced as a manager. After scope changed, the app attempted to create source `8` and failed with `AzureActiveDirectoryDuplicateUserPrincipalName`. The first message identified a scope problem; the second exposed a separate target-matching problem. This is why request acceptance, account existence, and an HR manager value are not sufficient evidence that the relationship was applied. Verify the provisioning logs and the resulting Entra Manager property. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the incident details and [WALKTHROUGH.md](WALKTHROUGH.md) for the safe validation sequence.

### Mover workflows are beta-only

Joiner and Leaver workflows are generally available. The **Mover** trigger — `attributeChangeTrigger`, firing on a department or job title change — is beta at time of writing, which means the beta Graph module and no production support commitment.

For most mover scenarios this does not matter: dynamic groups already handle the access change, and they handle it better because the correction is automatic rather than scripted. The mover workflow is only needed for the surrounding tasks — notifying the old and new manager, say.

Verify current GA status before building on it.

---

## Cross-plane decisions

### Why access reviews run separately per plane

Same mechanism, different question, different reviewer.

An entitlement review asks *should this person still reach this application* — the manager knows. A privileged review asks *should this person still be able to become an administrator* — a security owner knows.

Combining them produces a review nobody is qualified to complete in full, which is how rubber-stamping starts.

### Why "no response" must default to deny

A review that defaults to "no change" certifies everything the reviewer ignored. It produces an audit artefact stating that privileged access was reviewed, when in fact nothing was read.

Defaulting to removal makes silence expensive to the right person — the one who should have responded — rather than expensive to the organisation later.

### Why granting is fixed before reviewing

A review conducted over an unstructured access estate certifies the mess. The reviewer approves what exists because there is no defensible basis for challenging any individual item.

Fix the mechanism — attribute-driven birthright, requestable elevated, eligible-only privileged — and the review becomes a question about a small, explicable set of exceptions.

### Why Conditional Access applies to both other planes

It is orthogonal, not sequential. A CA policy evaluates the sign-in regardless of whether the user is about to open a SharePoint site or activate a privileged role.

The one place it becomes plane-specific is authentication strength on directory roles, which is a stronger requirement applied to a smaller population — practical precisely because those accounts are used infrequently.

---

## What this architecture does not address

- **Credentials outside Entra.** Local server administrators, service accounts, database and network device credentials. PAM territory.
- **What happens during a session.** These planes govern whether access is granted. They do not record, proxy or constrain what is then done with it.
- **Token lifetime.** Removing membership or deactivating a role does not invalidate an existing token. CAE closes this for supported applications only.
- **Workload identity.** Service principals and managed identities have their own governance problem, only partly addressed by the same tools.
- **Data classification.** Governing access to a SharePoint site says nothing about what is in it.
- **Approval quality.** An approver who approves everything is a rubber stamp with extra steps.
