<#
.SYNOPSIS
    Evidence classes, domain linkage and the evidence gate for one target.

.DESCRIPTION
    The evidence engine answers one question: does this evidence justify this
    write? It is pure: no machine state is read. The only file it opens is the
    bundled data file config/evidence-domains.json (data, not observation).

    Evidence kinds
        telemetry  a measured number (bytes, MB, counters, event counts) with
                   metric, value, domain and window
        state      a machine-read pre-state value plus a hardware/software
                   profile; an agent-supplied state value alone is never trusted

    Domain linkage
        An agent-discovered reg/svc/task target must cite a telemetry metric
        whose domain equals the pinned domain for that path or subsystem:
            svc  -> services
            task -> startup
            reg  -> config/evidence-domains.json entry for the canonical path
        A seed action validates through its catalog evidence_rule instead, so a
        curated rule may use cross-domain evidence (intent, printers).
        A file target must cite a metric rooted at the same path root.
        An undeclared target mapping refuses PCX-E-EVIDENCE-DOMAIN.

    Refusal codes (the decision is always a structured object, never a throw):
        PCX-E-EVIDENCE-ALLOW       evidence justifies the write
        PCX-E-EVIDENCE-KIND        unknown evidence kind
        PCX-E-EVIDENCE-SHAPE       missing kind/metric/window/profile field
        PCX-E-EVIDENCE-DOMAIN      missing, unknown or unrelated domain
        PCX-E-EVIDENCE-SELF        evidence cites the write target while
                                   asserting an unrelated benefit
        PCX-E-EVIDENCE-STATE-ONLY  state evidence for an agent-discovered target
                                   or state evidence without a profile
        PCX-E-EVIDENCE-UNAVAILABLE metric unavailable, unreliable, missing or
                                   mismatched; never coerced to zero
        PCX-E-EVIDENCE-RULE        seed action without a usable catalog evidence_rule
        PCX-E-EVIDENCE-ROOT        file evidence not rooted at the target root
        PCX-E-EVIDENCE-TARGET      the target does not parse as a typed target

    Decision shape:
        @{ allowed = <bool>; code = <string>; reason = <text>; domain = <string|null> }
#>

Set-StrictMode -Version 2.0

$script:PcxEvidenceDomainsRelative = 'config/evidence-domains.json'
$script:PcxEvidenceDomains = $null
$script:PcxEvidenceAllowedCode = 'PCX-E-EVIDENCE-ALLOW'

# ---------------------------------------------------------------------------
# Shape helpers
# ---------------------------------------------------------------------------

function Get-PcxEvidenceMember {
    # Reads a member by case-insensitive name from a dictionary or an object.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    return (Get-PcxPolicyMember -Object $Object -Name $Name)
}

function Test-PcxEvidenceHasMember {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ($key -is [string] -and [string]::Equals($key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-PcxEvidenceTextPresent {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [string]) {
        return (-not [string]::IsNullOrWhiteSpace([string]$Value))
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return ($Value.Count -gt 0)
    }

    return $true
}

function Test-PcxEvidenceObject {
    # A non-empty profile/rule object: a dictionary with entries or an object
    # with at least one note/property member. Scalars never qualify.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) {
        return $false
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return ($Value.Count -gt 0)
    }

    $members = @(
        $Value.PSObject.Properties |
            Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' }
    )

    return ($members.Count -gt 0)
}

function New-PcxEvidenceResult {
    param(
        [Parameter(Mandatory = $true)][bool] $Allowed,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Domain
    )

    return [pscustomobject]@{
        allowed = $Allowed
        code    = $Code
        reason  = $Reason
        domain  = $Domain
    }
}

function New-PcxEvidenceDenial {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Domain
    )

    return New-PcxEvidenceResult -Allowed $false -Code $Code -Reason $Reason -Domain $Domain
}

function New-PcxEvidenceAllow {
    param(
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Domain
    )

    return New-PcxEvidenceResult -Allowed $true -Code $script:PcxEvidenceAllowedCode -Reason $Reason -Domain $Domain
}

# ---------------------------------------------------------------------------
# Bundled domain data
# ---------------------------------------------------------------------------

function Get-PcxEvidenceDomainsPath {
    $candidate = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', $script:PcxEvidenceDomainsRelative)
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-PcxEvidenceDomains {
    # Cached: bundled data, not machine state.
    if ($null -ne $script:PcxEvidenceDomains) {
        return $script:PcxEvidenceDomains
    }

    $document = Read-PcxJson -Path (Get-PcxEvidenceDomainsPath)
    $script:PcxEvidenceDomains = $document
    return $document
}

function Get-PcxEvidenceTargetDomain {
    # Returns the pinned domain string, or $null when the canonical target has
    # no declared mapping. Callers refuse on $null.
    param([Parameter(Mandatory = $true)][object] $Canonical)

    $data = Get-PcxEvidenceDomains

    switch ([string]$Canonical.kind) {
        'service' {
            $domain = [string](Get-PcxEvidenceMember -Object (Get-PcxEvidenceMember -Object $data -Name 'subsystems') -Name 'svc')
            if ([string]::IsNullOrWhiteSpace($domain)) { return $null }
            return $domain
        }
        'task' {
            $domain = [string](Get-PcxEvidenceMember -Object (Get-PcxEvidenceMember -Object $data -Name 'subsystems') -Name 'task')
            if ([string]::IsNullOrWhiteSpace($domain)) { return $null }
            return $domain
        }
        'registry' {
            $canonicalPath = [string]$Canonical.hive + '\' + [string]$Canonical.key
            foreach ($entry in @(Get-PcxEvidenceMember -Object $data -Name 'targets')) {
                if ($null -eq $entry) { continue }

                $configuredPath = [string](Get-PcxEvidenceMember -Object $entry -Name 'path')
                if (-not [string]::Equals($canonicalPath, $configuredPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $configuredName = [string](Get-PcxEvidenceMember -Object $entry -Name 'name')
                if (-not [string]::IsNullOrWhiteSpace($configuredName)) {
                    if ($null -eq $Canonical.name) { continue }
                    if (-not [string]::Equals([string]$Canonical.name, $configuredName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                }

                $domain = [string](Get-PcxEvidenceMember -Object $entry -Name 'domain')
                if ([string]::IsNullOrWhiteSpace($domain)) { return $null }
                return $domain
            }

            return $null
        }
        'file' {
            return $null
        }
    }

    return $null
}

function Test-PcxEvidenceSameTarget {
    param(
        [Parameter(Mandatory = $true)][object] $Left,
        [Parameter(Mandatory = $true)][object] $Right
    )

    if (-not [string]::Equals([string]$Left.kind, [string]$Right.kind, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    switch ([string]$Left.kind) {
        'registry' {
            $leftPath = [string]$Left.hive + '\' + [string]$Left.key
            $rightPath = [string]$Right.hive + '\' + [string]$Right.key
            if (-not [string]::Equals($leftPath, $rightPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }

            if ($null -ne $Left.name -and $null -ne $Right.name) {
                return [string]::Equals([string]$Left.name, [string]$Right.name, [System.StringComparison]::OrdinalIgnoreCase)
            }

            # Same key: a value inside it is the same address for self-citation.
            return $true
        }
        'service' { return [string]::Equals([string]$Left.name, [string]$Right.name, [System.StringComparison]::OrdinalIgnoreCase) }
        'task' { return [string]::Equals([string]$Left.path, [string]$Right.path, [System.StringComparison]::OrdinalIgnoreCase) }
        'file' { return [string]::Equals([string]$Left.path, [string]$Right.path, [System.StringComparison]::OrdinalIgnoreCase) }
    }

    return $false
}

function Test-PcxEvidenceNumeric {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        return $true
    }

    return $false
}

function Test-PcxEvidenceValueEqual {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Left,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Right
    )

    if ($Left -is [bool] -or $Right -is [bool]) {
        return ([bool]$Left -eq [bool]$Right)
    }

    return [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PcxEvidenceDomainInList {
    param(
        [Parameter(Mandatory = $true)][string] $Domain,
        [Parameter(Mandatory = $false)][AllowNull()][object] $List
    )

    foreach ($entry in @($List)) {
        if ($null -eq $entry) { continue }
        if ([string]::Equals($Domain, [string]$entry, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

# ---------------------------------------------------------------------------
# Public: the evidence gate
# ---------------------------------------------------------------------------

function Test-PcxEvidenceRef {
    <#
    .SYNOPSIS
        Decides whether one evidence ref may justify a write to one target.

    .DESCRIPTION
        Pure: no machine state is read. Every refusal is a structured result
        with a PCX-E-EVIDENCE-* code. Missing, unavailable, unreliable or
        mismatched values never become zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Evidence,
        [Parameter(Mandatory = $true)][string] $Origin,
        [Parameter(Mandatory = $false)][AllowNull()][object] $CatalogRule,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $canonical = $null
    try {
        $canonical = ConvertTo-PcxTarget -Target $Target
    }
    catch {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-TARGET' -Reason ("the write target does not parse: {0}" -f $_.Exception.Message)
    }

    $originText = ([string]$Origin).Trim().ToLowerInvariant()
    if ($originText -ne 'seed' -and $originText -ne 'agent-discovered') {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-SHAPE' -Reason "origin '$Origin' is not seed or agent-discovered."
    }

    if ($null -eq $Evidence) {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-SHAPE' -Reason 'evidence is required.'
    }

    $kind = ([string](Get-PcxEvidenceMember -Object $Evidence -Name 'kind')).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($kind)) {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-SHAPE' -Reason 'evidence.kind is required (telemetry or state).'
    }
    if ($kind -ne 'telemetry' -and $kind -ne 'state') {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-KIND' -Reason "unknown evidence kind '$kind'; expected telemetry or state."
    }

    # Status and value: unavailable, unreliable, missing or mismatched refuses.
    $status = ([string](Get-PcxEvidenceMember -Object $Evidence -Name 'status')).Trim().ToLowerInvariant()
    if ($status -ne 'measured') {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-UNAVAILABLE' -Reason "evidence status '$status' is not measured; unavailable values are never coerced to zero."
    }

    if (-not (Test-PcxEvidenceHasMember -Object $Evidence -Name 'value')) {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-UNAVAILABLE' -Reason 'evidence.value is missing.'
    }

    $value = Get-PcxEvidenceMember -Object $Evidence -Name 'value'
    if ($null -eq $value) {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-UNAVAILABLE' -Reason 'evidence.value is null; a missing value is not zero.'
    }

    if (Test-PcxEvidenceHasMember -Object $Evidence -Name 'expected') {
        $expected = Get-PcxEvidenceMember -Object $Evidence -Name 'expected'
        if ($null -ne $expected -and -not (Test-PcxEvidenceValueEqual -Left $value -Right $expected)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-UNAVAILABLE' -Reason 'evidence.value does not match the expected value.'
        }
    }

    $metric = [string](Get-PcxEvidenceMember -Object $Evidence -Name 'metric')
    $domain = [string](Get-PcxEvidenceMember -Object $Evidence -Name 'domain')
    $window = Get-PcxEvidenceMember -Object $Evidence -Name 'window'

    if ($kind -eq 'telemetry') {
        if ([string]::IsNullOrWhiteSpace($metric)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-SHAPE' -Reason 'a telemetry ref requires metric.'
        }
        if ($null -eq $window -or ($window -is [string] -and [string]::IsNullOrWhiteSpace([string]$window))) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-SHAPE' -Reason 'a telemetry ref requires window.'
        }
        if ([string]::IsNullOrWhiteSpace($domain)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-DOMAIN' -Reason 'a telemetry ref requires domain.'
        }
        if (-not (Test-PcxEvidenceNumeric -Value $value)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-UNAVAILABLE' -Reason 'a telemetry value must be numeric.'
        }
    }

    $targetDomain = Get-PcxEvidenceTargetDomain -Canonical $canonical

    # Self-citation: evidence that cites the write target while asserting a
    # benefit in another domain proves nothing about this write.
    $cited = Get-PcxEvidenceMember -Object $Evidence -Name 'target'
    if ($null -eq $cited) {
        $cited = Get-PcxEvidenceMember -Object $Evidence -Name 'cites'
    }
    if ($null -ne $cited) {
        $citedCanonical = $null
        try {
            $citedCanonical = ConvertTo-PcxTarget -Target $cited
        }
        catch {
            $citedCanonical = $null
        }

        if ($null -ne $citedCanonical -and (Test-PcxEvidenceSameTarget -Left $citedCanonical -Right $canonical)) {
            if ($null -ne $targetDomain) {
                $benefit = [string](Get-PcxEvidenceMember -Object $Evidence -Name 'benefit')
                if (-not [string]::IsNullOrWhiteSpace($benefit) -and
                    -not [string]::Equals($benefit, $targetDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-SELF' -Reason "the evidence cites the write target but asserts a '$benefit' benefit, not the target's '$targetDomain' domain."
                }

                if (-not [string]::IsNullOrWhiteSpace($domain) -and
                    -not [string]::Equals($domain, $targetDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-SELF' -Reason "the evidence cites the write target while measuring the unrelated '$domain' domain."
                }
            }
        }
    }

    # A file target must tie the metric to the same root.
    if ([string]$canonical.kind -eq 'file') {
        $root = [string](Get-PcxEvidenceMember -Object $Evidence -Name 'root')
        if ([string]::IsNullOrWhiteSpace($root)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-ROOT' -Reason 'a file target requires evidence.root tied to the target root.'
        }

        $rootCanonical = $null
        try {
            $rootCanonical = ConvertTo-PcxPolicyCanonicalPath -Path $root
        }
        catch {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-ROOT' -Reason "evidence.root '$root' is not a valid absolute root."
        }

        if (-not (Test-PcxPolicyPathUnder -Path ([string]$canonical.path) -Root $rootCanonical)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-ROOT' -Reason "the file target is outside evidence.root '$rootCanonical'."
        }
    }

    # State evidence always needs an observed value and a profile. It is never
    # trusted on the agent's word alone.
    $stateProfile = $null
    if ($kind -eq 'state') {
        $stateProfile = Get-PcxEvidenceMember -Object $Evidence -Name 'profile'
        if (-not (Test-PcxEvidenceObject -Value $stateProfile)) {
            $stateProfile = $Profile
        }
        if (-not (Test-PcxEvidenceObject -Value $stateProfile)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-STATE-ONLY' -Reason 'state evidence requires a non-empty profile.'
        }
    }

    if ($originText -eq 'seed') {
        $rule = Get-PcxEvidenceMember -Object $CatalogRule -Name 'evidence_rule'
        if (-not (Test-PcxEvidenceObject -Value $rule)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-RULE' -Reason 'a seed action requires a catalog evidence_rule.'
        }

        $ruleKind = ([string](Get-PcxEvidenceMember -Object $rule -Name 'kind')).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($ruleKind) -and $ruleKind -ne $kind) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-RULE' -Reason "the seed rule expects '$ruleKind' evidence but received '$kind'."
        }

        $ruleMetric = [string](Get-PcxEvidenceMember -Object $rule -Name 'metric')
        if (-not [string]::IsNullOrWhiteSpace($ruleMetric) -and
            -not [string]::Equals($ruleMetric, $metric, [System.StringComparison]::OrdinalIgnoreCase)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-RULE' -Reason "the seed rule expects metric '$ruleMetric' but received '$metric'."
        }

        $allowedDomains = @()
        $ruleDomain = [string](Get-PcxEvidenceMember -Object $rule -Name 'domain')
        if (-not [string]::IsNullOrWhiteSpace($ruleDomain)) {
            $allowedDomains += $ruleDomain
        }
        foreach ($allowedDomain in @(Get-PcxEvidenceMember -Object $rule -Name 'domains')) {
            if ($null -ne $allowedDomain -and -not [string]::IsNullOrWhiteSpace([string]$allowedDomain)) {
                $allowedDomains += [string]$allowedDomain
            }
        }

        if ($allowedDomains.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace($domain)) {
                return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-DOMAIN' -Reason 'the seed rule requires a domain but the evidence has none.'
            }
            if (-not (Test-PcxEvidenceDomainInList -Domain $domain -List $allowedDomains)) {
                return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-DOMAIN' -Reason "the evidence domain '$domain' is not allowed by the seed rule."
            }
        }

        $resultDomain = $domain
        if ([string]::IsNullOrWhiteSpace($resultDomain)) { $resultDomain = $targetDomain }
        return New-PcxEvidenceAllow -Reason 'the seed evidence_rule accepts this evidence.' -Domain $resultDomain
    }

    # Agent-discovered.
    if ($kind -eq 'state') {
        return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-STATE-ONLY' -Reason 'an agent-discovered target requires telemetry evidence; state-only evidence is catalog-only.'
    }

    if ([string]$canonical.kind -ne 'file') {
        if ([string]::IsNullOrWhiteSpace($targetDomain)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-DOMAIN' -Reason 'the target has no declared evidence domain; an undeclared mapping refuses.'
        }
        if (-not [string]::Equals($domain, $targetDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
            return New-PcxEvidenceDenial -Code 'PCX-E-EVIDENCE-DOMAIN' -Reason "the evidence domain '$domain' does not match the target domain '$targetDomain'." -Domain $domain
        }
    }

    return New-PcxEvidenceAllow -Reason 'the telemetry evidence matches the pinned target domain.' -Domain $targetDomain
}
