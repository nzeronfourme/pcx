<#
.SYNOPSIS
    Background diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-BackgroundFindings -Environment -Scan. Fixture
    counts come from the scan state; live process, Run-key and scheduled
    task probes run only when PCX_TEST_RUN is empty. Missing data becomes
    an unavailable finding, never a throw. No console output, no global
    state, no external binaries. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxBackgroundProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $state = Get-PcxPolicyMember -Object $Scan -Name 'state'
    if ($null -eq $state) {
        $state = $Scan
    }

    $performance = Get-PcxPolicyMember -Object $state -Name 'performance'
    $processCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $performance -Name 'backgroundProcessCount')

    $startup = Get-PcxPolicyMember -Object $state -Name 'startup'
    $startupCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $startup -Name 'runValuesCount')

    $topRam = @()
    $taskCount = $null

    if ($liveOk) {
        if ($null -eq $processCount) {
            try {
                $processCount = @(Get-Process -ErrorAction Stop).Count
            }
            catch {
                $processCount = $null
            }
        }

        try {
            $topRam = @(Get-Process -ErrorAction Stop | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
                [ordered]@{ name = [string]$_.ProcessName; bytes = [long]$_.WorkingSet64 }
            })
        }
        catch {
            $topRam = @()
        }

        if ($null -eq $startupCount) {
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
                    continue
                }
            }

            if ($readAny) {
                $startupCount = $count
            }
        }

        try {
            $taskCount = @(Get-ScheduledTask -ErrorAction Stop).Count
        }
        catch {
            $taskCount = $null
        }
    }

    return [ordered]@{
        processCount = $processCount
        topRam       = $topRam
        startupCount = $startupCount
        taskCount    = $taskCount
    }
}

function Get-BackgroundFindings {
    <#
    .SYNOPSIS
        Builds the four read-only background findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxBackgroundProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.processCount) {
            $findings += New-PcxFinding -Section 'background' -Id 'process-count' -Severity 'unavailable' `
                -TitleKey 'finding.background.process-count.title' -DetailKey 'finding.background.process-count.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the process list could not be read'; source = 'fixture:state.performance' })
        }
        elseif ($probe.processCount -gt 300) {
            $findings += New-PcxFinding -Section 'background' -Id 'process-count' -Severity 'warn' `
                -TitleKey 'finding.background.process-count.title' -DetailKey 'finding.background.process-count.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.processCount; source = 'fixture:state.performance' })
        }
        elseif ($probe.processCount -gt 200) {
            $findings += New-PcxFinding -Section 'background' -Id 'process-count' -Severity 'info' `
                -TitleKey 'finding.background.process-count.title' -DetailKey 'finding.background.process-count.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.processCount; source = 'fixture:state.performance' })
        }
        else {
            $findings += New-PcxFinding -Section 'background' -Id 'process-count' -Severity 'good' `
                -TitleKey 'finding.background.process-count.title' -DetailKey 'finding.background.process-count.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.processCount; source = 'fixture:state.performance' })
        }

        if ($probe.topRam.Count -eq 0) {
            $findings += New-PcxFinding -Section 'background' -Id 'top-ram-processes' -Severity 'unavailable' `
                -TitleKey 'finding.background.top-ram-processes.title' -DetailKey 'finding.background.top-ram-processes.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'per-process working sets are not recorded'; source = 'process:Get-Process' })
        }
        else {
            $findings += New-PcxFinding -Section 'background' -Id 'top-ram-processes' -Severity 'info' `
                -TitleKey 'finding.background.top-ram-processes.title' -DetailKey 'finding.background.top-ram-processes.detail' `
                -Evidence ([ordered]@{ status = 'measured'; top = @($probe.topRam); source = 'process:Get-Process' })
        }

        if ($null -eq $probe.startupCount) {
            $findings += New-PcxFinding -Section 'background' -Id 'startup-entries' -Severity 'unavailable' `
                -TitleKey 'finding.background.startup-entries.title' -DetailKey 'finding.background.startup-entries.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the Run keys could not be read'; source = 'registry:Run keys' })
        }
        elseif ($probe.startupCount -gt 12) {
            $findings += New-PcxFinding -Section 'background' -Id 'startup-entries' -Severity 'warn' `
                -TitleKey 'finding.background.startup-entries.title' -DetailKey 'finding.background.startup-entries.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.startupCount; source = 'fixture:state.startup' })
        }
        elseif ($probe.startupCount -gt 6) {
            $findings += New-PcxFinding -Section 'background' -Id 'startup-entries' -Severity 'info' `
                -TitleKey 'finding.background.startup-entries.title' -DetailKey 'finding.background.startup-entries.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.startupCount; source = 'fixture:state.startup' })
        }
        else {
            $findings += New-PcxFinding -Section 'background' -Id 'startup-entries' -Severity 'good' `
                -TitleKey 'finding.background.startup-entries.title' -DetailKey 'finding.background.startup-entries.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.startupCount; source = 'fixture:state.startup' })
        }

        if ($null -eq $probe.taskCount) {
            $findings += New-PcxFinding -Section 'background' -Id 'scheduled-task-count' -Severity 'unavailable' `
                -TitleKey 'finding.background.scheduled-task-count.title' -DetailKey 'finding.background.scheduled-task-count.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the task scheduler could not be read'; source = 'task:Get-ScheduledTask' })
        }
        elseif ($probe.taskCount -gt 300) {
            $findings += New-PcxFinding -Section 'background' -Id 'scheduled-task-count' -Severity 'warn' `
                -TitleKey 'finding.background.scheduled-task-count.title' -DetailKey 'finding.background.scheduled-task-count.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.taskCount; source = 'task:Get-ScheduledTask' })
        }
        else {
            $findings += New-PcxFinding -Section 'background' -Id 'scheduled-task-count' -Severity 'info' `
                -TitleKey 'finding.background.scheduled-task-count.title' -DetailKey 'finding.background.scheduled-task-count.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.taskCount; source = 'task:Get-ScheduledTask' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'background' -Id 'background-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('background probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:background' }))
    }
}
