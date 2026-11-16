<#
.SYNOPSIS
    Environment detection suite: managed enrollment and anticheat activity.

.DESCRIPTION
    Guards the two measured false positives on a real Windows 11 22631 machine:

      * 30 Enrollments\<guid> keys with an empty ProviderID plus a
        PolicyManager\current\device key were read as "managed";
      * an installed but Stopped/Manual BEService was read as an anticheat
        session.

    A GUID enrollment counts only with a non-empty non-bridge ProviderID and
    EnrollmentState 1; an OMA-DM account with a UPN is the second signal.
    Anticheat.present means a known service or kernel driver that is Running,
    while installed keeps the idle client visible. Policy still refuses every
    write when either verdict is true, and an idle client does not block.

    Every case is a synthetic raw-row fixture fed to the real field functions
    through their test seams, so no live registry or CIM read happens here.
#>

BeforeAll {
    if ($env:PCX_TEST_RUN -ne '1') {
        throw "PCX_TEST_RUN must be '1' before the suite starts. Run tests through tests/run.ps1."
    }

    $env:PCX_TEST_RUN = '1'

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../../')).Path
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Pcx.psm1'
    $testAdapterPath = Join-Path -Path $repoRoot -ChildPath 'tests/TestAdapter/PcxPlatform.Test.ps1'

    $env:PCX_PLATFORM_MODULE = (Resolve-Path -LiteralPath $testAdapterPath).Path
    $env:PCX_ALLOW_REAL_WRITES = $null

    Import-Module -Name $modulePath -Force

    $script:Module = Get-Module -Name 'Pcx'
    $script:ToPolicyProfile = $script:Module.ExportedCommands['ConvertTo-PcxPolicyProfile']
    $script:TestTarget = $script:Module.ExportedCommands['Test-PcxTarget']
    $script:EnvironmentSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxEnvironment.ps1'

    $script:PolicyManagerMarker = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'
    $script:Hags = 'reg:HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers::HwSchMode'
    $script:AllTargets = @(
        $script:Hags
        @{ Kind = 'service'; Name = 'DiagTrack'; Start = 4 }
        @{ Kind = 'task'; Path = '\Pcx\MyTask'; Enabled = $false }
        'file:C:\Windows\SoftwareDistribution\Download'
    )

    function New-EnrollmentRow {
        param(
            [Parameter(Mandatory = $true)][string] $Id,
            [Parameter(Mandatory = $false)][string] $ProviderId = '',
            [Parameter(Mandatory = $false)][AllowNull()][object] $EnrollmentState = 1
        )

        return [pscustomobject]@{ id = $Id; providerId = $ProviderId; enrollmentState = $EnrollmentState }
    }

    function New-OmadmRow {
        param(
            [Parameter(Mandatory = $true)][string] $Id,
            [Parameter(Mandatory = $false)][string] $Upn = ''
        )

        return [pscustomobject]@{ id = $Id; upn = $Upn }
    }

    function New-AnticheatRow {
        param(
            [Parameter(Mandatory = $true)][string] $Name,
            [Parameter(Mandatory = $true)][string] $State,
            [Parameter(Mandatory = $false)][string] $StartMode = 'Manual'
        )

        return [pscustomobject]@{ name = $Name; state = $State; startMode = $StartMode }
    }

    function Get-ManagedField {
        # Passes the raw rows through the real field function in module scope.
        param(
            [Parameter(Mandatory = $false)][AllowNull()][object[]] $Enrollments = @(),
            [Parameter(Mandatory = $false)][AllowNull()][object[]] $OmadmAccounts = @(),
            [Parameter(Mandatory = $false)][AllowNull()][string[]] $Markers = @()
        )

        return & $script:Module {
            param($Fixture)
            Get-PcxEnvironmentManagedField -Enrollments $Fixture.Enrollments -OmadmAccounts $Fixture.OmadmAccounts -Markers $Fixture.Markers
        } ([pscustomobject]@{ Enrollments = $Enrollments; OmadmAccounts = $OmadmAccounts; Markers = $Markers })
    }

    function Get-AnticheatField {
        param([Parameter(Mandatory = $false)][AllowNull()][object[]] $Services = @())

        return & $script:Module {
            param($Fixture)
            Get-PcxEnvironmentAnticheatField -Services $Fixture.Services
        } ([pscustomobject]@{ Services = $Services })
    }

    function New-EnvironmentObject {
        # The two verdicts plus the facts the policy needs to allow a desktop.
        param(
            [Parameter(Mandatory = $true)][object] $Managed,
            [Parameter(Mandatory = $true)][object] $Anticheat
        )

        $measuredFalse = [pscustomobject]@{ value = $false; status = 'measured' }

        return [pscustomobject]@{
            managed   = $Managed
            sMode     = $measuredFalse
            devDrive  = $measuredFalse
            anticheat = $Anticheat
            paths     = [pscustomobject]@{
                LOCALAPPDATA = 'C:\Users\tester\AppData\Local'
                APPDATA      = 'C:\Users\tester\AppData\Roaming'
                PROGRAMDATA  = 'C:\ProgramData'
                SYSTEMROOT   = 'C:\Windows'
            }
        }
    }
}

Describe 'managed enrollment detection' {

    It 'is not managed from empty-provider enrollments plus PolicyManager' {
        # Exactly the real machine: every EnrollmentState is 1, every
        # ProviderID is empty, PolicyManager exists.
        $enrollments = @(
            (New-EnrollmentRow -Id '18DCFFD4-37D6-4BC6-87E0-4266FDBB8E49')
            (New-EnrollmentRow -Id '1E05DD5D-A022-46C5-963C-B20DE341170F')
            (New-EnrollmentRow -Id 'FC01E91F-914C-45AF-9D7C-0B2E5FBEDF62')
        )
        $markers = @(
            'HKLM:\SOFTWARE\Microsoft\Enrollments'
            'HKLM:\SOFTWARE\Microsoft\Enrollments\18DCFFD4-37D6-4BC6-87E0-4266FDBB8E49'
            'HKLM:\SOFTWARE\Microsoft\Enrollments\1E05DD5D-A022-46C5-963C-B20DE341170F'
            'HKLM:\SOFTWARE\Microsoft\Enrollments\FC01E91F-914C-45AF-9D7C-0B2E5FBEDF62'
            $script:PolicyManagerMarker
        )

        $field = Get-ManagedField -Enrollments $enrollments -Markers $markers

        $field.status | Should -Be 'measured'
        $field.value | Should -BeFalse -Because 'an empty ProviderID is not an MDM enrollment'
        $field.reason | Should -Match 'not managed'
        $field.reason | Should -Match 'PolicyManager'
        # Raw markers stay visible for transparency.
        $field.markers | Should -Contain $script:PolicyManagerMarker
        $field.markers | Should -Contain 'HKLM:\SOFTWARE\Microsoft\Enrollments\18DCFFD4-37D6-4BC6-87E0-4266FDBB8E49'
        $field.enrollments.Count | Should -Be 3
    }

    It 'is managed from a real provider enrollment' {
        $field = Get-ManagedField -Enrollments @(New-EnrollmentRow -Id 'B0B9123D-7D7F-4C6B-9973-CECED46F2A09' -ProviderId 'MS DM Server')

        $field.value | Should -BeTrue
        $field.reason | Should -Match 'managed:'
        $field.reason | Should -Match 'MS DM Server'
        $field.signals.Count | Should -Be 1
    }

    It 'is not managed from a WMI bridge leftover' {
        $field = Get-ManagedField -Enrollments @(New-EnrollmentRow -Id 'B03927B0-4DAE-4531-B0C1-A6B85901A286' -ProviderId 'WMI_Bridge_SCCM_Server')

        $field.value | Should -BeFalse -Because 'an SCCM WMI bridge is not an MDM enrollment'
        $field.reason | Should -Match 'not managed'
        $field.signals.Count | Should -Be 0
    }

    It 'requires an enrolled state even when a provider is present' {
        $field = Get-ManagedField -Enrollments @(New-EnrollmentRow -Id 'AAAAAAAA-0000-0000-0000-000000000001' -ProviderId 'MS DM Server' -EnrollmentState 0)

        $field.value | Should -BeFalse
        $field.reason | Should -Match 'not managed'
    }

    It 'is managed from an OMA-DM account with a UPN and keeps the UPN out of the reason' {
        $field = Get-ManagedField -OmadmAccounts @(New-OmadmRow -Id 'BBBBBBBB-0000-0000-0000-000000000001' -Upn 'user@contoso.example')

        $field.value | Should -BeTrue
        $field.reason | Should -Match 'UPN'
        $field.reason | Should -Not -Match 'contoso'
    }

    It 'is not managed from an OMA-DM account with an empty UPN' {
        $field = Get-ManagedField -OmadmAccounts @(New-OmadmRow -Id 'BBBBBBBB-0000-0000-0000-000000000002')

        $field.value | Should -BeFalse
    }
}

Describe 'anticheat activity detection' {

    It 'reports an installed but Stopped BEService as idle, not present' {
        $field = Get-AnticheatField -Services @(New-AnticheatRow -Name 'BEService' -State 'Stopped' -StartMode 'Manual')

        $field.status | Should -Be 'measured'
        $field.value.present | Should -BeFalse -Because 'an installed service is not a running session'
        $field.value.detected.Count | Should -Be 0
        $field.value.installed | Should -Contain 'BEService'
        $field.value.reason | Should -Match 'Stopped'
    }

    It 'reports a Running BEService as present' {
        $field = Get-AnticheatField -Services @(New-AnticheatRow -Name 'BEService' -State 'Running' -StartMode 'Manual')

        $field.value.present | Should -BeTrue
        $field.value.detected | Should -Contain 'BEService'
        $field.value.installed | Should -Contain 'BEService'
        $field.value.reason | Should -Match 'Running'
    }

    It 'reports a Running anticheat kernel driver as present' {
        $field = Get-AnticheatField -Services @(New-AnticheatRow -Name 'BEDaisy' -State 'Running' -StartMode 'Manual')

        $field.value.present | Should -BeTrue
        $field.value.detected | Should -Contain 'BEDaisy'
    }

    It 'ignores an unknown service and an empty fixture' {
        $field = Get-AnticheatField -Services @(New-AnticheatRow -Name 'Spooler' -State 'Running')
        $field.value.present | Should -BeFalse
        $field.value.installed.Count | Should -Be 0

        $empty = Get-AnticheatField -Services @()
        $empty.value.present | Should -BeFalse
        $empty.value.installed.Count | Should -Be 0
        $empty.value.reason | Should -Match 'no known anticheat'
    }
}

Describe 'policy keeps refusing active detections' {

    It 'refuses every target kind while managed' {
        $managed = Get-ManagedField -Enrollments @(New-EnrollmentRow -Id 'B0B9123D-7D7F-4C6B-9973-CECED46F2A09' -ProviderId 'MS DM Server')
        $idle = Get-AnticheatField -Services @(New-AnticheatRow -Name 'BEService' -State 'Stopped')

        $profile = & $script:ToPolicyProfile -Environment (New-EnvironmentObject -Managed $managed -Anticheat $idle)
        $profile.managed | Should -BeTrue

        foreach ($target in $script:AllTargets) {
            $result = & $script:TestTarget -Target $target -Profile $profile
            $result.allowed | Should -BeFalse -Because 'a managed machine refuses every write'
            $result.code | Should -Be 'PCX-POLICY-MANAGED'
        }
    }

    It 'refuses every target kind while an anticheat session is active' {
        $notManaged = Get-ManagedField -Enrollments @(New-EnrollmentRow -Id '18DCFFD4-37D6-4BC6-87E0-4266FDBB8E49')
        $active = Get-AnticheatField -Services @(New-AnticheatRow -Name 'BEService' -State 'Running')

        $profile = & $script:ToPolicyProfile -Environment (New-EnvironmentObject -Managed $notManaged -Anticheat $active)
        $profile.anticheat | Should -BeTrue

        foreach ($target in $script:AllTargets) {
            $result = & $script:TestTarget -Target $target -Profile $profile
            $result.allowed | Should -BeFalse
            $result.code | Should -Be 'PCX-POLICY-ANTICHEAT'
        }
    }

    It 'allows a desktop write when the anticheat client is only installed' {
        $notManaged = Get-ManagedField -Enrollments @(New-EnrollmentRow -Id '18DCFFD4-37D6-4BC6-87E0-4266FDBB8E49')
        $idle = Get-AnticheatField -Services @(New-AnticheatRow -Name 'BEService' -State 'Stopped')

        $profile = & $script:ToPolicyProfile -Environment (New-EnvironmentObject -Managed $notManaged -Anticheat $idle)
        $profile.managed | Should -BeFalse
        $profile.anticheat | Should -BeFalse

        $result = & $script:TestTarget -Target $script:Hags -Profile $profile
        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-POLICY-ALLOW'
    }
}

Describe 'VBS policy three-state detection' {

    It 'reports measured off when the value is absent on an existing key' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            throw [System.ArgumentException]::new('Property EnableVirtualizationBasedSecurity does not exist at path HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard.')
        } -ParameterFilter { $null -ne $Name }
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ RequirePlatformSecurityFeatures = 1 }
        } -ParameterFilter { $null -eq $Name }

        $field = & $script:Module { Get-PcxEnvironmentVbsField }

        $field.status | Should -Be 'measured'
        $field.value | Should -BeFalse
    }

    It 'reports unavailable when the key is absent' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            throw [System.IO.DirectoryNotFoundException]::new('Cannot find path HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard because it does not exist.')
        }

        $field = & $script:Module { Get-PcxEnvironmentVbsField }

        $field.status | Should -Be 'unavailable'
        ($null -eq $field.value) | Should -BeTrue
        $field.reason | Should -Match 'could not be read'
    }

    It 'reports unavailable, never off, when the read throws access-denied' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            throw [System.UnauthorizedAccessException]::new('Access to the registry key is denied.')
        }

        $field = & $script:Module { Get-PcxEnvironmentVbsField }

        $field.status | Should -Be 'unavailable'
        ($null -eq $field.value) | Should -BeTrue
        $field.reason | Should -Match '[Dd]enied'
    }

    It 'maps a present value of 1 to on' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ EnableVirtualizationBasedSecurity = 1 }
        }

        $field = & $script:Module { Get-PcxEnvironmentVbsField }

        $field.status | Should -Be 'measured'
        $field.value | Should -BeTrue
    }

    It 'maps a present value of 0 to off' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ EnableVirtualizationBasedSecurity = 0 }
        }

        $field = & $script:Module { Get-PcxEnvironmentVbsField }

        $field.status | Should -Be 'measured'
        $field.value | Should -BeFalse
    }
}

Describe 'HAGS three-state detection' {

    It 'reports HwSchMode=2 as measured on' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ HwSchMode = 2 }
        }

        $field = & $script:Module { Get-PcxEnvironmentHagsField }

        $field.status | Should -Be 'measured'
        $field.value | Should -Be 2
    }

    It 'reports HwSchMode=1 as measured off' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ HwSchMode = 1 }
        }

        $field = & $script:Module { Get-PcxEnvironmentHagsField }

        $field.status | Should -Be 'measured'
        $field.value | Should -Be 1
    }

    It 'reports measured off when the value is absent on an existing key' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            throw [System.ArgumentException]::new('Property HwSchMode does not exist at path HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers.')
        } -ParameterFilter { $null -ne $Name }
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ SomeOtherValue = 1 }
        } -ParameterFilter { $null -eq $Name }

        $field = & $script:Module { Get-PcxEnvironmentHagsField }

        $field.status | Should -Be 'measured'
        $field.value | Should -Be 1
    }

    It 'reports unavailable when the key is absent' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            throw [System.IO.DirectoryNotFoundException]::new('Cannot find path HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers because it does not exist.')
        }

        $field = & $script:Module { Get-PcxEnvironmentHagsField }

        $field.status | Should -Be 'unavailable'
        ($null -eq $field.value) | Should -BeTrue
        $field.reason | Should -Match 'could not be read'
    }

    It 'reports unavailable, never off, when the read throws access-denied' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            throw [System.UnauthorizedAccessException]::new('Access to the registry key is denied.')
        }

        $field = & $script:Module { Get-PcxEnvironmentHagsField }

        $field.status | Should -Be 'unavailable'
        ($null -eq $field.value) | Should -BeTrue
        $field.reason | Should -Match '[Dd]enied'
    }
}

Describe 'HVCI policy detection' {

    It 'maps a present value of 1 to on' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ Enabled = 1 }
        }

        $field = & $script:Module { Get-PcxEnvironmentHvciField }

        $field.status | Should -Be 'measured'
        $field.value | Should -BeTrue
    }

    It 'reports measured off when the value is absent on an existing key' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            throw [System.ArgumentException]::new('Property Enabled does not exist.')
        } -ParameterFilter { $null -ne $Name }
        Mock -ModuleName 'Pcx' -CommandName 'Get-ItemProperty' -MockWith {
            [pscustomobject]@{ SomeOtherValue = 1 }
        } -ParameterFilter { $null -eq $Name }

        $field = & $script:Module { Get-PcxEnvironmentHvciField }

        $field.status | Should -Be 'measured'
        $field.value | Should -BeFalse
    }
}

Describe 'printer counting' {

    It 'counts two printers as measured 2' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-CimInstance' -MockWith {
            return @(
                [pscustomobject]@{ Name = 'Contoso Printer'; Default = $true }
                [pscustomobject]@{ Name = 'Fabrikam Printer'; Default = $false }
            )
        }

        $field = & $script:Module { Get-PcxEnvironmentPrintersField }

        $field.status | Should -Be 'measured'
        $field.value | Should -Be 2
    }

    It 'reports a real zero as measured 0' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-CimInstance' -MockWith {
            return @()
        }

        $field = & $script:Module { Get-PcxEnvironmentPrintersField }

        $field.status | Should -Be 'measured'
        $field.value | Should -Be 0
    }

    It 'reports a null probe result as unavailable' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-CimInstance' -MockWith {
            return , $null
        }

        $field = & $script:Module { Get-PcxEnvironmentPrintersField }

        $field.status | Should -Be 'unavailable'
        ($null -eq $field.value) | Should -BeTrue
        $field.reason | Should -Not -BeNullOrEmpty
    }

    It 'reports a failed probe as unavailable' {
        Mock -ModuleName 'Pcx' -CommandName 'Get-CimInstance' -MockWith {
            throw [System.Exception]::new('The RPC server is unavailable.')
        }

        $field = & $script:Module { Invoke-PcxEnvironmentProbe -Label 'printers' -Probe { Get-PcxEnvironmentPrintersField } }

        $field.status | Should -Be 'unavailable'
        ($null -eq $field.value) | Should -BeTrue
        $field.reason | Should -Match 'printers'
    }
}

Describe 'detector source stays read-only' {

    BeforeAll {
        $script:Source = [System.IO.File]::ReadAllText($script:EnvironmentSourcePath)
    }

    It 'never runs a device-registration client or an installer' {
        $script:Source | Should -Not -Match 'dsregcmd'
        $script:Source | Should -Not -Match 'Win32_Product'
    }

    It 'never writes and never evaluates a command' {
        foreach ($token in @(
                'Set-ItemProperty'
                'New-ItemProperty'
                'Remove-ItemProperty'
                'New-Item'
                'Remove-Item'
                'Set-Service'
                'Invoke-Expression'
            )) {
            $script:Source | Should -Not -Match ([regex]::Escape($token)) -Because "PcxEnvironment.ps1 must not use '$token'"
        }
    }

    It 'keeps PolicyManager as a marker and not as a managed signal' {
        $script:Source | Should -Match 'PolicyManager'
        $script:Source | Should -Not -Match '\$managed\s*=\s*\(?\$markers'
    }
}
