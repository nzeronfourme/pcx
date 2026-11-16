<#
.SYNOPSIS
    Security diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-SecurityFindings -Environment -Scan. Defender,
    firewall, BitLocker and TPM state come from the environment document;
    Defender exclusions are counted from the registry only when
    PCX_TEST_RUN is empty. Missing data becomes an unavailable finding,
    never a throw. No console output, no global state, no external binaries.
    ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxSecurityProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $defenderValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'defender')
    $defenderPresent = Get-PcxPolicyMember -Object $defenderValue -Name 'present'
    $defenderNames = @()
    if ($null -ne $defenderValue) {
        $defenderNames = @(@(Get-PcxPolicyMember -Object $defenderValue -Name 'products') | Where-Object { $null -ne $_ })
        if ($null -ne $defenderPresent) {
            $defenderPresent = [bool]$defenderPresent
        }
    }

    $firewallValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'firewall')
    $firewallAny = Get-PcxPolicyMember -Object $firewallValue -Name 'anyEnabled'
    $firewallProfiles = [ordered]@{}
    if ($null -ne $firewallValue) {
        foreach ($name in @('Domain', 'Private', 'Public')) {
            $profile = Get-PcxPolicyMember -Object $firewallValue -Name $name
            if ($null -ne $profile) {
                $firewallProfiles[$name] = [bool]$profile
            }
        }

        if ($null -ne $firewallAny) {
            $firewallAny = [bool]$firewallAny
        }
    }

    $bitLockerValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'bitLocker')
    $bitLockerProtected = Get-PcxPolicyMember -Object $bitLockerValue -Name 'anyProtected'
    if ($null -ne $bitLockerProtected) {
        $bitLockerProtected = [bool]$bitLockerProtected
    }

    $tpmValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $Environment -Name 'tpm')
    $tpmPresent = Get-PcxPolicyMember -Object $tpmValue -Name 'present'
    $tpmReady = Get-PcxPolicyMember -Object $tpmValue -Name 'ready'
    $tpmVersion = [string](Get-PcxPolicyMember -Object $tpmValue -Name 'version')
    if ($null -ne $tpmPresent) {
        $tpmPresent = [bool]$tpmPresent
    }

    if ($null -ne $tpmReady) {
        $tpmReady = [bool]$tpmReady
    }

    $exclusionCount = $null

    if ($liveOk) {
        try {
            $exclusions = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths' -ErrorAction Stop
            $count = 0
            foreach ($property in $exclusions.PSObject.Properties) {
                if (-not $property.Name.StartsWith('PS', [System.StringComparison]::Ordinal)) {
                    $count++
                }
            }

            $exclusionCount = $count
        }
        catch {
            try {
                if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths') {
                    $exclusionCount = 0
                }
                else {
                    $exclusionCount = $null
                }
            }
            catch {
                $exclusionCount = $null
            }
        }
    }

    return [ordered]@{
        defenderPresent   = $defenderPresent
        defenderNames     = $defenderNames
        firewallAny       = $firewallAny
        firewallProfiles  = $firewallProfiles
        bitLockerOn       = $bitLockerProtected
        tpmPresent        = $tpmPresent
        tpmReady          = $tpmReady
        tpmVersion        = $tpmVersion
        exclusionCount    = $exclusionCount
    }
}

function Get-SecurityFindings {
    <#
    .SYNOPSIS
        Builds the five read-only security findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxSecurityProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.defenderPresent) {
            $findings += New-PcxFinding -Section 'security' -Id 'defender-state' -Severity 'unavailable' `
                -TitleKey 'finding.security.defender-state.title' -DetailKey 'finding.security.defender-state.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no antivirus product facts are recorded'; source = 'fixture:environment.defender' })
        }
        elseif ($probe.defenderPresent -eq $true) {
            $findings += New-PcxFinding -Section 'security' -Id 'defender-state' -Severity 'good' `
                -TitleKey 'finding.security.defender-state.title' -DetailKey 'finding.security.defender-state.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; present = $true; products = @($probe.defenderNames); source = 'fixture:environment.defender' })
        }
        else {
            $findings += New-PcxFinding -Section 'security' -Id 'defender-state' -Severity 'warn' `
                -TitleKey 'finding.security.defender-state.title' -DetailKey 'finding.security.defender-state.detail' `
                -Evidence ([ordered]@{ status = 'measured'; present = $false; products = @($probe.defenderNames); source = 'fixture:environment.defender' })
        }

        if ($null -eq $probe.firewallAny) {
            $findings += New-PcxFinding -Section 'security' -Id 'firewall-state' -Severity 'unavailable' `
                -TitleKey 'finding.security.firewall-state.title' -DetailKey 'finding.security.firewall-state.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no firewall profile facts are recorded'; source = 'fixture:environment.firewall' })
        }
        elseif ($probe.firewallAny -eq $true) {
            $findings += New-PcxFinding -Section 'security' -Id 'firewall-state' -Severity 'good' `
                -TitleKey 'finding.security.firewall-state.title' -DetailKey 'finding.security.firewall-state.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; anyEnabled = $true; profiles = $probe.firewallProfiles; source = 'fixture:environment.firewall' })
        }
        else {
            $findings += New-PcxFinding -Section 'security' -Id 'firewall-state' -Severity 'warn' `
                -TitleKey 'finding.security.firewall-state.title' -DetailKey 'finding.security.firewall-state.detail' `
                -Evidence ([ordered]@{ status = 'measured'; anyEnabled = $false; profiles = $probe.firewallProfiles; source = 'fixture:environment.firewall' })
        }

        if ($null -eq $probe.bitLockerOn) {
            $findings += New-PcxFinding -Section 'security' -Id 'bitlocker-state' -Severity 'unavailable' `
                -TitleKey 'finding.security.bitlocker-state.title' -DetailKey 'finding.security.bitlocker-state.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no volume encryption facts are recorded'; source = 'fixture:environment.bitLocker' })
        }
        elseif ($probe.bitLockerOn -eq $true) {
            $findings += New-PcxFinding -Section 'security' -Id 'bitlocker-state' -Severity 'good' `
                -TitleKey 'finding.security.bitlocker-state.title' -DetailKey 'finding.security.bitlocker-state.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; protected = $true; source = 'fixture:environment.bitLocker' })
        }
        else {
            $findings += New-PcxFinding -Section 'security' -Id 'bitlocker-state' -Severity 'info' `
                -TitleKey 'finding.security.bitlocker-state.title' -DetailKey 'finding.security.bitlocker-state.detail' `
                -Evidence ([ordered]@{ status = 'measured'; protected = $false; source = 'fixture:environment.bitLocker' })
        }

        if ($null -eq $probe.tpmPresent) {
            $findings += New-PcxFinding -Section 'security' -Id 'tpm-state' -Severity 'unavailable' `
                -TitleKey 'finding.security.tpm-state.title' -DetailKey 'finding.security.tpm-state.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no TPM facts are recorded'; source = 'fixture:environment.tpm' })
        }
        elseif ($probe.tpmReady -eq $true) {
            $findings += New-PcxFinding -Section 'security' -Id 'tpm-state' -Severity 'good' `
                -TitleKey 'finding.security.tpm-state.title' -DetailKey 'finding.security.tpm-state.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; present = $true; ready = $true; version = $probe.tpmVersion; source = 'fixture:environment.tpm' })
        }
        elseif ($probe.tpmPresent -eq $true) {
            $findings += New-PcxFinding -Section 'security' -Id 'tpm-state' -Severity 'warn' `
                -TitleKey 'finding.security.tpm-state.title' -DetailKey 'finding.security.tpm-state.detail' `
                -Evidence ([ordered]@{ status = 'measured'; present = $true; ready = $false; source = 'fixture:environment.tpm' })
        }
        else {
            $findings += New-PcxFinding -Section 'security' -Id 'tpm-state' -Severity 'info' `
                -TitleKey 'finding.security.tpm-state.title' -DetailKey 'finding.security.tpm-state.detail' `
                -Evidence ([ordered]@{ status = 'measured'; present = $false; source = 'fixture:environment.tpm' })
        }

        if ($null -eq $probe.exclusionCount) {
            $findings += New-PcxFinding -Section 'security' -Id 'defender-exclusions' -Severity 'unavailable' `
                -TitleKey 'finding.security.defender-exclusions.title' -DetailKey 'finding.security.defender-exclusions.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the exclusions key could not be read'; source = 'registry:Windows Defender/Exclusions' })
        }
        elseif ($probe.exclusionCount -gt 0) {
            $findings += New-PcxFinding -Section 'security' -Id 'defender-exclusions' -Severity 'info' `
                -TitleKey 'finding.security.defender-exclusions.title' -DetailKey 'finding.security.defender-exclusions.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.exclusionCount; source = 'registry:Windows Defender/Exclusions' })
        }
        else {
            $findings += New-PcxFinding -Section 'security' -Id 'defender-exclusions' -Severity 'good' `
                -TitleKey 'finding.security.defender-exclusions.title' -DetailKey 'finding.security.defender-exclusions.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = 0; source = 'registry:Windows Defender/Exclusions' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'security' -Id 'security-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('security probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:security' }))
    }
}
