# Runbooks

Azure Automation runbooks. Scheduled, managed identity, email delivery.

## Why these and not the `scripts/` versions

`scripts/` holds the interactive tools — run them by hand when investigating.

These are the same logic as scheduled controls. The difference is not the code, it is the delivery: a CSV on somebody's desktop requires that person to be at that machine, to remember, and to look. A runbook runs whether anyone remembers or not.

**The CSV is evidence. The email is the control.**

## Schedules

| Runbook | Cadence | Why |
|---|---|---|
| `Runbook-DuplicateCheck` | 15–20 min after HR-Sync | Provisioning is asynchronous; running immediately after upload sees nothing |
| `Runbook-AccessChangeWatch` | Daily, or hourly for high-sensitivity groups | Direct group additions are silent otherwise |

## Automation variables

Both reuse what HR-Sync already has: `AlertTo`, `GmailAddress`, `GmailAppPassword`.

## Managed identity permissions

| Runbook | Graph permissions |
|---|---|
| `Runbook-DuplicateCheck` | `User.Read.All` |
| `Runbook-AccessChangeWatch` | `AuditLog.Read.All`, `Group.Read.All`, `User.Read.All`, `Mail.Send` |

`Mail.Send` is an application permission — it lets the identity send as any mailbox in the tenant. Scope it with an application access policy to the single sending mailbox, or accept that it is broader than it looks.

## Alerting behaviour

Both call `Write-Error` when they find something, which marks the Automation job as **failed**. An Azure Monitor alert rule on job failure then catches the finding even if SMTP is blocked from the sandbox.

Two independent paths. An alert channel that fails silently is not an alert.

`Runbook-DuplicateCheck` alerts only on tiers 0, 1 and 2. Tier 4 is two real people sharing a name — emailing about it every run is how a control teaches people to ignore it.
