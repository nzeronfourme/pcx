<#
.SYNOPSIS
    One proposal table for `tune --table`: four columns, continuous numbers.

.DESCRIPTION
    The report is a single Markdown table:
    `# | Category | What is proposed | What you get`.
    Diagnostic sections, the build caveat and the how-to-run column are
    intentionally absent; the agent reads data.diagnostics and writes its own
    findings. This file stays ASCII and resolves every localized expectation
    at runtime through Get-PcxText.
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
    $script:Table = $script:Module.ExportedCommands['Invoke-PcxTable']
    $script:Plan = $script:Module.ExportedCommands['Invoke-PcxPlan']
    $script:Tune = $script:Module.ExportedCommands['Invoke-PcxTune']
    $script:Scan = $script:Module.ExportedCommands['Get-PcxScan']
    $script:GetCatalog = $script:Module.ExportedCommands['Get-PcxCatalog']
    $script:Catalog = & $script:GetCatalog
    $script:GetText = $script:Module.ExportedCommands['Get-PcxText']

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:ManagedFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'managed'
    $script:SModeFixture = Join-Path -Path $script:FixtureRoot -ChildPath 's-mode'
    $script:DesktopMachine = Join-Path -Path $script:DesktopFixture -ChildPath 'machine.json'
    $script:TableSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Commands/Invoke-PcxTable.ps1'

    $script:RiskOrder = @('safe', 'behavior', 'risky')
    $script:RiskIcons = @{
        'safe'     = [char]::ConvertFromUtf32(0x1F7E2)
        'behavior' = [char]::ConvertFromUtf32(0x1F7E0)
        'risky'    = [char]::ConvertFromUtf32(0x1F534)
    }

    # A deterministic platform state: the table reads every cleanup and manual
    # target through the adapter, so absent files must be absent in the fixture
    # and measured sizes must not depend on the developer's machine.
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE
    $script:StateFile = Join-Path -Path $TestDrive -ChildPath 'table-state.json'

    function New-PcxTablePlatformState {
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [switch] $Empty
        )

        $files = [ordered]@{}
        if (-not $Empty) {
            $localAppData = 'c:\users\tester\appdata\local'
            $roaming = 'c:\users\tester\appdata\roaming'
            $appendFile = {
                param([string] $TargetPath)
                $files[$TargetPath] = [ordered]@{
                    path           = $TargetPath
                    attributes     = 'Archive'
                    isReparsePoint = $false
                    sizeBytes      = 200MB
                }
            }

            foreach ($size in @(32, 96, 256, 1024)) {
                & $appendFile "$localAppData\microsoft\windows\explorer\thumbcache_$size.db"
            }
            foreach ($size in @(16, 32, 48, 96, 256, 1024)) {
                & $appendFile "$localAppData\microsoft\windows\explorer\iconcache_$size.db"
            }
            & $appendFile "$localAppData\microsoft\windows\explorer\iconcache_idx.db"
            & $appendFile "$roaming\microsoft\windows\start menu\programs\startup\onedrive.lnk"

            foreach ($directory in @(
                    'c:\windows\serviceprofiles\networkservice\appdata\local\microsoft\windows\deliveryoptimization\cache'
                    'c:\windows\softwaredistribution\download'
                    'c:\windows.old'
                    'c:\programdata\microsoft\windows\wer'
                    "$localAppData\microsoft\windows\wer"
                    "$localAppData\temp"
                )) {
                $files[$directory] = [ordered]@{
                    path           = $directory
                    attributes     = 'Directory'
                    isReparsePoint = $false
                    sizeBytes      = 2GB
                }
            }

            $files['c:\hiberfil.sys'] = [ordered]@{
                path           = 'c:\hiberfil.sys'
                attributes     = 'Archive'
                isReparsePoint = $false
                sizeBytes      = 4GB
            }
        }

        $services = [ordered]@{
            diagtrack = [ordered]@{ name = 'DiagTrack'; controlSet = 'ControlSet001'; start = 2 }
            spooler   = [ordered]@{ name = 'Spooler'; controlSet = 'ControlSet001'; start = 2 }
        }
        $tasks = [ordered]@{
            '\startup\example app' = [ordered]@{ path = '\startup\example app'; enabled = $true; state = 'Ready' }
        }
        if ($Empty) {
            $services = [ordered]@{}
            $tasks = [ordered]@{}
        }

        $state = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = @{}
            services = $services
            tasks    = $tasks
            files    = $files
        }

        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $state -Depth 8), $utf8)
        return $Path
    }

    $null = New-PcxTablePlatformState -Path $script:StateFile
    $env:PCX_TEST_STATE_FILE = $script:StateFile

    function Get-PcxTableNumberList {
        param([Parameter(Mandatory = $true)][string] $Text)

        $numbers = New-Object System.Collections.Generic.List[int]
        foreach ($match in [regex]::Matches($Text, '(?m)^\| ([0-9]+) \|')) {
            [void]$numbers.Add([int]$match.Groups[1].Value)
        }
        return ,([int[]]$numbers.ToArray())
    }

    function Get-PcxTableRowCells {
        param(
            [Parameter(Mandatory = $true)][string] $Text,
            [Parameter(Mandatory = $true)][int] $Number
        )

        $line = @($Text -split "`n" | Where-Object { $_ -match ('^\| ' + $Number + ' \|') })
        if ($line.Count -ne 1) { throw "row $Number must appear exactly once." }
        return ,([string[]]@($line[0] -split '(?<!\\)\|'))
    }

    function Get-PcxTableRows {
        param([Parameter(Mandatory = $true)][object] $Rendered)

        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($group in $Rendered.groups.Values) {
            foreach ($row in $group.rows) {
                [void]$rows.Add($row)
            }
        }
        return ,([object[]]$rows.ToArray())
    }

    function New-PcxSyntheticPerformanceScan {
        $environment = Get-Content -LiteralPath $script:DesktopMachine -Raw | ConvertFrom-Json
        $metrics = @(
            [ordered]@{ id = 'performance.hags_mode'; group = 'performance'; status = 'measured'; value = 1; unit = 'number'; domain = 'performance'; window = 'instant'; source = 'test' }
            [ordered]@{ id = 'performance.game_dvr_enabled'; group = 'performance'; status = 'measured'; value = $true; unit = 'bool'; domain = 'performance'; window = 'instant'; source = 'test' }
        )

        return [ordered]@{
            metrics     = $metrics
            environment = $environment
        }
    }

    function New-PcxTableEnvironment {
        param([Parameter(Mandatory = $false)][int] $Build = 22631)

        $environment = Get-Content -LiteralPath $script:DesktopMachine -Raw | ConvertFrom-Json
        $environment.os.build.value = $Build
        return $environment
    }
}

Describe 'proposal table surface' {

    It 'exports Invoke-PcxTable' {
        ($null -ne $script:Table) | Should -BeTrue
        $script:Module.ExportedCommands.ContainsKey('Invoke-PcxTable') | Should -BeTrue
    }

    It 'declares Markdown only: no HTML or forms' {
        $source = [System.IO.File]::ReadAllText($script:TableSourcePath)
        $source | Should -Not -Match '(?i)<html|<form|<table'
    }

    It 'stays ASCII-only so 5.1 reads it without a BOM' {
        $bytes = [System.IO.File]::ReadAllBytes($script:TableSourcePath)
        foreach ($byte in $bytes) {
            $byte | Should -BeLessOrEqual 127
        }
    }

    It 'returns a valid envelope with table, findings, diagnostics and groups' {
        $run = & $script:Tune -Arguments @('--lang', 'ru', '--fixture', $script:DesktopFixture, '--table')
        [int]$run.ExitCode | Should -Be 0
        $run.Envelope.status | Should -Be 'ok'
        [string]$run.Envelope.data.language | Should -BeExactly 'ru'

        foreach ($key in @('table', 'findings', 'groups', 'metrics', 'diagnostics')) {
            @($run.Envelope.data.Keys) -contains $key | Should -BeTrue -Because "data.$key must stay available to the agent"
        }
        [string]::IsNullOrWhiteSpace([string]$run.Envelope.data.table) | Should -BeFalse
    }
}

Describe 'one proposal table' {

    BeforeAll {
        $script:Ru = & $script:Tune -Arguments @('--lang', 'ru', '--fixture', $script:DesktopFixture, '--table')
        $script:RuText = [string]$script:Ru.Envelope.data.table
        $script:RuRows = @($script:Ru.Envelope.data.findings)

        $script:En = & $script:Tune -Arguments @('--lang', 'en', '--fixture', $script:DesktopFixture, '--table')
        $script:EnText = [string]$script:En.Envelope.data.table
    }

    It 'renders exactly one Markdown table with four columns' {
        $headerLines = @($script:RuText -split "`n" | Where-Object { $_ -match '^\| .*\|$' -and $_ -notmatch '^\|---' })
        $headerLines.Count | Should -BeGreaterThan 0
        $cells = @($headerLines[0] -split '(?<!\\)\|')
        ($cells.Count - 2) | Should -Be 4 -Because 'one table carries exactly four columns'

        @($script:RuText -split "`n" | Where-Object { $_ -match '^\|---' }).Count | Should -Be 1
    }

    It 'prints no diagnostics blocks, summary or build caveat' {
        $script:RuText | Should -Not -Match '(?m)^### '
        $script:RuText | Should -Not -Match '(?m)^_'
        foreach ($key in @('heading.attention', 'heading.notes', 'heading.good', 'heading.nodata')) {
            $text = & $script:GetText -Key $key -Language 'ru'
            $script:RuText | Should -Not -Match ([regex]::Escape($text))
        }
    }

    It 'numbers every row 1..N in display order without gaps' {
        $numbers = Get-PcxTableNumberList -Text $script:RuText
        $numbers.Count | Should -Be $script:RuRows.Count
        ($numbers -join ',') | Should -Be ((1..$script:RuRows.Count) -join ',')
    }

    It 'puts every catalog row into the table exactly once' {
        foreach ($row in $script:RuRows) {
            $cells = Get-PcxTableRowCells -Text $script:RuText -Number ([int]$row.number)
            $cells.Count | Should -Be 6 -Because 'four columns split into six pipe segments'
        }
    }

    It 'labels each row with its risk icon and label' {
        foreach ($row in $script:RuRows) {
            $cells = Get-PcxTableRowCells -Text $script:RuText -Number ([int]$row.number)
            $label = & $script:GetText -Key ('risk.' + [string]$row.risk) -Language 'ru'
            $expected = $script:RiskIcons[[string]$row.risk] + ' ' + $label
            ([string]$cells[2]).Trim() | Should -BeExactly $expected
        }
    }

    It 'orders rows from safe to risky' {
        $ranks = @()
        foreach ($row in $script:RuRows) {
            $ranks += $script:RiskOrder.IndexOf([string]$row.risk)
        }
        for ($i = 1; $i -lt $ranks.Count; $i++) {
            $ranks[$i] | Should -BeGreaterOrEqual $ranks[$i - 1] -Because 'risk levels never go backwards'
        }
    }

    It 'gives every row a proposal and an outcome' {
        foreach ($row in $script:RuRows) {
            $cells = Get-PcxTableRowCells -Text $script:RuText -Number ([int]$row.number)
            [string]::IsNullOrWhiteSpace(([string]$cells[3]).Trim()) | Should -BeFalse -Because "row $($row.number) needs a proposal"
            [string]::IsNullOrWhiteSpace(([string]$cells[4]).Trim()) | Should -BeFalse -Because "row $($row.number) needs an outcome"
        }
    }

    It 'proposes a short action and states the measured size in the outcome' {
        $thumb = @($script:RuRows | Where-Object { [string]$_.id -eq 'thumbnails' })[0]
        $cells = Get-PcxTableRowCells -Text $script:RuText -Number ([int]$thumb.number)
        $proposal = ([string]$cells[3]).Trim()
        $outcome = ([string]$cells[4]).Trim()

        $full = [string]$thumb.whatItDoes
        $proposal.Length | Should -BeLessThan $full.Length -Because 'the proposal is the short first sentence'
        $gb = & $script:GetText -Key 'unit.gb' -Language 'ru'
        $proposal | Should -Not -Match ([regex]::Escape($gb)) -Because 'the measured size belongs to the outcome'

        $freeTemplate = & $script:GetText -Key 'fact.frees' -Language 'ru'
        $freePrefix = $freeTemplate.Substring(0, $freeTemplate.IndexOf('{0}'))
        $outcome | Should -Match ([regex]::Escape($freePrefix))
    }

    It 'states a measured size on every Safe row, catalog or manual' {
        $freeTemplate = & $script:GetText -Key 'fact.frees' -Language 'ru'
        $freePrefix = $freeTemplate.Substring(0, $freeTemplate.IndexOf('{0}'))
        foreach ($row in @($script:RuRows | Where-Object { [string]$_.group -eq 'safe' })) {
            $cells = Get-PcxTableRowCells -Text $script:RuText -Number ([int]$row.number)
            ([string]$cells[4]).Trim().StartsWith($freePrefix) | Should -BeTrue -Because "safe row $($row.number) must state the gain"
        }
    }

    It 'gives every manual row a measured size, its own effect and rollback' {
        foreach ($row in @($script:RuRows | Where-Object { [string]$_.source -eq 'manual' -and [string]$_.group -eq 'manual' })) {
            $entry = @($script:Catalog.manual | Where-Object { $_.id -eq $row.id })[0]
            $expected = [string]$entry.outcome_ru
            [string]::IsNullOrWhiteSpace($expected) | Should -BeFalse -Because "manual entry '$($row.id)' needs an outcome"

            $freeTemplate = & $script:GetText -Key 'fact.frees' -Language 'ru'
            $freePrefix = $freeTemplate.Substring(0, $freeTemplate.IndexOf('{0}'))
            $cells = Get-PcxTableRowCells -Text $script:RuText -Number ([int]$row.number)
            $outcome = ([string]$cells[4]).Trim()
            $outcome.StartsWith($freePrefix) | Should -BeTrue -Because "manual row '$($row.id)' states the measured size"
            $outcome.EndsWith($expected) | Should -BeTrue -Because "manual row '$($row.id)' keeps its effect and rollback"
        }
    }

    It 'does not print how-to-run commands or a build caveat' {
        $script:RuText | Should -Not -Match 'pcx tune --apply'
        $script:RuText | Should -Not -Match '(?i)how to run'
        $script:RuText | Should -Not -Match '(?i)not verified'
    }

    It 'contains no raw JSON or machine source labels' {
        $script:RuText | Should -Not -Match '\{'
        $script:RuText | Should -Not -Match '"source":'
        $script:RuText | Should -Not -Match 'fixture:'
    }

    It 'keeps the ru headers Russian and the en headers English' {
        foreach ($key in @('column.number', 'column.category', 'column.proposal', 'column.outcome')) {
            $script:RuText | Should -Match ([regex]::Escape((& $script:GetText -Key $key -Language 'ru')))
            $script:EnText | Should -Match ([regex]::Escape((& $script:GetText -Key $key -Language 'en')))
        }

        $enProposal = & $script:GetText -Key 'column.proposal' -Language 'en'
        $ruProposal = & $script:GetText -Key 'column.proposal' -Language 'ru'
        $script:RuText | Should -Not -Match ([regex]::Escape($enProposal))
        $script:EnText | Should -Not -Match ([regex]::Escape($ruProposal))
    }

    It 'keeps the numbers identical between en and ru' {
        $ruNumbers = Get-PcxTableNumberList -Text $script:RuText
        $enNumbers = Get-PcxTableNumberList -Text $script:EnText
        ($ruNumbers -join ',') | Should -Be ($enNumbers -join ',')
    }
}

Describe 'manual and don''t-touch entries' {

    BeforeAll {
        $script:EntryRun = & $script:Tune -Arguments @('--lang', 'en', '--fixture', $script:DesktopFixture, '--table')
        $script:EntryRows = @($script:EntryRun.Envelope.data.findings)
        $script:EntryText = [string]$script:EntryRun.Envelope.data.table
    }

    It 'renders exactly the four measurable manual entries' {
        foreach ($id in @('windows-old', 'wer', 'temp', 'hiberfil')) {
            $rows = @($script:EntryRows | Where-Object { [string]$_.id -eq $id })
            $rows.Count | Should -Be 1 -Because "measured manual entry '$id' must render exactly once"
        }
    }

    It 'never renders an unmeasurable manual proposal' {
        foreach ($id in @('pagefile', 'move-games', 'restore-points', 'windows-update', 'bios-driver-age')) {
            @($script:EntryRows | Where-Object { [string]$_.id -eq $id }).Count | Should -Be 0 -Because "'$id' has no measured target and is not a row"
            $script:EntryText | Should -Not -Match ([regex]::Escape($id))
        }
    }

    It 'names the concrete target on every manual row' {
        foreach ($row in @($script:EntryRows | Where-Object { [string]$_.source -eq 'manual' })) {
            [string]$row.target | Should -Match '^[A-Za-z]:\\' -Because "manual row '$($row.id)' must name the measured path"
            [string]$row.evidence | Should -BeExactly 'measured = file size'
            [string]$row.recommendation | Should -Match '(?i)agent performs'
            [bool]$row.hidden | Should -BeFalse
        }
    }

    It 'names the hibernation file and its exact rollback' {
        $row = @($script:EntryRows | Where-Object { [string]$_.id -eq 'hiberfil' })[0]
        $cells = Get-PcxTableRowCells -Text $script:EntryText -Number ([int]$row.number)
        ([string]$cells[3]).Trim() | Should -Match 'hiberfil\.sys'
        ([string]$cells[4]).Trim() | Should -Match 'powercfg /h on'
    }

    It 'names the Startup shortcut it quarantines' {
        $row = @($script:EntryRows | Where-Object { [string]$_.id -eq 'startup-shortcut-u4' })[0]
        $cells = Get-PcxTableRowCells -Text $script:EntryText -Number ([int]$row.number)
        ([string]$cells[3]).Trim() | Should -Match 'OneDrive\.lnk'
    }

    It 'adds managed and S Mode findings to Don''t touch when present' {
        $managed = & $script:Table -Scan (& $script:Scan -FixturePath $script:ManagedFixture) -Catalog $script:Catalog
        $managedIds = @($managed.groups['Don''t touch'].rows | ForEach-Object { [string]$_.id })
        $managedIds -contains 'managed' | Should -BeTrue

        $sMode = & $script:Table -Scan (& $script:Scan -FixturePath $script:SModeFixture) -Catalog $script:Catalog
        $sModeIds = @($sMode.groups['Don''t touch'].rows | ForEach-Object { [string]$_.id })
        $sModeIds -contains 's-mode' | Should -BeTrue
    }
}

Describe 'performance rows' {

    It 'keeps the catalog promise disclaimer and never states FPS' {
        $rendered = & $script:Table -Scan (New-PcxSyntheticPerformanceScan) -Catalog $script:Catalog
        $rows = @($rendered.groups['Performance & latency'].rows)
        $rows.Count | Should -Be 2

        $disclaimer = & $script:GetText -Key 'outcome.performance' -Language 'en'
        $rendered.table | Should -Match ([regex]::Escape($disclaimer))
        $rendered.table | Should -Not -Match '\d+\s*%'
        $rendered.table | Should -Not -Match '(?i)fps'
    }
}

Describe 'risky rows' {

    It 'labels a risky row with the risky icon and label' {
        $entry = [pscustomobject]@{
            id          = 'temp'
            kind        = 'manual'
            risk        = 'risky'
            measure     = @([pscustomobject]@{ Kind = 'file'; Path = '%LOCALAPPDATA%\Temp' })
            user_text_ru = 'Clear temporary files'
            user_text_en = 'Clear temporary files'
            outcome_ru  = 'not reversible.'
            outcome_en  = 'not reversible.'
        }
        $catalog = [pscustomobject]@{ actions = @(); manual = @($entry) }

        $rendered = & $script:Table -Scan (& $script:Scan -FixturePath $script:DesktopFixture) -Catalog $catalog
        [int]$rendered.visibleRows.Count | Should -Be 1

        $label = & $script:GetText -Key 'risk.risky' -Language 'en'
        $rendered.table | Should -Match ([regex]::Escape($script:RiskIcons['risky'] + ' ' + $label))
    }
}

Describe 'main view completeness' {

    BeforeAll {
        $profile = [ordered]@{
            managed      = $true
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            serviceFacts = @{}
            environment  = [ordered]@{
                LOCALAPPDATA = 'C:\Users\tester\AppData\Local'
                APPDATA      = 'C:\Users\tester\AppData\Roaming'
                PROGRAMDATA  = 'C:\ProgramData'
                SYSTEMROOT   = 'C:\Windows'
            }
        }

        $script:ManagedProfilePath = Join-Path -Path $TestDrive -ChildPath 'managed-profile.json'
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:ManagedProfilePath, ($profile | ConvertTo-Json -Depth 8), $encoding)

        $script:OverflowScan = & $script:Scan -FixturePath $script:DesktopFixture
        $script:OverflowRendered = & $script:Table -Scan $script:OverflowScan -Catalog $script:Catalog -Profile $profile
        $script:OverflowTune = & $script:Tune -Arguments @('--lang', 'en', '--fixture', $script:DesktopFixture, '--profile', $script:ManagedProfilePath, '--table')
    }

    It 'shows every visible row with no hidden overflow' {
        $rows = @($script:OverflowTune.Envelope.data.findings)
        @($rows | Where-Object { $_.hidden -eq $true }).Count | Should -Be 0
        $script:OverflowRendered.truncated | Should -BeFalse

        $numbers = Get-PcxTableNumberList -Text ([string]$script:OverflowRendered.table)
        $numbers.Count | Should -Be $rows.Count
        ($numbers -join ',') | Should -Be ((1..$rows.Count) -join ',')
    }
}

Describe 'table and plan build coherence' {

    BeforeAll {
        $script:CoherenceScan = & $script:Scan -FixturePath $script:DesktopFixture
        $script:Env22631 = New-PcxTableEnvironment -Build 22631
        $script:Env17763 = New-PcxTableEnvironment -Build 17763

        $script:CoherenceRendered = & $script:Table -Scan $script:CoherenceScan -Catalog $script:Catalog -Profile $script:Env22631
        $script:CoherenceRows = Get-PcxTableRows -Rendered $script:CoherenceRendered
        $script:SelectableRows = @($script:CoherenceRows | Where-Object { [string]$_.source -eq 'catalog' })

        $script:Selection = (@($script:SelectableRows | ForEach-Object { [int]$_.number }) -join ',')
        $script:CoherencePlan = & $script:Plan -Selection $script:Selection -Scan $script:CoherenceScan -Profile $script:Env22631 -DryRun
    }

    It 'renders as selectable exactly the rows the plan accepts on 22631' {
        $script:SelectableRows.Count | Should -BeGreaterThan 0

        @($script:CoherencePlan.refused).Count | Should -Be 0
        @($script:CoherencePlan.demoted).Count | Should -Be 0
        @($script:CoherencePlan.items).Count | Should -Be $script:SelectableRows.Count

        $tableIds = @($script:SelectableRows | ForEach-Object { [string]$_.id } | Sort-Object)
        $planIds = @($script:CoherencePlan.items | ForEach-Object { [string]$_.actionId } | Sort-Object)
        ($tableIds -join ',') | Should -Be ($planIds -join ',')
    }

    It 'renders no selectable row on an unsupported build' {
        $rendered = & $script:Table -Scan $script:CoherenceScan -Catalog $script:Catalog -Profile $script:Env17763
        $rows = Get-PcxTableRows -Rendered $rendered
        $demoted = @($rows | Where-Object { [string]$_.source -eq 'demoted' })

        @($rows | Where-Object { [string]$_.source -eq 'catalog' }).Count | Should -Be 0
        $demoted.Count | Should -BeGreaterThan 0
        foreach ($row in $demoted) {
            $row.group | Should -Be 'manual'
        }
    }

    It 'refuses a plan selection on an unsupported build instead of accepting it' {
        $plan = & $script:Plan -Selection ([string]$script:SelectableRows[0].number) -Scan $script:CoherenceScan -Profile $script:Env17763 -DryRun

        @($plan.items | Where-Object { $null -ne $_ }).Count | Should -Be 0
        @($plan.refused).Count | Should -Be 1
        [string]$plan.refused[0].code | Should -Be 'PCX-E-PLAN-NOT-APPLYABLE'
    }
}

Describe 'absent and empty targets' {

    It 'never prints a row for a missing folder, an empty cache or a missing shortcut' {
        $previousStateFile = $env:PCX_TEST_STATE_FILE
        try {
            $emptyState = Join-Path -Path $TestDrive -ChildPath 'empty-state.json'
            $null = New-PcxTablePlatformState -Path $emptyState -Empty
            $env:PCX_TEST_STATE_FILE = $emptyState

            $run = & $script:Tune -Arguments @('--lang', 'ru', '--fixture', $script:DesktopFixture, '--table')
            [int]$run.ExitCode | Should -Be 0
            $rows = @($run.Envelope.data.findings)
            $text = [string]$run.Envelope.data.table

            foreach ($id in @('thumbnails', 'icon-cache', 'delivery-optimization-cache', 'windows-update-download-cache', 'windows-old', 'wer', 'temp', 'hiberfil', 'startup-shortcut-u4', 'startup-task-u4')) {
                @($rows | Where-Object { [string]$_.id -eq $id }).Count | Should -Be 0 -Because "'$id' has no target on this machine"
            }

            $text | Should -Not -Match 'Windows\.old'
            $text | Should -Not -Match 'thumbcache'
            $text | Should -Not -Match '(?i)hiberfil'
        }
        finally {
            $env:PCX_TEST_STATE_FILE = $previousStateFile
        }
    }
}

Describe 'already satisfied targets' {

    It 'hides a service row that already holds the target state' {
        $action = @($script:Catalog.actions | Where-Object { [string]$_.id -eq 'spooler-no-printers' })[0]
        $catalog = [pscustomobject]@{ actions = @($action); manual = @() }
        $scan = [ordered]@{
            environment = (Get-Content -LiteralPath $script:DesktopMachine -Raw | ConvertFrom-Json)
            metrics     = @([ordered]@{
                    id     = 'printers.count'
                    group  = 'printers'
                    status = 'measured'
                    value  = 0
                    unit   = 'count'
                    domain = 'printers'
                    window = 'instant'
                    source = 'test'
                })
        }
        # The blast-radius rule needs proven service facts; a profile without
        # them demotes the row, which is a different test.
        $profile = [ordered]@{
            managed      = $false
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            serviceFacts = @{ spooler = @{ dependents = 0; listeningPorts = 0; childProcesses = 0 } }
            environment  = [ordered]@{
                LOCALAPPDATA = 'C:\Users\tester\AppData\Local'
                APPDATA      = 'C:\Users\tester\AppData\Roaming'
                PROGRAMDATA  = 'C:\ProgramData'
                SYSTEMROOT   = 'C:\Windows'
            }
        }

        $enabledRun = & $script:Table -Scan $scan -Catalog $catalog -Profile $profile
        @($enabledRun.visibleRows | Where-Object { [string]$_.id -eq 'spooler-no-printers' }).Count | Should -Be 1

        $previousStateFile = $env:PCX_TEST_STATE_FILE
        try {
            $disabledState = Join-Path -Path $TestDrive -ChildPath 'spooler-disabled-state.json'
            $null = New-PcxTablePlatformState -Path $disabledState
            $document = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($disabledState))
            $document.services.spooler.start = 4
            $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
            [System.IO.File]::WriteAllText($disabledState, (ConvertTo-Json -InputObject $document -Depth 8), $utf8)
            $env:PCX_TEST_STATE_FILE = $disabledState

            $disabledRun = & $script:Table -Scan $scan -Catalog $catalog -Profile $profile
            @($disabledRun.visibleRows | Where-Object { [string]$_.id -eq 'spooler-no-printers' }).Count | Should -Be 0
        }
        finally {
            $env:PCX_TEST_STATE_FILE = $previousStateFile
        }
    }
}

Describe 'size floor' {

    It 'hides a measured target below 500 MB' {
        $previousStateFile = $env:PCX_TEST_STATE_FILE
        try {
            $smallState = Join-Path -Path $TestDrive -ChildPath 'small-target-state.json'
            $null = New-PcxTablePlatformState -Path $smallState
            $document = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($smallState))
            $document.files.'c:\windows\softwaredistribution\download'.sizeBytes = 8MB
            $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
            [System.IO.File]::WriteAllText($smallState, (ConvertTo-Json -InputObject $document -Depth 8), $utf8)
            $env:PCX_TEST_STATE_FILE = $smallState

            $run = & $script:Tune -Arguments @('--lang', 'en', '--fixture', $script:DesktopFixture, '--table')
            [int]$run.ExitCode | Should -Be 0
            $rows = @($run.Envelope.data.findings)
            @($rows | Where-Object { [string]$_.id -eq 'windows-update-download-cache' }).Count | Should -Be 0
            [string]$run.Envelope.data.table | Should -Not -Match '8 MB'
        }
        finally {
            $env:PCX_TEST_STATE_FILE = $previousStateFile
        }
    }
}

AfterAll {
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
}

