<#
.SYNOPSIS
    Thirteen read-only diagnostics sections (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Proves the todo 4 acceptance block verbatim: all 13 builders are
    exported and produce at least one finding on the desktop fixture; every
    fixed id is present (measured or unavailable); no monitor refresh-rate
    id exists anywhere; only approved read cmdlets appear in the section
    sources (comments and string literals stripped first, mirroring the
    ConvertTo-Json scan precedent); a throwing probe degrades to exactly one
    unavailable finding; top-space-consumers never exceeds 2 s. Every
    finding key resolves in both languages through the dictionary, ru copy
    carries no Latin, the group map validates, and the report round-trips
    through canonical JSON. Fixture-only: PCX_TEST_RUN stays set, no live
    OS reads or writes. This file stays ASCII and reads identically on
    PowerShell 5.1 and 7.
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
    $script:ModulePath = $modulePath
    $script:NewFinding = $pcxModule.ExportedCommands['New-PcxFinding']
    $script:NewReport = $pcxModule.ExportedCommands['New-PcxDiagnosticsReport']
    $script:TestMap = $pcxModule.ExportedCommands['Test-PcxFindingGroupMap']
    $script:ToDocument = $pcxModule.ExportedCommands['ConvertTo-PcxFindingsDocument']
    $script:ToCanonical = $pcxModule.ExportedCommands['ConvertTo-PcxCanonicalJson']
    $script:GetText = $pcxModule.ExportedCommands['Get-PcxText']

    $script:Builders = [ordered]@{
        platform    = 'Get-PlatformFindings'
        power       = 'Get-PowerFindings'
        storage     = 'Get-StorageFindings'
        memory      = 'Get-MemoryFindings'
        background  = 'Get-BackgroundFindings'
        services    = 'Get-ServicesFindings'
        gaming      = 'Get-GamingFindings'
        display     = 'Get-DisplayFindings'
        network     = 'Get-NetworkFindings'
        maintenance = 'Get-MaintenanceFindings'
        drivers     = 'Get-DriversFindings'
        security    = 'Get-SecurityFindings'
        thermal     = 'Get-ThermalFindings'
    }

    $script:FixedIds = [ordered]@{
        platform    = @('os-build-support', 'uptime', 'bios-age', 'gpu-driver-age', 'cpu-mem-summary')
        power       = @('pagefile-state', 'power-plan', 'fast-startup')
        storage     = @('system-free-space', 'volume-health', 'top-space-consumers')
        memory      = @('ram-usage', 'pagefile-pressure', 'standby-list')
        background  = @('process-count', 'top-ram-processes', 'startup-entries', 'scheduled-task-count')
        services    = @('auto-services', 'third-party-services', 'failed-services')
        gaming      = @('game-mode', 'hags', 'game-dvr', 'overlay-processes', 'vbs-hvci')
        display     = @('monitor-count', 'resolution-layout', 'audio-endpoints')
        network     = @('adapter-link-speed', 'dns-servers', 'nagle', 'tcp-autotuning')
        maintenance = @('windows-update-age', 'restore-points', 'pending-reboot')
        drivers     = @('driver-age', 'problem-devices')
        security    = @('defender-state', 'firewall-state', 'bitlocker-state', 'tpm-state', 'defender-exclusions')
        thermal     = @('cpu-temp', 'gpu-temp')
    }

    $script:Severities = @('critical', 'warn', 'info', 'good', 'unavailable')

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DiagRoot = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Diagnostics'

    $script:ReadCmdlets = @(
        'Get-CimInstance', 'Get-ItemProperty', 'Get-ChildItem', 'Test-Path',
        'Get-Process', 'Get-Service', 'Get-ScheduledTask', 'Get-WinEvent',
        'Get-ComputerRestorePoint', 'Get-Date'
    )
    $script:UtilityCmdlets = @(
        'Select-Object', 'Where-Object', 'Sort-Object', 'Measure-Object',
        'ForEach-Object', 'Join-Path', 'Split-Path', 'Resolve-Path',
        'New-Object', 'New-TimeSpan', 'Set-StrictMode'
    )

    function Get-DiagnosticsFixture {
        param([Parameter(Mandatory = $true)][string] $Profile)

        $environment = Get-Content -LiteralPath (Join-Path -Path $script:FixtureRoot -ChildPath ($Profile + '/machine.json')) -Raw | ConvertFrom-Json
        $scan = Get-Content -LiteralPath (Join-Path -Path $script:FixtureRoot -ChildPath ($Profile + '/state.json')) -Raw | ConvertFrom-Json
        return [ordered]@{ environment = $environment; scan = $scan }
    }

    function Get-DiagnosticsSectionFindings {
        param([Parameter(Mandatory = $true)][string] $Section)

        $fixture = Get-DiagnosticsFixture -Profile 'desktop'
        $command = $script:Module.ExportedCommands[$script:Builders[$Section]]
        return @(& $command -Environment $fixture.environment -Scan $fixture.scan)
    }

    function Get-PcxDiagnosticsCodeTokens {
        param([Parameter(Mandatory = $true)][string] $Text)

        $code = [regex]::Replace($Text, '(?s)<#.*?#>', '')
        $code = [regex]::Replace($code, "(?m)#[^\r\n]*", '')
        $code = [regex]::Replace($code, "'([^']|'')*'", "''")
        $tokens = @([regex]::Matches($code, '\b[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9][A-Za-z0-9_\-]*\b') | ForEach-Object { $_.Value })
        return @($tokens | Sort-Object -Unique)
    }

    function Get-PcxDiagnosticsInternalCalls {
        $calls = @(
            'Get-PcxPolicyMember', 'Get-PcxEnvironmentFieldValue',
            'ConvertTo-PcxCollectorInt', 'ConvertTo-PcxCollectorLong',
            'ConvertTo-PcxCollectorDouble', 'New-PcxFinding',
            'Read-PcxEnvironmentRegistryValueState', 'Read-PcxStorageTopConsumers',
            'Read-PcxPlatformProbe', 'Read-PcxPowerProbe', 'Read-PcxStorageProbe',
            'Read-PcxMemoryProbe', 'Read-PcxBackgroundProbe', 'Read-PcxServicesProbe',
            'Read-PcxGamingProbe', 'Read-PcxDisplayProbe', 'Read-PcxNetworkProbe',
            'Read-PcxMaintenanceProbe', 'Read-PcxDriversProbe', 'Read-PcxSecurityProbe',
            'Read-PcxThermalProbe',
            'Get-PlatformFindings', 'Get-PowerFindings', 'Get-StorageFindings',
            'Get-MemoryFindings', 'Get-BackgroundFindings', 'Get-ServicesFindings',
            'Get-GamingFindings', 'Get-DisplayFindings', 'Get-NetworkFindings',
            'Get-MaintenanceFindings', 'Get-DriversFindings', 'Get-SecurityFindings',
            'Get-ThermalFindings'
        )
        return $calls
    }
}

Describe 'diagnostics surface' {
    It 'exports all thirteen section builders' {
        foreach ($name in $script:Builders.Values) {
            $script:Module.ExportedCommands.ContainsKey($name) | Should -BeTrue -Because "$name is the todo 4 contract"
        }

        $script:Builders.Count | Should -BeExactly 13
    }

    It 'produces at least one finding per section on the desktop fixture' {
        foreach ($section in $script:Builders.Keys) {
            $findings = Get-DiagnosticsSectionFindings -Section $section
            $findings.Count | Should -BeGreaterOrEqual 1 -Because "section '$section' must report on the fixture"
        }
    }

    It 'runs every builder on every fixture profile without throwing' {
        foreach ($profile in @('desktop', 'managed', 's-mode')) {
            $fixture = Get-DiagnosticsFixture -Profile $profile
            foreach ($section in $script:Builders.Keys) {
                $command = $script:Module.ExportedCommands[$script:Builders[$section]]
                { & $command -Environment $fixture.environment -Scan $fixture.scan } | Should -Not -Throw -Because "section '$section' must never throw on '$profile'"
            }
        }
    }
}

Describe 'diagnostics fixed ids' {
    It 'emits every fixed id with a valid severity and non-empty evidence' {
        foreach ($section in $script:FixedIds.Keys) {
            $findings = Get-DiagnosticsSectionFindings -Section $section
            $ids = @($findings | ForEach-Object { [string]$_.section + '/' + [string]$_.id })

            foreach ($fixed in $script:FixedIds[$section]) {
                $ids | Should -Contain "$section/$fixed" -Because "fixed id '$fixed' must be present or unavailable"
            }

            $findings.Count | Should -BeExactly (@($script:FixedIds[$section]).Count) -Because "section '$section' emits exactly its fixed ids"

            foreach ($finding in $findings) {
                [string]$finding.severity | Should -BeIn $script:Severities -Because "finding '$($finding.id)' carries a known severity"
                ($null -eq $finding.evidence) | Should -BeFalse -Because "finding '$($finding.id)' carries machine evidence"
            }
        }
    }

    It 'marks unavailable findings with a reason and measured findings with measured evidence' {
        foreach ($section in $script:Builders.Keys) {
            foreach ($finding in (Get-DiagnosticsSectionFindings -Section $section)) {
                if ([string]$finding.severity -eq 'unavailable') {
                    [string]$finding.evidence.status | Should -BeExactly 'unavailable'
                    [string]$finding.evidence.reason | Should -Not -BeNullOrEmpty -Because "unavailable finding '$($finding.id)' explains why"
                }
                else {
                    [string]$finding.evidence.status | Should -BeExactly 'measured' -Because "finding '$($finding.id)' is measured"
                }
            }
        }
    }

    It 'contains no monitor refresh-rate finding anywhere' {
        foreach ($section in $script:Builders.Keys) {
            foreach ($finding in (Get-DiagnosticsSectionFindings -Section $section)) {
                [string]$finding.id | Should -Not -Match 'refresh' -Because 'no refresh-rate id may exist'
                [string]$finding.titleKey | Should -Not -Match 'refresh'
                [string]$finding.detailKey | Should -Not -Match 'refresh'
            }
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $script:DiagRoot -File -Filter '*.ps1')) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $code = [regex]::Replace($text, '(?s)<#.*?#>', '')
            $code | Should -Not -Match '(?i)refresh' -Because "$($file.Name) must never read monitor refresh rate"
        }
    }
}

Describe 'diagnostics read-only proof' {
    It 'calls only approved read cmdlets in every section file' {
        $internal = Get-PcxDiagnosticsInternalCalls

        foreach ($file in @(Get-ChildItem -LiteralPath $script:DiagRoot -File -Filter '*.ps1')) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $tokens = Get-PcxDiagnosticsCodeTokens -Text $text

            foreach ($token in $tokens) {
                if ($internal -contains $token) {
                    continue
                }

                if ($token -like 'Get-*' -or $token -like 'Test-*') {
                    $script:ReadCmdlets | Should -Contain $token -Because "$($file.Name) may only call approved read cmdlets, found '$token'"
                }
                else {
                    $script:UtilityCmdlets | Should -Contain $token -Because "$($file.Name) uses only utility cmdlets besides reads, found '$token'"
                }
            }
        }
    }

    It 'contains no bare external binary or shell escape' {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:DiagRoot -File -Filter '*.ps1')) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $code = [regex]::Replace($text, '(?s)<#.*?#>', '')
            $code = [regex]::Replace($code, "(?m)#[^\r\n]*", '')
            $code = [regex]::Replace($code, "'([^']|'')*'", "''")

            $code | Should -Not -Match '(?i)\bpowercfg\b' -Because "$($file.Name) never shells to powercfg"
            $code | Should -Not -Match '(?i)\bnetsh\b' -Because "$($file.Name) never shells to netsh"
            $code | Should -Not -Match '(?i)\bwmic\b' -Because "$($file.Name) never shells to wmic"
            $code | Should -Not -Match '(?i)\bbcdedit\b' -Because "$($file.Name) never runs bcdedit"
            $code | Should -Not -Match 'ConvertTo-Json' -Because "$($file.Name) never uses host-versioned JSON"
            $code | Should -Not -Match '(?i)\bInvoke-Expression\b' -Because "$($file.Name) never evaluates strings"
            $code | Should -Not -Match '(?m)^\s*exit\b' -Because "$($file.Name) never exits the host"
        }
    }

    It 'emits no Write-* output from any builder' {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:DiagRoot -File -Filter '*.ps1')) {
            $tokens = Get-PcxDiagnosticsCodeTokens -Text ([System.IO.File]::ReadAllText($file.FullName))
            foreach ($token in @($tokens | Where-Object { $_ -like 'Write-*' })) {
                $token | Should -BeExactly 'Write-IMPOSSIBLE' -Because "$($file.Name) must stay silent, found '$token'"
            }
        }
    }
}

Describe 'diagnostics degradation' {
    It 'degrades a throwing section to exactly one unavailable finding' {
        Mock -CommandName 'Read-PcxPlatformProbe' -ModuleName 'Pcx' -MockWith { throw 'simulated probe failure' }

        $command = $script:Module.ExportedCommands['Get-PlatformFindings']
        $fixture = Get-DiagnosticsFixture -Profile 'desktop'
        $findings = @(& $command -Environment $fixture.environment -Scan $fixture.scan)

        $findings.Count | Should -BeExactly 1 -Because 'a throwing section degrades to one finding'
        [string]$findings[0].section | Should -BeExactly 'platform'
        [string]$findings[0].severity | Should -BeExactly 'unavailable'
    }

    It 'degrades a throwing storage probe to exactly one unavailable finding' {
        Mock -CommandName 'Read-PcxStorageProbe' -ModuleName 'Pcx' -MockWith { throw 'simulated storage failure' }

        $command = $script:Module.ExportedCommands['Get-StorageFindings']
        $fixture = Get-DiagnosticsFixture -Profile 'desktop'
        $findings = @(& $command -Environment $fixture.environment -Scan $fixture.scan)

        $findings.Count | Should -BeExactly 1 -Because 'a throwing probe degrades to one finding'
        [string]$findings[0].section | Should -BeExactly 'storage'
        [string]$findings[0].severity | Should -BeExactly 'unavailable'
    }

    It 'keeps top-space-consumers under 2 s on the fixture builder call' {
        $command = $script:Module.ExportedCommands['Get-StorageFindings']
        $fixture = Get-DiagnosticsFixture -Profile 'desktop'

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $findings = @(& $command -Environment $fixture.environment -Scan $fixture.scan)
        $watch.Stop()

        $watch.ElapsedMilliseconds | Should -BeLessThan 2000 -Because 'top-space-consumers never exceeds 2 s'
        @($findings | Where-Object { [string]$_.id -eq 'top-space-consumers' }).Count | Should -BeExactly 1
    }

    It 'caps the folder walk by entries, depth and a hard budget' {
        $walkRoot = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
        $runWalk = $script:Module.NewBoundScriptBlock({ param($Root) Read-PcxStorageTopConsumers -Roots @($Root) -MaxDepth 2 -MaxEntries 500 -BudgetMs 2000 })
        $probe = & $runWalk $walkRoot

        $probe.budgetMs | Should -BeExactly 2000
        $probe.maxEntries | Should -BeExactly 500
        $probe.maxDepth | Should -BeExactly 2
        $probe.elapsedMs | Should -BeLessThan 2000

        $runCapped = $script:Module.NewBoundScriptBlock({ param($Root) Read-PcxStorageTopConsumers -Roots @($Root) -MaxDepth 2 -MaxEntries 1 -BudgetMs 2000 })
        $capped = & $runCapped $walkRoot

        ([int]$capped.counted) | Should -BeLessOrEqual 1 -Because 'the walk stops at the entry cap'
    }
}

Describe 'diagnostics text and mapping' {
    It 'resolves every finding key in both languages with no Latin in ru' {
        $all = @()
        foreach ($section in $script:Builders.Keys) {
            $all += Get-DiagnosticsSectionFindings -Section $section
        }

        $all.Count | Should -BeExactly 45 -Because '13 sections emit exactly the 45 fixed ids'

        foreach ($finding in $all) {
            $titleEn = & $script:GetText -Key ([string]$finding.titleKey) -Language 'en'
            $detailEn = & $script:GetText -Key ([string]$finding.detailKey) -Language 'en'
            $titleRu = & $script:GetText -Key ([string]$finding.titleKey) -Language 'ru'
            $detailRu = & $script:GetText -Key ([string]$finding.detailKey) -Language 'ru'

            $titleEn | Should -Match '[A-Za-z]' -Because "en title '$($finding.titleKey)' reads English"
            $detailEn | Should -Match '[A-Za-z]'
            $titleRu | Should -Not -Match '[A-Za-z]' -Because "ru title '$($finding.titleKey)' must not leak English"
            $detailRu | Should -Not -Match '[A-Za-z]'
            $titleEn | Should -Not -BeExactly $titleRu -Because "key '$($finding.titleKey)' is translated, not copied"
        }
    }

    It 'renders every finding to a document in both languages with no PCX-E-TEXT' {
        $all = @()
        foreach ($section in $script:Builders.Keys) {
            $all += Get-DiagnosticsSectionFindings -Section $section
        }

        $report = & $script:NewReport -Findings $all
        { & $script:ToDocument -Report $report -Language 'en' } | Should -Not -Throw
        { & $script:ToDocument -Report $report -Language 'ru' } | Should -Not -Throw

        $errors = & $script:TestMap -Findings $all
        @($errors).Count | Should -BeExactly 0 -Because 'no finding carries a remedy without a group'
    }

    It 'round-trips the full 45-finding report through canonical JSON' {
        $all = @()
        foreach ($section in $script:Builders.Keys) {
            $all += Get-DiagnosticsSectionFindings -Section $section
        }

        $report = & $script:NewReport -Findings $all
        $json = & $script:ToCanonical -InputObject $report
        $json | Should -Match 'os-build-support'
        $json | Should -Match 'gpu-temp'
        $json | Should -Not -Match 'refresh'
    }

    It 'builds repeat calls with identical bytes' {
        $first = Get-DiagnosticsSectionFindings -Section 'platform'
        $second = Get-DiagnosticsSectionFindings -Section 'platform'

        $firstJson = & $script:ToCanonical -InputObject (& $script:NewReport -Findings $first)
        $secondJson = & $script:ToCanonical -InputObject (& $script:NewReport -Findings $second)
        $secondJson | Should -BeExactly $firstJson -Because 'builders are pure functions of Environment and Scan'
    }
}
