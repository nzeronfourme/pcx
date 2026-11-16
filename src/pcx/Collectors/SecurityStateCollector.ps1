<#
.SYNOPSIS
    Security state collector group.

.DESCRIPTION
    Reports the security posture the tune table must not touch blindly: VBS,
    HVCI, Defender presence, firewall, TPM readiness, BitLocker protection and
    whether an anticheat session is active (installed-but-idle clients are not
    active). Read-only (registry and CIM via the existing environment probes). A
    failed probe is unavailable with value $null.

    Fixture mode (-Fixture) maps the environment fixture and performs no live
    probe.
#>

Set-StrictMode -Version 2.0

function Get-PcxCollectorSecurityState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    if ($null -ne $Fixture) {
        $environment = Get-PcxPolicyMember -Object $Fixture -Name 'environment'
        $source = 'fixture:environment'

        $vbs = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'vbs')
        $hvci = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'hvci')
        $defenderValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'defender')
        $firewallValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'firewall')
        $tpmValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'tpm')
        $bitLockerValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'bitLocker')
        $anticheatValue = Get-PcxEnvironmentFieldValue -Field (Get-PcxPolicyMember -Object $environment -Name 'anticheat')

        return @(
            New-PcxMetric -Id 'security.vbs_enabled' -Group 'security' -Status 'measured' -Value $vbs -Unit 'bool' -Domain 'security' -Window 'instant' -Source $source
            New-PcxMetric -Id 'security.hvci_enabled' -Group 'security' -Status 'measured' -Value $hvci -Unit 'bool' -Domain 'security' -Window 'instant' -Source $source
            New-PcxMetric -Id 'security.defender_present' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $defenderValue -Name 'present') -Unit 'bool' -Domain 'security' -Window 'instant' -Source $source
            New-PcxMetric -Id 'security.firewall_enabled' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $firewallValue -Name 'anyEnabled') -Unit 'bool' -Domain 'security' -Window 'instant' -Source $source
            New-PcxMetric -Id 'security.tpm_ready' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $tpmValue -Name 'ready') -Unit 'bool' -Domain 'security' -Window 'instant' -Source $source
            New-PcxMetric -Id 'security.bitlocker_protected' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $bitLockerValue -Name 'anyProtected') -Unit 'bool' -Domain 'security' -Window 'instant' -Source $source
            New-PcxMetric -Id 'security.anticheat_present' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $anticheatValue -Name 'present') -Unit 'bool' -Domain 'security' -Window 'instant' -Source $source
        )
    }

    $vbsField = Invoke-PcxEnvironmentProbe -Label 'vbs' -Probe { Get-PcxEnvironmentVbsField }
    $hvciField = Invoke-PcxEnvironmentProbe -Label 'hvci' -Probe { Get-PcxEnvironmentHvciField }
    $defenderField = Invoke-PcxEnvironmentProbe -Label 'defender' -Probe { Get-PcxEnvironmentDefenderField }
    $firewallField = Invoke-PcxEnvironmentProbe -Label 'firewall' -Probe { Get-PcxEnvironmentFirewallField }
    $tpmField = Invoke-PcxEnvironmentProbe -Label 'tpm' -Probe { Get-PcxEnvironmentTpmField }
    $bitLockerField = Invoke-PcxEnvironmentProbe -Label 'bitlocker' -Probe { Get-PcxEnvironmentBitLockerField }
    $anticheatField = Invoke-PcxEnvironmentProbe -Label 'anticheat' -Probe { Get-PcxEnvironmentAnticheatField }

    $defenderValue = Get-PcxEnvironmentFieldValue -Field $defenderField
    $firewallValue = Get-PcxEnvironmentFieldValue -Field $firewallField
    $tpmValue = Get-PcxEnvironmentFieldValue -Field $tpmField
    $bitLockerValue = Get-PcxEnvironmentFieldValue -Field $bitLockerField
    $anticheatValue = Get-PcxEnvironmentFieldValue -Field $anticheatField

    return @(
        New-PcxMetric -Id 'security.vbs_enabled' -Group 'security' -Status 'measured' -Value (Get-PcxEnvironmentFieldValue -Field $vbsField) -Unit 'bool' -Domain 'security' -Window 'instant' -Source 'registry:DeviceGuard'
        New-PcxMetric -Id 'security.hvci_enabled' -Group 'security' -Status 'measured' -Value (Get-PcxEnvironmentFieldValue -Field $hvciField) -Unit 'bool' -Domain 'security' -Window 'instant' -Source 'registry:DeviceGuard\Scenarios\HVCI'
        New-PcxMetric -Id 'security.defender_present' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $defenderValue -Name 'present') -Unit 'bool' -Domain 'security' -Window 'instant' -Source 'cim:root\SecurityCenter2 AntiVirusProduct'
        New-PcxMetric -Id 'security.firewall_enabled' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $firewallValue -Name 'anyEnabled') -Unit 'bool' -Domain 'security' -Window 'instant' -Source 'cim:MSFT_NetFirewallProfile'
        New-PcxMetric -Id 'security.tpm_ready' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $tpmValue -Name 'ready') -Unit 'bool' -Domain 'security' -Window 'instant' -Source 'cim:Win32_Tpm'
        New-PcxMetric -Id 'security.bitlocker_protected' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $bitLockerValue -Name 'anyProtected') -Unit 'bool' -Domain 'security' -Window 'instant' -Source 'cim:Win32_EncryptableVolume'
        New-PcxMetric -Id 'security.anticheat_present' -Group 'security' -Status 'measured' -Value (Get-PcxPolicyMember -Object $anticheatValue -Name 'present') -Unit 'bool' -Domain 'security' -Window 'instant' -Source 'cim:Win32_Service anticheat list'
    )
}
