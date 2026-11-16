<#
.SYNOPSIS
    Performance state collector group.

.DESCRIPTION
    Reports the performance-relevant state the tune table needs: HAGS mode, GPU
    count, GameDVR state, the active power plan, overlay processes and the
    background process count. These are measured state only; no FPS or latency
    percentage is claimed. Read-only (registry, CIM, process list). A failed
    probe is unavailable with value $null, never a guessed zero.

    Fixture mode (-Fixture) maps environment fields and state.performance and
    performs no live probe.
#>

Set-StrictMode -Version 2.0

$script:PcxOverlayProcessNames = @(
    'Discord'
    'steam'
    'steamwebhelper'
    'nvsphelper64'
    'NVIDIA Overlay'
    'RivaTuner'
    'RTSS'
    'obs64'
    'GameBar'
    'GameBarFTServer'
    'XboxGameBar'
    'MSIAfterburner'
    'CAM'
    'RazerSynapse'
)

function Get-PcxCollectorPerformance {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    $hags = $null
    $gpuCount = $null
    $gameDvrEnabled = $null
    $powerPlanName = $null
    $overlayCount = $null
    $backgroundCount = $null
    $source = $null

    if ($null -ne $Fixture) {
        $environment = Get-PcxPolicyMember -Object $Fixture -Name 'environment'
        $state = Get-PcxPolicyMember -Object $Fixture -Name 'state'
        $performance = Get-PcxPolicyMember -Object $state -Name 'performance'

        $hags = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'hags')
        $gpuValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'gpu')
        $controllers = Get-PcxPolicyMember -Object $gpuValue -Name 'controllers'
        if ($null -ne $controllers) { $gpuCount = @($controllers).Count }
        $gameDvrValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'gameDvr')
        $gameDvrEnabled = Get-PcxPolicyMember -Object $gameDvrValue -Name 'enabled'
        $powerPlanValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'powerPlan')
        $powerPlanName = Get-PcxPolicyMember -Object $powerPlanValue -Name 'name'
        $overlayCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $performance -Name 'overlayProcessCount')
        $backgroundCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $performance -Name 'backgroundProcessCount')
        $source = 'fixture:environment + state.performance'
    }
    else {
        $hagsField = Invoke-PcxEnvironmentProbe -Label 'hags' -Probe { Get-PcxEnvironmentHagsField }
        $hags = Get-PcxEnvironmentFieldValue -Field $hagsField

        $gpuField = Invoke-PcxEnvironmentProbe -Label 'gpu' -Probe { Get-PcxEnvironmentGpuField }
        $gpuValue = Get-PcxEnvironmentFieldValue -Field $gpuField
        $controllers = Get-PcxPolicyMember -Object $gpuValue -Name 'controllers'
        if ($null -ne $controllers) { $gpuCount = @($controllers).Count }

        $gameDvrField = Invoke-PcxEnvironmentProbe -Label 'game-dvr' -Probe { Get-PcxEnvironmentGameDvrField }
        $gameDvrValue = Get-PcxEnvironmentFieldValue -Field $gameDvrField
        $gameDvrEnabled = Get-PcxPolicyMember -Object $gameDvrValue -Name 'enabled'

        $powerPlanField = Invoke-PcxEnvironmentProbe -Label 'power-plan' -Probe { Get-PcxEnvironmentPowerPlanField }
        $powerPlanValue = Get-PcxEnvironmentFieldValue -Field $powerPlanField
        $powerPlanName = Get-PcxPolicyMember -Object $powerPlanValue -Name 'name'

        try {
            $processes = @(Get-Process -ErrorAction Stop)
            $backgroundCount = $processes.Count
            $overlayCount = @($processes | Where-Object { $script:PcxOverlayProcessNames -contains $_.ProcessName }).Count
        }
        catch {
            $backgroundCount = $null
            $overlayCount = $null
        }
        $source = 'registry:GraphicsDrivers/GameDVR/PowerSchemes, cim:Win32_VideoController, process list'
    }

    return @(
        New-PcxMetric -Id 'performance.hags_mode' -Group 'performance' -Status 'measured' -Value $hags -Unit 'number' -Domain 'performance' -Window 'instant' -Source $source
        New-PcxMetric -Id 'performance.gpu_count' -Group 'performance' -Status 'measured' -Value $gpuCount -Unit 'count' -Domain 'performance' -Window 'instant' -Source $source
        New-PcxMetric -Id 'performance.game_dvr_enabled' -Group 'performance' -Status 'measured' -Value $gameDvrEnabled -Unit 'bool' -Domain 'performance' -Window 'instant' -Source $source
        New-PcxMetric -Id 'performance.power_plan' -Group 'performance' -Status 'measured' -Value $powerPlanName -Unit 'string' -Domain 'performance' -Window 'instant' -Source $source
        New-PcxMetric -Id 'performance.overlay_processes' -Group 'performance' -Status 'measured' -Value $overlayCount -Unit 'count' -Domain 'performance' -Window 'instant' -Source $source
        New-PcxMetric -Id 'performance.background_processes' -Group 'performance' -Status 'measured' -Value $backgroundCount -Unit 'count' -Domain 'performance' -Window 'instant' -Source $source
    )
}
