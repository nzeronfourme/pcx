<#
.SYNOPSIS
    Deep-discovery eval and novel-target E2E (optimize-v0.1-discovery todo 9).

.DESCRIPTION
    Proves DV-7 end to end without any live-OS read and without an LLM loop;
    the agent side is scripted probe calls and scripted proposals against
    fixtures, and every assertion is on a typed call or a finding payload,
    never on free-form prose:

      1. The deep-discovery fixture holds one machine fact (sustained
         total-CPU saturation) that no fixed finding id covers. The eval
         issues exactly one typed counter probe for it, asserts the measured
         payload equals the fixture value, and asserts the fact lands as an
         extension:cpu-saturation finding whose evidence payload equals the
         same measured values.
      2. An agent-proposed task target outside the seed catalog is decided by
         Test-PcxTarget with a typed code: an ordinary disable-only target is
         allowed with PCX-POLICY-ALLOW, and a system task target is denied
         with PCX-POLICY-TASK-SYSTEM.

    Fixture adapter only: PCX_TEST_RUN stays set, the run refuses the real
    adapter, and nothing writes to the live OS. This file stays ASCII and
    reads identically on PowerShell 5.1 and 7.
#>

BeforeAll {
    if ($env:PCX_TEST_RUN -ne '1') {
        throw "PCX_TEST_RUN must be '1' before the suite starts. Run tests through tests/run.ps1."
    }

    $env:PCX_TEST_RUN = '1'

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../')).Path
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Pcx.psm1'
    $testAdapterPath = Join-Path -Path $repoRoot -ChildPath 'tests/TestAdapter/PcxPlatform.Test.ps1'

    $env:PCX_PLATFORM_MODULE = (Resolve-Path -LiteralPath $testAdapterPath).Path
    $env:PCX_ALLOW_REAL_WRITES = $null

    Import-Module -Name $modulePath -Force

    $script:Module = Get-Module -Name 'Pcx'
    $script:Probe = $script:Module.ExportedCommands['Invoke-PcxProbe']
    $script:NewFinding = $script:Module.ExportedCommands['New-PcxFinding']
    $script:NewReport = $script:Module.ExportedCommands['New-PcxDiagnosticsReport']
    $script:TestMap = $script:Module.ExportedCommands['Test-PcxFindingGroupMap']
    $script:ToDocument = $script:Module.ExportedCommands['ConvertTo-PcxFindingsDocument']
    $script:GetSections = $script:Module.ExportedCommands['Get-PcxSections']
    $script:GetCatalog = $script:Module.ExportedCommands['Get-PcxCatalog']
    $script:TestTarget = $script:Module.ExportedCommands['Test-PcxTarget']
    $script:ConvertPolicyProfile = $script:Module.ExportedCommands['ConvertTo-PcxPolicyProfile']
    $script:ReadJson = $script:Module.ExportedCommands['Read-PcxJson']

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:DeepFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'deep-discovery'

    function Get-DeepDiscoveryFixedIds {
        # Every fixed finding id the 13 builders can emit on the desktop
        # fixture. Builder names follow Get-<Section>Findings; sections come
        # from the registry so a 14th section would fail closed here too.
        $environment = & $script:ReadJson -Path (Join-Path -Path $script:DesktopFixture -ChildPath 'machine.json')
        $scan = & $script:ReadJson -Path (Join-Path -Path $script:DesktopFixture -ChildPath 'state.json')

        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($section in @(& $script:GetSections)) {
            $name = 'Get-' + $section.Substring(0, 1).ToUpperInvariant() + $section.Substring(1) + 'Findings'
            $command = $script:Module.ExportedCommands[$name]
            if ($null -eq $command) { throw "builder '$name' is not exported." }
            foreach ($finding in @(& $command -Environment $environment -Scan $scan)) {
                if ($null -eq $finding) { continue }
                [void]$ids.Add([string]$finding.id)
            }
        }

        return , @($ids | Sort-Object -Unique)
    }
}

Describe 'deep-discovery eval: probe call and extension finding' {

    BeforeAll {
        # The scripted agent side: exactly one typed probe call against the
        # deep-discovery fixture, the way SKILL.md tells the agent to ask the
        # machine for typed evidence.
        $script:DeepProbe = & $script:Probe -Probe 'counter:\Processor(_Total)\% Processor Time' -FixturePath $script:DeepFixture

        $script:DeepEvidence = [ordered]@{
            metric = 'cpu.processor_time_percent'
            value  = $script:DeepProbe.value
            status = 'measured'
            domain = 'cpu'
            window = 'instant'
            source = [string]$script:DeepProbe.source
        }

        $script:DeepFinding = & $script:NewFinding -Section 'extension:cpu-saturation' -Id 'cpu-saturation' -Severity 'warn' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence $script:DeepEvidence

        $script:DeepFixedIds = Get-DeepDiscoveryFixedIds
    }

    It 'issues one typed counter probe and measures the fixture value' {
        [string]$script:DeepProbe.family | Should -BeExactly 'counter'
        [string]$script:DeepProbe.status | Should -BeExactly 'measured'
        [double]$script:DeepProbe.value | Should -Be 87.25
        [string]$script:DeepProbe.source | Should -Match 'PdhAddEnglishCounter'
        ($null -eq $script:DeepProbe.value) | Should -BeFalse
    }

    It 'covers a machine fact no fixed finding id reaches' {
        @($script:DeepFixedIds).Count | Should -BeGreaterThan 0
        @($script:DeepFixedIds | Where-Object { $_ -ceq 'cpu-saturation' }).Count | Should -Be 0 `
            -Because 'sustained total-CPU saturation has no fixed finding id'
    }

    It 'lands the fact as an extension finding whose payload equals the measured values' {
        [string]$script:DeepFinding.section | Should -BeExactly 'extension:cpu-saturation'
        [string]$script:DeepFinding.id | Should -BeExactly 'cpu-saturation'
        [string]$script:DeepFinding.severity | Should -BeExactly 'warn'

        [double]$script:DeepFinding.evidence.value | Should -Be 87.25
        [double]$script:DeepFinding.evidence.value | Should -Be ([double]$script:DeepProbe.value) `
            -Because 'the finding payload must equal the fixture-measured probe value, not prose'
        [string]$script:DeepFinding.evidence.status | Should -BeExactly 'measured'
        [string]$script:DeepFinding.evidence.metric | Should -BeExactly 'cpu.processor_time_percent'
        [string]$script:DeepFinding.evidence.domain | Should -BeExactly 'cpu'
    }

    It 'validates the extension finding and renders its section' {
        @(& $script:TestMap -Findings @($script:DeepFinding)).Count | Should -Be 0

        $report = & $script:NewReport -Findings @($script:DeepFinding)
        $document = & $script:ToDocument -Report $report -Language 'en'
        @($document.sections | Where-Object { [string]$_.id -ceq 'extension:cpu-saturation' }).Count | Should -Be 1
        @($document.findings | Where-Object { [string]$_.id -ceq 'cpu-saturation' }).Count | Should -Be 1
    }
}

Describe 'novel-target eval: Test-PcxTarget decides with a typed code' {

    BeforeAll {
        $environment = & $script:ReadJson -Path (Join-Path -Path $script:DesktopFixture -ChildPath 'machine.json')
        $script:NovelPolicy = & $script:ConvertPolicyProfile -Environment $environment

        $catalogPaths = New-Object System.Collections.Generic.List[string]
        foreach ($action in @((& $script:GetCatalog).actions)) {
            foreach ($target in @($action.target)) {
                if ($null -eq $target) { continue }
                $pathProperty = $target.PSObject.Properties['Path']
                if ($null -eq $pathProperty) { continue }
                $path = [string]$pathProperty.Value
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                [void]$catalogPaths.Add($path.ToLowerInvariant())
            }
        }
        $script:NovelCatalogPaths = @($catalogPaths | Sort-Object -Unique)

        $script:NovelAllowedTarget = @{ Kind = 'task'; Path = '\PcxDemo\NovelTarget'; Enabled = $false }
        $script:NovelDeniedTarget = @{ Kind = 'task'; Path = '\Microsoft\Windows\NovelSystemTask'; Enabled = $false }
    }

    It 'proposes targets outside the seed catalog' {
        $script:NovelCatalogPaths -contains '\pcxdemo\noveltarget' | Should -BeFalse
        $script:NovelCatalogPaths -contains '\microsoft\windows\novelsystemtask' | Should -BeFalse
    }

    It 'allows an agent-proposed disable-only target with PCX-POLICY-ALLOW' {
        $decision = & $script:TestTarget -Target $script:NovelAllowedTarget -Profile $script:NovelPolicy

        [bool]$decision.allowed | Should -BeTrue
        [string]$decision.code | Should -BeExactly 'PCX-POLICY-ALLOW'
    }

    It 'denies an agent-proposed system task target with PCX-POLICY-TASK-SYSTEM' {
        $decision = & $script:TestTarget -Target $script:NovelDeniedTarget -Profile $script:NovelPolicy

        [bool]$decision.allowed | Should -BeFalse
        [string]$decision.code | Should -BeExactly 'PCX-POLICY-TASK-SYSTEM'
    }
}
