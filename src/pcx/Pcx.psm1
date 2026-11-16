<#
.SYNOPSIS
    pcx dispatch module.

.DESCRIPTION
    Dispatch surface only. This file resolves the user-facing command
    (doctor / tune / undo), validates subcommand tokens, and returns a single
    envelope result. Core primitives live in src/pcx/Core:

        Core/PcxJson.ps1      canonical JSON, SHA-256, typed read, atomic write
        Core/PcxState.ps1     %LOCALAPPDATA%\pcx and its containment guard
        Core/PcxEnvelope.ps1  envelope constructors, exit codes, stderr progress
        Core/PcxPlatform.ps1  the only OS boundary (registry, service, task, file)
        Commands/Invoke-PcxDoctor.ps1  read-only doctor report

    Every function returns a result object:
        @{ ExitCode = <int>; Envelope = <ordered hashtable> }
    The caller (pcx.ps1) owns stdout serialization and the real-write arming
    window; this module never arms PCX_ALLOW_REAL_WRITES.

    Exit codes: 0 ok, 1 error, 2 refused, 3 undo refused (nothing was reverted).
#>

Set-StrictMode -Version 2.0

# Absolute module root, used by Get-PcxScan to import this module inside the
# isolated collector runspace. Set once per module load.
$script:PcxModuleRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath 'Pcx.psm1'))

. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxEnvelope.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxJson.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxState.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxText.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxPlatform.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxSnapshot.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxPolicy.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxEnvironment.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxEvidence.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxFindings.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Core/PcxCatalog.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Providers/ProviderCommon.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Providers/RegistryProvider.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Providers/ServiceProvider.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Providers/TaskProvider.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Providers/FileProvider.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/IdentityCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/StorageCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/ServicesStartupCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/SecurityStateCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/IntentCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/PrintersCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/MemoryCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Collectors/PerformanceCollector.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/BackgroundDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/DisplayDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/DriversDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/GamingDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/MaintenanceDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/MemoryDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/NetworkDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/PlatformDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/PowerDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/SecurityDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/ServicesDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/StorageDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Diagnostics/ThermalDiagnostics.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxTune.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxTable.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxProbe.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxPlan.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxApply.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxQueue.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxUndo.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxStatus.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Commands/Invoke-PcxDoctor.ps1')

function Get-PcxHelpData {
    return [ordered]@{
        name     = 'pcx'
        version  = $script:PcxProductVersion
        commands = @('doctor', 'tune', 'undo', 'probe')
        usage    = @(
            'pcx doctor'
            'pcx tune [--lang <code>] [--fixture <path>] [--profile <path>] [--out <path>] [--table]'
            'pcx tune --apply [--plan <plan-id>] [--console] [--proposals <path>]'
            'pcx probe <spec> [--fixture <path>]'
            'pcx undo --last'
            'pcx undo --item <item-id>'
            'pcx undo --plan <plan-id>'
        )
        flags    = @('--help', '--apply', '--plan', '--console', '--item', '--last', '--fixture', '--profile', '--out', '--table', '--lang', '--proposals')
        note     = 'Read-only tune, tune --apply (agent or console) and hash-proven undo are available; status stays internal.'
    }
}

function Test-PcxSubCommandToken {
    # Only long-form switches are validated here; positional values (plan ids,
    # item ids, selection tokens) are parsed by the command modules.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Tokens,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Allowed
    )

    foreach ($token in $Tokens) {
        if ($token -like '--*' -and $Allowed -notcontains $token) {
            return $token
        }
    }

    return $null
}

function Test-PcxProbePolicy {
    <#
    .SYNOPSIS
        Policy pre-check for reg/task probe specs. Returns $null when the
        probe may proceed, or a pcx refusal result when the target is denied.

    .DESCRIPTION
        Never touches the OS: only Test-PcxTarget (pure) runs here, before
        Invoke-PcxProbe is ever called. Registry policy carries no write
        intent, so the full gate applies. A task probe is checked with the
        disabling intent a probe can only ever observe. Svc/file specs carry
        no Start/Role for the write gate to evaluate, and counter, event,
        intent and environment are not write targets at all, so those
        families go straight to the read-only engine.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Spec,
        [Parameter(Mandatory = $true)][string] $Family,
        [Parameter(Mandatory = $false)][AllowNull()][string] $FixturePath
    )

    $payload = $Spec.Substring($Spec.IndexOf(':') + 1)
    $typed = $null
    if ($Family -eq 'reg') {
        $hash = $payload.LastIndexOf('#')
        if ($hash -lt 0) { return $null }
        $path = $payload.Substring(0, $hash).Trim()
        $name = $payload.Substring($hash + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($name)) { return $null }
        $typed = [ordered]@{ Kind = 'registry'; Path = $path; Name = $name }
    }
    elseif ($Family -eq 'task') {
        if ([string]::IsNullOrWhiteSpace($payload)) { return $null }
        $typed = [ordered]@{ Kind = 'task'; Path = $payload.Trim(); Enabled = $false }
    }
    else {
        return $null
    }

    $profileObject = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
            $environment = Get-PcxEnvironment -FixturePath $FixturePath
            $profileObject = ConvertTo-PcxPolicyProfile -Environment $environment
        }
        elseif ([string]::IsNullOrEmpty($env:PCX_TEST_RUN)) {
            $environment = Get-PcxEnvironment
            $profileObject = ConvertTo-PcxPolicyProfile -Environment $environment
        }
    }
    catch {
        $profileObject = $null
    }
    if ($null -eq $profileObject) { return $null }

    $decision = $null
    try {
        $decision = Test-PcxTarget -Target $typed -Profile $profileObject
    }
    catch {
        return $null
    }
    if ($null -eq $decision) { return $null }
    if ([bool](Get-PcxPolicyMember -Object $decision -Name 'allowed')) { return $null }

    $code = [string](Get-PcxPolicyMember -Object $decision -Name 'code')
    $reason = [string](Get-PcxPolicyMember -Object $decision -Name 'reason')
    if ([string]::IsNullOrWhiteSpace($code)) { $code = 'PCX-POLICY-GRAMMAR' }
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'the probe target is not allowed.' }
    return New-PcxRefusal -CommandName 'probe' -Code $code -Message $reason
}

function Invoke-PcxProbeCommand {
    <#
    .SYNOPSIS
        Parses `pcx probe <spec> [--fixture <path>]` and returns a pcx result object.

    .DESCRIPTION
        Thin CLI surface over Invoke-PcxProbe: exactly one spec per call. The
        engine owns grammar and measurement; this wrapper only maps the typed
        result into the standard envelope. A refused engine result becomes a
        refused envelope with the engine typed code; anything else becomes an
        ok envelope carrying family/status/value/unit/source/code/reason/
        target. Never arms real writes: probe is absent from the pcx.ps1
        arming set, and the engine file declares no write path.
    #>
    param([Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]] $Arguments = @())

    $spec = $null
    $specCount = 0
    $fixture = $null

    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        if ($token -eq '--fixture') {
            if (($index + 1) -ge $Arguments.Count) {
                return New-PcxRefusal -CommandName 'probe' -Code 'PCX-E-PROBE-ARG' -Message 'PCX-E-PROBE-ARG: --fixture requires a path.'
            }
            $fixture = [string]$Arguments[$index + 1]
            $index += 2
            continue
        }
        if (-not $token.StartsWith('--')) {
            $specCount++
            if ($null -eq $spec) { $spec = $token }
        }
        $index++
    }

    if ($specCount -eq 0 -or [string]::IsNullOrWhiteSpace($spec)) {
        return New-PcxRefusal -CommandName 'probe' -Code 'PCX-E-PROBE-ARG' -Message 'PCX-E-PROBE-ARG: probe needs exactly one spec, for example reg:HKCU\Software\PcxProbe#Answer.'
    }
    if ($specCount -gt 1) {
        return New-PcxRefusal -CommandName 'probe' -Code 'PCX-E-PROBE-ARG' -Message 'PCX-E-PROBE-ARG: probe accepts exactly one spec per call.'
    }

    $family = $null
    $colon = $spec.IndexOf(':')
    if ($colon -gt 0) { $family = $spec.Substring(0, $colon).ToLowerInvariant() }

    if ($family -eq 'reg' -or $family -eq 'task') {
        $denial = Test-PcxProbePolicy -Spec $spec -Family $family -FixturePath $fixture
        if ($null -ne $denial) { return $denial }
    }

    $probeResult = $null
    try {
        if ([string]::IsNullOrWhiteSpace($fixture)) {
            $probeResult = Invoke-PcxProbe -Probe $spec
        }
        else {
            $probeResult = Invoke-PcxProbe -Probe $spec -FixturePath $fixture
        }
    }
    catch {
        return New-PcxError -CommandName 'probe' -Code 'PCX-E-PROBE' -Message $_.Exception.Message
    }

    $status = [string](Get-PcxPolicyMember -Object $probeResult -Name 'status')
    if ($status -eq 'refused') {
        $code = [string](Get-PcxPolicyMember -Object $probeResult -Name 'code')
        $reason = [string](Get-PcxPolicyMember -Object $probeResult -Name 'reason')
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'PCX-E-PROBE-ARG' }
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'the probe was refused.' }
        return New-PcxRefusal -CommandName 'probe' -Code $code -Message $reason
    }

    $data = [ordered]@{
        spec   = $spec
        family = [string](Get-PcxPolicyMember -Object $probeResult -Name 'family')
        status = $status
        value  = Get-PcxPolicyMember -Object $probeResult -Name 'value'
        unit   = [string](Get-PcxPolicyMember -Object $probeResult -Name 'unit')
        source = [string](Get-PcxPolicyMember -Object $probeResult -Name 'source')
        code   = Get-PcxPolicyMember -Object $probeResult -Name 'code'
        reason = Get-PcxPolicyMember -Object $probeResult -Name 'reason'
        target = Get-PcxPolicyMember -Object $probeResult -Name 'target'
    }

    return New-PcxResult -ExitCode $script:PcxExitOk -Envelope (New-PcxEnvelope -Status 'ok' -CommandName 'probe' -ExitCode $script:PcxExitOk -Data $data)
}

function Invoke-PcxDispatch {
    <#
    .SYNOPSIS
        Dispatches one pcx invocation and returns a result object.

    .DESCRIPTION
        Never writes to stdout and never exits. Arming of
        PCX_ALLOW_REAL_WRITES is the caller's responsibility.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]] $Arguments = @()
    )

    $tokens = @($Arguments | Where-Object { $null -ne $_ -and '' -ne ([string]$_).Trim() } | ForEach-Object { [string]$_ })

    if ($tokens.Count -eq 0) {
        $command = 'help'
    }
    else {
        $command = $tokens[0]
        $rest = @()
        if ($tokens.Count -gt 1) {
            $rest = @($tokens[1..($tokens.Count - 1)])
        }
    }

    if ($command -eq 'help' -or $command -eq '--help' -or $command -eq '-help' -or $command -eq '-h') {
        return New-PcxResult -ExitCode $script:PcxExitOk -Envelope (New-PcxEnvelope -Status 'ok' -CommandName 'help' -ExitCode $script:PcxExitOk -Data (Get-PcxHelpData))
    }

    $subCommands = @{
        'doctor'         = @()
        'tune'           = @('--apply', '--plan', '--console', '--fixture', '--profile', '--out', '--table', '--lang', '--proposals')
        'probe'          = @('--fixture')
        'undo'           = @('--item', '--plan', '--last')
        'apply-elevated' = @('--payload', '--hash', '--sid', '--run')
        'undo-elevated'  = @('--payload', '--hash', '--sid', '--run')
    }

    if (-not $subCommands.ContainsKey($command)) {
        return New-PcxRefusal -CommandName $command -Code 'PCX-E-COMMAND' -Message "Unknown command '$command'. Known commands: doctor, tune, undo, probe."
    }

    $allowed = @($subCommands[$command])

    $unknown = Test-PcxSubCommandToken -Tokens $rest -Allowed $allowed
    if ($null -ne $unknown) {
        $allowedText = if ($allowed.Count -eq 0) { '(none)' } else { $allowed -join ', ' }
        return New-PcxRefusal -CommandName $command -Code 'PCX-E-SUBCOMMAND' -Message "Unknown option '$unknown' for command '$command'. Allowed: $allowedText."
    }

    switch ($command) {
        'doctor' {
            return Invoke-PcxDoctor
        }
        'probe' {
            return Invoke-PcxProbeCommand -Arguments $rest
        }
        'tune' {
            if ($rest -contains '--apply') {
                return Invoke-PcxApplyCommand -Arguments $rest
            }
            return Invoke-PcxTune -Arguments $rest
        }
        'undo' {
            return Invoke-PcxUndoCommand -Arguments $rest
        }
        'apply-elevated' {
            return Invoke-PcxApplyElevatedCommand -Arguments $rest
        }
        'undo-elevated' {
            return Invoke-PcxUndoElevatedCommand -Arguments $rest
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-PcxDispatch'
    'New-PcxEnvelope'
    'New-PcxResult'
    'New-PcxRefusal'
    'New-PcxError'
    'Write-PcxProgress'
    'ConvertTo-PcxCanonicalJson'
    'Get-PcxSha256'
    'Read-PcxJson'
    'Write-PcxJsonAtomic'
    'Get-PcxStateRoot'
    'Initialize-PcxState'
    'Get-PcxStatePath'
    'Resolve-PcxLanguage'
    'Get-PcxText'
    'Get-PcxSeverityLabel'
    'Get-PcxSectionTitle'
    'Get-PcxPlatform'
    'Invoke-PcxPlatformRead'
    'Invoke-PcxPlatformWrite'
    'Invoke-PcxPlatformDelete'
    'Invoke-PcxPlatformMove'
    'Get-PcxTargetState'
    'New-PcxSnapshot'
    'Compare-PcxState'
    'Restore-PcxSnapshot'
    'ConvertTo-PcxTarget'
    'Test-PcxTarget'
    'Test-PcxEvidenceRef'
    'Get-PcxSections'
    'New-PcxFinding'
    'New-PcxDiagnosticsReport'
    'Test-PcxFindingGroupMap'
    'ConvertTo-PcxFindingsDocument'
    'Get-PcxCatalog'
    'Test-PcxCatalogAction'
    'Get-PcxEnvironment'
    'ConvertTo-PcxPolicyProfile'
    'Get-PcxRegistryProviderState'
    'Invoke-PcxRegistryProviderApply'
    'Test-PcxRegistryProviderState'
    'Get-PcxServiceProviderState'
    'Invoke-PcxServiceProviderApply'
    'Test-PcxServiceProviderState'
    'Get-PcxTaskProviderState'
    'Invoke-PcxTaskProviderApply'
    'Test-PcxTaskProviderState'
    'Get-PcxFileProviderState'
    'Invoke-PcxFileProviderApply'
    'Test-PcxFileProviderResult'
    'Get-PcxCollectorIdentity'
    'Get-PcxCollectorStorage'
    'Get-PcxCollectorServicesStartup'
    'Get-PcxCollectorSecurityState'
    'Get-PcxCollectorIntent'
    'Get-PcxCollectorPrinters'
    'Get-PcxCollectorMemory'
    'Get-PcxCollectorPerformance'
    'Get-BackgroundFindings'
    'Get-DisplayFindings'
    'Get-DriversFindings'
    'Get-GamingFindings'
    'Get-MaintenanceFindings'
    'Get-MemoryFindings'
    'Get-NetworkFindings'
    'Get-PlatformFindings'
    'Get-PowerFindings'
    'Get-SecurityFindings'
    'Get-ServicesFindings'
    'Get-StorageFindings'
    'Get-ThermalFindings'
    'Get-PcxScan'
    'Invoke-PcxTune'
    'Invoke-PcxTable'
    'Invoke-PcxProbe'
    'Invoke-PcxPlan'
    'Test-PcxPlan'
    'Invoke-PcxApply'
    'Invoke-PcxQueue'
    'Invoke-PcxApplyElevated'
    'Invoke-PcxApplyElevatedLoop'
    'Invoke-PcxUndo'
    'Invoke-PcxUndoElevated'
    'Invoke-PcxUndoElevatedLoop'
    'Invoke-PcxStatus'
    'Invoke-PcxDoctor'
)
