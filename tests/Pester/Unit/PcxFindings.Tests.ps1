<#
.SYNOPSIS
    Section registry, findings model and group mapping (optimize-v0.1-discovery todo 3).

.DESCRIPTION
    Proves the Wave 2 findings contract: the five functions are exported,
    Get-PcxSections returns exactly the 13 ordered ids, all 13 sections and
    extension:<id> validate while an unknown plain section refuses, a good
    finding with an actionId refuses, a remedy without a group refuses, the
    report round-trips through canonical JSON (never ConvertTo-Json), the
    document resolves every key through Get-PcxText, and the group map
    validates both directions. Fixture-only: no live-OS reads or writes.
    This file stays ASCII and reads identically on PowerShell 5.1 and 7.
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
    $script:GetSections = $pcxModule.ExportedCommands['Get-PcxSections']
    $script:NewFinding = $pcxModule.ExportedCommands['New-PcxFinding']
    $script:NewReport = $pcxModule.ExportedCommands['New-PcxDiagnosticsReport']
    $script:TestMap = $pcxModule.ExportedCommands['Test-PcxFindingGroupMap']
    $script:ToDocument = $pcxModule.ExportedCommands['ConvertTo-PcxFindingsDocument']
    $script:ToCanonical = $pcxModule.ExportedCommands['ConvertTo-PcxCanonicalJson']
    $script:GetText = $pcxModule.ExportedCommands['Get-PcxText']

    $script:OrderedSections = @(
        'platform', 'power', 'storage', 'memory', 'background', 'services',
        'gaming', 'display', 'network', 'maintenance', 'drivers', 'security',
        'thermal'
    )

    function New-TestEvidence {
        param([Parameter(Mandatory = $false)][object] $Value = 42)

        return [ordered]@{
            metric = 'test.metric'
            value  = $Value
            status = 'measured'
            domain = 'test'
            window = 'instant'
        }
    }

    function New-TestFinding {
        param(
            [string] $Section = 'platform',
            [string] $Id = 'test-finding',
            [string] $Severity = 'warn',
            [object] $Group = 'safe',
            [object] $ActionId = $null,
            [object] $Hint = $null,
            [bool] $AlreadyGood = $false
        )

        return (& $script:NewFinding -Section $Section -Id $Id -Severity $Severity `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence (New-TestEvidence) -AlreadyGood:$AlreadyGood `
            -WhyItMattersKey 'column.stops' -ActionHintKey $Hint `
            -Group $Group -ActionId $ActionId)
    }
}

Describe 'pcx findings surface' {
    It 'exports the five findings functions from the module' {
        foreach ($name in @('Get-PcxSections', 'New-PcxFinding', 'New-PcxDiagnosticsReport', 'Test-PcxFindingGroupMap', 'ConvertTo-PcxFindingsDocument')) {
            $script:Module.ExportedCommands.Keys | Should -Contain $name -Because "$name is the todo 3 contract"
        }
    }

    It 'returns exactly the 13 ordered section ids' {
        $sections = & $script:GetSections
        ($sections -join ',') | Should -BeExactly ($script:OrderedSections -join ',')
    }
}

Describe 'pcx finding validators' {
    It 'accepts all 13 registry sections' {
        foreach ($section in $script:OrderedSections) {
            $finding = New-TestFinding -Section $section -Id "probe-$section" -Group $null
            [string]$finding.section | Should -BeExactly $section
            [string]$finding.id | Should -BeExactly "probe-$section"
        }
    }

    It 'accepts an extension section' {
        $finding = New-TestFinding -Section 'extension:usb-errors' -Id 'usb-errors' -Group $null
        [string]$finding.section | Should -BeExactly 'extension:usb-errors'
    }

    It 'refuses an unknown plain section' {
        { New-TestFinding -Section 'bogus' } | Should -Throw '*PCX-E-FINDING-SECTION*'
    }

    It 'refuses an empty extension id' {
        { New-TestFinding -Section 'extension:' } | Should -Throw '*PCX-E-FINDING-SECTION*'
    }

    It 'refuses an extension id outside the identifier shape' {
        { New-TestFinding -Section 'extension:Bad Id!' } | Should -Throw '*PCX-E-FINDING-SECTION*'
    }

    It 'refuses an unknown severity' {
        { New-TestFinding -Severity 'fatal' } | Should -Throw '*PCX-E-FINDING-SEVERITY*'
    }

    It 'refuses an unknown group' {
        { New-TestFinding -Group 'someday' } | Should -Throw '*PCX-E-FINDING-GROUP*'
    }

    It 'refuses a good finding carrying an actionId' {
        { New-TestFinding -Severity 'good' -AlreadyGood:$true -Group 'safe' -ActionId 'game-dvr' } | Should -Throw '*PCX-E-FINDING-ACTION*'
    }

    It 'refuses a finding with an actionHintKey but no group' {
        { New-TestFinding -Severity 'warn' -Group $null -Hint 'column.recommendation' } | Should -Throw '*PCX-E-FINDING-GROUP*'
    }

    It 'refuses a finding with an actionId but no group' {
        { New-TestFinding -Severity 'warn' -Group $null -ActionId 'game-dvr' } | Should -Throw '*PCX-E-FINDING-GROUP*'
    }

    It 'accepts a remedy finding with a group' {
        $finding = New-TestFinding -Severity 'warn' -Group 'performance' -ActionId 'game-dvr' -Hint 'column.recommendation'
        [string]$finding.group | Should -BeExactly 'performance'
        [string]$finding.actionId | Should -BeExactly 'game-dvr'
    }

    It 'accepts a good finding with no remedy' {
        $finding = New-TestFinding -Severity 'good' -AlreadyGood:$true -Group $null
        [bool]$finding.alreadyGood | Should -BeTrue
        $finding.actionId | Should -BeNullOrEmpty
    }

    It 'refuses a finding without evidence' {
        { & $script:NewFinding -Section 'platform' -Id 'no-evidence' -Severity 'warn' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' -Evidence $null } | Should -Throw '*PCX-E-FINDING-EVIDENCE*'
    }

    It 'keeps the eleven-field shape in plan order' {
        $finding = New-TestFinding
        (@($finding.Keys) -join ',') | Should -BeExactly 'section,id,severity,titleKey,detailKey,evidence,alreadyGood,whyItMattersKey,actionHintKey,group,actionId'
    }
}

Describe 'pcx diagnostics report round-trip' {
    It 'builds a schema envelope around the findings' {
        $report = & $script:NewReport -Findings @((New-TestFinding -Id 'a'), (New-TestFinding -Id 'b'))
        [string]$report.schema | Should -BeExactly 'pcx-diagnostics/1'
        @($report.findings).Count | Should -Be 2
    }

    It 'round-trips the report through canonical JSON' {
        $findings = @(
            (New-TestFinding -Section 'platform' -Id 'os-build-support' -Severity 'info' -Group $null)
            (New-TestFinding -Section 'extension:usb-errors' -Id 'usb-errors' -Severity 'warn' -Group 'manual' -Hint 'column.recommendation')
            (New-TestFinding -Section 'gaming' -Id 'game-dvr' -Severity 'warn' -Group 'performance' -ActionId 'game-dvr')
        )
        $report = & $script:NewReport -Findings $findings

        $first = & $script:ToCanonical -InputObject $report
        $second = & $script:ToCanonical -InputObject $report
        $first | Should -BeExactly $second -Because 'canonical JSON is deterministic'

        $back = ConvertFrom-Json -InputObject $first
        [string]$back.schema | Should -BeExactly 'pcx-diagnostics/1'
        @($back.findings).Count | Should -Be 3
        [string]$back.findings[0].section | Should -BeExactly 'platform'
        [string]$back.findings[1].section | Should -BeExactly 'extension:usb-errors'
        [string]$back.findings[2].actionId | Should -BeExactly 'game-dvr'
        [string]$back.findings[2].evidence.metric | Should -BeExactly 'test.metric'
        [int]$back.findings[2].evidence.value | Should -Be 42
    }

    It 'round-trips a double with the invariant G17 form' {
        $finding = & $script:NewFinding -Section 'memory' -Id 'ram-usage' -Severity 'info' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence (New-TestEvidence -Value ([double]0.1 + [double]0.2)) -Group $null
        $report = & $script:NewReport -Findings @($finding)

        $json = & $script:ToCanonical -InputObject $report
        $json | Should -Match '0\.30000000000000004' -Because 'floats use invariant G17, never a locale decimal'

        $back = ConvertFrom-Json -InputObject $json
        [double]$back.findings[0].evidence.value | Should -Be ([double]0.1 + [double]0.2)
    }

    It 'never uses ConvertTo-Json for canonical output' {
        $source = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxFindings.ps1'
        $text = [System.IO.File]::ReadAllText($source)
        # Ignore comments: the file header documents the ban on that cmdlet.
        $code = [regex]::Replace($text, '(?s)<#.*?#>', '')
        $code = ($code -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        $code | Should -Not -Match 'ConvertTo-Json'
    }
}

Describe 'pcx findings document' {
    It 'resolves every key through Get-PcxText in English' {
        $report = & $script:NewReport -Findings @((New-TestFinding -Section 'power' -Id 'power-plan' -Severity 'warn' -Group 'safe' -ActionId 'power-plan' -Hint 'column.recommendation'))
        $document = & $script:ToDocument -Report $report -Language 'en'

        [string]$document.language | Should -BeExactly 'en'
        @($document.sections).Count | Should -Be 13
        [string]$document.sections[0].id | Should -BeExactly 'platform'
        $item = $document.findings[0]
        [string]$item.sectionTitle | Should -BeExactly (& $script:GetText -Key 'section.power' -Language 'en')
        [string]$item.severityLabel | Should -BeExactly (& $script:GetText -Key 'severity.warn' -Language 'en')
        [string]$item.title | Should -BeExactly (& $script:GetText -Key 'column.what' -Language 'en')
        [string]$item.detail | Should -BeExactly (& $script:GetText -Key 'column.evidence' -Language 'en')
        [string]$item.whyItMatters | Should -BeExactly (& $script:GetText -Key 'column.stops' -Language 'en')
        [string]$item.actionHint | Should -BeExactly (& $script:GetText -Key 'column.recommendation' -Language 'en')
        [string]$item.groupLabel | Should -BeExactly (& $script:GetText -Key 'group.safe' -Language 'en')
    }

    It 'renders Russian titles and appends extension sections with the bare suffix' {
        $report = & $script:NewReport -Findings @((New-TestFinding -Section 'extension:usb-errors' -Id 'usb-errors' -Group $null))
        $document = & $script:ToDocument -Report $report -Language 'ru'

        @($document.sections).Count | Should -Be 14
        [string]$document.sections[13].id | Should -BeExactly 'extension:usb-errors'
        [string]$document.sections[13].title | Should -BeExactly 'usb-errors'
        [string]$document.findings[0].sectionTitle | Should -BeExactly 'usb-errors'
        [string]$document.sections[0].title | Should -BeExactly (& $script:GetText -Key 'section.platform' -Language 'ru')
        [string]$document.sections[0].title | Should -Not -BeExactly (& $script:GetText -Key 'section.platform' -Language 'en')
    }

    It 'keeps evidence bytes stable across languages' {
        $report = & $script:NewReport -Findings @((New-TestFinding))
        $en = & $script:ToDocument -Report $report -Language 'en'
        $ru = & $script:ToDocument -Report $report -Language 'ru'

        $enEvidence = & $script:ToCanonical -InputObject $en.findings[0].evidence
        $ruEvidence = & $script:ToCanonical -InputObject $ru.findings[0].evidence
        $enEvidence | Should -BeExactly $ruEvidence
    }

    It 'throws PCX-E-TEXT for a key the dictionary does not carry' {
        $finding = & $script:NewFinding -Section 'platform' -Id 'bad-key' -Severity 'info' `
            -TitleKey 'nope.missing' -DetailKey 'column.evidence' `
            -Evidence (New-TestEvidence) -Group $null
        $report = & $script:NewReport -Findings @($finding)
        { & $script:ToDocument -Report $report -Language 'en' } | Should -Throw '*PCX-E-TEXT*'
    }
}

Describe 'pcx finding group map' {
    It 'accepts a consistent finding/action pair' {
        $finding = New-TestFinding -Section 'gaming' -Id 'game-dvr' -Group 'performance' -ActionId 'game-dvr' -Hint 'column.recommendation'
        $actions = @(
            [ordered]@{ id = 'game-dvr'; group = 'performance'; findingId = 'game-dvr' }
        )
        @( & $script:TestMap -Findings @($finding) -Actions $actions ).Count | Should -Be 0
    }

    It 'rejects a group mismatch between finding and action' {
        $finding = New-TestFinding -Section 'gaming' -Id 'game-dvr' -Group 'safe' -ActionId 'game-dvr' -Hint 'column.recommendation'
        $actions = @([ordered]@{ id = 'game-dvr'; group = 'performance' })
        @( & $script:TestMap -Findings @($finding) -Actions $actions ).Count | Should -BeGreaterThan 0
    }

    It 'rejects an actionId with no catalog action' {
        $finding = New-TestFinding -Group 'safe' -ActionId 'ghost' -Hint 'column.recommendation'
        @( & $script:TestMap -Findings @($finding) -Actions @([ordered]@{ id = 'other'; group = 'safe' }) ).Count | Should -BeGreaterThan 0
    }

    It 'rejects an action findingId that resolves to no finding' {
        $finding = New-TestFinding
        $actions = @([ordered]@{ id = 'game-dvr'; group = 'safe'; findingId = 'ghost' })
        @( & $script:TestMap -Findings @($finding) -Actions $actions ).Count | Should -BeGreaterThan 0
    }

    It 'rejects an action findingId that resolves to a good finding' {
        $good = New-TestFinding -Severity 'good' -AlreadyGood:$true -Group $null -Id 'all-good'
        $actions = @([ordered]@{ id = 'polish'; group = 'safe'; findingId = 'all-good' })
        @( & $script:TestMap -Findings @($good) -Actions $actions ).Count | Should -BeGreaterThan 0
    }

    It 'rejects a duplicate section/id pair' {
        $findings = @((New-TestFinding -Id 'dup'), (New-TestFinding -Id 'dup'))
        @( & $script:TestMap -Findings $findings ).Count | Should -BeGreaterThan 0
    }

    It 'rejects a raw action-carrying finding with a good severity' {
        $raw = [ordered]@{
            section = 'platform'; id = 'raw-good'; severity = 'good'; actionId = 'game-dvr'; group = 'safe'
        }
        @( & $script:TestMap -Findings @($raw) ).Count | Should -BeGreaterThan 0
    }
}
