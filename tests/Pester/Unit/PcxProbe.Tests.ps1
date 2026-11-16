<#
.SYNOPSIS
    Typed read-only probe command (todo 9).

.DESCRIPTION
    Proves the probe contract without any live probe: all eight families return
    one typed result object, reg/svc/task/file go through the platform adapter,
    counters resolve a localized path through PdhAddEnglishCounter, events use a
    filtered query only and refuse an unfiltered one, U4 intent is re-measured,
    the environment comes from a fixture, fixture mode refuses instead of
    touching the OS, and the source declares no write path.
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

    $script:StateFile = Join-Path -Path $TestDrive -ChildPath 'platform-state.json'
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

    $script:ProbeFixture = Join-Path -Path $TestDrive -ChildPath 'probe-fixture'
    $null = [System.IO.Directory]::CreateDirectory($script:ProbeFixture)

    $probeDocument = [ordered]@{
        counters = [ordered]@{
            '\Processor(_Total)\% Processor Time' = 12.5
            '\Memory\Available MBytes'            = 4096
        }
        events   = @(
            [ordered]@{ logName = 'Microsoft-Windows-TaskScheduler/Operational'; providerName = 'Microsoft-Windows-TaskScheduler'; id = 106; level = 4; timeCreated = '2026-10-29T10:00:00Z' }
            [ordered]@{ logName = 'Microsoft-Windows-TaskScheduler/Operational'; providerName = 'Microsoft-Windows-TaskScheduler'; id = 106; level = 4; timeCreated = '2026-10-29T11:00:00Z' }
            [ordered]@{ logName = 'Microsoft-Windows-TaskScheduler/Operational'; providerName = 'Microsoft-Windows-TaskScheduler'; id = 107; level = 4; timeCreated = '2026-10-29T12:00:00Z' }
        )
    }

    $probeJson = ConvertTo-Json -InputObject $probeDocument -Depth 10 -Compress
    [System.IO.File]::WriteAllText((Join-Path -Path $script:ProbeFixture -ChildPath 'probe.json'), $probeJson, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

    Import-Module -Name $modulePath -Force

    $pcxModule = Get-Module -Name 'Pcx'
    $script:Module = $pcxModule
    $script:Probe = $pcxModule.ExportedCommands['Invoke-PcxProbe']
    $script:Dispatch = $pcxModule.ExportedCommands['Invoke-PcxDispatch']

    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:ProbeSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Commands/Invoke-PcxProbe.ps1'

    $script:RegistryTarget = [ordered]@{ Kind = 'registry'; Path = $registryPath; Name = $registryName }
    $script:ServiceTarget = [ordered]@{ Kind = 'service'; Name = 'Spooler' }
    $script:TaskTarget = [ordered]@{ Kind = 'task'; Path = $taskPath }
    $script:FileTarget = [ordered]@{ Kind = 'file'; Path = $filePath }

    function Assert-ProbeShape {
        param([Parameter(Mandatory = $true)][AllowNull()][object] $Result)

        ($null -ne $Result) | Should -BeTrue
        $Result.PSObject.TypeNames[0] |
            Should -Be 'System.Management.Automation.PSCustomObject'

        foreach ($key in @('family', 'status', 'value', 'unit', 'source', 'code', 'reason', 'target')) {
            ($Result.PSObject.Properties.Name -contains $key) | Should -BeTrue -Because "probe result lacks '$key'"
        }

        $Result.status | Should -BeIn @('measured', 'unavailable', 'unreliable', 'refused')
        if ($Result.status -ne 'measured') {
            ($null -eq $Result.value) | Should -BeTrue -Because "a $($Result.status) result must not carry a guessed value"
            ([string]::IsNullOrWhiteSpace([string]$Result.code)) | Should -BeFalse -Because "a $($Result.status) result must carry a typed code"
        }
    }
}

AfterAll {
    $env:PCX_TEST_STATE_FILE = $script:PreviousStateFile
    $env:PCX_ENVIRONMENT_FIXTURE = $script:PreviousEnvironmentFixture
}

Describe 'probe surface' {

    It 'exports Invoke-PcxProbe and lists probe as a user-facing command' {
        ($null -ne $script:Probe) | Should -BeTrue

        $help = & $script:Dispatch -Arguments @('--help')
        ($help.Envelope.data.commands -contains 'probe') | Should -BeTrue -Because 'the agent probe surface is user-facing'
        (($help.Envelope.data.usage -join "`n") -match 'pcx probe') | Should -BeTrue
    }
}

Describe 'platform-backed families' {

    It 'measures a registry value through the platform boundary' {
        $result = & $script:Probe -Probe 'reg:HKCU:\Software\PcxProbe#Answer'

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'reg'
        $result.status | Should -Be 'measured'
        $result.value | Should -Be 42
        $result.unit | Should -Be 'registry:dword'
        $result.source | Should -Be 'platform:registry'
        $result.target.Path | Should -Be 'HKCU:\Software\PcxProbe'
    }

    It 'returns unavailable, not a zero, for an unset registry value' {
        $result = & $script:Probe -Probe 'reg:HKCU:\Software\PcxProbe#Missing'

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'unavailable'
        $result.code | Should -Be 'PCX-E-PROBE-NOT-FOUND'
        ($null -eq $result.value) | Should -BeTrue
    }

    It 'measures a service start type' {
        $result = & $script:Probe -Probe 'svc:Spooler'

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'svc'
        $result.status | Should -Be 'measured'
        $result.value | Should -Be 2
        $result.unit | Should -Be 'start-type'
    }

    It 'measures a scheduled task enabled state' {
        $result = & $script:Probe -Probe 'task:\Microsoft\Windows\PcxProbe'

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'task'
        $result.status | Should -Be 'measured'
        $result.value | Should -BeTrue
    }

    It 'measures file state including the SHA-256 of the bytes' {
        $result = & $script:Probe -Probe 'file:C:\pcx-probe-fixture\probe.txt'

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'file'
        $result.status | Should -Be 'measured'
        $result.value.exists | Should -BeTrue
        $result.value.length | Should -Be 5
        ([string]::IsNullOrWhiteSpace([string]$result.value.sha256)) | Should -BeFalse
    }
}

Describe 'counter family' {

    It 'resolves a localized counter path through PdhAddEnglishCounter' {
        $result = & $script:Probe -Probe 'counter:\Prozessor(_Total)\Prozessorzeit (%)' -FixturePath $script:ProbeFixture

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'counter'
        $result.status | Should -Be 'measured'
        $result.value | Should -Be 12.5
        $result.source | Should -Match 'PdhAddEnglishCounter'
        $result.target.english | Should -Be '\Processor(_Total)\% Processor Time'
    }

    It 'never returns a zero for a counter the fixture does not hold' {
        $result = & $script:Probe -Probe 'counter:\Processor(_Total)\% Idle Time' -FixturePath $script:ProbeFixture

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'unavailable'
        $result.code | Should -Be 'PCX-E-PROBE-COUNTER-UNAVAILABLE'
        ($null -eq $result.value) | Should -BeTrue
    }

    It 'refuses a counter probe with no fixture in fixture mode' {
        $result = & $script:Probe -Probe 'counter:\Processor(_Total)\% Processor Time'

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'refused'
        $result.code | Should -Be 'PCX-E-PROBE-FIXTURE'
    }
}

Describe 'event family' {

    It 'refuses an unfiltered event query' {
        $result = & $script:Probe -Probe 'event:System'

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'event'
        $result.status | Should -Be 'refused'
        $result.code | Should -Be 'PCX-E-PROBE-EVENT-UNFILTERED'
    }

    It 'refuses an unfiltered query even when a fixture is supplied' {
        $result = & $script:Probe -Probe 'event:System' -FixturePath $script:ProbeFixture

        Assert-ProbeShape -Result $result
        $result.code | Should -Be 'PCX-E-PROBE-EVENT-UNFILTERED'
    }

    It 'measures a filtered event count from the fixture' {
        $result = & $script:Probe -Probe 'event:Microsoft-Windows-TaskScheduler/Operational;Id=106' -FixturePath $script:ProbeFixture

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'measured'
        $result.value | Should -Be 2
        $result.unit | Should -Be 'events'
    }

    It 'reports an empty filtered result as unavailable, not zero' {
        $result = & $script:Probe -Probe 'event:Microsoft-Windows-TaskScheduler/Operational;Id=999' -FixturePath $script:ProbeFixture

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'unavailable'
        $result.code | Should -Be 'PCX-E-PROBE-EVENT-EMPTY'
        ($null -eq $result.value) | Should -BeTrue
    }

    It 'refuses a filtered live event query with no fixture in fixture mode' {
        $result = & $script:Probe -Probe 'event:System;Id=41'

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'refused'
        $result.code | Should -Be 'PCX-E-PROBE-FIXTURE'
    }
}

Describe 'intent family' {

    It 're-measures U4 usage from the fixture' {
        $result = & $script:Probe -Probe 'intent:u4' -FixturePath $script:DesktopFixture

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'intent'
        $result.status | Should -Be 'measured'
        $result.value.userAssistEntries | Should -Be 87
        $result.value.prefetchFiles | Should -Be 142
        $result.value.taskHistoryEvents | Should -Be 9
        $result.value.positive | Should -BeTrue
    }

    It 're-measures one usage metric' {
        $result = & $script:Probe -Probe 'intent:prefetch' -FixturePath $script:DesktopFixture

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'measured'
        $result.value | Should -Be 142
    }

    It 'refuses an intent probe with no fixture in fixture mode' {
        $result = & $script:Probe -Probe 'intent:u4'

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'refused'
        $result.code | Should -Be 'PCX-E-PROBE-FIXTURE'
    }
}

Describe 'environment family' {

    It 'returns the environment object from the fixture' {
        $result = & $script:Probe -Probe 'environment:' -FixturePath $script:DesktopFixture

        Assert-ProbeShape -Result $result
        $result.family | Should -Be 'environment'
        $result.status | Should -Be 'measured'
        $result.value.schema | Should -Be 'pcx-environment/1'
        $result.value.os.build.value | Should -Be 22631
    }

    It 'refuses a live environment read in fixture mode without a fixture' {
        $result = & $script:Probe -Probe 'environment:'

        Assert-ProbeShape -Result $result
        $result.status | Should -Be 'refused'
        $result.code | Should -Be 'PCX-E-ENVIRONMENT-FIXTURE'
    }
}

Describe 'probe source safety' {

    BeforeAll {
        $script:ProbeSource = [System.IO.File]::ReadAllText($script:ProbeSourcePath)
    }

    It 'contains no write path and no banned command' {
        $banned = @(
            'Invoke-PcxPlatformWrite'
            'Invoke-PcxPlatformDelete'
            'Invoke-PcxPlatformMove'
            'Set-ItemProperty'
            'New-ItemProperty'
            'Remove-ItemProperty'
            'Set-Service'
            'Enable-ScheduledTask'
            'Disable-ScheduledTask'
            'Remove-Item'
            'Invoke-Expression'
            'cmd /c'
            'reg.exe'
            'sc.exe'
            'schtasks.exe'
            'Win32_Product'
            'PdhAddCounter'
        )

        foreach ($token in $banned) {
            $script:ProbeSource | Should -Not -Match ([regex]::Escape($token)) -Because "probe code must not use '$token'"
        }
    }

    It 'routes reads through the platform boundary and the typed APIs' {
        $script:ProbeSource | Should -Match 'Invoke-PcxPlatformRead'
        $script:ProbeSource | Should -Match 'PdhAddEnglishCounter'
        $script:ProbeSource | Should -Match ([regex]::Escape('Get-WinEvent -FilterHashtable'))
        $script:ProbeSource | Should -Match 'Get-PcxEnvironment'
        $script:ProbeSource | Should -Match 'Get-PcxCollectorIntent'
    }

    It 'has no native registry read in reg/svc/task/file' {
        $script:ProbeSource | Should -Not -Match 'Get-ItemProperty'
        $script:ProbeSource | Should -Not -Match 'Get-ScheduledTask'
        $script:ProbeSource | Should -Not -Match 'Get-Service'
    }
}
