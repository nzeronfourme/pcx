<#
.SYNOPSIS
    Thermal diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-ThermalFindings -Environment -Scan. Processor
    temperature is probed best-effort via CIM only when PCX_TEST_RUN is
    empty; there is no vendor-neutral graphics counter, so the graphics
    finding degrades to unavailable with its reason. The fixture carries no
    thermal facts, so fixture runs report unavailable findings. Missing data
    becomes an unavailable finding, never a throw. No console output, no
    global state, no external binaries. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxThermalProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $cpuCelsius = $null

    if ($liveOk) {
        try {
            $zones = @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop)
            $peak = $null
            foreach ($zone in $zones) {
                $raw = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $zone -Name 'CurrentTemperature')
                if ($null -eq $raw -or $raw -le 0) {
                    continue
                }

                $celsius = [math]::Round([double]$raw / 10 - 273.15, 1)
                if ($null -eq $peak -or $celsius -gt $peak) {
                    $peak = $celsius
                }
            }

            $cpuCelsius = $peak
        }
        catch {
            $cpuCelsius = $null
        }
    }

    return [ordered]@{
        cpuCelsius = $cpuCelsius
    }
}

function Get-ThermalFindings {
    <#
    .SYNOPSIS
        Builds the two read-only thermal findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxThermalProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.cpuCelsius) {
            $findings += New-PcxFinding -Section 'thermal' -Id 'cpu-temp' -Severity 'unavailable' `
                -TitleKey 'finding.thermal.cpu-temp.title' -DetailKey 'finding.thermal.cpu-temp.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no thermal zone reading is available'; source = 'cim:MSAcpi_ThermalZoneTemperature' })
        }
        elseif ($probe.cpuCelsius -ge 85) {
            $findings += New-PcxFinding -Section 'thermal' -Id 'cpu-temp' -Severity 'warn' `
                -TitleKey 'finding.thermal.cpu-temp.title' -DetailKey 'finding.thermal.cpu-temp.detail' `
                -Evidence ([ordered]@{ status = 'measured'; celsius = $probe.cpuCelsius; source = 'cim:MSAcpi_ThermalZoneTemperature' })
        }
        elseif ($probe.cpuCelsius -ge 70) {
            $findings += New-PcxFinding -Section 'thermal' -Id 'cpu-temp' -Severity 'info' `
                -TitleKey 'finding.thermal.cpu-temp.title' -DetailKey 'finding.thermal.cpu-temp.detail' `
                -Evidence ([ordered]@{ status = 'measured'; celsius = $probe.cpuCelsius; source = 'cim:MSAcpi_ThermalZoneTemperature' })
        }
        else {
            $findings += New-PcxFinding -Section 'thermal' -Id 'cpu-temp' -Severity 'good' `
                -TitleKey 'finding.thermal.cpu-temp.title' -DetailKey 'finding.thermal.cpu-temp.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; celsius = $probe.cpuCelsius; source = 'cim:MSAcpi_ThermalZoneTemperature' })
        }

        $findings += New-PcxFinding -Section 'thermal' -Id 'gpu-temp' -Severity 'unavailable' `
            -TitleKey 'finding.thermal.gpu-temp.title' -DetailKey 'finding.thermal.gpu-temp.detail' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no vendor-neutral graphics temperature counter exists'; source = 'cim:best-effort' })

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'thermal' -Id 'thermal-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('thermal probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:thermal' }))
    }
}
