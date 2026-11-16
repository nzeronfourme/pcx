<#
.SYNOPSIS
    Registry write provider: exactly one value, nothing hierarchical.

.DESCRIPTION
    reg: writes one value. The policy engine already enforces the value-level
    rule (a key without a value name refuses) and the default-deny HKCU
    surface; this provider only routes the target through the shared
    Read -> Apply -> Verify pipeline.

    Never a native cmdlet; the only OS access is the platform boundary.
#>

Set-StrictMode -Version 2.0

function Get-PcxRegistryProviderState {
    <#
    .SYNOPSIS
        Read: the canonical state of one registry value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $null = Get-PcxProviderKind -Target $Target -Expected 'registry'
    return Get-PcxTargetState -Target $Target
}

function Invoke-PcxRegistryProviderApply {
    <#
    .SYNOPSIS
        Apply: policy, snapshot, one value write, read-back verify.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    return Invoke-PcxProviderValueApply -Target $Target -Profile $Profile -ExpectedKind 'registry'
}

function Test-PcxRegistryProviderState {
    <#
    .SYNOPSIS
        Verify: re-read the value and compare it to the snapshot post-state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Snapshot)

    return Test-PcxProviderValueState -Snapshot $Snapshot
}
