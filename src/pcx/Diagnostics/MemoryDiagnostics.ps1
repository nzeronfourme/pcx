<#
.SYNOPSIS
    Memory diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-MemoryFindings -Environment -Scan. Fixture values
    come from the environment document and the scan state; live CIM probes
    run only when PCX_TEST_RUN is empty. Missing data becomes an unavailable
    finding, never a throw. No console output, no global state, no external
    binaries. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxMemoryProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $memoryValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'memory')
    $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $memoryValue -Name 'totalBytes')

    $state = Get-PcxPolicyMember -Object $Scan -Name 'state'
    if ($null -eq $state) {
        $state = $Scan
    }

    $stateMemory = Get-PcxPolicyMember -Object $state -Name 'memory'
    $availableBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $stateMemory -Name 'availableBytes')

    $pagefileUsedMb = $null
    $pagefileMaxMb = $null
    $standbyBytes = $null

    if ($liveOk) {
        if ($null -eq $totalBytes -or $null -eq $availableBytes) {
            try {
                $liveOs = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
                $totalKb = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $liveOs -Name 'TotalVisibleMemorySize')
                $freeKb = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $liveOs -Name 'FreePhysicalMemory')
                if ($null -ne $totalKb) {
                    $totalBytes = $totalKb * 1024
                }

                if ($null -ne $freeKb) {
                    $availableBytes = $freeKb * 1024
                }
            }
            catch {
                $totalBytes = $null
                $availableBytes = $null
            }
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

        try {
            $perfMemory = Get-CimInstance -ClassName 'Win32_PerfFormattedData_PerfOS_Memory' -ErrorAction Stop | Select-Object -First 1
            $standby = [long]0
            foreach ($name in @('StandbyCacheNormalPriorityBytes', 'StandbyCacheReserveBytes', 'StandbyCacheCoreBytes')) {
                $part = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $perfMemory -Name $name)
                if ($null -ne $part) {
                    $standby += $part
                }
            }

            if ($standby -gt 0) {
                $standbyBytes = $standby
            }
        }
        catch {
            $standbyBytes = $null
        }
    }

    $usedPercent = $null
    if ($null -ne $totalBytes -and $null -ne $availableBytes -and $totalBytes -gt 0) {
        $usedPercent = [math]::Round((1 - ([double]$availableBytes / [double]$totalBytes)) * 100, 2)
    }

    $pagefilePercent = $null
    if ($null -ne $pagefileMaxMb -and $null -ne $pagefileUsedMb -and $pagefileMaxMb -gt 0) {
        $pagefilePercent = [math]::Round(([double]$pagefileUsedMb / [double]$pagefileMaxMb) * 100, 2)
    }

    return [ordered]@{
        totalBytes     = $totalBytes
        availableBytes = $availableBytes
        usedPercent    = $usedPercent
        pagefileUsedMb = $pagefileUsedMb
        pagefileMaxMb  = $pagefileMaxMb
        pagefilePct    = $pagefilePercent
        standbyBytes   = $standbyBytes
    }
}

function Get-MemoryFindings {
    <#
    .SYNOPSIS
        Builds the three read-only memory findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxMemoryProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.usedPercent) {
            $findings += New-PcxFinding -Section 'memory' -Id 'ram-usage' -Severity 'unavailable' `
                -TitleKey 'finding.memory.ram-usage.title' -DetailKey 'finding.memory.ram-usage.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'memory totals could not be read'; source = 'fixture:environment.memory' })
        }
        elseif ($probe.usedPercent -ge 93) {
            $findings += New-PcxFinding -Section 'memory' -Id 'ram-usage' -Severity 'critical' `
                -TitleKey 'finding.memory.ram-usage.title' -DetailKey 'finding.memory.ram-usage.detail' `
                -Evidence ([ordered]@{ status = 'measured'; usedPercent = $probe.usedPercent; totalBytes = $probe.totalBytes; source = 'fixture:environment.memory' })
        }
        elseif ($probe.usedPercent -ge 85) {
            $findings += New-PcxFinding -Section 'memory' -Id 'ram-usage' -Severity 'warn' `
                -TitleKey 'finding.memory.ram-usage.title' -DetailKey 'finding.memory.ram-usage.detail' `
                -Evidence ([ordered]@{ status = 'measured'; usedPercent = $probe.usedPercent; totalBytes = $probe.totalBytes; source = 'fixture:environment.memory' })
        }
        else {
            $findings += New-PcxFinding -Section 'memory' -Id 'ram-usage' -Severity 'good' `
                -TitleKey 'finding.memory.ram-usage.title' -DetailKey 'finding.memory.ram-usage.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; usedPercent = $probe.usedPercent; totalBytes = $probe.totalBytes; source = 'fixture:environment.memory' })
        }

        if ($null -eq $probe.pagefilePct) {
            $findings += New-PcxFinding -Section 'memory' -Id 'pagefile-pressure' -Severity 'unavailable' `
                -TitleKey 'finding.memory.pagefile-pressure.title' -DetailKey 'finding.memory.pagefile-pressure.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'pagefile usage could not be read'; source = 'cim:Win32_PageFileUsage' })
        }
        elseif ($probe.pagefilePct -ge 90) {
            $findings += New-PcxFinding -Section 'memory' -Id 'pagefile-pressure' -Severity 'critical' `
                -TitleKey 'finding.memory.pagefile-pressure.title' -DetailKey 'finding.memory.pagefile-pressure.detail' `
                -Evidence ([ordered]@{ status = 'measured'; usedPercent = $probe.pagefilePct; source = 'cim:Win32_PageFileUsage' })
        }
        elseif ($probe.pagefilePct -ge 70) {
            $findings += New-PcxFinding -Section 'memory' -Id 'pagefile-pressure' -Severity 'warn' `
                -TitleKey 'finding.memory.pagefile-pressure.title' -DetailKey 'finding.memory.pagefile-pressure.detail' `
                -Evidence ([ordered]@{ status = 'measured'; usedPercent = $probe.pagefilePct; source = 'cim:Win32_PageFileUsage' })
        }
        else {
            $findings += New-PcxFinding -Section 'memory' -Id 'pagefile-pressure' -Severity 'good' `
                -TitleKey 'finding.memory.pagefile-pressure.title' -DetailKey 'finding.memory.pagefile-pressure.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; usedPercent = $probe.pagefilePct; source = 'cim:Win32_PageFileUsage' })
        }

        if ($null -eq $probe.standbyBytes) {
            $findings += New-PcxFinding -Section 'memory' -Id 'standby-list' -Severity 'unavailable' `
                -TitleKey 'finding.memory.standby-list.title' -DetailKey 'finding.memory.standby-list.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the standby cache counters could not be read'; source = 'cim:Win32_PerfFormattedData_PerfOS_Memory' })
        }
        else {
            $findings += New-PcxFinding -Section 'memory' -Id 'standby-list' -Severity 'good' `
                -TitleKey 'finding.memory.standby-list.title' -DetailKey 'finding.memory.standby-list.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; bytes = $probe.standbyBytes; source = 'cim:Win32_PerfFormattedData_PerfOS_Memory' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'memory' -Id 'memory-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('memory probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:memory' }))
    }
}
