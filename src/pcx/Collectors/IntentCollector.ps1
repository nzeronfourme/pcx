<#
.SYNOPSIS
    Intent collector group.

.DESCRIPTION
    Reports positive usage evidence from UserAssist, Prefetch and Task
    Scheduler event history. BAM/SRUM are not available in v0 and are reported
    as an unavailable metric, never as zero. Event reads use
    Get-WinEvent -FilterHashtable only. Read-only.

    Fixture mode (-Fixture) reads state.intent and performs no live probe.
#>

Set-StrictMode -Version 2.0

function Get-PcxCollectorIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    $userAssist = $null
    $prefetch = $null
    $taskEvents = $null
    $source = $null

    if ($null -ne $Fixture) {
        $state = Get-PcxPolicyMember -Object $Fixture -Name 'state'
        $intent = Get-PcxPolicyMember -Object $state -Name 'intent'
        $userAssist = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $intent -Name 'userAssistEntries')
        $prefetch = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $intent -Name 'prefetchFiles')
        $taskEvents = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $intent -Name 'taskHistoryEvents')
        $source = 'fixture:state.intent'
    }
    else {
        try {
            $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
            $total = 0
            foreach ($child in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
                $countPath = $child.PSPath + '\Count'
                if (Test-Path -LiteralPath $countPath) {
                    $countKey = Get-Item -LiteralPath $countPath -ErrorAction Stop
                    $total += @($countKey.GetValueNames()).Count
                }
            }
            $userAssist = $total
        }
        catch {
            $userAssist = $null
        }

        try {
            $systemRoot = [System.Environment]::GetEnvironmentVariable('SystemRoot')
            if ([string]::IsNullOrWhiteSpace($systemRoot)) {
                throw [System.InvalidOperationException]::new('SystemRoot is not set.')
            }
            $prefetchPath = Join-Path -Path $systemRoot -ChildPath 'Prefetch'
            $prefetch = @(Get-ChildItem -LiteralPath $prefetchPath -Filter '*.pf' -File -ErrorAction Stop).Count
        }
        catch {
            $prefetch = $null
        }

        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TaskScheduler/Operational'; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 2000 -ErrorAction Stop)
            $taskEvents = $events.Count
        }
        catch {
            $taskEvents = $null
        }

        $source = 'registry:UserAssist / files:Prefetch / event:TaskScheduler'
    }

    return @(
        New-PcxMetric -Id 'intent.userassist_entries' -Group 'intent' -Status 'measured' -Value $userAssist -Unit 'count' -Domain 'intent' -Window 'all-time' -Source $source
        New-PcxMetric -Id 'intent.prefetch_files' -Group 'intent' -Status 'measured' -Value $prefetch -Unit 'count' -Domain 'intent' -Window 'all-time' -Source $source
        New-PcxMetric -Id 'intent.task_history_events' -Group 'intent' -Status 'measured' -Value $taskEvents -Unit 'count' -Domain 'intent' -Window '7d' -Source $source
        New-PcxMetric -Id 'intent.bam_srum_entries' -Group 'intent' -Status 'unavailable' -Value $null -Unit 'count' -Domain 'intent' -Window 'unavailable' -Source 'BAM/SRUM are not available in v0'
    )
}
