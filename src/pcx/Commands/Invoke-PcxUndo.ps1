<#
.SYNOPSIS
    `pcx undo`: hash-proven restore of applied items, and the elevated child.

.DESCRIPTION
    Undo consumes the per-plan session journal that `tune --apply` wrote and
    reverses each applied item through the value-level snapshot engine.

    Selectors (exactly one):
        --last            the newest session by document order (sequence,
                          then createdAtUtc, then planId; never file mtime)
        --item <id>       one applied item
        --plan <plan-id>  every applied item of one plan, LIFO

    The journal is UNTRUSTED. Before anything is reverted, for every recorded
    item:
      1. the plan file is re-validated by Test-PcxPlan (byte hash + every rule);
      2. the item must still be COMMITTED in the session (a second undo refuses);
      3. each snapshot's target identity is re-parsed and matched against the
         plan's own canonical target; a journal target that is not in the plan
         is refused (PCX-E-UNDO-JOURNAL);
      4. Test-PcxTarget is re-run under the plan profile (containment:
         a1_roots / a2_roots / the HKLM value allow-list), and the identity
         itself is policy-checked for the kinds whose identity is a complete
         write address (registry, file);
      5. the current state is compared with the recorded POST-state; any drift,
         including a moved service control set, refuses.

    Any refusal at step 1-5 exits 3 and reverts NOTHING: the preflight covers
    every selected item before the first write.

    Restore is Restore-PcxSnapshot only. There is no hive restore, no `.reg`
    merge, no --force and no emergency mode. A1 items are manifest-only and are
    reported `not restorable`; they are excluded from the equality set. A mixed
    plan therefore exits 0 when every restorable item matches.

    Elevation (one UAC, the task-12 contract)
        When any restorable target needs admin, the parent builds canonical undo
        request bytes (schema pcx-undo/1, planId, item ids), passes them as
        base64 plus their SHA-256 and the caller SID, and makes exactly ONE
        elevation call. The child re-decodes the bytes, recomputes the hash,
        re-validates the plan, re-resolves the selection, and OWNS the preflight
        and every write. The parent performs no write for an elevated undo.
        Oversized bytes (over 8192), altered bytes, a SID mismatch and a plan
        that no longer validates all refuse. No HMAC, nonce or secret.

    Exit codes: 0 every restorable item matched the pre-state; 3 drift or
    policy refusal (nothing reverted); 2 a bad selection or a second undo.
#>

Set-StrictMode -Version 2.0

$script:PcxUndoSchema = 'pcx-undo/1'
$script:PcxUndoMaxRequestBytes = 8192
$script:PcxUndoPlanIdPattern = '^[0-9a-f]{16}$'
$script:PcxUndoCommitted = 'COMMITTED'
$script:PcxUndoUndone = 'UNDONE'
$script:PcxUndoManifestOnly = 'manifest-only'

# ---------------------------------------------------------------------------
# Outcome shape
# ---------------------------------------------------------------------------

function ConvertTo-PcxUndoList {
    # @($null) is a one-element array in PowerShell; every optional list field
    # must normalize to a real empty array instead.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return ,@()
    }

    return ,@($Value)
}

function New-PcxUndoOutcome {
    param(
        [Parameter(Mandatory = $true)][bool] $Ok,
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Code,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Restored,
        [Parameter(Mandatory = $false)][AllowNull()][object] $NotRestorable,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Skipped,
        [Parameter(Mandatory = $false)][AllowNull()][object] $RestoreSet,
        [Parameter(Mandatory = $false)][bool] $Elevated = $false,
        [Parameter(Mandatory = $false)][int] $ElevationCalls = 0
    )

    return [pscustomobject][ordered]@{
        ok             = $Ok
        status         = $Status
        code           = $Code
        reason         = $Reason
        planId         = $PlanId
        restored       = (ConvertTo-PcxUndoList -Value $Restored)
        notRestorable  = (ConvertTo-PcxUndoList -Value $NotRestorable)
        skipped        = (ConvertTo-PcxUndoList -Value $Skipped)
        restoreSet     = (ConvertTo-PcxUndoList -Value $RestoreSet)
        elevated       = $Elevated
        elevationCalls = $ElevationCalls
    }
}

function New-PcxUndoRefusal {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $NotRestorable,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Skipped
    )

    return New-PcxUndoOutcome -Ok $false -Status 'refused' -Code $Code -Reason $Reason -PlanId $PlanId -NotRestorable $NotRestorable -Skipped $Skipped
}

function Get-PcxUndoExitCode {
    <#
    .SYNOPSIS
        Maps an undo diagnostic code to its documented exit code.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][string] $Code)

    if ([string]::IsNullOrWhiteSpace($Code)) {
        return 0
    }

    if ($Code.StartsWith('PCX-POLICY-', [System.StringComparison]::Ordinal)) {
        return $script:PcxExitUndoRefused
    }

    switch ($Code) {
        'PCX-E-UNDO-DRIFT' { return $script:PcxExitUndoRefused }
        'PCX-E-UNDO-JOURNAL' { return $script:PcxExitUndoRefused }
        'PCX-E-SNAPSHOT-DRIFT' { return $script:PcxExitUndoRefused }
        'PCX-E-SNAPSHOT-CONTROLSET' { return $script:PcxExitUndoRefused }
        'PCX-E-SNAPSHOT-CONFIRM' { return $script:PcxExitUndoRefused }
        'PCX-E-SNAPSHOT-UNSUPPORTED' { return $script:PcxExitUndoRefused }
        'PCX-E-SNAPSHOT-STATE' { return $script:PcxExitUndoRefused }
        'PCX-E-UAC-DECLINED' { return $script:PcxExitUndoRefused }
        'PCX-E-UAC-CHILD' { return $script:PcxExitUndoRefused }
        'PCX-E-UNDO-SELECTION' { return 2 }
        'PCX-E-UNDO-ALREADY' { return 2 }
        'PCX-E-UNDO-NOTHING' { return 2 }
        'PCX-E-UNDO-NOT-APPLIED' { return 2 }
        'PCX-E-UNDO-REQUEST' { return 2 }
        'PCX-E-UNDO-REQUEST-SIZE' { return 2 }
        'PCX-E-SID-MISMATCH' { return 2 }
        'PCX-E-PLAN-MISMATCH' { return 2 }
        'PCX-E-PLAN-SHAPE' { return 2 }
        'PCX-E-PLAN-NOTFOUND' { return 2 }
        'PCX-E-PLAN-ACTION' { return 2 }
        'PCX-E-PLAN-TARGET' { return 2 }
        'PCX-E-PLAN-EVIDENCE' { return 2 }
        'PCX-E-PLAN-INVERSE' { return 2 }
        'PCX-E-PLAN-DUPLICATE' { return 2 }
        'PCX-E-PLAN-BUILD' { return 2 }
        'PCX-E-PLAN-ORIGIN' { return 2 }
        'PCX-E-PLAN-CATEGORY' { return 2 }
        'PCX-E-PLAN-CATALOG' { return 2 }
    }

    return 1
}

function Get-PcxUndoErrorCode {
    param([Parameter(Mandatory = $true)][object] $ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $match = [regex]::Match($message, '^(PCX-[A-Z0-9-]+):')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return 'PCX-E-UNDO'
}

# ---------------------------------------------------------------------------
# Journal discovery (read-only)
# ---------------------------------------------------------------------------

function Get-PcxSessionOrderingPath {
    return Get-PcxStatePath -Kind 'journal' -ChildPath 'index.json'
}

function ConvertTo-PcxSessionOrderingStamp {
    <#
    .SYNOPSIS
        Normalizes a createdAtUtc value to one invariant round-trip string.

    .DESCRIPTION
        ConvertFrom-Json turns an ISO-8601 string into [DateTime], and [string]
        on a DateTime is culture-formatted. Ordering must never depend on the
        current culture, so a DateTime is re-emitted as 'o' in UTC.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Get-PcxSessionMaxSequence {
    # Highest sequence any session already records; a missing sequence is 0.
    $max = 0
    $directory = Get-PcxStatePath -Kind 'journal'
    if (-not [System.IO.Directory]::Exists($directory)) { return 0 }

    foreach ($file in [System.IO.Directory]::GetFiles($directory, 'session-*.json')) {
        $document = $null
        try {
            $document = Read-PcxJson -Path $file
        }
        catch {
            continue
        }

        $value = Get-PcxPolicyMember -Object $document -Name 'sequence'
        if ($null -eq $value) { continue }

        try {
            $number = [int]$value
        }
        catch {
            continue
        }
        if ($number -gt $max) { $max = $number }
    }

    return $max
}

function New-PcxSessionOrdering {
    <#
    .SYNOPSIS
        Allocates the ordering stamp for a NEW session.

    .DESCRIPTION
        The counter is persisted in journal/index.json and advances once per new
        session. A missing or corrupt index falls back to the highest sequence
        any session already records, so the counter only moves forward and a
        lost index never re-orders history.
    #>
    $path = Get-PcxSessionOrderingPath
    $current = 0
    if ([System.IO.File]::Exists($path)) {
        try {
            $document = Read-PcxJson -Path $path
            $value = Get-PcxPolicyMember -Object $document -Name 'sequence'
            if ($null -ne $value) { $current = [int]$value }
        }
        catch {
            $current = 0
        }
    }

    $maxRecorded = Get-PcxSessionMaxSequence
    if ($current -lt $maxRecorded) { $current = $maxRecorded }

    # ponytail: one pcx writer per user; a concurrent second writer would need a lock.
    $sequence = $current + 1
    $createdAtUtc = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $null = Write-PcxJsonAtomic -Path $path -InputObject ([ordered]@{
            schema       = 'pcx-journal-index/1'
            sequence     = $sequence
            createdAtUtc = $createdAtUtc
        })

    return [pscustomobject]@{ sequence = $sequence; createdAtUtc = $createdAtUtc }
}

function Get-PcxUndoJournalSessions {
    <#
    .SYNOPSIS
        Reads every session-*.json in the journal directory with its ordering
        metadata. A malformed file is returned with its error, never skipped
        silently.

    .DESCRIPTION
        Ordering is document-side, never filesystem-side: `sequence` (0 for an
        older session that has none), then `createdAtUtc`, then `planId`. Two
        sessions written in the same clock tick still have a total order.
    #>
    $sessions = New-Object System.Collections.Generic.List[object]
    $directory = Get-PcxStatePath -Kind 'journal'
    if (-not [System.IO.Directory]::Exists($directory)) {
        return $sessions.ToArray()
    }

    foreach ($file in [System.IO.Directory]::GetFiles($directory, 'session-*.json')) {
        $document = $null
        $errorText = $null
        try {
            $document = Read-PcxJson -Path $file
        }
        catch {
            $errorText = $_.Exception.Message
        }

        $updatedAt = ''
        $planId = ''
        $createdAtUtc = ''
        $sequence = 0

        if ($null -ne $document) {
            $updatedAt = [string](Get-PcxPolicyMember -Object $document -Name 'updatedAt')
            $planId = [string](Get-PcxPolicyMember -Object $document -Name 'planId')
            $createdAtUtc = ConvertTo-PcxSessionOrderingStamp -Value (Get-PcxPolicyMember -Object $document -Name 'createdAtUtc')

            $rawSequence = Get-PcxPolicyMember -Object $document -Name 'sequence'
            if ($null -ne $rawSequence) {
                try {
                    $sequence = [int]$rawSequence
                }
                catch {
                    $sequence = 0
                }
            }
        }

        [void]$sessions.Add([pscustomobject][ordered]@{
                path         = $file
                document     = $document
                error        = $errorText
                updatedAt    = $updatedAt
                planId       = $planId
                createdAtUtc = $createdAtUtc
                sequence     = $sequence
            })
    }

    return $sessions.ToArray()
}

function Sort-PcxUndoSessions {
    <#
    .SYNOPSIS
        Newest first: sequence, then createdAtUtc, then planId (all descending).
        The planId key makes the order total, so a tie can never be arbitrary.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][object[]] $Sessions)

    if ($null -eq $Sessions -or @($Sessions).Count -eq 0) {
        return @()
    }

    return @($Sessions | Sort-Object -Property `
            @{ Expression = { [int]$_.sequence } }, `
            @{ Expression = { [string]$_.createdAtUtc } }, `
            @{ Expression = { [string]$_.planId } } -Descending)
}

function Get-PcxUndoNewestSession {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Sessions)

    $ordered = @(Sort-PcxUndoSessions -Sessions $Sessions)
    if ($ordered.Count -eq 0) {
        return $null
    }

    return $ordered[0]
}

function Get-PcxUndoRecord {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $SessionDocument,
        [Parameter(Mandatory = $true)][string] $ItemId
    )

    foreach ($record in @(Get-PcxPolicyMember -Object $SessionDocument -Name 'items')) {
        if ($null -eq $record) { continue }
        if ([string]::Equals([string](Get-PcxPolicyMember -Object $record -Name 'id'), $ItemId, [System.StringComparison]::Ordinal)) {
            return $record
        }
    }

    return $null
}

function Find-PcxUndoSessionForItem {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Sessions,
        [Parameter(Mandatory = $true)][string] $ItemId
    )

    foreach ($session in @(Sort-PcxUndoSessions -Sessions $Sessions)) {
        if ($null -ne $session.error) { continue }
        if ($null -ne (Get-PcxUndoRecord -SessionDocument $session.document -ItemId $ItemId)) {
            return $session
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Session rewrite (undo owns the UNDONE status)
# ---------------------------------------------------------------------------

function Write-PcxUndoSession {
    <#
    .SYNOPSIS
        Marks the given items UNDONE and rewrites the session atomically.

    .DESCRIPTION
        Every other record, field and the plan hash are preserved byte-for-byte
        in value terms. The session schema is unchanged; only `status` and
        `updatedAt` move.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $SessionDocument,
        [Parameter(Mandatory = $true)][string] $SessionPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $UndoneIds
    )

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($record in @(Get-PcxPolicyMember -Object $SessionDocument -Name 'items')) {
        if ($null -eq $record) { continue }

        $copy = [ordered]@{}
        if ($record -is [System.Collections.IDictionary]) {
            foreach ($key in $record.Keys) { $copy[[string]$key] = $record[$key] }
        }
        else {
            foreach ($property in $record.PSObject.Properties) { $copy[$property.Name] = $property.Value }
        }

        $recordId = [string](Get-PcxPolicyMember -Object $copy -Name 'id')
        foreach ($undoneId in $UndoneIds) {
            if ([string]::Equals($recordId, [string]$undoneId, [System.StringComparison]::Ordinal)) {
                $copy['status'] = $script:PcxUndoUndone
            }
        }

        [void]$items.Add($copy)
    }

    $sequenceValue = Get-PcxPolicyMember -Object $SessionDocument -Name 'sequence'
    $sequence = 0
    if ($null -ne $sequenceValue) {
        try {
            $sequence = [int]$sequenceValue
        }
        catch {
            $sequence = 0
        }
    }

    $document = [ordered]@{
        schema       = [string](Get-PcxPolicyMember -Object $SessionDocument -Name 'schema')
        planId       = [string](Get-PcxPolicyMember -Object $SessionDocument -Name 'planId')
        planHash     = [string](Get-PcxPolicyMember -Object $SessionDocument -Name 'planHash')
        sequence     = $sequence
        createdAtUtc = (ConvertTo-PcxSessionOrderingStamp -Value (Get-PcxPolicyMember -Object $SessionDocument -Name 'createdAtUtc'))
        updatedAt    = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        items        = @($items.ToArray())
    }

    return Write-PcxJsonAtomic -Path $SessionPath -InputObject $document
}

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

function New-PcxUndoSelection {
    <#
    .SYNOPSIS
        Loads and validates one plan and its session, and resolves the item ids
        to undo.

    .DESCRIPTION
        -AllCommitted selects every COMMITTED item in plan order and reports
        UNDONE ones as skipped. -ItemIds selects exactly the given ids and
        refuses an item that is not COMMITTED.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $ItemIds,
        [Parameter(Mandatory = $false)][switch] $AllCommitted
    )

    if ($PlanId -notmatch $script:PcxUndoPlanIdPattern) {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason "plan id '$PlanId' is not 16 lowercase hex characters."
    }

    $planPath = Get-PcxStatePath -Kind 'journal' -ChildPath ('plan-' + $PlanId + '.json')
    if (-not [System.IO.File]::Exists($planPath)) {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason "no plan '$PlanId' exists at '$planPath'."
    }

    $sessionPath = Get-PcxStatePath -Kind 'journal' -ChildPath ('session-' + $PlanId + '.json')
    if (-not [System.IO.File]::Exists($sessionPath)) {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-NOTHING' -Reason "plan '$PlanId' has no session; nothing was applied." -PlanId $PlanId
    }

    $bytes = [System.IO.File]::ReadAllBytes($planPath)
    $validated = Test-PcxPlan -PlanBytes $bytes
    if (-not [bool]$validated.ok) {
        return New-PcxUndoRefusal -Code ([string]$validated.code) -Reason ([string]$validated.reason) -PlanId $PlanId
    }

    $document = $null
    try {
        $document = Read-PcxJson -Path $sessionPath
    }
    catch {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason ("the session '$sessionPath' cannot be read: {0}" -f $_.Exception.Message) -PlanId $PlanId
    }

    $planItems = @{}
    foreach ($item in @($validated.items)) {
        $planItems[[string](Get-PcxPolicyMember -Object $item -Name 'id')] = $item
    }

    $ids = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[object]

    if ($AllCommitted) {
        foreach ($item in @($validated.items)) {
            $itemId = [string](Get-PcxPolicyMember -Object $item -Name 'id')
            $record = Get-PcxUndoRecord -SessionDocument $document -ItemId $itemId
            $status = if ($null -eq $record) { '' } else { [string](Get-PcxPolicyMember -Object $record -Name 'status') }

            if ($status -eq $script:PcxUndoCommitted) {
                [void]$ids.Add($itemId)
            }
            elseif ($status -eq $script:PcxUndoUndone) {
                [void]$skipped.Add([ordered]@{ itemId = $itemId; status = $script:PcxUndoUndone })
            }
        }

        if ($ids.Count -eq 0) {
            if ($skipped.Count -gt 0) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-ALREADY' -Reason "every applied item of plan '$PlanId' is already UNDONE." -PlanId $PlanId -Skipped $skipped.ToArray()
            }
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-NOTHING' -Reason "plan '$PlanId' has no applied item to undo." -PlanId $PlanId
        }
    }
    else {
        foreach ($rawId in @($ItemIds)) {
            $itemId = [string]$rawId
            if ([string]::IsNullOrWhiteSpace($itemId)) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason 'an item id is required.' -PlanId $PlanId
            }
            if (-not $planItems.ContainsKey($itemId)) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason "item '$itemId' is not in plan '$PlanId'." -PlanId $PlanId
            }

            $record = Get-PcxUndoRecord -SessionDocument $document -ItemId $itemId
            if ($null -eq $record) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-NOTHING' -Reason "item '$itemId' has no session record." -PlanId $PlanId
            }

            $status = [string](Get-PcxPolicyMember -Object $record -Name 'status')
            if ($status -eq $script:PcxUndoUndone) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-ALREADY' -Reason "item '$itemId' is already UNDONE." -PlanId $PlanId
            }
            if ($status -ne $script:PcxUndoCommitted) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-NOT-APPLIED' -Reason "item '$itemId' is '$status'; only a COMMITTED item can be undone." -PlanId $PlanId
            }

            [void]$ids.Add($itemId)
        }
    }

    return [pscustomobject][ordered]@{
        ok              = $true
        code            = $null
        reason          = $null
        planId          = $PlanId
        plan            = $validated.plan
        planItems       = $planItems
        sessionDocument = $document
        sessionPath     = $sessionPath
        ids             = $ids.ToArray()
        skipped         = $skipped.ToArray()
        profile         = (Get-PcxPolicyMember -Object $validated.plan -Name 'profile')
    }
}

function Resolve-PcxUndoRequest {
    <#
    .SYNOPSIS
        Maps --last / --item / --plan to a plan id and a selection mode.
    #>
    param(
        [Parameter(Mandatory = $false)][bool] $Last = $false,
        [Parameter(Mandatory = $false)][AllowNull()][string] $ItemId,
        [Parameter(Mandatory = $false)][AllowNull()][string] $PlanId
    )

    $selectors = 0
    if ($Last) { $selectors++ }
    if (-not [string]::IsNullOrWhiteSpace($ItemId)) { $selectors++ }
    if (-not [string]::IsNullOrWhiteSpace($PlanId)) { $selectors++ }

    if ($selectors -ne 1) {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason 'exactly one of --last, --item or --plan is required.'
    }

    if (-not [string]::IsNullOrWhiteSpace($PlanId)) {
        return [pscustomobject]@{ ok = $true; planId = $PlanId.Trim(); itemIds = $null; allCommitted = $true }
    }

    $sessions = @(Get-PcxUndoJournalSessions)
    if ($sessions.Count -eq 0) {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-NOTHING' -Reason 'no pcx session exists; nothing was applied.'
    }

    if ($Last) {
        $newest = Get-PcxUndoNewestSession -Sessions $sessions
        if ($null -eq $newest) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-NOTHING' -Reason 'no pcx session exists; nothing was applied.'
        }
        if ($null -ne $newest.error) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason ("the newest session '{0}' cannot be read: {1}" -f $newest.path, $newest.error)
        }

        $newestPlanId = [string](Get-PcxPolicyMember -Object $newest.document -Name 'planId')
        if ($newestPlanId -notmatch $script:PcxUndoPlanIdPattern) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason "the newest session has no valid plan id ('$newestPlanId')."
        }

        return [pscustomobject]@{ ok = $true; planId = $newestPlanId; itemIds = $null; allCommitted = $true }
    }

    $session = Find-PcxUndoSessionForItem -Sessions $sessions -ItemId $ItemId
    if ($null -eq $session) {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason "no session records item '$ItemId'."
    }

    $sessionPlanId = [string](Get-PcxPolicyMember -Object $session.document -Name 'planId')
    if ($sessionPlanId -notmatch $script:PcxUndoPlanIdPattern) {
        return New-PcxUndoRefusal -Code 'PCX-E-UNDO-SELECTION' -Reason "the session for item '$ItemId' has no valid plan id."
    }

    return [pscustomobject]@{ ok = $true; planId = $sessionPlanId; itemIds = @($ItemId); allCommitted = $false }
}

# ---------------------------------------------------------------------------
# Journal target -> plan target matching
# ---------------------------------------------------------------------------

function Get-PcxUndoIdentityTarget {
    <#
    .SYNOPSIS
        Rebuilds the read/write address a snapshot identity names.

    .DESCRIPTION
        A snapshot identity is { kind; path; name } (registry), { kind; name }
        (service), { kind; path } (task) or { kind; path; restorePath } (file).
        A file identity with a restorePath is a quarantine move; without one it
        is an A1 delete.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Identity)

    $kind = ([string](Get-PcxPolicyMember -Object $Identity -Name 'kind')).Trim().ToLowerInvariant()

    switch ($kind) {
        'registry' {
            return [ordered]@{
                Kind = 'registry'
                Path = [string](Get-PcxPolicyMember -Object $Identity -Name 'path')
                Name = [string](Get-PcxPolicyMember -Object $Identity -Name 'name')
            }
        }
        'service' {
            return [ordered]@{ Kind = 'service'; Name = [string](Get-PcxPolicyMember -Object $Identity -Name 'name') }
        }
        'task' {
            return [ordered]@{ Kind = 'task'; Path = [string](Get-PcxPolicyMember -Object $Identity -Name 'path') }
        }
        'file' {
            $role = 'a1'
            $restorePath = Get-PcxPolicyMember -Object $Identity -Name 'restorePath'
            if ($null -ne $restorePath -and -not [string]::IsNullOrWhiteSpace([string]$restorePath)) {
                $role = 'quarantine'
            }
            return [ordered]@{
                Kind = 'file'
                Path = [string](Get-PcxPolicyMember -Object $Identity -Name 'path')
                Role = $role
            }
        }
    }

    return $null
}

function Test-PcxUndoCanonicalMatch {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Left,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return $false
    }
    if (-not [string]::Equals([string]$Left.kind, [string]$Right.kind, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    switch ([string]$Left.kind) {
        'registry' {
            $leftPath = [string]$Left.hive + '\' + [string]$Left.key
            $rightPath = [string]$Right.hive + '\' + [string]$Right.key
            return ([string]::Equals($leftPath, $rightPath, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$Left.name, [string]$Right.name, [System.StringComparison]::OrdinalIgnoreCase))
        }
        'service' {
            return [string]::Equals([string]$Left.name, [string]$Right.name, [System.StringComparison]::OrdinalIgnoreCase)
        }
        'task' {
            return [string]::Equals([string]$Left.path, [string]$Right.path, [System.StringComparison]::OrdinalIgnoreCase)
        }
        'file' {
            return [string]::Equals([string]$Left.path, [string]$Right.path, [System.StringComparison]::OrdinalIgnoreCase)
        }
    }

    return $false
}

function Find-PcxUndoPlanTarget {
    param(
        [Parameter(Mandatory = $true)][object] $Item,
        [Parameter(Mandatory = $true)][object] $Canonical
    )

    foreach ($candidate in @(Get-PcxPolicyMember -Object $Item -Name 'target')) {
        if ($null -eq $candidate) { continue }
        $candidateCanonical = $null
        try {
            $candidateCanonical = ConvertTo-PcxTarget -Target $candidate
        }
        catch {
            continue
        }
        if (Test-PcxUndoCanonicalMatch -Left $Canonical -Right $candidateCanonical) {
            return $candidateCanonical
        }
    }

    return $null
}

function Get-PcxUndoRecordSnapshots {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Record
    )

    return ,@(Get-PcxPolicyMember -Object $Record -Name 'snapshots')
}

# ---------------------------------------------------------------------------
# Preflight: policy, containment, journal match, drift
# ---------------------------------------------------------------------------

function Test-PcxUndoPreflight {
    <#
    .SYNOPSIS
        Validates every selected item before the first write.

    .DESCRIPTION
        Returns an outcome with restoreSet (LIFO) and notRestorable on success,
        or a refusal. Nothing is written here.
    #>
    param([Parameter(Mandatory = $true)][object] $Selection)

    $restoreSet = New-Object System.Collections.Generic.List[object]
    $notRestorable = New-Object System.Collections.Generic.List[object]

    $ids = @($Selection.ids)
    for ($index = $ids.Count - 1; $index -ge 0; $index--) {
        $itemId = [string]$ids[$index]
        $item = $Selection.planItems[$itemId]
        if ($null -eq $item) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason "item '$itemId' is selected but not in the validated plan." -PlanId $Selection.planId
        }

        $record = Get-PcxUndoRecord -SessionDocument $Selection.sessionDocument -ItemId $itemId
        if ($null -eq $record) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason "item '$itemId' has no session record." -PlanId $Selection.planId
        }

        $status = [string](Get-PcxPolicyMember -Object $record -Name 'status')
        if ($status -eq $script:PcxUndoUndone) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-ALREADY' -Reason "item '$itemId' is already UNDONE." -PlanId $Selection.planId
        }
        if ($status -ne $script:PcxUndoCommitted) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-NOT-APPLIED' -Reason "item '$itemId' is '$status'; only a COMMITTED item can be undone." -PlanId $Selection.planId
        }

        $inverse = ([string](Get-PcxPolicyMember -Object $item -Name 'inverse')).Trim().ToLowerInvariant()
        $snapshots = Get-PcxUndoRecordSnapshots -Record $record

        if ($inverse -eq $script:PcxUndoManifestOnly) {
            [void]$notRestorable.Add([ordered]@{
                    itemId     = $itemId
                    actionId   = [string](Get-PcxPolicyMember -Object $item -Name 'actionId')
                    category   = [string](Get-PcxPolicyMember -Object $item -Name 'category')
                    restoreMode = $script:PcxUndoManifestOnly
                    reason     = 'A1 is manifest-only; the deleted cache is regenerated by Windows and is never restored.'
                })
            continue
        }

        if ($snapshots.Count -eq 0) {
            return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason "item '$itemId' claims a snapshot inverse but carries no snapshot." -PlanId $Selection.planId
        }

        $ordered = New-Object System.Collections.Generic.List[object]
        for ($snapshotIndex = $snapshots.Count - 1; $snapshotIndex -ge 0; $snapshotIndex--) {
            [void]$ordered.Add($snapshots[$snapshotIndex])
        }

        foreach ($snapshot in $ordered) {
            $identity = Get-PcxPolicyMember -Object $snapshot -Name 'target'
            $identityTarget = Get-PcxUndoIdentityTarget -Identity $identity
            if ($null -eq $identityTarget) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason "item '$itemId' has a snapshot with no usable target identity." -PlanId $Selection.planId
            }

            $canonical = $null
            try {
                $canonical = ConvertTo-PcxTarget -Target $identityTarget
            }
            catch {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason ("item '$itemId' has a snapshot target that does not parse: {0}" -f $_.Exception.Message) -PlanId $Selection.planId
            }

            # A registry or file identity is a complete write address, so the
            # policy gate runs on the journal's own target first: an edited
            # journal path is refused by policy, not merely by the plan match.
            if ([string]$canonical.kind -eq 'registry' -or [string]$canonical.kind -eq 'file') {
                $identityDecision = Test-PcxTarget -Target $identityTarget -Profile $Selection.profile
                if (-not [bool]$identityDecision.allowed) {
                    return New-PcxUndoRefusal -Code ([string]$identityDecision.code) -Reason ("item '{0}': {1}" -f $itemId, [string]$identityDecision.reason) -PlanId $Selection.planId
                }
            }

            $planTarget = Find-PcxUndoPlanTarget -Item $item -Canonical $canonical
            if ($null -eq $planTarget) {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-JOURNAL' -Reason ("item '{0}' records a target '{1}' that is not in the validated plan; the journal is not trusted." -f $itemId, [string]$canonical.path) -PlanId $Selection.planId
            }

            $decision = Test-PcxTarget -Target $planTarget -Profile $Selection.profile
            if (-not [bool]$decision.allowed) {
                return New-PcxUndoRefusal -Code ([string]$decision.code) -Reason ("item '{0}': {1}" -f $itemId, [string]$decision.reason) -PlanId $Selection.planId
            }

            $current = Get-PcxTargetState -Target $identityTarget
            $comparison = Compare-PcxState -Recorded (Get-PcxPolicyMember -Object $snapshot -Name 'post') -Current $current
            if ([string]$comparison.status -ne 'equal') {
                return New-PcxUndoRefusal -Code 'PCX-E-UNDO-DRIFT' -Reason ("item '{0}' no longer matches its recorded post-state (field '{1}': recorded '{2}', observed '{3}'); nothing was reverted." -f $itemId, [string]$comparison.field, [string]$comparison.recorded, [string]$comparison.current) -PlanId $Selection.planId
            }
        }

        [void]$restoreSet.Add([pscustomobject][ordered]@{
                itemId    = $itemId
                actionId  = [string](Get-PcxPolicyMember -Object $item -Name 'actionId')
                snapshots = $ordered.ToArray()
            })
    }

    return New-PcxUndoOutcome -Ok $true -Status 'ready' -Code $null -Reason $null -PlanId $Selection.planId -NotRestorable $notRestorable.ToArray() -Skipped $Selection.skipped -RestoreSet $restoreSet.ToArray()
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

function Invoke-PcxUndoRestoreSet {
    <#
    .SYNOPSIS
        Restores a preflighted set LIFO and proves pre-state equality.

    .DESCRIPTION
        A failure mid-restore marks only fully restored items UNDONE and reports
        what was reverted; it never claims success.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Preflight,
        [Parameter(Mandatory = $true)][object] $Selection,
        [Parameter(Mandatory = $true)][scriptblock] $Restore
    )

    $restored = New-Object System.Collections.Generic.List[object]
    $undoneIds = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @($Preflight.restoreSet)) {
        try {
            foreach ($snapshot in @($entry.snapshots)) {
                $null = & $Restore $snapshot
            }

            foreach ($snapshot in @($entry.snapshots)) {
                $identity = Get-PcxPolicyMember -Object $snapshot -Name 'target'
                $after = Get-PcxTargetState -Target (Get-PcxUndoIdentityTarget -Identity $identity)
                $comparison = Compare-PcxState -Recorded (Get-PcxPolicyMember -Object $snapshot -Name 'pre') -Current $after
                if ([string]$comparison.status -ne 'equal') {
                    throw [System.InvalidOperationException]::new(("PCX-E-UNDO-DRIFT: item '{0}' did not return to its pre-state (field '{1}')." -f [string]$entry.itemId, [string]$comparison.field))
                }
            }

            [void]$restored.Add([ordered]@{ itemId = [string]$entry.itemId; actionId = [string]$entry.actionId })
            [void]$undoneIds.Add([string]$entry.itemId)
        }
        catch {
            $code = Get-PcxUndoErrorCode -ErrorRecord $_
            if ($undoneIds.Count -gt 0) {
                $null = Write-PcxUndoSession -SessionDocument $Selection.sessionDocument -SessionPath $Selection.sessionPath -UndoneIds $undoneIds.ToArray()
            }

            return New-PcxUndoOutcome -Ok $false -Status 'refused' -Code $code -Reason $_.Exception.Message -PlanId $Selection.planId -Restored $restored.ToArray() -NotRestorable $Preflight.notRestorable -Skipped $Selection.skipped
        }
    }

    $null = Write-PcxUndoSession -SessionDocument $Selection.sessionDocument -SessionPath $Selection.sessionPath -UndoneIds $undoneIds.ToArray()

    return New-PcxUndoOutcome -Ok $true -Status 'restored' -Code $null -Reason 'every restorable item matches its recorded pre-state.' -PlanId $Selection.planId -Restored $restored.ToArray() -NotRestorable $Preflight.notRestorable -Skipped $Selection.skipped
}

function Invoke-PcxUndoInProcess {
    param(
        [Parameter(Mandatory = $true)][object] $Selection,
        [Parameter(Mandatory = $true)][scriptblock] $Restore
    )

    $preflight = Test-PcxUndoPreflight -Selection $Selection
    if (-not [bool]$preflight.ok) {
        return $preflight
    }

    return Invoke-PcxUndoRestoreSet -Preflight $preflight -Selection $Selection -Restore $Restore
}

# ---------------------------------------------------------------------------
# Elevation need
# ---------------------------------------------------------------------------

function Test-PcxUndoNeedsElevation {
    param([Parameter(Mandatory = $true)][object] $Selection)

    foreach ($itemId in @($Selection.ids)) {
        $item = $Selection.planItems[[string]$itemId]
        if ($null -eq $item) { continue }

        $inverse = ([string](Get-PcxPolicyMember -Object $item -Name 'inverse')).Trim().ToLowerInvariant()
        if ($inverse -eq $script:PcxUndoManifestOnly) { continue }

        $record = Get-PcxUndoRecord -SessionDocument $Selection.sessionDocument -ItemId ([string]$itemId)
        foreach ($snapshot in (Get-PcxUndoRecordSnapshots -Record $record)) {
            $identityTarget = Get-PcxUndoIdentityTarget -Identity (Get-PcxPolicyMember -Object $snapshot -Name 'target')
            if ($null -eq $identityTarget) { continue }

            $canonical = $null
            try {
                $canonical = ConvertTo-PcxTarget -Target $identityTarget
            }
            catch {
                continue
            }

            $planTarget = Find-PcxUndoPlanTarget -Item $item -Canonical $canonical
            if ($null -eq $planTarget) { continue }

            if (Test-PcxApplyTargetNeedsElevation -Target $planTarget -Profile $Selection.profile) {
                return $true
            }
        }
    }

    return $false
}

# ---------------------------------------------------------------------------
# Elevated request bytes
# ---------------------------------------------------------------------------

function New-PcxUndoRequest {
    <#
    .SYNOPSIS
        Builds the canonical undo request bytes, hash and base64 payload.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ItemIds
    )

    $document = [ordered]@{
        schema = $script:PcxUndoSchema
        planId = $PlanId
        items  = @($ItemIds)
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-PcxCanonicalJson -InputObject $document))
    if ($bytes.Length -gt $script:PcxUndoMaxRequestBytes) {
        return [pscustomobject]@{ ok = $false; code = 'PCX-E-UNDO-REQUEST-SIZE'; reason = ("the undo request is {0} bytes; the elevated invocation accepts at most {1}." -f $bytes.Length, $script:PcxUndoMaxRequestBytes); bytes = $null; hash = $null; base64 = $null }
    }

    return [pscustomobject]@{
        ok     = $true
        code   = $null
        reason = $null
        bytes  = $bytes
        hash   = (Get-PcxSha256 -Bytes $bytes)
        base64 = [System.Convert]::ToBase64String($bytes)
    }
}

function Invoke-PcxUndoElevated {
    <#
    .SYNOPSIS
        Validates the bytes an elevated undo child received.

    .DESCRIPTION
        Recomputes the hash, enforces the size limit, re-parses the request,
        compares the caller SID with the current one, re-validates the plan from
        disk and re-resolves the selection. Never trusts the parent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RequestBytesBase64,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RequestHash,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $CallerSid,
        [Parameter(Mandatory = $false)][AllowNull()][string] $CurrentSid
    )

    function New-PcxUndoElevatedResult {
        param([bool] $Ok, [string] $Code, [string] $Reason, [object] $PlanId, [object] $Selection)

        return [pscustomobject][ordered]@{
            ok        = $Ok
            code      = $Code
            reason    = $Reason
            planId    = $PlanId
            selection = $Selection
        }
    }

    if ([string]::IsNullOrWhiteSpace($RequestBytesBase64)) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason 'the elevated invocation carries no undo request bytes.' -PlanId $null -Selection $null
    }

    $bytes = $null
    try {
        $bytes = [System.Convert]::FromBase64String($RequestBytesBase64)
    }
    catch {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason 'the undo request payload is not valid base64.' -PlanId $null -Selection $null
    }

    if ($bytes.Length -gt $script:PcxUndoMaxRequestBytes) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST-SIZE' -Reason ("the undo request is {0} bytes; the elevated invocation accepts at most {1}." -f $bytes.Length, $script:PcxUndoMaxRequestBytes) -PlanId $null -Selection $null
    }

    if ([string]::IsNullOrWhiteSpace($RequestHash)) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason 'the elevated invocation carries no request hash.' -PlanId $null -Selection $null
    }

    $recomputedHash = Get-PcxSha256 -Bytes $bytes
    if (-not [string]::Equals($recomputedHash, $RequestHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason 'the received undo request bytes do not match the hash passed by the parent.' -PlanId $null -Selection $null
    }

    $request = $null
    try {
        $request = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($bytes)) -ErrorAction Stop
    }
    catch {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason ("the undo request is not valid JSON: {0}" -f $_.Exception.Message) -PlanId $null -Selection $null
    }

    if ([string](Get-PcxPolicyMember -Object $request -Name 'schema') -ne $script:PcxUndoSchema) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason "the undo request schema must be '$($script:PcxUndoSchema)'." -PlanId $null -Selection $null
    }

    $planId = [string](Get-PcxPolicyMember -Object $request -Name 'planId')
    if ($planId -notmatch $script:PcxUndoPlanIdPattern) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason "the undo request plan id '$planId' is not 16 lowercase hex characters." -PlanId $null -Selection $null
    }

    $itemIds = @(Get-PcxPolicyMember -Object $request -Name 'items')
    if ($itemIds.Count -eq 0) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-UNDO-REQUEST' -Reason 'the undo request carries no item ids.' -PlanId $planId -Selection $null
    }

    if ([string]::IsNullOrWhiteSpace($CurrentSid)) {
        try {
            $CurrentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }
        catch {
            $CurrentSid = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($CurrentSid) -or [string]::IsNullOrWhiteSpace($CallerSid) -or -not [string]::Equals($CurrentSid, $CallerSid.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-PcxUndoElevatedResult -Ok $false -Code 'PCX-E-SID-MISMATCH' -Reason 'the caller SID does not match the elevated process SID.' -PlanId $planId -Selection $null
    }

    $selection = New-PcxUndoSelection -PlanId $planId -ItemIds $itemIds
    if (-not [bool]$selection.ok) {
        return New-PcxUndoElevatedResult -Ok $false -Code ([string]$selection.code) -Reason ([string]$selection.reason) -PlanId $planId -Selection $null
    }

    return New-PcxUndoElevatedResult -Ok $true -Code $null -Reason $null -PlanId $planId -Selection $selection
}

function Invoke-PcxUndoElevatedLoop {
    <#
    .SYNOPSIS
        The elevated undo child: validate the request, then own the preflight and
        every write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RequestBytesBase64,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RequestHash,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $CallerSid,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $InputReader,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Restore,
        [Parameter(Mandatory = $false)][AllowNull()][string] $CurrentSid
    )

    $validated = Invoke-PcxUndoElevated -RequestBytesBase64 $RequestBytesBase64 -RequestHash $RequestHash -CallerSid $CallerSid -CurrentSid $CurrentSid
    if (-not [bool]$validated.ok) {
        return New-PcxUndoOutcome -Ok $false -Status 'refused' -Code ([string]$validated.code) -Reason ([string]$validated.reason) -PlanId $validated.planId -Elevated $true -ElevationCalls 1
    }

    if ($null -eq $Restore) {
        $Restore = { param($snapshot) Restore-PcxSnapshot -Snapshot $snapshot }
    }

    $outcome = Invoke-PcxUndoInProcess -Selection $validated.selection -Restore $Restore
    $outcome.elevated = $true
    $outcome.elevationCalls = 1

    return $outcome
}

function Invoke-PcxUndoDefaultElevation {
    <#
    .SYNOPSIS
        Production UAC: one Start-Process -Verb RunAs for the whole undo.
    #>
    param([Parameter(Mandatory = $true)][object] $Request)

    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:PcxModuleRoot))
    $entry = Join-Path -Path $repoRoot -ChildPath 'pcx.ps1'

    $hostPath = $null
    try {
        $hostPath = (Get-Process -Id $PID).Path
    }
    catch {
        $hostPath = $null
    }
    if ([string]::IsNullOrWhiteSpace($hostPath)) {
        return [pscustomobject]@{ ok = $false; declined = $true; elevated = $false; code = 'PCX-E-UAC-DECLINED'; reason = 'the current PowerShell host path could not be resolved.'; result = $null }
    }

    $argumentList = @(
        '-NoProfile',
        '-File', $entry,
        'undo-elevated',
        '--run',
        '--payload', [string]$Request.payloadBase64,
        '--hash', [string]$Request.requestHash,
        '--sid', [string]$Request.callerSid
    )

    try {
        $process = Start-Process -FilePath $hostPath -ArgumentList $argumentList -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ ok = $false; declined = $true; elevated = $false; code = 'PCX-E-UAC-DECLINED'; reason = $_.Exception.Message; result = $null }
    }

    if ($null -eq $process -or $process.ExitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; declined = $false; elevated = $true; code = 'PCX-E-UAC-CHILD'; reason = 'the elevated undo child did not verify every restore; it reports nothing it could not confirm.'; result = $null }
    }

    return [pscustomobject]@{ ok = $true; declined = $false; elevated = $true; code = $null; reason = $null; result = $null }
}

function Get-PcxUndoSessionOutcome {
    <#
    .SYNOPSIS
        Builds the parent outcome for a real elevated child from the durable
        session the child wrote. The parent performs no write.
    #>
    param([Parameter(Mandatory = $true)][object] $Selection)

    $document = $null
    try {
        $document = Read-PcxJson -Path $Selection.sessionPath
    }
    catch {
        return New-PcxUndoOutcome -Ok $false -Status 'refused' -Code 'PCX-E-UNDO-JOURNAL' -Reason ("the session cannot be read after the elevated child: {0}" -f $_.Exception.Message) -PlanId $Selection.planId -Elevated $true -ElevationCalls 1
    }

    $restored = New-Object System.Collections.Generic.List[object]
    $pending = 0
    foreach ($itemId in @($Selection.ids)) {
        $record = Get-PcxUndoRecord -SessionDocument $document -ItemId ([string]$itemId)
        $status = if ($null -eq $record) { '' } else { [string](Get-PcxPolicyMember -Object $record -Name 'status') }
        if ($status -eq $script:PcxUndoUndone) {
            [void]$restored.Add([ordered]@{ itemId = [string]$itemId })
        }
        else {
            $pending++
        }
    }

    if ($pending -gt 0) {
        return New-PcxUndoOutcome -Ok $false -Status 'refused' -Code 'PCX-E-UAC-CHILD' -Reason 'the elevated undo child did not confirm every item; nothing unconfirmed is reported as restored.' -PlanId $Selection.planId -Restored $restored.ToArray() -Elevated $true -ElevationCalls 1
    }

    return New-PcxUndoOutcome -Ok $true -Status 'restored' -Code $null -Reason 'every restorable item matches its recorded pre-state.' -PlanId $Selection.planId -Restored $restored.ToArray() -Elevated $true -ElevationCalls 1
}

function Invoke-PcxUndoElevatedPath {
    <#
    .SYNOPSIS
        One UAC for the whole undo. The parent launches, waits and reads the
        session; it performs no write.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Selection,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Elevation,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $InputReader
    )

    $request = New-PcxUndoRequest -PlanId $Selection.planId -ItemIds @($Selection.ids)
    if (-not [bool]$request.ok) {
        return New-PcxUndoRefusal -Code ([string]$request.code) -Reason ([string]$request.reason) -PlanId $Selection.planId
    }

    $callerSid = Get-PcxApplyCurrentSid

    $elevation = $Elevation
    if ($null -eq $elevation) {
        $elevation = { param($r) Invoke-PcxUndoDefaultElevation -Request $r }
    }

    $payload = [ordered]@{
        payloadBase64 = [string]$request.base64
        requestHash   = [string]$request.hash
        planId        = $Selection.planId
        callerSid     = [string]$callerSid
        mode          = 'undo'
        inputReader   = $InputReader
    }

    $decision = $null
    try {
        $decision = & $elevation $payload
    }
    catch {
        $decision = [pscustomobject]@{ ok = $false; declined = $true; code = 'PCX-E-UAC-DECLINED'; reason = $_.Exception.Message; result = $null }
    }

    $decisionOk = $false
    if ($null -ne $decision) {
        $decisionOk = [bool](Get-PcxPolicyMember -Object $decision -Name 'ok')
    }

    if (-not $decisionOk) {
        $code = [string](Get-PcxPolicyMember -Object $decision -Name 'code')
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'PCX-E-UAC-DECLINED' }
        return New-PcxUndoOutcome -Ok $false -Status 'refused' -Code $code -Reason ([string](Get-PcxPolicyMember -Object $decision -Name 'reason')) -PlanId $Selection.planId -Elevated $true -ElevationCalls 1
    }

    $child = Get-PcxPolicyMember -Object $decision -Name 'result'
    if ($null -eq $child -and $null -ne (Get-PcxPolicyMember -Object $decision -Name 'status')) {
        # A fake elevation returned the child loop outcome directly.
        $child = $decision
    }

    if ($null -ne $child) {
        $outcome = New-PcxUndoOutcome -Ok ([bool](Get-PcxPolicyMember -Object $child -Name 'ok')) -Status ([string](Get-PcxPolicyMember -Object $child -Name 'status')) -Code (Get-PcxPolicyMember -Object $child -Name 'code') -Reason (Get-PcxPolicyMember -Object $child -Name 'reason') -PlanId $Selection.planId -Restored (Get-PcxPolicyMember -Object $child -Name 'restored') -NotRestorable (Get-PcxPolicyMember -Object $child -Name 'notRestorable') -Skipped $Selection.skipped -Elevated $true -ElevationCalls 1
        return $outcome
    }

    return Get-PcxUndoSessionOutcome -Selection $Selection
}

# ---------------------------------------------------------------------------
# Public: undo
# ---------------------------------------------------------------------------

function Invoke-PcxUndo {
    <#
    .SYNOPSIS
        Undoes applied items through the value-level snapshot engine.

    .PARAMETER Last
        Target the most recent session.

    .PARAMETER ItemId
        Undo exactly one applied item.

    .PARAMETER PlanId
        Undo every applied item of one plan, LIFO.

    .PARAMETER Elevation
        Injectable single UAC. Production default is one Start-Process -Verb RunAs.

    .PARAMETER InputReader
        Injectable answer reader, forwarded to the elevated child (parity with
        task 12; undo itself does not prompt).

    .PARAMETER Restore
        Injectable restore seam for tests. Production default is
        Restore-PcxSnapshot. An elevated undo never calls the parent's seam.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch] $Last,
        [Parameter(Mandatory = $false)][AllowNull()][string] $ItemId,
        [Parameter(Mandatory = $false)][AllowNull()][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Elevation,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $InputReader,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Restore
    )

    $request = Resolve-PcxUndoRequest -Last ([bool]$Last) -ItemId $ItemId -PlanId $PlanId
    if (-not [bool]$request.ok) {
        return $request
    }

    $selection = $null
    if ([bool]$request.allCommitted) {
        $selection = New-PcxUndoSelection -PlanId ([string]$request.planId) -AllCommitted
    }
    else {
        $selection = New-PcxUndoSelection -PlanId ([string]$request.planId) -ItemIds @($request.itemIds)
    }

    if (-not [bool]$selection.ok) {
        return $selection
    }

    if (Test-PcxUndoNeedsElevation -Selection $selection) {
        return Invoke-PcxUndoElevatedPath -Selection $selection -Elevation $Elevation -InputReader $InputReader
    }

    if ($null -eq $Restore) {
        $Restore = { param($snapshot) Restore-PcxSnapshot -Snapshot $snapshot }
    }

    return Invoke-PcxUndoInProcess -Selection $selection -Restore $Restore
}

# ---------------------------------------------------------------------------
# Envelope and dispatch
# ---------------------------------------------------------------------------

function New-PcxUndoEnvelopeResult {
    param(
        [Parameter(Mandatory = $true)][string] $CommandName,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Outcome
    )

    if ($null -eq $Outcome) {
        $Outcome = New-PcxUndoRefusal -Code 'PCX-E-UNDO' -Reason 'undo returned no outcome.'
    }

    $code = $Outcome.code
    $exitCode = Get-PcxUndoExitCode -Code ([string]$code)

    $restored = ConvertTo-PcxUndoList -Value $Outcome.restored
    $notRestorable = ConvertTo-PcxUndoList -Value $Outcome.notRestorable
    $skipped = ConvertTo-PcxUndoList -Value $Outcome.skipped

    $data = [ordered]@{
        status         = [string]$Outcome.status
        planId         = $Outcome.planId
        restored       = @($restored)
        notRestorable  = @($notRestorable)
        skipped        = @($skipped)
        elevated       = [bool]$Outcome.elevated
        elevationCalls = [int]$Outcome.elevationCalls
    }

    $diagnostics = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$code)) {
        $diagnostics = @([ordered]@{ code = [string]$code; message = [string]$Outcome.reason })
    }

    $status = if ($exitCode -eq 0) { 'ok' } else { 'refused' }

    return New-PcxResult -ExitCode $exitCode -Envelope (New-PcxEnvelope -Status $status -CommandName $CommandName -ExitCode $exitCode -Data $data -Diagnostics $diagnostics)
}

function Invoke-PcxUndoCommand {
    <#
    .SYNOPSIS
        Parses `undo --last|--item <id>|--plan <plan-id>` and returns a result.
    #>
    param([Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]] $Arguments = @())

    $last = $false
    $itemId = $null
    $planId = $null

    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        $value = $null
        if (($index + 1) -lt $Arguments.Count) { $value = [string]$Arguments[$index + 1] }

        switch ($token) {
            '--last' { $last = $true; $index++; continue }
            '--item' { $itemId = $value; $index += 2; continue }
            '--plan' { $planId = $value; $index += 2; continue }
            default { $index++ }
        }
    }

    try {
        $outcome = Invoke-PcxUndo -Last:$last -ItemId $itemId -PlanId $planId
    }
    catch {
        return New-PcxError -CommandName 'undo' -Code 'PCX-E-UNDO' -Message $_.Exception.Message
    }

    return New-PcxUndoEnvelopeResult -CommandName 'undo' -Outcome $outcome
}

function Invoke-PcxUndoElevatedCommand {
    <#
    .SYNOPSIS
        Dispatches the internal `undo-elevated` child command.
    #>
    param([Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]] $Arguments = @())

    $payload = $null
    $hash = $null
    $sid = $null
    $run = $false

    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        $value = $null
        if (($index + 1) -lt $Arguments.Count) { $value = [string]$Arguments[$index + 1] }

        switch ($token) {
            '--payload' { $payload = $value; $index += 2; continue }
            '--hash' { $hash = $value; $index += 2; continue }
            '--sid' { $sid = $value; $index += 2; continue }
            '--run' { $run = $true; $index++; continue }
            default { $index++ }
        }
    }

    if (-not $run) {
        $validated = Invoke-PcxUndoElevated -RequestBytesBase64 ([string]$payload) -RequestHash ([string]$hash) -CallerSid ([string]$sid)
        if (-not [bool]$validated.ok) {
            return New-PcxUndoEnvelopeResult -CommandName 'undo-elevated' -Outcome (New-PcxUndoRefusal -Code ([string]$validated.code) -Reason ([string]$validated.reason) -PlanId $validated.planId)
        }

        return New-PcxUndoEnvelopeResult -CommandName 'undo-elevated' -Outcome (New-PcxUndoOutcome -Ok $true -Status 'validated' -Code $null -Reason $null -PlanId $validated.planId)
    }

    $outcome = Invoke-PcxUndoElevatedLoop -RequestBytesBase64 ([string]$payload) -RequestHash ([string]$hash) -CallerSid ([string]$sid)
    return New-PcxUndoEnvelopeResult -CommandName 'undo-elevated' -Outcome $outcome
}
