<#
.SYNOPSIS
    `pcx probe`: the typed, read-only free-investigation surface.

.DESCRIPTION
    Internal command only. Per AS10 the user-facing commands stay doctor, tune
    and undo; probe is registered in Pcx.psm1 for the agent and for later
    internal callers (task 12 re-measures evidence live through it) but is never
    added to the pcx.ps1 dispatch.

    Invoke-PcxProbe -Probe <object|string> accepts exactly one probe and always
    returns exactly one result object:

        @{ family; status; value; unit; source; code; reason; target }

    status is measured | unavailable | unreliable | refused. A non-measured
    result always carries value $null and a typed PCX-E-* code; a zero is only
    ever a measured zero. There is no bare scalar return and no guessed value.

    Families and their inputs:
        reg:<key path>#<value name>      -> platform read (registry)
        svc:<service name>               -> platform read (service Start)
        task:<full task path>            -> platform read (task Enabled)
        file:<absolute path>             -> platform read (file state)
        counter:<PDH counter path>       -> PdhAddEnglishCounter (P/Invoke)
        event:<log>[;Provider=<p>][;Id=<n>][;Hours=<n>][;Level=<n>]
                                          -> Get-WinEvent -FilterHashtable only
        intent:u4|userassist|prefetch|taskhistory
                                          -> UserAssist/Prefetch/task history
        environment:                      -> Get-PcxEnvironment (fixture-aware)

    An object probe is also accepted, e.g.
        @{ family = 'counter'; path = '\Processor(_Total)\% Processor Time' }
        @{ family = 'event'; logName = 'System'; id = 41; hours = 24 }
        @{ family = 'intent'; metric = 'u4'; fixture = 'C:\fixtures\desktop' }

    Counter names are resolved through PdhAddEnglishCounter so a localized
    Windows still resolves the English counter path; a small alias table maps
    common localized object/counter names to their English form first. If the
    English counter is unavailable the result is unavailable with a typed code,
    never zero.

    Event probes refuse an unfiltered query with
    PCX-E-PROBE-EVENT-UNFILTERED. An empty filtered result is unavailable, not a
    measured zero.

    Fixture mode: counter, event and intent accept -FixturePath or a fixture
    value in the probe argument (a path string or an inline object). A fixture
    directory may contain probe.json (counters/events/intent), state.json
    (intent state) and machine.json (environment). Under PCX_TEST_RUN with no
    fixture available these families refuse with PCX-E-PROBE-FIXTURE instead of
    touching the live OS. environment is fixture-aware through
    Get-PcxEnvironment and refuses with its own PCX-E-ENVIRONMENT-FIXTURE.

    Read-only: this file declares no OS write path. reg/svc/task/file go through
    Invoke-PcxPlatformRead; counter is PdhAddEnglishCounter plus a read; event is
    a filtered Get-WinEvent; intent reuses the read-only intent collector;
    environment is Get-PcxEnvironment. Nothing here mutates a target.
#>

Set-StrictMode -Version 2.0

$script:PcxProbeFamilies = @('reg', 'svc', 'task', 'file', 'counter', 'event', 'intent', 'environment')
$script:PcxProbeStatuses = @('measured', 'unavailable', 'unreliable', 'refused')

# Common localized counter names -> the English form PdhAddEnglishCounter
# resolves. Keyed lowercase; this is a small convenience table, not a general
# locale database. ponytail: German plus a few Latin-script names; extend the
# table if a real user hits an unmapped locale.
$script:PcxProbeCounterObjectAliases = @{
    'prozessor'          = 'Processor'
    'system'             = 'System'
    'arbeitsspeicher'    = 'Memory'
    'speicher'           = 'Memory'
    'logischer datentraeger' = 'LogicalDisk'
    'physischer datentraeger' = 'PhysicalDisk'
}
$script:PcxProbeCounterNameAliases = @{
    'prozessorzeit (%)'  = '% Processor Time'
    'prozessorzeit'      = '% Processor Time'
    'arbeitsspeicher (%)' = '% Committed Bytes In Use'
    'auslagerungsdatei (%)' = '% Usage'
}

# ---------------------------------------------------------------------------
# Result construction
# ---------------------------------------------------------------------------

function New-PcxProbeResult {
    param(
        [Parameter(Mandatory = $true)][string] $Family,
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value = $null,
        [Parameter(Mandatory = $true)][string] $Unit,
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Code = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Reason = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target = $null
    )

    if ($script:PcxProbeStatuses -notcontains $Status) {
        $Status = 'unavailable'
        $Value = $null
        if ([string]::IsNullOrEmpty($Code)) { $Code = 'PCX-E-PROBE-STATUS' }
    }

    if ($Status -eq 'measured') {
        if ($null -eq $Value) {
            $Status = 'unavailable'
            if ([string]::IsNullOrEmpty($Code)) { $Code = 'PCX-E-PROBE-VALUE' }
        }
    }
    elseif ($Status -ne 'refused') {
        $Value = $null
    }

    return [pscustomobject][ordered]@{
        family = $Family
        status = $Status
        value  = $Value
        unit   = $Unit
        source = $Source
        code   = $Code
        reason = $Reason
        target = $Target
    }
}

# ---------------------------------------------------------------------------
# Probe argument parsing
# ---------------------------------------------------------------------------

function Split-PcxProbeText {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $Separator
    )

    $index = $Text.LastIndexOf($Separator, [System.StringComparison]::Ordinal)
    if ($index -lt 0) {
        return [pscustomobject]@{ Head = $Text; Tail = $null }
    }

    return [pscustomobject]@{
        Head = $Text.Substring(0, $index)
        Tail = $Text.Substring($index + $Separator.Length)
    }
}

function ConvertFrom-PcxProbeEventPayload {
    param([Parameter(Mandatory = $true)][string] $Payload)

    $tokens = @($Payload -split ';')
    $spec = [ordered]@{
        logName      = $tokens[0].Trim()
        providerName = $null
        id           = $null
        hours        = $null
        level        = $null
    }

    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i].Trim()
        if ($token.Length -eq 0) { continue }

        $pair = Split-PcxProbeText -Text $token -Separator '='
        if ([string]::IsNullOrEmpty($pair.Tail)) {
            throw [System.ArgumentException]::new("PCX-E-PROBE-ARG: event token '$token' must be key=value.")
        }

        switch ($pair.Head.Trim().ToLowerInvariant()) {
            'provider' { $spec['providerName'] = $pair.Tail.Trim() }
            'providername' { $spec['providerName'] = $pair.Tail.Trim() }
            'id' { $spec['id'] = $pair.Tail.Trim() }
            'hours' { $spec['hours'] = $pair.Tail.Trim() }
            'level' { $spec['level'] = $pair.Tail.Trim() }
            'logname' { $spec['logName'] = $pair.Tail.Trim() }
            default {
                throw [System.ArgumentException]::new("PCX-E-PROBE-ARG: unknown event filter '$( $pair.Head )'.")
            }
        }
    }

    return [pscustomobject]$spec
}

function ConvertTo-PcxProbeSpec {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Probe)

    $spec = [ordered]@{
        family        = 'unknown'
        path          = $null
        name          = $null
        logName       = $null
        providerName  = $null
        id            = $null
        hours         = $null
        level         = $null
        metric        = 'u4'
        fixture       = $null
        inlineFixture = $null
    }

    if ($null -eq $Probe) {
        throw [System.ArgumentException]::new('PCX-E-PROBE-ARG: a probe is required.')
    }

    if ($Probe -is [string]) {
        $text = ([string]$Probe).Trim()
        if ($text.Length -eq 0) {
            throw [System.ArgumentException]::new('PCX-E-PROBE-ARG: a probe is required.')
        }

        $colon = $text.IndexOf(':')
        if ($colon -lt 1) {
            throw [System.ArgumentException]::new("PCX-E-PROBE-ARG: '$text' has no family prefix (reg:, svc:, task:, file:, counter:, event:, intent:, environment:).")
        }

        $family = $text.Substring(0, $colon).ToLowerInvariant()
        $payload = $text.Substring($colon + 1)
        if ($script:PcxProbeFamilies -notcontains $family) {
            throw [System.ArgumentException]::new("PCX-E-PROBE-ARG: unknown probe family '$family'.")
        }

        $spec['family'] = $family

        switch ($family) {
            'reg' {
                $parts = Split-PcxProbeText -Text $payload -Separator '#'
                if ([string]::IsNullOrWhiteSpace($parts.Head) -or [string]::IsNullOrWhiteSpace($parts.Tail)) {
                    throw [System.ArgumentException]::new("PCX-E-PROBE-ARG: reg probe needs '<key path>#<value name>' (got '$payload').")
                }
                $spec['path'] = $parts.Head.Trim()
                $spec['name'] = $parts.Tail.Trim()
            }
            'svc' {
                if ([string]::IsNullOrWhiteSpace($payload)) {
                    throw [System.ArgumentException]::new('PCX-E-PROBE-ARG: svc probe needs a service name.')
                }
                $spec['name'] = $payload.Trim()
            }
            'task' {
                if ([string]::IsNullOrWhiteSpace($payload)) {
                    throw [System.ArgumentException]::new('PCX-E-PROBE-ARG: task probe needs a full task path.')
                }
                $spec['path'] = $payload.Trim()
            }
            'file' {
                if ([string]::IsNullOrWhiteSpace($payload)) {
                    throw [System.ArgumentException]::new('PCX-E-PROBE-ARG: file probe needs an absolute path.')
                }
                $spec['path'] = $payload.Trim()
            }
            'counter' {
                if ([string]::IsNullOrWhiteSpace($payload)) {
                    throw [System.ArgumentException]::new('PCX-E-PROBE-ARG: counter probe needs a PDH counter path.')
                }
                $spec['path'] = $payload.Trim()
            }
            'event' {
                $eventSpec = ConvertFrom-PcxProbeEventPayload -Payload $payload
                $spec['logName'] = $eventSpec.logName
                $spec['providerName'] = $eventSpec.providerName
                $spec['id'] = $eventSpec.id
                $spec['hours'] = $eventSpec.hours
                $spec['level'] = $eventSpec.level
            }
            'intent' {
                if (-not [string]::IsNullOrWhiteSpace($payload)) {
                    $spec['metric'] = $payload.Trim().ToLowerInvariant()
                }
            }
            'environment' {
                if (-not [string]::IsNullOrWhiteSpace($payload)) {
                    $spec['fixture'] = $payload.Trim()
                }
            }
        }

        return [pscustomobject]$spec
    }

    $family = [string](Get-PcxPolicyMember -Object $Probe -Name 'family')
    if ([string]::IsNullOrWhiteSpace($family)) {
        $family = [string](Get-PcxPolicyMember -Object $Probe -Name 'Family')
    }
    if ([string]::IsNullOrWhiteSpace($family)) {
        throw [System.ArgumentException]::new('PCX-E-PROBE-ARG: an object probe needs a family member.')
    }
    $family = $family.ToLowerInvariant()
    if ($script:PcxProbeFamilies -notcontains $family) {
        throw [System.ArgumentException]::new("PCX-E-PROBE-ARG: unknown probe family '$family'.")
    }
    $spec['family'] = $family

    $pathMember = Get-PcxPolicyMember -Object $Probe -Name 'path'
    if ($null -eq $pathMember) { $pathMember = Get-PcxPolicyMember -Object $Probe -Name 'Path' }
    $nameMember = Get-PcxPolicyMember -Object $Probe -Name 'name'
    if ($null -eq $nameMember) { $nameMember = Get-PcxPolicyMember -Object $Probe -Name 'Name' }

    $spec['path'] = $pathMember
    $spec['name'] = $nameMember

    foreach ($field in @('logName', 'providerName', 'id', 'hours', 'level', 'metric')) {
        $memberValue = Get-PcxPolicyMember -Object $Probe -Name $field
        if ($null -ne $memberValue) { $spec[$field] = $memberValue }
    }

    $fixtureMember = Get-PcxPolicyMember -Object $Probe -Name 'fixture'
    if ($null -eq $fixtureMember) {
        $fixtureMember = Get-PcxPolicyMember -Object $Probe -Name 'FixturePath'
    }
    if ($null -ne $fixtureMember) {
        if ($fixtureMember -is [string]) {
            $spec['fixture'] = $fixtureMember
        }
        else {
            $spec['inlineFixture'] = $fixtureMember
        }
    }

    return [pscustomobject]$spec
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

function Read-PcxProbeFixture {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)

    if ([System.IO.Directory]::Exists($fullPath)) {
        $document = [ordered]@{}

        $probePath = [System.IO.Path]::Combine($fullPath, 'probe.json')
        if ([System.IO.File]::Exists($probePath)) {
            $probeDocument = Read-PcxJson -Path $probePath
            foreach ($member in @('counters', 'events', 'intent')) {
                $value = Get-PcxPolicyMember -Object $probeDocument -Name $member
                if ($null -ne $value) { $document[$member] = $value }
            }
        }

        $statePath = [System.IO.Path]::Combine($fullPath, 'state.json')
        if ([System.IO.File]::Exists($statePath)) {
            $document['state'] = Read-PcxJson -Path $statePath
        }

        $machinePath = [System.IO.Path]::Combine($fullPath, 'machine.json')
        if ([System.IO.File]::Exists($machinePath)) {
            $document['environmentPath'] = $machinePath
        }

        return [pscustomobject]$document
    }

    if (-not [System.IO.File]::Exists($fullPath)) {
        throw [System.IO.FileNotFoundException]::new("PCX-E-PROBE-FIXTURE: '$fullPath' does not exist.", $fullPath)
    }

    return Read-PcxJson -Path $fullPath
}

function Resolve-PcxProbeFixtureDocument {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][string] $FixturePath,
        [Parameter(Mandatory = $false)][AllowNull()][object] $InlineFixture
    )

    if ($null -ne $InlineFixture) {
        return $InlineFixture
    }

    if ([string]::IsNullOrWhiteSpace($FixturePath)) {
        return $null
    }

    return Read-PcxProbeFixture -Path $FixturePath
}

function Test-PcxProbeFixtureMode {
    return (-not [string]::IsNullOrEmpty($env:PCX_TEST_RUN))
}

# ---------------------------------------------------------------------------
# Platform-backed families (reg, svc, task, file)
# ---------------------------------------------------------------------------

function Invoke-PcxProbePlatformFamily {
    param(
        [Parameter(Mandatory = $true)][string] $Family,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Target
    )

    try {
        $state = Invoke-PcxPlatformRead -Target $Target
    }
    catch {
        return New-PcxProbeResult -Family $Family -Status 'unavailable' -Unit $Family -Source "platform:$Family" -Code 'PCX-E-PROBE-PLATFORM' -Reason $_.Exception.Message -Target $Target
    }

    if ($null -eq $state) {
        return New-PcxProbeResult -Family $Family -Status 'unavailable' -Unit $Family -Source "platform:$Family" -Code 'PCX-E-PROBE-PLATFORM' -Reason 'the platform returned no state' -Target $Target
    }

    switch ($Family) {
        'reg' {
            if (-not [bool]$state.exists) {
                return New-PcxProbeResult -Family 'reg' -Status 'unavailable' -Unit 'registry-value' -Source 'platform:registry' -Code 'PCX-E-PROBE-NOT-FOUND' -Reason "registry value '$($Target['Name'])' is not present under '$($Target['Path'])'" -Target $Target
            }
            return New-PcxProbeResult -Family 'reg' -Status 'measured' -Value $state.data -Unit ('registry:' + [string]$state.type) -Source 'platform:registry' -Target $Target
        }
        'svc' {
            if (-not [bool]$state.exists) {
                return New-PcxProbeResult -Family 'svc' -Status 'unavailable' -Unit 'start-type' -Source 'platform:service' -Code 'PCX-E-PROBE-NOT-FOUND' -Reason "service '$($Target['Name'])' is not present" -Target $Target
            }
            return New-PcxProbeResult -Family 'svc' -Status 'measured' -Value $state.start -Unit 'start-type' -Source 'platform:service' -Target $Target
        }
        'task' {
            if (-not [bool]$state.exists) {
                return New-PcxProbeResult -Family 'task' -Status 'unavailable' -Unit 'bool' -Source 'platform:task' -Code 'PCX-E-PROBE-NOT-FOUND' -Reason "task '$($Target['Path'])' is not present" -Target $Target
            }
            return New-PcxProbeResult -Family 'task' -Status 'measured' -Value $state.enabled -Unit 'bool' -Source 'platform:task' -Target $Target
        }
        'file' {
            # A read is a measurement of existence; exists=false is honest, not a
            # guessed value.
            $value = [ordered]@{
                exists         = [bool]$state.exists
                length         = $state.length
                sha256         = $state.sha256
                attributes     = $state.attributes
                isReparsePoint = [bool]$state.isReparsePoint
            }
            return New-PcxProbeResult -Family 'file' -Status 'measured' -Value $value -Unit 'file-state' -Source 'platform:file' -Target $Target
        }
    }
}

# ---------------------------------------------------------------------------
# Counter family: PdhAddEnglishCounter
# ---------------------------------------------------------------------------

function ConvertTo-PcxEnglishCounterPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $trimmed = $Path.Trim()
    if ($trimmed.Length -eq 0) { return $trimmed }

    $hasLeading = $trimmed.StartsWith('\')
    $segments = @($trimmed.TrimStart('\') -split '\\')
    if ($segments.Count -lt 2) { return $trimmed }

    $objectIndex = $segments.Count - 2
    $counterIndex = $segments.Count - 1

    $objectSegment = $segments[$objectIndex]
    $instanceSuffix = ''
    $objectBase = $objectSegment
    $parenIndex = $objectSegment.IndexOf('(')
    if ($parenIndex -ge 0) {
        $objectBase = $objectSegment.Substring(0, $parenIndex)
        $instanceSuffix = $objectSegment.Substring($parenIndex)
    }

    $objectKey = $objectBase.Trim().ToLowerInvariant()
    if ($script:PcxProbeCounterObjectAliases.ContainsKey($objectKey)) {
        $objectBase = $script:PcxProbeCounterObjectAliases[$objectKey]
    }
    $segments[$objectIndex] = $objectBase + $instanceSuffix

    $counterName = $segments[$counterIndex].Trim()
    $counterKey = $counterName.ToLowerInvariant()
    if ($script:PcxProbeCounterNameAliases.ContainsKey($counterKey)) {
        $segments[$counterIndex] = $script:PcxProbeCounterNameAliases[$counterKey]
    }

    $joined = $segments -join '\'
    if ($hasLeading) { $joined = '\' + $joined }

    return $joined
}

function Initialize-PcxProbePdh {
    if ($null -ne ('Pcx.Probe.Pdh' -as [type])) {
        return
    }

    $pdhSource = @'
using System;
using System.Runtime.InteropServices;

namespace Pcx.Probe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PdhFmtCounterValue
    {
        public uint CStatus;
        public double Value;
    }

    public static class Pdh
    {
        [DllImport("pdh.dll", EntryPoint = "PdhOpenQueryW", CharSet = CharSet.Unicode)]
        public static extern uint OpenQuery(string dataSource, IntPtr userData, out IntPtr query);

        [DllImport("pdh.dll", EntryPoint = "PdhAddEnglishCounterW", CharSet = CharSet.Unicode)]
        public static extern uint AddEnglishCounter(IntPtr query, string fullCounterPath, IntPtr userData, out IntPtr counter);

        [DllImport("pdh.dll")]
        public static extern uint PdhCollectQueryData(IntPtr query);

        [DllImport("pdh.dll")]
        public static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out PdhFmtCounterValue value);

        [DllImport("pdh.dll")]
        public static extern uint PdhCloseQuery(IntPtr query);
    }
}
'@

    Add-Type -TypeDefinition $pdhSource -Language CSharp -ErrorAction Stop
}

function Get-PcxProbePdhValue {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        Initialize-PcxProbePdh
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Code = 'PCX-E-PROBE-COUNTER-UNAVAILABLE'; Reason = "the PDH bridge could not be compiled: $($_.Exception.Message)" }
    }

    $query = [IntPtr]::Zero
    $counter = [IntPtr]::Zero

    # PdhOpenQueryW rejects an empty data-source string; it needs real NULL for
    # the local machine, so pass [NullString]::Value rather than $null.
    $status = [Pcx.Probe.Pdh]::OpenQuery([NullString]::Value, [IntPtr]::Zero, [ref]$query)
    if ($status -ne 0) {
        return [pscustomobject]@{ Ok = $false; Value = $null; Code = 'PCX-E-PROBE-COUNTER-UNAVAILABLE'; Reason = ('PdhOpenQuery failed with status 0x{0:X8}' -f $status) }
    }

    try {
        $status = [Pcx.Probe.Pdh]::AddEnglishCounter($query, $Path, [IntPtr]::Zero, [ref]$counter)
        if ($status -ne 0) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Code = 'PCX-E-PROBE-COUNTER-UNAVAILABLE'; Reason = ('PdhAddEnglishCounter failed for ''{0}'' with status 0x{1:X8}' -f $Path, $status) }
        }

        $null = [Pcx.Probe.Pdh]::PdhCollectQueryData($query)
        Start-Sleep -Milliseconds 120
        $null = [Pcx.Probe.Pdh]::PdhCollectQueryData($query)

        $type = [uint32]0
        $formatValue = New-Object Pcx.Probe.PdhFmtCounterValue
        $status = [Pcx.Probe.Pdh]::PdhGetFormattedCounterValue($counter, [uint32]0x00000200, [ref]$type, [ref]$formatValue)
        if ($status -ne 0) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Code = 'PCX-E-PROBE-COUNTER-UNAVAILABLE'; Reason = ('PdhGetFormattedCounterValue failed with status 0x{0:X8}' -f $status) }
        }

        # PDH_CSTATUS_VALID_DATA (0) and PDH_CSTATUS_NEW_DATA (1) are usable; any
        # other status is a typed unavailable, never a zero.
        if ($formatValue.CStatus -ne 0 -and $formatValue.CStatus -ne 1) {
            return [pscustomobject]@{ Ok = $false; Value = $null; Code = 'PCX-E-PROBE-COUNTER-UNAVAILABLE'; Reason = ('the counter returned status 0x{0:X8}' -f $formatValue.CStatus) }
        }

        return [pscustomobject]@{ Ok = $true; Value = [double]$formatValue.Value; Code = $null; Reason = $null }
    }
    finally {
        [void][Pcx.Probe.Pdh]::PdhCloseQuery($query)
    }
}

function Invoke-PcxProbeCounter {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $false)][AllowNull()][object] $FixtureDocument
    )

    $englishPath = ConvertTo-PcxEnglishCounterPath -Path $Path

    $target = [ordered]@{
        requested = $Path
        english   = $englishPath
    }

    if ($null -ne $FixtureDocument) {
        $counters = Get-PcxPolicyMember -Object $FixtureDocument -Name 'counters'
        if ($null -eq $counters) {
            return New-PcxProbeResult -Family 'counter' -Status 'unavailable' -Unit 'counter' -Source 'pdh:PdhAddEnglishCounter(fixture)' -Code 'PCX-E-PROBE-COUNTER-UNAVAILABLE' -Reason 'the fixture carries no counters' -Target $target
        }

        $fixtureValue = Get-PcxPolicyMember -Object $counters -Name $englishPath
        if ($null -eq $fixtureValue) {
            $fixtureValue = Get-PcxPolicyMember -Object $counters -Name $Path
        }
        if ($null -eq $fixtureValue) {
            return New-PcxProbeResult -Family 'counter' -Status 'unavailable' -Unit 'counter' -Source 'pdh:PdhAddEnglishCounter(fixture)' -Code 'PCX-E-PROBE-COUNTER-UNAVAILABLE' -Reason "the fixture has no value for '$englishPath'" -Target $target
        }

        return New-PcxProbeResult -Family 'counter' -Status 'measured' -Value ([double]$fixtureValue) -Unit 'counter' -Source 'pdh:PdhAddEnglishCounter(fixture)' -Target $target
    }

    if (Test-PcxProbeFixtureMode) {
        return New-PcxProbeResult -Family 'counter' -Status 'refused' -Unit 'counter' -Source 'pdh:PdhAddEnglishCounter' -Code 'PCX-E-PROBE-FIXTURE' -Reason 'fixture mode is active (PCX_TEST_RUN) and no counter fixture was supplied; refusing to probe the live OS' -Target $target
    }

    $pdh = Get-PcxProbePdhValue -Path $englishPath
    if (-not $pdh.Ok) {
        return New-PcxProbeResult -Family 'counter' -Status 'unavailable' -Unit 'counter' -Source 'pdh:PdhAddEnglishCounter' -Code $pdh.Code -Reason $pdh.Reason -Target $target
    }

    return New-PcxProbeResult -Family 'counter' -Status 'measured' -Value $pdh.Value -Unit 'counter' -Source 'pdh:PdhAddEnglishCounter' -Target $target
}

# ---------------------------------------------------------------------------
# Event family: Get-WinEvent -FilterHashtable only
# ---------------------------------------------------------------------------

function Get-PcxProbeEventTime {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    try {
        return [datetime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        return $null
    }
}

function Invoke-PcxProbeEvent {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Spec)

    $logName = [string](Get-PcxPolicyMember -Object $Spec -Name 'logName')
    if ([string]::IsNullOrWhiteSpace($logName)) {
        return New-PcxProbeResult -Family 'event' -Status 'refused' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-ARG' -Reason 'an event probe needs a log name' -Target $null
    }

    $providerName = [string](Get-PcxPolicyMember -Object $Spec -Name 'providerName')
    $idValue = Get-PcxPolicyMember -Object $Spec -Name 'id'
    $hoursValue = Get-PcxPolicyMember -Object $Spec -Name 'hours'
    $levelValue = Get-PcxPolicyMember -Object $Spec -Name 'level'

    $target = [ordered]@{
        logName      = $logName
        providerName = $(if ([string]::IsNullOrWhiteSpace($providerName)) { $null } else { $providerName })
        id           = $idValue
        hours        = $hoursValue
        level        = $levelValue
    }

    $hasFilter = (-not [string]::IsNullOrWhiteSpace($providerName)) -or
                 ($null -ne $idValue) -or ($null -ne $hoursValue) -or ($null -ne $levelValue)

    if (-not $hasFilter) {
        return New-PcxProbeResult -Family 'event' -Status 'refused' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-EVENT-UNFILTERED' -Reason 'an event query needs at least one of ProviderName, Id, StartTime (hours) or Level; refusing to scan the whole log' -Target $target
    }

    $fixtureDocument = Get-PcxPolicyMember -Object $Spec -Name 'fixtureDocument'
    if ($null -ne $fixtureDocument) {
        $events = Get-PcxPolicyMember -Object $fixtureDocument -Name 'events'
        if ($null -eq $events) {
            return New-PcxProbeResult -Family 'event' -Status 'unavailable' -Unit 'events' -Source 'fixture:events' -Code 'PCX-E-PROBE-EVENT-EMPTY' -Reason 'the fixture carries no events' -Target $target
        }

        $startTime = $null
        if ($null -ne $hoursValue) {
            try { $startTime = (Get-Date).AddHours(-[double]$hoursValue) } catch { $startTime = $null }
        }

        $matched = 0
        foreach ($eventItem in @($events)) {
            if ($null -eq $eventItem) { continue }

            $eventLog = [string](Get-PcxPolicyMember -Object $eventItem -Name 'logName')
            if (-not [string]::IsNullOrWhiteSpace($eventLog) -and -not [string]::Equals($eventLog, $logName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            if (-not [string]::IsNullOrWhiteSpace($providerName)) {
                $eventProvider = [string](Get-PcxPolicyMember -Object $eventItem -Name 'providerName')
                if (-not [string]::Equals($eventProvider, $providerName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            }

            if ($null -ne $idValue) {
                $eventId = Get-PcxPolicyMember -Object $eventItem -Name 'id'
                if ($null -eq $eventId -or [int]$eventId -ne [int]$idValue) { continue }
            }

            if ($null -ne $levelValue) {
                $eventLevel = Get-PcxPolicyMember -Object $eventItem -Name 'level'
                if ($null -eq $eventLevel -or [int]$eventLevel -ne [int]$levelValue) { continue }
            }

            if ($null -ne $startTime) {
                $eventTime = Get-PcxProbeEventTime -Value (Get-PcxPolicyMember -Object $eventItem -Name 'timeCreated')
                if ($null -eq $eventTime -or $eventTime -lt $startTime) { continue }
            }

            $matched++
        }

        if ($matched -eq 0) {
            return New-PcxProbeResult -Family 'event' -Status 'unavailable' -Unit 'events' -Source 'fixture:events' -Code 'PCX-E-PROBE-EVENT-EMPTY' -Reason 'the filtered query matched no events' -Target $target
        }

        return New-PcxProbeResult -Family 'event' -Status 'measured' -Value $matched -Unit 'events' -Source 'fixture:events' -Target $target
    }

    if (Test-PcxProbeFixtureMode) {
        return New-PcxProbeResult -Family 'event' -Status 'refused' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-FIXTURE' -Reason 'fixture mode is active (PCX_TEST_RUN) and no event fixture was supplied; refusing to probe the live OS' -Target $target
    }

    $filter = @{ LogName = $logName }
    if (-not [string]::IsNullOrWhiteSpace($providerName)) { $filter['ProviderName'] = $providerName }
    if ($null -ne $idValue) { $filter['Id'] = [int]$idValue }
    if ($null -ne $levelValue) { $filter['Level'] = [int]$levelValue }
    if ($null -ne $hoursValue) {
        try { $filter['StartTime'] = (Get-Date).AddHours(-[double]$hoursValue) }
        catch {
            return New-PcxProbeResult -Family 'event' -Status 'refused' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-ARG' -Reason "hours '$hoursValue' is not a number" -Target $target
        }
    }

    $count = 0
    try {
        $records = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 5000 -ErrorAction Stop)
        $count = $records.Count
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'No events were found' -or $message -match 'No matching events') {
            return New-PcxProbeResult -Family 'event' -Status 'unavailable' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-EVENT-EMPTY' -Reason 'the filtered query matched no events' -Target $target
        }
        return New-PcxProbeResult -Family 'event' -Status 'unavailable' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-EVENT-UNAVAILABLE' -Reason $message -Target $target
    }

    if ($count -eq 0) {
        return New-PcxProbeResult -Family 'event' -Status 'unavailable' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-EVENT-EMPTY' -Reason 'the filtered query matched no events' -Target $target
    }

    return New-PcxProbeResult -Family 'event' -Status 'measured' -Value $count -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Target $target
}

# ---------------------------------------------------------------------------
# Intent family: re-measured U4 usage
# ---------------------------------------------------------------------------

function Get-PcxProbeMetricValue {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $Metrics,
        [Parameter(Mandatory = $true)][string] $Id
    )

    foreach ($metric in @($Metrics)) {
        if ($null -eq $metric) { continue }
        if ([string](Get-PcxPolicyMember -Object $metric -Name 'id') -eq $Id) {
            $status = [string](Get-PcxPolicyMember -Object $metric -Name 'status')
            if ($status -eq 'measured') {
                return (Get-PcxPolicyMember -Object $metric -Name 'value')
            }
            return $null
        }
    }

    return $null
}

function Invoke-PcxProbeIntent {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Spec,
        [Parameter(Mandatory = $false)][AllowNull()][object] $FixtureDocument
    )

    $metricName = [string](Get-PcxPolicyMember -Object $Spec -Name 'metric')
    if ([string]::IsNullOrWhiteSpace($metricName)) { $metricName = 'u4' }
    $metricName = $metricName.ToLowerInvariant()

    $target = [ordered]@{ intent = $metricName }

    if ($null -eq $FixtureDocument -and (Test-PcxProbeFixtureMode)) {
        return New-PcxProbeResult -Family 'intent' -Status 'refused' -Unit 'usage' -Source 'intent collector' -Code 'PCX-E-PROBE-FIXTURE' -Reason 'fixture mode is active (PCX_TEST_RUN) and no intent fixture was supplied; refusing to probe the live OS' -Target $target
    }

    $collectorFixture = $null
    if ($null -ne $FixtureDocument) {
        $state = Get-PcxPolicyMember -Object $FixtureDocument -Name 'state'
        if ($null -ne $state) {
            $collectorFixture = $FixtureDocument
        }
        else {
            $intent = Get-PcxPolicyMember -Object $FixtureDocument -Name 'intent'
            if ($null -eq $intent) {
                return New-PcxProbeResult -Family 'intent' -Status 'unavailable' -Unit 'usage' -Source 'intent collector' -Code 'PCX-E-PROBE-INTENT-UNAVAILABLE' -Reason 'the fixture carries no intent state' -Target $target
            }
            $collectorFixture = [pscustomobject]@{ state = [pscustomobject]@{ intent = $intent } }
        }
    }

    try {
        $metrics = @(Get-PcxCollectorIntent -Fixture $collectorFixture)
    }
    catch {
        return New-PcxProbeResult -Family 'intent' -Status 'unavailable' -Unit 'usage' -Source 'intent collector' -Code 'PCX-E-PROBE-INTENT-UNAVAILABLE' -Reason $_.Exception.Message -Target $target
    }

    if ($metricName -eq 'u4') {
        $userAssist = Get-PcxProbeMetricValue -Metrics $metrics -Id 'intent.userassist_entries'
        $prefetch = Get-PcxProbeMetricValue -Metrics $metrics -Id 'intent.prefetch_files'
        $taskHistory = Get-PcxProbeMetricValue -Metrics $metrics -Id 'intent.task_history_events'

        if ($null -eq $userAssist -and $null -eq $prefetch -and $null -eq $taskHistory) {
            return New-PcxProbeResult -Family 'intent' -Status 'unavailable' -Unit 'usage' -Source 'intent collector' -Code 'PCX-E-PROBE-INTENT-UNAVAILABLE' -Reason 'UserAssist, Prefetch and task history are all unavailable' -Target $target
        }

        $counts = @(@($userAssist, $prefetch, $taskHistory) | Where-Object { $null -ne $_ })
        $sum = 0
        foreach ($count in $counts) { $sum += [long]$count }

        $value = [ordered]@{
            userAssistEntries  = $userAssist
            prefetchFiles      = $prefetch
            taskHistoryEvents  = $taskHistory
            positive           = ($counts.Count -gt 0 -and $sum -gt 0)
        }

        return New-PcxProbeResult -Family 'intent' -Status 'measured' -Value $value -Unit 'usage' -Source 'intent collector: UserAssist/Prefetch/TaskScheduler' -Target $target
    }

    $metricMap = @{
        'userassist'   = 'intent.userassist_entries'
        'prefetch'     = 'intent.prefetch_files'
        'taskhistory'  = 'intent.task_history_events'
        'task-history' = 'intent.task_history_events'
    }

    if (-not $metricMap.ContainsKey($metricName)) {
        return New-PcxProbeResult -Family 'intent' -Status 'refused' -Unit 'usage' -Source 'intent collector' -Code 'PCX-E-PROBE-ARG' -Reason "unknown intent metric '$metricName'; use u4, userassist, prefetch or taskhistory" -Target $target
    }

    $metricId = $metricMap[$metricName]
    $metricValue = Get-PcxProbeMetricValue -Metrics $metrics -Id $metricId
    if ($null -eq $metricValue) {
        return New-PcxProbeResult -Family 'intent' -Status 'unavailable' -Unit 'count' -Source 'intent collector' -Code 'PCX-E-PROBE-INTENT-UNAVAILABLE' -Reason "intent metric '$metricId' is unavailable" -Target $target
    }

    return New-PcxProbeResult -Family 'intent' -Status 'measured' -Value $metricValue -Unit 'count' -Source 'intent collector' -Target $target
}

# ---------------------------------------------------------------------------
# Environment family
# ---------------------------------------------------------------------------

function Invoke-PcxProbeEnvironment {
    param([Parameter(Mandatory = $false)][AllowNull()][string] $FixturePath)

    $target = 'environment'

    try {
        $environment = Get-PcxEnvironment -FixturePath $FixturePath
    }
    catch {
        $message = $_.Exception.Message
        if ($message.StartsWith('PCX-E-ENVIRONMENT-FIXTURE', [System.StringComparison]::Ordinal)) {
            return New-PcxProbeResult -Family 'environment' -Status 'refused' -Unit 'object' -Source 'environment:Get-PcxEnvironment' -Code 'PCX-E-ENVIRONMENT-FIXTURE' -Reason $message -Target $target
        }
        return New-PcxProbeResult -Family 'environment' -Status 'unavailable' -Unit 'object' -Source 'environment:Get-PcxEnvironment' -Code 'PCX-E-PROBE-ENVIRONMENT' -Reason $message -Target $target
    }

    if ($null -eq $environment) {
        return New-PcxProbeResult -Family 'environment' -Status 'unavailable' -Unit 'object' -Source 'environment:Get-PcxEnvironment' -Code 'PCX-E-PROBE-ENVIRONMENT' -Reason 'Get-PcxEnvironment returned no value' -Target $target
    }

    return New-PcxProbeResult -Family 'environment' -Status 'measured' -Value $environment -Unit 'object' -Source 'environment:Get-PcxEnvironment' -Target $target
}

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

function Invoke-PcxProbe {
    <#
    .SYNOPSIS
        Runs exactly one typed, read-only probe and returns exactly one result.

    .DESCRIPTION
        Never throws for a bad probe: an unparsable argument returns a refused
        result with PCX-E-PROBE-ARG. Every helper returns one result object; this
        function never leaks a bare scalar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Probe,
        [Parameter(Mandatory = $false)][AllowNull()][string] $FixturePath
    )

    $spec = $null
    try {
        $spec = ConvertTo-PcxProbeSpec -Probe $Probe
    }
    catch {
        return New-PcxProbeResult -Family 'unknown' -Status 'refused' -Unit 'none' -Source 'probe' -Code 'PCX-E-PROBE-ARG' -Reason $_.Exception.Message -Target $null
    }

    $effectiveFixturePath = $FixturePath
    if ([string]::IsNullOrWhiteSpace($effectiveFixturePath)) {
        $effectiveFixturePath = [string](Get-PcxPolicyMember -Object $spec -Name 'fixture')
    }

    $inlineFixture = Get-PcxPolicyMember -Object $spec -Name 'inlineFixture'

    $family = [string]$spec.family
    switch ($family) {
        'reg' {
            $target = [ordered]@{
                Kind = 'registry'
                Path = [string]$spec.path
                Name = [string]$spec.name
            }
            return Invoke-PcxProbePlatformFamily -Family 'reg' -Target $target
        }
        'svc' {
            $target = [ordered]@{
                Kind = 'service'
                Name = [string]$spec.name
            }
            return Invoke-PcxProbePlatformFamily -Family 'svc' -Target $target
        }
        'task' {
            $target = [ordered]@{
                Kind = 'task'
                Path = [string]$spec.path
            }
            return Invoke-PcxProbePlatformFamily -Family 'task' -Target $target
        }
        'file' {
            $target = [ordered]@{
                Kind = 'file'
                Path = [string]$spec.path
            }
            return Invoke-PcxProbePlatformFamily -Family 'file' -Target $target
        }
        'counter' {
            $document = $null
            try {
                $document = Resolve-PcxProbeFixtureDocument -FixturePath $effectiveFixturePath -InlineFixture $inlineFixture
            }
            catch {
                return New-PcxProbeResult -Family 'counter' -Status 'refused' -Unit 'counter' -Source 'pdh:PdhAddEnglishCounter' -Code 'PCX-E-PROBE-FIXTURE' -Reason $_.Exception.Message -Target $null
            }
            return Invoke-PcxProbeCounter -Path ([string]$spec.path) -FixtureDocument $document
        }
        'event' {
            $document = $null
            if ($null -ne $inlineFixture -or -not [string]::IsNullOrWhiteSpace($effectiveFixturePath)) {
                try {
                    $document = Resolve-PcxProbeFixtureDocument -FixturePath $effectiveFixturePath -InlineFixture $inlineFixture
                }
                catch {
                    return New-PcxProbeResult -Family 'event' -Status 'refused' -Unit 'events' -Source 'Get-WinEvent -FilterHashtable' -Code 'PCX-E-PROBE-FIXTURE' -Reason $_.Exception.Message -Target $null
                }
            }

            $eventSpec = [pscustomobject][ordered]@{
                logName         = $spec.logName
                providerName    = $spec.providerName
                id              = $spec.id
                hours           = $spec.hours
                level           = $spec.level
                fixtureDocument = $document
            }
            return Invoke-PcxProbeEvent -Spec $eventSpec
        }
        'intent' {
            $document = $null
            if ($null -ne $inlineFixture -or -not [string]::IsNullOrWhiteSpace($effectiveFixturePath)) {
                try {
                    $document = Resolve-PcxProbeFixtureDocument -FixturePath $effectiveFixturePath -InlineFixture $inlineFixture
                }
                catch {
                    return New-PcxProbeResult -Family 'intent' -Status 'refused' -Unit 'usage' -Source 'intent collector' -Code 'PCX-E-PROBE-FIXTURE' -Reason $_.Exception.Message -Target $null
                }
            }
            return Invoke-PcxProbeIntent -Spec $spec -FixtureDocument $document
        }
        'environment' {
            return Invoke-PcxProbeEnvironment -FixturePath $effectiveFixturePath
        }
    }

    return New-PcxProbeResult -Family $family -Status 'refused' -Unit 'none' -Source 'probe' -Code 'PCX-E-PROBE-ARG' -Reason "unknown probe family '$family'" -Target $null
}
