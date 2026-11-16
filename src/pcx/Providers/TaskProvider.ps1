<#
.SYNOPSIS
    Scheduled-task write provider: may only disable an existing task.

.DESCRIPTION
    task: sets enabled=false and nothing else. Enabling, a system task under
    \Microsoft\Windows\ and an unknown enabled fact are refused by the policy
    engine with PCX-POLICY-TASK-ENABLE / PCX-POLICY-TASK-SYSTEM before any read
    or write. This provider routes the target through the shared
    Read -> Apply -> Verify pipeline.

    Never a native cmdlet; the only OS access is the platform boundary.
#>

Set-StrictMode -Version 2.0

function Get-PcxTaskProviderState {
    <#
    .SYNOPSIS
        Read: the canonical state of one scheduled task.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $null = Get-PcxProviderKind -Target $Target -Expected 'task'
    return Get-PcxTargetState -Target $Target
}

function Invoke-PcxTaskProviderApply {
    <#
    .SYNOPSIS
        Apply: policy (disable only), snapshot, disable, read-back verify.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    return Invoke-PcxProviderValueApply -Target $Target -Profile $Profile -ExpectedKind 'task'
}

function Test-PcxTaskProviderState {
    <#
    .SYNOPSIS
        Verify: re-read the task and compare it to the snapshot post-state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Snapshot)

    return Test-PcxProviderValueState -Snapshot $Snapshot
}
