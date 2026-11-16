<#
.SYNOPSIS
    Write-provider suite for todo 6: registry, service, task and file.

.DESCRIPTION
    Fixture-only: every test runs against tests/TestAdapter/PcxPlatform.Test.ps1
    with $env:LOCALAPPDATA / APPDATA / PROGRAMDATA / SYSTEMROOT pointed at a
    per-run temporary root inside $TestDrive before the module is imported, so
    no provider ever touches the real user profile.

    Covered here:
      * Read -> Apply -> Verify for all four providers;
      * the inverse (Restore-PcxSnapshot) equals the live pre-state;
      * quarantine restores byte-identically and the source is gone;
      * A1 writes a manifest-only, non-restorable result;
      * a locked file leaves A1 FAILED with residue, never COMMITTED;
      * a directory of regular files is deleted file-by-file with a full
        manifest, nested directories included;
      * a reparse child refuses; an A1 target without Children refuses;
      * a cross-volume quarantine refuses;
      * a path outside the root, a junction and a '..' path refuse;
      * svc Start=2 and task enabled=true refuse;
      * the provider sources contain no native cmdlet and no shell.
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

    $fixtureBase = if (-not [string]::IsNullOrEmpty($TestDrive)) { $TestDrive } else { [System.IO.Path]::GetTempPath() }
    $script:FixtureRoot = [System.IO.Path]::Combine($fixtureBase, ('pcx-providers-' + [guid]::NewGuid().ToString('N')))
    $script:LocalAppData = [System.IO.Path]::Combine($script:FixtureRoot, 'LocalAppData')
    $script:AppData = [System.IO.Path]::Combine($script:FixtureRoot, 'Roaming')
    $script:ProgramData = [System.IO.Path]::Combine($script:FixtureRoot, 'ProgramData')
    $script:SystemRoot = [System.IO.Path]::Combine($script:FixtureRoot, 'Windows')

    $null = [System.IO.Directory]::CreateDirectory($script:FixtureRoot)

    $script:OriginalEnvironment = [ordered]@{
        LOCALAPPDATA = $env:LOCALAPPDATA
        APPDATA      = $env:APPDATA
        PROGRAMDATA  = $env:PROGRAMDATA
        SYSTEMROOT   = $env:SYSTEMROOT
    }

    $env:LOCALAPPDATA = $script:LocalAppData
    $env:APPDATA = $script:AppData
    $env:PROGRAMDATA = $script:ProgramData

    # %SYSTEMROOT% stays real: on PowerShell 5.1 both Add-Type and
    # ConvertFrom-Json load their assemblies from it. Providers take SYSTEMROOT
    # from the injected profile environment, never from the process.
    Import-Module -Name $modulePath -Force

    $script:ProviderSourcePaths = @(
        (Join-Path -Path $repoRoot -ChildPath 'src/pcx/Providers/ProviderCommon.ps1')
        (Join-Path -Path $repoRoot -ChildPath 'src/pcx/Providers/RegistryProvider.ps1')
        (Join-Path -Path $repoRoot -ChildPath 'src/pcx/Providers/ServiceProvider.ps1')
        (Join-Path -Path $repoRoot -ChildPath 'src/pcx/Providers/TaskProvider.ps1')
        (Join-Path -Path $repoRoot -ChildPath 'src/pcx/Providers/FileProvider.ps1')
    )

    function New-PcxFixtureFileRecord {
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [string] $Text = 'fixture',
            [string] $Attributes = 'Archive',
            [bool] $Reparse = $false,
            [bool] $Locked = $false,
            [bool] $Directory = $false,
            [bool] $Unreadable = $false
        )

        $record = [ordered]@{
            path           = $Path
            attributes     = $Attributes
            isReparsePoint = $Reparse
            locked         = $Locked
            unreadable     = $Unreadable
        }

        if ($Directory) {
            $record['contentBase64'] = ''
        }
        else {
            $record['contentBase64'] = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
        }

        return $record
    }

    function Write-PcxFixtureState {
        param([Parameter(Mandatory = $true)][hashtable] $State)

        $json = ConvertTo-Json -InputObject $State -Depth 10 -Compress
        $parent = [System.IO.Path]::GetDirectoryName($script:StateFile)
        if (-not [System.IO.Directory]::Exists($parent)) {
            $null = [System.IO.Directory]::CreateDirectory($parent)
        }
        [System.IO.File]::WriteAllText($script:StateFile, $json, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    }

    function Read-PcxFixtureState {
        $text = [System.IO.File]::ReadAllText($script:StateFile, [System.Text.Encoding]::UTF8)
        return ConvertFrom-Json -InputObject $text
    }

    function Test-PcxFixtureFileExists {
        param([Parameter(Mandatory = $true)][string] $Path)

        $document = Read-PcxFixtureState
        $key = $Path.ToLowerInvariant()
        return ($null -ne $document.files.PSObject.Properties[$key])
    }

    function New-PcxFixtureRegistryKey {
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $true)][string] $Name
        )

        return ($Path.ToLowerInvariant() + [char]0x1F + $Name.ToLowerInvariant())
    }

    function New-PcxProvidersProfile {
        param(
            [hashtable] $EnvironmentOverride = @{},
            [hashtable] $ServiceFacts = @{}
        )

        $environment = [ordered]@{
            LOCALAPPDATA = $script:LocalAppData
            APPDATA      = $script:AppData
            PROGRAMDATA  = $script:ProgramData
            SYSTEMROOT   = $script:SystemRoot
        }
        foreach ($key in $EnvironmentOverride.Keys) {
            $environment[$key] = $EnvironmentOverride[$key]
        }

        $facts = @{
            diagtrack = @{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
        }
        foreach ($key in $ServiceFacts.Keys) {
            $facts[$key] = $ServiceFacts[$key]
        }

        return [pscustomobject]@{
            managed      = $false
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            serviceFacts = $facts
            environment  = $environment
        }
    }
}

AfterAll {
    if ($null -ne $script:OriginalEnvironment) {
        $env:LOCALAPPDATA = $script:OriginalEnvironment['LOCALAPPDATA']
        $env:APPDATA = $script:OriginalEnvironment['APPDATA']
        $env:PROGRAMDATA = $script:OriginalEnvironment['PROGRAMDATA']
        $env:SYSTEMROOT = $script:OriginalEnvironment['SYSTEMROOT']
    }
}

Describe 'pcx providers' {

BeforeEach {
    $script:StateFile = [System.IO.Path]::Combine($script:FixtureRoot, ('state-' + [guid]::NewGuid().ToString('N') + '.json'))
    $env:PCX_TEST_STATE_FILE = $script:StateFile
    $script:Profile = New-PcxProvidersProfile
}

Describe 'provider surface' {

    It 'exports Read, Apply and Verify for every provider' {
        $module = Get-Module -Name 'Pcx'
        $expected = @(
            'Get-PcxRegistryProviderState', 'Invoke-PcxRegistryProviderApply', 'Test-PcxRegistryProviderState'
            'Get-PcxServiceProviderState', 'Invoke-PcxServiceProviderApply', 'Test-PcxServiceProviderState'
            'Get-PcxTaskProviderState', 'Invoke-PcxTaskProviderApply', 'Test-PcxTaskProviderState'
            'Get-PcxFileProviderState', 'Invoke-PcxFileProviderApply', 'Test-PcxFileProviderResult'
        )

        foreach ($name in $expected) {
            $null -ne $module.ExportedCommands[$name] | Should -BeTrue -Because "$name must be exported"
        }
    }
}

Describe 'registry provider' {

    It 'reads one value through the snapshot engine' {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $state = @{
            registry = @{
                (New-PcxFixtureRegistryKey -Path $path -Name 'HwSchMode') = [ordered]@{ path = $path; name = 'HwSchMode'; type = 'dword'; data = 1 }
            }
            services = @{}
            tasks    = @{}
            files    = @{}
        }
        Write-PcxFixtureState -State $state

        $observed = Get-PcxRegistryProviderState -Target @{ Kind = 'registry'; Path = $path; Name = 'HwSchMode' }

        $observed['kind'] | Should -Be 'registry'
        $observed['exists'] | Should -BeTrue
        $observed['type'] | Should -Be 'dword'
        $observed['data'] | Should -Be 1
    }

    It 'round-trips one value and restores the live pre-state' {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        Write-PcxFixtureState -State @{
            registry = @{
                (New-PcxFixtureRegistryKey -Path $path -Name 'HwSchMode') = [ordered]@{ path = $path; name = 'HwSchMode'; type = 'dword'; data = 1 }
            }
            services = @{}
            tasks    = @{}
            files    = @{}
        }

        $target = @{ Kind = 'registry'; Path = $path; Name = 'HwSchMode'; Type = 'dword'; Value = 2 }
        $apply = Invoke-PcxRegistryProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        $apply['restorable'] | Should -BeTrue
        $apply['restoreMode'] | Should -Be 'snapshot'
        $apply['snapshot']['pre']['data'] | Should -Be 1
        $apply['snapshot']['post']['data'] | Should -Be 2

        $verification = Test-PcxRegistryProviderState -Snapshot $apply['snapshot']
        $verification['status'] | Should -Be 'COMMITTED'

        $live = Get-PcxRegistryProviderState -Target @{ Kind = 'registry'; Path = $path; Name = 'HwSchMode' }
        $live['data'] | Should -Be 2

        $restore = Restore-PcxSnapshot -Snapshot $apply['snapshot']
        $restore['status'] | Should -Be 'restored'
        $liveAfter = Get-PcxRegistryProviderState -Target @{ Kind = 'registry'; Path = $path; Name = 'HwSchMode' }
        $liveAfter['data'] | Should -Be 1
    }

    It 'refuses a value inside HKCU\Environment before any write' {
        Write-PcxFixtureState -State @{ registry = @{}; services = @{}; tasks = @{}; files = @{} }
        $target = @{ Kind = 'registry'; Path = 'HKCU:\Environment'; Name = 'Path'; Type = 'string'; Value = 'x' }

        $apply = Invoke-PcxRegistryProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-POLICY-HKCU-DEFAULT-DENY'
        $document = Read-PcxFixtureState
        @($document.registry.PSObject.Properties).Count | Should -Be 0
    }
}

Describe 'service provider' {

    It 'round-trips Start and restores the live pre-state' {
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{ diagtrack = [ordered]@{ name = 'DiagTrack'; controlSet = 'ControlSet001'; start = 2 } }
            tasks    = @{}
            files    = @{}
        }

        $target = @{ Kind = 'service'; Name = 'DiagTrack'; Start = 4 }
        $apply = Invoke-PcxServiceProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        $apply['snapshot']['pre']['start'] | Should -Be 2
        $apply['snapshot']['post']['start'] | Should -Be 4

        (Test-PcxServiceProviderState -Snapshot $apply['snapshot'])['status'] | Should -Be 'COMMITTED'
        (Get-PcxServiceProviderState -Target @{ Kind = 'service'; Name = 'DiagTrack' })['start'] | Should -Be 4

        $null = Restore-PcxSnapshot -Snapshot $apply['snapshot']
        (Get-PcxServiceProviderState -Target @{ Kind = 'service'; Name = 'DiagTrack' })['start'] | Should -Be 2
    }

    It 'refuses svc Start=2 with a typed policy code and writes nothing' {
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{ diagtrack = [ordered]@{ name = 'DiagTrack'; controlSet = 'ControlSet001'; start = 4 } }
            tasks    = @{}
            files    = @{}
        }

        $apply = Invoke-PcxServiceProviderApply -Target @{ Kind = 'service'; Name = 'DiagTrack'; Start = 2 } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-POLICY-SERVICE-START'
        (Get-PcxServiceProviderState -Target @{ Kind = 'service'; Name = 'DiagTrack' })['start'] | Should -Be 4
    }

    It 'refuses Start=0 and Start=1 too' {
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{ diagtrack = [ordered]@{ name = 'DiagTrack'; controlSet = 'ControlSet001'; start = 2 } }
            tasks    = @{}
            files    = @{}
        }

        foreach ($start in @(0, 1)) {
            $apply = Invoke-PcxServiceProviderApply -Target @{ Kind = 'service'; Name = 'DiagTrack'; Start = $start } -Profile $script:Profile
            $apply['status'] | Should -Be 'REFUSED'
            $apply['code'] | Should -Be 'PCX-POLICY-SERVICE-START'
        }
    }
}

Describe 'task provider' {

    It 'round-trips enabled=false and restores the live pre-state' {
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{ '\pcx\mytask' = [ordered]@{ path = '\Pcx\MyTask'; enabled = $true; state = 'Ready' } }
            files    = @{}
        }

        $target = @{ Kind = 'task'; Path = '\Pcx\MyTask'; Enabled = $false }
        $apply = Invoke-PcxTaskProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        $apply['snapshot']['pre']['enabled'] | Should -BeTrue
        $apply['snapshot']['post']['enabled'] | Should -BeFalse

        (Test-PcxTaskProviderState -Snapshot $apply['snapshot'])['status'] | Should -Be 'COMMITTED'
        (Get-PcxTaskProviderState -Target @{ Kind = 'task'; Path = '\Pcx\MyTask' })['enabled'] | Should -BeFalse

        $null = Restore-PcxSnapshot -Snapshot $apply['snapshot']
        (Get-PcxTaskProviderState -Target @{ Kind = 'task'; Path = '\Pcx\MyTask' })['enabled'] | Should -BeTrue
    }

    It 'refuses task enabled=true and writes nothing' {
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{ '\pcx\mytask' = [ordered]@{ path = '\Pcx\MyTask'; enabled = $false; state = 'Disabled' } }
            files    = @{}
        }

        $apply = Invoke-PcxTaskProviderApply -Target @{ Kind = 'task'; Path = '\Pcx\MyTask'; Enabled = $true } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-POLICY-TASK-ENABLE'
        (Get-PcxTaskProviderState -Target @{ Kind = 'task'; Path = '\Pcx\MyTask' })['enabled'] | Should -BeFalse
    }
}

Describe 'file provider A1 delete' {

    It 'deletes one concrete cache file, writes a manifest and promises no restore' {
        $file = [System.IO.Path]::Combine($script:LocalAppData, 'Microsoft\Windows\Explorer\thumbcache_32.db')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $file.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $file -Text 'thumb-bytes') }
        }

        $target = @{ Kind = 'file'; Path = $file; Role = 'a1'; PlanId = 'plan-a1' }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        $apply['restorable'] | Should -BeFalse
        $apply['restoreMode'] | Should -Be 'manifest-only'
        @($apply['manifest']).Count | Should -Be 1
        @($apply['skipped']).Count | Should -Be 0
        @($apply['residue']).Count | Should -Be 0
        (Test-PcxFixtureFileExists -Path $file) | Should -BeFalse

        $manifestPath = [System.IO.Path]::Combine($script:LocalAppData, 'pcx\journal\plan-a1-a1-manifest.json')
        $apply['manifestPath'] | Should -Be $manifestPath
        (Test-Path -LiteralPath $manifestPath) | Should -BeTrue

        $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($manifestPath))
        $manifest.schema | Should -Be 'pcx-a1-manifest/1'
        $manifest.restorable | Should -BeFalse
        $manifest.restoreMode | Should -Be 'manifest-only'
        @($manifest.entries).Count | Should -Be 1

        (Test-PcxFileProviderResult -Result $apply)['status'] | Should -Be 'COMMITTED'
    }

    It 'deletes a directory of regular files file-by-file with a complete manifest' {
        $directory = [System.IO.Path]::Combine($script:SystemRoot, 'SoftwareDistribution\Download')
        $first = [System.IO.Path]::Combine($directory, 'a.cab')
        $second = [System.IO.Path]::Combine($directory, 'b.cab')

        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{
                $directory.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $directory -Attributes 'Directory' -Directory $true)
                $first.ToLowerInvariant()     = (New-PcxFixtureFileRecord -Path $first -Text 'aaa')
                $second.ToLowerInvariant()    = (New-PcxFixtureFileRecord -Path $second -Text 'bbb')
            }
        }

        $target = @{ Kind = 'file'; Path = $directory; Role = 'a1'; PlanId = 'plan-dir'; Children = @($first, $second) }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        @($apply['manifest']).Count | Should -Be 2
        (Test-PcxFixtureFileExists -Path $first) | Should -BeFalse
        (Test-PcxFixtureFileExists -Path $second) | Should -BeFalse

        $manifestPath = [System.IO.Path]::Combine($script:LocalAppData, 'pcx\journal\plan-dir-a1-manifest.json')
        $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($manifestPath))
        @($manifest.entries).Count | Should -Be 2
        $manifest.restorable | Should -BeFalse
    }

    It 'walks a nested directory tree and lists every file' {
        $directory = [System.IO.Path]::Combine($script:SystemRoot, 'SoftwareDistribution\Download')
        $sub = [System.IO.Path]::Combine($directory, 'sub')
        $leaf = [System.IO.Path]::Combine($sub, 'c.cab')

        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{
                $directory.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $directory -Attributes 'Directory' -Directory $true)
                $sub.ToLowerInvariant()       = (New-PcxFixtureFileRecord -Path $sub -Attributes 'Directory' -Directory $true)
                $leaf.ToLowerInvariant()      = (New-PcxFixtureFileRecord -Path $leaf -Text 'ccc')
            }
        }

        $tree = @(
            @{ Path = $sub; Children = @($leaf) }
        )
        $target = @{ Kind = 'file'; Path = $directory; Role = 'a1'; PlanId = 'plan-nested'; Children = $tree }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        @($apply['manifest']).Count | Should -Be 1
        (Test-PcxFixtureFileExists -Path $leaf) | Should -BeFalse
    }

    It 'skips a locked file, deletes the free one, and reports the skip per file' {
        $directory = [System.IO.Path]::Combine($script:SystemRoot, 'SoftwareDistribution\Download')
        $first = [System.IO.Path]::Combine($directory, 'a.cab')
        $locked = [System.IO.Path]::Combine($directory, 'locked.cab')

        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{
                $directory.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $directory -Attributes 'Directory' -Directory $true)
                $first.ToLowerInvariant()     = (New-PcxFixtureFileRecord -Path $first -Text 'aaa')
                $locked.ToLowerInvariant()    = (New-PcxFixtureFileRecord -Path $locked -Text 'zzz' -Locked $true)
            }
        }

        $target = @{ Kind = 'file'; Path = $directory; Role = 'a1'; PlanId = 'plan-locked'; Children = @($first, $locked) }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        $apply['code'] | Should -BeNullOrEmpty
        @($apply['deleted']).Count | Should -Be 1
        @($apply['residue']).Count | Should -Be 0
        @($apply['skipped']).Count | Should -Be 1
        @($apply['skipped'])[0]['path'] | Should -Be $locked
        [string]@($apply['skipped'])[0]['code'] | Should -Be 'PCX-E-PLATFORM-LOCKED'
        [string]@($apply['skipped'])[0]['reason'] | Should -Not -BeNullOrEmpty
        [string]$apply['reason'] | Should -Match 'skipped 1'
        (Test-PcxFixtureFileExists -Path $first) | Should -BeFalse
        (Test-PcxFixtureFileExists -Path $locked) | Should -BeTrue
        $apply['restorable'] | Should -BeFalse

        $verification = Test-PcxFileProviderResult -Result $apply
        $verification['status'] | Should -Be 'COMMITTED'
        @($verification['skipped']).Count | Should -Be 1
    }

    It 'refuses when every file is locked and deletes nothing' {
        $directory = [System.IO.Path]::Combine($script:SystemRoot, 'SoftwareDistribution\Download')
        $first = [System.IO.Path]::Combine($directory, 'first.cab')
        $second = [System.IO.Path]::Combine($directory, 'second.cab')

        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{
                $directory.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $directory -Attributes 'Directory' -Directory $true)
                $first.ToLowerInvariant()     = (New-PcxFixtureFileRecord -Path $first -Text 'aaa' -Locked $true)
                $second.ToLowerInvariant()    = (New-PcxFixtureFileRecord -Path $second -Text 'bbb' -Locked $true)
            }
        }

        $target = @{ Kind = 'file'; Path = $directory; Role = 'a1'; PlanId = 'plan-all-locked'; Children = @($first, $second) }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'FAILED'
        $apply['status'] | Should -Not -Be 'COMMITTED'
        $apply['code'] | Should -Be 'PCX-E-PLATFORM-LOCKED'
        @($apply['deleted']).Count | Should -Be 0
        @($apply['residue']).Count | Should -Be 0
        @($apply['skipped']).Count | Should -Be 2
        [string]$apply['reason'] | Should -Match 'no file could be deleted'
        (Test-PcxFixtureFileExists -Path $first) | Should -BeTrue
        (Test-PcxFixtureFileExists -Path $second) | Should -BeTrue
        $apply['restorable'] | Should -BeFalse

        (Test-PcxFileProviderResult -Result $apply)['status'] | Should -Be 'FAILED'
    }

    It 'refuses a single locked file with its typed code and deletes nothing' {
        $file = [System.IO.Path]::Combine($script:LocalAppData, 'Microsoft\Windows\Explorer\thumbcache_32.db')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $file.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $file -Text 'thumb-bytes' -Locked $true) }
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $file; Role = 'a1'; PlanId = 'plan-single-locked' } -Profile $script:Profile

        $apply['status'] | Should -Be 'FAILED'
        $apply['code'] | Should -Be 'PCX-E-PLATFORM-LOCKED'
        @($apply['deleted']).Count | Should -Be 0
        @($apply['skipped']).Count | Should -Be 1
        @($apply['skipped'])[0]['path'] | Should -Be $file
        (Test-PcxFixtureFileExists -Path $file) | Should -BeTrue

        (Test-PcxFileProviderResult -Result $apply)['status'] | Should -Be 'FAILED'
    }

    It 'treats an absent A1 target as a skip, never as a missing failure' {
        $file = [System.IO.Path]::Combine($script:LocalAppData, 'Microsoft\Windows\Explorer\thumbcache_1024.db')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{}
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $file; Role = 'a1'; PlanId = 'plan-absent' } -Profile $script:Profile

        $apply['status'] | Should -Be 'FAILED'
        $apply['code'] | Should -Be 'PCX-E-PROVIDER-ALREADY-ABSENT'
        @($apply['deleted']).Count | Should -Be 0
        @($apply['skipped']).Count | Should -Be 1
        [string]@($apply['skipped'])[0]['code'] | Should -Be 'PCX-E-PROVIDER-ALREADY-ABSENT'
        [string]@($apply['skipped'])[0]['reason'] | Should -Match 'already absent'
        $apply['code'] | Should -Not -Be 'PCX-E-PROVIDER-MISSING'
    }

    It 'skips a file the pre-state cannot fingerprint and deletes the rest' {
        $directory = [System.IO.Path]::Combine($script:SystemRoot, 'SoftwareDistribution\Download')
        $first = [System.IO.Path]::Combine($directory, 'a.cab')
        $unreadable = [System.IO.Path]::Combine($directory, 'ghost.cab')

        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{
                $directory.ToLowerInvariant()   = (New-PcxFixtureFileRecord -Path $directory -Attributes 'Directory' -Directory $true)
                $first.ToLowerInvariant()       = (New-PcxFixtureFileRecord -Path $first -Text 'aaa')
                $unreadable.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $unreadable -Text 'zzz' -Unreadable $true)
            }
        }

        $target = @{ Kind = 'file'; Path = $directory; Role = 'a1'; PlanId = 'plan-unreadable'; Children = @($first, $unreadable) }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        $apply['code'] | Should -BeNullOrEmpty
        @($apply['deleted']).Count | Should -Be 1
        @($apply['residue']).Count | Should -Be 0
        @($apply['skipped']).Count | Should -Be 1
        @($apply['skipped'])[0]['path'] | Should -Be $unreadable
        [string]@($apply['skipped'])[0]['code'] | Should -Be 'PCX-E-PLATFORM-UNREADABLE'
        [string]@($apply['skipped'])[0]['reason'] | Should -Match 'being used'
        [string]$apply['reason'] | Should -Match 'skipped 1'
        (Test-PcxFixtureFileExists -Path $first) | Should -BeFalse
        (Test-PcxFixtureFileExists -Path $unreadable) | Should -BeTrue
        $apply['restorable'] | Should -BeFalse

        $verification = Test-PcxFileProviderResult -Result $apply
        $verification['status'] | Should -Be 'COMMITTED'
        @($verification['skipped']).Count | Should -Be 1
    }

    It 'refuses a single unfingerprintable file without deleting it' {
        $file = [System.IO.Path]::Combine($script:LocalAppData, 'Microsoft\Windows\Explorer\thumbcache_32.db')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $file.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $file -Text 'thumb-bytes' -Unreadable $true) }
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $file; Role = 'a1'; PlanId = 'plan-single-unreadable' } -Profile $script:Profile

        $apply['status'] | Should -Be 'FAILED'
        $apply['status'] | Should -Not -Be 'COMMITTED'
        $apply['code'] | Should -Be 'PCX-E-PLATFORM-UNREADABLE'
        @($apply['deleted']).Count | Should -Be 0
        @($apply['skipped']).Count | Should -Be 1
        @($apply['skipped'])[0]['path'] | Should -Be $file
        (Test-PcxFixtureFileExists -Path $file) | Should -BeTrue

        (Test-PcxFileProviderResult -Result $apply)['status'] | Should -Be 'FAILED'
    }

    It 'refuses a directory containing a reparse child' {
        $directory = [System.IO.Path]::Combine($script:SystemRoot, 'SoftwareDistribution\Download')
        $child = [System.IO.Path]::Combine($directory, 'link.cab')

        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{
                $directory.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $directory -Attributes 'Directory' -Directory $true)
                $child.ToLowerInvariant()     = (New-PcxFixtureFileRecord -Path $child -Text 'x' -Reparse $true)
            }
        }

        $target = @{ Kind = 'file'; Path = $directory; Role = 'a1'; PlanId = 'plan-reparse'; Children = @($child) }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-POLICY-REPARSE'
        (Test-PcxFixtureFileExists -Path $child) | Should -BeTrue
    }

    It 'refuses a directory target without an explicit Children tree' {
        $directory = [System.IO.Path]::Combine($script:SystemRoot, 'SoftwareDistribution\Download')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $directory.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $directory -Attributes 'Directory' -Directory $true) }
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $directory; Role = 'a1'; PlanId = 'plan-nochildren' } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-E-PROVIDER-FILE-TREE'
    }

    It 'refuses a path outside a1_roots' {
        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = 'C:\Users\tester\Documents\notes.txt'; Role = 'a1'; PlanId = 'plan-outside' } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-POLICY-FILE-ROOT'
    }

    It 'refuses a junction target' {
        $file = [System.IO.Path]::Combine($script:LocalAppData, 'Microsoft\Windows\Explorer\thumbcache_96.db')
        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $file; Role = 'a1'; PlanId = 'plan-junction'; Reparse = $true } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-POLICY-REPARSE'
    }

    It 'refuses a .. path' {
        $target = @{
            Kind   = 'file'
            Path   = 'C:\Windows\SoftwareDistribution\Download\..\..\System32\evil.dll'
            Role   = 'a1'
            PlanId = 'plan-dotdot'
        }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-POLICY-GRAMMAR'
    }

    It 'refuses a file target without a PlanId' {
        $file = [System.IO.Path]::Combine($script:LocalAppData, 'Microsoft\Windows\Explorer\thumbcache_256.db')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $file.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $file -Text 'x') }
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $file; Role = 'a1' } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-E-PROVIDER-PLANID'
        (Test-PcxFixtureFileExists -Path $file) | Should -BeTrue
    }
}

Describe 'file provider quarantine' {

    It 'quarantines, verifies and restores a file byte-identically' {
        $startup = [System.IO.Path]::Combine($script:AppData, 'Microsoft\Windows\Start Menu\Programs\Startup')
        $source = [System.IO.Path]::Combine($startup, 'update.lnk')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $source.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $source -Text 'shortcut-bytes') }
        }

        $target = @{ Kind = 'file'; Path = $source; Role = 'quarantine'; PlanId = 'plan-q' }
        $apply = Invoke-PcxFileProviderApply -Target $target -Profile $script:Profile

        $apply['status'] | Should -Be 'COMMITTED'
        $apply['restorable'] | Should -BeTrue
        $apply['restoreMode'] | Should -Be 'quarantine'

        $preSha = [string]$apply['snapshot']['pre']['sha256']
        $expectedDestination = [System.IO.Path]::Combine($script:LocalAppData, 'pcx\quarantine\plan-q', $preSha, 'update.lnk')
        $apply['restorePath'] | Should -Be $expectedDestination
        (Test-PcxFixtureFileExists -Path $source) | Should -BeFalse
        (Test-PcxFixtureFileExists -Path $expectedDestination) | Should -BeTrue

        (Test-PcxFileProviderResult -Result $apply)['status'] | Should -Be 'COMMITTED'

        $restore = Restore-PcxSnapshot -Snapshot $apply['snapshot']
        $restore['status'] | Should -Be 'restored'
        (Test-PcxFixtureFileExists -Path $source) | Should -BeTrue
        (Test-PcxFixtureFileExists -Path $expectedDestination) | Should -BeFalse

        $restoredSha = [string](Get-PcxFileProviderState -Target @{ Kind = 'file'; Path = $source })['sha256']
        $restoredSha | Should -Be $preSha
    }

    It 'refuses a cross-volume quarantine' {
        $source = 'D:\pcx-quarantine-roaming\Microsoft\Windows\Start Menu\Programs\Startup\update.lnk'
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $source.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $source -Text 'cross-volume') }
        }

        $profile = New-PcxProvidersProfile -EnvironmentOverride @{
            LOCALAPPDATA = 'C:\pcx-quarantine-local'
            APPDATA      = 'D:\pcx-quarantine-roaming'
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $source; Role = 'quarantine'; PlanId = 'plan-cross' } -Profile $profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-E-PROVIDER-VOLUME'
        (Test-PcxFixtureFileExists -Path $source) | Should -BeTrue
    }

    It 'refuses a directory as a quarantine source' {
        $startup = [System.IO.Path]::Combine($script:AppData, 'Microsoft\Windows\Start Menu\Programs\Startup')
        $source = [System.IO.Path]::Combine($startup, 'bundle')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $source.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $source -Attributes 'Directory' -Directory $true) }
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $source; Role = 'quarantine'; PlanId = 'plan-dirq' } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-E-PROVIDER-QUARANTINE-DIRECTORY'
    }

    It 'refuses an unfingerprintable file instead of quarantining it' {
        $startup = [System.IO.Path]::Combine($script:AppData, 'Microsoft\Windows\Start Menu\Programs\Startup')
        $source = [System.IO.Path]::Combine($startup, 'update.lnk')
        Write-PcxFixtureState -State @{
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = @{ $source.ToLowerInvariant() = (New-PcxFixtureFileRecord -Path $source -Text 'shortcut-bytes' -Unreadable $true) }
        }

        $apply = Invoke-PcxFileProviderApply -Target @{ Kind = 'file'; Path = $source; Role = 'quarantine'; PlanId = 'plan-q-unreadable' } -Profile $script:Profile

        $apply['status'] | Should -Be 'REFUSED'
        $apply['code'] | Should -Be 'PCX-E-PROVIDER-QUARANTINE'
        [string]$apply['reason'] | Should -Match 'fingerprinted'
        (Test-PcxFixtureFileExists -Path $source) | Should -BeTrue
    }
}

Describe 'provider static safety' {

    BeforeAll {
        $script:ProviderBannedTokens = @(
            'Remove-Item'
            'Set-ItemProperty'
            'New-ItemProperty'
            'Remove-ItemProperty'
            'Set-Service'
            'Get-ScheduledTask'
            'Enable-ScheduledTask'
            'Disable-ScheduledTask'
            'Get-Item'
            'Get-ChildItem'
            'Test-Path'
            'Set-Content'
            'Invoke-Expression'
            'reg.exe'
            'sc.exe'
            'schtasks.exe'
            'cmd /c'
            '[System.IO.Directory]::CreateDirectory'
            '[System.IO.File]::Delete'
            '[System.IO.Directory]::Delete'
        )
    }

    It 'contains no native cmdlet, no directory API and no shell' {
        foreach ($path in $script:ProviderSourcePaths) {
            $source = [System.IO.File]::ReadAllText($path)
            foreach ($token in $script:ProviderBannedTokens) {
                $source | Should -Not -Match ([regex]::Escape($token)) -Because "$([System.IO.Path]::GetFileName($path)) must not use '$token'"
            }
        }
    }

    It 'routes every mutation through the platform boundary' {
        $all = ''
        foreach ($path in $script:ProviderSourcePaths) {
            $all = $all + [System.IO.File]::ReadAllText($path)
        }

        $all | Should -Match ([regex]::Escape('Invoke-PcxPlatformWrite'))
        $all | Should -Match ([regex]::Escape('Invoke-PcxPlatformDelete'))
        $all | Should -Match ([regex]::Escape('Invoke-PcxPlatformMove'))
    }
}
}
