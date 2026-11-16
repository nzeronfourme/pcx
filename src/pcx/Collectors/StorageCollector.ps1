<#
.SYNOPSIS
    Storage collector group.

.DESCRIPTION
    Reports free and total bytes for the system drive, plus free percent when
    both numbers are measured. Read-only (CIM). A failed probe is unavailable
    with value $null, never a guessed zero.

    Fixture mode (-Fixture) reads state.storage from the collector fixture and
    performs no live probe.
#>

Set-StrictMode -Version 2.0

function Get-PcxCollectorStorage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    $freeBytes = $null
    $totalBytes = $null
    $freePercent = $null
    $source = $null

    if ($null -ne $Fixture) {
        $state = Get-PcxPolicyMember -Object $Fixture -Name 'state'
        $storage = Get-PcxPolicyMember -Object $state -Name 'storage'
        $freeBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $storage -Name 'freeBytes')
        $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $storage -Name 'totalBytes')
        $freePercent = ConvertTo-PcxCollectorDouble -Value (Get-PcxPolicyMember -Object $storage -Name 'freePercent')
        $source = 'fixture:state.storage'
    }
    else {
        try {
            $systemRoot = [System.IO.Path]::GetPathRoot([System.Environment]::SystemDirectory)
            $systemDrive = $systemRoot.TrimEnd([char]'\', [char]'/')
            $disks = @(Get-CimInstance -ClassName 'Win32_LogicalDisk' -ErrorAction Stop)
            $disk = $disks | Where-Object { $_.DeviceID -ieq $systemDrive } | Select-Object -First 1
            if ($null -ne $disk) {
                $freeBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $disk -Name 'FreeSpace')
                $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $disk -Name 'Size')
            }
        }
        catch {
            $freeBytes = $null
            $totalBytes = $null
        }
        $source = 'cim:Win32_LogicalDisk'
    }

    if ($null -eq $freePercent -and $null -ne $freeBytes -and $null -ne $totalBytes -and $totalBytes -gt 0) {
        $freePercent = [math]::Round((([double]$freeBytes / [double]$totalBytes) * 100), 2)
    }

    return @(
        New-PcxMetric -Id 'storage.system_free_bytes' -Group 'storage' -Status 'measured' -Value $freeBytes -Unit 'bytes' -Domain 'storage' -Window 'instant' -Source $source
        New-PcxMetric -Id 'storage.system_total_bytes' -Group 'storage' -Status 'measured' -Value $totalBytes -Unit 'bytes' -Domain 'storage' -Window 'instant' -Source $source
        New-PcxMetric -Id 'storage.system_free_percent' -Group 'storage' -Status 'measured' -Value $freePercent -Unit 'percent' -Domain 'storage' -Window 'instant' -Source $source
    )
}
