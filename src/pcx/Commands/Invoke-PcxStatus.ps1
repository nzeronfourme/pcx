<#
.SYNOPSIS
    Internal, read-only `status` view of applied and undone items.

.DESCRIPTION
    `status` is not a user-facing command (AS10: doctor, tune, probe and undo
    only).
    It exists so the agent and the tests can see what the session journal
    records without parsing JSON by hand.

    It reads every session-*.json under %LOCALAPPDATA%\pcx\journal, newest
    first, and lists only the items whose status is COMMITTED (applied) or
    UNDONE. Each row carries the plan id, item id, action id, status and the
    session timestamp (the last time that session was written, which is when
    the status changed).

    Nothing is created, nothing is written, no plan is re-validated and no
    target is read. A malformed session is reported as an unreadable session,
    never silently skipped.
#>

Set-StrictMode -Version 2.0

function Invoke-PcxStatus {
    <#
    .SYNOPSIS
        Lists applied/undone items from the session journal.

    .DESCRIPTION
        Read-only. Returns @{ ok; schema; sessions; items }. `sessions` carries
        one summary per session file; `items` carries the flattened rows.
    #>
    [CmdletBinding()]
    param()

    $sessions = @(Get-PcxUndoJournalSessions)

    # Same deterministic order as `undo --last`: sequence, createdAtUtc, planId.
    $ordered = @(Sort-PcxUndoSessions -Sessions $sessions)

    $rows = New-Object System.Collections.Generic.List[object]
    $summaries = New-Object System.Collections.Generic.List[object]

    foreach ($session in $ordered) {
        if ($null -ne $session.error) {
            [void]$summaries.Add([ordered]@{
                    planId    = $null
                    updatedAt = $session.updatedAt
                    applied   = 0
                    undone    = 0
                    error     = [string]$session.error
                })
            continue
        }

        $planId = [string](Get-PcxPolicyMember -Object $session.document -Name 'planId')
        $timestamp = [string](Get-PcxPolicyMember -Object $session.document -Name 'updatedAt')
        $applied = 0
        $undone = 0

        foreach ($record in @(Get-PcxPolicyMember -Object $session.document -Name 'items')) {
            if ($null -eq $record) { continue }

            $status = [string](Get-PcxPolicyMember -Object $record -Name 'status')
            if ($status -eq $script:PcxUndoCommitted) { $applied++ }
            elseif ($status -eq $script:PcxUndoUndone) { $undone++ }
            else { continue }

            [void]$rows.Add([ordered]@{
                    planId    = $planId
                    itemId    = [string](Get-PcxPolicyMember -Object $record -Name 'id')
                    actionId  = [string](Get-PcxPolicyMember -Object $record -Name 'actionId')
                    status    = $status
                    timestamp = $timestamp
                })
        }

        [void]$summaries.Add([ordered]@{
                planId    = $planId
                updatedAt = $timestamp
                applied   = $applied
                undone    = $undone
                error     = $null
            })
    }

    return [pscustomobject][ordered]@{
        ok       = $true
        schema   = 'pcx-status/1'
        sessions = @($summaries.ToArray())
        items    = @($rows.ToArray())
    }
}
