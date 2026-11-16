<#
.SYNOPSIS
    Platform diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-PlatformFindings -Environment -Scan. Fixture values
    come from the environment document; live CIM probes run only when
    PCX_TEST_RUN is empty, so fixture runs never touch the live OS. Missing
    data becomes an unavailable finding, never a throw. No console output,
    no global state, no external binaries. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxPlatformProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $os = Get-PcxPolicyMember -Object $Environment -Name 'os'
    $build = ConvertTo-PcxCollectorInt -Value (Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $os -Name 'build'))
    $ubr = ConvertTo-PcxCollectorInt -Value (Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $os -Name 'ubr'))
    $productName = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $os -Name 'productName')
    if ($null -ne $productName) {
        $productName = [string]$productName
    }

    $memoryValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'memory')
    $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $memoryValue -Name 'totalBytes')

    $gpuValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'gpu')
    $gpuName = $null
    $gpuDriver = $null
    $controllers = @()
    if ($null -ne $gpuValue) {
        $controllers = @(Get-PcxPolicyMember -Object $gpuValue -Name 'controllers')
    }

    if ($controllers.Count -gt 0 -and $null -ne $controllers[0]) {
        $gpuName = [string](Get-PcxPolicyMember -Object $controllers[0] -Name 'name')
        $gpuDriver = [string](Get-PcxPolicyMember -Object $controllers[0] -Name 'driverVersion')
    }

    $uptimeDays = $null
    $biosDate = $null
    $cpuName = $null
    $gpuDriverDate = $null

    if ($liveOk) {
        try {
            $liveOs = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
            $bootRaw = [string](Get-PcxPolicyMember -Object $liveOs -Name 'LastBootUpTime')
            if (-not [string]::IsNullOrWhiteSpace($bootRaw)) {
                $bootTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($bootRaw)
                $uptimeDays = [math]::Round(([System.DateTime]::UtcNow - $bootTime.ToUniversalTime()).TotalDays, 1)
            }
        }
        catch {
            $uptimeDays = $null
        }

        try {
            $liveBios = Get-CimInstance -ClassName 'Win32_BIOS' -ErrorAction Stop
            $releaseRaw = [string](Get-PcxPolicyMember -Object $liveBios -Name 'ReleaseDate')
            if (-not [string]::IsNullOrWhiteSpace($releaseRaw)) {
                $biosDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($releaseRaw).ToString('yyyy-MM-dd')
            }
        }
        catch {
            $biosDate = $null
        }

        try {
            $liveCpu = Get-CimInstance -ClassName 'Win32_Processor' -ErrorAction Stop | Select-Object -First 1
            $cpuName = [string](Get-PcxPolicyMember -Object $liveCpu -Name 'Name')
            if ([string]::IsNullOrWhiteSpace($cpuName)) {
                $cpuName = $null
            }
        }
        catch {
            $cpuName = $null
        }

        try {
            $displayDrivers = @(Get-CimInstance -ClassName 'Win32_PnPSignedDriver' -ErrorAction Stop | Where-Object { [string](Get-PcxPolicyMember -Object $_ -Name 'DeviceClass') -ieq 'DISPLAY' })
            foreach ($driver in $displayDrivers) {
                $dateRaw = [string](Get-PcxPolicyMember -Object $driver -Name 'DriverDate')
                if (-not [string]::IsNullOrWhiteSpace($dateRaw)) {
                    $gpuDriverDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($dateRaw).ToString('yyyy-MM-dd')
                    break
                }
            }
        }
        catch {
            $gpuDriverDate = $null
        }
    }

    return [ordered]@{
        build         = $build
        ubr           = $ubr
        productName   = $productName
        totalBytes    = $totalBytes
        gpuName       = $gpuName
        gpuDriver     = $gpuDriver
        uptimeDays    = $uptimeDays
        biosDate      = $biosDate
        cpuName       = $cpuName
        gpuDriverDate = $gpuDriverDate
    }
}

function Get-PlatformFindings {
    <#
    .SYNOPSIS
        Builds the five read-only platform findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxPlatformProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.build) {
            $findings += New-PcxFinding -Section 'platform' -Id 'os-build-support' -Severity 'unavailable' `
                -TitleKey 'finding.platform.os-build-support.title' -DetailKey 'finding.platform.os-build-support.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the OS build could not be read'; source = 'fixture:environment.os' })
        }
        elseif ($probe.build -ge 19041) {
            $findings += New-PcxFinding -Section 'platform' -Id 'os-build-support' -Severity 'good' `
                -TitleKey 'finding.platform.os-build-support.title' -DetailKey 'finding.platform.os-build-support.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; build = $probe.build; ubr = $probe.ubr; product = $probe.productName; source = 'fixture:environment.os' })
        }
        else {
            $findings += New-PcxFinding -Section 'platform' -Id 'os-build-support' -Severity 'critical' `
                -TitleKey 'finding.platform.os-build-support.title' -DetailKey 'finding.platform.os-build-support.detail' `
                -Evidence ([ordered]@{ status = 'measured'; build = $probe.build; ubr = $probe.ubr; product = $probe.productName; source = 'fixture:environment.os' })
        }

        if ($null -eq $probe.uptimeDays) {
            $findings += New-PcxFinding -Section 'platform' -Id 'uptime' -Severity 'unavailable' `
                -TitleKey 'finding.platform.uptime.title' -DetailKey 'finding.platform.uptime.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the last boot time could not be read'; source = 'cim:Win32_OperatingSystem' })
        }
        elseif ($probe.uptimeDays -gt 30) {
            $findings += New-PcxFinding -Section 'platform' -Id 'uptime' -Severity 'warn' `
                -TitleKey 'finding.platform.uptime.title' -DetailKey 'finding.platform.uptime.detail' `
                -Evidence ([ordered]@{ status = 'measured'; days = $probe.uptimeDays; source = 'cim:Win32_OperatingSystem' })
        }
        elseif ($probe.uptimeDays -gt 7) {
            $findings += New-PcxFinding -Section 'platform' -Id 'uptime' -Severity 'info' `
                -TitleKey 'finding.platform.uptime.title' -DetailKey 'finding.platform.uptime.detail' `
                -Evidence ([ordered]@{ status = 'measured'; days = $probe.uptimeDays; source = 'cim:Win32_OperatingSystem' })
        }
        else {
            $findings += New-PcxFinding -Section 'platform' -Id 'uptime' -Severity 'good' `
                -TitleKey 'finding.platform.uptime.title' -DetailKey 'finding.platform.uptime.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; days = $probe.uptimeDays; source = 'cim:Win32_OperatingSystem' })
        }

        if ($null -eq $probe.biosDate) {
            $findings += New-PcxFinding -Section 'platform' -Id 'bios-age' -Severity 'unavailable' `
                -TitleKey 'finding.platform.bios-age.title' -DetailKey 'finding.platform.bios-age.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the firmware release date could not be read'; source = 'cim:Win32_BIOS' })
        }
        else {
            $biosYears = $null
            try {
                $parsed = [System.DateTime]::ParseExact($probe.biosDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                $biosYears = [math]::Round(([System.DateTime]::UtcNow - $parsed.ToUniversalTime()).TotalDays / 365.25, 1)
            }
            catch {
                $biosYears = $null
            }

            if ($null -eq $biosYears) {
                $findings += New-PcxFinding -Section 'platform' -Id 'bios-age' -Severity 'unavailable' `
                    -TitleKey 'finding.platform.bios-age.title' -DetailKey 'finding.platform.bios-age.detail' `
                    -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the firmware release date is not a date'; source = 'cim:Win32_BIOS' })
            }
            elseif ($biosYears -gt 6) {
                $findings += New-PcxFinding -Section 'platform' -Id 'bios-age' -Severity 'warn' `
                    -TitleKey 'finding.platform.bios-age.title' -DetailKey 'finding.platform.bios-age.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.biosDate; years = $biosYears; source = 'cim:Win32_BIOS' })
            }
            elseif ($biosYears -gt 3) {
                $findings += New-PcxFinding -Section 'platform' -Id 'bios-age' -Severity 'info' `
                    -TitleKey 'finding.platform.bios-age.title' -DetailKey 'finding.platform.bios-age.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.biosDate; years = $biosYears; source = 'cim:Win32_BIOS' })
            }
            else {
                $findings += New-PcxFinding -Section 'platform' -Id 'bios-age' -Severity 'good' `
                    -TitleKey 'finding.platform.bios-age.title' -DetailKey 'finding.platform.bios-age.detail' `
                    -AlreadyGood $true `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.biosDate; years = $biosYears; source = 'cim:Win32_BIOS' })
            }
        }

        if ($null -eq $probe.gpuDriverDate) {
            $findings += New-PcxFinding -Section 'platform' -Id 'gpu-driver-age' -Severity 'unavailable' `
                -TitleKey 'finding.platform.gpu-driver-age.title' -DetailKey 'finding.platform.gpu-driver-age.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the graphics driver date is not recorded'; version = $probe.gpuDriver; source = 'cim:Win32_PnPSignedDriver' })
        }
        else {
            $driverDays = $null
            try {
                $parsedDriver = [System.DateTime]::ParseExact($probe.gpuDriverDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                $driverDays = ([System.DateTime]::UtcNow - $parsedDriver.ToUniversalTime()).TotalDays
            }
            catch {
                $driverDays = $null
            }

            if ($null -eq $driverDays) {
                $findings += New-PcxFinding -Section 'platform' -Id 'gpu-driver-age' -Severity 'unavailable' `
                    -TitleKey 'finding.platform.gpu-driver-age.title' -DetailKey 'finding.platform.gpu-driver-age.detail' `
                    -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the graphics driver date is not a date'; source = 'cim:Win32_PnPSignedDriver' })
            }
            elseif ($driverDays -gt 365) {
                $findings += New-PcxFinding -Section 'platform' -Id 'gpu-driver-age' -Severity 'warn' `
                    -TitleKey 'finding.platform.gpu-driver-age.title' -DetailKey 'finding.platform.gpu-driver-age.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.gpuDriverDate; name = $probe.gpuName; version = $probe.gpuDriver; source = 'cim:Win32_PnPSignedDriver' })
            }
            elseif ($driverDays -gt 180) {
                $findings += New-PcxFinding -Section 'platform' -Id 'gpu-driver-age' -Severity 'info' `
                    -TitleKey 'finding.platform.gpu-driver-age.title' -DetailKey 'finding.platform.gpu-driver-age.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.gpuDriverDate; name = $probe.gpuName; version = $probe.gpuDriver; source = 'cim:Win32_PnPSignedDriver' })
            }
            else {
                $findings += New-PcxFinding -Section 'platform' -Id 'gpu-driver-age' -Severity 'good' `
                    -TitleKey 'finding.platform.gpu-driver-age.title' -DetailKey 'finding.platform.gpu-driver-age.detail' `
                    -AlreadyGood $true `
                    -Evidence ([ordered]@{ status = 'measured'; date = $probe.gpuDriverDate; name = $probe.gpuName; version = $probe.gpuDriver; source = 'cim:Win32_PnPSignedDriver' })
            }
        }

        if ($null -eq $probe.totalBytes -and [string]::IsNullOrWhiteSpace($probe.cpuName)) {
            $findings += New-PcxFinding -Section 'platform' -Id 'cpu-mem-summary' -Severity 'unavailable' `
                -TitleKey 'finding.platform.cpu-mem-summary.title' -DetailKey 'finding.platform.cpu-mem-summary.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'neither the processor nor memory could be read'; source = 'fixture:environment.memory' })
        }
        else {
            $findings += New-PcxFinding -Section 'platform' -Id 'cpu-mem-summary' -Severity 'info' `
                -TitleKey 'finding.platform.cpu-mem-summary.title' -DetailKey 'finding.platform.cpu-mem-summary.detail' `
                -Evidence ([ordered]@{ status = 'measured'; cpu = $probe.cpuName; totalBytes = $probe.totalBytes; source = 'fixture:environment.memory' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'platform' -Id 'platform-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('platform probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:platform' }))
    }
}
