<#
.SYNOPSIS
    Section registry, findings model and group mapping.

.DESCRIPTION
    Wave 2 of optimize-v0.1-discovery (todo 3, closes C2/DV-3/DV-5/DV-11/DV-12).
    The contract consumed by later todos:

        todo 4 (diagnostics builders) calls New-PcxFinding and
            New-PcxDiagnosticsReport. Constructors are small, explicit and free
            of I/O: no machine state is read here.
        todo 6 (renderer) calls ConvertTo-PcxFindingsDocument, which resolves
            every titleKey/detailKey/whyItMattersKey/actionHintKey through
            Get-PcxText, so a key the dictionary does not carry throws
            PCX-E-TEXT instead of rendering a raw key.
        todo 7 (catalog validator) calls Test-PcxFindingGroupMap to prove an
            actionId/findingId pair resolves on both sides with equal groups.

    Closed sets: 13 ordered sections, five severities
    (critical/warn/info/good/unavailable), five groups
    (safe/performance/behavior/manual/dont-touch). The only open door is an
    `extension:<id>` section, which must carry a real machine fact in
    evidence, never a placeholder.

    Validators (all throw, never silently coerce):
        * unknown section refuses unless it matches `extension:<id>`;
        * unknown severity or group refuses;
        * alreadyGood with an actionId refuses (nothing to remedy);
        * a remedy (actionHintKey or actionId) without a group refuses.

    Canonical-JSON round-trips go through ConvertTo-PcxCanonicalJson in
    PcxJson.ps1; ConvertTo-Json is never used (it is host-version dependent).

    PowerShell 5.1 compatibility: no ??, no ternary ?:, no ?. operator.
    This file is ASCII-only, so no BOM is needed. Line endings are CRLF per
    .gitattributes.
#>

Set-StrictMode -Version 2.0

$script:PcxSectionOrder = @(
    'platform', 'power', 'storage', 'memory', 'background', 'services',
    'gaming', 'display', 'network', 'maintenance', 'drivers', 'security',
    'thermal'
)
$script:PcxFindingSeverities = @('critical', 'warn', 'info', 'good', 'unavailable')
$script:PcxFindingGroups = @('safe', 'performance', 'behavior', 'manual', 'dont-touch')
$script:PcxDiagnosticsSchema = 'pcx-diagnostics/1'

function Get-PcxSections {
    <#
    .SYNOPSIS
        Returns the 13 ordered diagnostics section ids.
    #>

    return @($script:PcxSectionOrder)
}

function Test-PcxSectionKnown {
    # Internal: $true when the normalized id is one of the 13 registry ids.
    param([Parameter(Mandatory = $true)][string] $Section)

    foreach ($known in $script:PcxSectionOrder) {
        if ([string]::Equals($Section, $known, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function ConvertTo-PcxSectionId {
    # Internal: normalizes one section id (trim + lowercase) or throws
    # PCX-E-FINDING-SECTION. Extension ids must match extension:<id> where
    # <id> starts alphanumerically and then holds alphanumerics or dashes.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Section)

    $text = ([string]$Section).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw [System.ArgumentException]::new('PCX-E-FINDING-SECTION: section is required.')
    }

    if (Test-PcxSectionKnown -Section $text) {
        return $text
    }

    if ($text -match '^extension:[a-z0-9][a-z0-9-]*$') {
        return $text
    }

    throw [System.ArgumentException]::new("PCX-E-FINDING-SECTION: unknown section '$text'; expected one of the 13 registry ids or extension:<id>.")
}

function ConvertTo-PcxSeverityName {
    # Internal: normalizes one severity name or throws PCX-E-FINDING-SEVERITY.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Severity)

    $text = ([string]$Severity).Trim().ToLowerInvariant()
    foreach ($known in $script:PcxFindingSeverities) {
        if ($text -ceq $known) {
            return $known
        }
    }

    throw [System.ArgumentException]::new("PCX-E-FINDING-SEVERITY: unknown severity '$text'; expected critical, warn, info, good or unavailable.")
}

function ConvertTo-PcxGroupName {
    # Internal: normalizes one group label ($null stays $null) or throws
    # PCX-E-FINDING-GROUP.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Group)

    if ($null -eq $Group) {
        return $null
    }

    $text = ([string]$Group).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    foreach ($known in $script:PcxFindingGroups) {
        if ($text -ceq $known) {
            return $known
        }
    }

    throw [System.ArgumentException]::new("PCX-E-FINDING-GROUP: unknown group '$text'; expected safe, performance, behavior, manual or dont-touch.")
}

function Get-PcxFindingRequiredText {
    # Internal: one required non-empty text field or throws PCX-E-FINDING-SHAPE.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Field
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw [System.ArgumentException]::new("PCX-E-FINDING-SHAPE: finding field '$Field' is required and must not be empty.")
    }

    return $text
}

function Get-PcxFindingOptionalText {
    # Internal: one optional text field; $null/empty/whitespace becomes $null.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text
}

function New-PcxFinding {
    <#
    .SYNOPSIS
        Builds one validated diagnostics finding (no I/O).

    .DESCRIPTION
        Finding shape: section, id, severity, titleKey, detailKey, evidence,
        alreadyGood, whyItMattersKey, actionHintKey, group, actionId. group is
        one of the five labels or $null; actionId is $null unless the finding
        has a safe remedy. alreadyGood with an actionId refuses, and a remedy
        (actionHintKey or actionId) without a group refuses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Section,
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][object] $Severity,
        [Parameter(Mandatory = $true)][string] $TitleKey,
        [Parameter(Mandatory = $true)][string] $DetailKey,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Evidence,
        [Parameter(Mandatory = $false)][bool] $AlreadyGood = $false,
        [Parameter(Mandatory = $false)][AllowNull()][object] $WhyItMattersKey = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object] $ActionHintKey = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Group = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object] $ActionId = $null
    )

    $sectionId = ConvertTo-PcxSectionId -Section $Section
    $findingId = Get-PcxFindingRequiredText -Value $Id -Field 'id'
    $severityName = ConvertTo-PcxSeverityName -Severity $Severity
    $title = Get-PcxFindingRequiredText -Value $TitleKey -Field 'titleKey'
    $detail = Get-PcxFindingRequiredText -Value $DetailKey -Field 'detailKey'

    if ($null -eq $Evidence) {
        throw [System.ArgumentException]::new("PCX-E-FINDING-EVIDENCE: finding '$findingId' carries no evidence; an extension section must carry a real machine fact, never a placeholder.")
    }

    $why = Get-PcxFindingOptionalText -Value $WhyItMattersKey
    $hint = Get-PcxFindingOptionalText -Value $ActionHintKey
    $groupName = ConvertTo-PcxGroupName -Group $Group
    $remedy = Get-PcxFindingOptionalText -Value $ActionId

    if ($AlreadyGood -and $null -ne $remedy) {
        throw [System.ArgumentException]::new("PCX-E-FINDING-ACTION: finding '$findingId' is already good but carries actionId '$remedy'; a good finding has nothing to remedy.")
    }

    if (($null -ne $hint -or $null -ne $remedy) -and $null -eq $groupName) {
        throw [System.ArgumentException]::new("PCX-E-FINDING-GROUP: finding '$findingId' carries a remedy but no group; a remedy must map to exactly one of the five groups.")
    }

    return [ordered]@{
        section         = $sectionId
        id              = $findingId
        severity        = $severityName
        titleKey        = $title
        detailKey       = $detail
        evidence        = $Evidence
        alreadyGood     = $AlreadyGood
        whyItMattersKey = $why
        actionHintKey   = $hint
        group           = $groupName
        actionId        = $remedy
    }
}

function New-PcxDiagnosticsReport {
    <#
    .SYNOPSIS
        Builds one diagnostics report envelope around validated findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]] $Findings = @()
    )

    $items = @($Findings)
    foreach ($item in $items) {
        $section = Get-PcxPolicyMember -Object $item -Name 'section'
        $id = Get-PcxPolicyMember -Object $item -Name 'id'
        if ($null -eq $section -or $null -eq $id) {
            throw [System.ArgumentException]::new('PCX-E-FINDING-SHAPE: every report finding must carry section and id; build findings with New-PcxFinding.')
        }
    }

    return [ordered]@{
        schema   = $script:PcxDiagnosticsSchema
        findings = @($items)
    }
}

function Get-PcxFindingsDocumentSectionTitle {
    # Internal: registry ids resolve through Get-PcxSectionTitle; an
    # extension:<id> section renders as its bare suffix.
    param([Parameter(Mandatory = $true)][string] $Section)

    if (Test-PcxSectionKnown -Section $Section) {
        return Get-PcxSectionTitle -Section $Section
    }

    return $Section.Substring('extension:'.Length)
}

function ConvertTo-PcxFindingsDocument {
    <#
    .SYNOPSIS
        Resolves one report into a render-ready document (no I/O).

    .DESCRIPTION
        Every key (titleKey, detailKey, whyItMattersKey, actionHintKey, group,
        severity, section) resolves through Get-PcxText for the requested
        language; a missing key throws PCX-E-TEXT. Evidence passes through
        untouched so the canonical-JSON bytes stay stable across languages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Report,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $code = Resolve-PcxLanguage -Requested $Language
    $schema = Get-PcxPolicyMember -Object $Report -Name 'schema'
    if ($null -eq $schema) {
        $schema = $script:PcxDiagnosticsSchema
    }

    $reportFindings = @((Get-PcxPolicyMember -Object $Report -Name 'findings'))
    if ($reportFindings.Count -eq 1 -and $null -eq $reportFindings[0]) {
        $reportFindings = @()
    }

    $extensionIds = New-Object System.Collections.Generic.List[string]
    foreach ($item in $reportFindings) {
        $section = [string](Get-PcxPolicyMember -Object $item -Name 'section')
        if (-not (Test-PcxSectionKnown -Section $section) -and -not $extensionIds.Contains($section)) {
            [void]$extensionIds.Add($section)
        }
    }
    $sortedExtensions = $extensionIds.ToArray()
    [Array]::Sort($sortedExtensions, [System.StringComparer]::Ordinal)

    $sections = @()
    foreach ($id in $script:PcxSectionOrder) {
        $sections += [ordered]@{
            id    = $id
            title = Get-PcxSectionTitle -Section $id -Language $code
        }
    }
    foreach ($id in $sortedExtensions) {
        $sections += [ordered]@{
            id    = $id
            title = Get-PcxFindingsDocumentSectionTitle -Section $id
        }
    }

    $documents = @()
    foreach ($item in $reportFindings) {
        $section = [string](Get-PcxPolicyMember -Object $item -Name 'section')
        $severity = [string](Get-PcxPolicyMember -Object $item -Name 'severity')
        $alreadyGood = [bool](Get-PcxPolicyMember -Object $item -Name 'alreadyGood')
        $why = Get-PcxPolicyMember -Object $item -Name 'whyItMattersKey'
        $hint = Get-PcxPolicyMember -Object $item -Name 'actionHintKey'
        $group = Get-PcxPolicyMember -Object $item -Name 'group'
        $actionId = Get-PcxPolicyMember -Object $item -Name 'actionId'

        if ([string]::IsNullOrWhiteSpace([string]$why)) { $why = $null }
        if ([string]::IsNullOrWhiteSpace([string]$hint)) { $hint = $null }
        if ($null -ne $group -and [string]::IsNullOrWhiteSpace([string]$group)) { $group = $null }
        if ($null -ne $actionId -and [string]::IsNullOrWhiteSpace([string]$actionId)) { $actionId = $null }

        $resolvedWhy = $null
        if ($null -ne $why) {
            $resolvedWhy = Get-PcxText -Key ([string]$why) -Language $code
        }
        $resolvedHint = $null
        if ($null -ne $hint) {
            $resolvedHint = Get-PcxText -Key ([string]$hint) -Language $code
        }
        $groupLabel = $null
        if ($null -ne $group) {
            $groupLabel = Get-PcxText -Key ('group.' + ([string]$group)) -Language $code
        }

        $documents += [ordered]@{
            section      = $section
            sectionTitle = Get-PcxFindingsDocumentSectionTitle -Section $section
            id           = [string](Get-PcxPolicyMember -Object $item -Name 'id')
            severity     = $severity
            severityLabel = (Get-PcxSeverityLabel -Severity $severity -Language $code)
            title        = Get-PcxText -Key ([string](Get-PcxPolicyMember -Object $item -Name 'titleKey')) -Language $code
            detail       = Get-PcxText -Key ([string](Get-PcxPolicyMember -Object $item -Name 'detailKey')) -Language $code
            evidence     = Get-PcxPolicyMember -Object $item -Name 'evidence'
            alreadyGood  = $alreadyGood
            whyItMatters = $resolvedWhy
            actionHint   = $resolvedHint
            group        = $group
            groupLabel   = $groupLabel
            actionId     = $actionId
        }
    }

    return [ordered]@{
        schema   = [string]$schema
        language = $code
        sections = @($sections)
        findings = @($documents)
    }
}

function Test-PcxFindingGroupMap {
    <#
    .SYNOPSIS
        Validates finding/action group mapping; returns error strings.

    .DESCRIPTION
        Returns an array of human-readable error strings; an empty result
        means the map is valid. Checks: no duplicate section/id pair; a
        finding carrying an actionId is never good/unavailable; when -Actions
        is supplied, every finding actionId resolves to a catalog action with
        an equal group, and every action findingId resolves to a finding that
        is neither good nor unavailable. Members are read case-insensitively,
        so deserialized (canonical-JSON round-tripped) objects validate too.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]] $Findings = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]] $Actions = @()
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $items = @($Findings)
    $catalog = @($Actions)

    $seen = @{}
    foreach ($item in $items) {
        $section = [string](Get-PcxPolicyMember -Object $item -Name 'section')
        $id = [string](Get-PcxPolicyMember -Object $item -Name 'id')
        $pair = $section.Trim().ToLowerInvariant() + '/' + $id.Trim().ToLowerInvariant()
        if ($seen.ContainsKey($pair)) {
            [void]$errors.Add("duplicate finding '$section/$id'.")
        }
        else {
            $seen[$pair] = $true
        }

        $actionId = Get-PcxPolicyMember -Object $item -Name 'actionId'
        if ($null -ne $actionId -and -not [string]::IsNullOrWhiteSpace([string]$actionId)) {
            $severity = ([string](Get-PcxPolicyMember -Object $item -Name 'severity')).Trim().ToLowerInvariant()
            if ($severity -eq 'good' -or $severity -eq 'unavailable') {
                [void]$errors.Add("finding '$section/$id' carries actionId '$([string]$actionId)' but severity '$severity' cannot carry a remedy.")
            }

            if ($catalog.Count -gt 0) {
                $match = $null
                foreach ($action in $catalog) {
                    if ([string]::Equals([string](Get-PcxPolicyMember -Object $action -Name 'id'), [string]$actionId, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $match = $action
                        break
                    }
                }
                if ($null -eq $match) {
                    [void]$errors.Add("finding '$section/$id' carries actionId '$([string]$actionId)' with no matching catalog action.")
                }
                else {
                    $actionGroup = Get-PcxPolicyMember -Object $match -Name 'group'
                    $findingGroup = Get-PcxPolicyMember -Object $item -Name 'group'
                    if ($null -ne $actionGroup -and -not [string]::IsNullOrWhiteSpace([string]$actionGroup) -and
                        -not [string]::Equals([string]$actionGroup, [string]$findingGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
                        [void]$errors.Add("finding '$section/$id' group '$([string]$findingGroup)' does not match catalog action '$([string]$actionId)' group '$([string]$actionGroup)'.")
                    }
                }
            }
        }
    }

    foreach ($action in $catalog) {
        $wanted = Get-PcxPolicyMember -Object $action -Name 'findingId'
        if ($null -eq $wanted -or [string]::IsNullOrWhiteSpace([string]$wanted)) {
            continue
        }

        $resolved = $null
        foreach ($item in $items) {
            if ([string]::Equals([string](Get-PcxPolicyMember -Object $item -Name 'id'), [string]$wanted, [System.StringComparison]::OrdinalIgnoreCase)) {
                $resolved = $item
                break
            }
        }

        $actionName = [string](Get-PcxPolicyMember -Object $action -Name 'id')
        if ($null -eq $resolved) {
            [void]$errors.Add("catalog action '$actionName' findingId '$([string]$wanted)' resolves to no finding.")
            continue
        }

        $severity = ([string](Get-PcxPolicyMember -Object $resolved -Name 'severity')).Trim().ToLowerInvariant()
        if ($severity -eq 'good' -or $severity -eq 'unavailable') {
            [void]$errors.Add("catalog action '$actionName' findingId '$([string]$wanted)' resolves to a '$severity' finding.")
        }
    }

    return $errors.ToArray()
}
