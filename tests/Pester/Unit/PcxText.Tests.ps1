<#
.SYNOPSIS
    ru/en text layer and --lang wiring (optimize-v0.1-discovery todo 1).

.DESCRIPTION
    Proves the Wave 0 text layer: the four text functions are exported, the
    dictionary is complete in both languages (every en key exists in ru and
    vice versa, so removing one ru finding key fails), UI copy carries no
    Latin word-sequence in ru, an unknown --lang refuses with PCX-E-LANG and
    never falls back silently, and tune --lang ru/en succeeds end to end.
    Cyrillic expectations are spelled with code points so this file stays
    ASCII and reads identically on PowerShell 5.1 and 7.
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
    $script:ResolveLanguage = $pcxModule.ExportedCommands['Resolve-PcxLanguage']
    $script:GetText = $pcxModule.ExportedCommands['Get-PcxText']
    $script:GetSeverity = $pcxModule.ExportedCommands['Get-PcxSeverityLabel']
    $script:GetSection = $pcxModule.ExportedCommands['Get-PcxSectionTitle']
    $script:Dispatch = $pcxModule.ExportedCommands['Invoke-PcxDispatch']

    $script:DesktopFixture = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment/desktop'

    $script:Sections = @(
        'platform', 'power', 'storage', 'memory', 'background', 'services',
        'gaming', 'display', 'network', 'maintenance', 'drivers', 'security',
        'thermal'
    )
    $script:Severities = @('critical', 'warn', 'info', 'good', 'unavailable')
    $script:Groups = @('safe', 'performance', 'behavior', 'manual', 'dont-touch')
    $script:Columns = @('number', 'category', 'section', 'finding', 'what', 'proposal', 'outcome', 'stops', 'evidence', 'recommendation')
    $script:Summaries = @('progress.section')
    $script:Decisions = @(
        'PCX-POLICY-ACL', 'PCX-POLICY-BOOTCHAIN', 'PCX-POLICY-SECURITY',
        'PCX-POLICY-ANTICHEAT', 'PCX-POLICY-HKCU-DEFAULT-DENY',
        'PCX-POLICY-REGISTRY-VALUE', 'PCX-POLICY-HKLM-VALUE', 'PCX-POLICY-HIVE',
        'PCX-POLICY-DRIVER', 'PCX-POLICY-SERVICE-START',
        'PCX-POLICY-BLAST-RADIUS', 'PCX-POLICY-TASK-SYSTEM',
        'PCX-POLICY-TASK-ENABLE', 'PCX-POLICY-REPARSE', 'PCX-POLICY-FILE-ROLE',
        'PCX-POLICY-QUARANTINE-ROOT', 'PCX-POLICY-FILE-ROOT',
        'PCX-POLICY-MANAGED', 'PCX-POLICY-SMODE', 'PCX-POLICY-DEVDRIVE',
        'PCX-POLICY-GRAMMAR', 'PCX-POLICY-ALLOW'
    )
    $script:BuildKeys = @(
        'build.unsupported', 'build.verified', 'build.unverified',
        'build.unavailable', 'build.notanumber'
    )
    $script:ScanKeys = @(
        'scan.env.budget', 'scan.env.timeout', 'scan.env.error',
        'scan.env.empty', 'scan.collector.timeout', 'scan.collector.error',
        'scan.source.nometric', 'scan.source.budget', 'scan.source.timeout',
        'scan.source.failed'
    )
    $script:ApplyKeys = @(
        'apply.file.partial', 'apply.file.all-skipped'
    )

    # Pure UI copy: every one of these must read in the user's language with
    # no word-sequence leaking from the other dictionary.
    $script:UiKeys = @(
        'section.platform', 'section.power', 'section.storage',
        'section.memory', 'section.background', 'section.services',
        'section.gaming', 'section.display', 'section.network',
        'section.maintenance', 'section.drivers', 'section.security',
        'section.thermal', 'severity.critical', 'severity.warn',
        'severity.info', 'severity.good', 'severity.unavailable',
        'group.safe', 'group.performance', 'group.behavior', 'group.manual',
        'group.dont-touch', 'column.number', 'column.category', 'column.section',
        'column.finding', 'column.what', 'column.proposal', 'column.outcome',
        'column.evidence', 'column.recommendation',
        'outcome.performance',
        'fact.frees', 'fact.frees.atleast', 'fact.frees.denied', 'unit.gb', 'unit.mb',
        'table.none.proposals',
        'risk.safe', 'risk.behavior', 'risk.risky',
        'heading.attention', 'heading.notes', 'heading.good', 'heading.nodata',
        'heading.actions', 'table.none.problems',
        'fact.free', 'fact.hags-off', 'fact.game-dvr-on', 'fact.no-printers',
        'fact.userassist', 'fact.prefetch', 'fact.taskhistory',
        'fact.tips-on', 'fact.ads-on', 'fact.web-on',
        'progress.section'
    )
}

Describe 'text layer surface' {

    It 'exports the four text functions' {
        foreach ($name in @('Resolve-PcxLanguage', 'Get-PcxText', 'Get-PcxSeverityLabel', 'Get-PcxSectionTitle')) {
            $script:Module.ExportedCommands.ContainsKey($name) | Should -BeTrue -Because "$name must be exported"
        }
        ($null -ne $script:ResolveLanguage) | Should -BeTrue
        ($null -ne $script:GetText) | Should -BeTrue
        ($null -ne $script:GetSeverity) | Should -BeTrue
        ($null -ne $script:GetSection) | Should -BeTrue
    }

    It 'resolves explicit language codes strictly' {
        & $script:ResolveLanguage -Requested 'ru' | Should -Be 'ru'
        & $script:ResolveLanguage -Requested 'en' | Should -Be 'en'
        & $script:ResolveLanguage -Requested 'RU' | Should -Be 'ru'
        & $script:ResolveLanguage -Requested 'ru-RU' | Should -Be 'ru'
        & $script:ResolveLanguage -Requested 'en-US' | Should -Be 'en'
    }

    It 'refuses an unknown code with PCX-E-LANG, never silently falling back' {
        foreach ($code in @('xx', 'de', 'fr', 'english')) {
            { & $script:ResolveLanguage -Requested $code } | Should -Throw '*PCX-E-LANG*' -Because "'$code' must refuse, not fall back"
        }
    }

    It 'auto-detects a supported language when no code is given' {
        $resolved = & $script:ResolveLanguage
        $resolved | Should -BeIn @('en', 'ru')
    }
}

Describe 'dictionary completeness' {

    It 'carries the same key set in en and ru' {
        foreach ($key in $script:UiKeys) {
            { & $script:GetText -Key $key -Language 'en' } | Should -Not -Throw -Because "en key '$key' must exist"
            { & $script:GetText -Key $key -Language 'ru' } | Should -Not -Throw -Because "ru key '$key' must exist"
        }

        $script:UiKeys.Count | Should -BeGreaterThan 30
    }

    It 'covers every section, severity, group and column in both languages' {
        foreach ($id in $script:Sections) {
            { & $script:GetSection -Section $id -Language 'en' } | Should -Not -Throw
            { & $script:GetSection -Section $id -Language 'ru' } | Should -Not -Throw
        }
        foreach ($name in $script:Severities) {
            { & $script:GetSeverity -Severity $name -Language 'en' } | Should -Not -Throw
            { & $script:GetSeverity -Severity $name -Language 'ru' } | Should -Not -Throw
        }
        foreach ($group in $script:Groups) {
            { & $script:GetText -Key ("group.$group") -Language 'en' } | Should -Not -Throw
            { & $script:GetText -Key ("group.$group") -Language 'ru' } | Should -Not -Throw
        }
        foreach ($column in $script:Columns) {
            { & $script:GetText -Key ("column.$column") -Language 'en' } | Should -Not -Throw
            { & $script:GetText -Key ("column.$column") -Language 'ru' } | Should -Not -Throw
        }
        foreach ($key in $script:Summaries) {
            { & $script:GetText -Key $key -Language 'en' } | Should -Not -Throw
            { & $script:GetText -Key $key -Language 'ru' } | Should -Not -Throw
        }
    }

    It 'covers every decision code and build-gate result in both languages' {
        foreach ($code in $script:Decisions) {
            { & $script:GetText -Key ("decision.$code") -Language 'en' } | Should -Not -Throw -Because "decision '$code' must read en"
            { & $script:GetText -Key ("decision.$code") -Language 'ru' } | Should -Not -Throw -Because "decision '$code' must read ru"
        }
        foreach ($key in $script:BuildKeys) {
            { & $script:GetText -Key $key -Language 'en' } | Should -Not -Throw
            { & $script:GetText -Key $key -Language 'ru' } | Should -Not -Throw
        }
        foreach ($key in $script:ScanKeys) {
            { & $script:GetText -Key $key -Language 'en' } | Should -Not -Throw
            { & $script:GetText -Key $key -Language 'ru' } | Should -Not -Throw
        }
    }

    It 'renders ru UI copy with no Latin word-sequence' {
        foreach ($key in $script:UiKeys) {
            $ru = & $script:GetText -Key $key -Language 'ru'
            $ru | Should -Not -Match '[A-Za-z]' -Because "ru key '$key' must not leak English"
        }
    }

    It 'renders en UI copy in Latin and different from ru' {
        foreach ($key in $script:UiKeys) {
            $en = & $script:GetText -Key $key -Language 'en'
            $ru = & $script:GetText -Key $key -Language 'ru'
            if ($key -ne 'column.number') {
                $en | Should -Match '[A-Za-z]' -Because "en key '$key' must read English"
            }
            $en | Should -Not -Be $ru -Because "key '$key' must be translated, not copied"
        }
    }

    It 'reads the platform title from code points in both languages' {
        (& $script:GetSection -Section 'platform' -Language 'en') | Should -BeExactly 'Platform'
        $ru = & $script:GetSection -Section 'platform' -Language 'ru'
        $expected = -join @(0x041F, 0x043B, 0x0430, 0x0442, 0x0444, 0x043E, 0x0440, 0x043C, 0x0430 | ForEach-Object { [char]$_ })
        $ru | Should -BeExactly $expected
    }

    It 'throws PCX-E-TEXT for an unknown key or label' {
        { & $script:GetText -Key 'section.no-such-section' -Language 'en' } | Should -Throw '*PCX-E-TEXT*'
        { & $script:GetSection -Section 'refresh-rate' -Language 'ru' } | Should -Throw '*PCX-E-TEXT*'
        { & $script:GetSeverity -Severity 'mild' -Language 'en' } | Should -Throw '*PCX-E-TEXT*'
    }

    It 'formats placeholders with the call-site values' {
        $free = & $script:GetText -Key 'fact.free' -Language 'ru' -FormatArgs @('105')
        $free | Should -Match '105'

        $timeout = & $script:GetText -Key 'scan.collector.timeout' -Language 'en' -FormatArgs @('storage', 20000)
        $timeout | Should -Match 'storage'
        $timeout | Should -Match '20000'
    }

    It 'covers every table action-region key in both languages' {
        $tableKeys = @(
            'table.recommendation.performance', 'table.recommendation.safe',
            'table.recommendation.behavior', 'table.recommendation.manual',
            'table.recommendation.donttouch', 'table.demotion.policy',
            'table.demotion.build', 'table.caveat',
            'table.stops.thumbnails', 'table.stops.icon-cache',
            'table.stops.delivery-optimization-cache',
            'table.stops.windows-update-download-cache',
            'table.stops.diagtrack-u4', 'table.stops.startup-task-u4',
            'table.stops.startup-shortcut-u4',
            'table.stops.spooler-no-printers', 'table.stops.game-dvr',
            'table.stops.hags', 'table.stops.tips',
            'table.stops.advertising-id', 'table.stops.search-web',
            'table.stops.vbs', 'table.stops.managed', 'table.stops.s-mode',
            'table.stops.hvci', 'table.stops.inverse.manifest-only',
            'table.stops.inverse.quarantine',
            'table.stops.inverse.snapshot', 'table.stops.default',
            'table.env.managed.label', 'table.env.managed.text',
            'table.env.smode.label', 'table.env.smode.text',
            'table.env.hvci.label', 'table.env.hvci.text'
        )
        foreach ($key in $tableKeys) {
            { & $script:GetText -Key $key -Language 'en' } | Should -Not -Throw -Because "table key '$key' must read en"
            { & $script:GetText -Key $key -Language 'ru' } | Should -Not -Throw -Because "table key '$key' must read ru"
        }

        $policy = & $script:GetText -Key 'table.demotion.policy' -Language 'en' -FormatArgs @('X')
        $policy | Should -Match 'X'
        $caveat = & $script:GetText -Key 'table.caveat' -Language 'en' -FormatArgs @('base', 'note')
        $caveat | Should -Match 'base'
        $caveat | Should -Match 'Caveat:'
        $caveat | Should -Match 'note'
    }

    It 'covers every apply file-skip key in both languages' {
        foreach ($key in $script:ApplyKeys) {
            { & $script:GetText -Key $key -Language 'en' } | Should -Not -Throw -Because "apply key '$key' must read en"
            { & $script:GetText -Key $key -Language 'ru' } | Should -Not -Throw -Because "apply key '$key' must read ru"
        }

        $partial = & $script:GetText -Key 'apply.file.partial' -Language 'en' -FormatArgs @(3, 4, 1, 'p: locked')
        $partial | Should -Match 'deleted 3 of 4'
        $partial | Should -Match 'skipped 1'

        $refused = & $script:GetText -Key 'apply.file.all-skipped' -Language 'en' -FormatArgs @(2, 'a: x; b: y')
        $refused | Should -Match 'no file could be deleted'
        $refused | Should -Match 'skipped 2'

        $partialRu = & $script:GetText -Key 'apply.file.partial' -Language 'ru' -FormatArgs @(3, 4, 1, '')
        $partialRu | Should -Not -Match '[A-Za-z]'
        $refusedRu = & $script:GetText -Key 'apply.file.all-skipped' -Language 'ru' -FormatArgs @(2, '')
        $refusedRu | Should -Not -Match '[A-Za-z]'
    }
}

Describe 'tune --lang wiring' {

    It 'accepts --lang ru and records the language on the envelope' {
        $result = & $script:Dispatch -Arguments @('tune', '--lang', 'ru', '--fixture', $script:DesktopFixture, '--table')
        $result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -Be 'ok'
        [string]$result.Envelope.data.language | Should -BeExactly 'ru'
        @($result.Envelope.diagnostics | Where-Object { $_.code -eq 'PCX-E-SUBCOMMAND' }).Count | Should -Be 0
        @($result.Envelope.diagnostics | Where-Object { $_.code -eq 'PCX-E-SCAN-ARG' }).Count | Should -Be 0
    }

    It 'accepts --lang en and reports English' {
        $result = & $script:Dispatch -Arguments @('tune', '--lang', 'en', '--fixture', $script:DesktopFixture, '--table')
        $result.ExitCode | Should -Be 0
        [string]$result.Envelope.data.language | Should -BeExactly 'en'
    }

    It 'resolves a bare fixture name so --fixture desktop works' {
        $result = & $script:Dispatch -Arguments @('tune', '--lang', 'ru', '--fixture', 'desktop', '--table')
        $result.ExitCode | Should -Be 0 -Because 'a bare fixture name must resolve under tests/fixtures/environment'
        $result.Envelope.status | Should -Be 'ok'
    }

    It 'refuses --lang xx with PCX-E-LANG and never scans' {
        $result = & $script:Dispatch -Arguments @('tune', '--lang', 'xx', '--fixture', $script:DesktopFixture)
        $result.ExitCode | Should -Be 2
        $result.Envelope.status | Should -Be 'refused'
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-LANG'
    }

    It 'advertises --lang in the help flags and tune usage' {
        $result = & $script:Dispatch -Arguments @('help')
        $result.ExitCode | Should -Be 0
        ($result.Envelope.data.flags -contains '--lang') | Should -BeTrue
        (($result.Envelope.data.usage -join "`n") -match '--lang') | Should -BeTrue
    }
}
