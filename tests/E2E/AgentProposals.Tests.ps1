<#
.SYNOPSIS
    Agent proposals end to end through the CLI (tune --apply --proposals).

.DESCRIPTION
    Proves the write half of the agent-freedom surface without touching the
    engine: an agent-invented task target outside the seed catalog travels
    from a pcx-proposals/1 document through Invoke-PcxPlan validation into
    the normal one-item agent apply path with snapshot and hash-proven undo.
    Refusals (missing file, bad schema, unknown action id, evidence-domain
    mismatch, policy denial) each exit 2 with a typed code and change nothing:
    the canonical state SHA-256 is identical before and after. Fixture-only:
    PCX_TEST_RUN stays set, the test platform adapter owns every write, and
    the elevated undo child runs in-process through an injected runner, so no
    live OS state is ever touched. ASCII-only, CRLF, PowerShell 5.1
    compatible.
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
    $script:Dispatch = $script:Module.ExportedCommands['Invoke-PcxDispatch']
    $script:Undo = $script:Module.ExportedCommands['Invoke-PcxUndo']
    $script:ReadJson = $script:Module.ExportedCommands['Read-PcxJson']
    $script:CanonicalJson = $script:Module.ExportedCommands['ConvertTo-PcxCanonicalJson']
    $script:Sha256 = $script:Module.ExportedCommands['Get-PcxSha256']
    $script:PlatformRead = $script:Module.ExportedCommands['Invoke-PcxPlatformRead']

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:ProposalsPath = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/proposals/agent-discovered.json'

    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE

    function New-PcxAgentProposalFixture {
        param([Parameter(Mandatory = $false)][string] $Name = 'proposals')

        $root = Join-Path -Path $TestDrive -ChildPath ($Name + '-' + [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($root)

        $env:LOCALAPPDATA = $root
        $stateFile = Join-Path -Path $root -ChildPath 'state.json'
        $env:PCX_TEST_STATE_FILE = $stateFile

        $state = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = @{}
            services = [ordered]@{}
            tasks    = [ordered]@{
                '\startup\example app' = [ordered]@{ path = '\startup\example app'; enabled = $true; state = 'Ready' }
                '\pcxdemo\agentfound'  = [ordered]@{ path = '\pcxdemo\agentfound'; enabled = $true; state = 'Ready' }
            }
            files    = [ordered]@{}
        }

        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject $state -Depth 8), $utf8)

        return [pscustomobject]@{
            Root      = $root
            StateFile = $stateFile
        }
    }

    function Get-PcxAgentProposalState {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Fixture.StateFile)) -ErrorAction Stop)
    }

    function Get-PcxAgentProposalStateHash {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        $document = Get-PcxAgentProposalState -Fixture $Fixture
        return (& $script:Sha256 -Text (& $script:CanonicalJson -InputObject $document))
    }

    function New-PcxAgentProposalUndoRunner {
        param([Parameter(Mandatory = $true)][object] $Counter)

        $module = Get-Module -Name 'Pcx'
        return {
            param($request)
            $Counter.Count = [int]$Counter.Count + 1
            return & $module.ExportedCommands['Invoke-PcxUndoElevatedLoop'] -RequestBytesBase64 $request.payloadBase64 -RequestHash $request.requestHash -CallerSid $request.callerSid
        }.GetNewClosure()
    }

    function Write-PcxAgentProposalFile {
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $true)][string] $ActionId,
            [Parameter(Mandatory = $true)][string] $TargetPath,
            [Parameter(Mandatory = $true)][string] $Domain,
            [Parameter(Mandatory = $false)][string] $Schema = 'pcx-proposals/1'
        )

        $document = [ordered]@{
            schema    = $Schema
            proposals = @(
                [ordered]@{
                    actionId = $ActionId
                    target   = [ordered]@{ Kind = 'task'; Path = $TargetPath; Enabled = $false }
                    evidence = [ordered]@{ kind = 'telemetry'; metric = 'startup.task_history_events'; domain = $Domain; value = 9; status = 'measured'; window = '7d' }
                }
            )
        }

        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 8), $utf8)
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
    $env:PCX_ALLOW_REAL_WRITES = $null
}

Describe 'agent proposals: invented target validated, applied, undone' {

    BeforeAll {
        $script:Happy = New-PcxAgentProposalFixture -Name 'proposals-happy'
        $script:HappyInitialHash = Get-PcxAgentProposalStateHash -Fixture $script:Happy

        $script:HappyApply = & $script:Dispatch -Arguments @('tune', '--apply', '--proposals', $script:ProposalsPath, '--fixture', $script:DesktopFixture)
        $script:HappyPlanId = [string]$script:HappyApply.Envelope.data.planId
    }

    It 'validates the invented target and applies exactly one item' {
        [int]$script:HappyApply.ExitCode | Should -Be 0
        $script:HappyApply.Envelope.status | Should -Be 'ok'
        $script:HappyApply.Envelope.command | Should -Be 'tune'
        $script:HappyPlanId | Should -Match '^[0-9a-f]{16}$'

        [string]$script:HappyApply.Envelope.data.status | Should -BeExactly 'done'
        @($script:HappyApply.Envelope.data.applied).Count | Should -Be 1
        [string]$script:HappyApply.Envelope.data.itemResults[0].status | Should -BeExactly 'COMMITTED'
        [string]$script:HappyApply.Envelope.data.applied[0] | Should -BeExactly ([string]$script:HappyApply.Envelope.data.itemResults[0].id)
        [string]$script:HappyApply.Envelope.data.itemResults[0].actionId | Should -BeExactly 'startup-task-u4'
    }

    It 'leaves nothing pending: a second call reports done with no new write' {
        $resume = & $script:Dispatch -Arguments @('tune', '--apply', '--plan', $script:HappyPlanId)

        [int]$resume.ExitCode | Should -Be 0
        [string]$resume.Envelope.data.status | Should -BeExactly 'done'
        @($resume.Envelope.data.applied).Count | Should -Be 0
    }

    It 'disables the invented task through the platform boundary' {
        $read = & $script:PlatformRead -Target @{ Kind = 'task'; Path = '\PcxDemo\AgentFound' }

        [bool]$read.exists | Should -BeTrue
        [bool]$read.enabled | Should -BeFalse
    }

    It 'restores the pre-state with SHA-256 equality on undo' {
        $counter = @{ Count = 0 }
        $runner = New-PcxAgentProposalUndoRunner -Counter $counter
        $outcome = & $script:Undo -PlanId $script:HappyPlanId -Elevation $runner -Restore { param($snapshot) throw 'the parent must not write' }

        [bool]$outcome.ok | Should -BeTrue
        [int]$outcome.elevationCalls | Should -Be 1
        @($outcome.restored).Count | Should -Be 1

        $afterUndo = & $script:PlatformRead -Target @{ Kind = 'task'; Path = '\PcxDemo\AgentFound' }
        [bool]$afterUndo.enabled | Should -BeTrue

        (Get-PcxAgentProposalStateHash -Fixture $script:Happy) | Should -BeExactly $script:HappyInitialHash
    }
}

Describe 'agent proposals refusals write nothing' {

    It 'refuses a missing proposals file with a typed code' {
        $fixture = New-PcxAgentProposalFixture -Name 'proposals-missing'
        $before = Get-PcxAgentProposalStateHash -Fixture $fixture
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-proposals.json'

        $result = & $script:Dispatch -Arguments @('tune', '--apply', '--proposals', $missing, '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.status | Should -Be 'refused'
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-PROPOSALS-FILE'
        (Get-PcxAgentProposalStateHash -Fixture $fixture) | Should -BeExactly $before
    }

    It 'refuses an invalid proposals schema with a typed code' {
        $fixture = New-PcxAgentProposalFixture -Name 'proposals-schema'
        $before = Get-PcxAgentProposalStateHash -Fixture $fixture
        $path = Join-Path -Path $TestDrive -ChildPath 'proposals-bad-schema.json'
        Write-PcxAgentProposalFile -Path $path -ActionId 'startup-task-u4' -TargetPath '\PcxDemo\AgentFound' -Domain 'startup' -Schema 'pcx-proposals/999'

        $result = & $script:Dispatch -Arguments @('tune', '--apply', '--proposals', $path, '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-PROPOSALS-SCHEMA'
        (Get-PcxAgentProposalStateHash -Fixture $fixture) | Should -BeExactly $before
    }

    It 'refuses an unknown action id with a typed code' {
        $fixture = New-PcxAgentProposalFixture -Name 'proposals-action'
        $before = Get-PcxAgentProposalStateHash -Fixture $fixture
        $path = Join-Path -Path $TestDrive -ChildPath 'proposals-bad-action.json'
        Write-PcxAgentProposalFile -Path $path -ActionId 'no-such-action' -TargetPath '\PcxDemo\AgentFound' -Domain 'startup'

        $result = & $script:Dispatch -Arguments @('tune', '--apply', '--proposals', $path, '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-PLAN-ACTION'
        (Get-PcxAgentProposalStateHash -Fixture $fixture) | Should -BeExactly $before
    }

    It 'refuses an evidence-domain mismatch with a typed code' {
        $fixture = New-PcxAgentProposalFixture -Name 'proposals-domain'
        $before = Get-PcxAgentProposalStateHash -Fixture $fixture
        $path = Join-Path -Path $TestDrive -ChildPath 'proposals-bad-domain.json'
        Write-PcxAgentProposalFile -Path $path -ActionId 'startup-task-u4' -TargetPath '\PcxDemo\AgentFound' -Domain 'ads'

        $result = & $script:Dispatch -Arguments @('tune', '--apply', '--proposals', $path, '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-EVIDENCE-DOMAIN'
        (Get-PcxAgentProposalStateHash -Fixture $fixture) | Should -BeExactly $before
    }

    It 'refuses a policy-denied target with a typed code' {
        $fixture = New-PcxAgentProposalFixture -Name 'proposals-policy'
        $before = Get-PcxAgentProposalStateHash -Fixture $fixture
        $path = Join-Path -Path $TestDrive -ChildPath 'proposals-denied.json'
        Write-PcxAgentProposalFile -Path $path -ActionId 'startup-task-u4' -TargetPath '\Microsoft\Windows\AgentDenied' -Domain 'startup'

        $result = & $script:Dispatch -Arguments @('tune', '--apply', '--proposals', $path, '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-POLICY-TASK-SYSTEM'
        (Get-PcxAgentProposalStateHash -Fixture $fixture) | Should -BeExactly $before
    }
}
