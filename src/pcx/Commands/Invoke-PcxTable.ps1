<#
.SYNOPSIS
    One proposal table for `pcx tune --table`, in en or ru.

.DESCRIPTION
    Invoke-PcxTable turns a scan into one Markdown proposal table:

        # | Category | What is proposed | What you get

    Category is the risk: safe, changes behavior, risky. Rows come from the
    applyable catalog actions and from config/actions/manual.json (windows-old,
    WER, %TEMP%, hiberfil.sys). A row exists only when its target exists on
    this machine and its size is measurable: an absent folder, an empty cache
    or a missing shortcut is not printed at all. Every size row states the
    measured bytes it frees ("freeing 6.4 GB"), never "frees space"; a
    truncated directory walk states a lower bound, and an unreadable target
    states that the size needs administrator rights.

    File, task and service rows name their concrete target (OneDrive.lnk,
    DiagTrack, \Startup\Example App) so a row is an action on a named object,
    not a category. The diagnostics JSON stays in data.diagnostics for the
    agent; it is never printed here.

    Language: explicit -Language wins, then Scan.language (tune stamps it
    from --lang), then en.

    Output is Markdown only: no HTML, no ANSI escapes, no external assets.
    Every finding row keeps its what-it-does, evidence, what-stops-working and
    recommendation members on the action rows so existing plan/undo contracts
    hold.

    PowerShell 5.1 compatibility: no ??, no ternary ?:, no ?. operator.
    This file is ASCII-only: severity icons are built from code points and
    every non-English sentence resolves through the dictionary at runtime.
    Line endings are CRLF per .gitattributes.
#>

Set-StrictMode -Version 2.0

$script:PcxTableGroupOrder = @('safe', 'performance', 'behavior', 'manual', 'dont-touch')

$script:PcxTableStopsWorking = @{
    'thumbnails'                     = 'Explorer thumbnails are gone until Windows rebuilds the cache. Not restorable.'
    'icon-cache'                     = 'Explorer icons are gone until Windows rebuilds the cache. Not restorable.'
    'delivery-optimization-cache'    = 'Cached delivery content is gone; it is downloaded again when needed. Not restorable.'
    'windows-update-download-cache'  = 'Downloaded update files are gone; Windows downloads them again on the next check. Not restorable.'
    'diagtrack-u4'                   = 'DiagTrack stays disabled; diagnostics stop. The Start value is snapshotted for undo.'
    'startup-task-u4'                = 'The startup task no longer runs at sign-in. Task state is snapshotted for undo.'
    'startup-shortcut-u4'            = 'The Startup shortcut no longer runs at sign-in. It is quarantined byte for byte and restorable.'
    'spooler-no-printers'            = 'Printing stops while the spooler is disabled. The Start value is snapshotted for undo.'
    'game-dvr'                       = 'Game DVR capture stays off; clips and background recording are unavailable. Values are snapshotted.'
    'hags'                           = 'HAGS stays enabled; DLSS Frame Generation requires it. The previous value is snapshotted.'
    'tips'                           = 'Windows tips and suggestions stop appearing. The previous value is snapshotted.'
    'advertising-id'                 = 'Ad personalization is disabled. The previous value is snapshotted.'
    'search-web'                     = 'Web results no longer appear in Windows Search. The previous value is snapshotted.'
    'vbs'                            = 'Disabling VBS weakens protection; pcx never changes it.'
    'anticheat'                      = 'Changing anticheat services or files can block a protected game; pcx never modifies it.'
    'managed'                        = 'Managed devices refuse every write; pcx leaves policy alone.'
    's-mode'                         = 'S Mode restricts writes; pcx leaves the mode alone.'
    'hvci'                           = 'Disabling HVCI weakens protection; pcx never changes it.'
}

function Format-PcxTableValue {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) { return 'unavailable' }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Format-PcxTableCell {
    param([Parameter(Mandatory = $false)][AllowNull()][string] $Text)

    if ($null -eq $Text) { return '' }
    $flat = $Text -replace "`r`n", ' ' -replace "`n", ' ' -replace "`r", ' '
    return $flat.Replace('|', '\|').Trim()
}

function Get-PcxTableProfile {
    # Accepts a policy profile, an environment fixture, or nothing. Nothing
    # falls back to scan.environment; still nothing means every Test-PcxTarget
    # call fails closed and the rows are demoted to Manual.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $source = $Profile
    if ($null -eq $source) {
        $source = Get-PcxPolicyMember -Object $Scan -Name 'environment'
    }
    if ($null -eq $source) { return $null }

    $sMode = Get-PcxPolicyMember -Object $source -Name 'sMode'
    $isEnvironment = ($null -ne (Get-PcxPolicyMember -Object $sMode -Name 'status')) -or
        ($null -ne (Get-PcxPolicyMember -Object $source -Name 'paths')) -or
        ($null -ne (Get-PcxPolicyMember -Object $source -Name 'os'))

    if ($isEnvironment) {
        return ConvertTo-PcxPolicyProfile -Environment $source
    }

    return $source
}

function Get-PcxTableBuild {
    # The plan's context resolver is the single source of truth for the
    # detected build. Using it here is what keeps the table gate and the plan
    # gate from ever disagreeing about which rows are selectable.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        return (Get-PcxPlanProfileContext -Profile $Profile -Scan $Scan).build
    }
    catch {
        return $null
    }
}

function Get-PcxTableExpandedTarget {
    # File targets carry %TOKEN% roots; resolve them with the policy profile
    # environment exactly as the catalog validator does. Registry, service and
    # task targets are handed to Test-PcxTarget untouched.
    param(
        [Parameter(Mandatory = $true)][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    if ((Get-PcxCatalogTargetKind -Target $Target) -ne 'file') { return $Target }

    $environment = Get-PcxPolicyMember -Object $Profile -Name 'environment'
    $rawPath = [string](Get-PcxPolicyMember -Object $Target -Name 'Path')
    $resolved = Resolve-PcxPolicyRoot -Root $rawPath -Environment $environment
    if ($null -eq $resolved) { return $Target }

    $role = [string](Get-PcxPolicyMember -Object $Target -Name 'Role')
    if ([string]::IsNullOrWhiteSpace($role)) { $role = 'a1' }

    return [pscustomobject]@{ Kind = 'file'; Path = $resolved; Role = $role }
}

function Get-PcxTableTargetText {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $targets = @(ConvertTo-PcxCatalogTargetList -Target $Target)
    if ($targets.Count -eq 0) { return 'none' }

    $parts = New-Object System.Collections.ArrayList
    foreach ($item in $targets) {
        if ($null -eq $item) { continue }
        $kind = Get-PcxCatalogTargetKind -Target $item
        switch ($kind) {
            'registry' {
                $path = [string](Get-PcxPolicyMember -Object $item -Name 'Path')
                $name = [string](Get-PcxPolicyMember -Object $item -Name 'Name')
                [void]$parts.Add(('{0}::{1}' -f $path, $name))
            }
            'service' {
                $name = [string](Get-PcxPolicyMember -Object $item -Name 'Name')
                $start = [string](Get-PcxPolicyMember -Object $item -Name 'Start')
                [void]$parts.Add("svc:$name Start=$start")
            }
            'task' {
                $path = [string](Get-PcxPolicyMember -Object $item -Name 'Path')
                $enabled = Format-PcxTableValue (Get-PcxPolicyMember -Object $item -Name 'Enabled')
                [void]$parts.Add("task:$path enabled=$enabled")
            }
            'file' {
                $path = [string](Get-PcxPolicyMember -Object $item -Name 'Path')
                $role = [string](Get-PcxPolicyMember -Object $item -Name 'Role')
                if ([string]::IsNullOrWhiteSpace($role)) { $role = 'a1' }
                [void]$parts.Add(('{0}:{1}' -f $role, $path))
            }
            default {
                [void]$parts.Add([string]$item)
            }
        }
    }

    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join ' | ')
}

function Test-PcxTablePredicate {
    # Evaluates the catalog evidence predicate against a measured value.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Predicate
    )

    if ([string]::IsNullOrWhiteSpace($Predicate)) { return $true }

    $text = $Predicate.Trim()
    $valueText = (Format-PcxTableValue $Value).ToLowerInvariant()

    if ($text.StartsWith('equals:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $expected = $text.Substring('equals:'.Length).Trim().ToLowerInvariant()
        return ($valueText -eq $expected)
    }

    if ($text -ieq 'is-off') {
        # HwSchMode 1 = disabled, 2 = enabled; booleans and generic flags also fit.
        return @('false', '0', '1', 'off', 'disabled') -contains $valueText
    }

    if ($text -match '^(?i)at-least:(-?[0-9]+)$') {
        $threshold = [double]$Matches[1]
        $number = 0.0
        if (-not [double]::TryParse($valueText, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            return $false
        }
        return ($number -ge $threshold)
    }

    if ($text -match '^(?i)(more-than|greater-than|>):?0$') {
        $number = 0.0
        if (-not [double]::TryParse($valueText, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            return $false
        }
        return ($number -gt 0)
    }

    return $false
}

function Get-PcxTableMetricIndex {
    param([Parameter(Mandatory = $false)][AllowNull()][object[]] $Metrics)

    $index = @{}
    foreach ($metric in @($Metrics)) {
        if ($null -eq $metric) { continue }
        $id = [string](Get-PcxPolicyMember -Object $metric -Name 'id')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $key = $id.ToLowerInvariant()
        if (-not $index.ContainsKey($key)) {
            $index[$key] = $metric
        }
    }
    return $index
}

function Get-PcxTableEvidence {
    # Returns @{ available; text; fact } for one catalog evidence rule. text is
    # the machine form kept in the plan; fact is the one-line human form the
    # table shows.
    param(
        [Parameter(Mandatory = $true)][object] $Rule,
        [Parameter(Mandatory = $true)][object] $MetricIndex,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $metricId = [string](Get-PcxPolicyMember -Object $Rule -Name 'metric')
    if ([string]::IsNullOrWhiteSpace($metricId)) {
        return [pscustomobject]@{ available = $false; text = 'unavailable'; fact = 'unavailable' }
    }

    $key = $metricId.ToLowerInvariant()
    if (-not $MetricIndex.ContainsKey($key)) {
        return [pscustomobject]@{ available = $false; text = 'unavailable'; fact = 'unavailable' }
    }

    $metric = $MetricIndex[$key]
    $status = [string](Get-PcxPolicyMember -Object $metric -Name 'status')
    if ($status -ne 'measured') {
        return [pscustomobject]@{ available = $false; text = 'unavailable'; fact = 'unavailable' }
    }

    $value = Get-PcxPolicyMember -Object $metric -Name 'value'
    if ($null -eq $value) {
        return [pscustomobject]@{ available = $false; text = 'unavailable'; fact = 'unavailable' }
    }

    $predicate = [string](Get-PcxPolicyMember -Object $Rule -Name 'predicate')
    if (-not (Test-PcxTablePredicate -Value $value -Predicate $predicate)) {
        return [pscustomobject]@{ available = $false; text = 'predicate not met'; fact = 'predicate not met' }
    }

    $window = [string](Get-PcxPolicyMember -Object $metric -Name 'window')
    if ([string]::IsNullOrWhiteSpace($window)) { $window = 'instant' }

    return [pscustomobject]@{
        available = $true
        text      = "$metricId = $(Format-PcxTableValue $value), $window"
        fact      = (Format-PcxTableFact -MetricId $metricId -Value $value -Language $Language)
    }
}

function Format-PcxTableFact {
    # One short human sentence per catalog metric, instead of a raw JSON dump.
    param(
        [Parameter(Mandatory = $true)][string] $MetricId,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $id = $MetricId.Trim().ToLowerInvariant()
    switch ($id) {
        'storage.system_free_bytes' {
            $gb = [math]::Round(([double]$Value / 1GB), 1)
            $text = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.#}', $gb)
            return Get-PcxText -Key 'fact.free' -Language $Language -FormatArgs @($text)
        }
        'performance.hags_mode' { return Get-PcxText -Key 'fact.hags-off' -Language $Language }
        'performance.game_dvr_enabled' { return Get-PcxText -Key 'fact.game-dvr-on' -Language $Language }
        'printers.count' { return Get-PcxText -Key 'fact.no-printers' -Language $Language }
        'intent.userassist_entries' { return Get-PcxText -Key 'fact.userassist' -Language $Language -FormatArgs @([string]$Value) }
        'intent.prefetch_files' { return Get-PcxText -Key 'fact.prefetch' -Language $Language -FormatArgs @([string]$Value) }
        'intent.task_history_events' { return Get-PcxText -Key 'fact.taskhistory' -Language $Language -FormatArgs @([string]$Value) }
        'ux.tips_enabled' { return Get-PcxText -Key 'fact.tips-on' -Language $Language }
        'ads.advertising_id_enabled' { return Get-PcxText -Key 'fact.ads-on' -Language $Language }
        'search.web_results_enabled' { return Get-PcxText -Key 'fact.web-on' -Language $Language }
    }

    return "$MetricId = $(Format-PcxTableValue $Value)"
}

function Get-PcxTableSizeText {
    # Human size for a measured target: MB up to 1024, then GB.
    param(
        [Parameter(Mandatory = $true)][long] $Bytes,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $mb = [double]$Bytes / 1MB
    if ($mb -ge 1024) {
        $value = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.#}', ($mb / 1024))
        $unit = Get-PcxText -Key 'unit.gb' -Language $Language
        return "$value $unit"
    }

    $value = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0}', $mb)
    $unit = Get-PcxText -Key 'unit.mb' -Language $Language
    return "$value $unit"
}

function Format-PcxTableFrees {
    # Always a number or an explicit machine state: never "frees space".
    param(
        [Parameter(Mandatory = $true)][object] $Measure,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    if ([bool](Get-PcxPolicyMember -Object $Measure -Name 'denied')) {
        return Get-PcxText -Key 'fact.frees.denied' -Language $Language
    }

    $sizeText = Get-PcxTableSizeText -Bytes ([long](Get-PcxPolicyMember -Object $Measure -Name 'bytes')) -Language $Language
    if ([bool](Get-PcxPolicyMember -Object $Measure -Name 'partial')) {
        return Get-PcxText -Key 'fact.frees.atleast' -Language $Language -FormatArgs @($sizeText)
    }

    return Get-PcxText -Key 'fact.frees' -Language $Language -FormatArgs @($sizeText)
}

function Expand-PcxTableDisplayPath {
    # Expands %TOKEN% placeholders without the policy canonicalizer, which
    # lowercases: the user should read C:\Windows.old, not c:\windows.old.
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $environment = Get-PcxPolicyMember -Object $Profile -Name 'environment'
    $text = $Path
    foreach ($placeholder in [regex]::Matches($text, '%([A-Za-z0-9_]+)%')) {
        $value = Get-PcxPolicyMember -Object $environment -Name $placeholder.Groups[1].Value
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $text }
        $text = $text.Replace($placeholder.Value, [string]$value)
    }

    try { return [System.IO.Path]::GetFullPath($text) }
    catch { return $text }
}

function Get-PcxTableFileMeasure {
    # Reads concrete file targets and sums their measured bytes.
    #   exists   any target exists
    #   bytes    sum of sizes (directories carry a measured walk size)
    #   partial  at least one directory walk was truncated or unreadable
    #   denied   an existing target has no measurable size
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Targets,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $total = [long]0
    $exists = $false
    $partial = $false
    $denied = $false

    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }

        $expanded = Get-PcxTableExpandedTarget -Target $target -Profile $Profile
        $state = $null
        try { $state = Invoke-PcxPlatformRead -Target $expanded } catch { $state = $null }
        if ($null -eq $state) { continue }
        if (-not [bool](Get-PcxPolicyMember -Object $state -Name 'exists')) { continue }

        $exists = $true
        if ([bool](Get-PcxPolicyMember -Object $state -Name 'sizeTruncated')) { $partial = $true }

        $size = Get-PcxPolicyMember -Object $state -Name 'size'
        if ($null -eq $size) { $size = Get-PcxPolicyMember -Object $state -Name 'length' }
        if ($null -eq $size) {
            $denied = $true
            continue
        }

        $total += [long]$size
    }

    return [pscustomobject]@{
        exists  = $exists
        bytes   = $total
        partial = $partial
        denied  = $denied
    }
}

function Get-PcxTableTargetHint {
    # One concrete target name for the proposal column: a shortcut file, a
    # scheduled task, a service. Multi-target actions have no single name.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Targets)

    if ($Targets.Count -ne 1) { return '' }
    $target = $Targets[0]
    if ($null -eq $target) { return '' }

    switch (Get-PcxCatalogTargetKind -Target $target) {
        'file' {
            $path = [string](Get-PcxPolicyMember -Object $target -Name 'Path')
            return [System.IO.Path]::GetFileName($path)
        }
        'task' {
            $path = [string](Get-PcxPolicyMember -Object $target -Name 'Path')
            return [System.IO.Path]::GetFileName($path)
        }
        'service' { return [string](Get-PcxPolicyMember -Object $target -Name 'Name') }
    }

    return ''
}

function Test-PcxTableSingleTargetExists {
    # A single file or task target that is absent on this machine is a no-op
    # row: the table hides it instead of proposing a change to nothing.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Targets,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    if ($Targets.Count -ne 1) { return $true }
    $target = $Targets[0]
    if ($null -eq $target) { return $true }

    $kind = Get-PcxCatalogTargetKind -Target $target
    if ($kind -ne 'file' -and $kind -ne 'task') { return $true }

    $expanded = Get-PcxTableExpandedTarget -Target $target -Profile $Profile
    try { $state = Invoke-PcxPlatformRead -Target $expanded }
    catch { return $true }

    return [bool](Get-PcxPolicyMember -Object $state -Name 'exists')
}

function Get-PcxTablePolicyDecision {
    # All catalog targets must be allowed; the first denial demotes the row.
    param(
        [Parameter(Mandatory = $true)][object] $Action,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    foreach ($target in @(ConvertTo-PcxCatalogTargetList -Target (Get-PcxPolicyMember -Object $Action -Name 'target'))) {
        $expanded = Get-PcxTableExpandedTarget -Target $target -Profile $Profile
        $decision = Test-PcxTarget -Target $expanded -Profile $Profile
        if (-not $decision.allowed) {
            return $decision
        }
    }

    return $null
}

function Get-PcxTablePerformanceRecommendation {
    # Uses the catalog text verbatim; the sentence that carries the promise
    # disclaimer is extracted so the table keeps the literal phrase.
    param([Parameter(Mandatory = $true)][string] $Text)

    foreach ($sentence in [regex]::Split($Text, '(?<=\.)\s+')) {
        if ($sentence.IndexOf('effect not promised', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $sentence.Trim()
        }
    }

    return $Text
}

function Test-PcxTableTargetAlreadySatisfied {
    # A service or task that already holds the target state is a no-op row:
    # the table hides it instead of proposing a change to "disabled" twice.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Targets,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    if ($Targets.Count -eq 0) { return $false }

    $checked = 0
    foreach ($target in $Targets) {
        if ($null -eq $target) { return $false }

        $kind = Get-PcxCatalogTargetKind -Target $target
        if ($kind -ne 'service' -and $kind -ne 'task') { return $false }

        $expanded = Get-PcxTableExpandedTarget -Target $target -Profile $Profile
        try { $state = Invoke-PcxPlatformRead -Target $expanded }
        catch { return $false }
        if (-not [bool](Get-PcxPolicyMember -Object $state -Name 'exists')) { return $false }

        if ($kind -eq 'service') {
            $desired = Get-PcxPolicyMember -Object $target -Name 'Start'
            $current = Get-PcxPolicyMember -Object $state -Name 'start'
            if ($null -eq $desired -or $null -eq $current) { return $false }
            if ([int]$current -ne [int]$desired) { return $false }
        }
        else {
            $desired = Get-PcxPolicyMember -Object $target -Name 'Enabled'
            $current = Get-PcxPolicyMember -Object $state -Name 'enabled'
            if ($null -eq $desired -or $null -eq $current) { return $false }
            if ([bool]$current -ne [bool]$desired) { return $false }
        }

        $checked++
    }

    return ($checked -gt 0)
}

# A size row must free at least this much: smaller caches are noise on a modern
# disk and are never printed. A target whose size cannot be measured (denied)
# is still printed with that state.
$script:PcxTableMinimumCleanupBytes = [long](500MB)

# Risk levels: safe cannot lose a function, behavior changes one specific
# function (reversible), risky can affect stability, updates or security.
$script:PcxTableRiskOrder = @('safe', 'behavior', 'risky')
$script:PcxTableRiskIcons = [ordered]@{
    'safe'     = [char]::ConvertFromUtf32(0x1F7E2)
    'behavior' = [char]::ConvertFromUtf32(0x1F7E0)
    'risky'    = [char]::ConvertFromUtf32(0x1F534)
}

function New-PcxTableRow {
    param(
        [Parameter(Mandatory = $true)][int] $Number,
        [Parameter(Mandatory = $true)][string] $Group,
        [Parameter(Mandatory = $true)][string] $GroupLabel,
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Target,
        [Parameter(Mandatory = $false)][string] $TargetName = '',
        [Parameter(Mandatory = $true)][string] $WhatItDoes,
        [Parameter(Mandatory = $true)][string] $Evidence,
        [Parameter(Mandatory = $false)][string] $Fact = '',
        [Parameter(Mandatory = $false)][string] $Outcome = '',
        [Parameter(Mandatory = $false)][string] $Risk = 'caution',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $StopsWorking,
        [Parameter(Mandatory = $true)][string] $Recommendation
    )

    return [ordered]@{
        number         = $Number
        group          = $Group
        groupLabel     = $GroupLabel
        source         = $Source
        id             = $Id
        target         = $Target
        targetName     = $TargetName
        whatItDoes     = $WhatItDoes
        evidence       = $Evidence
        fact           = $Fact
        outcome        = $Outcome
        risk           = $Risk
        stopsWorking   = $StopsWorking
        recommendation = $Recommendation
        hidden         = $false
    }
}

function Get-PcxTableStopsWorking {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Inverse,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    # The anticheat note overlaps the decision dictionary in English, so the
    # ru report renders the dictionary sentence instead of the English one.
    # Every other note reads the table.stops.* dictionary sentences under ru
    # and the English table below under en; machine codes stay verbatim.
    if ($Language -eq 'ru' -and $Id.ToLowerInvariant() -eq 'anticheat') {
        return Get-PcxText -Key 'decision.PCX-POLICY-ANTICHEAT' -Language 'ru'
    }

    $key = $Id.ToLowerInvariant()
    if ($Language -eq 'ru') {
        if ($script:PcxTableStopsWorking.ContainsKey($key)) {
            return Get-PcxText -Key ('table.stops.' + $key) -Language 'ru'
        }

        switch ($Inverse) {
            'manifest-only' { return Get-PcxText -Key 'table.stops.inverse.manifest-only' -Language 'ru' }
            'quarantine'    { return Get-PcxText -Key 'table.stops.inverse.quarantine' -Language 'ru' }
            'snapshot'      { return Get-PcxText -Key 'table.stops.inverse.snapshot' -Language 'ru' }
        }

        return Get-PcxText -Key 'table.stops.default' -Language 'ru'
    }

    if ($script:PcxTableStopsWorking.ContainsKey($key)) {
        return $script:PcxTableStopsWorking[$key]
    }

    switch ($Inverse) {
        'manifest-only' { return 'Deleted content is not restorable.' }
        'quarantine'    { return 'The item is moved to quarantine and restorable byte for byte.' }
        'snapshot'      { return 'Changed state is snapshotted for undo.' }
    }

    return 'Nothing from pcx.'
}

function Add-PcxTableRow {
    param(
        [Parameter(Mandatory = $true)][object] $Buckets,
        [Parameter(Mandatory = $true)][object] $Row
    )

    [void]$Buckets[$Row.group].Add($Row)
}

function Get-PcxTableLanguage {
    # Explicit -Language wins and refuses strictly; then the scan envelope
    # language stamped by tune --lang; then en so direct calls stay stable.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan,
        [Parameter(Mandatory = $false)][string] $Requested
    )

    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        return Resolve-PcxLanguage -Requested $Requested
    }

    $stamped = [string](Get-PcxPolicyMember -Object $Scan -Name 'language')
    if (-not [string]::IsNullOrWhiteSpace($stamped)) {
        try {
            return Resolve-PcxLanguage -Requested $stamped
        }
        catch {
            return 'en'
        }
    }

    return 'en'
}

function Get-PcxTableGroupLabel {
    param(
        [Parameter(Mandatory = $true)][string] $Group,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    return Get-PcxText -Key ('group.' + $Group.Trim().ToLowerInvariant()) -Language $Language
}

function Get-PcxTablePolicyDemotionText {
    # En keeps the engine sentence verbatim; ru renders the decision
    # dictionary sentence (every code resolves through Get-PcxText) and keeps
    # only the machine code verbatim. An unknown code falls back to English.
    param(
        [Parameter(Mandatory = $true)][object] $Decision,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $code = [string](Get-PcxPolicyMember -Object $Decision -Name 'code')
    $reason = [string](Get-PcxPolicyMember -Object $Decision -Name 'reason')
    $verbatim = "$code - $reason"

    if ($Language -ne 'ru') { return $verbatim }

    $translated = $null
    try {
        $translated = Get-PcxText -Key ('decision.' + $code) -Language 'ru'
    }
    catch {
        $translated = $null
    }

    if ([string]::IsNullOrWhiteSpace($translated)) { return $verbatim }
    return "$code - $translated"
}

function Get-PcxTableBuildDemotionText {
    # En keeps the engine sentence verbatim; ru recomposes it from the build
    # dictionary keys, which carry the same cases the catalog decides on.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Build,
        [Parameter(Mandatory = $true)][object] $BuildDecision,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    if ($Language -ne 'ru') { return [string](Get-PcxPolicyMember -Object $BuildDecision -Name 'reason') }

    if ($null -eq $Build -or [string]::IsNullOrWhiteSpace([string]$Build)) {
        return Get-PcxText -Key 'build.unavailable' -Language 'ru'
    }

    $number = 0
    if (-not [int]::TryParse([string]$Build, [ref]$number)) {
        return Get-PcxText -Key 'build.notanumber' -Language 'ru' -FormatArgs @([string]$Build)
    }

    return Get-PcxText -Key 'build.unsupported' -Language 'ru' -FormatArgs @($number)
}

function Get-PcxTableBuildCaveatText {
    # En keeps the engine caveat verbatim; ru recomposes it from the build
    # dictionary. The caveat only exists on supported-but-unverified builds,
    # so the family is always win10 or win11 here.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Build,
        [Parameter(Mandatory = $true)][object] $BuildDecision,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    if ($Language -ne 'ru') { return [string](Get-PcxPolicyMember -Object $BuildDecision -Name 'caveat') }

    $family = [string](Get-PcxPolicyMember -Object $BuildDecision -Name 'family')
    return Get-PcxText -Key 'build.unverified' -Language 'ru' -FormatArgs @([string]$Build, $family)
}


function Invoke-PcxTable {
    <#
    .SYNOPSIS
        Renders the one proposal table: number, risk, proposal, outcome.

    .PARAMETER Scan
        The object returned by Get-PcxScan (metrics plus optional environment
        and diagnostics), or a tune envelope data object (which carries the
        diagnostics report as data.diagnostics plus the stamped language).

    .PARAMETER Catalog
        Optional Get-PcxCatalog result. Loaded when omitted.

    .PARAMETER Profile
        Optional policy profile or environment fixture. Defaults to
        Scan.environment; when absent every applyable row is demoted to Manual.

    .PARAMETER Language
        Optional report language. Wins over Scan.language; an unknown code
        refuses with PCX-E-LANG. Defaults to Scan.language, then en.

    .OUTPUTS
        @{ table = <markdown>; groups = <ordered>; rowCount = <int>; truncated = <bool>; language = <code> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Scan,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Catalog,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $false)][string] $Language
    )

    if ($null -eq $Catalog) {
        $Catalog = Get-PcxCatalog
    }

    $code = Get-PcxTableLanguage -Scan $Scan -Requested $Language
    $profileData = Get-PcxTableProfile -Profile $Profile -Scan $Scan
    $build = Get-PcxTableBuild -Profile $Profile -Scan $Scan
    $metricIndex = Get-PcxTableMetricIndex -Metrics @(Get-PcxPolicyMember -Object $Scan -Name 'metrics')

    $buckets = [ordered]@{}
    foreach ($groupKey in $script:PcxTableGroupOrder) {
        $buckets[$groupKey] = New-Object System.Collections.Generic.List[object]
    }

    $number = 0

    # 1. Applyable catalog actions, in catalog order.
    foreach ($action in @(Get-PcxPolicyMember -Object $Catalog -Name 'actions')) {
        if ($null -eq $action) { continue }

        $id = [string](Get-PcxPolicyMember -Object $action -Name 'id')
        $rule = Get-PcxPolicyMember -Object $action -Name 'evidence_rule'
        $evidence = Get-PcxTableEvidence -Rule $rule -MetricIndex $metricIndex -Language $code
        if (-not $evidence.available) { continue }

        $actionTargets = @(ConvertTo-PcxCatalogTargetList -Target (Get-PcxPolicyMember -Object $action -Name 'target'))
        $inverse = [string](Get-PcxPolicyMember -Object $action -Name 'inverse')
        if ($inverse -eq 'manifest-only') {
            $measure = Get-PcxTableFileMeasure -Targets $actionTargets -Profile $profileData
            if (-not $measure.exists) { continue }
            if (-not $measure.denied -and $measure.bytes -lt $script:PcxTableMinimumCleanupBytes) { continue }
            $evidence = [pscustomobject]@{
                available = $true
                text      = $evidence.text
                fact      = (Format-PcxTableFrees -Measure $measure -Language $code)
            }
        }
        elseif (-not (Test-PcxTableSingleTargetExists -Targets $actionTargets -Profile $profileData)) {
            # A shortcut or task that is not on this machine is not a row.
            continue
        }
        elseif (Test-PcxTableTargetAlreadySatisfied -Targets $actionTargets -Profile $profileData) {
            # The service or task already holds the target state: no-op row.
            continue
        }

        $number++
        $group = ([string](Get-PcxPolicyMember -Object $action -Name 'group')).Trim().ToLowerInvariant()
        if ($script:PcxTableGroupOrder -notcontains $group) { $group = 'manual' }

        # Same build decision the plan uses. A supported-but-unverified action
        # stays selectable; an unsupported build is demoted to Manual with the
        # reason kept in the row.
        $buildDecision = Get-PcxCatalogBuildDecision -Action $action -Build $build
        $decision = $null
        $source = 'catalog'
        if (-not $buildDecision.applyable) {
            $group = 'manual'
            $source = 'demoted'
            $buildReason = Get-PcxTableBuildDemotionText -Build $build -BuildDecision $buildDecision -Language $code
            $demotedReason = Get-PcxText -Key 'table.demotion.build' -Language $code -FormatArgs @($buildReason)
        }
        else {
            $decision = Get-PcxTablePolicyDecision -Action $action -Profile $profileData
            if ($null -ne $decision) {
                $group = 'manual'
                $source = 'demoted'
                $policyReason = Get-PcxTablePolicyDemotionText -Decision $decision -Language $code
                $demotedReason = Get-PcxText -Key 'table.demotion.policy' -Language $code -FormatArgs @($policyReason)
            }
        }

        if ($code -eq 'ru') {
            $whatItDoes = [string](Get-PcxPolicyMember -Object $action -Name 'user_text_ru')
        }
        else {
            $whatItDoes = [string](Get-PcxPolicyMember -Object $action -Name 'user_text_en')
        }
        if ($source -eq 'demoted') {
            $recommendation = $demotedReason
        }
        elseif ($group -eq 'performance') {
            if ($code -eq 'ru') {
                $recommendation = Get-PcxText -Key 'table.recommendation.performance' -Language 'ru'
            }
            else {
                $recommendation = Get-PcxTablePerformanceRecommendation -Text $whatItDoes
            }
        }
        elseif ($group -eq 'safe') {
            $recommendation = Get-PcxText -Key 'table.recommendation.safe' -Language $code
        }
        else {
            $recommendation = Get-PcxText -Key 'table.recommendation.behavior' -Language $code
        }

        if ($source -ne 'demoted' -and $buildDecision.supported -and -not $buildDecision.verified) {
            $recommendation = Get-PcxText -Key 'table.caveat' -Language $code -FormatArgs @($recommendation, (Get-PcxTableBuildCaveatText -Build $build -BuildDecision $buildDecision -Language $code))
        }

        $risk = 'safe'
        if ($group -eq 'performance' -or $group -eq 'behavior') { $risk = 'behavior' }
        if ($source -eq 'demoted') { $risk = 'behavior' }

        $row = New-PcxTableRow -Number $number -Group $group -GroupLabel (Get-PcxTableGroupLabel -Group $group -Language $code) `
            -Source $source -Id $id `
            -Target (Get-PcxTableTargetText -Target (Get-PcxPolicyMember -Object $action -Name 'target')) `
            -TargetName (Get-PcxTableTargetHint -Targets $actionTargets) `
            -WhatItDoes $whatItDoes -Evidence $evidence.text -Fact $evidence.fact -Risk $risk `
            -StopsWorking (Get-PcxTableStopsWorking -Id $id -Inverse $inverse -Language $code) `
            -Recommendation $recommendation
        Add-PcxTableRow -Buckets $buckets -Row $row
    }

    # 2. Manual entries from config/actions/manual.json, in file order. A row
    # exists only when its measured target exists and is non-empty: an absent
    # Windows.old, an empty WER folder or a missing hiberfil.sys is not a row.
    foreach ($entry in @(Get-PcxPolicyMember -Object $Catalog -Name 'manual')) {
        if ($null -eq $entry) { continue }
        $kind = ([string](Get-PcxPolicyMember -Object $entry -Name 'kind')).Trim().ToLowerInvariant()
        if ($kind -ne 'manual') { continue }

        $entryTargets = @(ConvertTo-PcxCatalogTargetList -Target (Get-PcxPolicyMember -Object $entry -Name 'measure'))
        $measured = Get-PcxTableFileMeasure -Targets $entryTargets -Profile $profileData
        if (-not $measured.exists) { continue }
        if (-not $measured.denied -and $measured.bytes -lt $script:PcxTableMinimumCleanupBytes) { continue }

        $number++
        $id = [string](Get-PcxPolicyMember -Object $entry -Name 'id')
        if ($code -eq 'ru') {
            $manualWhat = [string](Get-PcxPolicyMember -Object $entry -Name 'user_text_ru')
            $manualOutcome = [string](Get-PcxPolicyMember -Object $entry -Name 'outcome_ru')
        }
        else {
            $manualWhat = [string](Get-PcxPolicyMember -Object $entry -Name 'user_text_en')
            $manualOutcome = [string](Get-PcxPolicyMember -Object $entry -Name 'outcome_en')
        }

        $displayTargets = New-Object System.Collections.Generic.List[string]
        foreach ($entryTarget in $entryTargets) {
            $rawPath = [string](Get-PcxPolicyMember -Object $entryTarget -Name 'Path')
            [void]$displayTargets.Add((Expand-PcxTableDisplayPath -Path $rawPath -Profile $profileData))
        }
        $targetText = ($displayTargets.ToArray() -join '; ')
        $manualWhat = $manualWhat.Replace('{target}', $targetText)
        $manualOutcome = (Format-PcxTableFrees -Measure $measured -Language $code) + '. ' + $manualOutcome

        $risk = ([string](Get-PcxPolicyMember -Object $entry -Name 'risk')).Trim().ToLowerInvariant()
        if ($risk -eq 'caution') { $risk = 'behavior' }
        if (@('safe', 'behavior', 'risky') -notcontains $risk) { $risk = 'behavior' }

        $row = New-PcxTableRow -Number $number -Group 'manual' -GroupLabel (Get-PcxTableGroupLabel -Group 'manual' -Language $code) `
            -Source 'manual' -Id $id -Target $targetText `
            -WhatItDoes $manualWhat `
            -Evidence 'measured = file size' `
            -Outcome $manualOutcome -Risk $risk `
            -StopsWorking '' `
            -Recommendation (Get-PcxText -Key 'table.recommendation.manual' -Language $code)
        Add-PcxTableRow -Buckets $buckets -Row $row
    }

    # 3. Don't-touch notes from manual.json, then environment findings.
    foreach ($entry in @(Get-PcxPolicyMember -Object $Catalog -Name 'manual')) {
        if ($null -eq $entry) { continue }
        $kind = ([string](Get-PcxPolicyMember -Object $entry -Name 'kind')).Trim().ToLowerInvariant()
        if ($kind -ne 'dont-touch') { continue }

        $number++
        $id = [string](Get-PcxPolicyMember -Object $entry -Name 'id')
        if ($code -eq 'ru') {
            $dontTouchWhat = [string](Get-PcxPolicyMember -Object $entry -Name 'user_text_ru')
        }
        else {
            $dontTouchWhat = [string](Get-PcxPolicyMember -Object $entry -Name 'user_text_en')
        }
        # The catalog sentence already names the anticheat subject; the
        # decision sentence alone would read as a fragment in a bullet list.
        $row = New-PcxTableRow -Number $number -Group 'dont-touch' -GroupLabel (Get-PcxTableGroupLabel -Group 'dont-touch' -Language $code) `
            -Source 'manual' -Id $id -Target 'none' `
            -WhatItDoes $dontTouchWhat `
            -Evidence 'manual = dont-touch, n/a' `
            -Risk 'never' `
            -StopsWorking (Get-PcxTableStopsWorking -Id $id -Language $code) `
            -Recommendation (Get-PcxText -Key 'table.recommendation.donttouch' -Language $code)
        Add-PcxTableRow -Buckets $buckets -Row $row
    }

    $environment = Get-PcxPolicyMember -Object $Scan -Name 'environment'
    $environmentFindings = @(
        @{ id = 'managed'; field = 'managed'; labelKey = 'table.env.managed.label'; textKey = 'table.env.managed.text' }
        @{ id = 's-mode'; field = 'sMode'; labelKey = 'table.env.smode.label'; textKey = 'table.env.smode.text' }
        @{ id = 'hvci'; field = 'hvci'; labelKey = 'table.env.hvci.label'; textKey = 'table.env.hvci.text' }
    )
    foreach ($finding in $environmentFindings) {
        $field = Get-PcxPolicyMember -Object $environment -Name $finding.field
        if ($null -eq $field) { continue }
        if ([string](Get-PcxPolicyMember -Object $field -Name 'status') -ne 'measured') { continue }
        $value = Get-PcxPolicyMember -Object $field -Name 'value'
        if ($value -isnot [bool] -or -not $value) { continue }

        $number++
        $row = New-PcxTableRow -Number $number -Group 'dont-touch' -GroupLabel (Get-PcxTableGroupLabel -Group 'dont-touch' -Language $code) `
            -Source 'environment' -Id $finding.id -Target 'environment' `
            -WhatItDoes (Get-PcxText -Key $finding.labelKey -Language $code) `
            -Evidence "environment.$($finding.field) = true, instant" `
            -Risk 'never' `
            -StopsWorking (Get-PcxTableStopsWorking -Id $finding.id -Language $code) `
            -Recommendation (Get-PcxText -Key 'table.recommendation.donttouch' -Language $code)
        Add-PcxTableRow -Buckets $buckets -Row $row
    }

    # 4. One proposal table, nothing else. The diagnostic JSON stays available
    # to the agent, which writes its own findings; the chat table stays short.
    $lines = New-Object System.Collections.Generic.List[string]

    $visibleRows = New-Object System.Collections.Generic.List[object]
    foreach ($riskKey in $script:PcxTableRiskOrder) {
        foreach ($groupKey in $script:PcxTableGroupOrder) {
            foreach ($row in $buckets[$groupKey]) {
                if ([string]$row.risk -ne $riskKey) { continue }
                if ([string]$row.source -eq 'demoted') { continue }
                if ([string]$row.source -eq 'environment') { continue }
                if ([string]$row.group -eq 'dont-touch') { continue }
                if ([string]$row.source -ne 'catalog' -and [string]$row.source -ne 'manual') { continue }
                [void]$visibleRows.Add($row)
            }
        }
    }

    foreach ($groupKey in $script:PcxTableGroupOrder) {
        foreach ($row in $buckets[$groupKey]) { $row.number = 0 }
    }

    $displayNumber = 0
    foreach ($row in $visibleRows) {
        $displayNumber++
        $row.number = $displayNumber
    }
    foreach ($groupKey in $script:PcxTableGroupOrder) {
        foreach ($row in $buckets[$groupKey]) {
            if ([int]$row.number -gt 0) { continue }
            $displayNumber++
            $row.number = $displayNumber
        }
    }

    $total = $visibleRows.Count
    $groups = [ordered]@{}
    foreach ($groupKey in $script:PcxTableGroupOrder) {
        $label = Get-PcxTableGroupLabel -Group $groupKey -Language $code
        $groups[$label] = [ordered]@{
            key   = $groupKey
            label = $label
            rows  = $buckets[$groupKey].ToArray()
        }
    }

    $numberHeader = Get-PcxText -Key 'column.number' -Language $code
    $categoryHeader = Get-PcxText -Key 'column.category' -Language $code
    $proposalHeader = Get-PcxText -Key 'column.proposal' -Language $code
    $outcomeHeader = Get-PcxText -Key 'column.outcome' -Language $code

    [void]$lines.Add('## ' + (Get-PcxText -Key 'heading.actions' -Language $code))
    [void]$lines.Add('')

    if ($visibleRows.Count -eq 0) {
        [void]$lines.Add('_' + (Get-PcxText -Key 'table.none.proposals' -Language $code) + '_')
        return [pscustomobject][ordered]@{
            table       = ($lines -join "`n").TrimEnd()
            groups      = $groups
            visibleRows = @()
            rowCount    = 0
            truncated   = $false
            language    = $code
        }
    }

    [void]$lines.Add(('| {0} | {1} | {2} | {3} |' -f $numberHeader, $categoryHeader, $proposalHeader, $outcomeHeader))
    [void]$lines.Add('|---|---|---|---|')

    foreach ($row in $visibleRows) {
        $riskKey = [string]$row.risk
        $category = $script:PcxTableRiskIcons[$riskKey] + ' ' + (Get-PcxText -Key ('risk.' + $riskKey) -Language $code)

        $proposal = [string]$row.whatItDoes
        $colon = $proposal.IndexOf(': ', [System.StringComparison]::Ordinal)
        $dot = $proposal.IndexOf('. ', [System.StringComparison]::Ordinal)
        if ($colon -gt 0 -and $colon -le 80 -and ($dot -lt 0 -or $colon -lt $dot)) {
            $proposal = $proposal.Substring(0, $colon)
        }
        elseif ($dot -gt 0) {
            $proposal = $proposal.Substring(0, $dot)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$row.targetName)) {
            $proposal = ($proposal.TrimEnd([char]'.')) + ' (' + [string]$row.targetName + ')'
        }

        $outcome = [string]$row.outcome
        if ([string]::IsNullOrWhiteSpace($outcome)) {
            if ([string]$row.group -eq 'safe') {
                $outcome = [string]$row.fact + '. ' + [string]$row.stopsWorking
            }
            elseif ([string]$row.group -eq 'performance') {
                if (-not [string]::IsNullOrWhiteSpace([string]$row.fact)) {
                    $proposal = $proposal + ' (' + [string]$row.fact + ')'
                }
                $outcome = (Get-PcxText -Key 'outcome.performance' -Language $code) + ' ' + [string]$row.stopsWorking
            }
            else {
                $outcome = [string]$row.stopsWorking
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$row.fact)) {
            $proposal = $proposal + ' (' + [string]$row.fact + ')'
        }

        [void]$lines.Add(('| {0} | {1} | {2} | {3} |' -f
                $row.number,
                (Format-PcxTableCell $category),
                (Format-PcxTableCell $proposal),
                (Format-PcxTableCell $outcome)))
    }

    return [pscustomobject][ordered]@{
        table       = ($lines -join "`n").TrimEnd()
        groups      = $groups
        visibleRows = $visibleRows.ToArray()
        rowCount    = $total
        truncated   = $false
        language    = $code
    }
}
