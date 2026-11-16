<#
.SYNOPSIS
    `pcx tune --apply` in agent mode, plus the shared per-item writer.

.DESCRIPTION
    Two modes share one writer:

    Agent mode (default)
        Invoke-PcxApply -PlanId <id> -Mode agent builds or loads a validated
        plan, applies exactly ONE PENDING item, never reads stdin, and returns
        @{ status = 'partial'|'done'; applied; next; itemResults }. The agent
        owns the chat loop and calls again until status is 'done'.

    Console mode
        Invoke-PcxApply -Mode console requires a TTY (PCX-E-NO-TTY otherwise)
        and delegates to Invoke-PcxQueue, which owns the single stop loop and
        makes ONE UAC for the whole plan. Prompting happens before every item,
        including the first pending item after a resume.

    Per item, in order:
        1. COMMITTED items are skipped BEFORE any snapshot is taken.
        2. evidence is re-measured live through Invoke-PcxProbe (fixture-aware);
           a state ref whose predicate no longer holds, or a missing target,
           refuses as drift;
        3. policy is re-checked through Test-PcxTarget;
        4. the target is re-read; a target already in the plan's expected
           post-state is drift (PCX-E-APPLY-DRIFT);
        5. the provider snapshots the pre-state, writes, and reads back;
        6. a read-back mismatch inline-undoes through Restore-PcxSnapshot,
           marks the item FAILED, and leaves every other item PENDING.

    State machine: PENDING -> COMMITTED | FAILED | SKIPPED. A later invocation
    resumes: COMMITTED stays COMMITTED, everything else stays PENDING unless
    this run attempts it. Session state lives at
    <LOCALAPPDATA>\pcx\journal\session-<planId>.json and carries each item's
    snapshot so the undo command (task 13) can consume it.

    Elevated contract (Invoke-PcxApplyElevated)
        The parent passes the canonical plan BYTES as base64 plus their SHA-256,
        never a writable path. The child recomputes the hash, re-runs
        Test-PcxPlan on those bytes, and compares the caller SID with its own.
        Oversized bytes (over 8192), altered bytes and a SID mismatch refuse.
        There is no HMAC, nonce or secret.

    Each applied item prints one result line carrying both
    `pcx undo --item <id>` and `pcx undo --plan <plan-id>`.
#>

Set-StrictMode -Version 2.0

$script:PcxApplySessionSchema = 'pcx-session/1'
$script:PcxApplyMaxPlanBytes = 8192
$script:PcxApplyPending = 'PENDING'
$script:PcxApplyCommitted = 'COMMITTED'
$script:PcxApplyFailed = 'FAILED'
$script:PcxApplySkipped = 'SKIPPED'
$script:PcxApplyPlanIdPattern = '^[0-9a-f]{16}$'

# Desired registry value per catalog action. The policy canonicalizer keeps
# only hive/key/name, so the write intent (type + value) is restored here, in
# one small table next to the writer. An action absent from this table and a
# target without Type/Value refuses: pcx never guesses a value.
$script:PcxApplyRegistryIntent = @{
    'tips|subscribedcontent-338389enabled'     = @{ Type = 'dword'; Value = 0 }
    'advertising-id|enabled'                   = @{ Type = 'dword'; Value = 0 }
    'search-web|bingsearchenabled'             = @{ Type = 'dword'; Value = 0 }
    'game-dvr|appcaptureenabled'               = @{ Type = 'dword'; Value = 0 }
    'game-dvr|gamedvr_enabled'                 = @{ Type = 'dword'; Value = 0 }
    'hags|hwschmode'                           = @{ Type = 'dword'; Value = 2 }
}

# ---------------------------------------------------------------------------
# Small shape helpers
# ---------------------------------------------------------------------------

function New-PcxApplyFailure {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Reason
    )

    return [pscustomobject][ordered]@{
        ok     = $false
        code   = $Code
        reason = $Reason
    }
}

function Get-PcxApplyTargetList {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Item)

    $target = Get-PcxPolicyMember -Object $Item -Name 'target'
    if ($null -eq $target) {
        return @()
    }

    return @($target)
}

# ---------------------------------------------------------------------------
# Target reconstruction: plan targets are canonical policy objects
# ---------------------------------------------------------------------------

function Get-PcxApplyRegistryIntent {
    param(
        [Parameter(Mandatory = $true)][object] $Item,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target
    )

    if ((Test-PcxSnapshotMember -Object $Target -Name 'Type') -and (Test-PcxSnapshotMember -Object $Target -Name 'Value')) {
        return [pscustomobject]@{ ok = $true; type = [string](Get-PcxSnapshotMember -Object $Target -Name 'Type'); value = (Get-PcxSnapshotMember -Object $Target -Name 'Value') }
    }

    $actionId = ([string](Get-PcxPolicyMember -Object $Item -Name 'actionId')).Trim().ToLowerInvariant()
    $name = ([string](Get-PcxPolicyMember -Object $Target -Name 'name')).Trim().ToLowerInvariant()
    $key = $actionId + '|' + $name

    if ($script:PcxApplyRegistryIntent.ContainsKey($key)) {
        $intent = $script:PcxApplyRegistryIntent[$key]
        return [pscustomobject]@{ ok = $true; type = [string]$intent.Type; value = $intent.Value }
    }

    return [pscustomobject]@{ ok = $false; type = $null; value = $null }
}

function ConvertFrom-PcxApplyCanonicalTarget {
    <#
    .SYNOPSIS
        Rebuilds a platform-ready typed target from a canonical plan target.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Item
    )

    $kind = ([string](Get-PcxPolicyMember -Object $Target -Name 'kind')).Trim().ToLowerInvariant()

    switch ($kind) {
        'registry' {
            $hive = [string](Get-PcxPolicyMember -Object $Target -Name 'hive')
            $key = [string](Get-PcxPolicyMember -Object $Target -Name 'key')
            $name = [string](Get-PcxPolicyMember -Object $Target -Name 'name')
            if ([string]::IsNullOrWhiteSpace($hive) -or [string]::IsNullOrWhiteSpace($name)) {
                return New-PcxApplyFailure -Code 'PCX-E-APPLY-TARGET' -Reason 'a canonical registry target has no hive or value name.'
            }

            $intent = Get-PcxApplyRegistryIntent -Item $Item -Target $Target
            if (-not $intent.ok) {
                return New-PcxApplyFailure -Code 'PCX-E-APPLY-INTENT' -Reason "no write intent is known for registry target '$hive\$key::$name' (action '$([string](Get-PcxPolicyMember -Object $Item -Name 'actionId'))')."
            }

            return [ordered]@{
                Kind  = 'registry'
                Path  = ($hive + ':\' + $key)
                Name  = $name
                Type  = $intent.type
                Value = $intent.value
            }
        }
        'service' {
            return [ordered]@{
                Kind  = 'service'
                Name  = [string](Get-PcxPolicyMember -Object $Target -Name 'name')
                Start = Get-PcxPolicyMember -Object $Target -Name 'start'
            }
        }
        'task' {
            return [ordered]@{
                Kind    = 'task'
                Path    = [string](Get-PcxPolicyMember -Object $Target -Name 'path')
                Enabled = Get-PcxPolicyMember -Object $Target -Name 'enabled'
            }
        }
        'file' {
            $typed = [ordered]@{
                Kind   = 'file'
                Path   = [string](Get-PcxPolicyMember -Object $Target -Name 'path')
                Role   = [string](Get-PcxPolicyMember -Object $Target -Name 'role')
                PlanId = $PlanId
            }

            $children = Get-PcxPolicyMember -Object $Target -Name 'children'
            if ($null -ne $children) {
                $typed['Children'] = $children
            }

            return $typed
        }
    }

    return New-PcxApplyFailure -Code 'PCX-E-APPLY-TARGET' -Reason "unknown canonical target kind '$kind'."
}

# ---------------------------------------------------------------------------
# Evidence re-measurement and drift
# ---------------------------------------------------------------------------

function Get-PcxApplyTargetProbe {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Target)

    switch ([string]$Target['Kind']) {
        'registry' { return [ordered]@{ family = 'reg'; path = [string]$Target['Path']; name = [string]$Target['Name'] } }
        'service' { return [ordered]@{ family = 'svc'; name = [string]$Target['Name'] } }
        'task' { return [ordered]@{ family = 'task'; path = [string]$Target['Path'] } }
        'file' { return [ordered]@{ family = 'file'; path = [string]$Target['Path'] } }
    }

    return $null
}

function ConvertTo-PcxApplyComparableText {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    return ([string]$Value).Trim().ToLowerInvariant()
}

function Test-PcxApplyPredicate {
    <#
    .SYNOPSIS
        Evaluates the small evidence predicate vocabulary: equals, at-least,
        is-off. An unknown predicate is not treated as drift.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string] $Predicate,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Expected,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Actual
    )

    if ([string]::IsNullOrWhiteSpace($Predicate)) {
        return [pscustomobject]@{ known = $true; holds = ([string]::Equals((ConvertTo-PcxApplyComparableText -Value $Expected), (ConvertTo-PcxApplyComparableText -Value $Actual), [System.StringComparison]::Ordinal)) }
    }

    $text = $Predicate.Trim()
    $separator = $text.IndexOf(':')
    $verb = if ($separator -ge 0) { $text.Substring(0, $separator).Trim().ToLowerInvariant() } else { $text.ToLowerInvariant() }
    $operand = if ($separator -ge 0) { $text.Substring($separator + 1).Trim() } else { $null }

    switch ($verb) {
        'equals' {
            return [pscustomobject]@{ known = $true; holds = ([string]::Equals((ConvertTo-PcxApplyComparableText -Value $operand), (ConvertTo-PcxApplyComparableText -Value $Actual), [System.StringComparison]::Ordinal)) }
        }
        'at-least' {
            $actualNumber = 0.0
            $expectedNumber = 0.0
            if (-not [double]::TryParse([string]$Actual, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$actualNumber)) {
                return [pscustomobject]@{ known = $true; holds = $false }
            }
            if (-not [double]::TryParse([string]$operand, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$expectedNumber)) {
                return [pscustomobject]@{ known = $false; holds = $true }
            }
            return [pscustomobject]@{ known = $true; holds = ($actualNumber -ge $expectedNumber) }
        }
        'is-off' {
            $actualText = ConvertTo-PcxApplyComparableText -Value $Actual
            return [pscustomobject]@{ known = $true; holds = ($actualText -eq '0' -or $actualText -eq 'false') }
        }
    }

    return [pscustomobject]@{ known = $false; holds = $true }
}

function Get-PcxApplyProbeValue {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $ProbeResult)

    if ($null -eq $ProbeResult) { return $null }
    $value = Get-PcxPolicyMember -Object $ProbeResult -Name 'value'
    $family = [string](Get-PcxPolicyMember -Object $ProbeResult -Name 'family')

    if ($family -eq 'file' -and $null -ne $value) {
        return (Get-PcxPolicyMember -Object $value -Name 'exists')
    }

    return $value
}

function Test-PcxApplyDrift {
    <#
    .SYNOPSIS
        True when a live state-evidence predicate no longer holds.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Item,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $ProbeResult
    )

    $evidence = Get-PcxPolicyMember -Object $Item -Name 'evidence'
    if ($null -eq $evidence) { return $false }

    $kind = ([string](Get-PcxPolicyMember -Object $evidence -Name 'kind')).Trim().ToLowerInvariant()
    if ($kind -ne 'state') { return $false }

    $targets = Get-PcxApplyTargetList -Item $Item
    if ($targets.Count -ne 1) { return $false }

    $canonical = $null
    try {
        $canonical = ConvertTo-PcxTarget -Target $Target
    }
    catch {
        return $false
    }

    $targetDomain = Get-PcxEvidenceTargetDomain -Canonical $canonical
    $evidenceDomain = [string](Get-PcxPolicyMember -Object $evidence -Name 'domain')
    if ([string]::IsNullOrWhiteSpace($targetDomain) -or -not [string]::Equals($targetDomain, $evidenceDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    if ($null -eq $ProbeResult -or [string](Get-PcxPolicyMember -Object $ProbeResult -Name 'status') -ne 'measured') {
        return $true
    }

    $predicate = [string](Get-PcxPolicyMember -Object $evidence -Name 'predicate')
    $expected = Get-PcxPolicyMember -Object $evidence -Name 'value'
    $actual = Get-PcxApplyProbeValue -ProbeResult $ProbeResult

    $evaluation = Test-PcxApplyPredicate -Predicate $predicate -Expected $expected -Actual $actual
    if (-not $evaluation.known) { return $false }

    return (-not $evaluation.holds)
}

# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

function Get-PcxApplySessionPath {
    param([Parameter(Mandatory = $true)][string] $PlanId)

    if ($PlanId -notmatch $script:PcxApplyPlanIdPattern) {
        throw [System.ArgumentException]::new("PCX-E-APPLY-PLANID: plan id '$PlanId' is not 16 lowercase hex characters.")
    }

    return Get-PcxStatePath -Kind 'journal' -ChildPath ('session-' + $PlanId + '.json')
}

function Read-PcxApplySession {
    param(
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][object] $Items
    )

    $path = Get-PcxApplySessionPath -PlanId $PlanId
    $existing = @{}
    $document = $null

    if ([System.IO.File]::Exists($path)) {
        try {
            $document = Read-PcxJson -Path $path
        }
        catch {
            $document = $null
        }

        if ($null -ne $document -and [string](Get-PcxPolicyMember -Object $document -Name 'schema') -eq $script:PcxApplySessionSchema) {
            $storedPlanId = [string](Get-PcxPolicyMember -Object $document -Name 'planId')
            if ($storedPlanId -eq $PlanId) {
                foreach ($record in @(Get-PcxPolicyMember -Object $document -Name 'items')) {
                    if ($null -eq $record) { continue }
                    $recordId = [string](Get-PcxPolicyMember -Object $record -Name 'id')
                    if (-not [string]::IsNullOrWhiteSpace($recordId)) {
                        $existing[$recordId] = $record
                    }
                }
            }
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Items)) {
        $itemId = [string](Get-PcxPolicyMember -Object $item -Name 'id')
        $status = $script:PcxApplyPending
        $snapshots = @()
        $code = $null
        $reason = $null
        $line = $null

        if ($existing.ContainsKey($itemId)) {
            $record = $existing[$itemId]
            $storedStatus = [string](Get-PcxPolicyMember -Object $record -Name 'status')
            if ($storedStatus -in @($script:PcxApplyCommitted, $script:PcxApplyFailed, $script:PcxApplySkipped)) {
                $status = $storedStatus
            }
            $storedSnapshots = Get-PcxPolicyMember -Object $record -Name 'snapshots'
            if ($null -ne $storedSnapshots) { $snapshots = @($storedSnapshots) }
            $code = Get-PcxPolicyMember -Object $record -Name 'code'
            $reason = Get-PcxPolicyMember -Object $record -Name 'reason'
            $line = Get-PcxPolicyMember -Object $record -Name 'line'
        }

        [void]$records.Add([ordered]@{
                id        = $itemId
                actionId  = [string](Get-PcxPolicyMember -Object $item -Name 'actionId')
                status    = $status
                snapshots = @($snapshots)
                code      = $code
                reason    = $reason
                line      = $line
            })
    }

    return [pscustomobject]@{
        schema  = $script:PcxApplySessionSchema
        planId  = $PlanId
        planHash = [string](Get-PcxPolicyMember -Object $Plan -Name 'planHash')
        items   = $records
    }
}

function Write-PcxApplySession {
    param(
        [Parameter(Mandatory = $true)][object] $Session,
        [Parameter(Mandatory = $true)][string] $PlanId
    )

    $path = Get-PcxApplySessionPath -PlanId $PlanId

    # Ordering lives in the document, never in filesystem timestamps: the
    # sequence comes from the persisted journal counter and is allocated once
    # per session; every later write of this session reuses it.
    $sequence = $null
    $createdAtUtc = $null
    if ([System.IO.File]::Exists($path)) {
        try {
            $existing = Read-PcxJson -Path $path
            $sequence = Get-PcxPolicyMember -Object $existing -Name 'sequence'
            $createdAtUtc = Get-PcxPolicyMember -Object $existing -Name 'createdAtUtc'
        }
        catch {
            $sequence = $null
            $createdAtUtc = $null
        }
    }
    if ($null -eq $sequence -or $null -eq $createdAtUtc) {
        $ordering = New-PcxSessionOrdering
        $sequence = $ordering.sequence
        $createdAtUtc = $ordering.createdAtUtc
    }

    $null = Write-PcxJsonAtomic -Path $path -InputObject ([ordered]@{
            schema       = $script:PcxApplySessionSchema
            planId       = $PlanId
            planHash     = [string]$Session.planHash
            sequence     = [int]$sequence
            createdAtUtc = (ConvertTo-PcxSessionOrderingStamp -Value $createdAtUtc)
            updatedAt    = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            items        = @($Session.items.ToArray())
        })

    return $path
}

function Get-PcxApplyRecord {
    param(
        [Parameter(Mandatory = $true)][object] $Session,
        [Parameter(Mandatory = $true)][string] $ItemId
    )

    foreach ($record in $Session.items) {
        if ([string]::Equals([string]$record['id'], $ItemId, [System.StringComparison]::Ordinal)) {
            return $record
        }
    }

    return $null
}

function Get-PcxApplyPendingItems {
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][object] $Session
    )

    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-PcxPolicyMember -Object $Plan -Name 'items')) {
        $itemId = [string](Get-PcxPolicyMember -Object $item -Name 'id')
        $record = Get-PcxApplyRecord -Session $Session -ItemId $itemId
        if ($null -ne $record -and [string]$record['status'] -eq $script:PcxApplyPending) {
            [void]$pending.Add($item)
        }
    }

    return $pending.ToArray()
}

# ---------------------------------------------------------------------------
# One target: policy, evidence, drift, provider, verify
# ---------------------------------------------------------------------------

function Invoke-PcxApplyProviderDefault {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Context)

    $target = $Context['target']
    $profile = $Context['profile']

    switch ([string]$Context['kind']) {
        'registry' { return Invoke-PcxRegistryProviderApply -Target $target -Profile $profile }
        'service' { return Invoke-PcxServiceProviderApply -Target $target -Profile $profile }
        'task' { return Invoke-PcxTaskProviderApply -Target $target -Profile $profile }
        'file' { return Invoke-PcxFileProviderApply -Target $target -Profile $profile }
    }

    return $null
}

function Invoke-PcxApplyProviderVerify {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Context,
        [Parameter(Mandatory = $true)][object] $Result
    )

    if ([string]$Context['kind'] -eq 'file') {
        return Test-PcxFileProviderResult -Result $Result
    }

    $snapshot = Get-PcxPolicyMember -Object $Result -Name 'snapshot'
    if ($null -eq $snapshot) {
        return $null
    }

    switch ([string]$Context['kind']) {
        'registry' { return Test-PcxRegistryProviderState -Snapshot $snapshot }
        'service' { return Test-PcxServiceProviderState -Snapshot $snapshot }
        'task' { return Test-PcxTaskProviderState -Snapshot $snapshot }
    }

    return $null
}

function Invoke-PcxApplyOneTarget {
    <#
    .SYNOPSIS
        Runs one target through policy, evidence, drift, provider and verify.
        Returns @{ ok; code; reason; snapshot; result }.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Item,
        [Parameter(Mandatory = $true)][AllowNull()][object] $CanonicalTarget,
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Provider
    )

    $typed = ConvertFrom-PcxApplyCanonicalTarget -Target $CanonicalTarget -PlanId $PlanId -Item $Item
    if ($typed -is [System.Management.Automation.PSCustomObject] -and $null -ne (Get-PcxPolicyMember -Object $typed -Name 'ok') -and -not [bool](Get-PcxPolicyMember -Object $typed -Name 'ok')) {
        return [pscustomobject]@{ ok = $false; code = [string](Get-PcxPolicyMember -Object $typed -Name 'code'); reason = [string](Get-PcxPolicyMember -Object $typed -Name 'reason'); snapshot = $null; result = $null }
    }

    # Policy first: a refused target is never read, snapshotted or written.
    $decision = Test-PcxTarget -Target $typed -Profile $Profile
    if (-not [bool](Get-PcxPolicyMember -Object $decision -Name 'allowed')) {
        return [pscustomobject]@{ ok = $false; code = [string](Get-PcxPolicyMember -Object $decision -Name 'code'); reason = [string](Get-PcxPolicyMember -Object $decision -Name 'reason'); snapshot = $null; result = $null }
    }

    # Re-measure evidence live.
    $probe = Get-PcxApplyTargetProbe -Target $typed
    $probeResult = $null
    if ($null -ne $probe) {
        $probeResult = Invoke-PcxProbe -Probe $probe
    }

    if (Test-PcxApplyDrift -Item $Item -Target $typed -ProbeResult $probeResult) {
        return [pscustomobject]@{ ok = $false; code = 'PCX-E-APPLY-DRIFT'; reason = 'the live evidence no longer justifies the change; the target drifted since the plan was built.'; snapshot = $null; result = $null }
    }

    # A value target already in its expected post-state is drift too: the plan
    # was built against a different pre-state. File targets are excluded (an A1
    # delete has no derived post-state and a missing file is a provider failure).
    if ([string]$typed['Kind'] -ne 'file') {
        $pre = Get-PcxTargetState -Target $typed
        $dry = New-PcxSnapshot -Target $typed -PreState $pre
        $comparison = Compare-PcxState -Recorded $dry['pre'] -Current $dry['post']
        if ([string]$comparison['status'] -eq 'equal') {
            return [pscustomobject]@{ ok = $false; code = 'PCX-E-APPLY-DRIFT'; reason = 'the target already matches the expected post-state; the plan drifted since it was built.'; snapshot = $null; result = $null }
        }
    }

    $context = [ordered]@{
        kind    = [string]$typed['Kind']
        target  = $typed
        profile = $Profile
        planId  = $PlanId
        item    = $Item
    }

    $result = $null
    if ($null -ne $Provider) {
        $result = & $Provider $context
    }
    else {
        $result = Invoke-PcxApplyProviderDefault -Context $context
    }

    if ($null -eq $result) {
        return [pscustomobject]@{ ok = $false; code = 'PCX-E-APPLY-PROVIDER'; reason = 'the provider returned no result.'; snapshot = $null; result = $null }
    }

    $status = [string](Get-PcxPolicyMember -Object $result -Name 'status')
    $code = Get-PcxPolicyMember -Object $result -Name 'code'
    $reason = Get-PcxPolicyMember -Object $result -Name 'reason'
    $snapshot = Get-PcxPolicyMember -Object $result -Name 'snapshot'

    if ($status -eq 'COMMITTED' -and $null -ne $Provider -and [string]$typed['Kind'] -eq 'file') {
        $status = 'FAILED'
        $code = 'PCX-E-APPLY-PROVIDER'
        $reason = 'an injected provider cannot satisfy the file read-back contract.'
    }

    if ($status -eq 'COMMITTED') {
        $verification = Invoke-PcxApplyProviderVerify -Context $context -Result $result
        if ($null -ne $verification) {
            $verifyStatus = [string](Get-PcxPolicyMember -Object $verification -Name 'status')
            if ($verifyStatus -ne 'COMMITTED') {
                $status = 'FAILED'
                $code = Get-PcxPolicyMember -Object $verification -Name 'code'
                $reason = Get-PcxPolicyMember -Object $verification -Name 'reason'
            }
        }
    }

    if ($status -ne 'COMMITTED') {
        return [pscustomobject]@{
            ok       = $false
            code     = $(if ([string]::IsNullOrWhiteSpace([string]$code)) { 'PCX-E-APPLY-FAILED' } else { [string]$code })
            reason   = [string]$reason
            snapshot = $snapshot
            result   = $result
        }
    }

    return [pscustomobject]@{ ok = $true; code = $null; reason = $null; snapshot = $snapshot; result = $result }
}

# ---------------------------------------------------------------------------
# One item
# ---------------------------------------------------------------------------

function Invoke-PcxApplyItem {
    <#
    .SYNOPSIS
        Applies one plan item. On any failure every snapshot taken for this item
        is inline-undone in reverse order and the item becomes FAILED.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Item,
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Provider
    )

    $itemId = [string](Get-PcxPolicyMember -Object $Item -Name 'id')
    $snapshots = New-Object System.Collections.Generic.List[object]
    $targetResults = New-Object System.Collections.Generic.List[object]
    $skippedAll = New-Object System.Collections.Generic.List[object]
    $fileDeletedCount = 0
    $anyCommitted = $false
    $failureCode = $null
    $failureReason = $null

    foreach ($canonicalTarget in (Get-PcxApplyTargetList -Item $Item)) {
        $targetResult = Invoke-PcxApplyOneTarget -Item $Item -CanonicalTarget $canonicalTarget -PlanId $PlanId -Profile $Profile -Provider $Provider

        $snapshot = Get-PcxPolicyMember -Object $targetResult -Name 'snapshot'
        if ($null -ne $snapshot) {
            [void]$snapshots.Add($snapshot)
        }

        $providerResult = Get-PcxPolicyMember -Object $targetResult -Name 'result'
        $targetSkipped = @()
        if ($null -ne $providerResult) {
            $rawSkipped = Get-PcxPolicyMember -Object $providerResult -Name 'skipped'
            if ($null -ne $rawSkipped) {
                $targetSkipped = @($rawSkipped)
            }
        }

        [void]$targetResults.Add([ordered]@{
                target  = $canonicalTarget
                ok      = [bool](Get-PcxPolicyMember -Object $targetResult -Name 'ok')
                code    = Get-PcxPolicyMember -Object $targetResult -Name 'code'
                reason  = Get-PcxPolicyMember -Object $targetResult -Name 'reason'
                skipped = @($targetSkipped)
            })

        if ([bool](Get-PcxPolicyMember -Object $targetResult -Name 'ok')) {
            $anyCommitted = $true
            if ($null -ne $providerResult) {
                $rawDeleted = Get-PcxPolicyMember -Object $providerResult -Name 'deleted'
                if ($null -ne $rawDeleted) {
                    $fileDeletedCount += @($rawDeleted).Count
                }
            }
            continue
        }

        # FILE-DELETE scope only: a file target that names its skipped files
        # does not abort the item; the loop continues with the next file.
        # Every other failure (registry, service, task, or a file failure
        # without a skip list) refuses exactly as before.
        $targetKind = ([string](Get-PcxPolicyMember -Object $canonicalTarget -Name 'kind')).Trim().ToLowerInvariant()
        if ($targetKind -eq 'file' -and $targetSkipped.Count -gt 0) {
            foreach ($skippedEntry in $targetSkipped) {
                [void]$skippedAll.Add($skippedEntry)
            }
            continue
        }

        $failureCode = [string](Get-PcxPolicyMember -Object $targetResult -Name 'code')
        $failureReason = [string](Get-PcxPolicyMember -Object $targetResult -Name 'reason')
        break
    }

    $status = $script:PcxApplyCommitted
    $undoNotes = New-Object System.Collections.Generic.List[object]

    if ($null -ne $failureCode) {
        $status = $script:PcxApplyFailed

        # Inline undo, LIFO over every snapshot this item produced.
        $index = $snapshots.Count - 1
        while ($index -ge 0) {
            $snapshot = $snapshots[$index]
            try {
                $restored = Restore-PcxSnapshot -Snapshot $snapshot
                [void]$undoNotes.Add([ordered]@{ status = 'restored'; kind = [string](Get-PcxPolicyMember -Object $restored -Name 'kind') })
            }
            catch {
                [void]$undoNotes.Add([ordered]@{ status = 'failed'; code = (Get-PcxProviderErrorCode -ErrorRecord $_); reason = $_.Exception.Message })
            }
            $index--
        }
    }

    if (($null -eq $failureCode) -and ($skippedAll.Count -gt 0)) {
        $itemSkipParts = New-Object System.Collections.Generic.List[string]
        foreach ($skippedEntry in $skippedAll) {
            [void]$itemSkipParts.Add(([string](Get-PcxPolicyMember -Object $skippedEntry -Name 'path') + ': ' + [string](Get-PcxPolicyMember -Object $skippedEntry -Name 'reason')))
        }
        $itemSkipDetails = ($itemSkipParts -join '; ')
        if ($anyCommitted) {
            $failureReason = Get-PcxText -Key 'apply.file.partial' -FormatArgs @(($fileDeletedCount), (($fileDeletedCount + $skippedAll.Count)), ($skippedAll.Count), $itemSkipDetails)
        }
        else {
            # Every file was skipped and nothing was deleted: refuse with the
            # first skipped file's typed code, never a partial success claim.
            $status = $script:PcxApplyFailed
            $failureCode = [string](Get-PcxPolicyMember -Object $skippedAll[0] -Name 'code')
            if ([string]::IsNullOrWhiteSpace($failureCode)) {
                $failureCode = 'PCX-E-PROVIDER'
            }
            $failureReason = Get-PcxText -Key 'apply.file.all-skipped' -FormatArgs @($skippedAll.Count, $itemSkipDetails)
        }
    }

    $undoItem = 'pcx undo --item ' + $itemId
    $undoPlan = 'pcx undo --plan ' + $PlanId
    $line = 'applied ' + $itemId + ': ' + $undoItem + ' | ' + $undoPlan

    if (($status -eq $script:PcxApplyCommitted) -and ($skippedAll.Count -gt 0)) {
        $line = 'applied ' + $itemId + ' (deleted ' + $fileDeletedCount + ', skipped ' + $skippedAll.Count + '): ' + $undoItem + ' | ' + $undoPlan
    }

    if ($status -eq $script:PcxApplyFailed) {
        $line = 'failed ' + $itemId + ' (' + $failureCode + '): ' + $undoItem + ' | ' + $undoPlan
    }

    return [ordered]@{
        id          = $itemId
        actionId    = [string](Get-PcxPolicyMember -Object $Item -Name 'actionId')
        status      = $status
        code        = $failureCode
        reason      = $failureReason
        deleted     = $fileDeletedCount
        snapshots   = @($snapshots.ToArray())
        targets     = @($targetResults.ToArray())
        skipped     = @($skippedAll.ToArray())
        undo        = @($undoNotes.ToArray())
        undoItem    = $undoItem
        undoPlan    = $undoPlan
        line        = $line
    }
}

# ---------------------------------------------------------------------------
# Session update
# ---------------------------------------------------------------------------

function Update-PcxApplySessionFromItem {
    param(
        [Parameter(Mandatory = $true)][object] $Session,
        [Parameter(Mandatory = $true)][object] $ItemResult
    )

    $record = Get-PcxApplyRecord -Session $Session -ItemId ([string]$ItemResult['id'])
    if ($null -eq $record) { return }

    $record['status'] = [string]$ItemResult['status']
    $record['snapshots'] = @($ItemResult['snapshots'])
    $record['code'] = $ItemResult['code']
    $record['reason'] = $ItemResult['reason']
    $record['line'] = $ItemResult['line']

    [Console]::Error.WriteLine([string]$ItemResult['line'])
}

# ---------------------------------------------------------------------------
# Plan resolution
# ---------------------------------------------------------------------------

function Resolve-PcxApplyPlan {
    <#
    .SYNOPSIS
        Loads plan-<id>.json or builds a plan from a selection.
        Returns @{ ok; code; reason; plan; planId; planHash; planBytes; items }.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Selection,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][string] $FixturePath
    )

    if (-not [string]::IsNullOrWhiteSpace($PlanId)) {
        if ($PlanId -notmatch $script:PcxApplyPlanIdPattern) {
            return New-PcxApplyFailure -Code 'PCX-E-APPLY-PLANID' -Reason "plan id '$PlanId' is not 16 lowercase hex characters."
        }

        $planPath = Get-PcxStatePath -Kind 'journal' -ChildPath ('plan-' + $PlanId + '.json')
        if (-not [System.IO.File]::Exists($planPath)) {
            return New-PcxApplyFailure -Code 'PCX-E-PLAN-NOTFOUND' -Reason "no plan '$PlanId' exists at '$planPath'."
        }

        $bytes = [System.IO.File]::ReadAllBytes($planPath)
        $validated = Test-PcxPlan -PlanBytes $bytes
        if (-not [bool]$validated.ok) {
            return New-PcxApplyFailure -Code ([string]$validated.code) -Reason ([string]$validated.reason)
        }

        return [pscustomobject]@{
            ok        = $true
            code      = $null
            reason    = $null
            plan      = $validated.plan
            planId    = [string]$validated.planId
            planHash  = (Get-PcxSha256 -Bytes $bytes)
            planBytes = $bytes
            items     = @($validated.items)
        }
    }

    if ([string]::IsNullOrWhiteSpace($Selection)) {
        return New-PcxApplyFailure -Code 'PCX-E-APPLY-SELECTION' -Reason 'tune --apply needs a plan id or a row selection.'
    }

    $scanData = $Scan
    if ($null -eq $scanData) {
        if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
            try {
                $scanData = Get-PcxScan -FixturePath $FixturePath
            }
            catch {
                return New-PcxApplyFailure -Code 'PCX-E-APPLY-SCAN' -Reason $_.Exception.Message
            }
        }
        elseif ([string]::IsNullOrEmpty($env:PCX_TEST_RUN)) {
            try {
                $scanData = Get-PcxScan
            }
            catch {
                return New-PcxApplyFailure -Code 'PCX-E-APPLY-SCAN' -Reason $_.Exception.Message
            }
        }
        else {
            return New-PcxApplyFailure -Code 'PCX-E-APPLY-SCAN' -Reason 'fixture mode is active and no fixture path was supplied.'
        }
    }

    $built = Invoke-PcxPlan -Selection $Selection -Scan $scanData -Profile $Profile
    if (@($built.refused).Count -gt 0) {
        $first = @($built.refused)[0]
        return New-PcxApplyFailure -Code ([string](Get-PcxPolicyMember -Object $first -Name 'code')) -Reason ([string](Get-PcxPolicyMember -Object $first -Name 'reason'))
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-PcxCanonicalJson -InputObject $built.plan))

    # Re-validate the bytes the parent would hand to an elevated child.
    $validated = Test-PcxPlan -PlanBytes $bytes
    if (-not [bool]$validated.ok) {
        return New-PcxApplyFailure -Code ([string]$validated.code) -Reason ([string]$validated.reason)
    }

    return [pscustomobject]@{
        ok        = $true
        code      = $null
        reason    = $null
        plan      = $built.plan
        planId    = [string]$built.planId
        planHash  = (Get-PcxSha256 -Bytes $bytes)
        planBytes = $bytes
        items     = @($validated.items)
    }
}

function Get-PcxApplyPlanProfile {
    param([Parameter(Mandatory = $true)][object] $Plan)

    return Get-PcxPolicyMember -Object $Plan -Name 'profile'
}

# ---------------------------------------------------------------------------
# Elevated child contract
# ---------------------------------------------------------------------------

function Invoke-PcxApplyElevated {
    <#
    .SYNOPSIS
        Validates the bytes an elevated child received from its parent.

    .DESCRIPTION
        Never trusts the caller's hash or sid: recomputes the byte hash, reruns
        Test-PcxPlan on the exact bytes, and compares the caller SID with the
        current user SID. Returns @{ ok; code; reason; planId; planHash; items }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PlanBytesBase64,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PlanHash,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $CallerSid,
        [Parameter(Mandatory = $false)][AllowNull()][string] $CurrentSid
    )

    function New-PcxApplyElevatedResult {
        param([bool] $Ok, [string] $Code, [string] $Reason, [object] $PlanId, [object] $PlanHash, [object] $Items, [object] $Plan)

        return [pscustomobject][ordered]@{
            ok       = $Ok
            code     = $Code
            reason   = $Reason
            planId   = $PlanId
            planHash = $PlanHash
            items    = @($Items)
            plan     = $Plan
        }
    }

    if ([string]::IsNullOrWhiteSpace($PlanBytesBase64)) {
        return New-PcxApplyElevatedResult -Ok $false -Code 'PCX-E-PLAN-SHAPE' -Reason 'the elevated invocation carries no plan bytes.' -PlanId $null -PlanHash $null -Items @()
    }

    $bytes = $null
    try {
        $bytes = [System.Convert]::FromBase64String($PlanBytesBase64)
    }
    catch {
        return New-PcxApplyElevatedResult -Ok $false -Code 'PCX-E-PLAN-SHAPE' -Reason 'the plan payload is not valid base64.' -PlanId $null -PlanHash $null -Items @()
    }

    if ($bytes.Length -gt $script:PcxApplyMaxPlanBytes) {
        return New-PcxApplyElevatedResult -Ok $false -Code 'PCX-E-PLAN-TOO-LARGE' -Reason ("the plan is {0} bytes; the elevated invocation accepts at most {1}." -f $bytes.Length, $script:PcxApplyMaxPlanBytes) -PlanId $null -PlanHash $null -Items @()
    }

    if ([string]::IsNullOrWhiteSpace($PlanHash)) {
        return New-PcxApplyElevatedResult -Ok $false -Code 'PCX-E-PLAN-MISMATCH' -Reason 'the elevated invocation carries no plan hash.' -PlanId $null -PlanHash $null -Items @()
    }

    $recomputedHash = Get-PcxSha256 -Bytes $bytes
    if (-not [string]::Equals($recomputedHash, $PlanHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-PcxApplyElevatedResult -Ok $false -Code 'PCX-E-PLAN-MISMATCH' -Reason 'the received plan bytes do not match the hash passed by the parent.' -PlanId $null -PlanHash $null -Items @()
    }

    $validated = Test-PcxPlan -PlanBytes $bytes
    if (-not [bool]$validated.ok) {
        return New-PcxApplyElevatedResult -Ok $false -Code ([string]$validated.code) -Reason ([string]$validated.reason) -PlanId $null -PlanHash $null -Items @()
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
        return New-PcxApplyElevatedResult -Ok $false -Code 'PCX-E-SID-MISMATCH' -Reason 'the caller SID does not match the elevated process SID.' -PlanId $null -PlanHash $null -Items @()
    }

    return New-PcxApplyElevatedResult -Ok $true -Code 'PCX-E-APPLY-ELEVATED-ALLOW' -Reason 'the plan bytes re-validate and the caller SID matches.' -PlanId ([string]$validated.planId) -PlanHash $recomputedHash -Items @($validated.items) -Plan $validated.plan
}

function Invoke-PcxApplyElevatedCommand {
    <#
    .SYNOPSIS
        Dispatches the internal `apply-elevated` command for the child process.
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
        $result = Invoke-PcxApplyElevated -PlanBytesBase64 ([string]$payload) -PlanHash ([string]$hash) -CallerSid ([string]$sid)
        if (-not $result.ok) {
            return New-PcxRefusal -CommandName 'apply-elevated' -Code ([string]$result.code) -Message ([string]$result.reason)
        }

        return New-PcxResult -ExitCode $script:PcxExitOk -Envelope (New-PcxEnvelope -Status 'ok' -CommandName 'apply-elevated' -ExitCode $script:PcxExitOk -Data ([ordered]@{ planId = $result.planId; planHash = $result.planHash }))
    }

    $loopResult = Invoke-PcxApplyElevatedLoop -PlanBytesBase64 ([string]$payload) -PlanHash ([string]$hash) -CallerSid ([string]$sid)
    if (-not $loopResult.ok) {
        return New-PcxRefusal -CommandName 'apply-elevated' -Code ([string]$loopResult.code) -Message ([string]$loopResult.reason)
    }

    $data = [ordered]@{
        status      = $loopResult.status
        planId      = $loopResult.planId
        applied     = @($loopResult.applied)
        next        = $loopResult.next
        itemResults = @($loopResult.itemResults)
        prompts     = $loopResult.prompts
        stoppedBy   = $loopResult.stoppedBy
        declined    = $loopResult.declined
    }

    return New-PcxResult -ExitCode $script:PcxExitOk -Envelope (New-PcxEnvelope -Status 'ok' -CommandName 'apply-elevated' -ExitCode $script:PcxExitOk -Data $data)
}

# ---------------------------------------------------------------------------
# Default elevation
# ---------------------------------------------------------------------------

function Invoke-PcxApplyDefaultElevation {
    <#
    .SYNOPSIS
        Production UAC: one Start-Process -Verb RunAs for the whole plan.

    .DESCRIPTION
        The elevated child receives canonical plan bytes, their SHA-256 and the
        caller SID, re-validates them, and then OWNS the stop loop and every
        write. The parent only launches, waits, and relays the exit code; it
        performs no write for an admin plan. A declined or failed launch returns
        ok = false, so nothing is applied.

        The child's structured per-item outcome is durable in the session file,
        which the parent reads after the child exits.
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
        'apply-elevated',
        '--run',
        '--payload', [string]$Request.payloadBase64,
        '--hash', [string]$Request.planHash,
        '--sid', [string]$Request.callerSid
    )

    try {
        $process = Start-Process -FilePath $hostPath -ArgumentList $argumentList -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ ok = $false; declined = $true; elevated = $false; code = 'PCX-E-UAC-DECLINED'; reason = $_.Exception.Message; result = $null }
    }

    if ($null -eq $process -or $process.ExitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; declined = $false; elevated = $true; code = 'PCX-E-UAC-CHILD'; reason = 'the elevated child did not succeed; it applied nothing it could not verify.'; result = $null }
    }

    return [pscustomobject]@{ ok = $true; declined = $false; elevated = $true; code = $null; reason = $null; result = $null }
}
function Get-PcxApplyCurrentSid {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Elevation need: only an admin target forces the elevated child
# ---------------------------------------------------------------------------

function Test-PcxApplyTargetNeedsElevation {
    <#
    .SYNOPSIS
        True when writing this target requires an elevated process.

    .DESCRIPTION
        HKCU registry values and files under the user's own LOCALAPPDATA/APPDATA
        are user-writable. Services, scheduled tasks, HKLM/HKU/HKCC values and
        files outside the user profile need elevation.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $kind = ([string](Get-PcxPolicyMember -Object $Target -Name 'kind')).Trim().ToLowerInvariant()

    switch ($kind) {
        'service' { return $true }
        'task' { return $true }
        'registry' {
            $hive = ([string](Get-PcxPolicyMember -Object $Target -Name 'hive')).Trim().ToUpperInvariant()
            return ($hive -ne 'HKCU')
        }
        'file' {
            $path = [string](Get-PcxPolicyMember -Object $Target -Name 'path')
            foreach ($name in @('LOCALAPPDATA', 'APPDATA')) {
                $root = [string](Get-PcxPolicyMember -Object (Get-PcxPolicyMember -Object $Profile -Name 'environment') -Name $name)
                if ([string]::IsNullOrWhiteSpace($root)) { continue }
                $bound = $root.TrimEnd([char]'\')
                if ([string]::Equals($path.TrimEnd([char]'\'), $bound, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
                if ($path.StartsWith($bound + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
            }
            return $true
        }
    }

    return $true
}

function Test-PcxApplyItemsNeedElevation {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $Items,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    foreach ($item in @($Items)) {
        foreach ($target in (Get-PcxApplyTargetList -Item $item)) {
            if (Test-PcxApplyTargetNeedsElevation -Target $target -Profile $Profile) {
                return $true
            }
        }
    }

    return $false
}

# ---------------------------------------------------------------------------
# Elevated child loop
# ---------------------------------------------------------------------------

function Invoke-PcxApplyElevatedLoop {
    <#
    .SYNOPSIS
        The elevated child entry point: validate bytes, then own the stop loop
        and the writes.

    .DESCRIPTION
        Runs Invoke-PcxApplyElevated first (byte hash, Test-PcxPlan, caller SID),
        then the same prompt/session/pipeline loop as a non-admin console apply.
        Every write happens in this process. The parent never writes for an
        admin plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PlanBytesBase64,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $PlanHash,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $CallerSid,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $InputReader,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Provider,
        [Parameter(Mandatory = $false)][AllowNull()][Nullable[bool]] $StdinRedirected,
        [Parameter(Mandatory = $false)][AllowNull()][string] $CurrentSid
    )

    $validated = Invoke-PcxApplyElevated -PlanBytesBase64 $PlanBytesBase64 -PlanHash $PlanHash -CallerSid $CallerSid -CurrentSid $CurrentSid
    if (-not $validated.ok) {
        return [pscustomobject][ordered]@{
            ok          = $false
            status      = 'refused'
            code        = [string]$validated.code
            reason      = [string]$validated.reason
            applied     = @()
            next        = $null
            itemResults = @()
            planId      = $null
            prompts     = 0
            stoppedBy   = $null
            declined    = $false
        }
    }

    if ($null -eq $InputReader) {
        $InputReader = { [Console]::In.ReadLine() }
    }

    return Invoke-PcxQueueLoop -Plan $validated.plan -PlanId ([string]$validated.planId) -Profile (Get-PcxApplyPlanProfile -Plan $validated.plan) -Items @($validated.items) -InputReader $InputReader -Provider $Provider -StdinRedirected $StdinRedirected
}

# ---------------------------------------------------------------------------
# Public: apply
# ---------------------------------------------------------------------------

function Invoke-PcxApply {
    <#
    .SYNOPSIS
        Applies one item (agent) or runs the console loop (console).

    .DESCRIPTION
        Agent mode never reads stdin and never applies more than one item.
        Console mode delegates to Invoke-PcxQueue, which owns the single stop
        loop and the single UAC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Selection,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][string] $FixturePath,
        [Parameter(Mandatory = $false)][ValidateSet('agent', 'console')][string] $Mode = 'agent',
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $InputReader,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Elevation,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Provider,
        [Parameter(Mandatory = $false)][AllowNull()][Nullable[bool]] $StdinRedirected
    )

    $resolved = Resolve-PcxApplyPlan -PlanId $PlanId -Selection $Selection -Scan $Scan -Profile $Profile -FixturePath $FixturePath
    if (-not $resolved.ok) {
        return [pscustomobject][ordered]@{
            ok       = $false
            status   = 'refused'
            code     = [string]$resolved.code
            reason   = [string]$resolved.reason
            applied  = @()
            next     = $null
            itemResults = @()
            planId   = $null
            prompts  = 0
        }
    }

    if ([string]::IsNullOrWhiteSpace($PlanId)) {
        $PlanId = $resolved.planId
    }

    $profileObject = Get-PcxApplyPlanProfile -Plan $resolved.plan

    if ($Mode -eq 'console') {
        return Invoke-PcxQueue -Plan $resolved.plan -PlanId $PlanId -Profile $profileObject -Items $resolved.items `
            -PlanBytes $resolved.planBytes -PlanHash $resolved.planHash `
            -InputReader $InputReader -Elevation $Elevation -Provider $Provider -StdinRedirected $StdinRedirected
    }

    $session = Read-PcxApplySession -PlanId $PlanId -Plan $resolved.plan -Items $resolved.items
    $null = Write-PcxApplySession -Session $session -PlanId $PlanId

    $pending = @(Get-PcxApplyPendingItems -Plan $resolved.plan -Session $session)
    if ($pending.Count -eq 0) {
        return [pscustomobject][ordered]@{
            ok          = $true
            status      = 'done'
            code        = $null
            reason      = $null
            applied     = @()
            next        = $null
            itemResults = @()
            planId      = $PlanId
            prompts     = 0
        }
    }

    # Exactly one PENDING item; never stdin.
    $item = $pending[0]
    $itemResult = Invoke-PcxApplyItem -Item $item -PlanId $PlanId -Profile $profileObject -Provider $Provider
    Update-PcxApplySessionFromItem -Session $session -ItemResult $itemResult
    $null = Write-PcxApplySession -Session $session -PlanId $PlanId

    $remaining = @(Get-PcxApplyPendingItems -Plan $resolved.plan -Session $session)
    $status = if ($remaining.Count -eq 0) { 'done' } else { 'partial' }
    $next = if ($remaining.Count -eq 0) { $null } else { [string](Get-PcxPolicyMember -Object $remaining[0] -Name 'id') }

    $applied = @()
    if ([string]$itemResult['status'] -eq $script:PcxApplyCommitted) {
        $applied = @([string]$itemResult['id'])
    }

    return [pscustomobject][ordered]@{
        ok          = $true
        status      = $status
        code        = $itemResult['code']
        reason      = $itemResult['reason']
        applied     = @($applied)
        next        = $next
        itemResults = @($itemResult)
        planId      = $PlanId
        prompts     = 0
    }
}

# ---------------------------------------------------------------------------
# Public: dispatch entry for `pcx tune --apply`
# ---------------------------------------------------------------------------

function Invoke-PcxApplyCommand {
    <#
    .SYNOPSIS
        Parses `tune --apply ...` and returns a pcx result object.
    #>
    param([Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]] $Arguments = @())

    $planId = $null
    $selection = $null
    $fixture = $null
    $profilePath = $null
    $proposalsPath = $null
    $console = $false

    $positional = New-Object System.Collections.Generic.List[string]
    $index = 0

    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        $value = $null
        if (($index + 1) -lt $Arguments.Count) { $value = [string]$Arguments[$index + 1] }

        switch ($token) {
            '--apply' { $index++; continue }
            '--console' { $console = $true; $index++; continue }
            '--plan' { $planId = $value; $index += 2; continue }
            '--fixture' { $fixture = $value; $index += 2; continue }
            '--proposals' { $proposalsPath = $value; $index += 2; continue }
            '--profile' { $profilePath = $value; $index += 2; continue }
            default {
                if (-not [string]::IsNullOrWhiteSpace($token) -and -not $token.StartsWith('--')) {
                    [void]$positional.Add($token)
                }
                $index++
            }
        }
    }

    if ($positional.Count -gt 0) {
        $selection = ($positional -join ',')
    }

    $profileData = $null
    if (-not [string]::IsNullOrWhiteSpace($profilePath)) {
        try {
            $profileData = Read-PcxJson -Path $profilePath
        }
        catch {
            return New-PcxError -CommandName 'tune' -Code 'PCX-E-PROFILE' -Message ("The profile could not be read: {0}" -f $_.Exception.Message)
        }
    }

    $mode = if ($console) { 'console' } else { 'agent' }

    if (-not [string]::IsNullOrWhiteSpace($proposalsPath)) {
        if (-not [string]::IsNullOrWhiteSpace($planId) -or -not [string]::IsNullOrWhiteSpace($selection)) {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-PLAN-SELECTION' -Message 'Provide either --proposals or a plan id / row selection, not both.'
        }

        $document = $null
        try {
            $document = Read-PcxJson -Path $proposalsPath
        }
        catch {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-PROPOSALS-FILE' -Message ("The proposals file could not be read: {0}" -f $_.Exception.Message)
        }

        $proposalSchema = [string](Get-PcxPolicyMember -Object $document -Name 'schema')
        if ($proposalSchema -ne 'pcx-proposals/1') {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-PROPOSALS-SCHEMA' -Message ("The proposals schema must be 'pcx-proposals/1' (found '$proposalSchema').")
        }

        $rawProposals = Get-PcxPolicyMember -Object $document -Name 'proposals'
        if ($null -eq $rawProposals) {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-PROPOSALS-SHAPE' -Message 'The proposals document carries no proposals array.'
        }
        $proposalList = @($rawProposals)
        if ($proposalList.Count -eq 0) {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-PROPOSALS-SHAPE' -Message 'The proposals array is empty.'
        }

        $scanData = $null
        if (-not [string]::IsNullOrWhiteSpace($fixture)) {
            try {
                $scanData = Get-PcxScan -FixturePath $fixture
            }
            catch {
                return New-PcxError -CommandName 'tune' -Code 'PCX-E-APPLY-SCAN' -Message $_.Exception.Message
            }
        }
        elseif ([string]::IsNullOrEmpty($env:PCX_TEST_RUN)) {
            try {
                $scanData = Get-PcxScan
            }
            catch {
                return New-PcxError -CommandName 'tune' -Code 'PCX-E-APPLY-SCAN' -Message $_.Exception.Message
            }
        }
        else {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-APPLY-SCAN' -Message 'Fixture mode is active and no fixture path was supplied.'
        }

        $planned = $null
        try {
            $planned = Invoke-PcxPlan -Proposals $proposalList -Scan $scanData -Profile $profileData
        }
        catch {
            return New-PcxError -CommandName 'tune' -Code 'PCX-E-PLAN' -Message $_.Exception.Message
        }

        $planRefused = @($planned.refused)
        if ($planRefused.Count -gt 0) {
            $first = $planRefused[0]
            return New-PcxRefusal -CommandName 'tune' -Code ([string](Get-PcxPolicyMember -Object $first -Name 'code')) -Message ([string](Get-PcxPolicyMember -Object $first -Name 'reason'))
        }

        $planId = [string]$planned.planId
        $selection = $null
    }

    try {
        $result = Invoke-PcxApply -PlanId $planId -Selection $selection -Profile $profileData -FixturePath $fixture -Mode $mode
    }
    catch {
        return New-PcxError -CommandName 'tune' -Code 'PCX-E-APPLY' -Message $_.Exception.Message
    }

    if (-not $result.ok) {
        return New-PcxRefusal -CommandName 'tune' -Code ([string]$result.code) -Message ([string]$result.reason)
    }

    $data = [ordered]@{
        status      = $result.status
        planId      = $result.planId
        applied     = @($result.applied)
        next        = $result.next
        itemResults = @($result.itemResults)
        prompts     = $result.prompts
    }
    if ($null -ne (Get-PcxPolicyMember -Object $result -Name 'code') -and -not [string]::IsNullOrWhiteSpace([string]$result.code)) {
        $data['code'] = $result.code
        $data['reason'] = $result.reason
    }

    return New-PcxResult -ExitCode $script:PcxExitOk -Envelope (New-PcxEnvelope -Status 'ok' -CommandName 'tune' -ExitCode $script:PcxExitOk -Data $data)
}
