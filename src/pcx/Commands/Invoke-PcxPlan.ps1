<#
.SYNOPSIS
    Internal plan validator: selection -> validated plan -> canonical hash.

.DESCRIPTION
    This file owns the gate between a read-only scan and the writer. It has two
    public surfaces and no user-facing command:

        Invoke-PcxPlan   builds a plan from stable table row numbers or from an
                         explicit proposal list supplied by the agent
        Test-PcxPlan     the elevated child's re-validation: it decodes the
                         received bytes, recomputes the canonical hash itself
                         and re-runs the full validation

    Plan contract (pcx-plan/1):
        plan_hash   lowercase SHA-256 of the canonical JSON of the plan body
                    (schema, build, profile, items, demoted). The hash field and
                    the derived planId are excluded, so planId can equal the
                    first 16 hex chars of plan_hash without a cycle.
        planId      first 16 hex chars of plan_hash (no clock, no RNG)
        items       applyable items only
        demoted     items whose verified_on_build excludes the detected major
                    build; they are never applied and never appear in items
        item        { id; actionId; row; origin; target; category; group;
                      inverse; evidence; user_text_en; user_text_ru }

    Expansion: %TOKEN% file roots are resolved from profile.environment at plan
    time, so the stored target is absolute and apply is deterministic. An
    unresolvable token refuses.

    Validation is authoritative and is re-run by Test-PcxPlan:
        * every target goes through Test-PcxTarget under the plan profile
        * every item goes through Test-PcxEvidenceRef with its origin
          (seed for catalog actions, agent-discovered for proposals)
        * the inverse is derived (A1 -> manifest-only, a Startup-folder B ->
          quarantine, every other B -> snapshot) and must equal the catalog's
          inverse
        * two items on the same canonical target refuse
        * an unknown action id, a protected target, a wildcard, a missing or
          unrelated evidence ref and an unresolved token refuse

    There is no HMAC, nonce, signature or secret anywhere in the plan.
#>

Set-StrictMode -Version 2.0

$script:PcxPlanSchema = 'pcx-plan/1'
$script:PcxPlanOrigins = @('seed', 'agent-discovered')
$script:PcxPlanDocumentKeys = @('schema', 'planId', 'planHash', 'build', 'profile', 'items', 'demoted')

# ---------------------------------------------------------------------------
# Result and refusal constructors
# ---------------------------------------------------------------------------

function New-PcxPlanRefusal {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Item
    )

    return [pscustomobject][ordered]@{
        code   = $Code
        reason = $Reason
        item   = $Item
    }
}

function New-PcxPlanResult {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Plan,
        [Parameter(Mandatory = $false)][AllowNull()][object] $PlanId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $PlanHash,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Items,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Demoted,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Refused,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Written
    )

    return [pscustomobject][ordered]@{
        plan     = $Plan
        planId   = $PlanId
        planHash = $PlanHash
        items    = @($Items)
        demoted  = @($Demoted)
        refused  = @($Refused)
        written  = $Written
    }
}

function New-PcxPlanItemFailure {
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

# ---------------------------------------------------------------------------
# Profile context and snapshot
# ---------------------------------------------------------------------------

function ConvertTo-PcxPlanBuildNumber {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Field)

    if ($null -eq $Field) {
        return $null
    }

    $status = Get-PcxPolicyMember -Object $Field -Name 'status'
    if ($null -ne $status) {
        if ([string]$status -ne 'measured') {
            return $null
        }
        $Field = Get-PcxPolicyMember -Object $Field -Name 'value'
    }

    if ($null -eq $Field) {
        return $null
    }

    try {
        return [int]$Field
    }
    catch {
        return $null
    }
}

function Get-PcxPlanProfileContext {
    <#
    .SYNOPSIS
        Normalizes -Profile (an environment fixture or a policy profile) into
        the policy profile, the token environment and the detected build.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $source = $Profile
    if ($null -eq $source) {
        $source = Get-PcxPolicyMember -Object $Scan -Name 'environment'
    }

    if ($null -eq $source) {
        return [pscustomobject]@{
            policy      = $null
            environment = [ordered]@{}
            build       = $null
        }
    }

    $sModeField = Get-PcxPolicyMember -Object $source -Name 'sMode'
    $isEnvironment = ($null -ne (Get-PcxPolicyMember -Object $sModeField -Name 'status')) -or
        ($null -ne (Get-PcxPolicyMember -Object $source -Name 'paths')) -or
        ($null -ne (Get-PcxPolicyMember -Object $source -Name 'os'))

    $policy = $null
    $environment = $null
    $build = $null

    if ($isEnvironment) {
        $policy = ConvertTo-PcxPolicyProfile -Environment $source
        $environment = Get-PcxPolicyMember -Object $source -Name 'paths'
        $build = ConvertTo-PcxPlanBuildNumber -Field (Get-PcxPolicyMember -Object (Get-PcxPolicyMember -Object $source -Name 'os') -Name 'build')
    }
    else {
        $policy = $source
        $environment = Get-PcxPolicyMember -Object $source -Name 'environment'
        $build = ConvertTo-PcxPlanBuildNumber -Field (Get-PcxPolicyMember -Object $source -Name 'build')
        if ($null -eq $build) {
            $build = ConvertTo-PcxPlanBuildNumber -Field (Get-PcxPolicyMember -Object (Get-PcxPolicyMember -Object $source -Name 'os') -Name 'build')
        }
    }

    if ($null -eq $build) {
        $scanEnvironment = Get-PcxPolicyMember -Object $Scan -Name 'environment'
        $build = ConvertTo-PcxPlanBuildNumber -Field (Get-PcxPolicyMember -Object (Get-PcxPolicyMember -Object $scanEnvironment -Name 'os') -Name 'build')
    }

    if ($null -eq $environment) {
        $environment = Get-PcxPolicyMember -Object $policy -Name 'environment'
    }

    return [pscustomobject]@{
        policy      = $policy
        environment = $environment
        build       = $build
    }
}

function New-PcxPlanPolicySnapshot {
    # A plain, JSON-safe copy of the policy facts the plan must carry so the
    # elevated child can re-run Test-PcxTarget without any live read.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Policy)

    $environment = Get-PcxPolicyMember -Object $Policy -Name 'environment'
    $environmentMap = [ordered]@{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA', 'SYSTEMROOT')) {
        $value = Get-PcxPolicyMember -Object $environment -Name $name
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
            $environmentMap[$name] = [string]$value
        }
    }

    $serviceFacts = [ordered]@{}
    $factsSource = Get-PcxPolicyMember -Object $Policy -Name 'serviceFacts'
    if ($null -ne $factsSource) {
        $names = @()
        if ($factsSource -is [System.Collections.IDictionary]) {
            $names = @($factsSource.Keys)
        }
        else {
            $names = @($factsSource.PSObject.Properties | ForEach-Object { $_.Name })
        }

        $sortedNames = @($names | ForEach-Object { [string]$_ })
        [Array]::Sort($sortedNames, [System.StringComparer]::Ordinal)

        foreach ($name in $sortedNames) {
            $facts = Get-PcxPolicyMember -Object $factsSource -Name $name
            if ($null -eq $facts) {
                continue
            }
            $serviceFacts[$name] = [ordered]@{
                dependents     = Get-PcxPolicyInteger -Object $facts -Name 'dependents'
                listeningPorts = Get-PcxPolicyInteger -Object $facts -Name 'listeningPorts'
                childProcesses = Get-PcxPolicyInteger -Object $facts -Name 'childProcesses'
            }
        }
    }

    return [ordered]@{
        managed      = Get-PcxPolicyBoolean -Object $Policy -Name 'managed'
        sMode        = Get-PcxPolicyBoolean -Object $Policy -Name 'sMode'
        devDrive     = Get-PcxPolicyBoolean -Object $Policy -Name 'devDrive'
        anticheat    = Get-PcxPolicyBoolean -Object $Policy -Name 'anticheat'
        serviceFacts = $serviceFacts
        environment  = $environmentMap
    }
}

# ---------------------------------------------------------------------------
# Target, inverse and evidence helpers
# ---------------------------------------------------------------------------

function Test-PcxPlanTargetList {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $RawTargets,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Policy
    )

    $canonical = New-Object System.Collections.Generic.List[object]

    foreach ($raw in @(ConvertTo-PcxCatalogTargetList -Target $RawTargets)) {
        if ($null -eq $raw) {
            return [pscustomobject]@{ ok = $false; code = 'PCX-E-PLAN-TARGET'; reason = 'an item contains an empty target.'; targets = @() }
        }

        foreach ($text in @(Get-PcxCatalogTargetText -Target $raw)) {
            if ($text.Contains('*') -or $text.Contains('?')) {
                return [pscustomobject]@{ ok = $false; code = 'PCX-POLICY-GRAMMAR'; reason = "target '$text' contains a wildcard."; targets = @() }
            }
        }

        $expanded = ConvertTo-PcxCatalogExpandedTarget -Target $raw -Profile $Policy
        if (-not $expanded.ok) {
            return [pscustomobject]@{ ok = $false; code = 'PCX-E-PLAN-TARGET'; reason = [string]$expanded.reason; targets = @() }
        }

        $decision = Test-PcxTarget -Target $expanded.target -Profile $Policy
        if (-not $decision.allowed) {
            return [pscustomobject]@{ ok = $false; code = [string]$decision.code; reason = [string]$decision.reason; targets = @() }
        }

        [void]$canonical.Add($decision.target)
    }

    if ($canonical.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; code = 'PCX-E-PLAN-TARGET'; reason = 'an item has no target.'; targets = @() }
    }

    return [pscustomobject]@{ ok = $true; code = $null; reason = $null; targets = $canonical.ToArray() }
}

function Get-PcxPlanTargetKey {
    param([Parameter(Mandatory = $true)][object] $Target)

    $kind = ([string](Get-PcxPolicyMember -Object $Target -Name 'kind')).Trim().ToLowerInvariant()

    switch ($kind) {
        'registry' {
            $hive = ([string](Get-PcxPolicyMember -Object $Target -Name 'hive')).ToLowerInvariant()
            $key = ([string](Get-PcxPolicyMember -Object $Target -Name 'key')).ToLowerInvariant()
            $name = ([string](Get-PcxPolicyMember -Object $Target -Name 'name')).ToLowerInvariant()
            return ('registry:{0}\{1}::{2}' -f $hive, $key, $name)
        }
        'service' {
            return ('service:{0}' -f ([string](Get-PcxPolicyMember -Object $Target -Name 'name')).ToLowerInvariant())
        }
        'task' {
            return ('task:{0}' -f ([string](Get-PcxPolicyMember -Object $Target -Name 'path')).ToLowerInvariant())
        }
        'file' {
            return ('file:{0}' -f ([string](Get-PcxPolicyMember -Object $Target -Name 'path')).ToLowerInvariant())
        }
    }

    return ([string]$Target).ToLowerInvariant()
}

function Get-PcxPlanCommonRoot {
    # Longest common directory prefix of every file target, used as the evidence
    # root. A single file resolves to itself, which is a valid root for the
    # boundary-aware containment check.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Targets)

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($target in @($Targets)) {
        if (([string](Get-PcxPolicyMember -Object $target -Name 'kind')).Trim().ToLowerInvariant() -ne 'file') {
            continue
        }
        $path = [string](Get-PcxPolicyMember -Object $target -Name 'path')
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            [void]$paths.Add($path.TrimEnd('\'))
        }
    }

    if ($paths.Count -eq 0) {
        return $null
    }

    $common = @($paths[0] -split '\\')
    for ($index = 1; $index -lt $paths.Count; $index++) {
        $segments = @($paths[$index] -split '\\')
        $limit = [Math]::Min($common.Count, $segments.Count)
        $match = 0
        while ($match -lt $limit -and [string]::Equals([string]$common[$match], [string]$segments[$match], [System.StringComparison]::OrdinalIgnoreCase)) {
            $match++
        }
        if ($match -eq 0) {
            return $null
        }
        $common = @($common[0..($match - 1)])
    }

    $root = ($common -join '\')
    if ([string]::IsNullOrWhiteSpace($root)) {
        return $null
    }

    return $root
}

function Get-PcxPlanDerivedInverse {
    param(
        [Parameter(Mandatory = $true)][string] $Category,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Targets,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Policy
    )

    $categoryText = $Category.Trim().ToUpperInvariant()

    if ($categoryText -eq 'A1') {
        return 'manifest-only'
    }

    if ($categoryText -eq 'B') {
        $environment = Get-PcxPolicyMember -Object $Policy -Name 'environment'
        $data = Get-PcxPolicyData
        $roots = @(Get-PcxPolicyMember -Object (Get-PcxPolicyMember -Object $data -Name 'files') -Name 'a2_roots')

        foreach ($target in @($Targets)) {
            if (([string](Get-PcxPolicyMember -Object $target -Name 'kind')).Trim().ToLowerInvariant() -ne 'file') {
                continue
            }

            $path = [string](Get-PcxPolicyMember -Object $target -Name 'path')
            foreach ($root in $roots) {
                if ($null -eq $root) { continue }
                $expanded = Resolve-PcxPolicyRoot -Root ([string]$root) -Environment $environment
                if ($null -eq $expanded) { continue }
                if (Test-PcxPolicyPathUnder -Path $path -Root $expanded) {
                    return 'quarantine'
                }
            }
        }

        return 'snapshot'
    }

    return $null
}

function New-PcxPlanSeedEvidence {
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan,
        [Parameter(Mandatory = $true)][object] $Targets
    )

    $rule = Get-PcxPolicyMember -Object $Action -Name 'evidence_rule'
    if ($null -eq $rule) {
        return [pscustomobject]@{ ok = $false; evidence = $null; reason = 'the action has no evidence rule.' }
    }

    $metricId = [string](Get-PcxPolicyMember -Object $rule -Name 'metric')
    if ([string]::IsNullOrWhiteSpace($metricId)) {
        return [pscustomobject]@{ ok = $false; evidence = $null; reason = 'the action evidence rule has no metric.' }
    }

    $metric = $null
    foreach ($candidate in @(Get-PcxPolicyMember -Object $Scan -Name 'metrics')) {
        if ($null -eq $candidate) { continue }
        if ([string]::Equals([string](Get-PcxPolicyMember -Object $candidate -Name 'id'), $metricId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $metric = $candidate
            break
        }
    }

    if ($null -eq $metric) {
        return [pscustomobject]@{ ok = $false; evidence = $null; reason = "the scan has no metric '$metricId'." }
    }
    if ([string](Get-PcxPolicyMember -Object $metric -Name 'status') -ne 'measured') {
        return [pscustomobject]@{ ok = $false; evidence = $null; reason = "the metric '$metricId' is not measured." }
    }

    $value = Get-PcxPolicyMember -Object $metric -Name 'value'
    if ($null -eq $value) {
        return [pscustomobject]@{ ok = $false; evidence = $null; reason = "the metric '$metricId' has no value." }
    }

    $window = [string](Get-PcxPolicyMember -Object $metric -Name 'window')
    if ([string]::IsNullOrWhiteSpace($window)) { $window = 'instant' }

    $evidence = [ordered]@{
        kind   = ([string](Get-PcxPolicyMember -Object $rule -Name 'kind')).Trim().ToLowerInvariant()
        metric = $metricId
        domain = [string](Get-PcxPolicyMember -Object $rule -Name 'domain')
        value  = $value
        status = 'measured'
        window = $window
    }

    $root = Get-PcxPlanCommonRoot -Targets $Targets
    if ($null -ne $root) {
        $evidence['root'] = $root
    }

    return [pscustomobject]@{ ok = $true; evidence = $evidence; reason = $null }
}

# ---------------------------------------------------------------------------
# One item: validate, derive inverse, dedupe, build-gate
# ---------------------------------------------------------------------------

function Test-PcxPlanItem {
    param(
        [Parameter(Mandatory = $true)][object] $Candidate,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Action,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Policy,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Build,
        [Parameter(Mandatory = $true)][hashtable] $SeenTargets,
        [Parameter(Mandatory = $true)][ValidateSet('build', 'applyable', 'demoted')][string] $Mode
    )

    $actionId = [string](Get-PcxPolicyMember -Object $Candidate -Name 'actionId')
    if ($null -eq $Action) {
        return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-ACTION' -Reason "action id '$actionId' is not in the catalog."
    }

    $origin = ([string](Get-PcxPolicyMember -Object $Candidate -Name 'origin')).Trim().ToLowerInvariant()
    if ($script:PcxPlanOrigins -notcontains $origin) {
        return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-ORIGIN' -Reason "origin '$origin' is not seed or agent-discovered."
    }

    $category = [string](Get-PcxPolicyMember -Object $Candidate -Name 'category')
    if ([string]::IsNullOrWhiteSpace($category)) {
        $category = [string](Get-PcxPolicyMember -Object $Action -Name 'category')
    }
    $category = $category.Trim().ToUpperInvariant()
    if ($category -ne 'A1' -and $category -ne 'B') {
        return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-CATEGORY' -Reason "category '$category' is not A1 or B."
    }

    $group = [string](Get-PcxPolicyMember -Object $Candidate -Name 'group')
    if ([string]::IsNullOrWhiteSpace($group)) {
        $group = [string](Get-PcxPolicyMember -Object $Action -Name 'group')
    }
    $group = $group.Trim().ToLowerInvariant()

    $userTextEn = [string](Get-PcxPolicyMember -Object $Candidate -Name 'user_text_en')
    if ([string]::IsNullOrWhiteSpace($userTextEn)) {
        $userTextEn = [string](Get-PcxPolicyMember -Object $Action -Name 'user_text_en')
    }
    $userTextRu = [string](Get-PcxPolicyMember -Object $Candidate -Name 'user_text_ru')
    if ([string]::IsNullOrWhiteSpace($userTextRu)) {
        $userTextRu = [string](Get-PcxPolicyMember -Object $Action -Name 'user_text_ru')
    }

    $targetResult = Test-PcxPlanTargetList -RawTargets (Get-PcxPolicyMember -Object $Candidate -Name 'target') -Policy $Policy
    if (-not $targetResult.ok) {
        return New-PcxPlanItemFailure -Code $targetResult.code -Reason $targetResult.reason
    }
    $targets = @($targetResult.targets)

    $evidence = Get-PcxPolicyMember -Object $Candidate -Name 'evidence'
    if ($null -eq $evidence -and $origin -eq 'seed') {
        $derivedEvidence = New-PcxPlanSeedEvidence -Action $Action -Scan $Scan -Targets $targets
        if (-not $derivedEvidence.ok) {
            return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-EVIDENCE' -Reason $derivedEvidence.reason
        }
        $evidence = $derivedEvidence.evidence
    }
    if ($null -eq $evidence) {
        return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-EVIDENCE' -Reason 'an item requires an evidence ref.'
    }

    $catalogRule = $null
    if ($origin -eq 'seed') {
        $catalogRule = $Action
    }
    foreach ($target in $targets) {
        $evidenceDecision = Test-PcxEvidenceRef -Target $target -Evidence $evidence -Origin $origin -CatalogRule $catalogRule -Profile $Policy
        if (-not $evidenceDecision.allowed) {
            return New-PcxPlanItemFailure -Code ([string]$evidenceDecision.code) -Reason ([string]$evidenceDecision.reason)
        }
    }

    $derivedInverse = Get-PcxPlanDerivedInverse -Category $category -Targets $targets -Policy $Policy
    if ([string]::IsNullOrWhiteSpace($derivedInverse)) {
        return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-INVERSE' -Reason "no inverse can be derived for category '$category'."
    }

    $catalogInverse = ([string](Get-PcxPolicyMember -Object $Action -Name 'inverse')).Trim().ToLowerInvariant()
    if ($catalogInverse -ne $derivedInverse) {
        return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-INVERSE' -Reason "the catalog inverse '$catalogInverse' disagrees with the derived inverse '$derivedInverse'."
    }

    $requestedInverse = [string](Get-PcxPolicyMember -Object $Candidate -Name 'inverse')
    if (-not [string]::IsNullOrWhiteSpace($requestedInverse) -and $requestedInverse.Trim().ToLowerInvariant() -ne $derivedInverse) {
        return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-INVERSE' -Reason "the requested inverse '$requestedInverse' disagrees with the derived inverse '$derivedInverse'."
    }

    foreach ($target in $targets) {
        $key = Get-PcxPlanTargetKey -Target $target
        if ($SeenTargets.ContainsKey($key)) {
            return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-DUPLICATE' -Reason "two items address the same canonical target '$key'."
        }
    }
    foreach ($target in $targets) {
        $SeenTargets[(Get-PcxPlanTargetKey -Target $target)] = $true
    }

    # One shared decision: the table renders selectable exactly what this
    # accepts. A missing build is already normalized into a demotion there.
    $buildDecision = Get-PcxCatalogBuildDecision -Action $Action -Build $Build

    $demotedItem = $false
    $demotedReason = $null

    if ($Mode -eq 'applyable') {
        if (-not $buildDecision.applyable) {
            return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-BUILD' -Reason ("the item is not applyable on the detected build: {0}" -f $buildDecision.reason)
        }
    }
    elseif ($Mode -eq 'demoted') {
        if ($buildDecision.applyable) {
            return New-PcxPlanItemFailure -Code 'PCX-E-PLAN-BUILD' -Reason 'the item is applyable on the detected build but was recorded as demoted.'
        }
        $demotedItem = $true
        $demotedReason = [string]$buildDecision.reason
    }
    else {
        if (-not $buildDecision.applyable) {
            $demotedItem = $true
            $demotedReason = [string]$buildDecision.reason
        }
    }

    $targetKeys = @($targets | ForEach-Object { Get-PcxPlanTargetKey -Target $_ })
    $digest = Get-PcxSha256 -Text ($actionId + '|' + ($targetKeys -join '|'))
    $itemId = $actionId + '-' + $digest.Substring(0, 8)

    $item = [ordered]@{
        id           = $itemId
        actionId     = $actionId
        row          = Get-PcxPolicyMember -Object $Candidate -Name 'row'
        origin       = $origin
        target       = $targets
        category     = $category
        group        = $group
        inverse      = $derivedInverse
        evidence     = $evidence
        user_text_en = $userTextEn
        user_text_ru = $userTextRu
    }

    if ($demotedItem) {
        $demotedCopy = [ordered]@{}
        foreach ($key in $item.Keys) {
            $demotedCopy[$key] = $item[$key]
        }
        $demotedCopy['reason'] = $demotedReason
        return [pscustomobject]@{ ok = $true; item = $item; demoted = $true; demotedItem = $demotedCopy; reason = $demotedReason }
    }

    return [pscustomobject]@{ ok = $true; item = $item; demoted = $false; demotedItem = $null; reason = $null }
}

# ---------------------------------------------------------------------------
# Candidates: table rows and proposals
# ---------------------------------------------------------------------------

function Get-PcxPlanActionById {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Catalog,
        [Parameter(Mandatory = $true)][string] $Id
    )

    foreach ($action in @(Get-PcxPolicyMember -Object $Catalog -Name 'actions')) {
        if ($null -eq $action) { continue }
        if ([string]::Equals([string](Get-PcxPolicyMember -Object $action -Name 'id'), $Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $action
        }
    }

    return $null
}

function ConvertTo-PcxPlanSelection {
    param([Parameter(Mandatory = $false)][AllowNull()][string] $Selection)

    if ([string]::IsNullOrWhiteSpace($Selection)) {
        return [pscustomobject]@{ ok = $false; reason = 'a selection is required.'; numbers = @() }
    }

    $numbers = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Selection -split ',')) {
        $text = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $number = 0
        if (-not [int]::TryParse($text, [ref]$number)) {
            return [pscustomobject]@{ ok = $false; reason = "selection token '$text' is not a row number."; numbers = @() }
        }
        if ($number -le 0) {
            return [pscustomobject]@{ ok = $false; reason = "row number '$number' must be positive."; numbers = @() }
        }
        [void]$numbers.Add($number)
    }

    if ($numbers.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; reason = 'a selection is required.'; numbers = @() }
    }

    return [pscustomobject]@{ ok = $true; reason = $null; numbers = $numbers.ToArray() }
}

function Get-PcxPlanRows {
    param(
        [Parameter(Mandatory = $true)][object] $Scan,
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $rendered = Invoke-PcxTable -Scan $Scan -Catalog $Catalog -Profile $Profile
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($group in $rendered.groups.Values) {
        foreach ($row in $group.rows) {
            [void]$rows.Add($row)
        }
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Plan document hash
# ---------------------------------------------------------------------------

function New-PcxPlanDocument {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Build,
        [Parameter(Mandatory = $true)][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Items,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Demoted
    )

    $body = [ordered]@{
        schema  = $script:PcxPlanSchema
        build   = $Build
        profile = $Profile
        items   = @($Items)
        demoted = @($Demoted)
    }

    $planHash = Get-PcxSha256 -Text (ConvertTo-PcxCanonicalJson -InputObject $body)
    $planId = $planHash.Substring(0, 16)

    $plan = [ordered]@{
        schema   = $script:PcxPlanSchema
        planId   = $planId
        planHash = $planHash
        build    = $Build
        profile  = $Profile
        items    = @($Items)
        demoted  = @($Demoted)
    }

    return [pscustomobject]@{ plan = $plan; planId = $planId; planHash = $planHash }
}

# ---------------------------------------------------------------------------
# Public: build a plan
# ---------------------------------------------------------------------------

function Invoke-PcxPlan {
    <#
    .SYNOPSIS
        Builds and validates one plan from a row selection or a proposal list.

    .DESCRIPTION
        Returns @{ plan; planId; planHash; items; demoted; refused; written }.
        Any refusal leaves plan/planId/planHash null and writes nothing.
        -DryRun writes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string] $Selection,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Scan,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyCollection()][object[]] $Proposals,
        [Parameter(Mandatory = $false)][switch] $DryRun
    )

    $hasSelection = -not [string]::IsNullOrWhiteSpace($Selection)
    $hasProposals = ($null -ne $Proposals -and @($Proposals).Count -gt 0)

    if ($hasSelection -and $hasProposals) {
        return New-PcxPlanResult -Refused @(New-PcxPlanRefusal -Code 'PCX-E-PLAN-SELECTION' -Reason 'provide either -Selection or -Proposals, not both.') -Written $false
    }
    if (-not $hasSelection -and -not $hasProposals) {
        return New-PcxPlanResult -Refused @(New-PcxPlanRefusal -Code 'PCX-E-PLAN-SELECTION' -Reason 'a selection or a proposal list is required.') -Written $false
    }

    try {
        $catalog = Get-PcxCatalog
    }
    catch {
        return New-PcxPlanResult -Refused @(New-PcxPlanRefusal -Code 'PCX-E-PLAN-CATALOG' -Reason ("the catalog could not be loaded: {0}" -f $_.Exception.Message)) -Written $false
    }

    $context = Get-PcxPlanProfileContext -Profile $Profile -Scan $Scan
    $policySnapshot = New-PcxPlanPolicySnapshot -Policy $context.policy

    $candidates = New-Object System.Collections.Generic.List[object]
    $refused = New-Object System.Collections.Generic.List[object]

    if ($hasProposals) {
        foreach ($proposal in @($Proposals)) {
            if ($null -eq $proposal) {
                [void]$refused.Add((New-PcxPlanRefusal -Code 'PCX-E-PLAN-SHAPE' -Reason 'the proposal list contains an empty entry.'))
                continue
            }

            $actionId = [string](Get-PcxPolicyMember -Object $proposal -Name 'actionId')
            if ([string]::IsNullOrWhiteSpace($actionId)) {
                $actionId = [string](Get-PcxPolicyMember -Object $proposal -Name 'id')
            }

            $action = Get-PcxPlanActionById -Catalog $catalog -Id $actionId
            if ($null -eq $action) {
                [void]$refused.Add((New-PcxPlanRefusal -Code 'PCX-E-PLAN-ACTION' -Reason "action id '$actionId' is not in the catalog."))
                continue
            }

            [void]$candidates.Add([pscustomobject]@{
                actionId     = $actionId
                row          = Get-PcxPolicyMember -Object $proposal -Name 'row'
                origin       = 'agent-discovered'
                target       = Get-PcxPolicyMember -Object $proposal -Name 'target'
                evidence     = Get-PcxPolicyMember -Object $proposal -Name 'evidence'
                category     = Get-PcxPolicyMember -Object $proposal -Name 'category'
                group        = Get-PcxPolicyMember -Object $proposal -Name 'group'
                inverse      = Get-PcxPolicyMember -Object $proposal -Name 'inverse'
                user_text_en = Get-PcxPolicyMember -Object $proposal -Name 'user_text_en'
                user_text_ru = Get-PcxPolicyMember -Object $proposal -Name 'user_text_ru'
                action       = $action
            })
        }
    }
    else {
        $parsed = ConvertTo-PcxPlanSelection -Selection $Selection
        if (-not $parsed.ok) {
            return New-PcxPlanResult -Refused @(New-PcxPlanRefusal -Code 'PCX-E-PLAN-SELECTION' -Reason $parsed.reason) -Written $false
        }

        $rows = @(Get-PcxPlanRows -Scan $Scan -Catalog $catalog -Profile $Profile)
        $rowByNumber = @{}
        foreach ($row in $rows) {
            $rowByNumber[[int]$row.number] = $row
        }

        foreach ($number in @($parsed.numbers)) {
            if (-not $rowByNumber.ContainsKey($number)) {
                [void]$refused.Add((New-PcxPlanRefusal -Code 'PCX-E-PLAN-ROW' -Reason "row $number is not in the tune table."))
                continue
            }

            $row = $rowByNumber[$number]
            if ([string]$row.source -ne 'catalog') {
                [void]$refused.Add((New-PcxPlanRefusal -Code 'PCX-E-PLAN-NOT-APPLYABLE' -Reason "row $number is '$($row.source)', not an applyable catalog action."))
                continue
            }

            $actionId = [string]$row.id
            $action = Get-PcxPlanActionById -Catalog $catalog -Id $actionId
            if ($null -eq $action) {
                [void]$refused.Add((New-PcxPlanRefusal -Code 'PCX-E-PLAN-ACTION' -Reason "row $number names action '$actionId', which is not in the catalog."))
                continue
            }

            [void]$candidates.Add([pscustomobject]@{
                actionId     = $actionId
                row          = [int]$number
                origin       = 'seed'
                target       = Get-PcxPolicyMember -Object $action -Name 'target'
                evidence     = $null
                category     = Get-PcxPolicyMember -Object $action -Name 'category'
                group        = Get-PcxPolicyMember -Object $action -Name 'group'
                inverse      = $null
                user_text_en = Get-PcxPolicyMember -Object $action -Name 'user_text_en'
                user_text_ru = Get-PcxPolicyMember -Object $action -Name 'user_text_ru'
                action       = $action
            })
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $demoted = New-Object System.Collections.Generic.List[object]
    $seenTargets = @{}

    foreach ($candidate in $candidates) {
        $result = Test-PcxPlanItem -Candidate $candidate -Action $candidate.action -Policy $context.policy -Scan $Scan -Build $context.build -SeenTargets $seenTargets -Mode 'build'

        if (-not $result.ok) {
            [void]$refused.Add((New-PcxPlanRefusal -Code $result.code -Reason $result.reason -Item $candidate.actionId))
            continue
        }

        if ($result.demoted) {
            [void]$demoted.Add($result.demotedItem)
        }
        else {
            [void]$items.Add($result.item)
        }
    }

    if ($refused.Count -gt 0) {
        return New-PcxPlanResult -Refused $refused.ToArray() -Written $false
    }

    $document = New-PcxPlanDocument -Build $context.build -Profile $policySnapshot -Items $items.ToArray() -Demoted $demoted.ToArray()

    $written = $false
    if (-not $DryRun) {
        try {
            $planPath = Get-PcxStatePath -Kind 'journal' -ChildPath ('plan-' + $document.planId + '.json')
            $null = Write-PcxJsonAtomic -Path $planPath -InputObject $document.plan
            $written = $planPath
        }
        catch {
            return New-PcxPlanResult -Refused @(New-PcxPlanRefusal -Code 'PCX-E-PLAN-WRITE' -Reason ("the plan could not be written: {0}" -f $_.Exception.Message)) -Written $false
        }
    }

    return New-PcxPlanResult -Plan $document.plan -PlanId $document.planId -PlanHash $document.planHash -Items $items.ToArray() -Demoted $demoted.ToArray() -Refused @() -Written $written
}

# ---------------------------------------------------------------------------
# Public: the elevated child re-validates the received bytes
# ---------------------------------------------------------------------------

function Test-PcxPlan {
    <#
    .SYNOPSIS
        Decodes plan bytes, recomputes the canonical hash and re-runs every rule.

    .DESCRIPTION
        Never trusts the caller's hash: the embedded planHash is compared with a
        hash recomputed from the decoded body, and the full validation runs
        again (grammar, policy, evidence, inverse, dedupe, build gate). Returns
        @{ ok; code; reason; plan; planId; planHash; items; demoted }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][byte[]] $PlanBytes
    )

    function New-PcxPlanValidationFailure {
        param([string] $Code, [string] $Reason)

        return [pscustomobject][ordered]@{
            ok       = $false
            code     = $Code
            reason   = $Reason
            plan     = $null
            planId   = $null
            planHash = $null
            items    = @()
            demoted  = @()
        }
    }

    if ($null -eq $PlanBytes -or $PlanBytes.Length -eq 0) {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'plan bytes are empty.'
    }

    try {
        $text = [System.Text.Encoding]::UTF8.GetString($PlanBytes)
    }
    catch {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'plan bytes are not valid UTF-8.'
    }

    $plan = $null
    try {
        $plan = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason ("the plan is not valid JSON: {0}" -f $_.Exception.Message)
    }

    if ($null -eq $plan -or $plan -is [string] -or $plan -is [System.ValueType]) {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'the plan must be a JSON object.'
    }

    $names = @($plan.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $names) {
        if ($script:PcxPlanDocumentKeys -notcontains $name) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason "the plan carries an unknown field '$name'."
        }
    }
    foreach ($required in $script:PcxPlanDocumentKeys) {
        if ($names -notcontains $required) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason "the plan is missing '$required'."
        }
    }

    $schema = [string](Get-PcxPolicyMember -Object $plan -Name 'schema')
    if ($schema -ne $script:PcxPlanSchema) {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason "the plan schema must be '$($script:PcxPlanSchema)' (found '$schema')."
    }

    $planHash = [string](Get-PcxPolicyMember -Object $plan -Name 'planHash')
    $planId = [string](Get-PcxPolicyMember -Object $plan -Name 'planId')
    if ([string]::IsNullOrWhiteSpace($planHash) -or [string]::IsNullOrWhiteSpace($planId)) {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'the plan must carry planId and planHash.'
    }

    $body = [ordered]@{
        schema  = Get-PcxPolicyMember -Object $plan -Name 'schema'
        build   = Get-PcxPolicyMember -Object $plan -Name 'build'
        profile = Get-PcxPolicyMember -Object $plan -Name 'profile'
        items   = @(Get-PcxPolicyMember -Object $plan -Name 'items')
        demoted = @(Get-PcxPolicyMember -Object $plan -Name 'demoted')
    }

    $recomputedHash = Get-PcxSha256 -Text (ConvertTo-PcxCanonicalJson -InputObject $body)
    if (-not [string]::Equals($recomputedHash, $planHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-MISMATCH' -Reason 'the plan bytes do not match the embedded planHash.'
    }

    $recomputedId = $recomputedHash.Substring(0, 16)
    if (-not [string]::Equals($recomputedId, $planId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-MISMATCH' -Reason 'the plan planId is not derived from planHash.'
    }

    try {
        $catalog = Get-PcxCatalog
    }
    catch {
        return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-CATALOG' -Reason ("the catalog could not be loaded: {0}" -f $_.Exception.Message)
    }

    $policy = Get-PcxPolicyMember -Object $plan -Name 'profile'
    $build = ConvertTo-PcxPlanBuildNumber -Field (Get-PcxPolicyMember -Object $plan -Name 'build')
    $seenTargets = @{}

    $validatedItems = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-PcxPolicyMember -Object $plan -Name 'items')) {
        if ($null -eq $item) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'the plan contains an empty item.'
        }

        $actionId = [string](Get-PcxPolicyMember -Object $item -Name 'actionId')
        $action = Get-PcxPlanActionById -Catalog $catalog -Id $actionId
        if ($null -eq $action) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-ACTION' -Reason "item action id '$actionId' is not in the catalog."
        }

        $result = Test-PcxPlanItem -Candidate $item -Action $action -Policy $policy -Scan $null -Build $build -SeenTargets $seenTargets -Mode 'applyable'
        if (-not $result.ok) {
            return New-PcxPlanValidationFailure -Code $result.code -Reason $result.reason
        }
        if (-not [string]::Equals([string]$result.item.id, [string](Get-PcxPolicyMember -Object $item -Name 'id'), [System.StringComparison]::Ordinal)) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'an item id does not match its action and targets.'
        }

        [void]$validatedItems.Add($result.item)
    }

    $validatedDemoted = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-PcxPolicyMember -Object $plan -Name 'demoted')) {
        if ($null -eq $item) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'the plan contains an empty demoted entry.'
        }

        $actionId = [string](Get-PcxPolicyMember -Object $item -Name 'actionId')
        $action = Get-PcxPlanActionById -Catalog $catalog -Id $actionId
        if ($null -eq $action) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-ACTION' -Reason "demoted action id '$actionId' is not in the catalog."
        }

        $result = Test-PcxPlanItem -Candidate $item -Action $action -Policy $policy -Scan $null -Build $build -SeenTargets $seenTargets -Mode 'demoted'
        if (-not $result.ok) {
            return New-PcxPlanValidationFailure -Code $result.code -Reason $result.reason
        }
        if (-not [string]::Equals([string]$result.item.id, [string](Get-PcxPolicyMember -Object $item -Name 'id'), [System.StringComparison]::Ordinal)) {
            return New-PcxPlanValidationFailure -Code 'PCX-E-PLAN-SHAPE' -Reason 'a demoted item id does not match its action and targets.'
        }

        [void]$validatedDemoted.Add($result.demotedItem)
    }

    return [pscustomobject][ordered]@{
        ok       = $true
        code     = 'PCX-E-PLAN-ALLOW'
        reason   = 'the plan bytes re-validate against the canonical hash and every rule.'
        plan     = $plan
        planId   = $planId
        planHash = $recomputedHash
        items    = $validatedItems.ToArray()
        demoted  = $validatedDemoted.ToArray()
    }
}
