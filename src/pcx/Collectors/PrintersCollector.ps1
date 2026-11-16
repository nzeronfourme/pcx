<#
.SYNOPSIS
    Printers collector group.

.DESCRIPTION
    Reports the installed printer count and default printer count. Read-only
    (CIM). A failed probe is unavailable with value $null, never a guessed
    zero.

    Fixture mode (-Fixture) maps environment.printers and state.printers and
    performs no live probe.
#>

Set-StrictMode -Version 2.0

function Get-PcxCollectorPrinters {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    $printerCount = $null
    $defaultCount = $null
    $source = $null

    if ($null -ne $Fixture) {
        $environment = Get-PcxPolicyMember -Object $Fixture -Name 'environment'
        $state = Get-PcxPolicyMember -Object $Fixture -Name 'state'
        $printers = Get-PcxPolicyMember -Object $state -Name 'printers'
        $printerCount = ConvertTo-PcxCollectorInt -Value (Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'printers'))
        $defaultCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $printers -Name 'defaultCount')
        $source = 'fixture:environment.printers'
    }
    else {
        try {
            $printers = @(Get-CimInstance -ClassName 'Win32_Printer' -ErrorAction Stop)
            $printerCount = $printers.Count
            $defaultCount = @($printers | Where-Object { $_.Default -eq $true }).Count
        }
        catch {
            $printerCount = $null
            $defaultCount = $null
        }
        $source = 'cim:Win32_Printer'
    }

    return @(
        New-PcxMetric -Id 'printers.count' -Group 'printers' -Status 'measured' -Value $printerCount -Unit 'count' -Domain 'printers' -Window 'instant' -Source $source
        New-PcxMetric -Id 'printers.default_count' -Group 'printers' -Status 'measured' -Value $defaultCount -Unit 'count' -Domain 'printers' -Window 'instant' -Source $source
    )
}
