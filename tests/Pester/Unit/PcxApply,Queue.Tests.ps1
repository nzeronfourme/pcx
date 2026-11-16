<#
.SYNOPSIS
    Apply, manual stop, resume, and one UAC (todo 12).

.DESCRIPTION
    Agent mode applies exactly one PENDING item per invocation, never reads
    stdin, and returns partial/done. Console mode refuses without a TTY, prompts
    before every item, accepts Enter / s / the Cyrillic stop word, re-prompts on
    garbage, never advances on EOF, and makes exactly one injected UAC.
    COMMITTED items are skipped before snapshotting; a declined UAC applies
    nothing; a drifted target refuses; a read-back mismatch inline-undoes and
    marks the item FAILED. The elevated child contract rejects altered bytes,
    oversized plans, hash-consistent-but-invalid plans, and a SID mismatch.

    No test prompts a human and no test performs a real UAC or a live write.
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
    $script:Apply = $script:Module.ExportedCommands['Invoke-PcxApply']
    $script:Queue = $script:Module.ExportedCommands['Invoke-PcxQueue']
    $script:Elevated = $script:Module.ExportedCommands['Invoke-PcxApplyElevated']
    $script:Plan = $script:Module.ExportedCommands['Invoke-PcxPlan']
    $script:ScanCommand = $script:Module.ExportedCommands['Get-PcxScan']
    $script:ReadJson = $script:Module.ExportedCommands['Read-PcxJson']

    $script:Scan = & $script:ScanCommand -FixturePath (Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment/desktop')
    $script:StopWord = -join @([char]0x0441, [char]0x0442, [char]0x043E, [char]0x043F)

    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE
    $script:FixtureCounter = 0

    function New-PcxApplyFixture {
        param([Parameter(Mandatory = $false)][int] $DiagTrackStart = 2, [Parameter(Mandatory = $false)][int] $MapsBrokerStart = 2)

        $script:FixtureCounter = [int]$script:FixtureCounter + 1
        $root = Join-Path -Path $TestDrive -ChildPath ('apply-fixture-' + $script:FixtureCounter + '-' + [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($root)

        $env:LOCALAPPDATA = $root
        $stateFile = Join-Path -Path $root -ChildPath 'state.json'
        $env:PCX_TEST_STATE_FILE = $stateFile

        $state = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = @{}
            services = [ordered]@{
                diagtrack  = [ordered]@{ name = 'DiagTrack'; controlSet = 'ControlSet001'; start = $DiagTrackStart }
                mapsbroker = [ordered]@{ name = 'MapsBroker'; controlSet = 'ControlSet001'; start = $MapsBrokerStart }
            }
            tasks    = @{}
            files    = @{}
        }
        [System.IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject $state -Depth 8), (New-Object System.Text.UTF8Encoding -ArgumentList $false))

        $profile = [ordered]@{
            managed      = $false
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            build        = 26100
            environment  = [ordered]@{ LOCALAPPDATA = $root; APPDATA = (Join-Path $root 'Roaming'); PROGRAMDATA = 'C:\ProgramData'; SYSTEMROOT = 'C:\Windows' }
            serviceFacts = [ordered]@{
                diagtrack  = [ordered]@{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
                mapsbroker = [ordered]@{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
            }
        }

        return [pscustomobject]@{ Root = $root; StateFile = $stateFile; Profile = $profile }
    }

    function New-PcxApplyProposal {
        param([Parameter(Mandatory = $true)][string] $ServiceName)

        return [ordered]@{
            actionId = 'diagtrack-u4'
            target   = [ordered]@{ Kind = 'service'; Name = $ServiceName; Start = 4 }
            evidence = [ordered]@{
                kind   = 'telemetry'
                metric = 'services.running_count'
                domain = 'services'
                value  = 143
                status = 'measured'
                window = 'instant'
            }
        }
    }

    function New-PcxApplyPlan {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        $proposals = @(
            (New-PcxApplyProposal -ServiceName 'DiagTrack'),
            (New-PcxApplyProposal -ServiceName 'MapsBroker')
        )
        return & $script:Plan -Proposals $proposals -Scan $script:Scan -Profile $Fixture.Profile
    }

    function New-PcxAnswerReader {
        param(
            [Parameter(Mandatory = $false)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Answers = @(),
            [Parameter(Mandatory = $false)][switch] $EndOfInput
        )

        if ($EndOfInput) {
            return { $null }
        }

        $queue = New-Object System.Collections.Generic.Queue[string]
        foreach ($answer in $Answers) { $queue.Enqueue($answer) }
        return { if ($queue.Count -eq 0) { return $null } return $queue.Dequeue() }.GetNewClosure()
    }

    function Get-PcxApplySession {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $PlanId)

        $path = Join-Path -Path $Fixture.Root -ChildPath ('pcx/journal/session-' + $PlanId + '.json')
        return & $script:ReadJson -Path $path
    }

    function Get-PcxApplyStateFile {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        return (Get-Content -LiteralPath $Fixture.StateFile -Raw | ConvertFrom-Json)
    }

    function Set-PcxApplyStateStart {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $ServiceName, [Parameter(Mandatory = $true)][int] $Start)

        $state = Get-PcxApplyStateFile -Fixture $Fixture
        $key = $ServiceName.ToLowerInvariant()
        $state.services.$key.start = $Start
        [System.IO.File]::WriteAllText($Fixture.StateFile, (ConvertTo-Json -InputObject $state -Depth 8), (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    }

    function New-PcxElevationOk {
        return { param($request) [pscustomobject]@{ ok = $true; declined = $false; code = $null; reason = $null } }
    }

    function New-PcxElevationDeclined {
        return { param($request) [pscustomobject]@{ ok = $false; declined = $true; code = 'PCX-E-UAC-DECLINED'; reason = 'denied by the user' } }
    }

    function New-PcxElevatedRunner {
        <#
        .SYNOPSIS
            Fake elevation that runs the real elevated child entry point
            in-process with a scripted reader. The loop and the writes happen
            inside Invoke-PcxApplyElevatedLoop, never in the parent.
        #>
        param(
            [Parameter(Mandatory = $true)][scriptblock] $Reader,
            [Parameter(Mandatory = $false)][AllowNull()][scriptblock] $Provider,
            [Parameter(Mandatory = $false)][AllowNull()][object] $Counter
        )

        $module = Get-Module -Name 'Pcx'
        $runner = {
            param($request)
            if ($null -ne $Counter) { $Counter.Count = [int]$Counter.Count + 1 }
            $child = $module.ExportedCommands['Invoke-PcxApplyElevatedLoop']
            if ($null -ne $Provider) {
                return & $child -PlanBytesBase64 $request.payloadBase64 -PlanHash $request.planHash -CallerSid $request.callerSid -InputReader $Reader -Provider $Provider -StdinRedirected ([bool]$request.stdinRedirected)
            }
            return & $child -PlanBytesBase64 $request.payloadBase64 -PlanHash $request.planHash -CallerSid $request.callerSid -InputReader $Reader -StdinRedirected ([bool]$request.stdinRedirected)
        }.GetNewClosure()

        return $runner
    }

    function New-PcxApplyUserPlan {
        param([Parameter(Mandatory = $true)][object] $Fixture)

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

        return & $script:Plan -Proposals @($proposal) -Scan $script:Scan -Profile $Fixture.Profile
    }

    function Get-PcxApplyRegistryState {
        param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Name)

        return & $script:Module.ExportedCommands['Invoke-PcxPlatformRead'] -Target @{ Kind = 'registry'; Path = $Path; Name = $Name }
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
}

Describe 'apply surface' {

    It 'exports agent, queue and elevated entry points and keeps the child command internal' {
        ($null -ne $script:Apply) | Should -BeTrue
        ($null -ne $script:Queue) | Should -BeTrue
        ($null -ne $script:Elevated) | Should -BeTrue

        $help = & $script:Module.ExportedCommands['Invoke-PcxDispatch'] -Arguments @('--help')
        @($help.Envelope.data.commands) -contains 'apply-elevated' | Should -BeFalse
    }

    It 'no longer returns PCX-E-NOT-IMPLEMENTED for tune --apply' {
        $result = & $script:Module.ExportedCommands['Invoke-PcxDispatch'] -Arguments @('tune', '--apply')
        $codes = @($result.Envelope.diagnostics | ForEach-Object { [string]$_.code })
        $codes -contains 'PCX-E-NOT-IMPLEMENTED' | Should -BeFalse
        [int]$result.ExitCode | Should -Be 2
    }
}

Describe 'agent mode' {

    It 'applies exactly one PENDING item and returns partial then done' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture

        $first = & $script:Apply -PlanId $plan.planId -Mode agent
        $first.status | Should -Be 'partial'
        @($first.applied).Count | Should -Be 1
        [string]::IsNullOrWhiteSpace([string]$first.next) | Should -BeFalse
        @($first.itemResults).Count | Should -Be 1
        $first.itemResults[0].status | Should -Be 'COMMITTED'

        $stateAfterFirst = Get-PcxApplyStateFile -Fixture $fixture
        $stateAfterFirst.services.diagtrack.start | Should -Be 4
        $stateAfterFirst.services.mapsbroker.start | Should -Be 2

        $second = & $script:Apply -PlanId $plan.planId -Mode agent
        $second.status | Should -Be 'done'
        @($second.applied).Count | Should -Be 1
        $second.next | Should -BeNullOrEmpty

        $stateAfterSecond = Get-PcxApplyStateFile -Fixture $fixture
        $stateAfterSecond.services.diagtrack.start | Should -Be 4
        $stateAfterSecond.services.mapsbroker.start | Should -Be 4
    }

    It 'never reads stdin' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture

        $throwingReader = { throw 'agent mode read stdin' }
        $result = & $script:Apply -PlanId $plan.planId -Mode agent -InputReader $throwingReader

        $result.status | Should -Be 'partial'
        @($result.applied).Count | Should -Be 1
    }

    It 'persists a session file with the item snapshot for undo' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $null = & $script:Apply -PlanId $plan.planId -Mode agent

        $session = Get-PcxApplySession -Fixture $fixture -PlanId $plan.planId
        $session.schema | Should -Be 'pcx-session/1'
        $session.planId | Should -Be $plan.planId

        $committed = @($session.items | Where-Object { $_.status -eq 'COMMITTED' })
        @($committed).Count | Should -Be 1
        @($committed[0].snapshots).Count | Should -Be 1
        $committed[0].snapshots[0].kind | Should -Be 'service'
        $committed[0].snapshots[0].pre.start | Should -Be 2
        $committed[0].snapshots[0].post.start | Should -Be 4
    }

    It 'prints pcx undo --item and pcx undo --plan on the applied item line' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $result = & $script:Apply -PlanId $plan.planId -Mode agent

        $itemResult = $result.itemResults[0]
        $itemResult.line | Should -Match ('pcx undo --item ' + [regex]::Escape([string]$itemResult.id))
        $itemResult.line | Should -Match ('pcx undo --plan ' + [regex]::Escape([string]$plan.planId))
        $itemResult.undoItem | Should -Be ('pcx undo --item ' + [string]$itemResult.id)
        $itemResult.undoPlan | Should -Be ('pcx undo --plan ' + [string]$plan.planId)
    }
}

Describe 'console mode TTY' {

    It 'refuses without a TTY and applies nothing' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $true -Elevation (New-PcxElevationOk) -InputReader (New-PcxAnswerReader -Answers @(''))

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-NO-TTY'
        @($result.applied).Count | Should -Be 0

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 2
        $state.services.mapsbroker.start | Should -Be 2
    }
}

Describe 'console mode manual stop' {

    It 'advances on Enter and stops on s' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $reader = New-PcxAnswerReader -Answers @('', 's')

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation (New-PcxElevatedRunner -Reader $reader) -InputReader $reader

        $result.status | Should -Be 'stopped'
        $result.prompts | Should -Be 2
        @($result.applied).Count | Should -Be 1

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 4
        $state.services.mapsbroker.start | Should -Be 2
    }

    It 'stops on the Cyrillic word' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $stopReader = New-PcxAnswerReader -Answers @($script:StopWord)

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation (New-PcxElevatedRunner -Reader $stopReader) -InputReader $stopReader

        $result.status | Should -Be 'stopped'
        @($result.applied).Count | Should -Be 0

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 2
    }

    It 're-prompts on other input and only then stops' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $reader = New-PcxAnswerReader -Answers @('@@', 's')

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation (New-PcxElevatedRunner -Reader $reader) -InputReader $reader

        $result.status | Should -Be 'stopped'
        $result.prompts | Should -Be 2
        @($result.applied).Count | Should -Be 0
    }

    It 'never advances on EOF' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $eofReader = New-PcxAnswerReader -EndOfInput

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation (New-PcxElevatedRunner -Reader $eofReader) -InputReader $eofReader

        $result.status | Should -Be 'stopped'
        $result.stoppedBy | Should -Be 'eof'
        @($result.applied).Count | Should -Be 0

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 2
    }
}

Describe 'one UAC per plan' {

    It 'makes exactly one elevation call and the child applies N items without a parent write' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $reader = New-PcxAnswerReader -Answers @('', '', '')
        $elevationCounter = @{ Count = 0 }
        $countingElevation = New-PcxElevatedRunner -Reader $reader -Counter $elevationCounter

        $parentProvider = { param($context) throw 'the parent provider must not write for an admin plan' }
        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation $countingElevation -InputReader $reader -Provider $parentProvider

        $elevationCounter.Count | Should -Be 1
        $result.elevated | Should -BeTrue
        $result.status | Should -Be 'done'
        $result.prompts | Should -Be 2
        @($result.applied).Count | Should -Be 2

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 4
        $state.services.mapsbroker.start | Should -Be 4
    }

    It 'keeps the remainder PENDING when the child is stopped' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        $reader = New-PcxAnswerReader -Answers @('', 's')
        $runner = New-PcxElevatedRunner -Reader $reader

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation $runner -InputReader $reader

        $result.elevated | Should -BeTrue
        $result.status | Should -Be 'stopped'
        @($result.applied).Count | Should -Be 1
        [string]::IsNullOrWhiteSpace([string]$result.next) | Should -BeFalse

        $session = Get-PcxApplySession -Fixture $fixture -PlanId $plan.planId
        @($session.items | Where-Object { $_.status -eq 'PENDING' }).Count | Should -Be 1
    }

    It 'applies nothing when the UAC is declined and leaves every item PENDING' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation (New-PcxElevationDeclined) -InputReader (New-PcxAnswerReader -Answers @(''))

        $result.status | Should -Be 'stopped'
        $result.declined | Should -BeTrue
        $result.code | Should -Be 'PCX-E-UAC-DECLINED'
        @($result.applied).Count | Should -Be 0

        $session = Get-PcxApplySession -Fixture $fixture -PlanId $plan.planId
        @($session.items | Where-Object { $_.status -ne 'PENDING' }).Count | Should -Be 0

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 2
        $state.services.mapsbroker.start | Should -Be 2
    }
}

Describe 'non-admin console' {

    It 'raises no UAC and writes in-process' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyUserPlan -Fixture $fixture
        $reader = New-PcxAnswerReader -Answers @('')
        $elevationCounter = @{ Count = 0 }
        $noUac = { param($request) $elevationCounter.Count = [int]$elevationCounter.Count + 1; throw 'no UAC expected' }.GetNewClosure()

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation $noUac -InputReader $reader

        $elevationCounter.Count | Should -Be 0
        $result.elevated | Should -BeFalse
        $result.status | Should -Be 'done'
        @($result.applied).Count | Should -Be 1

        $value = Get-PcxApplyRegistryState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338389Enabled'
        $value.exists | Should -BeTrue
        $value.type | Should -Be 'dword'
        [int]$value.data | Should -Be 0
    }
}

Describe 'resume' {

    It 'prompts before the first PENDING item after a resume' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture

        $first = & $script:Apply -PlanId $plan.planId -Mode agent
        $first.status | Should -Be 'partial'
        $secondId = [string]$first.next
        $resumeReader = New-PcxAnswerReader -Answers @('s')

        $result = & $script:Apply -PlanId $plan.planId -Mode console -StdinRedirected $false -Elevation (New-PcxElevatedRunner -Reader $resumeReader) -InputReader $resumeReader

        $result.status | Should -Be 'stopped'
        $result.prompts | Should -Be 1
        @($result.applied).Count | Should -Be 0
        $result.next | Should -Be $secondId

        $session = Get-PcxApplySession -Fixture $fixture -PlanId $plan.planId
        @($session.items | Where-Object { $_.status -eq 'COMMITTED' }).Count | Should -Be 1
        @($session.items | Where-Object { $_.status -eq 'PENDING' }).Count | Should -Be 1
    }

    It 'skips COMMITTED items before snapshotting and before the provider' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture

        $first = & $script:Apply -PlanId $plan.planId -Mode agent
        $committedId = [string]$first.applied[0]

        $sessionBefore = Get-PcxApplySession -Fixture $fixture -PlanId $plan.planId
        $snapshotsBefore = @(@($sessionBefore.items | Where-Object { $_.id -eq $committedId })[0].snapshots).Count

        $providerCalls = New-Object System.Collections.Generic.List[string]
        $recordingProvider = {
            param($context)
            [void]$providerCalls.Add([string]$context.target.Name)
            $target = $context.target
            $pre = Get-PcxTargetState -Target $target
            $snapshot = New-PcxSnapshot -Target $target -PreState $pre
            $null = Invoke-PcxPlatformWrite -Target $target
            return [ordered]@{ status = 'COMMITTED'; kind = 'service'; target = $target; code = $null; reason = 'ok'; snapshot = $snapshot; restorable = $true; restoreMode = 'snapshot' }
        }.GetNewClosure()

        $second = & $script:Apply -PlanId $plan.planId -Mode agent -Provider $recordingProvider
        $second.status | Should -Be 'done'

        @($providerCalls).Count | Should -Be 1
        $providerCalls[0] | Should -Be 'mapsbroker'

        $sessionAfter = Get-PcxApplySession -Fixture $fixture -PlanId $plan.planId
        $snapshotsAfter = @(@($sessionAfter.items | Where-Object { $_.id -eq $committedId })[0].snapshots).Count
        $snapshotsAfter | Should -Be $snapshotsBefore
    }
}

Describe 'drift and read-back' {

    It 'refuses a drifted target without writing' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture
        Set-PcxApplyStateStart -Fixture $fixture -ServiceName 'DiagTrack' -Start 4

        $result = & $script:Apply -PlanId $plan.planId -Mode agent

        @($result.itemResults).Count | Should -Be 1
        $result.itemResults[0].status | Should -Be 'FAILED'
        $result.itemResults[0].code | Should -Be 'PCX-E-APPLY-DRIFT'

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 4
        $state.services.mapsbroker.start | Should -Be 2
    }

    It 'inline-undoes a read-back mismatch and marks the item FAILED' {
        $fixture = New-PcxApplyFixture
        $plan = New-PcxApplyPlan -Fixture $fixture

        $badProvider = {
            param($context)
            $target = $context.target
            $pre = Get-PcxTargetState -Target $target
            $snapshot = New-PcxSnapshot -Target $target -PreState $pre
            $null = Invoke-PcxPlatformWrite -Target $target
            return [ordered]@{ status = 'FAILED'; kind = 'service'; target = $target; code = 'PCX-E-PROVIDER-READBACK'; reason = 'simulated read-back mismatch'; snapshot = $snapshot; restorable = $true; restoreMode = 'snapshot' }
        }

        $result = & $script:Apply -PlanId $plan.planId -Mode agent -Provider $badProvider

        $result.itemResults[0].status | Should -Be 'FAILED'
        $result.itemResults[0].code | Should -Be 'PCX-E-PROVIDER-READBACK'
        @($result.itemResults[0].undo).Count | Should -Be 1
        $result.itemResults[0].undo[0].status | Should -Be 'restored'

        $state = Get-PcxApplyStateFile -Fixture $fixture
        $state.services.diagtrack.start | Should -Be 2

        $session = Get-PcxApplySession -Fixture $fixture -PlanId $plan.planId
        @($session.items | Where-Object { $_.status -eq 'PENDING' }).Count | Should -Be 1
    }
}

Describe 'elevated child contract' {

    BeforeAll {
        $fixture = New-PcxApplyFixture
        $script:ElevatedFixture = $fixture
        $script:ElevatedPlan = New-PcxApplyPlan -Fixture $fixture
        $script:PlanBytes = [System.IO.File]::ReadAllBytes([string]$script:ElevatedPlan.written)
        $script:PlanHash = & $script:Module.ExportedCommands['Get-PcxSha256'] -Bytes $script:PlanBytes
        $script:PlanBase64 = [System.Convert]::ToBase64String($script:PlanBytes)
        $script:CurrentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }

    It 'accepts the exact bytes with the canonical hash and the matching SID' {
        $result = & $script:Elevated -PlanBytesBase64 $script:PlanBase64 -PlanHash $script:PlanHash -CallerSid $script:CurrentSid

        $result.ok | Should -BeTrue
        $result.planId | Should -Be $script:ElevatedPlan.planId
        $result.planHash | Should -Be $script:PlanHash
    }

    It 'refuses altered bytes with PCX-E-PLAN-MISMATCH' {
        $text = [System.Text.Encoding]::UTF8.GetString($script:PlanBytes)
        $altered = [System.Text.Encoding]::UTF8.GetBytes($text.Replace('diagtrack', 'diagtrackx'))

        $result = & $script:Elevated -PlanBytesBase64 ([System.Convert]::ToBase64String($altered)) -PlanHash $script:PlanHash -CallerSid $script:CurrentSid

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-PLAN-MISMATCH'
    }

    It 'refuses a plan over 8 KB' {
        $big = New-Object byte[] 9000
        for ($index = 0; $index -lt $big.Length; $index++) { $big[$index] = 65 }

        $result = & $script:Elevated -PlanBytesBase64 ([System.Convert]::ToBase64String($big)) -PlanHash (& $script:Module.ExportedCommands['Get-PcxSha256'] -Bytes $big) -CallerSid $script:CurrentSid

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-PLAN-TOO-LARGE'
    }

    It 'fails child validation for hash-consistent but invalid plan bytes' {
        $text = [System.Text.Encoding]::UTF8.GetString($script:PlanBytes)
        $altered = [System.Text.Encoding]::UTF8.GetBytes($text.Replace('diagtrack', 'diagtrackx'))
        $consistentHash = & $script:Module.ExportedCommands['Get-PcxSha256'] -Bytes $altered

        $result = & $script:Elevated -PlanBytesBase64 ([System.Convert]::ToBase64String($altered)) -PlanHash $consistentHash -CallerSid $script:CurrentSid

        $result.ok | Should -BeFalse
        [string]::IsNullOrWhiteSpace([string]$result.code) | Should -BeFalse
    }

    It 'refuses a SID mismatch' {
        $result = & $script:Elevated -PlanBytesBase64 $script:PlanBase64 -PlanHash $script:PlanHash -CallerSid 'S-1-5-21-0000000000-0000000000-0000000000-9999'

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-SID-MISMATCH'
    }

    It 'applies nothing when the elevated loop receives altered bytes' {
        $text = [System.Text.Encoding]::UTF8.GetString($script:PlanBytes)
        $altered = [System.Text.Encoding]::UTF8.GetBytes($text.Replace('diagtrack', 'diagtrackx'))
        $loop = $script:Module.ExportedCommands['Invoke-PcxApplyElevatedLoop']

        $result = & $loop -PlanBytesBase64 ([System.Convert]::ToBase64String($altered)) -PlanHash $script:PlanHash -CallerSid $script:CurrentSid -InputReader (New-PcxAnswerReader -Answers @('')) -StdinRedirected $false

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-PLAN-MISMATCH'
        @($result.applied).Count | Should -Be 0

        $state = Get-PcxApplyStateFile -Fixture $script:ElevatedFixture
        $state.services.diagtrack.start | Should -Be 2
        $state.services.mapsbroker.start | Should -Be 2
    }
}
