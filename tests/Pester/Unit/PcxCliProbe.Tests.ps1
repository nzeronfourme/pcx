<#
.SYNOPSIS
    pcx probe CLI surface plus the tune --proposals flag wiring.

.DESCRIPTION
    Proves the agent-freedom CLI surface on top of the unchanged engine:
    `pcx probe <spec>` wraps Invoke-PcxProbe exactly once per call and maps
    the typed result (family/status/value/unit/source/code/reason/target)
    into a standard ok envelope; unknown families and policy-denied targets
    refuse with a typed code and exit 2. `tune --proposals` without --apply
    refuses with a typed code. Every probe family is covered at least at
    shape level; reg/svc/task/file go through the fixture platform adapter,
    counter/event through a probe fixture, intent/environment through the
    desktop fixture. Fixture-only: PCX_TEST_RUN stays set, no live OS reads
    or writes. ASCII-only, CRLF, PowerShell 5.1 compatible.
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

    $script:PreviousStateFile = $env:PCX_TEST_STATE_FILE
    $script:PreviousEnvironmentFixture = $env:PCX_ENVIRONMENT_FIXTURE

    $script:StateFile = Join-Path -Path $TestDrive -ChildPath 'cli-probe-state.json'
    $env:PCX_TEST_STATE_FILE = $script:StateFile
    $env:PCX_ENVIRONMENT_FIXTURE = $null

    $registryPath = 'HKCU:\Software\PcxProbe'
    $registryName = 'Answer'
    $registryKey = $registryPath.ToLowerInvariant() + [char]0x1F + $registryName.ToLowerInvariant()
    $taskPath = '\Microsoft\Windows\PcxProbe'
    $filePath = 'C:\pcx-probe-fixture\probe.txt'

    $state = [ordered]@{
        schema   = 'pcx-platform-test/1'
        registry = [ordered]@{
            $registryKey = [ordered]@{
                path = $registryPath
                name = $registryName
                type = 'dword'
                data = 42
            }
        }
        services = [ordered]@{
            'spooler' = [ordered]@{
                name       = 'Spooler'
                controlSet = 'ControlSet001'
                start      = 2
            }
        }
        tasks    = [ordered]@{
            $taskPath.ToLowerInvariant() = [ordered]@{
                path    = $taskPath
                enabled = $true
                state   = 'Ready'
            }
        }
        files    = [ordered]@{
            $filePath.ToLowerInvariant() = [ordered]@{
                path           = $filePath
                contentBase64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('hello'))
                attributes     = 'Archive'
                isReparsePoint = $false
            }
        }
    }

    $stateJson = ConvertTo-Json -InputObject $state -Depth 10 -Compress
    [System.IO.File]::WriteAllText($script:StateFile, $stateJson, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

    $script:ProbeFixture = Join-Path -Path $TestDrive -ChildPath 'cli-probe-fixture'
    $null = [System.IO.Directory]::CreateDirectory($script:ProbeFixture)

    $probeDocument = [ordered]@{
        counters = [ordered]@{
            '\Processor(_Total)\% Processor Time' = 12.5
            '\Memory\Available MBytes'            = 4096
        }
        events   = @(
            [ordered]@{ logName = 'Microsoft-Windows-TaskScheduler/Operational'; providerName = 'Microsoft-Windows-TaskScheduler'; id = 106; level = 4; timeCreated = '2026-10-29T10:00:00Z' }
            [ordered]@{ logName = 'Microsoft-Windows-TaskScheduler/Operational'; providerName = 'Microsoft-Windows-TaskScheduler'; id = 106; level = 4; timeCreated = '2026-10-29T11:00:00Z' }
        )
    }

    $probeJson = ConvertTo-Json -InputObject $probeDocument -Depth 10 -Compress
    [System.IO.File]::WriteAllText((Join-Path -Path $script:ProbeFixture -ChildPath 'probe.json'), $probeJson, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

    Import-Module -Name $modulePath -Force

    $pcxModule = Get-Module -Name 'Pcx'
    $script:Dispatch = $pcxModule.ExportedCommands['Invoke-PcxDispatch']

    $script:DesktopFixture = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment/desktop'

    function Assert-PcxCliProbeShape {
        param([Parameter(Mandatory = $true)][AllowNull()][object] $Data)

        ($null -ne $Data) | Should -BeTrue
        foreach ($key in @('family', 'status', 'value', 'unit', 'source', 'code', 'reason', 'target')) {
            (($Data.Keys -contains $key)) | Should -BeTrue -Because "probe data lacks '$key'"
        }

        [string]$Data.status | Should -BeIn @('measured', 'unavailable', 'unreliable')
        if ([string]$Data.status -ne 'measured') {
            ($null -eq $Data.value) | Should -BeTrue
        }
    }
}

AfterAll {
    $env:PCX_TEST_STATE_FILE = $script:PreviousStateFile
    $env:PCX_ENVIRONMENT_FIXTURE = $script:PreviousEnvironmentFixture
}

Describe 'probe help surface' {

    It 'lists probe in commands, usage and the proposals flag' {
        $help = & $script:Dispatch -Arguments @('--help')

        [int]$help.ExitCode | Should -Be 0
        ($help.Envelope.data.commands -contains 'probe') | Should -BeTrue
        ($help.Envelope.data.flags -contains '--proposals') | Should -BeTrue
        (($help.Envelope.data.usage -join "`n") -match 'pcx probe') | Should -BeTrue
        (($help.Envelope.data.usage -join "`n") -match '--proposals') | Should -BeTrue
    }
}

Describe 'probe command: platform families' {

    It 'measures a registry value through the CLI envelope' {
        $result = & $script:Dispatch -Arguments @('probe', 'reg:HKCU:\Software\PcxProbe#Answer')

        [int]$result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -Be 'ok'
        $result.Envelope.command | Should -Be 'probe'
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'reg'
        [string]$result.Envelope.data.status | Should -BeExactly 'measured'
        $result.Envelope.data.value | Should -Be 42
    }

    It 'measures a service start type through the CLI envelope' {
        $result = & $script:Dispatch -Arguments @('probe', 'svc:Spooler')

        [int]$result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -Be 'ok'
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'svc'
        $result.Envelope.data.value | Should -Be 2
    }

    It 'measures a scheduled task state through the CLI envelope' {
        $result = & $script:Dispatch -Arguments @('probe', 'task:\Microsoft\Windows\PcxProbe')

        [int]$result.ExitCode | Should -Be 0
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'task'
        [string]$result.Envelope.data.status | Should -BeExactly 'measured'
        [bool]$result.Envelope.data.value | Should -BeTrue
    }

    It 'measures file state through the CLI envelope' {
        $result = & $script:Dispatch -Arguments @('probe', 'file:C:\pcx-probe-fixture\probe.txt')

        [int]$result.ExitCode | Should -Be 0
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'file'
        [bool]$result.Envelope.data.value.exists | Should -BeTrue
    }
}

Describe 'probe command: counter, event, intent, environment' {

    It 'measures a counter from the probe fixture' {
        $result = & $script:Dispatch -Arguments @('probe', 'counter:\Processor(_Total)\% Processor Time', '--fixture', $script:ProbeFixture)

        [int]$result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -Be 'ok'
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'counter'
        $result.Envelope.data.value | Should -Be 12.5
    }

    It 'measures a filtered event count from the probe fixture' {
        $result = & $script:Dispatch -Arguments @('probe', 'event:Microsoft-Windows-TaskScheduler/Operational;Id=106', '--fixture', $script:ProbeFixture)

        [int]$result.ExitCode | Should -Be 0
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'event'
        $result.Envelope.data.value | Should -Be 2
    }

    It 'measures intent usage from the desktop fixture' {
        $result = & $script:Dispatch -Arguments @('probe', 'intent:u4', '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 0
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'intent'
        [bool]$result.Envelope.data.value.positive | Should -BeTrue
    }

    It 'measures the environment from the desktop fixture' {
        $result = & $script:Dispatch -Arguments @('probe', 'environment:', '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 0
        Assert-PcxCliProbeShape -Data $result.Envelope.data
        [string]$result.Envelope.data.family | Should -BeExactly 'environment'
        [string]$result.Envelope.data.value.schema | Should -BeExactly 'pcx-environment/1'
    }
}

Describe 'probe command refusals' {

    It 'refuses an unknown family with a typed code' {
        $result = & $script:Dispatch -Arguments @('probe', 'bogus:something')

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.status | Should -Be 'refused'
        $result.Envelope.command | Should -Be 'probe'
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-PROBE-ARG'
    }

    It 'refuses a policy-denied target before touching the OS' {
        $result = & $script:Dispatch -Arguments @('probe', 'task:\Microsoft\Windows\Defrag', '--fixture', $script:DesktopFixture)

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.status | Should -Be 'refused'
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-POLICY-TASK-SYSTEM'
    }

    It 'refuses a missing spec with a typed code' {
        $result = & $script:Dispatch -Arguments @('probe')

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-PROBE-ARG'
    }

    It 'refuses a second spec: exactly one probe per call' {
        $result = & $script:Dispatch -Arguments @('probe', 'svc:Spooler', 'svc:Spooler')

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-PROBE-ARG'
    }

    It 'refuses tune --proposals without --apply with a typed code' {
        $result = & $script:Dispatch -Arguments @('tune', '--fixture', $script:DesktopFixture, '--proposals', 'proposals.json')

        [int]$result.ExitCode | Should -Be 2
        $result.Envelope.status | Should -Be 'refused'
        $result.Envelope.diagnostics[0].code | Should -Be 'PCX-E-SCAN-ARG'
    }
}

Describe 'probe stays read-only' {

    It 'never arms real writes while probing' {
        $env:PCX_ALLOW_REAL_WRITES = $null

        $first = & $script:Dispatch -Arguments @('probe', 'svc:Spooler')
        [int]$first.ExitCode | Should -Be 0

        $second = & $script:Dispatch -Arguments @('probe', 'task:\Microsoft\Windows\PcxProbe')
        [int]$second.ExitCode | Should -Be 0

        $env:PCX_ALLOW_REAL_WRITES | Should -BeExactly $null
    }
}
