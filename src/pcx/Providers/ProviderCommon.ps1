<#
.SYNOPSIS
    Shared write-provider pipeline: policy gate, value-level snapshot,
    platform write, read-back verify, and the typed result shape.

.DESCRIPTION
    Every provider implements exactly Read -> Apply -> Verify. Registry,
    service and task differ only in their target kind, so their pipeline lives
    here once. File keeps its own pipeline (a manifest delete and a quarantine
    move are not value writes) but uses the same result constructor, plan-id
    validation and environment resolution.

    Hard rules enforced here:
      * Test-PcxTarget runs FIRST in Apply; a refused target never reaches a
        read, a snapshot or a write.
      * The only OS access is the platform boundary
        (Invoke-PcxPlatformRead / Write / Delete / Move).
      * No native cmdlet, no shell, no expression evaluation.
      * The pre-state is always read before the write; the expected post-state
        is read back and verified with Compare-PcxState.

    Status vocabulary: COMMITTED (read-back verified), FAILED (operational
    failure), REFUSED (policy, grammar or validation). A result with residue is
    never COMMITTED.

    Module-private helpers from PcxSnapshot.ps1 / PcxPolicy.ps1 are used
    directly: every file dot-sources into one module scope.
#>

Set-StrictMode -Version 2.0

$script:PcxProviderResultSchema = 'pcx-provider-result/1'
$script:PcxProviderPlanIdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

function Stop-PcxProvider {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message
    )

    throw [System.InvalidOperationException]::new(('{0}: {1}' -f $Code, $Message))
}

function New-PcxProviderResult {
    <#
    .SYNOPSIS
        Builds the uniform provider result map.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string] $Kind,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Code,
        [Parameter(Mandatory = $false)][AllowNull()][string] $Reason
    )

    $result = [ordered]@{
        schema       = $script:PcxProviderResultSchema
        status       = $Status
        kind         = $Kind
        target       = $Target
        code         = $Code
        reason       = $Reason
        snapshot     = $null
        manifest     = @()
        manifestPath = $null
        restorable   = $false
        restoreMode  = $null
        deleted      = @()
        residue      = @()
        skipped      = @()
        restorePath  = $null
    }

    return $result
}

function Get-PcxProviderKind {
    <#
    .SYNOPSIS
        Validates the target kind and returns it.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Expected
    )

    $kind = Get-PcxSnapshotKind -Target $Target
    if ($kind -ne $Expected) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-KIND' -Message "expected a $Expected target, received '$kind'."
    }

    return $kind
}

function Resolve-PcxProviderAbsolutePath {
    <#
    .SYNOPSIS
        Rejects wildcards, '..' segments and relative paths, then returns the
        normalized absolute path.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-PATH' -Message 'a concrete absolute path is required.'
    }
    if ($Path.Contains('*') -or $Path.Contains('?')) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-PATH' -Message "path '$Path' contains a wildcard."
    }
    if ([regex]::IsMatch($Path, '(^|[\\/])\.\.([\\/]|$)')) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-PATH' -Message "path '$Path' contains a '..' segment."
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-PATH' -Message "path '$Path' must be absolute."
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PcxProviderPathUnder {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $candidate = $Path.TrimEnd([char]'\')
    $bound = $Root.TrimEnd([char]'\')
    if ([string]::Equals($candidate, $bound, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $candidate.StartsWith($bound + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PcxProviderPathStrictlyUnder {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    if ([string]::Equals($Path.TrimEnd([char]'\'), $Root.TrimEnd([char]'\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return Test-PcxProviderPathUnder -Path $Path -Root $Root
}

function Resolve-PcxProviderPlanId {
    <#
    .SYNOPSIS
        Reads and validates the explicit PlanId member of a file target.
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $planId = [string](Get-PcxSnapshotMember -Object $Target -Name 'PlanId')
    if ([string]::IsNullOrWhiteSpace($planId)) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-PLANID' -Message 'a file target must carry an explicit PlanId; the provider never invents one.'
    }
    if ($planId -notmatch $script:PcxProviderPlanIdPattern) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-PLANID' -Message "PlanId '$planId' is not a safe token."
    }

    return $planId
}

function Get-PcxProviderStateRoot {
    <#
    .SYNOPSIS
        Resolves %LOCALAPPDATA%\pcx from the injected profile environment.
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Profile)

    $environment = Get-PcxSnapshotMember -Object $Profile -Name 'environment'
    $localAppData = [string](Get-PcxSnapshotMember -Object $environment -Name 'LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [System.IO.Path]::IsPathRooted($localAppData)) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-ENVIRONMENT' -Message 'the profile environment has no absolute LOCALAPPDATA; the pcx state root cannot be resolved.'
    }

    return [System.IO.Path]::Combine([System.IO.Path]::GetFullPath($localAppData), 'pcx')
}

function Get-PcxProviderErrorCode {
    <#
    .SYNOPSIS
        Extracts a leading PCX-* code from an error record.
    #>
    param([Parameter(Mandatory = $true)][object] $ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $match = [regex]::Match($message, '^(PCX-[A-Z0-9-]+):')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return 'PCX-E-PROVIDER'
}

# ---------------------------------------------------------------------------
# Generic value apply: registry, service, task
# ---------------------------------------------------------------------------

function Invoke-PcxProviderValueApply {
    <#
    .SYNOPSIS
        Policy -> snapshot -> platform write -> read-back verify.

    .DESCRIPTION
        The original target is passed to the platform (the policy's canonical
        registry path is lowercase and lacks the HKCU:\ provider prefix); the
        canonical decision is used only for allow/deny and reporting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $true)][string] $ExpectedKind
    )

    $null = Get-PcxProviderKind -Target $Target -Expected $ExpectedKind

    # First gate: no read, snapshot or write happens before the decision.
    $decision = Test-PcxTarget -Target $Target -Profile $Profile
    if (-not [bool]$decision.allowed) {
        return New-PcxProviderResult -Status 'REFUSED' -Kind $ExpectedKind -Target $decision.target -Code $decision.code -Reason $decision.reason
    }

    $pre = Get-PcxTargetState -Target $Target
    $snapshot = New-PcxSnapshot -Target $Target -PreState $pre

    $null = Invoke-PcxPlatformWrite -Target $Target

    $observed = Get-PcxTargetState -Target $Target
    $expectedPost = Get-PcxSnapshotMember -Object $snapshot -Name 'post'
    $comparison = Compare-PcxState -Recorded $expectedPost -Current $observed

    $status = 'COMMITTED'
    $code = $null
    $reason = 'the write was read back in its expected post-state.'
    if ([string]$comparison['status'] -ne 'equal') {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-READBACK'
        $reason = "read-back differs from the expected post-state (field '$($comparison['field'])'; expected '$($comparison['recorded'])', observed '$($comparison['current'])')."
    }

    $result = New-PcxProviderResult -Status $status -Kind $ExpectedKind -Target (Get-PcxSnapshotMember -Object $snapshot -Name 'target') -Code $code -Reason $reason
    $result['snapshot'] = $snapshot
    $result['pre'] = $pre
    $result['observed'] = $observed
    $result['restorable'] = $true
    $result['restoreMode'] = 'snapshot'

    return $result
}

function Test-PcxProviderValueState {
    <#
    .SYNOPSIS
        Re-reads a value target and compares it to the snapshot post-state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Snapshot
    )

    if ($null -eq $Snapshot) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-SNAPSHOT' -Message 'a snapshot is required to verify a value target.'
    }

    $kind = Get-PcxSnapshotKind -Target $Snapshot
    $identity = Get-PcxSnapshotMember -Object $Snapshot -Name 'target'
    $expectedPost = Get-PcxSnapshotMember -Object $Snapshot -Name 'post'
    $observed = Get-PcxTargetState -Target $identity
    $comparison = Compare-PcxState -Recorded $expectedPost -Current $observed

    $status = 'COMMITTED'
    $code = $null
    $reason = 'the target still matches the expected post-state.'
    if ([string]$comparison['status'] -ne 'equal') {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-VERIFY'
        $reason = "the target no longer matches the expected post-state (field '$($comparison['field'])')."
    }

    $result = New-PcxProviderResult -Status $status -Kind $kind -Target $identity -Code $code -Reason $reason
    $result['snapshot'] = $Snapshot
    $result['observed'] = $observed
    $result['restorable'] = $true
    $result['restoreMode'] = 'snapshot'

    return $result
}
