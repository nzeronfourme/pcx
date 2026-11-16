<#
.SYNOPSIS
    Network diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-NetworkFindings -Environment -Scan. Link speed,
    DNS servers, Nagle state and TCP auto-tuning are probed via CIM and the
    registry only when PCX_TEST_RUN is empty; the fixture carries no network
    facts, so fixture runs report unavailable findings. No console output,
    no global state, no external binaries. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxNetworkProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $adapters = @()
    $dnsByInterface = @()
    $nagleByInterface = @()
    $autoTuning = $null

    if ($liveOk) {
        try {
            $liveAdapters = @(Get-CimInstance -ClassName 'Win32_NetworkAdapter' -ErrorAction Stop | Where-Object {
                [int](ConvertTo-PcxCollectorInt -Value (Get-PcxPolicyMember -Object $_ -Name 'NetConnectionStatus')) -eq 2
            })

            foreach ($adapter in $liveAdapters) {
                $speedBps = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $adapter -Name 'Speed')
                $speedMbps = $null
                if ($null -ne $speedBps -and $speedBps -gt 0) {
                    $speedMbps = [math]::Round([double]$speedBps / 1000000, 0)
                }

                $adapters += [ordered]@{
                    name      = [string](Get-PcxPolicyMember -Object $adapter -Name 'NetConnectionID')
                    product   = [string](Get-PcxPolicyMember -Object $adapter -Name 'Name')
                    speedMbps = $speedMbps
                }
            }
        }
        catch {
            $adapters = @()
        }

        try {
            $ifaceKeys = @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction Stop)
            foreach ($key in $ifaceKeys) {
                try {
                    $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                }
                catch {
                    continue
                }

                $ifaceId = [string]$key.PSChildName
                $staticDns = [string](Get-PcxPolicyMember -Object $props -Name 'NameServer')
                $dhcpDns = [string](Get-PcxPolicyMember -Object $props -Name 'DhcpNameServer')
                $servers = @()
                foreach ($raw in @($staticDns, $dhcpDns)) {
                    if ([string]::IsNullOrWhiteSpace($raw)) {
                        continue
                    }

                    foreach ($part in ($raw -split '[,\s]+')) {
                        $clean = $part.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($clean) -and $servers -notcontains $clean) {
                            $servers += $clean
                        }
                    }
                }

                $dnsByInterface += [ordered]@{ interface = $ifaceId; servers = $servers }

                $noDelay = Get-PcxPolicyMember -Object $props -Name 'TcpNoDelay'
                $ackFreq = Get-PcxPolicyMember -Object $props -Name 'TcpAckFrequency'
                $nagleDisabled = $null
                if ($null -ne $noDelay) {
                    $nagleDisabled = ((ConvertTo-PcxCollectorInt -Value $noDelay) -eq 1)
                }
                elseif ($null -ne $ackFreq) {
                    $nagleDisabled = ((ConvertTo-PcxCollectorInt -Value $ackFreq) -eq 1)
                }

                $nagleByInterface += [ordered]@{ interface = $ifaceId; nagleDisabled = $nagleDisabled }
            }
        }
        catch {
            $dnsByInterface = @()
            $nagleByInterface = @()
        }

        try {
            $tcpSetting = Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName 'MSFT_NetTCPSetting' -ErrorAction Stop | Select-Object -First 1
            $autoTuning = [string](Get-PcxPolicyMember -Object $tcpSetting -Name 'AutoTuningLevelLocal')
            if ([string]::IsNullOrWhiteSpace($autoTuning)) {
                $autoTuning = $null
            }
        }
        catch {
            $autoTuning = $null
        }
    }

    return [ordered]@{
        adapters   = $adapters
        dns        = $dnsByInterface
        nagle      = $nagleByInterface
        autoTuning = $autoTuning
    }
}

function Get-NetworkFindings {
    <#
    .SYNOPSIS
        Builds the four read-only network findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxNetworkProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($probe.adapters.Count -eq 0) {
            $findings += New-PcxFinding -Section 'network' -Id 'adapter-link-speed' -Severity 'unavailable' `
                -TitleKey 'finding.network.adapter-link-speed.title' -DetailKey 'finding.network.adapter-link-speed.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no connected adapter facts are recorded'; source = 'cim:Win32_NetworkAdapter' })
        }
        else {
            $findings += New-PcxFinding -Section 'network' -Id 'adapter-link-speed' -Severity 'info' `
                -TitleKey 'finding.network.adapter-link-speed.title' -DetailKey 'finding.network.adapter-link-speed.detail' `
                -Evidence ([ordered]@{ status = 'measured'; adapters = @($probe.adapters); source = 'cim:Win32_NetworkAdapter' })
        }

        if ($probe.dns.Count -eq 0) {
            $findings += New-PcxFinding -Section 'network' -Id 'dns-servers' -Severity 'unavailable' `
                -TitleKey 'finding.network.dns-servers.title' -DetailKey 'finding.network.dns-servers.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no interface DNS facts are recorded'; source = 'registry:Tcpip/Parameters/Interfaces' })
        }
        else {
            $empty = @($probe.dns | Where-Object { @($_.servers).Count -eq 0 })
            if ($empty.Count -gt 0) {
                $findings += New-PcxFinding -Section 'network' -Id 'dns-servers' -Severity 'warn' `
                    -TitleKey 'finding.network.dns-servers.title' -DetailKey 'finding.network.dns-servers.detail' `
                    -Evidence ([ordered]@{ status = 'measured'; interfaces = @($probe.dns); source = 'registry:Tcpip/Parameters/Interfaces' })
            }
            else {
                $findings += New-PcxFinding -Section 'network' -Id 'dns-servers' -Severity 'good' `
                    -TitleKey 'finding.network.dns-servers.title' -DetailKey 'finding.network.dns-servers.detail' `
                    -AlreadyGood $true `
                    -Evidence ([ordered]@{ status = 'measured'; interfaces = @($probe.dns); source = 'registry:Tcpip/Parameters/Interfaces' })
            }
        }

        if ($probe.nagle.Count -eq 0) {
            $findings += New-PcxFinding -Section 'network' -Id 'nagle' -Severity 'unavailable' `
                -TitleKey 'finding.network.nagle.title' -DetailKey 'finding.network.nagle.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no interface TCP facts are recorded'; source = 'registry:Tcpip/Parameters/Interfaces' })
        }
        else {
            $findings += New-PcxFinding -Section 'network' -Id 'nagle' -Severity 'info' `
                -TitleKey 'finding.network.nagle.title' -DetailKey 'finding.network.nagle.detail' `
                -Evidence ([ordered]@{ status = 'measured'; interfaces = @($probe.nagle); source = 'registry:Tcpip/Parameters/Interfaces' })
        }

        if ($null -eq $probe.autoTuning) {
            $findings += New-PcxFinding -Section 'network' -Id 'tcp-autotuning' -Severity 'unavailable' `
                -TitleKey 'finding.network.tcp-autotuning.title' -DetailKey 'finding.network.tcp-autotuning.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the auto-tuning level could not be read'; source = 'cim:MSFT_NetTCPSetting' })
        }
        elseif ($probe.autoTuning -ieq 'Normal') {
            $findings += New-PcxFinding -Section 'network' -Id 'tcp-autotuning' -Severity 'good' `
                -TitleKey 'finding.network.tcp-autotuning.title' -DetailKey 'finding.network.tcp-autotuning.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; level = $probe.autoTuning; source = 'cim:MSFT_NetTCPSetting' })
        }
        elseif ($probe.autoTuning -ieq 'Disabled') {
            $findings += New-PcxFinding -Section 'network' -Id 'tcp-autotuning' -Severity 'warn' `
                -TitleKey 'finding.network.tcp-autotuning.title' -DetailKey 'finding.network.tcp-autotuning.detail' `
                -Evidence ([ordered]@{ status = 'measured'; level = $probe.autoTuning; source = 'cim:MSFT_NetTCPSetting' })
        }
        else {
            $findings += New-PcxFinding -Section 'network' -Id 'tcp-autotuning' -Severity 'info' `
                -TitleKey 'finding.network.tcp-autotuning.title' -DetailKey 'finding.network.tcp-autotuning.detail' `
                -Evidence ([ordered]@{ status = 'measured'; level = $probe.autoTuning; source = 'cim:MSFT_NetTCPSetting' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'network' -Id 'network-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('network probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:network' }))
    }
}
