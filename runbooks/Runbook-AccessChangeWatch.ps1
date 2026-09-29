<#
================================================================================
 RUNBOOK: Access-Change-Watch

 Reports who was added to a watched group or assigned an access
   package, notifies the group owner, and summarises to the identity team.

   Entra notifies on access PACKAGE assignment. It does NOT notify anyone when
   someone is added directly to a group. The mechanism with the weakest
   governance is the one with no notification.

 WHY A RUNBOOK RATHER THAN A LOCAL SCRIPT
   A report written to somebody's desktop is not an alert. It requires that
   person to be at that machine, to remember, and to look. Scheduled in Azure
   Automation on a managed identity, this runs whether anyone remembers or not
   and delivers its finding by email.

   The CSV is evidence. The email is the control.

 SCHEDULE: Daily, or hourly for high-sensitivity groups.
 Credentials: managed identity for Graph; Gmail app password for SMTP.
================================================================================
#>

param(
    [int]      $LookBackHours = 24,
    [string[]] $WatchedGroups = @(),
    [string]   $FromAddress
)

$ErrorActionPreference = 'Stop'

$alertTo      = Get-AutomationVariable -Name 'AlertTo'
$gmailAddress = Get-AutomationVariable -Name 'GmailAddress'
$gmailPass    = Get-AutomationVariable -Name 'GmailAppPassword'

# Runbooks have no persistent filesystem. Write to job temp, attach to the
# email, let the sandbox discard it. The email IS the persistence.
$OutputFolder = Join-Path $env:TEMP 'access-changes'
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

function Send-Alert {
    param([string] $Subject, [string] $Body, [string[]] $Attachments = @())
    try {
        $secure = ConvertTo-SecureString $gmailPass -AsPlainText -Force
        $cred   = New-Object System.Management.Automation.PSCredential($gmailAddress, $secure)
        $p = @{ From=$gmailAddress; To=$alertTo; Subject=$Subject; Body=$Body
                SmtpServer='smtp.gmail.com'; Port=587; UseSsl=$true; Credential=$cred
                WarningAction='SilentlyContinue' }
        if ($Attachments.Count -gt 0) { $p['Attachments'] = $Attachments }
        Send-MailMessage @p
        Write-Output "  [alert emailed to $alertTo]"
    }
    catch { Write-Warning "  Email alert failed: $($_.Exception.Message)" }
}

Connect-MgGraph -Identity -NoWelcome

$since = (Get-Date).AddHours(-$LookBackHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")


# ------------------------------------------------------------------------------
# 1 — Group membership additions
# ------------------------------------------------------------------------------
Write-Output "[*] Reading directory audit log — last $LookBackHours hour(s)..."

$audit = @(Get-MgAuditLogDirectoryAudit -Filter "activityDateTime ge $since" -All)

$adds = @($audit | Where-Object { $_.ActivityDisplayName -eq 'Add member to group' -and $_.Result -eq 'success' })
Write-Output "    $($adds.Count) group membership addition(s)"

# Dynamic membership shows in the audit log the same as a manual add. The
# distinction matters: a dynamic add is the rule working, a manual add is a
# decision somebody made. Only the second needs a human to know.
$groupCache = @{}
function Get-GroupInfo {
    param([string] $GroupId)
    if ($groupCache.ContainsKey($GroupId)) { return $groupCache[$GroupId] }
    try {
        $g = Get-MgGroup -GroupId $GroupId -Property Id,DisplayName,GroupTypes,SecurityEnabled -ErrorAction Stop
        $owners = @()
        try { $owners = @(Get-MgGroupOwner -GroupId $GroupId -All -ErrorAction Stop) } catch { }
        $info = [PSCustomObject]@{
            DisplayName = $g.DisplayName
            IsDynamic   = ($g.GroupTypes -contains 'DynamicMembership')
            IsSecurity  = $g.SecurityEnabled
            OwnerUpns   = @($owners | ForEach-Object { $_.AdditionalProperties.userPrincipalName } | Where-Object { $_ })
        }
    }
    catch {
        $info = [PSCustomObject]@{ DisplayName = "(deleted or inaccessible)"; IsDynamic = $false; IsSecurity = $false; OwnerUpns = @() }
    }
    $groupCache[$GroupId] = $info
    return $info
}

$findings = foreach ($a in $adds) {
    $target    = $a.TargetResources | Where-Object { $_.Type -eq 'Group' } | Select-Object -First 1
    $member    = $a.TargetResources | Where-Object { $_.Type -eq 'User' }  | Select-Object -First 1
    if (-not $target) { continue }

    $g = Get-GroupInfo -GroupId $target.Id

    if ($WatchedGroups.Count -gt 0 -and $g.DisplayName -notin $WatchedGroups) { continue }
    if ($WatchedGroups.Count -eq 0 -and -not $g.IsSecurity) { continue }

    [PSCustomObject]@{
        When       = $a.ActivityDateTime
        Type       = if ($g.IsDynamic) { 'Group (dynamic)' } else { 'Group (manual)' }
        Resource   = $g.DisplayName
        Member     = if ($member) { $member.UserPrincipalName } else { '(unknown)' }
        AddedBy    = $a.InitiatedBy.User.UserPrincipalName
        Owners     = ($g.OwnerUpns -join '; ')
        NeedsOwner = (-not $g.IsDynamic)     # a rule adding someone is not a decision
    }
}
$findings = @($findings)


# ------------------------------------------------------------------------------
# 2 — Access package assignments
# ------------------------------------------------------------------------------
Write-Output "[*] Reading access package assignments..."

try {
    $pkgAssignments = @(Get-MgEntitlementManagementAssignment -All -ExpandProperty AccessPackage,Target |
        Where-Object { $_.Schedule.StartDateTime -ge (Get-Date).AddHours(-$LookBackHours) })

    foreach ($p in $pkgAssignments) {
        $findings += [PSCustomObject]@{
            When       = $p.Schedule.StartDateTime
            Type       = 'Access package'
            Resource   = $p.AccessPackage.DisplayName
            Member     = $p.Target.Email
            AddedBy    = '(entitlement management)'
            Owners     = ''
            NeedsOwner = $false      # package assignment already notifies
        }
    }
    Write-Output "    $($pkgAssignments.Count) package assignment(s)"
}
catch {
    Write-Warning "    Could not read entitlement assignments: $($_.Exception.Message). Confirm Entra ID P2."
}


# ------------------------------------------------------------------------------
# 3 — Report
# ------------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$path  = Join-Path $OutputFolder "access-changes-$stamp.csv"

if ($findings.Count -gt 0) { $findings | Sort-Object When -Descending | Export-Csv $path -NoTypeInformation }
else { "When,Type,Resource,Member,AddedBy,Owners,NeedsOwner" | Set-Content $path }

Write-Output ""
Write-Output "============================================="
Write-Output " Access Changes — last $LookBackHours hour(s)"
Write-Output "============================================="
if ($findings.Count -eq 0) {
    Write-Output "  No changes in scope."
} else {
    $findings | Group-Object Type | ForEach-Object { Write-Output ("  {0,-18} {1}" -f $_.Name, $_.Count) }
    Write-Output ""
    $manual = @($findings | Where-Object NeedsOwner)
    if ($manual.Count -gt 0) {
        Write-Output " Manual additions — a person decided these:"
        $manual | ForEach-Object { Write-Output ("   {0} -> {1}   (by {2})" -f $_.Member, $_.Resource, $_.AddedBy) }
    }
}
Write-Output "============================================="


# ------------------------------------------------------------------------------
# 4 — Notify owners
# ------------------------------------------------------------------------------
# Only for MANUAL additions to watched groups. A dynamic add is the rule
# working as designed; emailing an owner about it is the fastest way to teach
# them to filter these messages.
if ($true) {
    $notify = @($findings | Where-Object { $_.NeedsOwner -and $_.Owners })
    Write-Output ""
    Write-Output "[*] Notifying owners of $($notify.Count) manual addition(s)..."

    foreach ($group in $notify | Group-Object Resource) {
        $owners = @(($group.Group[0].Owners -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $rows   = ($group.Group | ForEach-Object { "  $($_.Member)  — added by $($_.AddedBy) at $($_.When)" }) -join "`n"

        $body = @"
$($group.Count) member(s) were added directly to the group '$($group.Name)' in the last $LookBackHours hour(s):

$rows

Direct group additions are not governed by an approval workflow and are not
reviewed until the next access review. If any of these was not expected,
investigate now rather than at the next review cycle.
"@
        foreach ($o in $owners) {
            try {
                Send-MgUserMail -UserId $FromAddress -BodyParameter @{
                    message = @{
                        subject      = "Access change: $($group.Count) member(s) added to '$($group.Name)'"
                        body         = @{ contentType = "Text"; content = $body }
                        toRecipients = @(@{ emailAddress = @{ address = $o } })
                    }
                    saveToSentItems = "false"
                }
                Write-Output "    Notified $o about '$($group.Name)'"
            }
            catch { Write-Warning "    Could not notify $o : $($_.Exception.Message)" }
        }
    }

    $noOwner = @($findings | Where-Object { $_.NeedsOwner -and -not $_.Owners })
    if ($noOwner.Count -gt 0) {
        Write-Warning "$($noOwner.Count) manual addition(s) to groups with NO OWNER — nobody can be told."
        $noOwner | Select-Object -ExpandProperty Resource -Unique | ForEach-Object { Write-Output "      $_" }
    }
}


# ------------------------------------------------------------------------------
# Summary alert
# ------------------------------------------------------------------------------
# Owners get told about their own group. This goes to the identity team and
# covers what no owner can see: additions to groups nobody owns.
$manual  = @($findings | Where-Object NeedsOwner)
$noOwner = @($manual   | Where-Object { -not $_.Owners })

if ($manual.Count -gt 0) {
    $rows = ($manual | ForEach-Object { "  $($_.Member) -> $($_.Resource)  (by $($_.AddedBy))" }) -join "`n"
    $orphanNote = if ($noOwner.Count -gt 0) {
        "`n`n$($noOwner.Count) of these are groups with NO OWNER — nobody could be notified:`n" +
        (($noOwner | Select-Object -ExpandProperty Resource -Unique | ForEach-Object { "  $_" }) -join "`n")
    } else { "" }

    Send-Alert -Subject "$($manual.Count) manual group addition(s) in the last $LookBackHours hour(s)" -Attachments @($path) -Body @"
Direct group additions are not governed by an approval workflow and are not
reviewed until the next access review.

$rows$orphanNote

Full report attached.
"@
}
else { Write-Output "No manual additions in scope." }

Disconnect-MgGraph | Out-Null
