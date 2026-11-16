<#
.SYNOPSIS
    Seed catalog loader and validator for the pcx action catalog.

.DESCRIPTION
    The catalog is bundled data (config/actions/*.json) plus one validator.
    It is knowledge and an evidence template: it never decides whether a write
    is allowed. Test-PcxTarget stays the only boundary, so every target in the
    catalog is fed back through that gate with a permissive desktop profile.

    Public surface contributed to the Pcx module (exactly these two names):
        Get-PcxCatalog          loads all action files, validates, throws PCX-CATALOG
        Test-PcxCatalogAction   decides whether an action is applyable on a build

    Internal (not exported):
        Get-PcxBuildSupport         classifies a build as win10 / win11 / unsupported
        Get-PcxCatalogBuildDecision normalizes a missing build into a demotion so
                                    the table and the plan share one decision

    Action shape (all required):
        id, findingId, target, category (A1|B), evidence_rule (@{kind;metric;domain;predicate?}),
        verified_on_build (26100 / 26200), inverse (snapshot|manifest-only|quarantine),
        group (safe|performance|behavior), user_text_ru, user_text_en

    Catalog rules enforced here:
        * exactly 13 applyable actions: 4 A1 + 9 B, no category C anywhere
        * every action carries an evidence rule, an inverse and a findingId
        * the findingId names a fixed Diagnostics finding id that admits a
          non-good severity (critical, warn or info); invented ids refuse
        * every action id is inside the pinned allow-list; ids are unique
        * no wildcard in any target
        * every target is allowed by Test-PcxTarget under a permissive profile
        * U4 actions cite positive usage evidence from the intent collector
        * performance actions say "effect not promised"; no FPS percentage
        * HAGS is a performance action that requires the current state off and
          explains the DLSS Frame Generation requirement
        * manual entries are display-only: they carry no target and no inverse,
          and a printed manual entry names a concrete file measure target
#>

Set-StrictMode -Version 2.0

$script:PcxCatalogSchema = 'pcx-actions/1'
$script:PcxCatalogManualSchema = 'pcx-manual/1'
$script:PcxCatalogActionFiles = @('cleanup.json', 'behavior.json', 'performance.json')
$script:PcxCatalogManualFile = 'manual.json'
$script:PcxCatalogRequiredApplyable = 13

$script:PcxCatalogAllowedIds = @(
    'thumbnails'
    'icon-cache'
    'delivery-optimization-cache'
    'windows-update-download-cache'
    'diagtrack-u4'
    'startup-task-u4'
    'startup-shortcut-u4'
    'spooler-no-printers'
    'game-dvr'
    'hags'
    'tips'
    'advertising-id'
    'search-web'
)

$script:PcxCatalogManualIds = @(
    'windows-old'
    'wer'
    'temp'
    'hiberfil'
    'vbs'
    'anticheat'
    'vbs-hvci'
    'defender-exclusions'
)

$script:PcxCatalogManualKinds = @{
    'windows-old'        = 'manual'
    'wer'                = 'manual'
    'temp'               = 'manual'
    'hiberfil'           = 'manual'
    'vbs'                = 'dont-touch'
    'anticheat'          = 'dont-touch'
    'vbs-hvci'           = 'dont-touch'
    'defender-exclusions' = 'dont-touch'
}

# Fixed Diagnostics finding ids that admit a non-good severity (critical,
# warn or info) and may therefore back an applyable action. Verified against
# src/pcx/Diagnostics/*Diagnostics.ps1: standby-list (good-only) and
# gpu-temp (unavailable-only) admit no remedy and are excluded, as are the
# synthetic *-unavailable fallbacks. Runtime severity is decided again by
# Test-PcxFindingGroupMap with live findings; this pin only refuses
# invented or remedy-less ids at catalog load.
$script:PcxCatalogProvenanceFindingIds = @(
    'os-build-support'
    'uptime'
    'bios-age'
    'gpu-driver-age'
    'cpu-mem-summary'
    'pagefile-state'
    'power-plan'
    'fast-startup'
    'system-free-space'
    'volume-health'
    'top-space-consumers'
    'ram-usage'
    'pagefile-pressure'
    'process-count'
    'top-ram-processes'
    'startup-entries'
    'scheduled-task-count'
    'auto-services'
    'third-party-services'
    'failed-services'
    'hags'
    'game-dvr'
    'overlay-processes'
    'vbs-hvci'
    'monitor-count'
    'resolution-layout'
    'audio-endpoints'
    'adapter-link-speed'
    'dns-servers'
    'nagle'
    'tcp-autotuning'
    'windows-update-age'
    'restore-points'
    'pending-reboot'
    'driver-age'
    'problem-devices'
    'defender-state'
    'firewall-state'
    'bitlocker-state'
    'tpm-state'
    'defender-exclusions'
    'cpu-temp'
)

$script:PcxCatalogVerifiedBuilds = @(26100, 26200)
$script:PcxCatalogInverseValues = @('snapshot', 'manifest-only', 'quarantine')
$script:PcxCatalogGroups = @('safe', 'performance', 'behavior')

# ---------------------------------------------------------------------------
# Paths and shape helpers
# ---------------------------------------------------------------------------

function Get-PcxCatalogRoot {
    $candidate = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'config', 'actions')
    return [System.IO.Path]::GetFullPath($candidate)
}

function Add-PcxCatalogError {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Errors,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message
    )

    [void]$Errors.Add("PCX-CATALOG-$Code`: $Message")
}

function ConvertTo-PcxCatalogTargetList {
    # A target may be one typed target or an array of typed targets (one A1
    # cache family spans several concrete files). Strings, dictionaries and
    # custom objects are single targets; other enumerables are lists.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    if ($null -eq $Target) { return @() }
    if ($Target -is [string]) { return @($Target) }
    if ($Target -is [System.Collections.IDictionary]) { return @($Target) }
    if ($Target -is [System.Management.Automation.PSCustomObject]) { return @($Target) }
    if ($Target -is [System.Collections.IEnumerable]) { return @($Target) }

    return @($Target)
}

function Get-PcxCatalogTargetText {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    if ($null -eq $Target) { return @() }
    if ($Target -is [string]) { return @([string]$Target) }

    $texts = New-Object System.Collections.ArrayList
    if ($Target -is [System.Collections.IDictionary]) {
        foreach ($key in $Target.Keys) {
            if ($key -is [string]) {
                $value = $Target[$key]
                if ($value -is [string]) { [void]$texts.Add($value) }
            }
        }
        return @($texts)
    }

    foreach ($property in $Target.PSObject.Properties) {
        if ($property.Value -is [string]) { [void]$texts.Add($property.Value) }
    }

    return @($texts)
}

function Get-PcxCatalogTargetKind {
    param([Parameter(Mandatory = $true)][object] $Target)

    if ($Target -is [string]) {
        if ($Target -match '^(?i)file:') { return 'file' }
        if ($Target -match '^(?i)svc:') { return 'service' }
        if ($Target -match '^(?i)task:') { return 'task' }
        return 'registry'
    }

    $kind = [string](Get-PcxPolicyMember -Object $Target -Name 'Kind')
    if ([string]::IsNullOrWhiteSpace($kind)) { return '' }
    return $kind.Trim().ToLowerInvariant()
}

function Get-PcxCatalogServiceName {
    param([Parameter(Mandatory = $true)][object] $Target)

    if ($Target -is [string]) {
        if ($Target -match '^(?i)svc:(.+)$') { return $Matches[1].Trim().ToLowerInvariant() }
        return ''
    }

    return ([string](Get-PcxPolicyMember -Object $Target -Name 'Name')).Trim().ToLowerInvariant()
}

function New-PcxCatalogProfile {
    # Permissive desktop profile: only bounds the *catalog*, never a real
    # machine. Service facts are zeroed for every service the catalog names so
    # the blast-radius rule can be exercised without inventing dependents.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Actions)

    $serviceFacts = @{}
    foreach ($action in @($Actions)) {
        if ($null -eq $action) { continue }
        foreach ($target in @(ConvertTo-PcxCatalogTargetList -Target (Get-PcxPolicyMember -Object $action -Name 'target'))) {
            if ((Get-PcxCatalogTargetKind -Target $target) -ne 'service') { continue }
            $name = Get-PcxCatalogServiceName -Target $target
            if (-not [string]::IsNullOrWhiteSpace($name) -and -not $serviceFacts.ContainsKey($name)) {
                $serviceFacts[$name] = @{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
            }
        }
    }

    return [pscustomobject][ordered]@{
        managed      = $false
        sMode        = $false
        devDrive     = $false
        anticheat    = $false
        serviceFacts = $serviceFacts
        environment  = [ordered]@{
            LOCALAPPDATA = 'C:\Users\pcx-catalog\AppData\Local'
            APPDATA      = 'C:\Users\pcx-catalog\AppData\Roaming'
            PROGRAMDATA  = 'C:\ProgramData'
            SYSTEMROOT   = 'C:\Windows'
        }
    }
}

function ConvertTo-PcxCatalogExpandedTarget {
    # Expands %TOKEN% placeholders for file targets using the validation
    # profile environment. Every other target is handed to Test-PcxTarget
    # untouched, so the gate still parses and decides it.
    param(
        [Parameter(Mandatory = $true)][object] $Target,
        [Parameter(Mandatory = $true)][object] $Profile
    )

    $environment = Get-PcxPolicyMember -Object $Profile -Name 'environment'

    if ($Target -is [string]) {
        if ($Target -match '^(?i)file:(?:(a1|quarantine):)?(.*)$') {
            $role = 'a1'
            if (-not [string]::IsNullOrWhiteSpace($Matches[1])) { $role = $Matches[1].ToLowerInvariant() }
            $expanded = Resolve-PcxPolicyRoot -Root $Matches[2] -Environment $environment
            if ($null -eq $expanded) {
                return [pscustomobject]@{ ok = $false; target = $null; reason = "file target '$Target' has an unresolved root or is not absolute." }
            }
            return [pscustomobject]@{
                ok     = $true
                target = [pscustomobject]@{ Kind = 'file'; Path = $expanded; Role = $role }
                reason = $null
            }
        }
        return [pscustomobject]@{ ok = $true; target = $Target; reason = $null }
    }

    if ((Get-PcxCatalogTargetKind -Target $Target) -eq 'file') {
        $rawPath = [string](Get-PcxPolicyMember -Object $Target -Name 'Path')
        $expanded = Resolve-PcxPolicyRoot -Root $rawPath -Environment $environment
        if ($null -eq $expanded) {
            return [pscustomobject]@{ ok = $false; target = $null; reason = "file target '$rawPath' has an unresolved root or is not absolute." }
        }
        $role = [string](Get-PcxPolicyMember -Object $Target -Name 'Role')
        if ([string]::IsNullOrWhiteSpace($role)) { $role = 'a1' }
        $reparse = Get-PcxPolicyMember -Object $Target -Name 'Reparse'
        return [pscustomobject]@{
            ok     = $true
            target = [pscustomobject]@{ Kind = 'file'; Path = $expanded; Role = $role; Reparse = $reparse }
            reason = $null
        }
    }

    return [pscustomobject]@{ ok = $true; target = $Target; reason = $null }
}

# ---------------------------------------------------------------------------
# Rule checks
# ---------------------------------------------------------------------------

function Test-PcxCatalogEvidenceRule {
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Rule,
        [Parameter(Mandatory = $true)][object] $Errors
    )

    $id = [string](Get-PcxPolicyMember -Object $Action -Name 'id')
    if ($null -eq $Rule) {
        Add-PcxCatalogError -Errors $Errors -Code 'EVIDENCE' -Message "action '$id' has no evidence rule."
        return
    }

    $kind = ([string](Get-PcxPolicyMember -Object $Rule -Name 'kind')).Trim().ToLowerInvariant()
    $metric = [string](Get-PcxPolicyMember -Object $Rule -Name 'metric')
    $domain = [string](Get-PcxPolicyMember -Object $Rule -Name 'domain')
    $predicate = [string](Get-PcxPolicyMember -Object $Rule -Name 'predicate')

    if ($kind -ne 'telemetry' -and $kind -ne 'state') {
        Add-PcxCatalogError -Errors $Errors -Code 'EVIDENCE-KIND' -Message "action '$id' evidence kind '$kind' is not telemetry or state."
    }
    if ([string]::IsNullOrWhiteSpace($metric)) {
        Add-PcxCatalogError -Errors $Errors -Code 'EVIDENCE-METRIC' -Message "action '$id' evidence rule has no metric."
    }
    if ([string]::IsNullOrWhiteSpace($domain)) {
        Add-PcxCatalogError -Errors $Errors -Code 'EVIDENCE-DOMAIN' -Message "action '$id' evidence rule has no domain."
    }

    # U4: positive usage evidence from the intent collector, or no offer.
    if ($id -match '(?i)-u4$') {
        if (-not $metric.StartsWith('intent.', [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-PcxCatalogError -Errors $Errors -Code 'U4-EVIDENCE' -Message "U4 action '$id' must cite an intent.* usage metric, not '$metric'."
        }
        if ($predicate -notmatch '^(?i)(at-least:[1-9][0-9]*|more-than:0|greater-than:0|>0)$') {
            Add-PcxCatalogError -Errors $Errors -Code 'U4-EVIDENCE' -Message "U4 action '$id' must require positive usage (predicate '$predicate' does not)."
        }
    }
}

function Test-PcxCatalogPerformanceText {
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $true)][object] $Errors
    )

    $id = [string](Get-PcxPolicyMember -Object $Action -Name 'id')
    $group = ([string](Get-PcxPolicyMember -Object $Action -Name 'group')).Trim().ToLowerInvariant()
    if ($group -ne 'performance') { return }

    $en = [string](Get-PcxPolicyMember -Object $Action -Name 'user_text_en')
    $ru = [string](Get-PcxPolicyMember -Object $Action -Name 'user_text_ru')

    if ($en.IndexOf('effect not promised', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-PcxCatalogError -Errors $Errors -Code 'PERF-PROMISE' -Message "performance action '$id' must contain 'effect not promised' in user_text_en."
    }
    if ($ru -notmatch '\u044D\u0444\u0444\u0435\u043A\u0442\u0020\u043D\u0435\u0020\u043E\u0431\u0435\u0449\u0430\u043D') {
        Add-PcxCatalogError -Errors $Errors -Code 'PERF-PROMISE' -Message "performance action '$id' must contain the Russian 'effect not promised' phrase in user_text_ru."
    }

    # No FPS percentage anywhere in a performance action, in either text.
    foreach ($text in @($en, $ru)) {
        if ($text -match '\d+\s*%\s*(FPS|boost|\u043F\u0440\u0438\u0440\u043E\u0441\u0442)') {
            Add-PcxCatalogError -Errors $Errors -Code 'PERF-FPS' -Message "performance action '$id' states an FPS percentage ('$($Matches[0])')."
        }
        elseif ($text -match '(FPS|boost|\u043F\u0440\u0438\u0440\u043E\u0441\u0442)\s*[^0-9]{0,12}\d+\s*%') {
            Add-PcxCatalogError -Errors $Errors -Code 'PERF-FPS' -Message "performance action '$id' states an FPS percentage ('$($Matches[0])')."
        }
    }
}

function Test-PcxCatalogHags {
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $true)][object] $Errors
    )

    $id = ([string](Get-PcxPolicyMember -Object $Action -Name 'id')).Trim().ToLowerInvariant()
    if ($id -ne 'hags') { return }

    $group = ([string](Get-PcxPolicyMember -Object $Action -Name 'group')).Trim().ToLowerInvariant()
    if ($group -ne 'performance') {
        Add-PcxCatalogError -Errors $Errors -Code 'HAGS-GROUP' -Message "action 'hags' must carry group=performance."
    }

    $rule = Get-PcxPolicyMember -Object $Action -Name 'evidence_rule'
    $kind = ([string](Get-PcxPolicyMember -Object $rule -Name 'kind')).Trim().ToLowerInvariant()
    $metric = [string](Get-PcxPolicyMember -Object $rule -Name 'metric')
    $predicate = ([string](Get-PcxPolicyMember -Object $rule -Name 'predicate')).Trim().ToLowerInvariant()

    if ($kind -ne 'state') {
        Add-PcxCatalogError -Errors $Errors -Code 'HAGS-STATE' -Message "action 'hags' must use state evidence (found '$kind')."
    }
    if ($metric.IndexOf('hags', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-PcxCatalogError -Errors $Errors -Code 'HAGS-STATE' -Message "action 'hags' must read the HAGS state metric (found '$metric')."
    }
    if ($predicate -ne 'is-off' -and $predicate -ne 'equals:1') {
        Add-PcxCatalogError -Errors $Errors -Code 'HAGS-STATE' -Message "action 'hags' must require the current state to be off (predicate '$predicate' does not)."
    }

    $en = [string](Get-PcxPolicyMember -Object $Action -Name 'user_text_en')
    $ru = [string](Get-PcxPolicyMember -Object $Action -Name 'user_text_ru')
    if ($en.IndexOf('DLSS Frame Generation', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-PcxCatalogError -Errors $Errors -Code 'HAGS-DLSS' -Message "action 'hags' must explain the DLSS Frame Generation requirement in user_text_en."
    }
    if ($ru.IndexOf('DLSS Frame Generation', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-PcxCatalogError -Errors $Errors -Code 'HAGS-DLSS' -Message "action 'hags' must explain the DLSS Frame Generation requirement in user_text_ru."
    }
}

function Test-PcxCatalogTargets {
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $true)][object] $Profile,
        [Parameter(Mandatory = $true)][object] $Errors
    )

    $id = [string](Get-PcxPolicyMember -Object $Action -Name 'id')
    $targets = @(ConvertTo-PcxCatalogTargetList -Target (Get-PcxPolicyMember -Object $Action -Name 'target'))
    if ($targets.Count -eq 0) {
        Add-PcxCatalogError -Errors $Errors -Code 'TARGET' -Message "action '$id' has no target."
        return
    }

    foreach ($target in $targets) {
        if ($null -eq $target) {
            Add-PcxCatalogError -Errors $Errors -Code 'TARGET' -Message "action '$id' contains an empty target."
            continue
        }

        foreach ($text in (Get-PcxCatalogTargetText -Target $target)) {
            if ($text.Contains('*') -or $text.Contains('?')) {
                Add-PcxCatalogError -Errors $Errors -Code 'WILDCARD' -Message "action '$id' target '$text' contains a wildcard."
            }
        }

        $expanded = ConvertTo-PcxCatalogExpandedTarget -Target $target -Profile $Profile
        if (-not $expanded.ok) {
            Add-PcxCatalogError -Errors $Errors -Code 'TARGET' -Message "action '$id' $($expanded.reason)"
            continue
        }

        $decision = Test-PcxTarget -Target $expanded.target -Profile $Profile
        if (-not $decision.allowed) {
            Add-PcxCatalogError -Errors $Errors -Code 'TARGET-DENIED' -Message "action '$id' target is denied by Test-PcxTarget ($($decision.code): $($decision.reason))."
        }
    }
}

# ---------------------------------------------------------------------------
# Document validator
# ---------------------------------------------------------------------------

function Test-PcxCatalogManualMeasure {
    <#
    .SYNOPSIS
        Validates the read-only measure block of a manual entry.

    .DESCRIPTION
        A printed manual row must be measurable on this machine: it carries one
        or more concrete file targets, never a wildcard, and the table hides it
        when nothing exists. A dont-touch entry is knowledge only and carries
        no measure block at all.
    #>
    param(
        [Parameter(Mandatory = $true)][object] $Entry,
        [Parameter(Mandatory = $true)][object] $Profile,
        [Parameter(Mandatory = $true)][object] $Errors
    )

    $id = ([string](Get-PcxPolicyMember -Object $Entry -Name 'id')).Trim().ToLowerInvariant()
    $kind = ([string](Get-PcxPolicyMember -Object $Entry -Name 'kind')).Trim().ToLowerInvariant()
    $measure = Get-PcxPolicyMember -Object $Entry -Name 'measure'

    if ($kind -eq 'dont-touch') {
        if ($null -ne $measure) {
            Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "dont-touch entry '$id' carries a measure block; it is knowledge only."
        }
        return
    }

    if ($null -eq $measure) {
        Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "manual entry '$id' has no measure block; an unmeasurable row is never printed."
        return
    }

    $targets = @(ConvertTo-PcxCatalogTargetList -Target $measure)
    if ($targets.Count -eq 0) {
        Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "manual entry '$id' has an empty measure block."
        return
    }

    foreach ($target in $targets) {
        if ($null -eq $target) {
            Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "manual entry '$id' has an empty measure target."
            continue
        }
        if ((Get-PcxCatalogTargetKind -Target $target) -ne 'file') {
            Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "manual entry '$id' measure target must be a file target."
            continue
        }

        foreach ($text in (Get-PcxCatalogTargetText -Target $target)) {
            if ($text.Contains('*') -or $text.Contains('?')) {
                Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "manual entry '$id' measure target '$text' contains a wildcard."
            }
        }

        $expanded = ConvertTo-PcxCatalogExpandedTarget -Target $target -Profile $Profile
        if (-not $expanded.ok) {
            Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "manual entry '$id' $($expanded.reason)"
        }
    }

    foreach ($field in @('outcome_ru', 'outcome_en')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-PcxPolicyMember -Object $Entry -Name $field))) {
            Add-PcxCatalogError -Errors $Errors -Code 'MANUAL-MEASURE' -Message "manual entry '$id' has no '$field'; every printed row states its effect and rollback."
        }
    }
}

function Test-PcxCatalogDocument {
    <#
    .SYNOPSIS
        Validates one catalog document set. Returns @{ valid; errors; ... }.
        Get-PcxCatalog throws on invalid output; tests can call this directly
        to prove that a malformed action is rejected.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Actions,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Manual
    )

    $errors = New-Object System.Collections.ArrayList
    $actionList = @($Actions)
    $manualList = @($Manual)
    $profile = New-PcxCatalogProfile -Actions $actionList

    $seenIds = @{}
    $a1Count = 0
    $bCount = 0
    $groupCounts = [ordered]@{ safe = 0; performance = 0; behavior = 0 }

    foreach ($action in $actionList) {
        if ($null -eq $action) {
            Add-PcxCatalogError -Errors $errors -Code 'ACTION' -Message 'the action set contains an empty entry.'
            continue
        }

        $id = [string](Get-PcxPolicyMember -Object $action -Name 'id')
        if ([string]::IsNullOrWhiteSpace($id)) {
            Add-PcxCatalogError -Errors $errors -Code 'ID' -Message 'an action has no id.'
        }
        else {
            if ($seenIds.ContainsKey($id.ToLowerInvariant())) {
                Add-PcxCatalogError -Errors $errors -Code 'DUPLICATE' -Message "action id '$id' appears more than once."
            }
            else {
                $seenIds[$id.ToLowerInvariant()] = $true
            }
            if ($script:PcxCatalogAllowedIds -notcontains $id.ToLowerInvariant()) {
                Add-PcxCatalogError -Errors $errors -Code 'ID-ALLOW-LIST' -Message "action id '$id' is outside the catalog allow-list."
            }
        }

        foreach ($field in @('target', 'category', 'evidence_rule', 'verified_on_build', 'inverse', 'group', 'user_text_ru', 'user_text_en')) {
            if ($null -eq (Get-PcxPolicyMember -Object $action -Name $field)) {
                Add-PcxCatalogError -Errors $errors -Code 'SHAPE' -Message "action '$id' is missing '$field'."
            }
        }

        $findingId = ([string](Get-PcxPolicyMember -Object $action -Name 'findingId')).Trim()
        if ([string]::IsNullOrWhiteSpace($findingId)) {
            Add-PcxCatalogError -Errors $errors -Code 'FINDING-ID' -Message "action '$id' has no findingId; every applyable action must cite its provenance finding."
        }
        elseif ($script:PcxCatalogProvenanceFindingIds -notcontains $findingId.ToLowerInvariant()) {
            Add-PcxCatalogError -Errors $errors -Code 'FINDING-ID' -Message "action '$id' findingId '$findingId' is not a known non-good Diagnostics finding id."
        }

        $category = ([string](Get-PcxPolicyMember -Object $action -Name 'category')).Trim()
        if ($category -eq 'A1') { $a1Count++ }
        elseif ($category -eq 'B') { $bCount++ }
        else {
            Add-PcxCatalogError -Errors $errors -Code 'CATEGORY' -Message "action '$id' has category '$category'; only A1 and B exist and no category C is allowed."
        }

        $group = ([string](Get-PcxPolicyMember -Object $action -Name 'group')).Trim().ToLowerInvariant()
        if ($script:PcxCatalogGroups -notcontains $group) {
            Add-PcxCatalogError -Errors $errors -Code 'GROUP' -Message "action '$id' has group '$group'; expected safe, performance or behavior."
        }
        else {
            $groupCounts[$group] = [int]$groupCounts[$group] + 1
        }

        $inverse = ([string](Get-PcxPolicyMember -Object $action -Name 'inverse')).Trim().ToLowerInvariant()
        if ($script:PcxCatalogInverseValues -notcontains $inverse) {
            Add-PcxCatalogError -Errors $errors -Code 'INVERSE' -Message "action '$id' has inverse '$inverse'; expected snapshot, manifest-only or quarantine."
        }
        elseif ($category -eq 'A1' -and $inverse -ne 'manifest-only') {
            Add-PcxCatalogError -Errors $errors -Code 'INVERSE' -Message "A1 action '$id' must use inverse=manifest-only."
        }
        elseif ($category -eq 'B' -and $id -eq 'startup-shortcut-u4' -and $inverse -ne 'quarantine') {
            Add-PcxCatalogError -Errors $errors -Code 'INVERSE' -Message "startup-shortcut action '$id' must use inverse=quarantine."
        }
        elseif ($category -eq 'B' -and $id -ne 'startup-shortcut-u4' -and $inverse -ne 'snapshot') {
            Add-PcxCatalogError -Errors $errors -Code 'INVERSE' -Message "B action '$id' must use inverse=snapshot."
        }

        $builds = @(Get-PcxPolicyMember -Object $action -Name 'verified_on_build')
        if ($builds.Count -eq 0) {
            Add-PcxCatalogError -Errors $errors -Code 'BUILD' -Message "action '$id' has no verified_on_build entries."
        }
        foreach ($build in $builds) {
            $buildNumber = 0
            $parsed = [int]::TryParse([string]$build, [ref]$buildNumber)
            if (-not $parsed -or $script:PcxCatalogVerifiedBuilds -notcontains $buildNumber) {
                Add-PcxCatalogError -Errors $errors -Code 'BUILD' -Message "action '$id' pins unsupported build '$build'; expected 26100 or 26200."
            }
        }

        if ([string]::IsNullOrWhiteSpace([string](Get-PcxPolicyMember -Object $action -Name 'user_text_ru'))) {
            Add-PcxCatalogError -Errors $errors -Code 'TEXT' -Message "action '$id' has no user_text_ru."
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-PcxPolicyMember -Object $action -Name 'user_text_en'))) {
            Add-PcxCatalogError -Errors $errors -Code 'TEXT' -Message "action '$id' has no user_text_en."
        }

        Test-PcxCatalogEvidenceRule -Action $action -Rule (Get-PcxPolicyMember -Object $action -Name 'evidence_rule') -Errors $errors
        Test-PcxCatalogPerformanceText -Action $action -Errors $errors
        Test-PcxCatalogHags -Action $action -Errors $errors
        Test-PcxCatalogTargets -Action $action -Profile $profile -Errors $errors
    }

    if ($actionList.Count -ne $script:PcxCatalogRequiredApplyable) {
        Add-PcxCatalogError -Errors $errors -Code 'COUNT' -Message "the catalog has $($actionList.Count) applyable actions; exactly $($script:PcxCatalogRequiredApplyable) are required."
    }
    if ($a1Count -ne 4) {
        Add-PcxCatalogError -Errors $errors -Code 'COUNT' -Message "the catalog has $a1Count A1 actions; exactly 4 are required."
    }
    if ($bCount -ne 9) {
        Add-PcxCatalogError -Errors $errors -Code 'COUNT' -Message "the catalog has $bCount B actions; exactly 9 are required."
    }

    # Manual entries: display only, never a target and never an inverse.
    $seenManual = @{}
    foreach ($entry in $manualList) {
        if ($null -eq $entry) {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL' -Message 'the manual set contains an empty entry.'
            continue
        }

        $manualId = ([string](Get-PcxPolicyMember -Object $entry -Name 'id')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($manualId)) {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL-ID' -Message 'a manual entry has no id.'
            continue
        }
        if ($seenManual.ContainsKey($manualId)) {
            Add-PcxCatalogError -Errors $errors -Code 'DUPLICATE' -Message "manual id '$manualId' appears more than once."
        }
        else {
            $seenManual[$manualId] = $true
        }
        if ($script:PcxCatalogManualIds -notcontains $manualId) {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL-ID' -Message "manual id '$manualId' is outside the manual allow-list."
        }

        $kind = ([string](Get-PcxPolicyMember -Object $entry -Name 'kind')).Trim().ToLowerInvariant()
        if ($kind -ne 'manual' -and $kind -ne 'dont-touch') {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL-KIND' -Message "manual entry '$manualId' has kind '$kind'; expected manual or dont-touch."
        }
        if ($script:PcxCatalogManualKinds.ContainsKey($manualId) -and $script:PcxCatalogManualKinds[$manualId] -ne $kind) {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL-KIND' -Message "manual entry '$manualId' must be kind '$($script:PcxCatalogManualKinds[$manualId])'."
        }

        if ($null -ne (Get-PcxPolicyMember -Object $entry -Name 'target')) {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL-TARGET' -Message "manual entry '$manualId' carries a target; manual entries are display-only."
        }
        if ($null -ne (Get-PcxPolicyMember -Object $entry -Name 'inverse')) {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL-INVERSE' -Message "manual entry '$manualId' carries an inverse; manual entries are display-only."
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-PcxPolicyMember -Object $entry -Name 'user_text_ru'))) {
            Add-PcxCatalogError -Errors $errors -Code 'TEXT' -Message "manual entry '$manualId' has no user_text_ru."
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-PcxPolicyMember -Object $entry -Name 'user_text_en'))) {
            Add-PcxCatalogError -Errors $errors -Code 'TEXT' -Message "manual entry '$manualId' has no user_text_en."
        }

        Test-PcxCatalogManualMeasure -Entry $entry -Profile $profile -Errors $errors
    }

    foreach ($manualId in $script:PcxCatalogManualIds) {
        if (-not $seenManual.ContainsKey($manualId)) {
            Add-PcxCatalogError -Errors $errors -Code 'MANUAL-MISSING' -Message "manual entry '$manualId' is missing."
        }
    }

    return [pscustomobject][ordered]@{
        valid           = ($errors.Count -eq 0)
        errors          = @($errors)
        applyableCount  = $actionList.Count
        categoryCounts  = [ordered]@{ A1 = $a1Count; B = $bCount; C = 0 }
        groupCounts     = $groupCounts
        manualCount     = $manualList.Count
    }
}

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

function Get-PcxCatalog {
    <#
    .SYNOPSIS
        Loads and validates the bundled action catalog.

    .DESCRIPTION
        Reads cleanup.json, behavior.json, performance.json and manual.json
        from -Path (default: config/actions beside the module). Throws a
        PCX-CATALOG error when any rule fails; a denied target fails the
        catalog. This is a data loader, not a policy boundary: every target
        decision still comes from Test-PcxTarget.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-PcxCatalogRoot
    }

    $root = [System.IO.Path]::GetFullPath($Path)
    $actions = New-Object System.Collections.ArrayList

    foreach ($file in $script:PcxCatalogActionFiles) {
        $document = Read-PcxJson -Path (Join-Path -Path $root -ChildPath $file)
        $fileActions = Get-PcxPolicyMember -Object $document -Name 'actions'
        if ($null -eq $fileActions) {
            throw "PCX-CATALOG-SHAPE: '$file' has no actions array."
        }
        foreach ($action in @($fileActions)) {
            if ($null -ne $action) { [void]$actions.Add($action) }
        }
    }

    $manualDocument = Read-PcxJson -Path (Join-Path -Path $root -ChildPath $script:PcxCatalogManualFile)
    $manualEntries = Get-PcxPolicyMember -Object $manualDocument -Name 'entries'
    if ($null -eq $manualEntries) {
        throw "PCX-CATALOG-SHAPE: '$($script:PcxCatalogManualFile)' has no entries array."
    }
    $manual = @($manualEntries | Where-Object { $null -ne $_ })

    $result = Test-PcxCatalogDocument -Actions @($actions) -Manual $manual
    if (-not $result.valid) {
        throw ('PCX-CATALOG: ' + ($result.errors -join ' | '))
    }

    return [pscustomobject][ordered]@{
        schema          = $script:PcxCatalogSchema
        manualSchema    = $script:PcxCatalogManualSchema
        path            = $root
        actions         = @($actions)
        manual          = $manual
        applyableCount  = $result.applyableCount
        categoryCounts  = $result.categoryCounts
        groupCounts     = $result.groupCounts
        manualCount     = $result.manualCount
    }
}

function Get-PcxBuildSupport {
    <#
    .SYNOPSIS
        Classifies a Windows build into a support family.

    .DESCRIPTION
        A support family, not a two-build pin:
            win10        build >= 19041 (Windows 10 2004+)
            win11        build >= 22000
            unsupported  anything else (for example 17763 Server 2019)

        supported is true for win10 and win11. verified is true only when the
        build is in the action's verified_on_build: that field labels where the
        effect was actually verified, it never blocks a supported build.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int] $Build,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Action
    )

    $family = 'unsupported'
    $supported = $false
    if ($Build -ge 22000) {
        $family = 'win11'
        $supported = $true
    }
    elseif ($Build -ge 19041) {
        $family = 'win10'
        $supported = $true
    }

    $verified = $false
    if ($null -ne $Action) {
        foreach ($entry in @(Get-PcxPolicyMember -Object $Action -Name 'verified_on_build')) {
            $number = 0
            if ([int]::TryParse([string]$entry, [ref]$number) -and $number -eq $Build) {
                $verified = $true
                break
            }
        }
    }

    if (-not $supported) {
        $reason = "build $Build is unsupported; Windows 10 2004+ (build 19041) or Windows 11 (build 22000) is required."
    }
    elseif ($verified) {
        $reason = "build $Build is a verified $family build."
    }
    else {
        $reason = "build $Build is a supported $family build but is not verified."
    }

    return [pscustomobject][ordered]@{
        family    = $family
        supported = $supported
        verified  = $verified
        reason    = $reason
    }
}

function Get-PcxCatalogBuildDecision {
    <#
    .SYNOPSIS
        The one build decision the table and the plan both consume.

    .DESCRIPTION
        A missing or malformed build is a demotion with a visible reason, so a
        caller can never silently treat an unknown build as applyable. Any real
        build is delegated to Test-PcxCatalogAction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Build
    )

    if ($null -eq $Build) {
        return [pscustomobject][ordered]@{
            applyable = $false
            demoted   = $true
            supported = $false
            verified  = $false
            family    = 'unsupported'
            caveat    = $null
            reason    = 'the detected build is unavailable; demoted to Manual.'
        }
    }

    $number = 0
    if (-not [int]::TryParse([string]$Build, [ref]$number)) {
        return [pscustomobject][ordered]@{
            applyable = $false
            demoted   = $true
            supported = $false
            verified  = $false
            family    = 'unsupported'
            caveat    = $null
            reason    = "the detected build '$Build' is not a number; demoted to Manual."
        }
    }

    return Test-PcxCatalogAction -Action $Action -Build $number
}

function Test-PcxCatalogAction {
    <#
    .SYNOPSIS
        Decides whether one catalog action is applyable on a specific build.

    .DESCRIPTION
        Demotion happens only for an unsupported build family. A supported but
        unverified build stays applyable and carries the honesty caveat
        "not verified on build <n>; effect not promised"; verified_on_build is
        a label, never a block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $true)][int] $Build
    )

    $support = Get-PcxBuildSupport -Build $Build -Action $Action

    if (-not $support.supported) {
        return [pscustomobject][ordered]@{
            applyable = $false
            demoted   = $true
            supported = $false
            verified  = $false
            family    = $support.family
            caveat    = $null
            reason    = "$($support.reason) Demoted to Manual."
        }
    }

    if ($support.verified) {
        return [pscustomobject][ordered]@{
            applyable = $true
            demoted   = $false
            supported = $true
            verified  = $true
            family    = $support.family
            caveat    = $null
            reason    = $support.reason
        }
    }

    return [pscustomobject][ordered]@{
        applyable = $true
        demoted   = $false
        supported = $true
        verified  = $false
        family    = $support.family
        caveat    = "not verified on build $Build; effect not promised"
        reason    = "build $Build is a supported $($support.family) build but is not verified; effect not promised."
    }
}
