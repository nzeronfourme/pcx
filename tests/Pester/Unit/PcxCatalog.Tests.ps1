<#
.SYNOPSIS
    Seed catalog suite for todo 14: the 13-action catalog and its validator.

.DESCRIPTION
    Proves the shipped data (config/actions/*.json) validates, and that each
    rejection rule fires: category C, an id outside the allow-list, a duplicate
    id, a U4 action without positive usage evidence, a denied target, a
    wildcard target, an FPS claim in a performance action, and a manual entry
    that carries a target or an inverse. Also proves the build-family gate
    (win10, win11, unsupported) and the HAGS contract. The catalog is data:
    every target decision comes from Test-PcxTarget under a permissive
    validation profile.
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
    $script:GetCatalog = $script:Module.ExportedCommands['Get-PcxCatalog']
    $script:TestCatalogAction = $script:Module.ExportedCommands['Test-PcxCatalogAction']
    $script:TestMap = $script:Module.ExportedCommands['Test-PcxFindingGroupMap']
    $script:NewFinding = $script:Module.ExportedCommands['New-PcxFinding']
    $script:Catalog = & $script:GetCatalog

    function Copy-PcxCatalogActions {
        return @($script:Catalog.actions | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    }

    function Copy-PcxCatalogManual {
        return @($script:Catalog.manual | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    }

    function Get-PcxCatalogActionById {
        param([Parameter(Mandatory = $true)][string] $Id)
        return @($script:Catalog.actions | Where-Object { $_.id -eq $Id })[0]
    }

    function Invoke-PcxCatalogValidation {
        param(
            [Parameter(Mandatory = $true)][object] $Actions,
            [Parameter(Mandatory = $true)][object] $Manual
        )

        # The document validator is module-internal on purpose: the public
        # surface stays Get-PcxCatalog + Test-PcxCatalogAction. Synthetic
        # documents are validated through the same rules the loader uses.
        return & $script:Module {
            param($ActionSet, $ManualSet)
            Test-PcxCatalogDocument -Actions $ActionSet -Manual $ManualSet
        } $Actions $Manual
    }

    function Test-PcxCatalogErrorPresent {
        param(
            [Parameter(Mandatory = $true)][object] $Result,
            [Parameter(Mandatory = $true)][string] $Code
        )

        return (@($Result.errors | Where-Object { [string]$_ -like "*$Code*" }).Count -gt 0)
    }
}

Describe 'pcx seed catalog' {

    It 'loads without throwing' {
        { & $script:GetCatalog } | Should -Not -Throw
    }

    It 'exports exactly the loader and the build gate' {
        $null -eq $script:Module.ExportedCommands['Get-PcxCatalog'] | Should -BeFalse
        $null -eq $script:Module.ExportedCommands['Test-PcxCatalogAction'] | Should -BeFalse
    }

    It 'has exactly 13 applyable actions: 4 A1 + 9 B, no category C' {
        $script:Catalog.applyableCount | Should -Be 13
        @($script:Catalog.actions).Count | Should -Be 13
        $script:Catalog.categoryCounts.A1 | Should -Be 4
        $script:Catalog.categoryCounts.B | Should -Be 9
        $script:Catalog.categoryCounts.C | Should -Be 0

        @($script:Catalog.actions | Where-Object { $_.category -ne 'A1' -and $_.category -ne 'B' }).Count | Should -Be 0
    }

    It 'carries every required field on every action' {
        foreach ($action in $script:Catalog.actions) {
            foreach ($field in @('id', 'findingId', 'target', 'category', 'evidence_rule', 'verified_on_build', 'inverse', 'group', 'user_text_ru', 'user_text_en')) {
                $null -eq $action.PSObject.Properties[$field] | Should -BeFalse -Because "action '$($action.id)' must carry '$field'"
            }
        }
    }

    It 'keeps hags a performance B action with effect not promised' {
        $mode = Get-PcxCatalogActionById -Id 'hags'

        $mode.category | Should -Be 'B'
        $mode.group | Should -Be 'performance'
        $mode.inverse | Should -Be 'snapshot'
        [string]$mode.findingId | Should -BeExactly 'hags'
        $mode.user_text_en | Should -Match 'effect not promised'
        @($mode.target).Count | Should -Be 1
        [string]$mode.target[0].Path | Should -BeExactly 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        [string]$mode.target[0].Name | Should -BeExactly 'HwSchMode'
    }

    It 'gives every action an evidence rule and an inverse' {
        foreach ($action in $script:Catalog.actions) {
            $null -eq $action.evidence_rule | Should -BeFalse -Because "action '$($action.id)' needs an evidence rule"
            [string]::IsNullOrWhiteSpace([string]$action.evidence_rule.metric) | Should -BeFalse
            [string]::IsNullOrWhiteSpace([string]$action.evidence_rule.domain) | Should -BeFalse
            @('telemetry', 'state') -contains ([string]$action.evidence_rule.kind) | Should -BeTrue
            @('snapshot', 'manifest-only', 'quarantine') -contains ([string]$action.inverse) | Should -BeTrue
        }
    }

    It 'has no target denied by Test-PcxTarget' {
        # Get-PcxCatalog itself feeds every target through Test-PcxTarget with
        # a permissive desktop profile and throws on a denial.
        { & $script:GetCatalog } | Should -Not -Throw

        $result = Invoke-PcxCatalogValidation -Actions $script:Catalog.actions -Manual $script:Catalog.manual
        $result.valid | Should -BeTrue
        Test-PcxCatalogErrorPresent -Result $result -Code 'TARGET-DENIED' | Should -BeFalse
    }

    It 'never uses a wildcard in a target' {
        foreach ($action in $script:Catalog.actions) {
            foreach ($target in @($action.target)) {
                foreach ($property in $target.PSObject.Properties) {
                    if ($property.Value -is [string]) {
                        $property.Value.Contains('*') | Should -BeFalse -Because "action '$($action.id)' must not use a wildcard"
                        $property.Value.Contains('?') | Should -BeFalse -Because "action '$($action.id)' must not use a wildcard"
                    }
                }
            }
        }
    }

    It 'keeps A1 inverses manifest-only and the startup shortcut quarantined' {
        foreach ($action in $script:Catalog.actions) {
            if ($action.category -eq 'A1') {
                $action.inverse | Should -Be 'manifest-only'
            }
            if ($action.id -eq 'startup-shortcut-u4') {
                $action.inverse | Should -Be 'quarantine'
            }
        }
    }

    It 'keeps manual entries display-only with no target and no inverse' {
        $script:Catalog.manualCount | Should -Be 8
        foreach ($entry in $script:Catalog.manual) {
            @('manual', 'dont-touch') -contains ([string]$entry.kind) | Should -BeTrue
            $null -eq $entry.PSObject.Properties['target'] | Should -BeTrue -Because "manual entry '$($entry.id)' must not carry a target"
            $null -eq $entry.PSObject.Properties['inverse'] | Should -BeTrue -Because "manual entry '$($entry.id)' must not carry an inverse"
        }

        @($script:Catalog.manual | Where-Object { $_.kind -eq 'manual' } | ForEach-Object { $_.id } | Sort-Object) |
            Should -Be @('hiberfil', 'temp', 'wer', 'windows-old')
        @($script:Catalog.manual | Where-Object { $_.kind -eq 'dont-touch' } | ForEach-Object { $_.id } | Sort-Object) |
            Should -Be @('anticheat', 'defender-exclusions', 'vbs', 'vbs-hvci')
    }

    It 'gives every printed manual entry a concrete measure target' {
        foreach ($entry in @($script:Catalog.manual | Where-Object { $_.kind -eq 'manual' })) {
            @($entry.measure).Count | Should -BeGreaterThan 0 -Because "manual entry '$($entry.id)' must be measurable"
            foreach ($target in @($entry.measure)) {
                [string]$target.Kind | Should -BeExactly 'file'
                [string]$target.Path | Should -Match '^%[A-Za-z0-9_]+%\\'
            }
            [string]::IsNullOrWhiteSpace([string]$entry.outcome_ru) | Should -BeFalse
            [string]::IsNullOrWhiteSpace([string]$entry.outcome_en) | Should -BeFalse
        }

        foreach ($entry in @($script:Catalog.manual | Where-Object { $_.kind -eq 'dont-touch' })) {
            $null -eq $entry.PSObject.Properties['measure'] | Should -BeTrue -Because "dont-touch entry '$($entry.id)' is knowledge only"
        }
    }

    It 'pins only the 24H2/25H2 builds' {
        foreach ($action in $script:Catalog.actions) {
            @($action.verified_on_build).Count | Should -BeGreaterThan 0
            foreach ($build in @($action.verified_on_build)) {
                @(26100, 26200) -contains ([int]$build) | Should -BeTrue -Because "action '$($action.id)' pins build '$build'"
            }
        }
    }
}

Describe 'pcx catalog rejections' {

    It 'rejects a category C action' {
        $actions = Copy-PcxCatalogActions
        ($actions | Where-Object { $_.id -eq 'tips' })[0].category = 'C'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-CATEGORY' | Should -BeTrue
        ($result.errors -join "`n") | Should -Match "category 'C'"
    }

    It 'rejects an action id outside the allow-list' {
        $actions = Copy-PcxCatalogActions
        ($actions | Where-Object { $_.id -eq 'thumbnails' })[0].id = 'download-more-ram'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-ID-ALLOW-LIST' | Should -BeTrue
    }

    It 'rejects a duplicate action id' {
        $actions = Copy-PcxCatalogActions
        ($actions | Where-Object { $_.id -eq 'hags' })[0].id = 'game-dvr'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-DUPLICATE' | Should -BeTrue
    }

    It 'rejects a U4 action without positive usage evidence' {
        $actions = Copy-PcxCatalogActions
        $u4 = ($actions | Where-Object { $_.id -eq 'diagtrack-u4' })[0]
        $u4.evidence_rule.metric = 'storage.system_free_bytes'
        $u4.evidence_rule.domain = 'storage'
        $u4.evidence_rule.predicate = 'at-least:1'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-U4-EVIDENCE' | Should -BeTrue
    }

    It 'rejects a U4 action that does not require positive usage' {
        $actions = Copy-PcxCatalogActions
        $u4 = ($actions | Where-Object { $_.id -eq 'startup-task-u4' })[0]
        $u4.evidence_rule.predicate = 'at-least:0'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-U4-EVIDENCE' | Should -BeTrue
    }

    It 'rejects a performance action with a numeric FPS claim' {
        $actions = Copy-PcxCatalogActions
        $performance = ($actions | Where-Object { $_.id -eq 'game-dvr' })[0]
        $performance.user_text_en = $performance.user_text_en + ' Up to 20% FPS boost.'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-PERF-FPS' | Should -BeTrue
    }

    It 'rejects a performance action without effect-not-promised text' {
        $actions = Copy-PcxCatalogActions
        $performance = ($actions | Where-Object { $_.id -eq 'hags' })[0]
        $performance.user_text_en = 'Turn HAGS on. DLSS Frame Generation needs it.'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-PERF-PROMISE' | Should -BeTrue
    }

    It 'rejects a denied target' {
        $actions = Copy-PcxCatalogActions
        $thumbnails = ($actions | Where-Object { $_.id -eq 'thumbnails' })[0]
        $thumbnails.target[0].Path = 'C:\Users\pcx\Documents\not-a-cache.txt'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-TARGET-DENIED' | Should -BeTrue
    }

    It 'rejects a wildcard target' {
        $actions = Copy-PcxCatalogActions
        $thumbnails = ($actions | Where-Object { $_.id -eq 'thumbnails' })[0]
        $thumbnails.target[0].Path = '%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-WILDCARD' | Should -BeTrue
    }

    It 'rejects a manual entry that carries a target' {
        $manual = Copy-PcxCatalogManual
        ($manual | Where-Object { $_.id -eq 'windows-old' })[0] | Add-Member -NotePropertyName 'target' -NotePropertyValue 'reg:HKCU\Software\Foo::Bar'

        $result = Invoke-PcxCatalogValidation -Actions $script:Catalog.actions -Manual $manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-MANUAL-TARGET' | Should -BeTrue
    }

    It 'rejects a manual entry that carries an inverse' {
        $manual = Copy-PcxCatalogManual
        ($manual | Where-Object { $_.id -eq 'wer' })[0] | Add-Member -NotePropertyName 'inverse' -NotePropertyValue 'snapshot'

        $result = Invoke-PcxCatalogValidation -Actions $script:Catalog.actions -Manual $manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-MANUAL-INVERSE' | Should -BeTrue
    }

    It 'rejects a printed manual entry without a measure block' {
        $manual = Copy-PcxCatalogManual
        $entry = ($manual | Where-Object { $_.id -eq 'windows-old' })[0]
        $entry.PSObject.Properties.Remove('measure')

        $result = Invoke-PcxCatalogValidation -Actions $script:Catalog.actions -Manual $manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-MANUAL-MEASURE' | Should -BeTrue
    }

    It 'rejects a manual measure target with a wildcard' {
        $manual = Copy-PcxCatalogManual
        $entry = ($manual | Where-Object { $_.id -eq 'temp' })[0]
        $entry.measure[0].Path = '%LOCALAPPDATA%\\Temp\\*'

        $result = Invoke-PcxCatalogValidation -Actions $script:Catalog.actions -Manual $manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-MANUAL-MEASURE' | Should -BeTrue
    }

    It 'fails the loader when the catalog path is missing' {
        { & $script:GetCatalog -Path 'C:\pcx-no-such-catalog-path' } | Should -Throw
    }
}

Describe 'pcx catalog provenance' {

    BeforeAll {
        function New-PcxCatalogProvenanceFinding {
            param(
                [Parameter(Mandatory = $true)][string] $Id,
                [Parameter(Mandatory = $false)][string] $Severity = 'info'
            )

            $evidence = [ordered]@{
                metric = 'test.metric'
                value  = 1
                status = 'measured'
                domain = 'test'
                window = 'instant'
            }

            $parameters = @{
                Section   = 'gaming'
                Id        = $Id
                Severity  = $Severity
                TitleKey  = 'column.what'
                DetailKey = 'column.evidence'
                Evidence  = $evidence
            }
            if ($Severity -eq 'good') { $parameters['AlreadyGood'] = $true }

            return (& $script:NewFinding @parameters)
        }
    }

    It 'resolves every action findingId to a non-good finding' {
        $wanted = @($script:Catalog.actions | ForEach-Object { [string]$_.findingId } | Sort-Object -Unique)
        $wanted.Count | Should -BeGreaterThan 0
        foreach ($id in $wanted) {
            [string]::IsNullOrWhiteSpace($id) | Should -BeFalse -Because 'every action must cite a findingId'
        }

        $synthetic = @($wanted | ForEach-Object { New-PcxCatalogProvenanceFinding -Id $_ -Severity 'info' })
        $errors = @( & $script:TestMap -Findings $synthetic -Actions @($script:Catalog.actions) )

        $errors.Count | Should -Be 0 -Because ("every findingId must resolve to a non-good finding: " + ($errors -join ' | '))
    }

    It 'rejects an applyable action with no findingId' {
        $actions = Copy-PcxCatalogActions
        ($actions | Where-Object { $_.id -eq 'tips' })[0].PSObject.Properties.Remove('findingId')

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-FINDING-ID' | Should -BeTrue
    }

    It 'rejects an invented findingId' {
        $actions = Copy-PcxCatalogActions
        ($actions | Where-Object { $_.id -eq 'tips' })[0].findingId = 'download-more-ram'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-FINDING-ID' | Should -BeTrue
    }

    It 'rejects a findingId that resolves to a good finding' {
        $good = New-PcxCatalogProvenanceFinding -Id 'hags' -Severity 'good'

        $errors = @( & $script:TestMap -Findings @($good) -Actions @($script:Catalog.actions) )

        $errors.Count | Should -BeGreaterThan 0
        ($errors -join "`n") | Should -Match "resolves to a 'good' finding"
    }
}

Describe 'pcx catalog build gate' {

    It 'keeps every action applyable, supported and unverified on build 22631' {
        foreach ($action in $script:Catalog.actions) {
            $result = & $script:TestCatalogAction -Action $action -Build 22631

            $result.applyable | Should -BeTrue -Because "action '$($action.id)' is supported on 23H2"
            $result.demoted | Should -BeFalse -Because "action '$($action.id)' must not be demoted on 23H2"
            $result.supported | Should -BeTrue
            $result.family | Should -Be 'win11'
            $result.verified | Should -BeFalse
            $result.caveat | Should -Be 'not verified on build 22631; effect not promised'
            $result.reason | Should -Match 'effect not promised'
        }
    }

    It 'keeps a verified build applyable with no caveat' {
        $action = Get-PcxCatalogActionById -Id 'game-dvr'

        $result = & $script:TestCatalogAction -Action $action -Build 26100

        $result.applyable | Should -BeTrue
        $result.demoted | Should -BeFalse
        $result.supported | Should -BeTrue
        $result.family | Should -Be 'win11'
        $result.verified | Should -BeTrue
        $null -eq $result.caveat | Should -BeTrue
    }

    It 'keeps a Windows 10 2004+ build applyable and unverified' {
        $action = Get-PcxCatalogActionById -Id 'thumbnails'

        $result = & $script:TestCatalogAction -Action $action -Build 19045

        $result.applyable | Should -BeTrue
        $result.demoted | Should -BeFalse
        $result.supported | Should -BeTrue
        $result.family | Should -Be 'win10'
        $result.verified | Should -BeFalse
        $result.caveat | Should -Be 'not verified on build 19045; effect not promised'
    }

    It 'demotes an unsupported build to Manual and names the build' {
        $action = Get-PcxCatalogActionById -Id 'game-dvr'

        $result = & $script:TestCatalogAction -Action $action -Build 17763

        $result.applyable | Should -BeFalse
        $result.demoted | Should -BeTrue
        $result.supported | Should -BeFalse
        $result.family | Should -Be 'unsupported'
        $result.verified | Should -BeFalse
        $result.reason | Should -Match '17763'
        $result.reason | Should -Match 'unsupported'
        $result.reason | Should -Match 'Manual'
    }

    It 'classifies the boundary builds into families' {
        $cases = @(
            @{ Build = 17763; Family = 'unsupported'; Supported = $false }
            @{ Build = 19044; Family = 'win10'; Supported = $true }
            @{ Build = 19045; Family = 'win10'; Supported = $true }
            @{ Build = 22000; Family = 'win11'; Supported = $true }
            @{ Build = 22631; Family = 'win11'; Supported = $true }
            @{ Build = 26100; Family = 'win11'; Supported = $true }
        )

        foreach ($case in $cases) {
            $result = & $script:Module {
                param($Number)
                Get-PcxBuildSupport -Build $Number
            } $case.Build

            $result.family | Should -Be $case.Family -Because "build $($case.Build) belongs to $($case.Family)"
            $result.supported | Should -Be $case.Supported
        }
    }
}

Describe 'pcx HAGS contract' {

    BeforeAll {
        $script:Hags = Get-PcxCatalogActionById -Id 'hags'
    }

    It 'is a performance B action that needs the current state off' {
        $script:Hags.category | Should -Be 'B'
        $script:Hags.group | Should -Be 'performance'
        $script:Hags.evidence_rule.kind | Should -Be 'state'
        $script:Hags.evidence_rule.metric | Should -Be 'performance.hags_mode'
        $script:Hags.evidence_rule.predicate | Should -Be 'is-off'
    }

    It 'says effect not promised in both languages and names DLSS Frame Generation' {
        $script:Hags.user_text_en | Should -Match 'effect not promised'
        $script:Hags.user_text_ru | Should -Match '\u044D\u0444\u0444\u0435\u043A\u0442\u0020\u043D\u0435\u0020\u043E\u0431\u0435\u0449\u0430\u043D'
        $script:Hags.user_text_en | Should -Match 'DLSS Frame Generation'
        $script:Hags.user_text_ru | Should -Match 'DLSS Frame Generation'
    }

    It 'contains no FPS number' {
        $script:Hags.user_text_en | Should -Not -Match '\d+\s*%'
        $script:Hags.user_text_ru | Should -Not -Match '\d+\s*%'
        $script:Hags.user_text_en | Should -Not -Match '(?i)fps'
        $script:Hags.user_text_ru | Should -Not -Match '(?i)fps'
    }

    It 'is rejected when it stops requiring the state off' {
        $actions = Copy-PcxCatalogActions
        $hags = ($actions | Where-Object { $_.id -eq 'hags' })[0]
        $hags.evidence_rule.predicate = 'equals:2'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-HAGS-STATE' | Should -BeTrue
    }

    It 'is rejected when it stops naming the DLSS Frame Generation requirement' {
        $actions = Copy-PcxCatalogActions
        $hags = ($actions | Where-Object { $_.id -eq 'hags' })[0]
        $hags.user_text_en = 'Turn HAGS on. effect not promised.'
        $hags.user_text_ru = 'Turn HAGS on. effect not promised.'

        $result = Invoke-PcxCatalogValidation -Actions $actions -Manual $script:Catalog.manual

        $result.valid | Should -BeFalse
        Test-PcxCatalogErrorPresent -Result $result -Code 'PCX-CATALOG-HAGS-DLSS' | Should -BeTrue
    }
}
