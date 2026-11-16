<#
.SYNOPSIS
    Memory collector group.

.DESCRIPTION
    Reports total physical memory, available memory and used percent.
    Read-only (CIM). A failed probe is unavailable with value $null, never a
    guessed zero; used percent is computed only when both byte counts are
    measured and total is positive.

    Fixture mode (-Fixture) maps environment.memory and state.memory and
    performs no live probe.
#>

Set-StrictMode -Version 2.0

function Get-PcxCollectorMemory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    $totalBytes = $null
    $availableBytes = $null
    $usedPercent = $null
    $source = $null

    if ($null -ne $Fixture) {
        $environment = Get-PcxPolicyMember -Object $Fixture -Name 'environment'
        $state = Get-PcxPolicyMember -Object $Fixture -Name 'state'
        $memory = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'memory')
        $stateMemory = Get-PcxPolicyMember -Object $state -Name 'memory'
        $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $memory -Name 'totalBytes')
        $availableBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $stateMemory -Name 'availableBytes')
        $source = 'fixture:environment.memory'
    }
    else {
        try {
            $operatingSystem = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
            $totalKb = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $operatingSystem -Name 'TotalVisibleMemorySize')
            $freeKb = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $operatingSystem -Name 'FreePhysicalMemory')
            if ($null -ne $totalKb) { $totalBytes = $totalKb * 1024 }
            if ($null -ne $freeKb) { $availableBytes = $freeKb * 1024 }
        }
        catch {
            $totalBytes = $null
            $availableBytes = $null
        }
        $source = 'cim:Win32_OperatingSystem'
    }

    if ($null -ne $totalBytes -and $null -ne $availableBytes -and $totalBytes -gt 0) {
        $usedPercent = [math]::Round((1 - ([double]$availableBytes / [double]$totalBytes)) * 100, 2)
    }

    return @(
        New-PcxMetric -Id 'memory.total_bytes' -Group 'memory' -Status 'measured' -Value $totalBytes -Unit 'bytes' -Domain 'performance' -Window 'instant' -Source $source
        New-PcxMetric -Id 'memory.available_bytes' -Group 'memory' -Status 'measured' -Value $availableBytes -Unit 'bytes' -Domain 'performance' -Window 'instant' -Source $source
        New-PcxMetric -Id 'memory.used_percent' -Group 'memory' -Status 'measured' -Value $usedPercent -Unit 'percent' -Domain 'performance' -Window 'instant' -Source $source
    )
}
