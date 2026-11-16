<#
.SYNOPSIS
    Default-deny target policy engine and canonical target grammar.

.DESCRIPTION
    This file answers one question for every typed target: may pcx write it?
    It is pure by construction: the engine reads no machine state. Every live
    fact arrives through the -Profile object, so the same code runs against a
    fixture profile in tests and against the detected environment later. The
    only file it opens is the bundled data file config/protected/protected-
    targets.json (data, not machine state).

    Public surface contributed to the Pcx module (exactly these two names):
        ConvertTo-PcxTarget   canonicalizes a target or throws a grammar error
        Test-PcxTarget        the gate: returns a structured decision

    Decision shape (never a bare boolean):
        @{ allowed = <bool>; code = <PCX-POLICY-*|PCX-POLICY-ALLOW>; reason = <text>; target = <canonical|null> }

    Profile shape (all facts are injected; a missing fact is unknown):
        managed       bool or $null-unknown
        sMode         bool or $null-unknown
        devDrive      bool or $null-unknown
        anticheat     bool or $null-unknown
        serviceFacts  map: "<service name>" -> @{ dependents; listeningPorts; childProcesses }
        environment   map: "LOCALAPPDATA" -> "<absolute path>" (used only to expand
                      %TOKEN% placeholders in the protected file roots)

    Fail-closed rule: for every denying rule, a fact that is missing, $null or
    not a known boolean/integer is treated as "cannot prove safe" and the target
    is refused. A desktop fixture therefore passes managed=false, sMode=false,
    devDrive=false and anticheat=false explicitly; an unknown profile refuses
    every write.

    Decision order (deny wins over allow, always):
        1. grammar
        2. whole-machine gates: managed, S Mode, Dev Drive, anticheat
        3. protected lists: TrustedInstaller (PCX-POLICY-ACL), boot chain,
           security, anticheat target membership
        4. kind-specific provider constraints and blast radius
        5. the allow surface (HKCU subtrees, one HKLM value, a1/a2 roots,
           non-system tasks that only disable)

    Blast radius choice: a service is refused when the profile cannot prove it
    has zero dependents, zero listening ports and zero child processes. The
    plan allowed either "refuse" or "demote to manual"; the policy layer only
    returns allowed/denied, so it refuses and the caller (table / plan) may
    surface the refusal as a manual finding. This keeps the gate monotonic:
    a target that policy refuses can never be applied by accident.

    TrustedInstaller ownership is data, not a live ACL read: the engine cannot
    inspect an ACL without machine access, so the protected data file lists the
    keys whose owner is TrustedInstaller and a match returns PCX-POLICY-ACL.
    Reparse-point *detection* also needs machine access; the policy refuses a
    target that declares itself a reparse point, and the file provider's walk
    performs the actual detection.

    Trailing separators: a registry key and a task path must not carry one
    (ambiguous address), so that form is a grammar refusal. A file path may
    carry one (a directory is a legitimate target) and is normalized by
    trimming it.
#>

Set-StrictMode -Version 2.0

$script:PcxPolicyConfigRelative = 'config/protected/protected-targets.json'
$script:PcxPolicyData = $null
$script:PcxPolicyDataPath = $null
$script:PcxPolicyAllowedCode = 'PCX-POLICY-ALLOW'

# ---------------------------------------------------------------------------
# Shape helpers (accept ordered maps, hashtables and PSCustomObjects)
# ---------------------------------------------------------------------------

function Get-PcxPolicyMember {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ($key -is [string] -and [string]::Equals($key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Object[$key]
            }
        }
        return $null
    }

    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $property.Value
        }
    }

    return $null
}

function Get-PcxPolicyBoolean {
    # Returns $true, $false, or $null when the fact is absent or unreadable.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $value = Get-PcxPolicyMember -Object $Object -Name $Name
    if ($null -eq $value) {
        return $null
    }

    if ($value -is [bool]) {
        return $value
    }

    $text = ([string]$value).Trim()
    if ($text -ieq 'true') { return $true }
    if ($text -ieq 'false') { return $false }
    return $null
}

function Get-PcxPolicyInteger {
    # Returns an integer, or $null when the fact is absent or not numeric.
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $value = Get-PcxPolicyMember -Object $Object -Name $Name
    if ($null -eq $value) {
        return $null
    }

    try {
        return [int]$value
    }
    catch {
        return $null
    }
}

function Stop-PcxPolicyGrammar {
    param([Parameter(Mandatory = $true)][string] $Message)

    throw [System.ArgumentException]::new(('PCX-POLICY-GRAMMAR: {0}' -f $Message))
}

function New-PcxPolicyResult {
    param(
        [Parameter(Mandatory = $true)][bool] $Allowed,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target
    )

    return [pscustomobject]@{
        allowed = $Allowed
        code    = $Code
        reason  = $Reason
        target  = $Target
    }
}

function New-PcxPolicyDenial {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target
    )

    return New-PcxPolicyResult -Allowed $false -Code $Code -Reason $Reason -Target $Target
}

function New-PcxPolicyAllow {
    param(
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target
    )

    return New-PcxPolicyResult -Allowed $true -Code $script:PcxPolicyAllowedCode -Reason $Reason -Target $Target
}

# ---------------------------------------------------------------------------
# Bundled policy data
# ---------------------------------------------------------------------------

function Get-PcxPolicyDataPath {
    $candidate = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', $script:PcxPolicyConfigRelative)
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-PcxPolicyData {
    # Cached: the data file is bundled with the product and does not change at
    # runtime. Reading it is data ingestion, not machine-state observation.
    if ($null -ne $script:PcxPolicyData) {
        return $script:PcxPolicyData
    }

    $path = Get-PcxPolicyDataPath
    $document = Read-PcxJson -Path $path
    $script:PcxPolicyDataPath = $path
    $script:PcxPolicyData = $document
    return $document
}

# ---------------------------------------------------------------------------
# Grammar helpers
# ---------------------------------------------------------------------------

function Test-PcxPolicyHasWildcard {
    param([Parameter(Mandatory = $true)][string] $Text)

    return ($Text.Contains('*') -or $Text.Contains('?'))
}

function Test-PcxPolicyHasParentSegment {
    param([Parameter(Mandatory = $true)][string] $Text)

    return [regex]::IsMatch($Text, '(^|[\\/])\.\.([\\/]|$)')
}

function ConvertTo-PcxPolicyHive {
    param([Parameter(Mandatory = $true)][string] $Hive)

    switch ($Hive.ToLowerInvariant()) {
        'hkcu' { return 'HKCU' }
        'hkey_current_user' { return 'HKCU' }
        'hklm' { return 'HKLM' }
        'hkey_local_machine' { return 'HKLM' }
        'hku' { return 'HKU' }
        'hkey_users' { return 'HKU' }
        'hkcc' { return 'HKCC' }
        'hkey_current_config' { return 'HKCC' }
        'hkcr' {
            Stop-PcxPolicyGrammar 'HKCR is not an addressable hive.'
        }
        'hkey_classes_root' {
            Stop-PcxPolicyGrammar 'HKEY_CLASSES_ROOT is not an addressable hive.'
        }
    }

    Stop-PcxPolicyGrammar "unknown registry hive '$Hive'."
}

function ConvertTo-PcxPolicyCanonicalPath {
    # Pure path normalization: no stat, no existence probe.
    param([Parameter(Mandatory = $true)][string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $full = $full -replace '/', '\'
    $full = $full.ToLowerInvariant()
    if ($full.Length -gt 3 -and $full.EndsWith('\')) {
        $full = $full.TrimEnd('\')
    }

    return $full
}

function Test-PcxPolicyPathUnder {
    # Boundary-aware containment: "C:\a" contains "C:\a\b" but not "C:\ab".
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Root)) {
        return $false
    }

    $candidate = $Path.TrimEnd('\')
    $bound = $Root.TrimEnd('\')

    if ([string]::Equals($candidate, $bound, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $candidate.StartsWith($bound + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PcxPolicyNameInList {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $false)][AllowNull()][object] $List
    )

    foreach ($entry in @($List)) {
        if ($null -eq $entry) { continue }
        if ([string]::Equals([string]$entry, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Resolve-PcxPolicyRoot {
    # Expands %TOKEN% placeholders from the injected profile environment. An
    # unresolved token or a non-absolute result returns $null (fail closed).
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment
    )

    $text = $Root
    $pattern = '%([A-Za-z0-9_]+)%'
    $placeholders = [regex]::Matches($text, $pattern)
    foreach ($placeholder in $placeholders) {
        $token = $placeholder.Groups[1].Value
        $value = Get-PcxPolicyMember -Object $Environment -Name $token
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            return $null
        }
        $text = $text.Replace($placeholder.Value, [string]$value)
    }

    if ($text.Contains('%')) {
        return $null
    }

    if (-not [System.IO.Path]::IsPathRooted($text)) {
        return $null
    }

    try {
        return ConvertTo-PcxPolicyCanonicalPath -Path $text
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Canonical target parser
# ---------------------------------------------------------------------------

function ConvertTo-PcxPolicyRegistryTarget {
    param([Parameter(Mandatory = $true)][string] $Text)

    $work = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($work)) {
        Stop-PcxPolicyGrammar 'a registry target is empty.'
    }
    if (Test-PcxPolicyHasWildcard -Text $work) {
        Stop-PcxPolicyGrammar "registry target '$work' contains a wildcard."
    }
    if ($work -match '^(?i)Registry::') {
        Stop-PcxPolicyGrammar 'Registry:: provider paths are not addressable.'
    }
    if ($work -match '^(?i)(hkcr|hkey_classes_root)(\\|$|::)') {
        Stop-PcxPolicyGrammar 'HKCR and HKEY_CLASSES_ROOT are not addressable hives.'
    }

    $work = $work -replace '/', '\'
    if (Test-PcxPolicyHasParentSegment -Text $work) {
        Stop-PcxPolicyGrammar "registry target '$Text' contains a '..' segment."
    }

    $name = $null
    $separatorIndex = $work.IndexOf('::', [System.StringComparison]::Ordinal)
    if ($separatorIndex -ge 0) {
        $name = $work.Substring($separatorIndex + 2).Trim()
        $work = $work.Substring(0, $separatorIndex)
        if ([string]::IsNullOrEmpty($name)) {
            Stop-PcxPolicyGrammar 'a registry value name after :: is empty.'
        }
        if ($name.Contains('\')) {
            Stop-PcxPolicyGrammar "registry value name '$name' must not contain a separator."
        }
        if (Test-PcxPolicyHasWildcard -Text $name) {
            Stop-PcxPolicyGrammar "registry value name '$name' contains a wildcard."
        }
        $name = $name.ToLowerInvariant()
    }

    if ($work.EndsWith('\')) {
        Stop-PcxPolicyGrammar "registry target '$Text' has a trailing separator."
    }

    $parts = $work -split '\\', 2
    # Accept the PowerShell provider form "HKCU:\Software" as well as "HKCU\Software".
    $hiveRaw = $parts[0].TrimEnd(':')
    $hive = ConvertTo-PcxPolicyHive -Hive $hiveRaw
    $key = ''
    if ($parts.Count -gt 1) {
        $key = $parts[1].Trim('\').ToLowerInvariant()
    }

    return [pscustomobject]@{
        kind = 'registry'
        hive = $hive
        key  = $key
        name = $name
        path = ($hive + '\' + $key)
    }
}

function ConvertTo-PcxPolicyServiceTarget {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Start
    )

    $name = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        Stop-PcxPolicyGrammar 'a service target is empty.'
    }
    if (Test-PcxPolicyHasWildcard -Text $name) {
        Stop-PcxPolicyGrammar "service target '$name' contains a wildcard."
    }
    if ($name.Contains('\') -or $name.Contains('/')) {
        Stop-PcxPolicyGrammar "service target '$name' must not contain a path separator."
    }
    if (Test-PcxPolicyHasParentSegment -Text $name) {
        Stop-PcxPolicyGrammar "service target '$name' contains a '..' segment."
    }
    $name = $name.ToLowerInvariant()

    $startValue = $null
    if ($null -ne $Start -and -not ($Start -is [string] -and [string]::IsNullOrWhiteSpace([string]$Start))) {
        try {
            $startValue = [int]$Start
        }
        catch {
            Stop-PcxPolicyGrammar "service Start '$Start' is not an integer."
        }
    }

    return [pscustomobject]@{
        kind  = 'service'
        name  = $name
        start = $startValue
    }
}

function ConvertTo-PcxPolicyTaskTarget {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Enabled
    )

    $path = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path)) {
        Stop-PcxPolicyGrammar 'a task target is empty.'
    }
    if (Test-PcxPolicyHasWildcard -Text $path) {
        Stop-PcxPolicyGrammar "task target '$path' contains a wildcard."
    }

    $path = $path -replace '/', '\'
    if (Test-PcxPolicyHasParentSegment -Text $path) {
        Stop-PcxPolicyGrammar "task target '$path' contains a '..' segment."
    }
    if ($path.EndsWith('\')) {
        Stop-PcxPolicyGrammar "task target '$path' has a trailing separator."
    }
    if (-not $path.StartsWith('\')) {
        Stop-PcxPolicyGrammar "task target '$path' must start with a backslash."
    }
    $path = $path.ToLowerInvariant()
    if ($path -eq '\') {
        Stop-PcxPolicyGrammar 'a task target must contain a task name.'
    }

    $enabledValue = $null
    if ($Enabled -is [bool]) {
        $enabledValue = $Enabled
    }

    return [pscustomobject]@{
        kind    = 'task'
        path    = $path
        enabled = $enabledValue
    }
}

function ConvertTo-PcxPolicyFileTarget {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Role,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Reparse
    )

    $pathText = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($pathText)) {
        Stop-PcxPolicyGrammar 'a file target is empty.'
    }
    if (Test-PcxPolicyHasWildcard -Text $pathText) {
        Stop-PcxPolicyGrammar "file target '$pathText' contains a wildcard."
    }
    if (Test-PcxPolicyHasParentSegment -Text $pathText) {
        Stop-PcxPolicyGrammar "file target '$pathText' contains a '..' segment."
    }
    if (-not [System.IO.Path]::IsPathRooted($pathText)) {
        Stop-PcxPolicyGrammar "file target '$pathText' must be an absolute path."
    }

    $roleValue = 'a1'
    if ($null -ne $Role -and -not [string]::IsNullOrWhiteSpace([string]$Role)) {
        $roleValue = ([string]$Role).Trim().ToLowerInvariant()
    }
    if ($roleValue -ne 'a1' -and $roleValue -ne 'quarantine') {
        Stop-PcxPolicyGrammar "unknown file role '$roleValue'; expected a1 or quarantine."
    }

    $reparseValue = $false
    if ($Reparse -is [bool] -and $Reparse) {
        $reparseValue = $true
    }

    try {
        $canonicalPath = ConvertTo-PcxPolicyCanonicalPath -Path $pathText
    }
    catch {
        Stop-PcxPolicyGrammar "file target '$pathText' is not a valid absolute path."
    }

    return [pscustomobject]@{
        kind    = 'file'
        path    = $canonicalPath
        role    = $roleValue
        reparse = $reparseValue
    }
}

function ConvertFrom-PcxPolicyFileString {
    param([Parameter(Mandatory = $true)][string] $Text)

    $rest = $Text
    $role = 'a1'
    if ($rest -match '^(?i)a1:(.*)$') {
        $role = 'a1'
        $rest = $Matches[1]
    }
    elseif ($rest -match '^(?i)quarantine:(.*)$') {
        $role = 'quarantine'
        $rest = $Matches[1]
    }

    return ConvertTo-PcxPolicyFileTarget -Path $rest -Role $role -Reparse $null
}

function ConvertFrom-PcxPolicyTargetString {
    param([Parameter(Mandatory = $true)][string] $Text)

    $trimmed = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Stop-PcxPolicyGrammar 'a target is required.'
    }

    if ($trimmed -match '^(?i)(reg|svc|task|file):(.*)$') {
        $scheme = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2]
    }
    elseif ($trimmed -match '^(?i)(registry::|hkcr|hkey_classes_root)(\\|$|::|:)') {
        Stop-PcxPolicyGrammar 'HKCR and Registry:: paths are not addressable.'
    }
    elseif ($trimmed -match '^(?i)(hkcu|hklm|hku|hkcc|hkey_[a-z_]+)(\\|$|::|:)') {
        $scheme = 'reg'
        $rest = $trimmed
    }
    else {
        Stop-PcxPolicyGrammar "target '$trimmed' has no recognisable scheme; use reg:, svc:, task: or file:."
    }

    switch ($scheme) {
        'reg' { return ConvertTo-PcxPolicyRegistryTarget -Text $rest }
        'svc' { return ConvertTo-PcxPolicyServiceTarget -Text $rest -Start $null }
        'task' { return ConvertTo-PcxPolicyTaskTarget -Text $rest -Enabled $null }
        'file' { return ConvertFrom-PcxPolicyFileString -Text $rest }
    }

    Stop-PcxPolicyGrammar "unknown target scheme '$scheme'."
}

function ConvertTo-PcxTarget {
    <#
    .SYNOPSIS
        Canonicalizes a typed target or throws PCX-POLICY-GRAMMAR.

    .DESCRIPTION
        Accepts a scheme string (reg:, svc:, task:, file:) or an object with a
        Kind member naming one of registry, service, task or file. Bare strings
        that start with a hive alias are treated as registry targets. Every
        alias is canonicalized, case and separators are normalized, and a
        trailing separator on a registry key or task path, a '..' segment, a
        wildcard or a rejected hive (HKCR / HKEY_CLASSES_ROOT / Registry::)
        raises a grammar error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target
    )

    if ($null -eq $Target) {
        Stop-PcxPolicyGrammar 'a target is required.'
    }

    if ($Target -is [string]) {
        return ConvertFrom-PcxPolicyTargetString -Text ([string]$Target)
    }

    $kindRaw = Get-PcxPolicyMember -Object $Target -Name 'Kind'
    if ($null -eq $kindRaw -or [string]::IsNullOrWhiteSpace([string]$kindRaw)) {
        Stop-PcxPolicyGrammar 'target.Kind is required (registry, service, task or file).'
    }
    $kind = ([string]$kindRaw).Trim().ToLowerInvariant()

    switch ($kind) {
        'registry' {
            $pathRaw = Get-PcxPolicyMember -Object $Target -Name 'Path'
            if ($null -eq $pathRaw -or [string]::IsNullOrWhiteSpace([string]$pathRaw)) {
                Stop-PcxPolicyGrammar 'target.Path is required for a registry target.'
            }

            $text = [string]$pathRaw
            $nameRaw = Get-PcxPolicyMember -Object $Target -Name 'Name'
            if ($null -ne $nameRaw -and -not [string]::IsNullOrWhiteSpace([string]$nameRaw) -and $text.IndexOf('::', [System.StringComparison]::Ordinal) -lt 0) {
                $text = $text + '::' + [string]$nameRaw
            }

            return ConvertTo-PcxPolicyRegistryTarget -Text $text
        }
        'service' {
            $nameRaw = Get-PcxPolicyMember -Object $Target -Name 'Name'
            if ($null -eq $nameRaw -or [string]::IsNullOrWhiteSpace([string]$nameRaw)) {
                Stop-PcxPolicyGrammar 'target.Name is required for a service target.'
            }

            return ConvertTo-PcxPolicyServiceTarget -Text ([string]$nameRaw) -Start (Get-PcxPolicyMember -Object $Target -Name 'Start')
        }
        'task' {
            $pathRaw = Get-PcxPolicyMember -Object $Target -Name 'Path'
            if ($null -eq $pathRaw -or [string]::IsNullOrWhiteSpace([string]$pathRaw)) {
                Stop-PcxPolicyGrammar 'target.Path is required for a task target.'
            }

            return ConvertTo-PcxPolicyTaskTarget -Text ([string]$pathRaw) -Enabled (Get-PcxPolicyMember -Object $Target -Name 'Enabled')
        }
        'file' {
            $pathRaw = Get-PcxPolicyMember -Object $Target -Name 'Path'
            if ($null -eq $pathRaw -or [string]::IsNullOrWhiteSpace([string]$pathRaw)) {
                Stop-PcxPolicyGrammar 'target.Path is required for a file target.'
            }

            $reparseRaw = Get-PcxPolicyMember -Object $Target -Name 'Reparse'
            if ($null -eq $reparseRaw) {
                $reparseRaw = Get-PcxPolicyMember -Object $Target -Name 'IsReparsePoint'
            }

            return ConvertTo-PcxPolicyFileTarget -Path ([string]$pathRaw) -Role (Get-PcxPolicyMember -Object $Target -Name 'Role') -Reparse $reparseRaw
        }
    }

    Stop-PcxPolicyGrammar "unknown target kind '$kind'; supported: registry, service, task, file."
}

# ---------------------------------------------------------------------------
# Rule helpers
# ---------------------------------------------------------------------------

function Test-PcxPolicyRegistryUnderAny {
    param(
        [Parameter(Mandatory = $true)][object] $Canonical,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Prefixes
    )

    $canonicalPath = [string]$Canonical.hive + '\' + [string]$Canonical.key
    foreach ($prefix in @($Prefixes)) {
        if ($null -eq $prefix) { continue }
        $normalized = ([string]$prefix) -replace '/', '\'
        $normalized = $normalized.TrimEnd('\')
        if (Test-PcxPolicyPathUnder -Path $canonicalPath -Root $normalized) {
            return $true
        }
    }

    return $false
}

function Test-PcxPolicyHklmValueAllowed {
    param(
        [Parameter(Mandatory = $true)][object] $Canonical,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Data
    )

    if ($null -eq $Canonical.name) {
        return $false
    }

    $registryAllow = Get-PcxPolicyMember -Object $Data -Name 'registryAllow'
    $canonicalPath = [string]$Canonical.hive + '\' + [string]$Canonical.key

    foreach ($entry in @(Get-PcxPolicyMember -Object $registryAllow -Name 'hklmValues')) {
        if ($null -eq $entry) { continue }
        $path = [string](Get-PcxPolicyMember -Object $entry -Name 'path')
        $name = [string](Get-PcxPolicyMember -Object $entry -Name 'name')
        $normalized = $path -replace '/', '\'
        $normalized = $normalized.TrimEnd('\')

        if ([string]::Equals($canonicalPath, $normalized, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$Canonical.name, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-PcxPolicyRegistry {
    param(
        [Parameter(Mandatory = $true)][object] $Canonical,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Data
    )

    $registry = Get-PcxPolicyMember -Object $Data -Name 'registry'

    # Deny wins over allow: the protected lists are evaluated first, so a
    # boot-chain key never reaches the allow surface even if it were listed.
    if (Test-PcxPolicyRegistryUnderAny -Canonical $Canonical -Prefixes (Get-PcxPolicyMember -Object $registry -Name 'trustedInstallerKeys')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-ACL' -Reason 'the key is owned by TrustedInstaller; pcx never writes it.' -Target $Canonical
    }
    if (Test-PcxPolicyRegistryUnderAny -Canonical $Canonical -Prefixes (Get-PcxPolicyMember -Object $registry -Name 'bootChainKeys')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-BOOTCHAIN' -Reason 'the key belongs to the boot chain; a wrong value can prevent the machine from booting.' -Target $Canonical
    }
    if (Test-PcxPolicyRegistryUnderAny -Canonical $Canonical -Prefixes (Get-PcxPolicyMember -Object $registry -Name 'securityKeys')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-SECURITY' -Reason 'the key configures a security subsystem and is manual-only.' -Target $Canonical
    }

    $anticheat = Get-PcxPolicyMember -Object $Data -Name 'anticheat'
    if (Test-PcxPolicyRegistryUnderAny -Canonical $Canonical -Prefixes (Get-PcxPolicyMember -Object $anticheat -Name 'registryKeys')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-ANTICHEAT' -Reason 'the key belongs to an anticheat client; modifying it can block a protected game.' -Target $Canonical
    }

    if ($Canonical.hive -eq 'HKCU') {
        $registryAllow = Get-PcxPolicyMember -Object $Data -Name 'registryAllow'
        $allowed = $false
        foreach ($subkey in @(Get-PcxPolicyMember -Object $registryAllow -Name 'hkcuSubkeys')) {
            if ($null -eq $subkey) { continue }
            $normalized = ([string]$subkey) -replace '/', '\'
            $normalized = $normalized.Trim('\')
            if (Test-PcxPolicyPathUnder -Path ([string]$Canonical.key) -Root $normalized) {
                $allowed = $true
                break
            }
        }

        if (-not $allowed) {
            return New-PcxPolicyDenial -Code 'PCX-POLICY-HKCU-DEFAULT-DENY' -Reason 'HKCU is default-deny; the key is outside the enumerated writable subtrees.' -Target $Canonical
        }
        if ($null -eq $Canonical.name) {
            return New-PcxPolicyDenial -Code 'PCX-POLICY-REGISTRY-VALUE' -Reason 'registry writes are value-level only; a key without a value name is not writable.' -Target $Canonical
        }

        return New-PcxPolicyAllow -Reason 'the value is inside an enumerated writable HKCU subtree.' -Target $Canonical
    }

    if ($Canonical.hive -eq 'HKLM') {
        if (Test-PcxPolicyHklmValueAllowed -Canonical $Canonical -Data $Data) {
            return New-PcxPolicyAllow -Reason 'the value is the single enumerated writable HKLM value.' -Target $Canonical
        }

        return New-PcxPolicyDenial -Code 'PCX-POLICY-HKLM-VALUE' -Reason 'HKLM writes are value-level only; the target is not the enumerated HAGS value and no HKLM subtree is writable.' -Target $Canonical
    }

    return New-PcxPolicyDenial -Code 'PCX-POLICY-HIVE' -Reason "the '$($Canonical.hive)' hive is not a writable surface." -Target $Canonical
}

function Test-PcxPolicyService {
    param(
        [Parameter(Mandatory = $true)][object] $Canonical,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Data,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $services = Get-PcxPolicyMember -Object $Data -Name 'services'
    $anticheat = Get-PcxPolicyMember -Object $Data -Name 'anticheat'

    if (Test-PcxPolicyNameInList -Name ([string]$Canonical.name) -List (Get-PcxPolicyMember -Object $services -Name 'bootChain')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-BOOTCHAIN' -Reason 'the service is part of the boot chain.' -Target $Canonical
    }
    if (Test-PcxPolicyNameInList -Name ([string]$Canonical.name) -List (Get-PcxPolicyMember -Object $services -Name 'security')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-SECURITY' -Reason 'the service is a security component and is manual-only.' -Target $Canonical
    }
    if (Test-PcxPolicyNameInList -Name ([string]$Canonical.name) -List (Get-PcxPolicyMember -Object $services -Name 'kernelDrivers')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-DRIVER' -Reason 'the service is a kernel driver.' -Target $Canonical
    }
    if (Test-PcxPolicyNameInList -Name ([string]$Canonical.name) -List (Get-PcxPolicyMember -Object $anticheat -Name 'services')) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-ANTICHEAT' -Reason 'the service belongs to an anticheat client; modifying it can block a protected game.' -Target $Canonical
    }

    # Provider-level constraint: only Manual (3) or Disabled (4) are ever a
    # legal service write. Enabled, boot or system start types and an unknown
    # start all refuse.
    if ($null -eq $Canonical.start -or ($Canonical.start -ne 3 -and $Canonical.start -ne 4)) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-SERVICE-START' -Reason 'a service write may only set Start to 3 (Manual) or 4 (Disabled).' -Target $Canonical
    }

    # Blast radius: prove the service has nothing depending on it. A missing or
    # unknown fact cannot prove that, so it refuses (fail closed).
    $facts = Get-PcxPolicyMember -Object (Get-PcxPolicyMember -Object $Profile -Name 'serviceFacts') -Name ([string]$Canonical.name)
    if ($null -eq $facts) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-BLAST-RADIUS' -Reason 'the profile has no facts for this service; it cannot be proven to have zero dependents.' -Target $Canonical
    }

    $dependents = Get-PcxPolicyInteger -Object $facts -Name 'dependents'
    $listeningPorts = Get-PcxPolicyInteger -Object $facts -Name 'listeningPorts'
    $childProcesses = Get-PcxPolicyInteger -Object $facts -Name 'childProcesses'

    if ($null -eq $dependents -or $null -eq $listeningPorts -or $null -eq $childProcesses) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-BLAST-RADIUS' -Reason 'the profile facts for this service are incomplete; blast radius cannot be ruled out.' -Target $Canonical
    }
    if ($dependents -gt 0) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-BLAST-RADIUS' -Reason "the service has $dependents running dependent(s); changing it can break them." -Target $Canonical
    }
    if ($listeningPorts -gt 0 -or $childProcesses -gt 0) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-BLAST-RADIUS' -Reason 'the service holds a listening port or child processes; blast radius cannot be ruled out.' -Target $Canonical
    }

    return New-PcxPolicyAllow -Reason 'the service is not protected and has no measurable blast radius.' -Target $Canonical
}

function Test-PcxPolicyTask {
    param(
        [Parameter(Mandatory = $true)][object] $Canonical,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Data
    )

    $tasks = Get-PcxPolicyMember -Object $Data -Name 'tasks'
    $systemPrefix = [string](Get-PcxPolicyMember -Object $tasks -Name 'systemPrefix')

    if (Test-PcxPolicyPathUnder -Path ([string]$Canonical.path) -Root $systemPrefix) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-TASK-SYSTEM' -Reason 'tasks under \Microsoft\Windows\ are system tasks and are never touched.' -Target $Canonical
    }

    $anticheat = Get-PcxPolicyMember -Object $Data -Name 'anticheat'
    foreach ($prefix in @(Get-PcxPolicyMember -Object $anticheat -Name 'taskPrefixes')) {
        if ($null -eq $prefix) { continue }
        if (Test-PcxPolicyPathUnder -Path ([string]$Canonical.path) -Root ([string]$prefix)) {
            return New-PcxPolicyDenial -Code 'PCX-POLICY-ANTICHEAT' -Reason 'the task belongs to an anticheat client.' -Target $Canonical
        }
    }

    # Enabling is never allowed. A missing enabled fact refuses as well.
    if ($Canonical.enabled -ne $false) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-TASK-ENABLE' -Reason 'a task write may only disable an existing task; enabling is never allowed.' -Target $Canonical
    }

    return New-PcxPolicyAllow -Reason 'the task is not a system or anticheat task and the write only disables it.' -Target $Canonical
}

function Test-PcxPolicyFile {
    param(
        [Parameter(Mandatory = $true)][object] $Canonical,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Data,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    if ($Canonical.reparse) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-REPARSE' -Reason 'the target is a reparse point; pcx never follows one.' -Target $Canonical
    }

    $rootKey = $null
    if ($Canonical.role -eq 'a1') {
        $rootKey = 'a1_roots'
    }
    elseif ($Canonical.role -eq 'quarantine') {
        $rootKey = 'a2_roots'
    }
    else {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-FILE-ROLE' -Reason 'a file target must declare role a1 or quarantine.' -Target $Canonical
    }

    $files = Get-PcxPolicyMember -Object $Data -Name 'files'
    $environment = Get-PcxPolicyMember -Object $Profile -Name 'environment'

    $inside = $false
    $unresolved = $false
    foreach ($root in @(Get-PcxPolicyMember -Object $files -Name $rootKey)) {
        if ($null -eq $root) { continue }
        $expanded = Resolve-PcxPolicyRoot -Root ([string]$root) -Environment $environment
        if ($null -eq $expanded) {
            $unresolved = $true
            continue
        }
        if (Test-PcxPolicyPathUnder -Path ([string]$Canonical.path) -Root $expanded) {
            $inside = $true
            break
        }
    }

    if ($inside) {
        return New-PcxPolicyAllow -Reason "the path is inside a configured $rootKey entry." -Target $Canonical
    }
    if ($unresolved) {
        $code = if ($Canonical.role -eq 'quarantine') { 'PCX-POLICY-QUARANTINE-ROOT' } else { 'PCX-POLICY-FILE-ROOT' }
        return New-PcxPolicyDenial -Code $code -Reason 'a configured root could not be resolved from the profile environment; containment cannot be proven.' -Target $Canonical
    }
    if ($Canonical.role -eq 'quarantine') {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-QUARANTINE-ROOT' -Reason 'a quarantine source must be inside the Startup folders (a2_roots).' -Target $Canonical
    }

    return New-PcxPolicyDenial -Code 'PCX-POLICY-FILE-ROOT' -Reason 'an A1 target must be inside a1_roots (OS-regenerable caches only).' -Target $Canonical
}

# ---------------------------------------------------------------------------
# Public: the gate
# ---------------------------------------------------------------------------

function Test-PcxTarget {
    <#
    .SYNOPSIS
        Decides whether one typed target may be written under one profile.

    .DESCRIPTION
        Pure: no machine state is read. Returns a structured decision with an
        allowed flag, a typed PCX-POLICY-* code (or PCX-POLICY-ALLOW) and a
        human reason. Grammar errors are reported as PCX-POLICY-GRAMMAR rather
        than thrown, so every caller gets the same shape.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $canonical = $null
    try {
        $canonical = ConvertTo-PcxTarget -Target $Target
    }
    catch {
        $message = $_.Exception.Message
        $prefix = 'PCX-POLICY-GRAMMAR:'
        if ($message.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $message = $message.Substring($prefix.Length).Trim()
        }
        return New-PcxPolicyResult -Allowed $false -Code 'PCX-POLICY-GRAMMAR' -Reason $message -Target $null
    }

    # Whole-machine gates. Anything other than an explicit false is unknown and
    # therefore refuses every write (fail closed).
    $managed = Get-PcxPolicyBoolean -Object $Profile -Name 'managed'
    if ($managed -ne $false) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-MANAGED' -Reason 'the profile is managed or unknown; managed machines refuse every write.' -Target $canonical
    }

    $sMode = Get-PcxPolicyBoolean -Object $Profile -Name 'sMode'
    if ($sMode -ne $false) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-SMODE' -Reason 'the profile is in S Mode or unknown; a write is refused.' -Target $canonical
    }

    $devDrive = Get-PcxPolicyBoolean -Object $Profile -Name 'devDrive'
    if ($devDrive -ne $false) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-DEVDRIVE' -Reason 'the profile uses a Dev Drive or is unknown; a write is refused.' -Target $canonical
    }

    $anticheat = Get-PcxPolicyBoolean -Object $Profile -Name 'anticheat'
    if ($anticheat -ne $false) {
        return New-PcxPolicyDenial -Code 'PCX-POLICY-ANTICHEAT' -Reason 'anticheat software is present or unknown; a write is refused.' -Target $canonical
    }

    $data = Get-PcxPolicyData

    switch ($canonical.kind) {
        'registry' { return Test-PcxPolicyRegistry -Canonical $canonical -Data $data }
        'service' { return Test-PcxPolicyService -Canonical $canonical -Data $data -Profile $Profile }
        'task' { return Test-PcxPolicyTask -Canonical $canonical -Data $data }
        'file' { return Test-PcxPolicyFile -Canonical $canonical -Data $data -Profile $Profile }
    }

    return New-PcxPolicyDenial -Code 'PCX-POLICY-GRAMMAR' -Reason "unknown target kind '$($canonical.kind)'." -Target $canonical
}
