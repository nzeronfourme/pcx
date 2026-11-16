<#
.SYNOPSIS
    Drivers diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-DriversFindings -Environment -Scan. Third-party
    driver dates and problem devices are probed via CIM only when
    PCX_TEST_RUN is empty; the fixture carries no driver facts, so fixture
    runs report unavailable findings. Missing data becomes an unavailable
    finding, never a throw. No console output, no global state, no external
    binaries. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxDriversProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $oldestDriverDate = $null
    $oldestDriverName = $null
    $problemDevices = $null

    if ($liveOk) {
        try {
            $drivers = @(Get-CimInstance -ClassName 'Win32_PnPSignedDriver' -ErrorAction Stop | Where-Object {
                [string](Get-PcxPolicyMember -Object $_ -Name 'Manufacturer') -inotlike 'Microsoft*'
            })

            foreach ($driver in $drivers) {
                $dateRaw = [string](Get-PcxPolicyMember -Object $driver -Name 'DriverDate')
                if ([string]::IsNullOrWhiteSpace($dateRaw)) {
                    continue
                }

                if ($null -eq $oldestDriverDate -or $dateRaw -lt $oldestDriverDate) {
                    $oldestDriverDate = $dateRaw
                    $oldestDriverName = [string](Get-PcxPolicyMember -Object $driver -Name 'DeviceName')
                }
            }

            if ($null -ne $oldestDriverDate) {
                $oldestDriverDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($oldestDriverDate).ToString('yyyy-MM-dd')
            }
        }
        catch {
            $oldestDriverDate = $null
            $oldestDriverName = $null
        }

        try {
            $devices = @(Get-CimInstance -ClassName 'Win32_PnPEntity' -ErrorAction Stop | Where-Object {
                [int](ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $_ -Name 'ConfigManagerErrorCode')) -ne 0
            })

            $problemDevices = @()
            foreach ($device in $devices) {
                $problemDevices += [ordered]@{
                    name = [string](Get-PcxPolicyMember -Object $device -Name 'Name')
                    code = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $device -Name 'ConfigManagerErrorCode')
                }
            }
        }
        catch {
            $problemDevices = $null
        }
    }

    return [ordered]@{
        oldestDate   = $oldestDriverDate
        oldestName   = $oldestDriverName
        problemNames = $problemDevices
    }
}

function Get-DriversFindings {
    <#
    .SYNOPSIS
        Builds the two read-only drivers findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxDriversProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.oldestDate) {
            $findings += New-PcxFinding -Section 'drivers' -Id 'driver-age' -Severity 'unavailable' `
                -TitleKey 'finding.drivers.driver-age.title' -DetailKey 'finding.drivers.driver-age.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no signed driver dates are recorded'; source = 'cim:Win32_PnPSignedDriver' })
        }
        else {
            $driverYears = $null
            try {
                $parsed = [System.DateTime]::ParseExact($probe.oldestDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                $driverYears = [math]::Round(([System.DateTime]::UtcNow - $parsed.ToUniversalTime()).TotalDays / 365.25, 1)
            }
            catch {
                $driverYears = $null
            }

            if ($null -eq $driverYears) {
                $findings += New-PcxFinding -Section 'drivers' -Id 'driver-age' -Severity 'unavailable' `
                    -TitleKey 'finding.drivers.driver-age.title' -DetailKey 'finding.drivers.driver-age.detail' `
                    -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the oldest driver date is not a date'; source = 'cim:Win32_PnPSignedDriver' })
            }
            elseif ($driverYears -gt 3) {
                $findings += New-PcxFinding -Section 'drivers' -Id 'driver-age' -Severity 'warn' `
                    -TitleKey 'finding.drivers.driver-age.title' -DetailKey 'finding.drivers.driver-age.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.oldestDate; name = $probe.oldestName; years = $driverYears; source = 'cim:Win32_PnPSignedDriver' })
            }
            elseif ($driverYears -gt 1) {
                $findings += New-PcxFinding -Section 'drivers' -Id 'driver-age' -Severity 'info' `
                    -TitleKey 'finding.drivers.driver-age.title' -DetailKey 'finding.drivers.driver-age.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.oldestDate; name = $probe.oldestName; years = $driverYears; source = 'cim:Win32_PnPSignedDriver' })
            }
            else {
                $findings += New-PcxFinding -Section 'drivers' -Id 'driver-age' -Severity 'good' `
                    -TitleKey 'finding.drivers.driver-age.title' -DetailKey 'finding.drivers.driver-age.detail' `
                    -AlreadyGood $true `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.oldestDate; name = $probe.oldestName; years = $driverYears; source = 'cim:Win32_PnPSignedDriver' })
            }
        }

        if ($null -eq $probe.problemNames) {
            $findings += New-PcxFinding -Section 'drivers' -Id 'problem-devices' -Severity 'unavailable' `
                -TitleKey 'finding.drivers.problem-devices.title' -DetailKey 'finding.drivers.problem-devices.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no device status facts are recorded'; source = 'cim:Win32_PnPEntity' })
        }
        elseif ($probe.problemNames.Count -eq 0) {
            $findings += New-PcxFinding -Section 'drivers' -Id 'problem-devices' -Severity 'good' `
                -TitleKey 'finding.drivers.problem-devices.title' -DetailKey 'finding.drivers.problem-devices.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = 0; source = 'cim:Win32_PnPEntity' })
        }
        else {
            $findings += New-PcxFinding -Section 'drivers' -Id 'problem-devices' -Severity 'warn' `
                -TitleKey 'finding.drivers.problem-devices.title' -DetailKey 'finding.drivers.problem-devices.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.problemNames.Count; devices = @($probe.problemNames | Select-Object -First 5); source = 'cim:Win32_PnPEntity' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'drivers' -Id 'drivers-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('drivers probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:drivers' }))
    }
}
