<#
.SYNOPSIS
    Identity / build collector group.

.DESCRIPTION
    Reports the OS identity facts the tune table needs: product name, build,
    UBR and edition. Read-only. Returns one metric per fact, each with
    status measured|unavailable|unreliable. A failed probe is unavailable with
    value $null, never a guessed zero.

    Fixture mode (-Fixture) maps the already-validated environment fixture and
    performs no live probe.
#>

Set-StrictMode -Version 2.0

function Get-PcxCollectorIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Fixture)

    if ($null -ne $Fixture) {
        $environment = Get-PcxPolicyMember -Object $Fixture -Name 'environment'
        $os = Get-PcxPolicyMember -Object $environment -Name 'os'
        $source = 'fixture:environment.os'

        return @(
            New-PcxEnvironmentFieldMetric -Id 'identity.product_name' -Group 'identity' -Field (Get-PcxPolicyMember -Object $os -Name 'productName') -Unit 'string' -Domain 'identity' -Window 'instant' -Source $source
            New-PcxEnvironmentFieldMetric -Id 'identity.build' -Group 'identity' -Field (Get-PcxPolicyMember -Object $os -Name 'build') -Unit 'build' -Domain 'identity' -Window 'instant' -Source $source
            New-PcxEnvironmentFieldMetric -Id 'identity.ubr' -Group 'identity' -Field (Get-PcxPolicyMember -Object $os -Name 'ubr') -Unit 'number' -Domain 'identity' -Window 'instant' -Source $source
            New-PcxEnvironmentFieldMetric -Id 'identity.edition' -Group 'identity' -Field (Get-PcxPolicyMember -Object $os -Name 'edition') -Unit 'string' -Domain 'identity' -Window 'instant' -Source $source
        )
    }

    $osFields = Get-PcxEnvironmentOsFields
    $source = 'registry:HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    return @(
        New-PcxEnvironmentFieldMetric -Id 'identity.product_name' -Group 'identity' -Field $osFields.productName -Unit 'string' -Domain 'identity' -Window 'instant' -Source $source
        New-PcxEnvironmentFieldMetric -Id 'identity.build' -Group 'identity' -Field $osFields.build -Unit 'build' -Domain 'identity' -Window 'instant' -Source $source
        New-PcxEnvironmentFieldMetric -Id 'identity.ubr' -Group 'identity' -Field $osFields.ubr -Unit 'number' -Domain 'identity' -Window 'instant' -Source $source
        New-PcxEnvironmentFieldMetric -Id 'identity.edition' -Group 'identity' -Field $osFields.edition -Unit 'string' -Domain 'identity' -Window 'instant' -Source $source
    )
}
