<#
.SYNOPSIS
    Undo and status (todo 13).

.DESCRIPTION
    Undo restores the exact pre-state and exits 0 only when every restorable
    item matches. The journal is untrusted: a changed target, an edited journal
    target and a moved service control set all exit 3 and revert nothing. A
    mixed plan reports A1 as not restorable and still exits 0. Quarantine
    restores byte-identically. An admin undo makes exactly ONE injected UAC and
    the parent performs no write. A second undo refuses. `status` (internal,
    read-only) lists applied and undone items.

    No test prompts a human, performs a real UAC or writes to the live OS.
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
    $script:Undo = $script:Module.ExportedCommands['Invoke-PcxUndo']
    $script:UndoElevated = $script:Module.ExportedCommands['Invoke-PcxUndoElevated']
    $script:UndoLoop = $script:Module.ExportedCommands['Invoke-PcxUndoElevatedLoop']
    $script:Status = $script:Module.ExportedCommands['Invoke-PcxStatus']
    $script:Apply = $script:Module.ExportedCommands['Invoke-PcxApply']
    $script:Plan = $script:Module.ExportedCommands['Invoke-PcxPlan']
    $script:Dispatch = $script:Module.ExportedCommands['Invoke-PcxDispatch']
    $script:ReadJson = $script:Module.ExportedCommands['Read-PcxJson']
    $script:ScanCommand = $script:Module.ExportedCommands['Get-PcxScan']
    $script:Sha256 = $script:Module.ExportedCommands['Get-PcxSha256']

    $script:Scan = & $script:ScanCommand -FixturePath (Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment/desktop')

    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE
    $script:FixtureCounter = 0

    $script:TipsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $script:TipsName = 'SubscribedContent-338389Enabled'
    $script:AdsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
    $script:AdsName = 'Enabled'

    function Get-PcxUndoRegistryKey {
        param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Name)

        return ($Path.ToLowerInvariant() + [char]0x1F + $Name.ToLowerInvariant())
    }

    function Write-PcxUndoStateFile {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][object] $State)

        $json = ConvertTo-Json -InputObject $State -Depth 10
        [System.IO.File]::WriteAllText($Fixture.StateFile, $json, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    }

    function Get-PcxUndoStateFile {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        return (Get-Content -LiteralPath $Fixture.StateFile -Raw | ConvertFrom-Json)
    }

    function Add-PcxUndoFileRecord {
        param(
            [Parameter(Mandatory = $true)][object] $State,
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $false)][string] $Content = 'fixture-content'
        )

        $key = $Path.ToLowerInvariant()
        $State.files[$key] = [ordered]@{
            path           = $Path
            contentBase64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
            attributes     = 'Archive'
            isReparsePoint = $false
        }
    }

    function New-PcxUndoFixture {
        param(
            [Parameter(Mandatory = $false)][int] $DiagTrackStart = 2,
            [Parameter(Mandatory = $false)][int] $MapsBrokerStart = 2
        )

        $script:FixtureCounter = [int]$script:FixtureCounter + 1
        $root = Join-Path -Path $TestDrive -ChildPath ('undo-fixture-' + $script:FixtureCounter + '-' + [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($root)

        $env:LOCALAPPDATA = $root
        $stateFile = Join-Path -Path $root -ChildPath 'state.json'
        $env:PCX_TEST_STATE_FILE = $stateFile

        $registry = @{}
        $registry[(Get-PcxUndoRegistryKey -Path $script:TipsPath -Name $script:TipsName)] = [ordered]@{
            path = $script:TipsPath
            name = $script:TipsName
            type = 'dword'
            data = 1
        }
        $registry[(Get-PcxUndoRegistryKey -Path $script:AdsPath -Name $script:AdsName)] = [ordered]@{
            path = $script:AdsPath
            name = $script:AdsName
            type = 'dword'
            data = 1
        }

        $state = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = $registry
            services = [ordered]@{
                diagtrack  = [ordered]@{ name = 'DiagTrack'; controlSet = 'ControlSet001'; start = $DiagTrackStart }
                mapsbroker = [ordered]@{ name = 'MapsBroker'; controlSet = 'ControlSet001'; start = $MapsBrokerStart }
            }
            tasks    = @{}
            files    = @{}
        }

        $profile = [ordered]@{
            managed      = $false
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            build        = 26100
            environment  = [ordered]@{
                LOCALAPPDATA = $root
                APPDATA      = (Join-Path $root 'Roaming')
                PROGRAMDATA  = 'C:\ProgramData'
                SYSTEMROOT   = 'C:\Windows'
            }
            serviceFacts = [ordered]@{
                diagtrack  = [ordered]@{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
                mapsbroker = [ordered]@{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
            }
        }

        $fixture = [pscustomobject]@{ Root = $root; StateFile = $stateFile; Profile = $profile; State = $state }
        Write-PcxUndoStateFile -Fixture $fixture -State $state

        return $fixture
    }

    function New-PcxUndoRegistryProposal {
        param(
            [Parameter(Mandatory = $true)][string] $ActionId,
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $true)][string] $Name,
            [Parameter(Mandatory = $true)][string] $Domain,
            [Parameter(Mandatory = $true)][string] $Metric
        )

        return [ordered]@{
            actionId = $ActionId
            target   = [ordered]@{ Kind = 'registry'; Path = $Path; Name = $Name }
            evidence = [ordered]@{
                kind   = 'telemetry'
                metric = $Metric
                domain = $Domain
                value  = 1
                status = 'measured'
                window = 'instant'
            }
        }
    }

    function New-PcxUndoServiceProposal {
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

    function New-PcxUndoA1Proposal {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        $directory = Join-Path -Path $Fixture.Root -ChildPath 'Microsoft\Windows\Explorer'
        $targets = @()
        foreach ($name in @('thumbcache_32.db', 'thumbcache_96.db', 'thumbcache_256.db', 'thumbcache_1024.db')) {
            $targets += [ordered]@{ Kind = 'file'; Path = (Join-Path $directory $name); Role = 'a1' }
        }

        return [ordered]@{
            actionId = 'thumbnails'
            target   = $targets
            evidence = [ordered]@{
                kind   = 'telemetry'
                metric = 'storage.system_free_bytes'
                domain = 'storage'
                value  = 343597383680
                status = 'measured'
                window = 'instant'
                root   = $directory
            }
        }
    }

    function New-PcxUndoQuarantineProposal {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        $startup = Join-Path -Path $Fixture.Root -ChildPath 'Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $source = Join-Path -Path $startup -ChildPath 'OneDrive.lnk'

        return [ordered]@{
            actionId = 'startup-shortcut-u4'
            target   = [ordered]@{ Kind = 'file'; Path = $source; Role = 'quarantine' }
            evidence = [ordered]@{
                kind   = 'telemetry'
                metric = 'intent.userassist_entries'
                domain = 'intent'
                value  = 87
                status = 'measured'
                window = 'instant'
                root   = $startup
            }
        }
    }

    function New-PcxUndoPlan {
        param(
            [Parameter(Mandatory = $true)][object] $Fixture,
            [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Proposals
        )

        return & $script:Plan -Proposals $Proposals -Scan $script:Scan -Profile $Fixture.Profile
    }

    function Get-PcxUndoSessionDocument {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $PlanId)

        $path = Join-Path -Path $Fixture.Root -ChildPath ('pcx/journal/session-' + $PlanId + '.json')
        return & $script:ReadJson -Path $path
    }

    function Get-PcxUndoSessionPath {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $PlanId)

        return (Join-Path -Path $Fixture.Root -ChildPath ('pcx/journal/session-' + $PlanId + '.json'))
    }

    function Set-PcxUndoSessionDocument {
        param(
            [Parameter(Mandatory = $true)][object] $Fixture,
            [Parameter(Mandatory = $true)][string] $PlanId,
            [Parameter(Mandatory = $true)][object] $Document
        )

        $path = Get-PcxUndoSessionPath -Fixture $Fixture -PlanId $PlanId
        $json = ConvertTo-Json -InputObject $Document -Depth 20
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    }

    function Get-PcxUndoJournalIndex {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        $path = Join-Path -Path $Fixture.Root -ChildPath 'pcx/journal/index.json'
        if (-not [System.IO.File]::Exists($path)) { return $null }
        return (& $script:ReadJson -Path $path)
    }

    function New-PcxUndoSearchProposal {
        return [ordered]@{
            actionId = 'search-web'
            target   = [ordered]@{ Kind = 'registry'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled' }
            evidence = [ordered]@{
                kind   = 'telemetry'
                metric = 'search.web_results_enabled'
                domain = 'search'
                value  = 1
                status = 'measured'
                window = 'instant'
            }
        }
    }

    function Get-PcxUndoRegistryData {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Name)

        $state = Get-PcxUndoStateFile -Fixture $Fixture
        $property = $state.registry.PSObject.Properties[(Get-PcxUndoRegistryKey -Path $Path -Name $Name)]
        if ($null -eq $property) { return $null }
        return $property.Value.data
    }

    function Set-PcxUndoRegistryData {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][int] $Data)

        $state = Get-PcxUndoStateFile -Fixture $Fixture
        $state.registry.PSObject.Properties[(Get-PcxUndoRegistryKey -Path $Path -Name $Name)].Value.data = $Data
        Write-PcxUndoStateFile -Fixture $Fixture -State $state
    }

    function Set-PcxUndoServiceControlSet {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $ServiceName, [Parameter(Mandatory = $true)][string] $ControlSet)

        $state = Get-PcxUndoStateFile -Fixture $Fixture
        $state.services.($ServiceName.ToLowerInvariant()).controlSet = $ControlSet
        Write-PcxUndoStateFile -Fixture $Fixture -State $state
    }

    function Get-PcxUndoFileProperty {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $Path)

        $state = Get-PcxUndoStateFile -Fixture $Fixture
        return $state.files.PSObject.Properties[$Path.ToLowerInvariant()]
    }

    function Get-PcxUndoFileCount {
        param([Parameter(Mandatory = $true)][object] $Fixture)

        $state = Get-PcxUndoStateFile -Fixture $Fixture
        return @($state.files.PSObject.Properties).Count
    }

    function Invoke-PcxUndoDispatch {
        param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments)

        return & $script:Dispatch -Arguments $Arguments
    }

    function Get-PcxUndoDiagnosticCode {
        param([Parameter(Mandatory = $true)][object] $Result)

        $codes = @($Result.Envelope.diagnostics | ForEach-Object { [string]$_.code })
        if ($codes.Count -eq 0) { return $null }
        return $codes[0]
    }

    function New-PcxUndoElevationRunner {
        <#
        .SYNOPSIS
            Fake UAC that runs the real elevated undo child in-process.
        #>
        param(
            [Parameter(Mandatory = $true)][object] $Counter,
            [Parameter(Mandatory = $false)][switch] $CannedOk
        )

        $module = Get-Module -Name 'Pcx'
        $runner = {
            param($request)
            $Counter.Count = [int]$Counter.Count + 1
            if ($CannedOk) {
                return [pscustomobject]@{ ok = $true; status = 'restored'; code = $null; reason = $null; restored = @(); notRestorable = @() }
            }
            return & $module.ExportedCommands['Invoke-PcxUndoElevatedLoop'] -RequestBytesBase64 $request.payloadBase64 -RequestHash $request.requestHash -CallerSid $request.callerSid
        }.GetNewClosure()

        return $runner
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
}

Describe 'undo surface' {

    It 'exports the undo and status entry points' {
        ($null -ne $script:Undo) | Should -BeTrue
        ($null -ne $script:UndoElevated) | Should -BeTrue
        ($null -ne $script:UndoLoop) | Should -BeTrue
        ($null -ne $script:Status) | Should -BeTrue
    }

    It 'keeps status internal: the user-facing command list is doctor, tune, undo, probe' {
        $help = Invoke-PcxUndoDispatch -Arguments @('--help')
        $commands = @($help.Envelope.data.commands)
        $commands | Should -Be @('doctor', 'tune', 'undo', 'probe')
        $commands -contains 'status' | Should -BeFalse
    }

    It 'no longer returns PCX-E-NOT-IMPLEMENTED for undo' {
        $result = Invoke-PcxUndoDispatch -Arguments @('undo')
        (Get-PcxUndoDiagnosticCode -Result $result) | Should -Not -Be 'PCX-E-NOT-IMPLEMENTED'
        [int]$result.ExitCode | Should -Be 2
    }
}

Describe 'undo command surface' {

    BeforeAll {
        # An isolated empty state root: --last/--item/--plan refuse before any
        # write, so no real journal is ever touched.
        $script:SurfaceFixture = New-PcxUndoFixture
    }

    It 'accepts exactly --last, --item and --plan' {
        foreach ($arguments in @(
                @('undo', '--last')
                @('undo', '--item', 'aaaaaaaaaaaaaaaa')
                @('undo', '--plan', 'aaaaaaaaaaaaaaaa'))) {
            $result = Invoke-PcxUndoDispatch -Arguments $arguments
            (Get-PcxUndoDiagnosticCode -Result $result) | Should -Not -Be 'PCX-E-SUBCOMMAND' -Because "undo must accept '$($arguments[1])'"
        }
    }

    It 'refuses --force with exit 2 and a typed code' {
        $forced = Invoke-PcxUndoDispatch -Arguments @('undo', '--force')

        [int]$forced.ExitCode | Should -Be 2
        (Get-PcxUndoDiagnosticCode -Result $forced) | Should -Be 'PCX-E-SUBCOMMAND'
        [string]$forced.Envelope.diagnostics[0].message | Should -Match 'Allowed: --item, --plan, --last'
    }

    It 'has no Force parameter on Invoke-PcxUndo' {
        ($script:Module.ExportedCommands['Invoke-PcxUndo']).Parameters.ContainsKey('Force') | Should -BeFalse -Because 'undo has no --force escape hatch'
    }
}

Describe 'undo restores the exact pre-state' {

    It 'restores both registry values and exits 0' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen'),
            (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
        )

        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 0
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:AdsPath -Name $script:AdsName) | Should -Be 0

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--plan', $plan.planId)

        [int]$result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -Be 'ok'
        @($result.Envelope.data.restored).Count | Should -Be 2
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 1
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:AdsPath -Name $script:AdsName) | Should -Be 1

        $session = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $plan.planId
        @($session.items | Where-Object { $_.status -eq 'UNDONE' }).Count | Should -Be 2
    }
}

Describe 'drift is terminal' {

    It 'exits 3 and reverts nothing when a target changed' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen'),
            (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
        )

        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        $null = & $script:Apply -PlanId $plan.planId -Mode agent

        # External change to the first plan item: its recorded post-state is gone.
        Set-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName -Data 1

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--plan', $plan.planId)

        [int]$result.ExitCode | Should -Be 3
        (Get-PcxUndoDiagnosticCode -Result $result) | Should -Be 'PCX-E-UNDO-DRIFT'

        # Nothing was reverted: the other applied item still holds its post-state.
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:AdsPath -Name $script:AdsName) | Should -Be 0

        $session = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $plan.planId
        @($session.items | Where-Object { $_.status -eq 'COMMITTED' }).Count | Should -Be 2
    }
}

Describe 'the journal is untrusted' {

    It 'refuses an edited journal target by policy and exits 3' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )

        $applied = & $script:Apply -PlanId $plan.planId -Mode agent
        $itemId = [string]$applied.itemResults[0].id
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 0

        # Point the journal snapshot at a protected HKLM value.
        $sessionPath = Get-PcxUndoSessionPath -Fixture $fixture -PlanId $plan.planId
        $session = & $script:ReadJson -Path $sessionPath
        $record = @($session.items | Where-Object { $_.id -eq $itemId })[0]
        $record.snapshots[0].target.path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        $record.snapshots[0].target.name = 'PcxTest'
        $json = ConvertTo-Json -InputObject $session -Depth 20
        [System.IO.File]::WriteAllText($sessionPath, $json, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--item', $itemId)

        [int]$result.ExitCode | Should -Be 3
        (Get-PcxUndoDiagnosticCode -Result $result) | Should -Match '^PCX-POLICY-'
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 0
    }

    It 'refuses a journal target that is not in the validated plan' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )

        $applied = & $script:Apply -PlanId $plan.planId -Mode agent
        $itemId = [string]$applied.itemResults[0].id

        $sessionPath = Get-PcxUndoSessionPath -Fixture $fixture -PlanId $plan.planId
        $session = & $script:ReadJson -Path $sessionPath
        $record = @($session.items | Where-Object { $_.id -eq $itemId })[0]
        $record.snapshots[0].target.path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        $record.snapshots[0].target.name = 'Enabled'
        $json = ConvertTo-Json -InputObject $session -Depth 20
        [System.IO.File]::WriteAllText($sessionPath, $json, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--item', $itemId)

        [int]$result.ExitCode | Should -Be 3
        (Get-PcxUndoDiagnosticCode -Result $result) | Should -Be 'PCX-E-UNDO-JOURNAL'
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 0
    }
}

Describe 'mixed plan with A1' {

    It 'exits 0 when every restorable item matches and reports A1 not restorable' {
        $fixture = New-PcxUndoFixture

        $explorer = Join-Path -Path $fixture.Root -ChildPath 'Microsoft\Windows\Explorer'
        foreach ($name in @('thumbcache_32.db', 'thumbcache_96.db', 'thumbcache_256.db', 'thumbcache_1024.db')) {
            Add-PcxUndoFileRecord -State $fixture.State -Path (Join-Path $explorer $name)
        }
        Write-PcxUndoStateFile -Fixture $fixture -State $fixture.State

        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoA1Proposal -Fixture $fixture),
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )

        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        $null = & $script:Apply -PlanId $plan.planId -Mode agent

        (Get-PcxUndoFileCount -Fixture $fixture) | Should -Be 0
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 0

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--plan', $plan.planId)

        [int]$result.ExitCode | Should -Be 0
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 1

        $notRestorable = @($result.Envelope.data.notRestorable)
        @($notRestorable).Count | Should -Be 1
        $notRestorable[0].actionId | Should -Be 'thumbnails'
        $notRestorable[0].restoreMode | Should -Be 'manifest-only'

        # A1 stays absent: it was never restored.
        (Get-PcxUndoFileCount -Fixture $fixture) | Should -Be 0
    }
}

Describe 'quarantine' {

    It 'restores the quarantined file byte-identically' {
        $fixture = New-PcxUndoFixture

        $startup = Join-Path -Path $fixture.Root -ChildPath 'Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $source = Join-Path -Path $startup -ChildPath 'OneDrive.lnk'
        Add-PcxUndoFileRecord -State $fixture.State -Path $source -Content 'shortcut-bytes-0123456789'
        Write-PcxUndoStateFile -Fixture $fixture -State $fixture.State

        $originalSha = & $script:Sha256 -Text 'shortcut-bytes-0123456789'

        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoQuarantineProposal -Fixture $fixture)
        )

        $applied = & $script:Apply -PlanId $plan.planId -Mode agent
        $applied.itemResults[0].status | Should -Be 'COMMITTED'

        ($null -eq (Get-PcxUndoFileProperty -Fixture $fixture -Path $source)) | Should -BeTrue
        (Get-PcxUndoFileCount -Fixture $fixture) | Should -Be 1

        $itemId = [string]$applied.itemResults[0].id
        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--item', $itemId)

        [int]$result.ExitCode | Should -Be 0

        $restoredProperty = Get-PcxUndoFileProperty -Fixture $fixture -Path $source
        ($null -ne $restoredProperty) | Should -BeTrue
        $content = [System.Convert]::FromBase64String([string]$restoredProperty.Value.contentBase64)
        (& $script:Sha256 -Bytes $content) | Should -Be $originalSha
        $content.Length | Should -Be ([System.Text.Encoding]::UTF8.GetBytes('shortcut-bytes-0123456789')).Length
    }
}

Describe 'a second undo refuses' {

    It 'refuses --item and --plan after an item is UNDONE' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )

        $applied = & $script:Apply -PlanId $plan.planId -Mode agent
        $itemId = [string]$applied.itemResults[0].id

        $first = Invoke-PcxUndoDispatch -Arguments @('undo', '--item', $itemId)
        [int]$first.ExitCode | Should -Be 0

        $second = Invoke-PcxUndoDispatch -Arguments @('undo', '--item', $itemId)
        [int]$second.ExitCode | Should -Be 2
        (Get-PcxUndoDiagnosticCode -Result $second) | Should -Be 'PCX-E-UNDO-ALREADY'

        $third = Invoke-PcxUndoDispatch -Arguments @('undo', '--plan', $plan.planId)
        [int]$third.ExitCode | Should -Be 2
        (Get-PcxUndoDiagnosticCode -Result $third) | Should -Be 'PCX-E-UNDO-ALREADY'
    }
}

Describe 'selection' {

    It 'refuses no selector, an unknown item and a plan with no session' {
        $fixture = New-PcxUndoFixture

        $noSelector = Invoke-PcxUndoDispatch -Arguments @('undo')
        [int]$noSelector.ExitCode | Should -Be 2
        (Get-PcxUndoDiagnosticCode -Result $noSelector) | Should -Be 'PCX-E-UNDO-SELECTION'

        $appliedPlan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )
        $null = & $script:Apply -PlanId $appliedPlan.planId -Mode agent

        $unknown = Invoke-PcxUndoDispatch -Arguments @('undo', '--item', 'tips-00000000')
        [int]$unknown.ExitCode | Should -Be 2
        (Get-PcxUndoDiagnosticCode -Result $unknown) | Should -Be 'PCX-E-UNDO-SELECTION'

        $neverAppliedPlan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
        )
        $neverApplied = Invoke-PcxUndoDispatch -Arguments @('undo', '--plan', $neverAppliedPlan.planId)
        [int]$neverApplied.ExitCode | Should -Be 2
        (Get-PcxUndoDiagnosticCode -Result $neverApplied) | Should -Be 'PCX-E-UNDO-NOTHING'
    }
}

Describe '--last' {

    It 'targets the most recent session' {
        $fixture = New-PcxUndoFixture

        $firstPlan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )
        $null = & $script:Apply -PlanId $firstPlan.planId -Mode agent

        $secondPlan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
        )
        $null = & $script:Apply -PlanId $secondPlan.planId -Mode agent

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--last')

        [int]$result.ExitCode | Should -Be 0
        $result.Envelope.data.planId | Should -Be $secondPlan.planId
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:AdsPath -Name $script:AdsName) | Should -Be 1
        # The first plan's item is untouched.
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 0
    }
}

Describe 'deterministic session ordering' {

    It 'records sequence and createdAtUtc in the session document and the journal index' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )
        $null = & $script:Apply -PlanId $plan.planId -Mode agent

        $session = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $plan.planId
        [int]$session.sequence | Should -Be 1

        $raw = [System.IO.File]::ReadAllText((Get-PcxUndoSessionPath -Fixture $fixture -PlanId $plan.planId))
        $raw | Should -Match '"createdAtUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}'

        $index = Get-PcxUndoJournalIndex -Fixture $fixture
        ($null -ne $index) | Should -BeTrue
        [int]$index.sequence | Should -Be ([int]$session.sequence)
    }

    It 'selects the third of three tight-loop sessions, five times over' {
        for ($iteration = 1; $iteration -le 5; $iteration++) {
            $fixture = New-PcxUndoFixture

            $planA = New-PcxUndoPlan -Fixture $fixture -Proposals @(
                (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
            )
            $planB = New-PcxUndoPlan -Fixture $fixture -Proposals @(
                (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
            )
            $planC = New-PcxUndoPlan -Fixture $fixture -Proposals @(
                (New-PcxUndoSearchProposal)
            )

            $null = & $script:Apply -PlanId $planA.planId -Mode agent
            $null = & $script:Apply -PlanId $planB.planId -Mode agent
            $null = & $script:Apply -PlanId $planC.planId -Mode agent

            $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--last')

            [int]$result.ExitCode | Should -Be 0
            $result.Envelope.data.planId | Should -Be $planC.planId
        }
    }

    It 'orders two sessions from the same clock tick by sequence' {
        $fixture = New-PcxUndoFixture

        $planA = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )
        $planB = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
        )
        $null = & $script:Apply -PlanId $planA.planId -Mode agent
        $null = & $script:Apply -PlanId $planB.planId -Mode agent

        # Force the same creation stamp in both documents: only the sequence
        # may decide the order now.
        $sameStamp = '2026-10-30T00:00:00.0000000Z'
        foreach ($planId in @($planA.planId, $planB.planId)) {
            $document = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $planId
            $document.createdAtUtc = $sameStamp
            Set-PcxUndoSessionDocument -Fixture $fixture -PlanId $planId -Document $document
        }

        $documentA = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $planA.planId
        $documentB = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $planB.planId
        [int]$documentB.sequence | Should -BeGreaterThan ([int]$documentA.sequence)

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--last')

        [int]$result.ExitCode | Should -Be 0
        $result.Envelope.data.planId | Should -Be $planB.planId
    }

    It 'still selects an old-shape session that has no sequence' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )
        $null = & $script:Apply -PlanId $plan.planId -Mode agent

        # Rebuild the document without the ordering fields (the pre-fix shape).
        $session = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $plan.planId
        $legacy = [ordered]@{}
        foreach ($property in $session.PSObject.Properties) {
            if ($property.Name -eq 'sequence' -or $property.Name -eq 'createdAtUtc') { continue }
            $legacy[$property.Name] = $property.Value
        }
        Set-PcxUndoSessionDocument -Fixture $fixture -PlanId $plan.planId -Document $legacy

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--last')

        [int]$result.ExitCode | Should -Be 0
        $result.Envelope.data.planId | Should -Be $plan.planId
        (Get-PcxUndoRegistryData -Fixture $fixture -Path $script:TipsPath -Name $script:TipsName) | Should -Be 1
    }

    It 'lists status newest-first in the same order as --last' {
        $fixture = New-PcxUndoFixture

        $planA = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen')
        )
        $planB = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
        )
        $planC = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoSearchProposal)
        )
        $null = & $script:Apply -PlanId $planA.planId -Mode agent
        $null = & $script:Apply -PlanId $planB.planId -Mode agent
        $null = & $script:Apply -PlanId $planC.planId -Mode agent

        $statusBefore = & $script:Status
        @($statusBefore.sessions)[0].planId | Should -Be $planC.planId
        @($statusBefore.sessions)[2].planId | Should -Be $planA.planId

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--last')
        $result.Envelope.data.planId | Should -Be $planC.planId

        # Undo rewrites the session; the order must survive that rewrite.
        $statusAfter = & $script:Status
        @($statusAfter.sessions)[0].planId | Should -Be $planC.planId
        @($statusAfter.sessions)[0].undone | Should -Be 1
    }
}

Describe 'status' {

    It 'lists applied and undone items, read-only' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoRegistryProposal -ActionId 'tips' -Path $script:TipsPath -Name $script:TipsName -Domain 'ads' -Metric 'ads.settings_seen'),
            (New-PcxUndoRegistryProposal -ActionId 'advertising-id' -Path $script:AdsPath -Name $script:AdsName -Domain 'ads' -Metric 'ads.advertising_id_enabled')
        )

        $first = & $script:Apply -PlanId $plan.planId -Mode agent
        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        $undoneId = [string]$first.itemResults[0].id
        $null = Invoke-PcxUndoDispatch -Arguments @('undo', '--item', $undoneId)

        $stateBefore = [System.IO.File]::ReadAllText($fixture.StateFile)

        $status = & $script:Status

        $status.ok | Should -BeTrue
        $status.schema | Should -Be 'pcx-status/1'

        $rows = @($status.items)
        $rows.Count | Should -Be 2

        $undoneRow = @($rows | Where-Object { $_.itemId -eq $undoneId })[0]
        $undoneRow.status | Should -Be 'UNDONE'
        $undoneRow.planId | Should -Be $plan.planId
        $undoneRow.actionId | Should -Be 'tips'
        [string]::IsNullOrWhiteSpace([string]$undoneRow.timestamp) | Should -BeFalse

        $appliedRow = @($rows | Where-Object { $_.status -eq 'COMMITTED' })[0]
        $appliedRow.actionId | Should -Be 'advertising-id'
        $appliedRow.planId | Should -Be $plan.planId

        # Read-only: the platform state is untouched and a second read is identical.
        [System.IO.File]::ReadAllText($fixture.StateFile) | Should -Be $stateBefore
        $again = & $script:Status
        @($again.items).Count | Should -Be 2
    }
}

Describe 'service control set' {

    It 'refuses undo when the control set moved, exit 3' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoServiceProposal -ServiceName 'DiagTrack')
        )

        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        (Get-PcxUndoStateFile -Fixture $fixture).services.diagtrack.start | Should -Be 4

        Set-PcxUndoServiceControlSet -Fixture $fixture -ServiceName 'DiagTrack' -ControlSet 'ControlSet002'

        $result = Invoke-PcxUndoDispatch -Arguments @('undo', '--plan', $plan.planId)

        [int]$result.ExitCode | Should -Be 3
        (Get-PcxUndoStateFile -Fixture $fixture).services.diagtrack.start | Should -Be 4
    }
}

Describe 'elevated undo: exactly one UAC, parent writes nothing' {

    It 'makes one elevation call and the parent performs no write' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoServiceProposal -ServiceName 'DiagTrack'),
            (New-PcxUndoServiceProposal -ServiceName 'MapsBroker')
        )

        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        (Get-PcxUndoStateFile -Fixture $fixture).services.diagtrack.start | Should -Be 4

        $counter = @{ Count = 0 }
        $cannedElevation = New-PcxUndoElevationRunner -Counter $counter -CannedOk
        $parentRestore = { param($snapshot) throw 'the parent must not write for an elevated undo' }

        $outcome = & $script:Undo -PlanId $plan.planId -Elevation $cannedElevation -Restore $parentRestore

        $outcome.ok | Should -BeTrue
        $outcome.elevated | Should -BeTrue
        $outcome.elevationCalls | Should -Be 1
        $counter.Count | Should -Be 1

        # The canned child wrote nothing, and the parent wrote nothing either.
        (Get-PcxUndoStateFile -Fixture $fixture).services.diagtrack.start | Should -Be 4
        (Get-PcxUndoStateFile -Fixture $fixture).services.mapsbroker.start | Should -Be 4
    }

    It 'restores both services inside the single elevated child' {
        $fixture = New-PcxUndoFixture
        $plan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoServiceProposal -ServiceName 'DiagTrack'),
            (New-PcxUndoServiceProposal -ServiceName 'MapsBroker')
        )

        $null = & $script:Apply -PlanId $plan.planId -Mode agent
        $null = & $script:Apply -PlanId $plan.planId -Mode agent

        $counter = @{ Count = 0 }
        $runner = New-PcxUndoElevationRunner -Counter $counter
        $parentRestore = { param($snapshot) throw 'the parent must not write for an elevated undo' }

        $outcome = & $script:Undo -PlanId $plan.planId -Elevation $runner -Restore $parentRestore

        $outcome.ok | Should -BeTrue
        $outcome.elevationCalls | Should -Be 1
        $counter.Count | Should -Be 1
        @($outcome.restored).Count | Should -Be 2

        (Get-PcxUndoStateFile -Fixture $fixture).services.diagtrack.start | Should -Be 2
        (Get-PcxUndoStateFile -Fixture $fixture).services.mapsbroker.start | Should -Be 2

        $session = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $plan.planId
        @($session.items | Where-Object { $_.status -eq 'UNDONE' }).Count | Should -Be 2
    }
}

Describe 'elevated undo child contract' {

    BeforeAll {
        $fixture = New-PcxUndoFixture
        $script:ChildFixture = $fixture
        $script:ChildPlan = New-PcxUndoPlan -Fixture $fixture -Proposals @(
            (New-PcxUndoServiceProposal -ServiceName 'DiagTrack')
        )
        $null = & $script:Apply -PlanId $script:ChildPlan.planId -Mode agent

        $script:ChildSession = Get-PcxUndoSessionDocument -Fixture $fixture -PlanId $script:ChildPlan.planId
        $script:ChildItemId = [string](@($script:ChildSession.items)[0].id)

        $requestDocument = [ordered]@{
            schema = 'pcx-undo/1'
            planId = [string]$script:ChildPlan.planId
            items  = @([string]$script:ChildItemId)
        }
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes((& $script:Module.ExportedCommands['ConvertTo-PcxCanonicalJson'] -InputObject $requestDocument))

        $script:ChildRequestBase64 = [System.Convert]::ToBase64String($requestBytes)
        $script:ChildRequestHash = & $script:Sha256 -Bytes $requestBytes
        $script:ChildSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }

    It 'accepts the exact request bytes with the canonical hash and the matching SID' {
        $result = & $script:UndoElevated -RequestBytesBase64 $script:ChildRequestBase64 -RequestHash $script:ChildRequestHash -CallerSid $script:ChildSid

        $result.ok | Should -BeTrue
        $result.planId | Should -Be $script:ChildPlan.planId
    }

    It 'refuses altered request bytes' {
        $bytes = [System.Convert]::FromBase64String($script:ChildRequestBase64)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $altered = [System.Text.Encoding]::UTF8.GetBytes($text.Replace($script:ChildPlan.planId, '0000000000000000'))

        $result = & $script:UndoElevated -RequestBytesBase64 ([System.Convert]::ToBase64String($altered)) -RequestHash $script:ChildRequestHash -CallerSid $script:ChildSid

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-UNDO-REQUEST'
    }

    It 'refuses a request over 8 KB' {
        $big = New-Object byte[] 9000
        for ($index = 0; $index -lt $big.Length; $index++) { $big[$index] = 65 }

        $result = & $script:UndoElevated -RequestBytesBase64 ([System.Convert]::ToBase64String($big)) -RequestHash (& $script:Sha256 -Bytes $big) -CallerSid $script:ChildSid

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-UNDO-REQUEST-SIZE'
    }

    It 'refuses a SID mismatch' {
        $result = & $script:UndoElevated -RequestBytesBase64 $script:ChildRequestBase64 -RequestHash $script:ChildRequestHash -CallerSid 'S-1-5-21-0000000000-0000000000-0000000000-9999'

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-SID-MISMATCH'
    }

    It 'restores nothing when the elevated loop receives altered bytes' {
        $bytes = [System.Convert]::FromBase64String($script:ChildRequestBase64)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $altered = [System.Text.Encoding]::UTF8.GetBytes($text.Replace($script:ChildPlan.planId, '0000000000000000'))

        $result = & $script:UndoLoop -RequestBytesBase64 ([System.Convert]::ToBase64String($altered)) -RequestHash $script:ChildRequestHash -CallerSid $script:ChildSid

        $result.ok | Should -BeFalse
        $result.code | Should -Be 'PCX-E-UNDO-REQUEST'
        @($result.restored).Count | Should -Be 0
        (Get-PcxUndoStateFile -Fixture $script:ChildFixture).services.diagtrack.start | Should -Be 4
    }
}
