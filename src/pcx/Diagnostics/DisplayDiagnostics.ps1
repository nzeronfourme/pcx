<#
.SYNOPSIS
    Display diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-DisplayFindings -Environment -Scan. Monitor count,
    resolution layout and audio endpoints are probed live via CIM only when
    PCX_TEST_RUN is empty; the fixture carries no display facts, so fixture
    runs report unavailable findings. This section never checks monitor
    refresh rate. No console output, no global state, no external binaries.
    ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxDisplayProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $monitorCount = $null
    $resolutions = @()
    $audioNames = $null

    if ($liveOk) {
        try {
            $monitors = @(Get-CimInstance -ClassName 'Win32_DesktopMonitor' -ErrorAction Stop | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string](Get-PcxPolicyMember -Object $_ -Name 'DeviceID'))
            })

            if ($monitors.Count -gt 0) {
                $monitorCount = $monitors.Count
                foreach ($monitor in $monitors) {
                    $width = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $monitor -Name 'ScreenWidth')
                    $height = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $monitor -Name 'ScreenHeight')
                    if ($null -ne $width -and $null -ne $height) {
                        $resolutions += ([string]$width + 'x' + [string]$height)
                    }
                }
            }
        }
        catch {
            $monitorCount = $null
        }

        if ($null -eq $monitorCount) {
            try {
                $configs = @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration' -ErrorAction Stop)
                if ($configs.Count -gt 0) {
                    $monitorCount = $configs.Count
                }
            }
            catch {
                $monitorCount = $null
            }
        }

        if ($resolutions.Count -eq 0) {
            try {
                $controllers = @(Get-CimInstance -ClassName 'Win32_VideoController' -ErrorAction Stop)
                foreach ($controller in $controllers) {
                    $width = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $controller -Name 'CurrentHorizontalResolution')
                    $height = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $controller -Name 'CurrentVerticalResolution')
                    if ($null -ne $width -and $null -ne $height) {
                        $resolutions += ([string]$width + 'x' + [string]$height)
                    }
                }
            }
            catch {
                $resolutions = @()
            }
        }

        try {
            $devices = @(Get-CimInstance -ClassName 'Win32_SoundDevice' -ErrorAction Stop)
            $audioNames = @()
            foreach ($device in $devices) {
                $name = ([string](Get-PcxPolicyMember -Object $device -Name 'Name')).Trim()
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $audioNames += $name
                }
            }
        }
        catch {
            $audioNames = $null
        }
    }

    return [ordered]@{
        monitorCount = $monitorCount
        resolutions  = $resolutions
        audioNames   = $audioNames
    }
}

function Get-DisplayFindings {
    <#
    .SYNOPSIS
        Builds the three read-only display findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxDisplayProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.monitorCount) {
            $findings += New-PcxFinding -Section 'display' -Id 'monitor-count' -Severity 'unavailable' `
                -TitleKey 'finding.display.monitor-count.title' -DetailKey 'finding.display.monitor-count.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no display facts are recorded'; source = 'cim:Win32_DesktopMonitor' })
        }
        elseif ($probe.monitorCount -lt 1) {
            $findings += New-PcxFinding -Section 'display' -Id 'monitor-count' -Severity 'warn' `
                -TitleKey 'finding.display.monitor-count.title' -DetailKey 'finding.display.monitor-count.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.monitorCount; source = 'cim:Win32_DesktopMonitor' })
        }
        else {
            $findings += New-PcxFinding -Section 'display' -Id 'monitor-count' -Severity 'good' `
                -TitleKey 'finding.display.monitor-count.title' -DetailKey 'finding.display.monitor-count.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.monitorCount; source = 'cim:Win32_DesktopMonitor' })
        }

        if ($probe.resolutions.Count -eq 0) {
            $findings += New-PcxFinding -Section 'display' -Id 'resolution-layout' -Severity 'unavailable' `
                -TitleKey 'finding.display.resolution-layout.title' -DetailKey 'finding.display.resolution-layout.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no display resolution facts are recorded'; source = 'cim:Win32_VideoController' })
        }
        else {
            $findings += New-PcxFinding -Section 'display' -Id 'resolution-layout' -Severity 'info' `
                -TitleKey 'finding.display.resolution-layout.title' -DetailKey 'finding.display.resolution-layout.detail' `
                -Evidence ([ordered]@{ status = 'measured'; layout = @($probe.resolutions); source = 'cim:Win32_VideoController' })
        }

        if ($null -eq $probe.audioNames) {
            $findings += New-PcxFinding -Section 'display' -Id 'audio-endpoints' -Severity 'unavailable' `
                -TitleKey 'finding.display.audio-endpoints.title' -DetailKey 'finding.display.audio-endpoints.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no audio device facts are recorded'; source = 'cim:Win32_SoundDevice' })
        }
        elseif ($probe.audioNames.Count -eq 0) {
            $findings += New-PcxFinding -Section 'display' -Id 'audio-endpoints' -Severity 'warn' `
                -TitleKey 'finding.display.audio-endpoints.title' -DetailKey 'finding.display.audio-endpoints.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = 0; source = 'cim:Win32_SoundDevice' })
        }
        else {
            $findings += New-PcxFinding -Section 'display' -Id 'audio-endpoints' -Severity 'good' `
                -TitleKey 'finding.display.audio-endpoints.title' -DetailKey 'finding.display.audio-endpoints.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.audioNames.Count; names = @($probe.audioNames | Select-Object -First 5); source = 'cim:Win32_SoundDevice' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'display' -Id 'display-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('display probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:display' }))
    }
}
