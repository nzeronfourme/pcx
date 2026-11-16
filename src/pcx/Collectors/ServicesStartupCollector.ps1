<#
.SYNOPSIS
    Services / startup collector group.

.DESCRIPTION
    Reports running and automatic service counts plus the number of Run-key
    startup values. Read-only (CIM and registry). A failed probe is unavailable
    with value $null, never a guessed zero.

    Fixture mode (-Fixture) reads state.services and state.startup and performs
    no live probe.
#>

Set-StrictMode -Version 2.0

function Get-PcxCollectorServicesStartup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    $runningCount = $null
    $autoCount = $null
    $startupCount = $null
    $serviceSource = $null
    $startupSource = $null

    if ($null -ne $Fixture) {
        $state = Get-PcxPolicyMember -Object $Fixture -Name 'state'
        $services = Get-PcxPolicyMember -Object $state -Name 'services'
        $startup = Get-PcxPolicyMember -Object $state -Name 'startup'
        $runningCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $services -Name 'runningCount')
        $autoCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $services -Name 'autoCount')
        $startupCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $startup -Name 'runValuesCount')
        $serviceSource = 'fixture:state.services'
        $startupSource = 'fixture:state.startup'
    }
    else {
        try {
            $services = @(Get-CimInstance -ClassName 'Win32_Service' -ErrorAction Stop)
            $runningCount = @($services | Where-Object { $_.State -eq 'Running' }).Count
            $autoCount = @($services | Where-Object { $_.StartMode -eq 'Auto' }).Count
        }
        catch {
            $runningCount = $null
            $autoCount = $null
        }
        $serviceSource = 'cim:Win32_Service'

        $runPaths = @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        )
        $count = 0
        $readAny = $false
        foreach ($path in $runPaths) {
            try {
                $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
                $readAny = $true
                foreach ($property in $item.PSObject.Properties) {
                    if (-not $property.Name.StartsWith('PS', [System.StringComparison]::Ordinal)) {
                        $count++
                    }
                }
            }
            catch {
                # A missing Run key is not a failed probe when another one was read.
            }
        }
        if ($readAny) {
            $startupCount = $count
        }
        $startupSource = 'registry:Run keys'
    }

    return @(
        New-PcxMetric -Id 'services.running_count' -Group 'services-startup' -Status 'measured' -Value $runningCount -Unit 'count' -Domain 'services' -Window 'instant' -Source $serviceSource
        New-PcxMetric -Id 'services.auto_count' -Group 'services-startup' -Status 'measured' -Value $autoCount -Unit 'count' -Domain 'services' -Window 'instant' -Source $serviceSource
        New-PcxMetric -Id 'startup.run_values_count' -Group 'services-startup' -Status 'measured' -Value $startupCount -Unit 'count' -Domain 'startup' -Window 'instant' -Source $startupSource
    )
}
