<#
.SYNOPSIS
    Evidence engine and environment detection suite for todo 7.

.DESCRIPTION
    Proves the evidence decision order: a matching telemetry domain validates,
    state evidence needs a profile, an unrelated or undeclared domain refuses,
    a storage metric cannot justify a ux write, an agent-discovered target with
    state-only evidence refuses, a seed rule may use curated cross-domain
    evidence, unavailable values never become zero, self-citation refuses, and
    a managed fixture drives the policy refusal without any live device client.
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

    $pcxModule = Get-Module -Name 'Pcx'
    $script:Module = $pcxModule
    $script:TestEvidence = $pcxModule.ExportedCommands['Test-PcxEvidenceRef']
    $script:GetEnvironment = $pcxModule.ExportedCommands['Get-PcxEnvironment']
    $script:ToPolicyProfile = $pcxModule.ExportedCommands['ConvertTo-PcxPolicyProfile']
    $script:TestTarget = $pcxModule.ExportedCommands['Test-PcxTarget']

    $script:EvidenceSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxEvidence.ps1'
    $script:EnvironmentSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxEnvironment.ps1'
    $script:DomainConfigPath = Join-Path -Path $repoRoot -ChildPath 'config/evidence-domains.json'

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:ManagedFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'managed'
    $script:SModeFixture = Join-Path -Path $script:FixtureRoot -ChildPath 's-mode'

    $script:PreviousEnvironmentFixture = $env:PCX_ENVIRONMENT_FIXTURE

    $script:ExplorerAdvanced = 'reg:HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced::HideFileExt'
    $script:Hags = 'reg:HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers::HwSchMode'
    $script:ContentDelivery = 'reg:HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager::SubscribedContent-338388Enabled'

    function New-EvidenceTelemetry {
        param(
            [Parameter(Mandatory = $true)][string] $Domain,
            [Parameter(Mandatory = $false)][AllowNull()][object] $Value = 42,
            [Parameter(Mandatory = $false)][string] $Metric = 'metric.value',
            [Parameter(Mandatory = $false)][string] $Window = '7d',
            [Parameter(Mandatory = $false)][string] $Status = 'measured',
            [Parameter(Mandatory = $false)][hashtable] $Extra = @{}
        )

        $evidence = [ordered]@{
            kind   = 'telemetry'
            metric = $Metric
            value  = $Value
            domain = $Domain
            window = $Window
            status = $Status
        }

        foreach ($key in $Extra.Keys) {
            $evidence[$key] = $Extra[$key]
        }

        return $evidence
    }

    function New-EvidenceState {
        param(
            [Parameter(Mandatory = $false)][AllowNull()][object] $Value = 1,
            [Parameter(Mandatory = $false)][AllowNull()][object] $Profile = $null,
            [Parameter(Mandatory = $false)][string] $Status = 'measured',
            [Parameter(Mandatory = $false)][hashtable] $Extra = @{}
        )

        $evidence = [ordered]@{
            kind   = 'state'
            metric = 'state.value'
            value  = $Value
            status = $Status
        }

        if ($null -ne $Profile) {
            $evidence['profile'] = $Profile
        }

        foreach ($key in $Extra.Keys) {
            $evidence[$key] = $Extra[$key]
        }

        return $evidence
    }

    function New-HardwareProfile {
        return @{
            os  = @{ build = 22631; edition = 'Professional' }
            gpu = @{ controllers = @(@{ name = 'Test GPU'; driverVersion = '1.0' }) }
            hags = 2
        }
    }

    function Invoke-Evidence {
        param(
            [Parameter(Mandatory = $true)][object] $Target,
            [Parameter(Mandatory = $true)][object] $Evidence,
            [Parameter(Mandatory = $true)][string] $Origin,
            [Parameter(Mandatory = $false)][AllowNull()][object] $CatalogRule,
            [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
        )

        $arguments = @{
            Target   = $Target
            Evidence = $Evidence
            Origin   = $Origin
        }
        if ($null -ne $CatalogRule) { $arguments['CatalogRule'] = $CatalogRule }
        if ($null -ne $Profile) { $arguments['Profile'] = $Profile }

        return (& $script:TestEvidence @arguments)
    }
}

AfterAll {
    $env:PCX_ENVIRONMENT_FIXTURE = $script:PreviousEnvironmentFixture
}

Describe 'evidence gate surface' {

    It 'exports the evidence gate, environment detection and policy-profile bridge' {
        $null -eq $script:TestEvidence | Should -BeFalse
        $null -eq $script:GetEnvironment | Should -BeFalse
        $null -eq $script:ToPolicyProfile | Should -BeFalse
    }

    It 'returns a structured decision, not a bare boolean' {
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceTelemetry -Domain 'ux') -Origin 'agent-discovered'

        $result.PSObject.Properties.Name | Should -Contain 'allowed'
        $result.PSObject.Properties.Name | Should -Contain 'code'
        $result.PSObject.Properties.Name | Should -Contain 'reason'
        $result.PSObject.Properties.Name | Should -Contain 'domain'
    }

    It 'pins the domain map exactly' {
        $document = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:DomainConfigPath))

        $document.schema | Should -Be 'pcx-evidence-domains/1'
        $document.subsystems.svc | Should -Be 'services'
        $document.subsystems.task | Should -Be 'startup'

        $expected = @{
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'        = 'ux'
            'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'   = 'ads'
            'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'                  = 'performance'
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'                   = 'search'
            'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'          = 'ads'
            'HKCU\System\GameConfigStore'                                            = 'performance'
            'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'                  = 'performance'
        }

        foreach ($path in $expected.Keys) {
            $entry = @($document.targets | Where-Object { $_.path -eq $path })
            $entry.Count | Should -Be 1 -Because "the domain map must declare '$path'"
            $entry[0].domain | Should -Be $expected[$path]
        }

        $hags = @($document.targets | Where-Object { $_.path -eq 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' })[0]
        $hags.name | Should -Be 'HwSchMode'
    }
}

Describe 'telemetry evidence' {

    It 'validates a telemetry ref whose domain matches the target' {
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceTelemetry -Domain 'ux') -Origin 'agent-discovered'

        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-E-EVIDENCE-ALLOW'
        $result.domain | Should -Be 'ux'
    }

    It 'validates the HAGS value with a performance metric' {
        $result = Invoke-Evidence -Target $script:Hags -Evidence (New-EvidenceTelemetry -Domain 'performance' -Metric 'gpu.hags_mode') -Origin 'agent-discovered'

        $result.allowed | Should -BeTrue
        $result.domain | Should -Be 'performance'
    }

    It 'validates a service target with the services subsystem domain' {
        $result = Invoke-Evidence -Target 'svc:DiagTrack' -Evidence (New-EvidenceTelemetry -Domain 'services' -Metric 'service.cpu_ms') -Origin 'agent-discovered'

        $result.allowed | Should -BeTrue
        $result.domain | Should -Be 'services'
    }

    It 'validates a task target with the startup subsystem domain' {
        $result = Invoke-Evidence -Target 'task:\Pcx\MyTask' -Evidence (New-EvidenceTelemetry -Domain 'startup' -Metric 'task.boot_ms') -Origin 'agent-discovered'

        $result.allowed | Should -BeTrue
        $result.domain | Should -Be 'startup'
    }

    It 'refuses an unrelated domain with PCX-E-EVIDENCE-DOMAIN' {
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceTelemetry -Domain 'storage' -Metric 'storage.free_mb' -Value 120000) -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-DOMAIN'
    }

    It 'refuses a reg target in Explorer\Advanced justified by a storage metric' {
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceTelemetry -Domain 'storage' -Metric 'disk.free_mb' -Value 512000 -Window '30d') -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-DOMAIN'
    }

    It 'refuses an undeclared target mapping' {
        $target = 'reg:HKCU\Software\Microsoft\Windows\CurrentVersion\Run::Agent'
        $result = Invoke-Evidence -Target $target -Evidence (New-EvidenceTelemetry -Domain 'startup') -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-DOMAIN'
    }

    It 'refuses an unavailable metric instead of coercing it to zero' {
        $result = Invoke-Evidence -Target $script:Hags -Evidence (New-EvidenceTelemetry -Domain 'performance' -Status 'unavailable' -Value 0) -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-UNAVAILABLE'
    }

    It 'refuses an unreliable metric instead of coercing it to zero' {
        $result = Invoke-Evidence -Target $script:Hags -Evidence (New-EvidenceTelemetry -Domain 'performance' -Status 'unreliable' -Value 0) -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-UNAVAILABLE'
    }

    It 'refuses a missing telemetry value' {
        $result = Invoke-Evidence -Target $script:Hags -Evidence (New-EvidenceTelemetry -Domain 'performance' -Value $null) -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-UNAVAILABLE'
    }

    It 'refuses a mismatched telemetry value' {
        $evidence = New-EvidenceTelemetry -Domain 'performance' -Value 99 -Extra @{ expected = 42 }
        $result = Invoke-Evidence -Target $script:Hags -Evidence $evidence -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-UNAVAILABLE'
    }

    It 'refuses a non-numeric telemetry value' {
        $result = Invoke-Evidence -Target $script:Hags -Evidence (New-EvidenceTelemetry -Domain 'performance' -Value 'many') -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-UNAVAILABLE'
    }
}

Describe 'state evidence' {

    It 'validates a state ref with a profile under a seed rule' {
        $rule = @{ evidence_rule = @{ kind = 'state' } }
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceState -Value 1 -Profile (New-HardwareProfile)) -Origin 'seed' -CatalogRule $rule

        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-E-EVIDENCE-ALLOW'
    }

    It 'refuses an agent-supplied state value alone' {
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceState -Value 1) -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-STATE-ONLY'
    }

    It 'refuses state evidence without a profile even under a seed rule' {
        $rule = @{ evidence_rule = @{ kind = 'state' } }
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceState -Value 1) -Origin 'seed' -CatalogRule $rule

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-STATE-ONLY'
    }

    It 'refuses an agent-discovered B with state-only evidence even when a profile exists' {
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceState -Value 1 -Profile (New-HardwareProfile)) -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-STATE-ONLY'
    }

    It 'refuses a seed action with no catalog evidence_rule' {
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceState -Value 1 -Profile (New-HardwareProfile)) -Origin 'seed'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-RULE'
    }

    It 'refuses a seed rule whose kind does not match the evidence kind' {
        $rule = @{ evidence_rule = @{ kind = 'telemetry' } }
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence (New-EvidenceState -Value 1 -Profile (New-HardwareProfile)) -Origin 'seed' -CatalogRule $rule

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-RULE'
    }
}

Describe 'self citation' {

    It 'refuses evidence that cites the write target for an unrelated benefit' {
        $evidence = New-EvidenceTelemetry -Domain 'ads' -Metric 'ad.impressions' -Extra @{
            target  = $script:ExplorerAdvanced
            benefit = 'ads'
        }
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence $evidence -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-SELF'
    }

    It 'refuses evidence that cites the write target while measuring another domain' {
        $evidence = New-EvidenceTelemetry -Domain 'storage' -Metric 'disk.free_mb' -Extra @{ target = $script:ExplorerAdvanced }
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence $evidence -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-SELF'
    }

    It 'allows evidence that cites the same target in the same domain' {
        $evidence = New-EvidenceTelemetry -Domain 'ux' -Metric 'shell.menu_ms' -Extra @{ target = $script:ExplorerAdvanced; benefit = 'ux' }
        $result = Invoke-Evidence -Target $script:ExplorerAdvanced -Evidence $evidence -Origin 'agent-discovered'

        $result.allowed | Should -BeTrue
    }
}

Describe 'seed catalog rules' {

    It 'validates a seed action with an intent/printers evidence_rule across domains' {
        $rule = @{ evidence_rule = @{ kind = 'telemetry'; domains = @('intent', 'printers') } }
        $evidence = New-EvidenceTelemetry -Domain 'printers' -Metric 'printers.count' -Value 3 -Window '30d'
        $result = Invoke-Evidence -Target $script:ContentDelivery -Evidence $evidence -Origin 'seed' -CatalogRule $rule

        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-E-EVIDENCE-ALLOW'
        $result.domain | Should -Be 'printers'
    }

    It 'refuses a seed rule metric mismatch' {
        $rule = @{ evidence_rule = @{ kind = 'telemetry'; metric = 'printers.count' } }
        $evidence = New-EvidenceTelemetry -Domain 'intent' -Metric 'intent.userassist_runs' -Value 3
        $result = Invoke-Evidence -Target $script:ContentDelivery -Evidence $evidence -Origin 'seed' -CatalogRule $rule

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-RULE'
    }

    It 'refuses a seed rule domain outside the allowed set' {
        $rule = @{ evidence_rule = @{ kind = 'telemetry'; domains = @('intent', 'printers') } }
        $evidence = New-EvidenceTelemetry -Domain 'storage' -Metric 'disk.free_mb' -Value 10
        $result = Invoke-Evidence -Target $script:ContentDelivery -Evidence $evidence -Origin 'seed' -CatalogRule $rule

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-DOMAIN'
    }

    It 'refuses a seed telemetry ref with no catalog rule' {
        $result = Invoke-Evidence -Target $script:ContentDelivery -Evidence (New-EvidenceTelemetry -Domain 'ads') -Origin 'seed'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-RULE'
    }
}

Describe 'file evidence root' {

    It 'validates an A1 target with a metric rooted at the same path' {
        $target = 'file:C:\Windows\SoftwareDistribution\Download'
        $evidence = New-EvidenceTelemetry -Domain 'storage' -Metric 'dir.bytes' -Value 1024 -Extra @{ root = 'C:\Windows\SoftwareDistribution\Download' }
        $result = Invoke-Evidence -Target $target -Evidence $evidence -Origin 'agent-discovered'

        $result.allowed | Should -BeTrue
    }

    It 'refuses a metric rooted somewhere else' {
        $target = 'file:C:\Windows\SoftwareDistribution\Download'
        $evidence = New-EvidenceTelemetry -Domain 'storage' -Metric 'dir.bytes' -Value 1024 -Extra @{ root = 'C:\Windows\Temp' }
        $result = Invoke-Evidence -Target $target -Evidence $evidence -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-ROOT'
    }

    It 'refuses file evidence with no root' {
        $target = 'file:C:\Windows\SoftwareDistribution\Download'
        $result = Invoke-Evidence -Target $target -Evidence (New-EvidenceTelemetry -Domain 'storage') -Origin 'agent-discovered'

        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-E-EVIDENCE-ROOT'
    }
}

Describe 'environment fixtures' {

    It 'loads all three complete machine profiles by path' {
        $fixtures = @{
            desktop = $script:DesktopFixture
            managed = $script:ManagedFixture
            's-mode' = $script:SModeFixture
        }
        $fields = @('managed', 'sMode', 'vbs', 'hvci', 'bitLocker', 'defender', 'firewall', 'tpm', 'anticheat', 'devDrive', 'printers', 'memory', 'gpu', 'hags', 'gameDvr', 'powerPlan')

        foreach ($name in $fixtures.Keys) {
            $environment = & $script:GetEnvironment -FixturePath $fixtures[$name]

            $environment.schema | Should -Be 'pcx-environment/1' -Because "$name fixture"
            foreach ($field in $fields) {
                ($environment.$field).status | Should -Be 'measured' -Because "$name.$field must be a measured profile fact"
            }
            foreach ($osField in @('productName', 'build', 'ubr', 'edition')) {
                ($environment.os.$osField).status | Should -Be 'measured' -Because "$name.os.$osField"
            }
        }
    }

    It 'turns the desktop fixture into an allowing policy profile' {
        $environment = & $script:GetEnvironment -FixturePath $script:DesktopFixture
        $profile = & $script:ToPolicyProfile $environment

        $profile.managed | Should -BeFalse
        $profile.sMode | Should -BeFalse
        $profile.devDrive | Should -BeFalse
        $profile.anticheat | Should -BeFalse
        $profile.environment['SYSTEMROOT'] | Should -Be 'C:\Windows'

        $result = & $script:TestTarget -Target $script:Hags -Profile $profile
        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-POLICY-ALLOW'
    }

    It 'drives Test-PcxTarget to refuse from the managed fixture without a live device client' {
        $environment = & $script:GetEnvironment -FixturePath $script:ManagedFixture
        $profile = & $script:ToPolicyProfile $environment

        $profile.managed | Should -BeTrue

        $targets = @(
            $script:Hags
            @{ Kind = 'service'; Name = 'DiagTrack'; Start = 4 }
            @{ Kind = 'task'; Path = '\Pcx\MyTask'; Enabled = $false }
            'file:C:\Windows\SoftwareDistribution\Download'
        )

        foreach ($target in $targets) {
            $result = & $script:TestTarget -Target $target -Profile $profile
            $result.allowed | Should -BeFalse -Because 'a managed machine refuses every write'
            $result.code | Should -Be 'PCX-POLICY-MANAGED'
        }

        [System.IO.File]::ReadAllText($script:EnvironmentSourcePath) | Should -Not -Match 'dsregcmd'
    }

    It 'drives the S Mode refusal from the s-mode fixture' {
        $environment = & $script:GetEnvironment -FixturePath $script:SModeFixture
        $profile = & $script:ToPolicyProfile $environment

        $profile.sMode | Should -BeTrue

        $result = & $script:TestTarget -Target $script:Hags -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-SMODE'
    }

    It 'prefers -FixturePath over the environment variable' {
        $saved = $env:PCX_ENVIRONMENT_FIXTURE
        try {
            $env:PCX_ENVIRONMENT_FIXTURE = $script:SModeFixture
            $environment = & $script:GetEnvironment -FixturePath $script:DesktopFixture
            $profile = & $script:ToPolicyProfile $environment

            $profile.managed | Should -BeFalse
            $profile.sMode | Should -BeFalse
        }
        finally {
            $env:PCX_ENVIRONMENT_FIXTURE = $saved
        }
    }

    It 'refuses fixture mode without a fixture path instead of reading the live OS' {
        $saved = $env:PCX_ENVIRONMENT_FIXTURE
        try {
            $env:PCX_ENVIRONMENT_FIXTURE = $null
            { & $script:GetEnvironment } | Should -Throw '*PCX-E-ENVIRONMENT-FIXTURE*'
        }
        finally {
            $env:PCX_ENVIRONMENT_FIXTURE = $saved
        }
    }

    It 'treats a non-measured fact as unknown instead of true or false' {
        $environment = [pscustomobject]@{
            managed      = [pscustomobject]@{ value = $true; status = 'unavailable' }
            sMode        = [pscustomobject]@{ value = $false; status = 'measured' }
            devDrive     = [pscustomobject]@{ value = $false; status = 'measured' }
            anticheat    = [pscustomobject]@{ value = $false; status = 'measured' }
            paths        = [pscustomobject]@{ SYSTEMROOT = 'C:\Windows' }
        }

        $profile = & $script:ToPolicyProfile $environment

        $profile.managed | Should -BeNullOrEmpty
        $profile.sMode | Should -BeFalse
        $profile.environment['SYSTEMROOT'] | Should -Be 'C:\Windows'
    }
}

Describe 'environment detection source' {

    BeforeAll {
        $script:EnvironmentSource = [System.IO.File]::ReadAllText($script:EnvironmentSourcePath)
        $script:EvidenceSource = [System.IO.File]::ReadAllText($script:EvidenceSourcePath)
    }

    It 'never uses a live device-registration client or an inventory-only command' {
        $script:EnvironmentSource | Should -Not -Match 'dsregcmd'
        $script:EnvironmentSource | Should -Not -Match 'Win32_Product'
        $script:EnvironmentSource | Should -Not -Match 'Get-WindowsCapability'
    }

    It 'never writes or evaluates a command in the environment detector' {
        $banned = @(
            'Set-ItemProperty'
            'New-ItemProperty'
            'Remove-ItemProperty'
            'New-Item'
            'Remove-Item'
            'Set-Service'
            'Enable-ScheduledTask'
            'Disable-ScheduledTask'
            'Invoke-Expression'
        )

        foreach ($token in $banned) {
            $script:EnvironmentSource | Should -Not -Match ([regex]::Escape($token)) -Because "PcxEnvironment.ps1 must not use '$token'"
        }
    }

    It 'reads machine state only through read-only probes' {
        $script:EnvironmentSource | Should -Match ([regex]::Escape('Get-CimInstance'))
        $script:EnvironmentSource | Should -Match ([regex]::Escape('Get-ItemProperty'))
        $script:EnvironmentSource | Should -Match ([regex]::Escape('Test-Path'))
    }
}

Describe 'evidence purity' {

    BeforeAll {
        $script:EvidenceSource = [System.IO.File]::ReadAllText($script:EvidenceSourcePath)
        $script:bannedEvidenceTokens = @(
            'Get-Item'
            'Get-ItemProperty'
            'Get-ChildItem'
            'Get-Service'
            'Get-ScheduledTask'
            'Get-Process'
            'Get-WinEvent'
            'Get-CimInstance'
            'Get-ComputerInfo'
            'Test-Path'
            'Microsoft.Win32.Registry'
            '[System.IO.File]'
            '[System.IO.Directory]'
            '[Environment]::GetEnvironmentVariable'
            'Set-ItemProperty'
            'New-ItemProperty'
            'Remove-ItemProperty'
            'New-Item'
            'Remove-Item'
            'Set-Service'
            'Invoke-Expression'
            'Invoke-PcxPlatformRead'
            'Invoke-PcxPlatformWrite'
            'Invoke-PcxPlatformDelete'
            'Invoke-PcxPlatformMove'
            'reg.exe'
            'sc.exe'
            'schtasks.exe'
            'cmd /c'
            'dsregcmd'
        )
    }

    It 'contains no machine-state read, platform call or shell' {
        foreach ($token in $script:bannedEvidenceTokens) {
            $script:EvidenceSource | Should -Not -Match ([regex]::Escape($token)) -Because "PcxEvidence.ps1 must not use '$token'"
        }
    }

    It 'reads only the bundled domain data through Read-PcxJson' {
        $script:EvidenceSource | Should -Match ([regex]::Escape('Read-PcxJson'))
        $script:EvidenceSource | Should -Match ([regex]::Escape('evidence-domains.json'))
    }

    It 'proves the scanner would catch a banned call' {
        $sample = 'x' + 'Get-CimInstance' + 'y'
        $sample | Should -Match ([regex]::Escape('Get-CimInstance'))
    }
}
