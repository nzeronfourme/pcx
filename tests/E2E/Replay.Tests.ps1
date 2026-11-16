<#
.SYNOPSIS
    Full end-to-end replay (todo 15): tune table, selection, one-item apply,
    manual stop, resume, and hash-proven undo, plus managed and S Mode refusals
    and one invented agent-discovered target.

.DESCRIPTION
    This is the whole user journey from SKILL.md, driven through the real module
    entry points against the fixture adapter:

      1. pcx tune --table returns the grouped table.
      2. The user replies with row numbers; the plan validator accepts them.
      3. tune --apply applies exactly ONE item and returns partial.
      4. A resume stops on [s] and on the Cyrillic stop word, keeping the rest
         PENDING.
      5. A final resume prompts before the first pending item and finishes.
      6. undo restores every restorable item and exits 0 with canonical
         SHA-256 equality to the pre-state.

    Managed and S Mode profiles refuse every write. A proposal whose target is
    outside the seed catalog round-trips through snapshot/apply/verify/undo.

    Fixture adapter only: the suite proves the adapter is the test one, proves
    the repository carries tests/.pcx-test-root, and never writes to the live OS.
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
    $script:Tune = $script:Module.ExportedCommands['Invoke-PcxTune']
    $script:Plan = $script:Module.ExportedCommands['Invoke-PcxPlan']
    $script:Apply = $script:Module.ExportedCommands['Invoke-PcxApply']
    $script:Undo = $script:Module.ExportedCommands['Invoke-PcxUndo']
    $script:Scan = $script:Module.ExportedCommands['Get-PcxScan']
    $script:ReadJson = $script:Module.ExportedCommands['Read-PcxJson']
    $script:CanonicalJson = $script:Module.ExportedCommands['ConvertTo-PcxCanonicalJson']
    $script:Sha256 = $script:Module.ExportedCommands['Get-PcxSha256']
    $script:GetPlatform = $script:Module.ExportedCommands['Get-PcxPlatform']
    $script:PlatformRead = $script:Module.ExportedCommands['Invoke-PcxPlatformRead']
    $script:GetCatalog = $script:Module.ExportedCommands['Get-PcxCatalog']
    $script:ConvertPolicyProfile = $script:Module.ExportedCommands['ConvertTo-PcxPolicyProfile']

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:ProposalsPath = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/proposals/agent-discovered.json'
    $script:PlatformSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxPlatform.ps1'
    $script:TestRootMarker = Join-Path -Path $repoRoot -ChildPath 'tests/.pcx-test-root'

    $script:StopWord = -join @([char]0x0441, [char]0x0442, [char]0x043E, [char]0x043F)
    $script:GroupLabels = @('Safe', 'Performance & latency', 'Changes behavior', 'Agent does it', "Don't touch")

    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE

    function New-PcxReplayFixture {
        param([Parameter(Mandatory = $false)][string] $Name = 'replay')

        $root = Join-Path -Path $TestDrive -ChildPath ($Name + '-' + [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($root)

        $env:LOCALAPPDATA = $root
        $stateFile = Join-Path -Path $root -ChildPath 'state.json'
        $env:PCX_TEST_STATE_FILE = $stateFile

        $appData = Join-Path -Path $root -ChildPath 'Roaming'
        $startup = Join-Path -Path $appData -ChildPath 'Microsoft\Windows\Start Menu\Programs\Startup'
        $shortcut = Join-Path -Path $startup -ChildPath 'OneDrive.lnk'
        $content = [System.Text.Encoding]::UTF8.GetBytes('shortcut-bytes-0123456789')

        # Machine-read paths are stored in canonical (lower-case) form so a
        # restore that writes the canonical target back is byte-identical here.
        $canonicalShortcut = $shortcut.ToLowerInvariant()

        $state = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = @{}
            services = [ordered]@{
                diagtrack = [ordered]@{ name = 'DiagTrack'; controlSet = 'ControlSet001'; start = 2 }
            }
            tasks    = [ordered]@{
                '\startup\example app' = [ordered]@{ path = '\startup\example app'; enabled = $true; state = 'Ready' }
                '\pcxdemo\agentfound'  = [ordered]@{ path = '\pcxdemo\agentfound'; enabled = $true; state = 'Ready' }
            }
            files    = [ordered]@{
                $canonicalShortcut = [ordered]@{
                    path           = $canonicalShortcut
                    contentBase64  = [System.Convert]::ToBase64String($content)
                    attributes     = 'Archive'
                    isReparsePoint = $false
                }
            }
        }

        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject $state -Depth 8), $utf8)

        $profile = [ordered]@{
            managed      = $false
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            build        = 26100
            environment  = [ordered]@{
                LOCALAPPDATA = $root
                APPDATA      = $appData
                PROGRAMDATA  = (Join-Path $root 'ProgramData')
                SYSTEMROOT   = 'C:\Windows'
            }
            serviceFacts = [ordered]@{
                diagtrack = [ordered]@{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
            }
        }

        $profilePath = Join-Path -Path $root -ChildPath 'profile.json'
        [System.IO.File]::WriteAllText($profilePath, (ConvertTo-Json -InputObject $profile -Depth 8), $utf8)

        return [pscustomobject]@{
            Root        = $root
            StateFile   = $stateFile
            ProfilePath = $profilePath
            Shortcut    = $shortcut
        }
    }

    function Get-PcxReplayState {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Fixture.StateFile)) -ErrorAction Stop)
    }

    function Get-PcxReplayStateHash {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        $document = Get-PcxReplayState -Fixture $Fixture
        return (& $script:Sha256 -Text (& $script:CanonicalJson -InputObject $document))
    }

    function New-PcxReplayReader {
        param([Parameter(Mandatory = $false)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Answers = @())

        $queue = New-Object System.Collections.Generic.Queue[string]
        foreach ($answer in $Answers) { $queue.Enqueue($answer) }
        return { if ($queue.Count -eq 0) { return $null } return $queue.Dequeue() }.GetNewClosure()
    }

    function New-PcxReplayUndoRunner {
        # Fake UAC that runs the real elevated undo child in-process.
        param([Parameter(Mandatory = $true)][object] $Counter)

        $module = Get-Module -Name 'Pcx'
        return {
            param($request)
            $Counter.Count = [int]$Counter.Count + 1
            return & $module.ExportedCommands['Invoke-PcxUndoElevatedLoop'] -RequestBytesBase64 $request.payloadBase64 -RequestHash $request.requestHash -CallerSid $request.callerSid
        }.GetNewClosure()
    }

    function Get-PcxReplayRowNumber {
        param([Parameter(Mandatory = $true)][object] $Findings, [Parameter(Mandatory = $true)][string] $Id)

        $row = @($Findings | Where-Object { [string]$_.id -eq $Id })
        $row.Count | Should -Be 1 -Because "the tune table must offer '$Id'"
        return [int]$row[0].number
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
    $env:PCX_ALLOW_REAL_WRITES = $null
}

Describe 'full replay: table, selection, one-item apply, stop, resume, undo' {

    BeforeAll {
        $script:Replay = New-PcxReplayFixture -Name 'replay'
        $script:ReplayScan = & $script:Scan -FixturePath $script:DesktopFixture

        $script:ReplayTune = & $script:Tune -Arguments @('--lang', 'en', '--fixture', $script:DesktopFixture, '--profile', $script:Replay.ProfilePath, '--table')
        $script:ReplayFindings = @($script:ReplayTune.Envelope.data.findings)

        $taskRow = Get-PcxReplayRowNumber -Findings $script:ReplayFindings -Id 'startup-task-u4'
        $shortcutRow = Get-PcxReplayRowNumber -Findings $script:ReplayFindings -Id 'startup-shortcut-u4'
        $script:ReplaySelection = '{0},{1}' -f $taskRow, $shortcutRow

        $replayProfile = & $script:ReadJson -Path $script:Replay.ProfilePath
        $script:ReplayPlan = & $script:Plan -Selection $script:ReplaySelection -Scan $script:ReplayScan -Profile $replayProfile
        $script:ReplayInitialHash = Get-PcxReplayStateHash -Fixture $script:Replay
    }

    It 'returns the numbered tune table with selectable behavior rows' {
        [int]$script:ReplayTune.ExitCode | Should -Be 0
        $script:ReplayTune.Envelope.status | Should -Be 'ok'

        $table = [string]$script:ReplayTune.Envelope.data.table
        $table | Should -Match '\| Category \|'
        $riskLabels = @(
            (& $script:Module.ExportedCommands['Get-PcxText'] -Key 'risk.safe' -Language 'en'),
            (& $script:Module.ExportedCommands['Get-PcxText'] -Key 'risk.behavior' -Language 'en'),
            (& $script:Module.ExportedCommands['Get-PcxText'] -Key 'risk.risky' -Language 'en')
        )
        foreach ($row in $script:ReplayFindings) {
            $riskLabels -contains (& $script:Module.ExportedCommands['Get-PcxText'] -Key ('risk.' + [string]$row.risk) -Language 'en') | Should -BeTrue
            $table | Should -Match ([regex]::Escape((& $script:Module.ExportedCommands['Get-PcxText'] -Key ('risk.' + [string]$row.risk) -Language 'en')))
        }

        foreach ($id in @('startup-task-u4', 'startup-shortcut-u4')) {
            $row = @($script:ReplayFindings | Where-Object { [string]$_.id -eq $id })
            $row.Count | Should -Be 1
            [string]$row[0].group | Should -BeExactly 'behavior'
            [string]$row[0].source | Should -BeExactly 'catalog'
            [int]$row[0].number | Should -BeGreaterThan 0
        }
    }

    It 'builds a validated plan from the user row numbers' {
        $script:ReplaySelection | Should -Match '^[0-9]+,[0-9]+$'
        [int]$script:ReplayPlan.items.Count | Should -Be 2
        @($script:ReplayPlan.refused).Count | Should -Be 0

        [string]$script:ReplayPlan.items[0].actionId | Should -BeExactly 'startup-task-u4'
        [string]$script:ReplayPlan.items[1].actionId | Should -BeExactly 'startup-shortcut-u4'
        [string]$script:ReplayPlan.items[0].inverse | Should -BeExactly 'snapshot'
        [string]$script:ReplayPlan.items[1].inverse | Should -BeExactly 'quarantine'
    }

    It 'applies exactly one item per call and returns partial' {
        $first = & $script:Apply -PlanId $script:ReplayPlan.planId -Mode agent

        [string]$first.status | Should -BeExactly 'partial'
        @($first.applied).Count | Should -Be 1
        @($first.itemResults)[0].status | Should -BeExactly 'COMMITTED'
        [string]$first.next | Should -BeExactly ([string]$script:ReplayPlan.items[1].id)

        $state = Get-PcxReplayState -Fixture $script:Replay
        $state.tasks.'\startup\example app'.enabled | Should -BeFalse
        ($null -ne $state.files.PSObject.Properties[$script:Replay.Shortcut.ToLowerInvariant()]) | Should -BeTrue
    }

    It 'stops on [s] before the next item and keeps it pending' {
        $reader = New-PcxReplayReader -Answers @('s')
        $stopped = & $script:Apply -PlanId $script:ReplayPlan.planId -Mode console -StdinRedirected $false -InputReader $reader

        [string]$stopped.status | Should -BeExactly 'stopped'
        @($stopped.applied).Count | Should -Be 0
        [int]$stopped.prompts | Should -Be 1
        [string]$stopped.next | Should -BeExactly ([string]$script:ReplayPlan.items[1].id)

        $session = & $script:ReadJson -Path (Join-Path $script:Replay.Root ('pcx/journal/session-' + $script:ReplayPlan.planId + '.json'))
        @($session.items | Where-Object { [string]$_.status -eq 'COMMITTED' }).Count | Should -Be 1
        @($session.items | Where-Object { [string]$_.status -eq 'PENDING' }).Count | Should -Be 1
    }

    It 'stops on the Cyrillic stop word too' {
        $reader = New-PcxReplayReader -Answers @($script:StopWord)
        $stopped = & $script:Apply -PlanId $script:ReplayPlan.planId -Mode console -StdinRedirected $false -InputReader $reader

        [string]$stopped.status | Should -BeExactly 'stopped'
        @($stopped.applied).Count | Should -Be 0
        [int]$stopped.prompts | Should -Be 1
    }

    It 'resumes, prompts before the first pending item, and finishes' {
        $before = Get-PcxReplayState -Fixture $script:Replay
        ($null -ne $before.files.PSObject.Properties[$script:Replay.Shortcut.ToLowerInvariant()]) | Should -BeTrue

        $reader = New-PcxReplayReader -Answers @('')
        $resumed = & $script:Apply -PlanId $script:ReplayPlan.planId -Mode console -StdinRedirected $false -InputReader $reader

        [string]$resumed.status | Should -BeExactly 'done'
        [int]$resumed.prompts | Should -Be 1
        @($resumed.applied).Count | Should -Be 1
        [string]$resumed.applied[0] | Should -BeExactly ([string]$script:ReplayPlan.items[1].id)

        $state = Get-PcxReplayState -Fixture $script:Replay
        ($null -eq $state.files.PSObject.Properties[$script:Replay.Shortcut.ToLowerInvariant()]) | Should -BeTrue
        @($state.files.PSObject.Properties).Count | Should -Be 1
    }

    It 'undoes the whole plan with canonical SHA-256 equality' {
        $counter = @{ Count = 0 }
        $runner = New-PcxReplayUndoRunner -Counter $counter
        $parentRestore = { param($snapshot) throw 'the parent must not write for an elevated undo' }

        $outcome = & $script:Undo -PlanId $script:ReplayPlan.planId -Elevation $runner -Restore $parentRestore

        [bool]$outcome.ok | Should -BeTrue
        [bool]$outcome.elevated | Should -BeTrue
        [int]$outcome.elevationCalls | Should -Be 1
        $counter.Count | Should -Be 1
        @($outcome.restored).Count | Should -Be 2
        @($outcome.notRestorable).Count | Should -Be 0

        $state = Get-PcxReplayState -Fixture $script:Replay
        $state.tasks.'\startup\example app'.enabled | Should -BeTrue
        ($null -ne $state.files.PSObject.Properties[$script:Replay.Shortcut.ToLowerInvariant()]) | Should -BeTrue

        (Get-PcxReplayStateHash -Fixture $script:Replay) | Should -BeExactly $script:ReplayInitialHash
    }
}

Describe 'managed and S Mode refuse every write' {

    BeforeAll {
        $script:RefusalPolicies = [ordered]@{}
        foreach ($name in @('managed', 's-mode')) {
            $fixturePath = Join-Path -Path $script:FixtureRoot -ChildPath $name
            $scan = & $script:Scan -FixturePath $fixturePath
            $script:RefusalPolicies[$name] = [pscustomobject]@{
                Scan   = $scan
                Policy = & $script:ConvertPolicyProfile -Environment $scan.environment
            }
        }

        $script:RefusalTargets = @(
            @{ Kind = 'registry'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'PcxReplay' }
            @{ Kind = 'service'; Name = 'DiagTrack'; Start = 4 }
            @{ Kind = 'task'; Path = '\Startup\Example App'; Enabled = $false }
            @{ Kind = 'file'; Path = (Join-Path $TestDrive 'refusal-Startup\OneDrive.lnk'); Role = 'quarantine' }
        )
    }

    It '<Name> refuses every target kind with the documented code' -TestCases @(@{ Name = 'managed' }, @{ Name = 's-mode' }) -Test {
        param($Name)

        $expected = if ($Name -eq 'managed') { 'PCX-POLICY-MANAGED' } else { 'PCX-POLICY-SMODE' }
        $policy = $script:RefusalPolicies[$Name].Policy

        foreach ($target in $script:RefusalTargets) {
            $decision = & $script:Module.ExportedCommands['Test-PcxTarget'] -Target $target -Profile $policy
            [bool]$decision.allowed | Should -BeFalse
            [string]$decision.code | Should -BeExactly $expected
        }
    }

    It '<Name> refuses the plan and writes nothing' -TestCases @(@{ Name = 'managed' }, @{ Name = 's-mode' }) -Test {
        param($Name)

        $fixture = New-PcxReplayFixture -Name ('refusal-' + $Name)
        $before = Get-PcxReplayStateHash -Fixture $fixture

        $proposal = [ordered]@{
            actionId = 'tips'
            target   = [ordered]@{
                Kind = 'registry'
                Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                Name = 'SubscribedContent-338389Enabled'
            }
            evidence = [ordered]@{
                kind   = 'telemetry'
                metric = 'ads.settings_seen'
                domain = 'ads'
                value  = 1
                status = 'measured'
                window = 'instant'
            }
        }

        $context = $script:RefusalPolicies[$Name]
        $plan = & $script:Plan -Proposals @($proposal) -Scan $context.Scan -Profile $context.Scan.environment

        @($plan.items | Where-Object { $null -ne $_ }).Count | Should -Be 0
        @($plan.refused).Count | Should -BeGreaterThan 0
        [bool]$plan.written | Should -BeFalse

        $expected = if ($Name -eq 'managed') { 'PCX-POLICY-MANAGED' } else { 'PCX-POLICY-SMODE' }
        $codes = @($plan.refused | ForEach-Object { [string]$_.code })
        ($codes -contains $expected) | Should -BeTrue

        (Get-PcxReplayStateHash -Fixture $fixture) | Should -BeExactly $before
    }
}

Describe 'invented agent-discovered target' {

    BeforeAll {
        $script:Invented = New-PcxReplayFixture -Name 'invented'
        $script:InventedInitialHash = Get-PcxReplayStateHash -Fixture $script:Invented

        $desktopScan = & $script:Scan -FixturePath $script:DesktopFixture
        $inventedProfile = & $script:ReadJson -Path $script:Invented.ProfilePath
        $document = & $script:ReadJson -Path $script:ProposalsPath

        $script:InventedPlan = & $script:Plan -Proposals @($document.proposals) -Scan $desktopScan -Profile $inventedProfile
    }

    It 'accepts a target that is outside the seed catalog' {
        @($script:InventedPlan.refused).Count | Should -Be 0
        @($script:InventedPlan.items).Count | Should -Be 1

        $item = @($script:InventedPlan.items)[0]
        [string]$item.origin | Should -BeExactly 'agent-discovered'
        [string]$item.actionId | Should -BeExactly 'startup-task-u4'
        [string]$item.inverse | Should -BeExactly 'snapshot'

        $itemPath = ([string]$item.target[0].path).ToLowerInvariant()
        $itemPath | Should -BeExactly '\pcxdemo\agentfound'

        $catalogAction = @((& $script:GetCatalog).actions | Where-Object { [string]$_.id -eq 'startup-task-u4' })[0]
        foreach ($catalogTarget in @($catalogAction.target)) {
            ([string]$catalogTarget.Path).ToLowerInvariant() | Should -Not -BeExactly $itemPath
        }
    }

    It 'round-trips snapshot, apply, verify, and undo' {
        $item = @($script:InventedPlan.items)[0]
        $applyTarget = @{ Kind = 'task'; Path = [string]$item.target[0].path }

        $applied = & $script:Apply -PlanId $script:InventedPlan.planId -Mode agent
        [string]$applied.itemResults[0].status | Should -BeExactly 'COMMITTED'

        $afterApply = & $script:PlatformRead -Target $applyTarget
        $afterApply.exists | Should -BeTrue
        $afterApply.enabled | Should -BeFalse

        $counter = @{ Count = 0 }
        $runner = New-PcxReplayUndoRunner -Counter $counter
        $outcome = & $script:Undo -PlanId $script:InventedPlan.planId -Elevation $runner -Restore { param($snapshot) throw 'the parent must not write' }

        [bool]$outcome.ok | Should -BeTrue
        [int]$outcome.elevationCalls | Should -Be 1
        @($outcome.restored).Count | Should -Be 1

        $afterUndo = & $script:PlatformRead -Target $applyTarget
        $afterUndo.enabled | Should -BeTrue

        (Get-PcxReplayStateHash -Fixture $script:Invented) | Should -BeExactly $script:InventedInitialHash
    }
}

Describe 'no live-OS write' {

    BeforeAll {
        $script:Guard = New-PcxReplayFixture -Name 'guard'
    }

    It 'runs the replay through the fixture adapter' {
        $platform = & $script:GetPlatform
        [string]$platform.Name | Should -BeExactly 'test'
        [string]$platform.StateFile | Should -BeExactly $env:PCX_TEST_STATE_FILE
        $platform.StateFile.StartsWith($TestDrive, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $script:Guard.Root.StartsWith($TestDrive, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $env:LOCALAPPDATA | Should -BeExactly $script:Guard.Root
    }

    It 'carries the repo test-root marker the real adapter checks' {
        $env:PCX_TEST_RUN | Should -BeExactly '1'
        [System.IO.File]::Exists($script:TestRootMarker) | Should -BeTrue

        $source = [System.IO.File]::ReadAllText($script:PlatformSourcePath)
        $source | Should -Match ([regex]::Escape("'.pcx-test-root'"))
        $source | Should -Match 'PCX-E-PLATFORM-TESTROOT'
        $source | Should -Match 'PCX-E-PLATFORM-TESTRUN'
    }
}
