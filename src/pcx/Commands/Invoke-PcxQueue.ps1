<#
.SYNOPSIS
    Console-mode apply queue: one stop loop, one UAC for the whole plan.

.DESCRIPTION
    Invoke-PcxQueue decides who owns the writes:

      * Non-admin plan: no UAC is raised. The in-process stop loop runs here,
        prompts before every item and writes through the providers.
      * Admin plan: ONE elevation call is made. The elevated child re-validates
        the canonical bytes (hash, Test-PcxPlan, caller SID), then owns the stop
        loop AND the writes. The parent only launches, waits and relays the
        result; it performs no write for an admin plan.

    In both paths the prompt comes BEFORE every item, including the first
    PENDING item after a resume: [Enter] advances, `s` or the Cyrillic stop word
    stops, anything else re-prompts, and EOF never advances. COMMITTED items are
    skipped before snapshotting. A declined or failed elevation applies nothing
    and leaves every item PENDING.

    Enter, `s`, the Cyrillic stop word, garbage and EOF are all injectable
    through -InputReader. The UAC decision is injectable through -Elevation; a
    fake can run Invoke-PcxApplyElevatedLoop in-process with the same reader, so
    tests prove writes happen inside the elevated path.
#>

Set-StrictMode -Version 2.0

# Cyrillic "stop" built from code points so the source stays ASCII and PS 5.1
# cannot misread the literal on a non-UTF-8 console code page.
$script:PcxApplyStopWord = -join @([char]0x0441, [char]0x0442, [char]0x043E, [char]0x043F)

function Write-PcxApplyPromptLine {
    param([Parameter(Mandatory = $true)][string] $Message)

    [Console]::Error.WriteLine($Message)
}

function Read-PcxApplyAnswer {
    <#
    .SYNOPSIS
        Reads one answer: next | stop | eof. Garbage re-prompts; EOF never
        advances.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock] $InputReader,
        [Parameter(Mandatory = $true)][ref] $PromptCount
    )

    while ($true) {
        $PromptCount.Value = [int]$PromptCount.Value + 1
        Write-PcxApplyPromptLine '[Enter] - next, [s] - stop'

        $line = & $InputReader
        if ($null -eq $line) {
            # EOF never advances.
            return 'eof'
        }

        $text = ([string]$line).Trim().ToLowerInvariant()
        if ($text.Length -eq 0) {
            return 'next'
        }
        if ($text -eq 's' -or $text -eq $script:PcxApplyStopWord) {
            return 'stop'
        }

        Write-PcxApplyPromptLine "unknown input; press [Enter] to continue or [s] to stop."
    }
}

function New-PcxQueueEmptyResult {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $PlanId)

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
        stoppedBy   = $null
        declined    = $false
        elevated    = $false
    }
}

function Invoke-PcxQueueLoop {
    <#
    .SYNOPSIS
        The stop loop itself. Runs in-process for a non-admin plan and inside
        the elevated child for an admin plan.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $Items,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $InputReader,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Provider,
        [Parameter(Mandatory = $false)][AllowNull()][Nullable[bool]] $StdinRedirected
    )

    $redirected = [Console]::IsInputRedirected
    if ($null -ne $StdinRedirected) {
        $redirected = [bool]$StdinRedirected
    }
    if ($redirected) {
        $refused = New-PcxQueueEmptyResult -PlanId $PlanId
        $refused.ok = $false
        $refused.status = 'refused'
        $refused.code = 'PCX-E-NO-TTY'
        $refused.reason = 'console mode needs an interactive stdin; stdin is redirected.'
        return $refused
    }

    if ($null -eq $InputReader) {
        $InputReader = { [Console]::In.ReadLine() }
    }

    $planItems = @($Items)
    if ($planItems.Count -eq 0) {
        $planItems = @(Get-PcxPolicyMember -Object $Plan -Name 'items')
    }

    $session = Read-PcxApplySession -PlanId $PlanId -Plan $Plan -Items $planItems
    $null = Write-PcxApplySession -Session $session -PlanId $PlanId

    $result = New-PcxQueueEmptyResult -PlanId $PlanId

    $pending = @(Get-PcxApplyPendingItems -Plan $Plan -Session $session)
    if ($pending.Count -eq 0) {
        return $result
    }

    $applied = New-Object System.Collections.Generic.List[string]
    $itemResults = New-Object System.Collections.Generic.List[object]
    $promptCount = 0

    while ($true) {
        $pending = @(Get-PcxApplyPendingItems -Plan $Plan -Session $session)
        if ($pending.Count -eq 0) {
            $result.status = 'done'
            break
        }

        $answer = Read-PcxApplyAnswer -InputReader $InputReader -PromptCount ([ref]$promptCount)
        $result.prompts = [int]$promptCount

        if ($answer -eq 'stop' -or $answer -eq 'eof') {
            # EOF and an explicit stop both leave the current plan resumable.
            $result.stoppedBy = $answer
            $result.status = 'stopped'
            break
        }

        $item = $pending[0]
        $itemResult = Invoke-PcxApplyItem -Item $item -PlanId $PlanId -Profile $Profile -Provider $Provider
        Update-PcxApplySessionFromItem -Session $session -ItemResult $itemResult
        $null = Write-PcxApplySession -Session $session -PlanId $PlanId
        [void]$itemResults.Add($itemResult)

        if ([string]$itemResult['status'] -eq $script:PcxApplyCommitted) {
            [void]$applied.Add([string]$itemResult['id'])
        }
    }

    $remaining = @(Get-PcxApplyPendingItems -Plan $Plan -Session $session)
    $result.applied = @($applied.ToArray())
    $result.itemResults = @($itemResults.ToArray())
    if ($remaining.Count -gt 0) {
        $result.next = [string](Get-PcxPolicyMember -Object $remaining[0] -Name 'id')
    }

    return $result
}

function ConvertTo-PcxQueueChildResult {
    <#
    .SYNOPSIS
        Normalizes a fake or child result into the queue result shape.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Child,
        [Parameter(Mandatory = $true)][string] $PlanId
    )

    $result = New-PcxQueueEmptyResult -PlanId $PlanId
    $result.ok = [bool](Get-PcxPolicyMember -Object $Child -Name 'ok')
    $result.status = [string](Get-PcxPolicyMember -Object $Child -Name 'status')
    $result.code = Get-PcxPolicyMember -Object $Child -Name 'code'
    $result.reason = Get-PcxPolicyMember -Object $Child -Name 'reason'
    $result.applied = @(Get-PcxPolicyMember -Object $Child -Name 'applied')
    $result.next = Get-PcxPolicyMember -Object $Child -Name 'next'
    $result.itemResults = @(Get-PcxPolicyMember -Object $Child -Name 'itemResults')
    $result.prompts = [int](Get-PcxPolicyMember -Object $Child -Name 'prompts')
    $result.stoppedBy = Get-PcxPolicyMember -Object $Child -Name 'stoppedBy'
    $result.declined = [bool](Get-PcxPolicyMember -Object $Child -Name 'declined')
    $result.elevated = $true

    return $result
}

function Get-PcxQueueSessionOutcome {
    <#
    .SYNOPSIS
        Builds the queue result from the durable session after a real elevated
        child exits. The parent never guesses item outcomes.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $true)][AllowNull()][object[]] $Items
    )

    $session = Read-PcxApplySession -PlanId $PlanId -Plan $Plan -Items $Items
    $result = New-PcxQueueEmptyResult -PlanId $PlanId

    $applied = New-Object System.Collections.Generic.List[string]
    foreach ($record in $session.items) {
        if ([string]$record['status'] -eq $script:PcxApplyCommitted) {
            [void]$applied.Add([string]$record['id'])
        }
    }

    $pending = @(Get-PcxApplyPendingItems -Plan $Plan -Session $session)
    $result.applied = @($applied.ToArray())
    $result.status = $(if ($pending.Count -eq 0) { 'done' } else { 'stopped' })
    if ($pending.Count -gt 0) {
        $result.next = [string](Get-PcxPolicyMember -Object $pending[0] -Name 'id')
    }
    $result.elevated = $true

    return $result
}

function Invoke-PcxQueue {
    <#
    .SYNOPSIS
        Console mode over one validated plan.

    .PARAMETER Plan
        The validated plan document (items in plan order).

    .PARAMETER PlanBytes / PlanHash
        Canonical plan bytes and their SHA-256, passed to the elevated child.

    .PARAMETER InputReader
        Injectable answer reader. Production default is [Console]::In.ReadLine().

    .PARAMETER Elevation
        Injectable single UAC. Production default is Start-Process -Verb RunAs.

    .PARAMETER Provider
        Test seam for the non-admin in-process loop. An admin plan ignores it:
        the elevated child writes, the parent does not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $Items,
        [Parameter(Mandatory = $false)][AllowNull()][byte[]] $PlanBytes,
        [Parameter(Mandatory = $false)][AllowNull()][string] $PlanHash,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $InputReader,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Elevation,
        [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Provider,
        [Parameter(Mandatory = $false)][AllowNull()][Nullable[bool]] $StdinRedirected
    )

    $redirected = [Console]::IsInputRedirected
    if ($null -ne $StdinRedirected) {
        $redirected = [bool]$StdinRedirected
    }
    if ($redirected) {
        $refused = New-PcxQueueEmptyResult -PlanId $PlanId
        $refused.ok = $false
        $refused.status = 'refused'
        $refused.code = 'PCX-E-NO-TTY'
        $refused.reason = 'console mode needs an interactive stdin; stdin is redirected.'
        return $refused
    }

    if ($null -eq $InputReader) {
        $InputReader = { [Console]::In.ReadLine() }
    }

    $planItems = @($Items)
    if ($planItems.Count -eq 0) {
        $planItems = @(Get-PcxPolicyMember -Object $Plan -Name 'items')
    }

    $session = Read-PcxApplySession -PlanId $PlanId -Plan $Plan -Items $planItems
    $null = Write-PcxApplySession -Session $session -PlanId $PlanId

    $pending = @(Get-PcxApplyPendingItems -Plan $Plan -Session $session)
    if ($pending.Count -eq 0) {
        return New-PcxQueueEmptyResult -PlanId $PlanId
    }

    if (-not (Test-PcxApplyItemsNeedElevation -Items $pending -Profile $Profile)) {
        # Non-admin plan: no UAC, writes in this process.
        return Invoke-PcxQueueLoop -Plan $Plan -PlanId $PlanId -Profile $Profile -Items $planItems -InputReader $InputReader -Provider $Provider -StdinRedirected $redirected
    }

    # Admin plan: ONE elevation. The child owns the loop and the writes.
    $callerSid = Get-PcxApplyCurrentSid
    $payloadBase64 = ''
    if ($null -ne $PlanBytes -and $PlanBytes.Length -gt 0) {
        $payloadBase64 = [System.Convert]::ToBase64String($PlanBytes)
    }

    $elevation = $Elevation
    if ($null -eq $elevation) {
        $elevation = { param($request) Invoke-PcxApplyDefaultElevation -Request $request }
    }

    $request = [ordered]@{
        payloadBase64   = $payloadBase64
        planHash        = [string]$PlanHash
        planId          = $PlanId
        callerSid       = [string]$callerSid
        mode            = 'console'
        stdinRedirected = $redirected
        inputReader     = $InputReader
    }

    $decision = $null
    try {
        $decision = & $elevation $request
    }
    catch {
        $decision = [pscustomobject]@{ ok = $false; declined = $true; code = 'PCX-E-UAC-DECLINED'; reason = $_.Exception.Message; result = $null }
    }

    $decisionOk = $false
    if ($null -ne $decision) {
        $decisionOk = [bool](Get-PcxPolicyMember -Object $decision -Name 'ok')
    }

    if (-not $decisionOk) {
        $stopped = New-PcxQueueEmptyResult -PlanId $PlanId
        $stopped.status = 'stopped'
        $stopped.elevated = [bool](Get-PcxPolicyMember -Object $decision -Name 'elevated')
        $stopped.declined = [bool](Get-PcxPolicyMember -Object $decision -Name 'declined')
        $stopped.code = 'PCX-E-UAC-DECLINED'
        $stopped.reason = [string](Get-PcxPolicyMember -Object $decision -Name 'reason')
        return $stopped
    }

    $childResult = Get-PcxPolicyMember -Object $decision -Name 'result'
    if ($null -eq $childResult) {
        if ($null -ne (Get-PcxPolicyMember -Object $decision -Name 'status')) {
            # A fake elevation returned the child loop result directly.
            $childResult = $decision
        }
    }

    if ($null -ne $childResult) {
        return ConvertTo-PcxQueueChildResult -Child $childResult -PlanId $PlanId
    }

    # Real elevated child: outcome comes from the durable session the child
    # wrote. The parent performed no write.
    return Get-PcxQueueSessionOutcome -Plan $Plan -PlanId $PlanId -Items $planItems
}
