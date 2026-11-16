<#
.SYNOPSIS
    Diagnostics wired into tune with no global time cap (optimize-v0.1-discovery todo 5).

.DESCRIPTION
    Proves the todo 5 acceptance block verbatim: `tune --table --fixture
    desktop` returns all 13 diagnostics sections alongside the action table;
    a sleeping section is terminated at the 120 s per-section guard and
    becomes `unavailable` while the other twelve report; no global
    `exhausted` flag exists anywhere (object shape, canonical JSON bytes and
    scan source); progress lines appear on stderr in the fixture's language
    from the progress.<section> dictionary templates, never hardcoded
    English; a per-section timing table is present. No assertion is made on
    the fixture's total time, because a fast fixture proves nothing about
    real hardware. Fixture-only: PCX_TEST_RUN stays set, no live OS reads or
    writes. This file stays ASCII and reads identically on PowerShell 5.1
    and 7 (expected non-English copy is resolved at runtime through
    Get-PcxText, never embedded as a literal).
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
    $script:Scan = $pcxModule.ExportedCommands['Get-PcxScan']
    $script:Dispatch = $pcxModule.ExportedCommands['Invoke-PcxDispatch']
    $script:GetText = $pcxModule.ExportedCommands['Get-PcxText']
    $script:ToCanonical = $pcxModule.ExportedCommands['ConvertTo-PcxCanonicalJson']
    $script:GetSections = $pcxModule.ExportedCommands['Get-PcxSections']

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:TuneSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Commands/Invoke-PcxTune.ps1'
    $script:TuneSource = [System.IO.File]::ReadAllText($script:TuneSourcePath)

    $script:SectionIds = @(& $script:GetSections)

    # A deterministic platform state: --table prints an A1 row only when its
    # target exists with a measured size. Seed the four thumbnail files.
    $script:PlatformStateFile = Join-Path -Path $TestDrive -ChildPath 'tune-platform-state.json'
    $tuneContent = [Convert]::ToBase64String((New-Object byte[] 4096))
    $tuneFiles = [ordered]@{}
    foreach ($cacheSize in @(32, 96, 256, 1024)) {
        $cachePath = "c:\users\tester\appdata\local\microsoft\windows\explorer\thumbcache_$cacheSize.db"
        $tuneFiles[$cachePath] = [ordered]@{
            path           = $cachePath
            contentBase64  = $tuneContent
            attributes     = 'Archive'
            isReparsePoint = $false
            sizeBytes      = 200MB
        }
    }
    $tuneState = [ordered]@{
        schema   = 'pcx-platform-test/1'
        registry = @{}
        services = @{}
        tasks    = @{}
        files    = $tuneFiles
    }
    $tuneUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($script:PlatformStateFile, (ConvertTo-Json -InputObject $tuneState -Depth 8 -Compress), $tuneUtf8)
    $env:PCX_TEST_STATE_FILE = $script:PlatformStateFile

    function Get-PcxTuneSectionIds {
        # Section ids in first-seen (registry) order, not sorted: the pool
        # appends batch results in registry order.
        param([Parameter(Mandatory = $true)][object] $Findings)

        $seen = New-Object System.Collections.Generic.List[string]
        foreach ($finding in @($Findings)) {
            $section = [string]$finding.section
            if (-not $seen.Contains($section)) {
                [void]$seen.Add($section)
            }
        }
        return $seen.ToArray()
    }

    function Get-PcxTuneStderr {
        # Runs one scriptblock with [Console]::Error redirected into a string
        # and restores the previous writer, so progress-on-stderr is asserted
        # without touching stdout (which carries the JSON envelope).
        param([Parameter(Mandatory = $true)][scriptblock] $Probe)

        $writer = New-Object System.IO.StringWriter
        $previous = [Console]::Error
        [Console]::SetError($writer)
        try {
            $result = & $Probe
        }
        finally {
            [Console]::SetError($previous)
        }

        return [ordered]@{ Result = $result; Stderr = $writer.ToString() }
    }

    function Get-PcxTuneCodeText {
        # The scan source with block comments, line comments and string
        # literals stripped, so the no-global-cap assertion inspects code,
        # not the explanatory comment that records the cap removal.
        $code = [regex]::Replace($script:TuneSource, '(?s)<#.*?#>', '')
        $code = [regex]::Replace($code, "(?m)#[^\r\n]*", '')
        $code = [regex]::Replace($code, "'([^']|'')*'", "''")
        return $code
    }
}

Describe 'tune returns diagnostics alongside the action table' {

    It 'returns all 13 sections and the action table on tune --table --fixture desktop' {
        $result = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--table')

        $result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -Be 'ok'

        # The existing action-table path is intact.
        ($result.Envelope.data.Keys -contains 'groups') | Should -BeTrue
        ($result.Envelope.data.Keys -contains 'findings') | Should -BeTrue
        ($result.Envelope.data.Keys -contains 'table') | Should -BeTrue
        [string]::IsNullOrWhiteSpace([string]$result.Envelope.data.table) | Should -BeFalse
        @($result.Envelope.data.findings).Count | Should -BeGreaterThan 0
        $result.Envelope.data.groups.Keys.Count | Should -Be 8

        # The wired diagnostics report travels as data.diagnostics.
        ($result.Envelope.data.Keys -contains 'diagnostics') | Should -BeTrue
        $result.Envelope.data.diagnostics.schema | Should -BeExactly 'pcx-diagnostics/1'
        ((Get-PcxTuneSectionIds -Findings $result.Envelope.data.diagnostics.findings) -join ',') | Should -BeExactly ($script:SectionIds -join ',')
        foreach ($section in $script:SectionIds) {
            @($result.Envelope.data.diagnostics.findings | Where-Object { [string]$_.section -eq $section }).Count | Should -BeGreaterThan 0 -Because "section '$section' must report at least one finding"
        }
    }

    It 'keeps tune flags unchanged: no table means no table, an unknown flag still refuses' {
        $plain = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture)

        $plain.ExitCode | Should -Be 0
        ($plain.Envelope.data.Keys -contains 'groups') | Should -BeTrue
        ($plain.Envelope.data.Keys -contains 'metrics') | Should -BeTrue
        ($plain.Envelope.data.Keys -contains 'table') | Should -BeFalse

        $refused = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--bogus-todo5')
        $refused.ExitCode | Should -Be 2
        $refused.Envelope.diagnostics[0].code | Should -Be 'PCX-E-SUBCOMMAND'
    }
}

Describe 'per-section guard with no global cap' {

    It 'terminates a sleeping section at the guard while the other twelve report' {
        # The shipped default is 120 s (asserted on the source below); the
        # mechanism is proven here with a short guard so the suite stays fast.
        $scan = & $script:Scan -FixturePath $script:DesktopFixture -PerSectionTimeoutSeconds 2 -DiagnosticsScripts @{ 'thermal' = 'Start-Sleep -Seconds 30' }

        ((Get-PcxTuneSectionIds -Findings $scan.diagnosticsReport.findings) -join ',') | Should -BeExactly ($script:SectionIds -join ',')

        $thermal = @($scan.diagnosticsReport.findings | Where-Object { [string]$_.section -eq 'thermal' })
        $thermal.Count | Should -Be 1
        $thermal[0].id | Should -BeExactly 'thermal-unavailable'
        $thermal[0].severity | Should -BeExactly 'unavailable'

        foreach ($section in @($script:SectionIds | Where-Object { $_ -ne 'thermal' })) {
            @($scan.diagnosticsReport.findings | Where-Object { [string]$_.section -eq $section }).Count | Should -BeGreaterThan 0 -Because "section '$section' must still report when thermal hangs"
        }

        $thermalTiming = @($scan.budget.perSection | Where-Object { [string]$_.id -eq 'thermal' })
        $thermalTiming.Count | Should -Be 1
        $thermalTiming[0].status | Should -BeExactly 'timeout'
    }

    It 'ships the 120 s per-section guard and the mandatory pool of 4' {
        $script:TuneSource | Should -Match ([regex]::Escape('PerSectionTimeoutSeconds = 120'))
        $script:TuneSource | Should -Match ([regex]::Escape('$script:PcxDiagnosticsPoolSize = 4'))
        $script:TuneSource | Should -Match ([regex]::Escape('$script:PcxDiagnosticsSectionTimeoutSeconds = 120'))
        $script:TuneSource | Should -Match 'CreateRunspacePool'
        $script:TuneSource | Should -Match 'BeginInvoke'
    }

    It 'never reports a global exhausted flag anywhere' {
        $scan = & $script:Scan -FixturePath $script:DesktopFixture

        ($scan.budget.Keys -contains 'exhausted') | Should -BeFalse
        ($scan.budget.Keys -contains 'totalSeconds') | Should -BeFalse

        $bytes = & $script:ToCanonical -InputObject $scan
        $bytes | Should -Not -Match 'exhausted'

        $code = Get-PcxTuneCodeText
        $code | Should -Not -Match 'exhausted'
        $code | Should -Not -Match 'TotalBudgetSeconds'
    }
}

Describe 'progress on stderr in the fixture language' {

    It 'writes all 13 dictionary progress lines to stderr in Russian with --lang ru' {
        $captured = Get-PcxTuneStderr -Probe { & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--table', '--lang', 'ru') }

        $captured.Result.ExitCode | Should -Be 0
        foreach ($section in $script:SectionIds) {
            $line = & $script:GetText -Key ('progress.' + $section) -Language 'ru'
            $captured.Stderr | Should -Match ([regex]::Escape($line)) -Because "stderr must carry the ru progress line for '$section'"
        }
        $captured.Stderr | Should -Not -Match 'Scanning'
    }

    It 'writes all 13 dictionary progress lines to stderr in English with --lang en' {
        $captured = Get-PcxTuneStderr -Probe { & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--table', '--lang', 'en') }

        $captured.Result.ExitCode | Should -Be 0
        foreach ($section in $script:SectionIds) {
            $line = & $script:GetText -Key ('progress.' + $section) -Language 'en'
            $captured.Stderr | Should -Match ([regex]::Escape($line)) -Because "stderr must carry the en progress line for '$section'"
        }
    }
}

Describe 'per-section timing table' {

    It 'records elapsedMs plus one timing row per section and asserts nothing about total time' {
        $scan = & $script:Scan -FixturePath $script:DesktopFixture

        ($scan.budget.Keys -contains 'elapsedMs') | Should -BeTrue
        ([long]$scan.budget.elapsedMs) | Should -BeGreaterOrEqual 0
        @($scan.budget.perSection).Count | Should -Be 13
        (@($scan.budget.perSection | ForEach-Object { [string]$_.id } | Sort-Object) -join ',') | Should -BeExactly (($script:SectionIds | Sort-Object) -join ',')

        foreach ($row in @($scan.budget.perSection)) {
            ([string]$row.status) | Should -BeIn @('completed', 'timeout', 'error', 'empty')
            ([long]$row.ms) | Should -BeGreaterOrEqual 0
        }

        # Deliberately no upper bound on elapsedMs: a fast fixture proves
        # nothing about real hardware, and the plan forbids that assertion.
    }
}
