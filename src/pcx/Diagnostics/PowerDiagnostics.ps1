<#
.SYNOPSIS
    Power diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-PowerFindings -Environment -Scan. The power plan
    comes from the environment document (registry-sourced, never powercfg);
    pagefile and fast-startup CIM/registry probes run only when PCX_TEST_RUN
    is empty. Missing data becomes an unavailable finding, never a throw.
    No console output, no global state. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxPowerProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $planValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'powerPlan')
    $planName = [string](Get-PcxPolicyMember -Object $planValue -Name 'name')
    if ([string]::IsNullOrWhiteSpace($planName)) {
        $planName = $null
    }

    $memoryValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'memory')
    $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $memoryValue -Name 'totalBytes')

    $pagefileManaged = $null
    $pagefileMaxMb = $null
    $pagefileUsedMb = $null
    $fastStartup = $null
    $fastStartupState = 'unavailable'

    if ($liveOk) {
        try {
            $system = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction Stop
            $autoManaged = Get-PcxPolicyMember -Object $system -Name 'AutomaticManagedPagefile'
            if ($null -ne $autoManaged) {
                $pagefileManaged = [bool]$autoManaged
            }
        }
        catch {
            $pagefileManaged = $null
        }

        try {
            $usages = @(Get-CimInstance -ClassName 'Win32_PageFileUsage' -ErrorAction Stop)
            $allocated = 0
            $used = 0
            foreach ($usage in $usages) {
                $allocated += [int](ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $usage -Name 'AllocatedBaseSize'))
                $used += [int](ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $usage -Name 'CurrentUsage'))
            }

            if ($allocated -gt 0) {
                $pagefileMaxMb = $allocated
                $pagefileUsedMb = $used
            }
        }
        catch {
            $pagefileMaxMb = $null
            $pagefileUsedMb = $null
        }

        if ($null -eq $planName) {
            try {
                $scheme = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme' -ErrorAction Stop
                $guid = ([string]$scheme.ActivePowerScheme).Trim().ToLowerInvariant()
                $planTable = [ordered]@{
                    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
                    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
                    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
                }

                if ($planTable.Contains($guid)) {
                    $planName = [string]$planTable[$guid]
                }
                elseif (-not [string]::IsNullOrWhiteSpace($guid)) {
                    $planName = $guid
                }
            }
            catch {
                $planName = $null
            }
        }

        $state = Read-PcxEnvironmentRegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled'
        if ($state.outcome -eq 'unreadable') {
            $fastStartupState = 'unavailable'
        }
        elseif ($state.outcome -eq 'present') {
            $value = ConvertTo-PcxCollectorInt -Value $state.raw
            if ($null -eq $value) {
                $fastStartupState = 'unavailable'
            }
            elseif ($value -eq 1) {
                $fastStartup = $true
                $fastStartupState = 'measured'
            }
            else {
                $fastStartup = $false
                $fastStartupState = 'measured'
            }
        }
        else {
            $fastStartup = $false
            $fastStartupState = 'measured'
        }
    }

    return [ordered]@{
        planName          = $planName
        totalBytes        = $totalBytes
        pagefileManaged   = $pagefileManaged
        pagefileMaxMb     = $pagefileMaxMb
        pagefileUsedMb    = $pagefileUsedMb
        fastStartup       = $fastStartup
        fastStartupState  = $fastStartupState
    }
}

function Get-PowerFindings {
    <#
    .SYNOPSIS
        Builds the three read-only power findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxPowerProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.pagefileManaged -and $null -eq $probe.pagefileMaxMb) {
            $findings += New-PcxFinding -Section 'power' -Id 'pagefile-state' -Severity 'unavailable' `
                -TitleKey 'finding.power.pagefile-state.title' -DetailKey 'finding.power.pagefile-state.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the paging file settings could not be read'; source = 'cim:Win32_PageFileUsage' })
        }
        elseif ($probe.pagefileManaged -eq $true) {
            $findings += New-PcxFinding -Section 'power' -Id 'pagefile-state' -Severity 'good' `
                -TitleKey 'finding.power.pagefile-state.title' -DetailKey 'finding.power.pagefile-state.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; managed = $true; maxMb = $probe.pagefileMaxMb; source = 'cim:Win32_PageFileUsage' })
        }
        else {
            $ramMb = $null
            if ($null -ne $probe.totalBytes -and $probe.totalBytes -gt 0) {
                $ramMb = [math]::Round($probe.totalBytes / 1048576, 0)
            }

            if ($null -ne $ramMb -and $null -ne $probe.pagefileMaxMb -and $probe.pagefileMaxMb -lt ($ramMb * 1.5)) {
                $findings += New-PcxFinding -Section 'power' -Id 'pagefile-state' -Severity 'warn' `
                    -TitleKey 'finding.power.pagefile-state.title' -DetailKey 'finding.power.pagefile-state.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; managed = $false; maxMb = $probe.pagefileMaxMb; ramMb = $ramMb; source = 'cim:Win32_PageFileUsage' })
            }
            else {
                $findings += New-PcxFinding -Section 'power' -Id 'pagefile-state' -Severity 'info' `
                    -TitleKey 'finding.power.pagefile-state.title' -DetailKey 'finding.power.pagefile-state.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; managed = $false; maxMb = $probe.pagefileMaxMb; ramMb = $ramMb; source = 'cim:Win32_PageFileUsage' })
            }
        }

        if ($null -eq $probe.planName) {
            $findings += New-PcxFinding -Section 'power' -Id 'power-plan' -Severity 'unavailable' `
                -TitleKey 'finding.power.power-plan.title' -DetailKey 'finding.power.power-plan.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the active power scheme could not be read'; source = 'registry:Power/User/PowerSchemes' })
        }
        elseif ($probe.planName -ieq 'Balanced') {
            $findings += New-PcxFinding -Section 'power' -Id 'power-plan' -Severity 'good' `
                -TitleKey 'finding.power.power-plan.title' -DetailKey 'finding.power.power-plan.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; name = $probe.planName; source = 'fixture:environment.powerPlan' })
        }
        elseif ($probe.planName -ieq 'Power saver') {
            $findings += New-PcxFinding -Section 'power' -Id 'power-plan' -Severity 'warn' `
                -TitleKey 'finding.power.power-plan.title' -DetailKey 'finding.power.power-plan.detail' `
                -Evidence ([ordered]@{ status = 'measured'; name = $probe.planName; source = 'fixture:environment.powerPlan' })
        }
        else {
            $findings += New-PcxFinding -Section 'power' -Id 'power-plan' -Severity 'info' `
                -TitleKey 'finding.power.power-plan.title' -DetailKey 'finding.power.power-plan.detail' `
                -Evidence ([ordered]@{ status = 'measured'; name = $probe.planName; source = 'fixture:environment.powerPlan' })
        }

        if ($probe.fastStartupState -ne 'measured') {
            $findings += New-PcxFinding -Section 'power' -Id 'fast-startup' -Severity 'unavailable' `
                -TitleKey 'finding.power.fast-startup.title' -DetailKey 'finding.power.fast-startup.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the fast startup value could not be read'; source = 'registry:Session Manager/Power' })
        }
        elseif ($probe.fastStartup -eq $true) {
            $findings += New-PcxFinding -Section 'power' -Id 'fast-startup' -Severity 'good' `
                -TitleKey 'finding.power.fast-startup.title' -DetailKey 'finding.power.fast-startup.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; enabled = $true; source = 'registry:Session Manager/Power' })
        }
        else {
            $findings += New-PcxFinding -Section 'power' -Id 'fast-startup' -Severity 'info' `
                -TitleKey 'finding.power.fast-startup.title' -DetailKey 'finding.power.fast-startup.detail' `
                -Evidence ([ordered]@{ status = 'measured'; enabled = $false; source = 'registry:Session Manager/Power' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'power' -Id 'power-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('power probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:power' }))
    }
}
