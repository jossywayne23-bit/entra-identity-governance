# Troubleshooting

One entry per incident: symptom, root cause, fix, and how production differs.

---

## HR Provisioning and Lifecycle Workflows

These incidents were observed while testing BambooHR-to-Entra provisioning and manager-dependent lifecycle tasks. A `202 Accepted` response means bulkUpload received the request; it does not mean Entra successfully processed every record. Always inspect the provisioning logs for the final result.

### 1. Manager relationship rejected because the manager was out of scope

**Observed message**

> We were unable to assign 8 as the manager of ... In order to ensure that the references are updated properly, you have two options. First, ensure that 8 is in scope for provisioning. Provision 8 on-demand and then provision ... on-demand. Alternatively, you can restart provisioning after ensuring that 8 is in scope for provisioning.

**Cause**

The manager record was outside the API-driven provisioning app's scope. An existing Entra account was not sufficient: the provisioning service also needed to process the manager source record so it could resolve the reference. The manager's BambooHR department was Operations, outside the app's then-current allowed department scope.

**Fix**

Keep the employee's real department in BambooHR. Confirm that the provisioning app's scope includes the manager when policy allows it. Verify target matching before expanding scope (see incident 2), then provision the manager on-demand before the employee, or restart provisioning after the manager is in scope. If policy intentionally excludes that department, document that the manager relationship cannot be established by this provisioning job; do not falsify the source department to force it through.

### 2. Out-of-scope manager was treated as a new user and hit a duplicate UPN

**Observed error**

`AzureActiveDirectoryDuplicateUserPrincipalName`

The provisioning log showed source ID `8` would be created, then failed because the resulting UPN already existed in Entra.

**Cause**

After the manager was brought into scope, the provisioning app did not match the BambooHR record to the existing Entra account. It attempted a create instead. Scope and identity matching are separate controls: fixing the first does not fix the second.

**Fix**

In the API-driven provisioning app's attribute mapping, configure a stable matching property that identifies the existing account. Prefer the BambooHR employee ID mapped consistently to Entra `employeeId` when supported by the app. The existing manager's Entra employee ID must equal the BambooHR ID. If using UPN matching, the incoming `userName` must exactly equal the existing Entra UPN. Confirm the provisioning log says the source matched the existing target user before retrying the employee relationship. Do not delete and recreate the account to work around a matching error.

### 3. Manager notification cannot deliver

**Observed data-quality finding**

The readiness output reported manager accounts with blank Entra `mail` values (50 employee-manager relationships in one test run; this is a relationship count, not necessarily 50 distinct managers).

**Cause**

The manager relationship and the manager's mailbox are different things. BambooHR may identify the manager, but a blank Entra `mail` can mean there is no provisioned mailbox. Setting a text address on the user does not create a mailbox and can make a task appear successful while mail is undeliverable.

**Fix**

Resolve the manager relationship through provisioning, then confirm the manager has a real mailbox and an appropriate Exchange license or mail-enabled configuration. Do not fabricate `mail` from a BambooHR value. If the manager is intentionally not mail-enabled, do not rely on the manager-email task for that person.

### 4. Lifecycle date fields exist but most values do not parse

**Observed test output**

One 109-person report had 109 populated values in each termination field, but only 3 projected-date values and 40 standard termination-date values parsed as dates; the remainder were reported invalid.

**Cause**

Field presence is not proof that the BambooHR report returns usable dates. The values may be in an unexpected format or contain non-date text. Lifecycle Workflows cannot trigger reliably from values that the upstream provisioning mapping does not write as valid Entra dates.

**Fix**

Inspect the raw BambooHR values for the affected records, verify the report field aliases, and correct or normalize the source data before enabling a live leaver action. Confirm the final `employeeHireDate` or `employeeLeaveDateTime` value on the Entra user and verify the provisioning result. Do not interpret a populated-but-unparseable field as a successful trigger value.

### Lessons learned

- BambooHR is the source of truth. Do not manually create a manager in Entra or manually seed `employeeId` to make a demonstration link work.
- A manager relationship requires a resolvable source manager, a correctly matched Entra target, and provisioning scope that includes the manager record. These are separate prerequisites.
- A manager's `mail` value is not the same as a mailbox. Never manufacture it to silence a workflow warning.
- Department scope is a provisioning policy, not a data-cleanup tool. Preserve the real HR department and change scope only after reviewing the access and account-creation impact.
- A successful request receipt, an enabled workflow, and a green-looking task are not proof of the end-to-end result. Check provisioning logs, Entra user properties, and workflow run history.
- Test plan-only first, review every planned manager link and account-state change, then use on-demand provisioning/workflow runs for a single test identity before scheduling.

---

## Known constraints — documented, not yet encountered

From Microsoft's documentation rather than from this build. Listed separately because they have not been hit here and must not be presented as findings.

| Constraint | Consequence | Track |
|---|---|---|
| Security Defaults and Conditional Access cannot coexist | Defaults must be disabled before any policy applies | CA |
| Report-only results appear only in the sign-in log's Report-only tab | Easy to conclude a policy "isn't working" | CA |
| Legacy authentication cannot perform MFA | An MFA policy does not apply to it — it must be blocked separately | CA |
| Dynamic group evaluation is asynchronous | A window exists after an attribute change where old access persists | Entitlement |
| A rule without `accountEnabled` retains disabled users | Disabled accounts keep group-derived access | Entitlement |
| `isMemberManagementRestricted` cannot be changed after AU creation | Delete and rebuild if set wrongly | Privileged |
| Restricted management AU members are excluded from PIM, entitlement management, Lifecycle Workflows and access reviews | Acceptable for break glass only | Privileged |
| A service principal cannot use an AU-scoped role assignment without directory read | Silent failure presenting as 403 | Privileged |
| Deactivating a role does not invalidate an existing access token | CAE closes this for supported apps only | Privileged |
| PIM, access packages, access reviews and risk conditions all require P2 | Most of this build is impossible on P1 | All |

If any is encountered during the build, it graduates to a numbered entry above with the real error attached.
