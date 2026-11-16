<#
.SYNOPSIS
    `pcx tune` read-only scan: eight collector groups plus the 13 diagnostics
    sections, with no global time cap.

.DESCRIPTION
    Invoke-PcxTune is the command surface. Get-PcxScan is the orchestrator: it
    runs the eight collector groups (each with a per-collector timeout) and
    then the 13 diagnostics builders, and never lets a throwing or hanging
    probe kill the scan. A failed, timed-out or empty collector becomes one
    unavailable metric for that group; a failed, timed-out or empty
    diagnostics section becomes one unavailable finding for that section.

    Budget (optimize-v0.1-discovery todo 5, DV-6): there is NO global time
    cap. This explicitly supersedes the old `under 60 seconds` README promise
    and the removed `TotalBudgetSeconds = 60` default, and is consistent with
    the v0 plan's IS-2 (a scan may take 5-10 minutes on real hardware). Every
    section runs to completion; the only guard is a per-section hard
    termination at 120 s. The pool of 4 is mandatory and runspace-based on
    PowerShell 5.1: a serial fallback is forbidden because 13 x 120 s = 26 min
    would break IS-2's 10-minute ceiling, while ceil(13/4) x 120 s ~= 8 min
    fits. Progress lines go to stderr in the user's language
    (progress.<section> dictionary templates); data.budget carries
    { elapsedMs, perSection: [{id, ms, status}] } and never reports
    `exhausted`.

    Isolation: each live collector runs in its own runspace with
    BeginInvoke() / WaitOne(timeout) / Stop(). Diagnostics sections run on
    one shared runspace pool (max 4) fed by an InitialSessionState that
    pre-imports this module, in batches of 4 with a polled hard deadline per
    batch; WaitHandle.WaitAll is deliberately avoided (STA-unsafe on 5.1).
    No job scheduler, no external process, no shell. Fixture mode runs the
    same runspace-pool path against the validated fixture and performs no
    live probe.

    Honesty: a metric is measured|unavailable|unreliable. A non-measured metric
    always has value $null; a zero is legal only when it was actually measured.
    A diagnostics finding is critical|warn|info|good|unavailable with machine
    evidence; builders stay pure functions of (-Environment, -Scan).

    Writes: a scan writes nothing unless --out is supplied, and --out is
    confined to %LOCALAPPDATA%\pcx\scans\ or the canonical resolved current
    directory. A reparse/junction cwd refuses.
#>

Set-StrictMode -Version 2.0

$script:PcxScanSchema = 'pcx-scan/1'
$script:PcxScanStateSchema = 'pcx-scan-state/1'
$script:PcxScanMetricStatuses = @('measured', 'unavailable', 'unreliable')
$script:PcxCollectorGroups = [ordered]@{
    'identity'         = 'Get-PcxCollectorIdentity'
    'storage'          = 'Get-PcxCollectorStorage'
    'services-startup' = 'Get-PcxCollectorServicesStartup'
    'security'         = 'Get-PcxCollectorSecurityState'
    'intent'           = 'Get-PcxCollectorIntent'
    'printers'         = 'Get-PcxCollectorPrinters'
    'memory'           = 'Get-PcxCollectorMemory'
    'performance'      = 'Get-PcxCollectorPerformance'
}
$script:PcxCollectorGroupDomains = @{
    'identity'         = 'identity'
    'storage'          = 'storage'
    'services-startup' = 'services'
    'security'         = 'security'
    'intent'           = 'intent'
    'printers'         = 'printers'
    'memory'           = 'performance'
    'performance'      = 'performance'
}

# ---------------------------------------------------------------------------
# Diagnostics wiring (todo 5): the 13 pure Get-<Section>Findings builders.
# Order comes from Get-PcxSections (the registry); this map only resolves a
# section id to its builder function name.
# ---------------------------------------------------------------------------

$script:PcxDiagnosticsBuilders = [ordered]@{
    'platform'    = 'Get-PlatformFindings'
    'power'       = 'Get-PowerFindings'
    'storage'     = 'Get-StorageFindings'
    'memory'      = 'Get-MemoryFindings'
    'background'  = 'Get-BackgroundFindings'
    'services'    = 'Get-ServicesFindings'
    'gaming'      = 'Get-GamingFindings'
    'display'     = 'Get-DisplayFindings'
    'network'     = 'Get-NetworkFindings'
    'maintenance' = 'Get-MaintenanceFindings'
    'drivers'     = 'Get-DriversFindings'
    'security'    = 'Get-SecurityFindings'
    'thermal'     = 'Get-ThermalFindings'
}

# Mandatory runspace pool width. A serial fallback is forbidden: with a 120 s
# per-section guard, serial execution degrades to 13 x 120 s = 26 min and
# breaks the v0 plan's IS-2 10-minute ceiling.
$script:PcxDiagnosticsPoolSize = 4

# Hard per-section termination guard in seconds. A hung probe becomes one
# `unavailable` finding and the scan continues; there is no global cap.
$script:PcxDiagnosticsSectionTimeoutSeconds = 120

# ---------------------------------------------------------------------------
# Metric construction and fixture helpers
# ---------------------------------------------------------------------------

function New-PcxMetric {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Group,
        [Parameter(Mandatory = $true)][ValidateSet('measured', 'unavailable', 'unreliable')][string] $Status,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value = $null,
        [Parameter(Mandatory = $true)][string] $Unit,
        [Parameter(Mandatory = $true)][string] $Domain,
        [Parameter(Mandatory = $true)][string] $Window,
        [Parameter(Mandatory = $true)][string] $Source
    )

    if ($Status -eq 'measured' -and $null -eq $Value) {
        $Status = 'unavailable'
    }
    if ($Status -ne 'measured') {
        $Value = $null
    }

    return [ordered]@{
        id     = $Id
        group  = $Group
        status = $Status
        value  = $Value
        unit   = $Unit
        domain = $Domain
        window = $Window
        source = $Source
    }
}

function Get-PcxEnvironmentFieldValue {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Field)

    if ($null -eq $Field) {
        return $null
    }

    $status = [string](Get-PcxPolicyMember -Object $Field -Name 'status')
    if ($status -ne 'measured') {
        return $null
    }

    return Get-PcxPolicyMember -Object $Field -Name 'value'
}

function New-PcxEnvironmentFieldMetric {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Group,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Field,
        [Parameter(Mandatory = $true)][string] $Unit,
        [Parameter(Mandatory = $true)][string] $Domain,
        [Parameter(Mandatory = $true)][string] $Window,
        [Parameter(Mandatory = $true)][string] $Source
    )

    return New-PcxMetric -Id $Id -Group $Group -Status 'measured' -Value (Get-PcxEnvironmentFieldValue -Field $Field) -Unit $Unit -Domain $Domain -Window $Window -Source $Source
}

function ConvertTo-PcxCollectorInt {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }

    try { return [int]$Value }
    catch { return $null }
}

function ConvertTo-PcxCollectorLong {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }

    try { return [long]$Value }
    catch { return $null }
}

function ConvertTo-PcxCollectorDouble {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }

    try { return [double]$Value }
    catch { return $null }
}

function ConvertTo-PcxScanEnvironment {
    # Projects the environment onto the fields the table and the policy profile
    # need. The raw fixture also carries a DateTime capturedAt, which has no
    # canonical JSON representation; the envelope must stay writable.
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Environment)

    if ($null -eq $Environment) { return $null }

    $summary = [ordered]@{}
    foreach ($name in @('sMode', 'managed', 'devDrive', 'anticheat', 'hvci')) {
        $field = Get-PcxPolicyMember -Object $Environment -Name $name
        if ($null -eq $field) {
            $summary[$name] = $null
            continue
        }
        $summary[$name] = [ordered]@{
            value  = Get-PcxPolicyMember -Object $field -Name 'value'
            status = [string](Get-PcxPolicyMember -Object $field -Name 'status')
        }
    }

    # The OS build travels with the scan so the table and the plan can make the
    # same build-family decision from the same data.
    $os = Get-PcxPolicyMember -Object $Environment -Name 'os'
    if ($null -ne $os) {
        $osSummary = [ordered]@{}
        foreach ($name in @('productName', 'build', 'ubr', 'edition')) {
            $field = Get-PcxPolicyMember -Object $os -Name $name
            if ($null -eq $field) {
                $osSummary[$name] = $null
                continue
            }
            $osSummary[$name] = [ordered]@{
                value  = Get-PcxPolicyMember -Object $field -Name 'value'
                status = [string](Get-PcxPolicyMember -Object $field -Name 'status')
            }
        }
        $summary['os'] = $osSummary
    }

    $paths = Get-PcxPolicyMember -Object $Environment -Name 'paths'
    $pathMap = [ordered]@{}
    foreach ($pathName in @('LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA', 'SYSTEMROOT')) {
        $pathMap[$pathName] = [string](Get-PcxPolicyMember -Object $paths -Name $pathName)
    }
    $summary['paths'] = $pathMap

    return [pscustomobject]$summary
}

function Resolve-PcxScanFixtureAlias {
    # Accepts a bare fixture name (desktop, managed, s-mode) as well as a
    # path. A name with no directory separator resolves against
    # tests/fixtures/environment under the repository root; anything that
    # already exists or carries a separator passes through untouched so the
    # downstream reader keeps its typed errors.
    param([Parameter(Mandatory = $false)][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if (($Path -match '[\\/]') -or (Test-Path -LiteralPath $Path)) { return $Path }

    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\..\..'))
    $candidate = [System.IO.Path]::Combine($repoRoot, 'tests', 'fixtures', 'environment', $Path)
    if (Test-Path -LiteralPath $candidate) { return $candidate }

    return $Path
}

function Read-PcxScanFixture {
    param([Parameter(Mandatory = $true)][string] $Path)

    $Path = Resolve-PcxScanFixtureAlias -Path $Path
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $machinePath = $fullPath
    $statePath = $null

    if ([System.IO.Directory]::Exists($fullPath)) {
        $machinePath = [System.IO.Path]::Combine($fullPath, 'machine.json')
        $statePath = [System.IO.Path]::Combine($fullPath, 'state.json')
    }
    else {
        $statePath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($fullPath), 'state.json')
    }

    $environment = Read-PcxEnvironmentFixture -Path $machinePath

    $state = $null
    if ([System.IO.File]::Exists($statePath)) {
        $state = Read-PcxJson -Path $statePath
        $schema = [string](Get-PcxPolicyMember -Object $state -Name 'schema')
        if ($schema -ne $script:PcxScanStateSchema) {
            throw [System.IO.InvalidDataException]::new("PCX-E-SCAN-FIXTURE: '$statePath' schema must be '$($script:PcxScanStateSchema)' (found '$schema').")
        }
    }

    return [pscustomobject][ordered]@{
        environment = $environment
        state       = $state
        machinePath = $machinePath
        statePath   = $(if ($null -ne $state) { $statePath } else { $null })
    }
}

# ---------------------------------------------------------------------------
# Runspace isolation
# ---------------------------------------------------------------------------

function Invoke-PcxCollectorScript {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptText,
        [Parameter(Mandatory = $true)][int] $TimeoutMs,
        [Parameter(Mandatory = $false)][switch] $ImportModule,
        [Parameter(Mandatory = $false)][string] $ModulePath
    )

    $powerShell = [System.Management.Automation.PowerShell]::Create()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()

    try {
        $runspace.Open()
        $powerShell.Runspace = $runspace

        $script = $ScriptText
        if ($ImportModule) {
            $escapedPath = $ModulePath.Replace("'", "''")
            $script = "Import-Module -Name '$escapedPath' -Force; $ScriptText"
        }

        [void]$powerShell.AddScript($script)
        $handle = $powerShell.BeginInvoke()

        if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            try { $powerShell.Stop() } catch { }
            return [pscustomobject]@{ TimedOut = $true; Output = @(); Error = $null }
        }

        $output = @()
        $errorText = $null
        try {
            $output = @($powerShell.EndInvoke($handle))
        }
        catch {
            $errorText = $_.Exception.Message
        }

        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $streamErrors = @($powerShell.Streams.Error | ForEach-Object { $_.ToString() })
            if ($streamErrors.Count -gt 0) {
                $errorText = ($streamErrors -join '; ')
            }
        }

        return [pscustomobject]@{ TimedOut = $false; Output = $output; Error = $errorText }
    }
    catch {
        return [pscustomobject]@{ TimedOut = $false; Output = @(); Error = $_.Exception.Message }
    }
    finally {
        try { $powerShell.Dispose() } catch { }
        try { $runspace.Dispose() } catch { }
    }
}

function ConvertTo-PcxCollectorMetrics {
    # Normalizes whatever a collector returned: every item becomes the fixed
    # metric shape, a malformed item is dropped, a non-measured item loses its
    # value, and an empty group becomes one unavailable metric.
    param(
        [Parameter(Mandatory = $true)][string] $Group,
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $Metrics,
        [Parameter(Mandatory = $true)][string] $FallbackDomain,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $normalized = New-Object System.Collections.Generic.List[object]

    foreach ($item in @($Metrics)) {
        if ($null -eq $item) { continue }

        $id = [string](Get-PcxPolicyMember -Object $item -Name 'id')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $status = [string](Get-PcxPolicyMember -Object $item -Name 'status')
        if ($script:PcxScanMetricStatuses -notcontains $status) {
            $status = 'unavailable'
        }

        $value = Get-PcxPolicyMember -Object $item -Name 'value'
        if ($status -ne 'measured') {
            $value = $null
        }
        if ($status -eq 'measured' -and $null -eq $value) {
            $status = 'unavailable'
        }

        $metricGroup = [string](Get-PcxPolicyMember -Object $item -Name 'group')
        if ([string]::IsNullOrWhiteSpace($metricGroup)) { $metricGroup = $Group }

        $unit = [string](Get-PcxPolicyMember -Object $item -Name 'unit')
        if ([string]::IsNullOrWhiteSpace($unit)) { $unit = 'none' }

        $domain = [string](Get-PcxPolicyMember -Object $item -Name 'domain')
        if ([string]::IsNullOrWhiteSpace($domain)) { $domain = $FallbackDomain }

        $window = [string](Get-PcxPolicyMember -Object $item -Name 'window')
        if ([string]::IsNullOrWhiteSpace($window)) { $window = 'instant' }

        $source = [string](Get-PcxPolicyMember -Object $item -Name 'source')
        if ([string]::IsNullOrWhiteSpace($source)) { $source = 'collector' }

        [void]$normalized.Add((New-PcxMetric -Id $id -Group $metricGroup -Status $status -Value $value -Unit $unit -Domain $domain -Window $window -Source $source))
    }

    if ($normalized.Count -eq 0) {
        [void]$normalized.Add((New-PcxMetric -Id "$Group.unavailable" -Group $Group -Status 'unavailable' -Value $null -Unit 'none' -Domain $FallbackDomain -Window 'instant' -Source (Get-PcxText -Key 'scan.source.nometric' -Language $Language)))
    }

    return $normalized.ToArray()
}

# ---------------------------------------------------------------------------
# Diagnostics pool (no global cap, per-section hard guard, pool of 4)
# ---------------------------------------------------------------------------

function New-PcxDiagnosticsUnavailableFinding {
    # One unavailable finding for a section that threw, timed out or returned
    # nothing. Generic column keys keep the dictionary additive-only; the
    # machine reason travels in evidence (mirrors the builder-internal
    # degrade path, e.g. Get-ThermalFindings).
    param(
        [Parameter(Mandatory = $true)][string] $Section,
        [Parameter(Mandatory = $true)][string] $Reason
    )

    return (New-PcxFinding -Section $Section -Id ($Section + '-unavailable') -Severity 'unavailable' `
        -TitleKey 'column.what' -DetailKey 'column.evidence' `
        -Evidence ([ordered]@{ status = 'unavailable'; reason = $Reason; source = ('diagnostics:' + $Section) }))
}

function Resolve-PcxDiagnosticsJobOutput {
    # Turns one finished (or stopped) pool slot into findings plus a timing
    # status. Never throws: EndInvoke and stream reads are guarded, and the
    # caller's Stop() has already fired for a timed-out slot.
    param(
        [Parameter(Mandatory = $true)][object] $Job,
        [Parameter(Mandatory = $true)][bool] $TimedOut,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )

    $section = [string]$Job.Section
    $ms = [long]$Job.Timer.ElapsedMilliseconds

    if ($TimedOut) {
        $finding = New-PcxDiagnosticsUnavailableFinding -Section $section -Reason ('section exceeded the per-section guard of ' + [string]$TimeoutSeconds + ' s and was terminated')
        return [ordered]@{ findings = @($finding); status = 'timeout'; ms = $ms }
    }

    $output = @()
    $errorText = $null
    try {
        $output = @($Job.PowerShell.EndInvoke($Job.Handle))
    }
    catch {
        $errorText = $_.Exception.Message
    }

    if ([string]::IsNullOrWhiteSpace($errorText)) {
        $streamErrors = @($Job.PowerShell.Streams.Error | ForEach-Object { $_.ToString() })
        if ($streamErrors.Count -gt 0) {
            $errorText = ($streamErrors -join '; ')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($errorText)) {
        $finding = New-PcxDiagnosticsUnavailableFinding -Section $section -Reason ('section failed: ' + [string]$errorText)
        return [ordered]@{ findings = @($finding); status = 'error'; ms = $ms }
    }

    $items = @($output | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        $finding = New-PcxDiagnosticsUnavailableFinding -Section $section -Reason 'section returned no findings'
        return [ordered]@{ findings = @($finding); status = 'empty'; ms = $ms }
    }

    return [ordered]@{ findings = @($items); status = 'completed'; ms = $ms }
}

function Invoke-PcxDiagnosticsSections {
    <#
    .SYNOPSIS
        Runs the 13 diagnostics builders on a mandatory runspace pool.

    .DESCRIPTION
        Every section runs to completion; there is no global cap. The only
        guard is a per-section hard termination at PerSectionTimeoutSeconds
        (default 120): a hung probe becomes one `unavailable` finding and the
        scan continues. Sections run in registry order in batches of PoolSize
        (default 4) on one shared runspace pool whose InitialSessionState
        pre-imports this module, so fixture and live mode share the same
        pool path. Progress lines go to stderr via Write-PcxProgress using
        the progress.<section> dictionary templates in the scan language;
        stdout is never touched.

    .PARAMETER DiagnosticsScripts
        Test seam: a map of section id to a scriptblock (or script text) that
        replaces the builder for that section on the same pool path, so
        timeout and failure behavior is identical.

    .PARAMETER Environment
        The environment object handed to every builder as -Environment
        (fixture machine.json, or the resolved live environment).

    .PARAMETER Scan
        The scan object handed to every builder as -Scan (fixture state.json,
        or the partial live scan).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan,
        [Parameter(Mandatory = $false)][AllowNull()][System.Collections.IDictionary] $DiagnosticsScripts,
        [Parameter(Mandatory = $false)][int] $PerSectionTimeoutSeconds = 120,
        [Parameter(Mandatory = $false)][int] $PoolSize = 4,
        [Parameter(Mandatory = $false)][string] $Language = 'en'
    )

    $sections = @(Get-PcxSections)

    $timeoutMs = $PerSectionTimeoutSeconds * 1000
    if ($timeoutMs -lt 1) { $timeoutMs = 1 }

    $slots = $PoolSize
    if ($slots -lt 1) { $slots = 1 }

    $allFindings = New-Object System.Collections.Generic.List[object]
    $perSection = New-Object System.Collections.Generic.List[object]

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    [void]$sessionState.ImportPSModule(@($script:PcxModuleRoot))
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $slots, $sessionState, $Host)

    try {
        $pool.Open()

        $index = 0
        while ($index -lt $sections.Count) {
            $batch = New-Object System.Collections.Generic.List[string]
            $end = $index + $slots - 1
            if ($end -ge $sections.Count) { $end = $sections.Count - 1 }
            for ($i = $index; $i -le $end; $i++) {
                [void]$batch.Add([string]$sections[$i])
            }

            foreach ($section in $batch) {
                Write-PcxProgress -Message (Get-PcxText -Key ('progress.' + $section) -Language $Language)
            }

            $jobs = New-Object System.Collections.Generic.List[object]
            foreach ($section in $batch) {
                $shell = [System.Management.Automation.PowerShell]::Create()
                $shell.RunspacePool = $pool

                # Variables travel as invocation arguments bound to a param
                # block (SessionStateProxy lives on Runspace, not on the
                # PowerShell instance, so SetVariable is unavailable here).
                # Same-process pool: the environment/scan objects pass by
                # reference; builders never mutate them.
                $override = $null
                if ($null -ne $DiagnosticsScripts -and $DiagnosticsScripts.Contains($section)) {
                    $override = $DiagnosticsScripts[$section]
                }
                if ($null -ne $override) {
                    [void]$shell.AddScript([string]$override)
                }
                else {
                    [void]$shell.AddScript(('param($PcxDiagEnvironment, $PcxDiagScan) ' + $script:PcxDiagnosticsBuilders[$section] + ' -Environment $PcxDiagEnvironment -Scan $PcxDiagScan'))
                }
                [void]$shell.AddArgument($Environment)
                [void]$shell.AddArgument($Scan)

                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $handle = $shell.BeginInvoke()
                [void]$jobs.Add([pscustomobject]@{ Section = $section; PowerShell = $shell; Handle = $handle; Timer = $timer; Done = $false })
            }

            # Polled hard deadline per batch (WaitHandle.WaitAll is STA-unsafe
            # on 5.1): every slot gets up to the full per-section guard, and a
            # batch of 4 costs at most ~120 s, so the worst case stays at
            # ceil(13/4) x 120 s.
            $deadline = [System.DateTime]::UtcNow.AddMilliseconds($timeoutMs)
            $unfinished = $true
            while ($unfinished -and [System.DateTime]::UtcNow -lt $deadline) {
                $unfinished = $false
                foreach ($job in $jobs) {
                    if ($job.Done) { continue }
                    if ($job.Handle.AsyncWaitHandle.WaitOne(250)) {
                        $job.Done = $true
                    }
                    else {
                        $unfinished = $true
                    }
                }
            }

            # Registry order is kept: results append in batch order even when
            # a later section finished first.
            foreach ($job in $jobs) {
                $timedOut = -not $job.Done
                if ($timedOut) {
                    try { $job.PowerShell.Stop() } catch { }
                }
                $resolved = Resolve-PcxDiagnosticsJobOutput -Job $job -TimedOut $timedOut -TimeoutSeconds $PerSectionTimeoutSeconds
                foreach ($finding in @($resolved.findings)) {
                    [void]$allFindings.Add($finding)
                }
                [void]$perSection.Add([ordered]@{ id = [string]$job.Section; ms = [long]$resolved.ms; status = [string]$resolved.status })
                try { $job.Timer.Stop() } catch { }
                try { $job.PowerShell.Dispose() } catch { }
            }

            $index = $end + 1
        }
    }
    finally {
        try { $pool.Close() } catch { }
        try { $pool.Dispose() } catch { }
    }

    return [ordered]@{ findings = $allFindings.ToArray(); perSection = $perSection.ToArray() }
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

function Get-PcxScan {
    <#
    .SYNOPSIS
        Runs the eight collector groups plus the 13 diagnostics sections and
        returns the scan data object.

    .DESCRIPTION
        Fixture mode loads machine.json (and optional state.json) and performs
        no live probe. Live mode runs each collector in an isolated runspace
        with a timeout. A throwing, hanging or empty collector becomes one
        unavailable metric; the scan always completes.

        There is no global time cap: every collector group and every
        diagnostics section runs to completion under its own guard (a
        per-collector timeout, a 120 s per-section hard termination), and
        data.budget carries { elapsedMs, perSection } with no `exhausted`
        flag. The 13 builders are pure functions of (-Environment, -Scan);
        their findings are collected through New-PcxDiagnosticsReport into
        data.diagnosticsReport.

    .PARAMETER CollectorScripts
        Test seam: a map of group id to a scriptblock (or script text) that
        replaces the live collector for that group. It runs in the same
        isolated runspace path, so timeout and failure behavior is identical.

    .PARAMETER DiagnosticsScripts
        Test seam: a map of section id to a scriptblock (or script text) that
        replaces the diagnostics builder for that section. It runs on the
        same mandatory runspace pool, so timeout and failure behavior is
        identical.

    .PARAMETER PerSectionTimeoutSeconds
        Hard per-section termination guard (default 120). A hung section
        becomes one `unavailable` finding and the scan continues.

    .PARAMETER Environment
        Test seam and caller override: the environment object to attach to the
        scan instead of probing the OS. The fixture path always keeps its own
        environment. This is what makes a live-shaped scan testable without a
        live probe.

    .PARAMETER EnvironmentProbe
        Test seam: scriptblock (or script text) that replaces the live
        Get-PcxEnvironment probe. A throwing or hanging probe degrades to
        environment $null plus a typed diagnostic; it never escapes the scan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string] $FixturePath,
        [Parameter(Mandatory = $false)][AllowNull()][System.Collections.IDictionary] $CollectorScripts,
        [Parameter(Mandatory = $false)][AllowNull()][System.Collections.IDictionary] $DiagnosticsScripts,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $EnvironmentProbe,
        [Parameter(Mandatory = $false)][int] $PerSectionTimeoutSeconds = 120,
        [Parameter(Mandatory = $false)][int] $PerCollectorTimeoutSeconds = 20,
        [Parameter(Mandatory = $false)][string] $Language
    )

    $scanLanguage = $Language
    if ([string]::IsNullOrWhiteSpace($scanLanguage)) {
        $scanLanguage = Resolve-PcxLanguage
    }

    if ([string]::IsNullOrWhiteSpace($FixturePath) -and -not [string]::IsNullOrEmpty($env:PCX_TEST_RUN)) {
        throw [System.InvalidOperationException]::new('PCX-E-SCAN-FIXTURE: fixture mode is active (PCX_TEST_RUN) but no fixture path was supplied; refusing to read the live OS.')
    }

    $fixture = $null
    if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
        $fixture = Read-PcxScanFixture -Path $FixturePath
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allMetrics = New-Object System.Collections.Generic.List[object]
    $groups = [ordered]@{}
    $diagnostics = New-Object System.Collections.Generic.List[object]

    # No global time cap (todo 5, DV-6): the scan runs until every collector
    # group and every diagnostics section has reported, consistent with the v0
    # plan's IS-2 (5-10 minutes). Each stage below carries only its own guard:
    # the environment probe and each collector get the per-collector timeout,
    # and each diagnostics section gets the 120 s hard termination.

    # The detected build must travel with every scan, live or fixture, because
    # the table and the plan both read environment.os.build to gate rows. A
    # live probe runs under the per-collector timeout; on timeout, failure or
    # empty output it degrades to $null with a typed diagnostic and the scan
    # still completes, so the build gate fails closed instead of crashing.
    $resolvedEnvironment = $null
    if ($null -ne $fixture) {
        $resolvedEnvironment = $fixture.environment
    }
    elseif ($null -ne $Environment) {
        $resolvedEnvironment = $Environment
    }
    else {
        $probeTimeoutMs = $PerCollectorTimeoutSeconds * 1000
        if ($probeTimeoutMs -lt 1) { $probeTimeoutMs = 1 }

        $probeText = 'Get-PcxEnvironment'
        if ($null -ne $EnvironmentProbe) { $probeText = [string]$EnvironmentProbe }

        $probeRun = Invoke-PcxCollectorScript -ScriptText $probeText -TimeoutMs $probeTimeoutMs -ImportModule -ModulePath $script:PcxModuleRoot
        if ($probeRun.TimedOut) {
            [void]$diagnostics.Add([ordered]@{
                    code      = 'PCX-E-ENVIRONMENT-TIMEOUT'
                    reasonKey = 'scan.env.timeout'
                    message   = Get-PcxText -Key 'scan.env.timeout' -Language $scanLanguage -FormatArgs @($probeTimeoutMs)
                })
        }
        elseif (-not [string]::IsNullOrWhiteSpace($probeRun.Error)) {
            [void]$diagnostics.Add([ordered]@{
                    code      = 'PCX-E-ENVIRONMENT-ERROR'
                    reasonKey = 'scan.env.error'
                    message   = Get-PcxText -Key 'scan.env.error' -Language $scanLanguage -FormatArgs @($probeRun.Error)
                })
        }
        else {
            $probeOutput = @($probeRun.Output)
            if ($probeOutput.Count -gt 0 -and $null -ne $probeOutput[0]) {
                $resolvedEnvironment = $probeOutput[0]
            }
            else {
                [void]$diagnostics.Add([ordered]@{
                        code      = 'PCX-E-ENVIRONMENT-ERROR'
                        reasonKey = 'scan.env.empty'
                        message   = Get-PcxText -Key 'scan.env.empty' -Language $scanLanguage
                    })
            }
        }
    }

    foreach ($group in $script:PcxCollectorGroups.Keys) {
        $timeoutMs = $PerCollectorTimeoutSeconds * 1000
        if ($timeoutMs -lt 1) { $timeoutMs = 1 }

        $groupMetrics = @()
        $override = $null
        if ($null -ne $CollectorScripts -and $CollectorScripts.Contains($group)) {
            $override = $CollectorScripts[$group]
        }

        try {
            if ($null -ne $override) {
                $scriptText = [string]$override
                $run = Invoke-PcxCollectorScript -ScriptText $scriptText -TimeoutMs $timeoutMs
                if ($run.TimedOut) {
                    $groupMetrics = @(New-PcxMetric -Id "$group.timeout" -Group $group -Status 'unavailable' -Value $null -Unit 'none' -Domain $script:PcxCollectorGroupDomains[$group] -Window 'scan' -Source (Get-PcxText -Key 'scan.source.timeout' -Language $scanLanguage -FormatArgs @($timeoutMs)))
                    [void]$diagnostics.Add([ordered]@{ code = 'PCX-E-COLLECTOR-TIMEOUT'; reasonKey = 'scan.collector.timeout'; message = Get-PcxText -Key 'scan.collector.timeout' -Language $scanLanguage -FormatArgs @($group, $timeoutMs) })
                }
                elseif (-not [string]::IsNullOrWhiteSpace($run.Error)) {
                    $groupMetrics = @(New-PcxMetric -Id "$group.error" -Group $group -Status 'unavailable' -Value $null -Unit 'none' -Domain $script:PcxCollectorGroupDomains[$group] -Window 'scan' -Source (Get-PcxText -Key 'scan.source.failed' -Language $scanLanguage))
                    [void]$diagnostics.Add([ordered]@{ code = 'PCX-E-COLLECTOR-ERROR'; reasonKey = 'scan.collector.error'; message = Get-PcxText -Key 'scan.collector.error' -Language $scanLanguage -FormatArgs @($group, $run.Error) })
                }
                else {
                    $groupMetrics = @($run.Output)
                }
            }
            elseif ($null -ne $fixture) {
                $groupMetrics = @(& $script:PcxCollectorGroups[$group] -Fixture $fixture)
            }
            else {
                $modulePath = $script:PcxModuleRoot
                $run = Invoke-PcxCollectorScript -ScriptText $script:PcxCollectorGroups[$group] -TimeoutMs $timeoutMs -ImportModule -ModulePath $modulePath
                if ($run.TimedOut) {
                    $groupMetrics = @(New-PcxMetric -Id "$group.timeout" -Group $group -Status 'unavailable' -Value $null -Unit 'none' -Domain $script:PcxCollectorGroupDomains[$group] -Window 'scan' -Source (Get-PcxText -Key 'scan.source.timeout' -Language $scanLanguage -FormatArgs @($timeoutMs)))
                    [void]$diagnostics.Add([ordered]@{ code = 'PCX-E-COLLECTOR-TIMEOUT'; reasonKey = 'scan.collector.timeout'; message = Get-PcxText -Key 'scan.collector.timeout' -Language $scanLanguage -FormatArgs @($group, $timeoutMs) })
                }
                elseif (-not [string]::IsNullOrWhiteSpace($run.Error)) {
                    $groupMetrics = @(New-PcxMetric -Id "$group.error" -Group $group -Status 'unavailable' -Value $null -Unit 'none' -Domain $script:PcxCollectorGroupDomains[$group] -Window 'scan' -Source (Get-PcxText -Key 'scan.source.failed' -Language $scanLanguage))
                    [void]$diagnostics.Add([ordered]@{ code = 'PCX-E-COLLECTOR-ERROR'; reasonKey = 'scan.collector.error'; message = Get-PcxText -Key 'scan.collector.error' -Language $scanLanguage -FormatArgs @($group, $run.Error) })
                }
                else {
                    $groupMetrics = @($run.Output)
                }
            }
        }
        catch {
            $groupMetrics = @(New-PcxMetric -Id "$group.error" -Group $group -Status 'unavailable' -Value $null -Unit 'none' -Domain $script:PcxCollectorGroupDomains[$group] -Window 'scan' -Source (Get-PcxText -Key 'scan.source.failed' -Language $scanLanguage))
            [void]$diagnostics.Add([ordered]@{ code = 'PCX-E-COLLECTOR-ERROR'; reasonKey = 'scan.collector.error'; message = Get-PcxText -Key 'scan.collector.error' -Language $scanLanguage -FormatArgs @($group, $_.Exception.Message) })
        }

        $normalized = ConvertTo-PcxCollectorMetrics -Group $group -Metrics $groupMetrics -FallbackDomain $script:PcxCollectorGroupDomains[$group] -Language $scanLanguage
        $measuredCount = @($normalized | Where-Object { $_.status -eq 'measured' }).Count
        $groupStatus = if ($measuredCount -gt 0) { 'measured' } else { 'unavailable' }

        $groups[$group] = [ordered]@{ id = $group; status = $groupStatus; metrics = @($normalized) }
        foreach ($metric in $normalized) {
            [void]$allMetrics.Add($metric)
        }
    }

    # Diagnostics phase: all 13 builders run to completion on the mandatory
    # pool of 4 under the per-section hard guard. The builders are pure
    # functions of (-Environment, -Scan): fixture mode hands them the fixture
    # machine.json/state.json pair (the same pair the diagnostics suite calls
    # them with), live mode hands them the resolved environment plus the
    # partial scan collected above.
    $diagEnvironment = $null
    $diagScan = $null
    if ($null -ne $fixture) {
        $diagEnvironment = $fixture.environment
        $diagScan = $fixture.state
    }
    else {
        $diagEnvironment = $resolvedEnvironment
        $diagScan = [ordered]@{
            groups      = $groups
            metrics     = $allMetrics.ToArray()
            environment = $resolvedEnvironment
        }
    }

    $diagResult = Invoke-PcxDiagnosticsSections -Environment $diagEnvironment -Scan $diagScan `
        -DiagnosticsScripts $DiagnosticsScripts -PerSectionTimeoutSeconds $PerSectionTimeoutSeconds `
        -PoolSize $script:PcxDiagnosticsPoolSize -Language $scanLanguage
    $diagReport = New-PcxDiagnosticsReport -Findings $diagResult.findings

    $stopwatch.Stop()

    return [ordered]@{
        schema     = $script:PcxScanSchema
        fixture    = ($null -ne $fixture)
        capturedAt = [System.DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        budget     = [ordered]@{
            elapsedMs  = $stopwatch.ElapsedMilliseconds
            perSection = $diagResult.perSection
        }
        groups     = $groups
        metrics    = $allMetrics.ToArray()
        environment = $(if ($null -ne $resolvedEnvironment) { ConvertTo-PcxScanEnvironment -Environment $resolvedEnvironment } else { $null })
        diagnostics = $diagnostics.ToArray()
        diagnosticsReport = $diagReport
    }
}

# ---------------------------------------------------------------------------
# --out confinement
# ---------------------------------------------------------------------------

function Test-PcxPathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char]'\', [char]'/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)

    if ([string]::Equals($pathFull, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PcxNoReparseInPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char]'\', [char]'/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $relative = $pathFull.Substring($rootFull.Length).TrimStart([char]'\', [char]'/')
    $current = $rootFull

    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        $current = Join-Path -Path $current -ChildPath $segment
        if ([System.IO.Directory]::Exists($current) -or [System.IO.File]::Exists($current)) {
            $attributes = [System.IO.File]::GetAttributes($current)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw [System.UnauthorizedAccessException]::new("PCX-E-OUT-DENIED: '$current' is a reparse point; the out path must not leave its root through a junction.")
            }
        }
    }
}

function Resolve-PcxScanOutPath {
    param([Parameter(Mandatory = $true)][string] $OutPath)

    if ([string]::IsNullOrWhiteSpace($OutPath)) {
        throw [System.ArgumentException]::new('PCX-E-OUT-DENIED: --out needs a file path.')
    }

    if ($OutPath -match '^[\\/]{2}') {
        throw [System.UnauthorizedAccessException]::new("PCX-E-OUT-DENIED: UNC path '$OutPath' is not an allowed scan location.")
    }

    if ($OutPath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw [System.UnauthorizedAccessException]::new("PCX-E-OUT-DENIED: '$OutPath' contains a '..' segment.")
    }

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        throw [System.UnauthorizedAccessException]::new('PCX-E-OUT-DENIED: the current location is not a filesystem directory.')
    }

    $currentDirectory = [System.IO.Path]::GetFullPath($location.ProviderPath)
    $currentItem = Get-Item -LiteralPath $currentDirectory -Force -ErrorAction Stop
    if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw [System.UnauthorizedAccessException]::new("PCX-E-OUT-DENIED: the current directory '$currentDirectory' is a reparse/junction; --out refuses it.")
    }

    $fullPath = if ([System.IO.Path]::IsPathRooted($OutPath)) {
        [System.IO.Path]::GetFullPath($OutPath)
    }
    else {
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($currentDirectory, $OutPath))
    }

    if ([System.IO.Directory]::Exists($fullPath)) {
        throw [System.UnauthorizedAccessException]::new("PCX-E-OUT-DENIED: '$fullPath' is a directory, not a scan file.")
    }

    $stateScans = Get-PcxStatePath -Kind 'scans'
    $underState = Test-PcxPathUnderRoot -Path $fullPath -Root $stateScans
    $underCurrent = Test-PcxPathUnderRoot -Path $fullPath -Root $currentDirectory

    if (-not $underState -and -not $underCurrent) {
        throw [System.UnauthorizedAccessException]::new("PCX-E-OUT-DENIED: '$fullPath' is outside the allowed scan locations ('$stateScans' or the current directory '$currentDirectory').")
    }

    $root = if ($underState) { $stateScans } else { $currentDirectory }
    Assert-PcxNoReparseInPath -Path $fullPath -Root $root

    return $fullPath
}

# ---------------------------------------------------------------------------
# Command surface
# ---------------------------------------------------------------------------

function Read-PcxTuneArguments {
    param([Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]] $Arguments = @())

    $options = [ordered]@{
        FixturePath = $null
        ProfilePath = $null
        OutPath     = $null
        Table       = $false
        Language    = $null
    }

    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        switch ($token) {
            '--lang' {
                $index++
                if ($index -ge $Arguments.Count) { throw 'PCX-E-SCAN-ARG: --lang requires a language code (en, ru).' }
                $options['Language'] = Resolve-PcxLanguage -Requested ([string]$Arguments[$index])
            }
            '--fixture' {
                $index++
                if ($index -ge $Arguments.Count) { throw 'PCX-E-SCAN-ARG: --fixture requires a path.' }
                $options['FixturePath'] = [string]$Arguments[$index]
            }
            '--profile' {
                $index++
                if ($index -ge $Arguments.Count) { throw 'PCX-E-SCAN-ARG: --profile requires a path.' }
                $options['ProfilePath'] = [string]$Arguments[$index]
            }
            '--out' {
                $index++
                if ($index -ge $Arguments.Count) { throw 'PCX-E-SCAN-ARG: --out requires a path.' }
                $options['OutPath'] = [string]$Arguments[$index]
            }
            '--table' {
                $options['Table'] = $true
            }
            '--proposals' {
                throw 'PCX-E-SCAN-ARG: --proposals requires --apply; proposals are validated by the plan engine and applied one item per call.'
            }
            default {
                throw "PCX-E-SCAN-ARG: unexpected argument '$token' for tune."
            }
        }
        $index++
    }

    return [pscustomobject]$options
}

function Invoke-PcxTune {
    <#
    .SYNOPSIS
        Read-only `pcx tune`: returns one scan envelope, optionally written to
        an allowed --out file. No table renderer yet; --table is accepted and
        recorded as a pending-renderer diagnostic.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]] $Arguments = @())

    try {
        $options = Read-PcxTuneArguments -Arguments $Arguments
    }
    catch {
        $caught = $_.Exception.Message
        if ($caught.StartsWith('PCX-E-LANG', [System.StringComparison]::Ordinal)) {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-LANG' -Message $caught
        }
        return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-SCAN-ARG' -Message $caught
    }

    $profileData = $null
    if (-not [string]::IsNullOrWhiteSpace($options.ProfilePath)) {
        try {
            $profileData = Read-PcxJson -Path $options.ProfilePath
        }
        catch {
            return New-PcxError -CommandName 'tune' -Code 'PCX-E-PROFILE' -Message "The profile could not be read: $($_.Exception.Message)"
        }
    }

    $language = $options.Language
    if ([string]::IsNullOrWhiteSpace($language)) {
        $language = Resolve-PcxLanguage
    }

    try {
        $data = Get-PcxScan -FixturePath $options.FixturePath -Language $language
    }
    catch {
        $message = $_.Exception.Message
        if ($message.StartsWith('PCX-E-SCAN-FIXTURE', [System.StringComparison]::Ordinal)) {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-SCAN-FIXTURE' -Message $message
        }
        return New-PcxError -CommandName 'tune' -Code 'PCX-E-SCAN' -Message $message
    }

    $data['language'] = $language

    if ($null -ne $profileData) {
        $data['profile'] = $profileData
    }

    # Todo 5 wiring: data.diagnostics is the 13-section diagnostics report
    # (the renderer contract consumed by todo 6); the collector-stage entries
    # move to the envelope diagnostics where typed codes belong.
    $collectorDiagnostics = @($data['diagnostics'])
    $data['diagnostics'] = $data['diagnosticsReport']
    $data.Remove('diagnosticsReport')

    $diagnostics = @($collectorDiagnostics)
    if ($options.Table) {
        try {
            $rendered = Invoke-PcxTable -Scan $data -Profile $profileData
        }
        catch {
            return New-PcxError -CommandName 'tune' -Code 'PCX-E-TABLE' -Message "The tune table could not be rendered: $($_.Exception.Message)"
        }

        $data['table'] = $rendered.table
        $data['findings'] = @($rendered.visibleRows | Sort-Object { [int]$_.number })
        $data['tableRowCount'] = $rendered.rowCount
        $data['tableTruncated'] = $rendered.truncated
    }

    $fullOut = $null
    if (-not [string]::IsNullOrWhiteSpace($options.OutPath)) {
        try {
            $fullOut = Resolve-PcxScanOutPath -OutPath $options.OutPath
        }
        catch {
            return New-PcxRefusal -CommandName 'tune' -Code 'PCX-E-OUT-DENIED' -Message $_.Exception.Message
        }
        $data['out'] = $fullOut
    }

    $envelope = New-PcxEnvelope -Status 'ok' -CommandName 'tune' -ExitCode $script:PcxExitOk -Data $data -Diagnostics $diagnostics

    if ($null -ne $fullOut) {
        try {
            [void](Write-PcxJsonAtomic -Path $fullOut -InputObject $envelope)
        }
        catch {
            return New-PcxError -CommandName 'tune' -Code 'PCX-E-OUT-WRITE' -Message "The scan envelope could not be written: $($_.Exception.Message)"
        }
    }

    return New-PcxResult -ExitCode $script:PcxExitOk -Envelope $envelope
}
