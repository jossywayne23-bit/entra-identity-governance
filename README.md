# Identity Governance in Microsoft Entra ID

Three control planes, built and evidenced in a live Entra ID P2 tenant: authentication-time enforcement, entitlement governance, and privileged access governance.

They are frequently treated as one topic. They are not. This repository separates them, explains what each answers, and states which to reach for in a given situation.

---

## Business Problem

Most tenants have all three problems and a name for only one of them.

> A user signs in from an unmanaged device on a foreign network, with a password and nothing else. They reach a SharePoint site they inherited from a role they left eighteen months ago. Their colleague, who holds Global Administrator permanently, resets a password at 2am and no record says why.

Three failures, three different controls, and no single product fixes all of them.

| Failure | Control plane | What's missing |
|---|---|---|
| Weak authentication, unmanaged device | Conditional Access | Nothing evaluates the sign-in |
| Access inherited from a former role | Entitlement governance | Nothing removes access when the reason for it ends |
| Permanent admin rights, unexplained use | Privileged access governance | Access is granted rather than requested |

---

## Architecture

The organising idea, and the thing that makes these separable:

> **Conditional Access is the door. Entitlement governance is the rooms you hold keys to. Privileged access governance is the key you borrow for an hour and hand back.**

Each answers a different question, at a different moment, about a different population.

| | Question | Evaluated when | Population | Mechanism |
|---|---|---|---|---|
| **Conditional Access** | Should this sign-in be allowed, and on what terms? | Every authentication | Everyone | CA policies |
| **Entitlement governance** | What should this identity be able to reach? | On attribute change, or on request | Everyone | Dynamic groups · access packages |
| **Privileged access governance** | May this person become an admin right now? | On elevation request | A handful | PIM · break glass · Administrative Units |

```
                       ┌─────────────────────────────┐
   sign-in attempt ───►│   CONDITIONAL ACCESS        │  the door
                       │   device · risk · location  │  evaluated every time
                       └──────────────┬──────────────┘
                                      │ allowed
                    ┌─────────────────┴─────────────────┐
                    ▼                                   ▼
     ┌──────────────────────────┐        ┌──────────────────────────┐
     │  ENTITLEMENT GOVERNANCE  │        │  PRIVILEGED ACCESS       │
     │  standing access         │        │  temporary elevation     │
     │                          │        │                          │
     │  dynamic groups          │        │  PIM eligible roles      │
     │  access packages         │        │  justification + approval│
     │  auto-revoke on change   │        │  expires in hours        │
     └────────────┬─────────────┘        └────────────┬─────────────┘
                  │                                   │
                  └──────────────┬────────────────────┘
                                 ▼
                    ┌────────────────────────┐
                    │    ACCESS REVIEWS      │  the only shared control
                    │    both, separately    │  different reviewers
                    └────────────────────────┘

   ─────────────────────────────────────────────────────────────────
   LIFECYCLE WORKFLOWS — orchestration, not a fourth plane
   Triggers on employeeHireDate / employeeLeaveDateTime, written by the
   provisioning pipeline upstream. Runs the tasks no plane covers:
   temporary access passes, manager notifications, licence removal.
   The pipeline owns account state; this owns everything around it.
```

### The test that separates entitlement from privileged

One question decides it:

> **If this access were held permanently, would that itself be the problem?**

| Access | Held permanently? | Therefore |
|---|---|---|
| Finance SharePoint site, for a finance employee | Fine — that's the point | **Entitlement governance** |
| Global Administrator | The permanence *is* the risk, whoever holds it | **Privileged access governance** |
| A contractor's project folder | Fine while the project runs | **Entitlement governance**, with an expiry |
| Ability to reset any password in the tenant | Yes — that's standing compromise | **Privileged access governance**, scoped to an AU |

Everything else follows from that. Entitlement governance asks *who should hold this*. Privileged access governance starts from *nobody should hold this permanently* and works backwards.

### Where they legitimately overlap

An access package can grant **eligibility** for a privileged role rather than the role itself. That combines both: the request-and-approve workflow of entitlement management, producing PIM eligibility rather than standing access.

Useful where privileged access needs a business-facing request process rather than an admin-facing one.

### Lifecycle workflows depend on upstream HR data

Lifecycle Workflows trigger on Entra attributes such as `employeeHireDate` and `employeeLeaveDateTime`. They do not read BambooHR directly and cannot populate those attributes; the HR provisioning process must write them first.

Manager tasks have two separate prerequisites:

1. The employee's manager relationship must resolve to an Entra user. BambooHR's `reportsTo` field is source data; the provisioning service must match that manager record to the correct Entra account.
2. For email tasks, the manager must have a real, usable Entra mailbox. A BambooHR email string or a manually populated Entra `mail` value does not create a mailbox.

The provisioning app's scope matters too. In the test tenant, Entra reported that it could not assign source employee `8` as a manager because `8` was not in scope for provisioning, even though an Entra account existed. After the scope was changed, the app attempted to create source ID `8` and failed with `AzureActiveDirectoryDuplicateUserPrincipalName`. These are distinct issues: the manager must be in scope, and the app must match that source record to its existing Entra account rather than attempting a duplicate create.

Keep BambooHR as the source of truth. Do not create or seed a manager account manually, and do not change a person's real department just to pass a provisioning filter. Configure the approved scope and a reliable target matching property (prefer a stable employee ID when supported; use UPN only when the incoming value exactly matches the existing UPN). Process the manager before the employee relationship, then verify the provisioning result. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) and the lifecycle section in [WALKTHROUGH.md](WALKTHROUGH.md).

---

## Compliance Mapping

| Control objective | ISO 27001:2022 | NIST 800-53 r5 | Which plane | Implementation |
|---|---|---|---|---|
| Strong authentication | A.8.5 | IA-2(1) | Conditional Access | MFA and authentication strength policies |
| Device trust | A.8.1 | AC-19 | Conditional Access | Compliant or hybrid-joined device required |
| Risk-based access decisions | A.8.16 | AC-2(12) | Conditional Access | Sign-in and user risk conditions |
| Legacy protocol elimination | A.8.20 | SC-8 | Conditional Access | Block legacy authentication |
| Least privilege | A.8.2 | AC-6 | Entitlement + Privileged | Attribute-driven groups · AU-scoped roles |
| Access granted on a business basis | A.5.15 | AC-3 | Entitlement | Access packages with approval |
| Timely revocation | A.5.18 | AC-2(3) | Entitlement | Dynamic groups re-evaluate on attribute change |
| No standing privileged access | A.8.2 | AC-2(7) | Privileged | PIM eligible assignments |
| Privileged actions justified and logged | A.8.15 | AU-2 | Privileged | Activation justification · PIM audit |
| Separation of duties | A.5.3 | AC-5 | Privileged | Approval on tier 1 roles |
| Emergency access controlled | A.5.29 | CP-2 | Privileged | Documented break glass with alerting |
| Periodic certification | A.5.18 | AC-2(j) | Both | Access reviews, run separately per plane |

---

## Implementation

### Licensing

| Capability | Requirement |
|---|---|
| Conditional Access | Entra ID **P1** |
| Dynamic groups | Entra ID **P1** |
| Risk-based conditions | Entra ID **P2** |
| Access packages (entitlement management) | Entra ID **P2** |
| Privileged Identity Management | Entra ID **P2** |
| Access reviews | Entra ID **P2** |

Only Conditional Access and dynamic groups are reachable on P1. Everything else needs P2.

### Build order, and why

| Phase | Track | Rationale |
|---|---|---|
| 0 / prerequisite | HR provisioning | Confirm identity matching and source attributes before building controls that depend on them |
| 1 | Break glass + Conditional Access foundation | Emergency access must exist before any policy can lock anyone out |
| 2 | Conditional Access policy set, report-only | Observe before enforcing |
| 3 | Conditional Access enforcement | Only after sign-in logs confirm the blast radius |
| 4 | Dynamic groups — birthright access | Attribute-driven access that self-corrects |
| 5 | Access packages — requestable access | The layer that needs approval |
| 6 | PIM — eligible assignments replace standing ones | Requires break glass from phase 1 |
| 7 | Access reviews on both planes | Certifies the steady state |
| 8 | Lifecycle Workflows | Verify lifecycle dates, manager relationships, mailbox prerequisites, and task availability |
| Ongoing | Secure Score baseline | Run before phase 1 and after each phase — measures where you stand against Microsoft's baseline |

Break glass comes first and is never negotiable. Every phase after it can lock somebody out.

Step-by-step in [WALKTHROUGH.md](WALKTHROUGH.md). Reasoning in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Verification

> **Status: design and build procedure complete; execution in progress.**
>
> Per this project's documentation standard, claims must map to real test results and actual error messages. Each row below is marked with what has actually been run in this tenant. Nothing is marked complete on the strength of the design alone.

### Track 1 — Conditional Access

| Check | Evidence | Status |
|---|---|---|
| Break glass excluded from every policy | Policy exclusion list | ⬚ |
| Report-only run analysed in sign-in logs | Sign-in log with policy result | ⬚ |
| MFA enforced | Sign-in showing the requirement | ⬚ |
| Legacy authentication blocked | Blocked sign-in in the log | ⬚ |
| Device compliance enforced | Non-compliant device blocked | ⬚ |
| Risk-based policy fires | Risky sign-in triggering MFA | ⬚ |
| Phishing-resistant MFA on admin roles | Admin sign-in with strength requirement | ⬚ |

### Track 2 — Entitlement governance

| Check | Evidence | Status |
|---|---|---|
| Dynamic group populates by attribute | Membership matching the rule | ⬚ |
| Department change moves group membership | Before/after membership | ⬚ |
| Access package request and approval | Request with approver decision | ⬚ |
| Access package expires and revokes | Assignment removed at expiry | ⬚ |

### Track 3 — Privileged access governance

| Check | Evidence | Status |
|---|---|---|
| Standing assignments removed | PIM showing eligible-only | ⬚ |
| Activation requires MFA and justification | Activation request | ⬚ |
| Approval workflow completes | Approver granting a request | ⬚ |
| Role auto-removed at expiry | Audit entry | ⬚ |
| AU-scoped admin fails outside scope | Failed action | ⬚ |
| Break glass sign-in alerts | Alert fired by a test sign-in | ⬚ |

### Track 4 — Lifecycle Workflows

| Check | Evidence | Status |
|---|---|---|
| Joiner and leaver trigger attributes are populated | Entra user properties and readiness output | ⬚ |
| Source manager is in provisioning scope and matched to the existing Entra user | Provisioning log shows a match, not a create | ⬚ |
| Manager relationship is applied to the employee | Provisioning log and Entra user manager property | ⬚ |
| Manager notification has a real mailbox recipient | Entra manager `mail` and a successful task run | ⬚ |
| Workflow tested on demand before scheduling | Workflow run history | ⬚ |

### Track 5 — Access reviews

| Check | Evidence | Status |
|---|---|---|
| Review on group/package membership | Completed review with decisions | ⬚ |
| Review on privileged roles | Completed review with decisions | ⬚ |
| Decisions auto-applied | Access removed following a deny | ⬚ |

---

## Repository Contents

```
├── README.md              ← this file — the three planes and when to use each
├── ARCHITECTURE.md        ← design decisions, per plane, with the reasoning
├── WALKTHROUGH.md         ← step-by-step build across all three tracks
├── TROUBLESHOOTING.md     ← real incidents: symptom, root cause, fix
├── policies/              ← Conditional Access policy definitions
├── scripts/
│   ├── Test-GovernancePosture.ps1         ← read-only check across all three planes
│   ├── Get-SecureScoreIdentityRunbook.ps1 ← Secure Score → prioritised remediation runbook
│   ├── Find-DuplicateIdentities.ps1       ← accounts that probably represent the same human
│   ├── Watch-AccessChanges.ps1            ← who was added to a group or package, and tell the owner
│   ├── Get-AccountHygiene.ps1             ← orphaned vs stale vs guest, separated
│   └── Deploy-GovernanceBaseline.ps1      ← automates the safe phases, refuses the rest
├── lifecycle-workflows/   ← joiner/leaver orchestration and its attribute dependency
├── screenshots/           ← evidence by track
└── evidence/              ← exported reports, anonymised
```

---

## Continuous Access Evaluation

Mostly already on, so the work is verification rather than configuration.

CAE lets a supported service re-evaluate access mid-session instead of waiting for the token to expire — so a disabled account or a revoked session takes effect in near real time rather than up to an hour later. It is enabled by default in most tenants.

Two things to know:

**It only covers CAE-capable services and clients.** Exchange Online, SharePoint Online, Teams and Graph, accessed by modern clients. Applications outside that set still hold their token for its full lifetime, which is why "removing group membership does not immediately revoke access" remains true in the general case.

**A Conditional Access session control can disable it.** That is the thing to check — nobody needs to turn CAE on, but somebody may have turned it off. In the portal it appears as a session control named "Customize continuous access evaluation"; if any policy has it set to Disable, find out why.

It closes part of the token-lifetime gap. It does not close all of it, and it is not a substitute for deactivating a role promptly.

---

## Which to Implement, for Which Case

The practical version of the question.

| Situation | Reach for |
|---|---|
| "Anyone can sign in with just a password" | **Conditional Access** — MFA, device compliance, legacy block |
| "People keep access after changing department" | **Dynamic groups** — attribute-driven, self-correcting |
| "Access requests go through email and nobody tracks them" | **Access packages** — request, approve, expire, audit |
| "Everyone in IT is a Global Administrator" | **PIM** — eligible assignments, activation with justification |
| "One admin can reset any password in the company" | **Administrative Units** — scope the role to a population |
| "Nobody knows who has access to what" | **Access reviews** — but fix the granting first, or you'll certify chaos |
| "We got locked out by our own policy" | **Break glass** — before anything else |
| "Contractors keep access after the project ends" | **Access packages** with an expiry, not a group |
| "We need to prove access was justified" | **PIM** for privileged, **access packages** for everything else |

### The sequencing mistake worth avoiding

Running access reviews before fixing how access is granted produces a certified mess. The reviewer approves what exists because they have no basis to challenge it, and you now hold an audit artefact stating that the access was reviewed.

Fix the granting mechanism first. Review afterwards, when there is a defensible baseline to review against.

---

## Measurement

Two read-only scripts, both safe to run against production.

**`Test-GovernancePosture.ps1`** — checks the specific things this build gets wrong. A Conditional Access policy missing its break-glass exclusion, a dynamic group rule omitting `accountEnabled`, standing tier 1 role assignments, eligibility with no expiry. Run it before starting for a baseline, then after each phase.

**`Find-DuplicateIdentities.ps1`** — finds accounts that probably represent the same person. Every upstream control reduces the risk of provisioning creating a second account for someone who already has one; none eliminates it. This is the check that asks whether it happened anyway. Findings are tiered: two accounts sharing an `employeeId` is urgent, two with none is probably a duplicate, two with different ones is probably two real people.

**`Get-SecureScoreIdentityRunbook.ps1`** — pulls Microsoft Secure Score, keeps the identity controls, and produces a remediation runbook ordered by **points per unit of effort**, each finding mapped to the plane that owns it.

The ordering matters more than it sounds. Secure Score sorts by points; a ten-point control needing a device-enrolment programme outranks a five-point control that inconveniences nobody. Dividing points by Microsoft's own user-impact rating inverts that, which is usually the correct order to actually work in.

> **Two different Secure Scores.** This reads **Microsoft Secure Score** via the Graph Security API — identity, devices, apps, data. It is not **Defender for Cloud Secure Score**, which scores Azure resource configuration. The names are nearly identical and the confusion is common: if a recommendation concerns a storage account or a VM, you are reading the wrong one.

What the score does not tell you: whether a control is *working*, whether anyone reads its alerts, or whether an exception list has quietly grown to cover everyone. A tenant can score well with a Conditional Access policy excluding half the workforce. Use it to find gaps, not to conclude there are none.

---

## Honest Limits

**Scope.** This covers Entra ID: sign-ins, group and package membership, and directory role assignments. It does not cover local server administrators, service account credentials, database or network device access. Those need a PAM platform.

**Conditional Access is not Zero Trust.** It is one enforcement point in a Zero Trust architecture. Device management, network segmentation, data classification and workload identity are all outside this repository.

**Token lifetime.** Removing group membership or deactivating a role does not invalidate an existing access token. Continuous Access Evaluation closes this for supported applications; for others there is a window.

**Reviews depend on reviewers.** A review where everything is approved unread is worse than no review — it manufactures assurance.

**This is a lab tenant.** The controls and reasoning are real; the scale is not. Nothing here has been operated through a real incident or across thousands of users.
