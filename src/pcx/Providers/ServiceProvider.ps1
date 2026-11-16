<#
.SYNOPSIS
    Service write provider: sets Start only, and only to 3 (Manual) or 4
    (Disabled).

.DESCRIPTION
    svc: sets the boot start type of one existing service. Start 0/1/2 is
    refused by the policy engine with PCX-POLICY-SERVICE-START before any read
    or write; the blast-radius rule (zero dependents, zero listening ports,
    zero child processes) also lives there. This provider routes the target
    through the shared Read -> Apply -> Verify pipeline.

    Never a native cmdlet; the only OS access is the platform boundary.
#>

Set-StrictMode -Version 2.0

function Get-PcxServiceProviderState {
    <#
    .SYNOPSIS
        Read: the canonical state (Start plus resolved control set) of one
        service.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $null = Get-PcxProviderKind -Target $Target -Expected 'service'
    return Get-PcxTargetState -Target $Target
}

function Invoke-PcxServiceProviderApply {
    <#
    .SYNOPSIS
        Apply: policy (Start 3/4 only), snapshot, Start write, read-back verify.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    return Invoke-PcxProviderValueApply -Target $Target -Profile $Profile -ExpectedKind 'service'
}

function Test-PcxServiceProviderState {
    <#
    .SYNOPSIS
        Verify: re-read the service and compare it to the snapshot post-state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Snapshot)

    return Test-PcxProviderValueState -Snapshot $Snapshot
}
