<#
.SYNOPSIS
    Eight collectors and the read-only tune scan (todo 8).

.DESCRIPTION
    Proves the scan contract without any live probe: eight groups appear, a
    throwing collector becomes unavailable and does not stop the scan, a
    sleeping collector is aborted at its timeout, a non-measured metric always
    has a null value (never a guessed zero), fixture scans are fast, --out is
    confined to the state scans directory or the canonical current directory,
    a junction cwd refuses, and `pcx tune` returns one scan envelope with no
    table. All fixture mode goes through PCX_TEST_RUN.
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
    $script:Tune = $pcxModule.ExportedCommands['Invoke-PcxTune']
    $script:Dispatch = $pcxModule.ExportedCommands['Invoke-PcxDispatch']
    $script:Table = $pcxModule.ExportedCommands['Invoke-PcxTable']
    $script:Plan = $pcxModule.ExportedCommands['Invoke-PcxPlan']
    $script:GetCatalog = $pcxModule.ExportedCommands['Get-PcxCatalog']

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:ManagedFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'managed'
    $script:SModeFixture = Join-Path -Path $script:FixtureRoot -ChildPath 's-mode'

    $script:CollectorRoot = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Collectors'
    $script:TuneSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Commands/Invoke-PcxTune.ps1'

    $script:GroupIds = @(
        'identity'
        'storage'
        'services-startup'
        'security'
        'intent'
        'printers'
        'memory'
        'performance'
    )

    $script:CollectorFunctions = @(
        'Get-PcxCollectorIdentity'
        'Get-PcxCollectorStorage'
        'Get-PcxCollectorServicesStartup'
        'Get-PcxCollectorSecurityState'
        'Get-PcxCollectorIntent'
        'Get-PcxCollectorPrinters'
        'Get-PcxCollectorMemory'
        'Get-PcxCollectorPerformance'
    )

    $script:PreviousEnvironmentFixture = $env:PCX_ENVIRONMENT_FIXTURE

    function Assert-MetricHonesty {
        param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Metrics)

        foreach ($metric in $Metrics) {
            $metric.status | Should -BeIn @('measured', 'unavailable', 'unreliable')
            if ($metric.status -ne 'measured') {
                ($null -eq $metric.value) | Should -BeTrue -Because "metric '$($metric.id)' is $($metric.status) and must not carry a guessed value"
            }
        }
    }
}

AfterAll {
    $env:PCX_ENVIRONMENT_FIXTURE = $script:PreviousEnvironmentFixture
}

Describe 'collector surface' {

    It 'exports the eight collector groups and the orchestrator' {
        foreach ($name in $script:CollectorFunctions) {
            $script:Module.ExportedCommands.ContainsKey($name) | Should -BeTrue -Because "$name must be exported"
        }
        ($null -ne $script:Scan) | Should -BeTrue
        ($null -ne $script:Tune) | Should -BeTrue
    }

    It 'declares one collector file per group' {
        $files = @(Get-ChildItem -LiteralPath $script:CollectorRoot -Filter '*.ps1' -File)
        $files.Count | Should -Be 8
        foreach ($name in @('IdentityCollector.ps1', 'StorageCollector.ps1', 'ServicesStartupCollector.ps1', 'SecurityStateCollector.ps1', 'IntentCollector.ps1', 'PrintersCollector.ps1', 'MemoryCollector.ps1', 'PerformanceCollector.ps1')) {
            ($files.Name -contains $name) | Should -BeTrue -Because "$name must exist"
        }
    }
}

Describe 'fixture scan' {

    It 'returns exactly the eight groups with the fixed metric shape' {
        $scan = & $script:Scan -FixturePath $script:DesktopFixture

        $scan.groups.Keys.Count | Should -Be 8
        foreach ($group in $script:GroupIds) {
            ($scan.groups.Keys -contains $group) | Should -BeTrue -Because "group '$group' must appear"
            @($scan.groups[$group].metrics).Count | Should -BeGreaterThan 0
        }

        foreach ($metric in $scan.metrics) {
            foreach ($key in @('id', 'group', 'status', 'value', 'unit', 'domain', 'window', 'source')) {
                ($metric.Keys -contains $key) | Should -BeTrue -Because "metric '$($metric.id)' lacks '$key'"
            }
        }
    }

    It 'never carries a guessed zero in any fixture profile' {
        foreach ($fixture in @($script:DesktopFixture, $script:ManagedFixture, $script:SModeFixture)) {
            $scan = & $script:Scan -FixturePath $fixture
            $scan.groups.Keys.Count | Should -Be 8
            Assert-MetricHonesty -Metrics $scan.metrics
        }
    }

    It 'reports BAM/SRUM as unavailable, not zero' {
        $scan = & $script:Scan -FixturePath $script:DesktopFixture
        $metric = @($scan.metrics | Where-Object { $_.id -eq 'intent.bam_srum_entries' })
        $metric.Count | Should -Be 1
        $metric[0].status | Should -Be 'unavailable'
        ($null -eq $metric[0].value) | Should -BeTrue
    }

    It 'finishes a fixture scan in under five seconds' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = & $script:Tune -Arguments @('--fixture', $script:DesktopFixture)
        $stopwatch.Stop()

        $result.ExitCode | Should -Be 0
        ($stopwatch.Elapsed.TotalSeconds -lt 5) | Should -BeTrue -Because 'fixture mode must not probe the live OS'
    }
}

Describe 'failure isolation' {

    It 'turns a throwing collector into one unavailable metric and keeps scanning' {
        $scan = & $script:Scan -FixturePath $script:DesktopFixture -CollectorScripts @{ 'storage' = { throw 'collector exploded' } }

        $scan.groups['storage'].status | Should -Be 'unavailable'
        @($scan.groups['storage'].metrics).Count | Should -Be 1
        $scan.groups['storage'].metrics[0].id | Should -Be 'storage.error'
        ($null -eq $scan.groups['storage'].metrics[0].value) | Should -BeTrue

        $scan.groups.Keys.Count | Should -Be 8
        $scan.groups['identity'].status | Should -Be 'measured'
        $scan.groups['intent'].status | Should -Be 'measured'
    }

    It 'aborts a sleeping collector at its per-collector timeout with no global cap' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $scan = & $script:Scan -FixturePath $script:DesktopFixture -PerCollectorTimeoutSeconds 1 -CollectorScripts @{ 'intent' = { Start-Sleep -Seconds 30 } }
        $stopwatch.Stop()

        $scan.groups['intent'].status | Should -Be 'unavailable'
        $scan.groups['intent'].metrics[0].id | Should -Be 'intent.timeout'
        ($null -eq $scan.groups['intent'].metrics[0].value) | Should -BeTrue
        ($stopwatch.Elapsed.TotalSeconds -lt 20) | Should -BeTrue

        # No global cap: the budget carries elapsed time plus the per-section
        # timing table and never reports `exhausted`.
        ($scan.budget.Keys -contains 'totalSeconds') | Should -BeFalse
        ($scan.budget.Keys -contains 'exhausted') | Should -BeFalse
        ($scan.budget.Keys -contains 'elapsedMs') | Should -BeTrue
        ($scan.budget.Keys -contains 'perSection') | Should -BeTrue
        @($scan.budget.perSection).Count | Should -Be 13
        @($scan.diagnostics | Where-Object { $_.code -eq 'PCX-E-COLLECTOR-TIMEOUT' }).Count | Should -Be 1
        $scan.groups.Keys.Count | Should -Be 8
    }

    It 'runs every group to completion with no global budget to exhaust' {
        $scan = & $script:Scan -FixturePath $script:DesktopFixture

        ($scan.budget.Keys -contains 'exhausted') | Should -BeFalse
        ($scan.budget.Keys -contains 'totalSeconds') | Should -BeFalse
        $scan.groups.Keys.Count | Should -Be 8

        foreach ($group in $script:GroupIds) {
            @($scan.groups[$group].metrics).Count | Should -BeGreaterThan 0
            foreach ($metric in @($scan.groups[$group].metrics)) {
                # No group is ever cut off by a global cap: no budget id exists.
                ([string]$metric.id -like '*budget*') | Should -BeFalse -Because "'$($metric.id)' must not be a budget-cutoff metric"
            }
        }
        Assert-MetricHonesty -Metrics $scan.metrics
    }
}

Describe 'out confinement' {

    It 'refuses an --out path outside the scans directory and the current directory' {
        $outside = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('pcx-denied-' + [guid]::NewGuid().ToString('N') + '.json')

        $result = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--out', $outside)

        $result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-OUT-DENIED'
        [System.IO.File]::Exists($outside) | Should -BeFalse
    }

    It 'writes an --out file under the canonical current directory' {
        $tempRoot = Join-Path -Path $TestDrive -ChildPath ('pcx-out-' + [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($tempRoot)

        Push-Location -LiteralPath $tempRoot
        try {
            $out = Join-Path -Path $tempRoot -ChildPath 'scan.json'
            $result = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--out', $out)

            $result.ExitCode | Should -Be 0
            [System.IO.File]::Exists($out) | Should -BeTrue
        }
        finally {
            Pop-Location
            if ([System.IO.File]::Exists((Join-Path -Path $tempRoot -ChildPath 'scan.json'))) {
                [System.IO.File]::Delete((Join-Path -Path $tempRoot -ChildPath 'scan.json'))
            }
            if ([System.IO.Directory]::Exists($tempRoot)) {
                [System.IO.Directory]::Delete($tempRoot, $true)
            }
        }
    }

    It 'refuses a reparse/junction current directory' {
        $real = Join-Path -Path $TestDrive -ChildPath ('pcx-real-' + [guid]::NewGuid().ToString('N'))
        $link = Join-Path -Path $TestDrive -ChildPath ('pcx-link-' + [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($real)
        $null = New-Item -ItemType Junction -Path $link -Target $real -ErrorAction Stop

        Push-Location -LiteralPath $link
        try {
            $result = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--out', 'scan.json')

            $result.ExitCode | Should -Be 2
            $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-OUT-DENIED'
            [System.IO.File]::Exists((Join-Path -Path $real -ChildPath 'scan.json')) | Should -BeFalse
        }
        finally {
            Pop-Location
            if ([System.IO.Directory]::Exists($link)) {
                [System.IO.Directory]::Delete($link, $false)
            }
            if ([System.IO.Directory]::Exists($real)) {
                [System.IO.Directory]::Delete($real, $true)
            }
        }
    }
}

Describe 'command surface' {

    It 'returns one tune envelope with the scan findings and no table' {
        $result = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture)

        $result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -Be 'ok'
        $result.Envelope.command | Should -Be 'tune'
        ($result.Envelope.data.Keys -contains 'groups') | Should -BeTrue
        ($result.Envelope.data.Keys -contains 'metrics') | Should -BeTrue
        ($result.Envelope.data.Keys -contains 'table') | Should -BeFalse
        $result.Envelope.data.groups.Keys.Count | Should -Be 8
    }

    It 'accepts --table and renders the grouped table in data.table' {
        $result = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--table')

        $result.ExitCode | Should -Be 0
        ($result.Envelope.data.Keys -contains 'table') | Should -BeTrue
        [string]::IsNullOrWhiteSpace([string]$result.Envelope.data.table) | Should -BeFalse
        @($result.Envelope.diagnostics | Where-Object { $_.code -eq 'PCX-I-TABLE-PENDING' }).Count | Should -Be 0
    }

    It 'refuses tune --apply without a plan id or selection' {
        $result = & $script:Dispatch -Arguments @('tune', '--apply', '--fixture', $script:DesktopFixture)

        $result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-APPLY-SELECTION'
    }

    It 'refuses a live scan in fixture mode without a fixture path' {
        { & $script:Scan } | Should -Throw '*PCX-E-SCAN-FIXTURE*'

        $result = & $script:Dispatch -Arguments @('tune')
        $result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-SCAN-FIXTURE'
    }
}

Describe 'collector source safety' {

    BeforeAll {
        $script:CollectorSources = @(Get-ChildItem -LiteralPath $script:CollectorRoot -Filter '*.ps1' -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
        $script:TuneSource = [System.IO.File]::ReadAllText($script:TuneSourcePath)
        $script:AllSources = @($script:CollectorSources) + @($script:TuneSource)
    }

    It 'never uses an inventory-only, device-registration, shell or job command' {
        $banned = @(
            'Win32_Product'
            'dsregcmd'
            'cmd /c'
            'Invoke-Expression'
            'Remove-Item'
            'Start-Job'
            'reg.exe'
            'sc.exe'
            'schtasks.exe'
        )

        foreach ($source in $script:AllSources) {
            foreach ($token in $banned) {
                $source | Should -Not -Match ([regex]::Escape($token)) -Because "collector code must not use '$token'"
            }
        }
    }

    It 'reads events only through Get-WinEvent -FilterHashtable' {
        $intentSource = [System.IO.File]::ReadAllText((Join-Path -Path $script:CollectorRoot -ChildPath 'IntentCollector.ps1'))
        $intentSource | Should -Match ([regex]::Escape('Get-WinEvent -FilterHashtable'))
    }
}

Describe 'live-shaped environment' {

    BeforeAll {
        $script:LiveFixtureScan = & $script:Scan -FixturePath $script:DesktopFixture
        $script:LiveCatalog = & $script:GetCatalog

        # A measured A1 row is seeded here: the live-shaped scan clears the
        # fixture sentinel while it runs, so ambient state from another suite is
        # not a contract this file may rely on.
        $script:PreviousStateFile = $env:PCX_TEST_STATE_FILE
        $script:CollectorStateFile = Join-Path -Path $TestDrive -ChildPath 'collectors-state.json'
        $collectorContent = [Convert]::ToBase64String((New-Object byte[] 4096))
        $collectorFiles = [ordered]@{}
        foreach ($cacheSize in @(32, 96, 256, 1024)) {
            $cachePath = "c:\users\tester\appdata\local\microsoft\windows\explorer\thumbcache_$cacheSize.db"
            $collectorFiles[$cachePath] = [ordered]@{
                path           = $cachePath
                contentBase64  = $collectorContent
                attributes     = 'Archive'
                isReparsePoint = $false
                sizeBytes      = 200MB
            }
        }
        $collectorState = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = $collectorFiles
        }
        $collectorUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($script:CollectorStateFile, (ConvertTo-Json -InputObject $collectorState -Depth 8 -Compress), $collectorUtf8)
        $env:PCX_TEST_STATE_FILE = $script:CollectorStateFile

        # Replay the fixture metrics through the live collector seam so a
        # live-shaped scan never reads the real OS inside Pester.
        $script:LiveCollectorScripts = @{}
        foreach ($group in $script:GroupIds) {
            $json = @($script:LiveFixtureScan.groups[$group].metrics) | ConvertTo-Json -Depth 12 -Compress
            $script:LiveCollectorScripts[$group] = ('ConvertFrom-Json -InputObject ''{0}'' | ForEach-Object {{ $_ }}' -f $json.Replace("'", "''"))
        }

        function New-PcxLiveEnvironment {
            param([Parameter(Mandatory = $true)][int] $Build)

            $environment = Get-Content -LiteralPath (Join-Path -Path $script:DesktopFixture -ChildPath 'machine.json') -Raw | ConvertFrom-Json
            $environment.os.build.value = $Build
            return $environment
        }

        function Invoke-PcxLiveShapedScan {
            # no --fixture + injected environment (or a throwing probe). The
            # sticky sentinel is cleared only around this call and restored so
            # the runner's final fixture check still holds.
            param(
                [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
                [Parameter(Mandatory = $false)][AllowNull()][object] $EnvironmentProbe
            )

            $previous = $env:PCX_TEST_RUN
            $env:PCX_TEST_RUN = $null
            try {
                $parameters = @{ CollectorScripts = $script:LiveCollectorScripts }
                if ($null -ne $Environment) { $parameters['Environment'] = $Environment }
                if ($null -ne $EnvironmentProbe) { $parameters['EnvironmentProbe'] = $EnvironmentProbe }
                return (& $script:Scan @parameters)
            }
            finally {
                $env:PCX_TEST_RUN = $previous
            }
        }

        function Get-PcxLiveRows {
            param([Parameter(Mandatory = $true)][object] $Scan)

            $rendered = & $script:Table -Scan $Scan -Catalog $script:LiveCatalog
            $rows = @()
            foreach ($group in $rendered.groups.Values) { $rows += @($group.rows) }
            return $rows
        }
    }

    It 'attaches the injected build and makes applyable rows selectable on 22631' {
        $scan = Invoke-PcxLiveShapedScan -Environment (New-PcxLiveEnvironment -Build 22631)

        $scan.fixture | Should -BeFalse
        $scan.environment.os.build.value | Should -Be 22631

        $selectable = @(Get-PcxLiveRows -Scan $scan | Where-Object { [string]$_.source -eq 'catalog' })
        $selectable.Count | Should -BeGreaterThan 0
        foreach ($row in $selectable) {
            $row.recommendation | Should -Match ([regex]::Escape('not verified on build 22631; effect not promised'))
        }

        # The plan resolves the same build from the scan alone, with no -Profile.
        $plan = & $script:Plan -Selection ([string]$selectable[0].number) -Scan $scan -Profile $null -DryRun
        @($plan.refused).Count | Should -Be 0
        @($plan.items).Count | Should -Be 1
    }

    It 'keeps 26100 selectable without the unverified caveat' {
        $scan = Invoke-PcxLiveShapedScan -Environment (New-PcxLiveEnvironment -Build 26100)

        $scan.environment.os.build.value | Should -Be 26100

        $selectable = @(Get-PcxLiveRows -Scan $scan | Where-Object { [string]$_.source -eq 'catalog' })
        $selectable.Count | Should -BeGreaterThan 0
        foreach ($row in $selectable) {
            $row.recommendation | Should -Not -Match 'not verified on build'
        }
    }

    It 'fails closed with a typed diagnostic when the environment probe throws' {
        $scan = Invoke-PcxLiveShapedScan -EnvironmentProbe { throw 'environment exploded' }

        $scan.fixture | Should -BeFalse
        ($null -eq $scan.environment) | Should -BeTrue
        @($scan.diagnostics | Where-Object { $_.code -eq 'PCX-E-ENVIRONMENT-ERROR' }).Count | Should -Be 1

        $selectable = @(Get-PcxLiveRows -Scan $scan | Where-Object { [string]$_.source -eq 'catalog' })
        $selectable.Count | Should -Be 0
    }

    It 'keeps fixture scans on their own environment and row counts' {
        $scan = & $script:Scan -FixturePath $script:DesktopFixture

        $scan.fixture | Should -BeTrue
        $scan.environment.os.build.value | Should -Be 22631
        @(Get-PcxLiveRows -Scan $scan).Count | Should -Be @(Get-PcxLiveRows -Scan $script:LiveFixtureScan).Count
    }

    AfterAll {
        $env:PCX_TEST_STATE_FILE = $script:PreviousStateFile
    }
}
