<#
.SYNOPSIS
    Services diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-ServicesFindings -Environment -Scan. Fixture counts
    come from the scan state; live CIM service probes run only when
    PCX_TEST_RUN is empty. Missing data becomes an unavailable finding, never
    a throw. No console output, no global state, no external binaries. ASCII
    only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxServicesProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $state = Get-PcxPolicyMember -Object $Scan -Name 'state'
    if ($null -eq $state) {
        $state = $Scan
    }

    $services = Get-PcxPolicyMember -Object $state -Name 'services'
    $autoCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $services -Name 'autoCount')
    $runningCount = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $services -Name 'runningCount')

    $thirdPartyCount = $null
    $thirdPartySample = @()
    $failedCount = $null
    $failedSample = @()

    if ($liveOk) {
        try {
            $systemRoot = [System.Environment]::GetEnvironmentVariable('SYSTEMROOT')
            if ([string]::IsNullOrWhiteSpace($systemRoot)) {
                $systemRoot = 'C:\Windows'
            }

            $liveServices = @(Get-CimInstance -ClassName 'Win32_Service' -ErrorAction Stop)
            if ($null -eq $autoCount) {
                $autoCount = @($liveServices | Where-Object { [string](Get-PcxPolicyMember -Object $_ -Name 'StartMode') -ieq 'Auto' }).Count
            }

            if ($null -eq $runningCount) {
                $runningCount = @($liveServices | Where-Object { [string](Get-PcxPolicyMember -Object $_ -Name 'State') -ieq 'Running' }).Count
            }

            $thirdParty = @()
            $failed = @()
            foreach ($service in $liveServices) {
                $startMode = [string](Get-PcxPolicyMember -Object $service -Name 'StartMode')
                $name = [string](Get-PcxPolicyMember -Object $service -Name 'Name')
                if ($startMode -ieq 'Auto') {
                    $path = ([string](Get-PcxPolicyMember -Object $service -Name 'PathName')).Trim()
                    $quote = [char]34
                    if ($path.StartsWith([string]$quote)) {
                        $path = $path.TrimStart($quote).Split($quote)[0]
                    }

                    $path = $path.Split(' ')[0]
                    if (-not [string]::IsNullOrWhiteSpace($path) -and -not $path.StartsWith($systemRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $thirdParty += $name
                    }
                }

                $stateName = [string](Get-PcxPolicyMember -Object $service -Name 'State')
                $exitCode = ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $service -Name 'ExitCode')
                if ($stateName -ieq 'Stopped' -and $startMode -ieq 'Auto' -and $null -ne $exitCode -and $exitCode -ne 0 -and $exitCode -ne 1077) {
                    $failed += ($name + ' exit ' + [string]$exitCode)
                }
            }

            $thirdPartyCount = $thirdParty.Count
            $thirdPartySample = @($thirdParty | Select-Object -First 5)
            $failedCount = $failed.Count
            $failedSample = @($failed | Select-Object -First 5)
        }
        catch {
            $thirdPartyCount = $null
            $failedCount = $null
        }
    }

    return [ordered]@{
        autoCount       = $autoCount
        runningCount    = $runningCount
        thirdPartyCount = $thirdPartyCount
        thirdPartyNames = $thirdPartySample
        failedCount     = $failedCount
        failedNames     = $failedSample
    }
}

function Get-ServicesFindings {
    <#
    .SYNOPSIS
        Builds the three read-only services findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxServicesProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.autoCount) {
            $findings += New-PcxFinding -Section 'services' -Id 'auto-services' -Severity 'unavailable' `
                -TitleKey 'finding.services.auto-services.title' -DetailKey 'finding.services.auto-services.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the service list could not be read'; source = 'fixture:state.services' })
        }
        elseif ($probe.autoCount -gt 140) {
            $findings += New-PcxFinding -Section 'services' -Id 'auto-services' -Severity 'warn' `
                -TitleKey 'finding.services.auto-services.title' -DetailKey 'finding.services.auto-services.detail' `
                -Evidence ([ordered]@{ status = 'measured'; auto = $probe.autoCount; running = $probe.runningCount; source = 'fixture:state.services' })
        }
        elseif ($probe.autoCount -gt 110) {
            $findings += New-PcxFinding -Section 'services' -Id 'auto-services' -Severity 'info' `
                -TitleKey 'finding.services.auto-services.title' -DetailKey 'finding.services.auto-services.detail' `
                -Evidence ([ordered]@{ status = 'measured'; auto = $probe.autoCount; running = $probe.runningCount; source = 'fixture:state.services' })
        }
        else {
            $findings += New-PcxFinding -Section 'services' -Id 'auto-services' -Severity 'good' `
                -TitleKey 'finding.services.auto-services.title' -DetailKey 'finding.services.auto-services.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; auto = $probe.autoCount; running = $probe.runningCount; source = 'fixture:state.services' })
        }

        if ($null -eq $probe.thirdPartyCount) {
            $findings += New-PcxFinding -Section 'services' -Id 'third-party-services' -Severity 'unavailable' `
                -TitleKey 'finding.services.third-party-services.title' -DetailKey 'finding.services.third-party-services.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'service image paths are not recorded'; source = 'cim:Win32_Service' })
        }
        elseif ($probe.thirdPartyCount -gt 20) {
            $findings += New-PcxFinding -Section 'services' -Id 'third-party-services' -Severity 'warn' `
                -TitleKey 'finding.services.third-party-services.title' -DetailKey 'finding.services.third-party-services.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.thirdPartyCount; sample = @($probe.thirdPartyNames); source = 'cim:Win32_Service' })
        }
        elseif ($probe.thirdPartyCount -gt 0) {
            $findings += New-PcxFinding -Section 'services' -Id 'third-party-services' -Severity 'info' `
                -TitleKey 'finding.services.third-party-services.title' -DetailKey 'finding.services.third-party-services.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.thirdPartyCount; sample = @($probe.thirdPartyNames); source = 'cim:Win32_Service' })
        }
        else {
            $findings += New-PcxFinding -Section 'services' -Id 'third-party-services' -Severity 'good' `
                -TitleKey 'finding.services.third-party-services.title' -DetailKey 'finding.services.third-party-services.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = 0; source = 'cim:Win32_Service' })
        }

        if ($null -eq $probe.failedCount) {
            $findings += New-PcxFinding -Section 'services' -Id 'failed-services' -Severity 'unavailable' `
                -TitleKey 'finding.services.failed-services.title' -DetailKey 'finding.services.failed-services.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'service exit codes are not recorded'; source = 'cim:Win32_Service' })
        }
        elseif ($probe.failedCount -gt 0) {
            $findings += New-PcxFinding -Section 'services' -Id 'failed-services' -Severity 'warn' `
                -TitleKey 'finding.services.failed-services.title' -DetailKey 'finding.services.failed-services.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.failedCount; sample = @($probe.failedNames); source = 'cim:Win32_Service' })
        }
        else {
            $findings += New-PcxFinding -Section 'services' -Id 'failed-services' -Severity 'good' `
                -TitleKey 'finding.services.failed-services.title' -DetailKey 'finding.services.failed-services.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = 0; source = 'cim:Win32_Service' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'services' -Id 'services-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('services probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:services' }))
    }
}
