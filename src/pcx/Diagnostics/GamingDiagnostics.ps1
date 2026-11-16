<#
.SYNOPSIS
    Gaming diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-GamingFindings -Environment -Scan. HAGS, GameDVR
    and VBS/HVCI come from the environment document; the Game Mode registry
    value and overlay process list are probed live only when PCX_TEST_RUN is
    empty. A registry value missing on an existing key means off, never
    unavailable. Missing data becomes an unavailable finding, never a throw.
    No console output, no global state, no external binaries. ASCII only,
    5.1 compatible.
#>

Set-StrictMode -Version 2.0

$script:PcxGamingOverlayProcessNames = @(
    'Discord'
    'steam'
    'steamwebhelper'
    'nvsphelper64'
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

function Read-PcxGamingProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $hags = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'hags')
    $hags = ConvertTo-PcxCollectorInt -Value $hags

    $gameDvrValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'gameDvr')
    $gameDvrEnabled = Get-PcxPolicyMember -Object $gameDvrValue -Name 'enabled'
    if ($null -ne $gameDvrEnabled) {
        $gameDvrEnabled = [bool]$gameDvrEnabled
    }

    $vbs = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'vbs')
    if ($null -ne $vbs) {
        $vbs = [bool]$vbs
    }

    $hvci = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'hvci')
    if ($null -ne $hvci) {
        $hvci = [bool]$hvci
    }

    $state = Get-PcxPolicyMember -Object $Scan -Name 'state'
    if ($null -eq $state) {
        $state = $Scan
    }

    $performance = Get-PcxPolicyMember -Object $state -Name 'performance'
    $overlayCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $performance -Name 'overlayProcessCount')
    $overlayNames = @()

    $gameMode = $null
    $gameModeState = 'unavailable'

    if ($liveOk) {
        $modeState = Read-PcxEnvironmentRegistryValueState -Path 'HKCU:\SOFTWARE\Microsoft\GameBar' -Name 'AllowAutoGameMode'
        if ($modeState.outcome -eq 'present') {
            $modeValue = ConvertTo-PcxCollectorInt -Value $modeState.raw
            if ($null -eq $modeValue) {
                $gameModeState = 'unavailable'
            }
            else {
                $gameMode = ($modeValue -eq 1)
                $gameModeState = 'measured'
            }
        }
        elseif ($modeState.outcome -eq 'missing') {
            $gameMode = $false
            $gameModeState = 'measured'
        }
        else {
            $gameModeState = 'unavailable'
        }

        if ($null -eq $gameDvrEnabled) {
            $captureState = Read-PcxEnvironmentRegistryValueState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled'
            if ($captureState.outcome -eq 'present') {
                $captureValue = ConvertTo-PcxCollectorInt -Value $captureState.raw
                if ($null -ne $captureValue) {
                    $gameDvrEnabled = ($captureValue -eq 1)
                }
            }
            elseif ($captureState.outcome -eq 'missing') {
                $gameDvrEnabled = $false
            }
        }

        if ($null -eq $overlayCount) {
            try {
                $matches = @(Get-Process -ErrorAction Stop | Where-Object { $script:PcxGamingOverlayProcessNames -contains $_.ProcessName })
                $overlayCount = $matches.Count
                $overlayNames = @($matches | Select-Object -First 5 | ForEach-Object { [string]$_.ProcessName })
            }
            catch {
                $overlayCount = $null
                $overlayNames = @()
            }
        }
    }

    return [ordered]@{
        hags          = $hags
        gameDvr       = $gameDvrEnabled
        vbs           = $vbs
        hvci          = $hvci
        gameMode      = $gameMode
        gameModeState = $gameModeState
        overlayCount  = $overlayCount
        overlayNames  = $overlayNames
    }
}

function Get-GamingFindings {
    <#
    .SYNOPSIS
        Builds the five read-only gaming findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxGamingProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($probe.gameModeState -ne 'measured') {
            $findings += New-PcxFinding -Section 'gaming' -Id 'game-mode' -Severity 'unavailable' `
                -TitleKey 'finding.gaming.game-mode.title' -DetailKey 'finding.gaming.game-mode.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the game mode value could not be read'; source = 'registry:GameBar' })
        }
        elseif ($probe.gameMode -eq $true) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'game-mode' -Severity 'good' `
                -TitleKey 'finding.gaming.game-mode.title' -DetailKey 'finding.gaming.game-mode.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; enabled = $true; source = 'registry:GameBar' })
        }
        else {
            $findings += New-PcxFinding -Section 'gaming' -Id 'game-mode' -Severity 'info' `
                -TitleKey 'finding.gaming.game-mode.title' -DetailKey 'finding.gaming.game-mode.detail' `
                -Evidence ([ordered]@{ status = 'measured'; enabled = $false; source = 'registry:GameBar' })
        }

        if ($null -eq $probe.hags) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'hags' -Severity 'unavailable' `
                -TitleKey 'finding.gaming.hags.title' -DetailKey 'finding.gaming.hags.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the scheduling mode could not be read'; source = 'fixture:environment.hags' })
        }
        elseif ($probe.hags -eq 2) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'hags' -Severity 'good' `
                -TitleKey 'finding.gaming.hags.title' -DetailKey 'finding.gaming.hags.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; mode = 2; enabled = $true; source = 'fixture:environment.hags' })
        }
        else {
            $findings += New-PcxFinding -Section 'gaming' -Id 'hags' -Severity 'info' `
                -TitleKey 'finding.gaming.hags.title' -DetailKey 'finding.gaming.hags.detail' `
                -Evidence ([ordered]@{ status = 'measured'; mode = $probe.hags; enabled = $false; source = 'fixture:environment.hags' })
        }

        if ($null -eq $probe.gameDvr) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'game-dvr' -Severity 'unavailable' `
                -TitleKey 'finding.gaming.game-dvr.title' -DetailKey 'finding.gaming.game-dvr.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the capture values could not be read'; source = 'fixture:environment.gameDvr' })
        }
        elseif ($probe.gameDvr -eq $true) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'game-dvr' -Severity 'info' `
                -TitleKey 'finding.gaming.game-dvr.title' -DetailKey 'finding.gaming.game-dvr.detail' `
                -Evidence ([ordered]@{ status = 'measured'; enabled = $true; source = 'fixture:environment.gameDvr' })
        }
        else {
            $findings += New-PcxFinding -Section 'gaming' -Id 'game-dvr' -Severity 'good' `
                -TitleKey 'finding.gaming.game-dvr.title' -DetailKey 'finding.gaming.game-dvr.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; enabled = $false; source = 'fixture:environment.gameDvr' })
        }

        if ($null -eq $probe.overlayCount) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'overlay-processes' -Severity 'unavailable' `
                -TitleKey 'finding.gaming.overlay-processes.title' -DetailKey 'finding.gaming.overlay-processes.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the process list could not be read'; source = 'process:Get-Process' })
        }
        elseif ($probe.overlayCount -ge 3) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'overlay-processes' -Severity 'warn' `
                -TitleKey 'finding.gaming.overlay-processes.title' -DetailKey 'finding.gaming.overlay-processes.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.overlayCount; names = @($probe.overlayNames); source = 'process:Get-Process' })
        }
        elseif ($probe.overlayCount -ge 1) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'overlay-processes' -Severity 'info' `
                -TitleKey 'finding.gaming.overlay-processes.title' -DetailKey 'finding.gaming.overlay-processes.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.overlayCount; names = @($probe.overlayNames); source = 'process:Get-Process' })
        }
        else {
            $findings += New-PcxFinding -Section 'gaming' -Id 'overlay-processes' -Severity 'good' `
                -TitleKey 'finding.gaming.overlay-processes.title' -DetailKey 'finding.gaming.overlay-processes.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = 0; source = 'process:Get-Process' })
        }

        if ($null -eq $probe.vbs -or $null -eq $probe.hvci) {
            $findings += New-PcxFinding -Section 'gaming' -Id 'vbs-hvci' -Severity 'unavailable' `
                -TitleKey 'finding.gaming.vbs-hvci.title' -DetailKey 'finding.gaming.vbs-hvci.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the virtualization policy values could not be read'; source = 'fixture:environment.vbs' })
        }
        else {
            $findings += New-PcxFinding -Section 'gaming' -Id 'vbs-hvci' -Severity 'info' `
                -TitleKey 'finding.gaming.vbs-hvci.title' -DetailKey 'finding.gaming.vbs-hvci.detail' `
                -Evidence ([ordered]@{ status = 'measured'; vbs = $probe.vbs; hvci = $probe.hvci; source = 'fixture:environment.vbs' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'gaming' -Id 'gaming-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('gaming probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:gaming' }))
    }
}
