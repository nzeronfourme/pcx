<#
.SYNOPSIS
    Platform boundary suite for todo 3: adapter surface parity, typed
    round-trips through the JSON state adapter, the four write refusals, literal
    quote/ampersand targets, and the static safety scan.
#>

BeforeAll {
    if ($env:PCX_TEST_RUN -ne '1') {
        throw "PCX_TEST_RUN must be '1' before the suite starts. Run tests through tests/run.ps1."
    }

    # Sticky fixture mode, re-asserted for every suite.
    $env:PCX_TEST_RUN = '1'

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../../')).Path
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Pcx.psm1'
    $realAdapterPath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxPlatform.ps1'
    $testAdapterPath = Join-Path -Path $repoRoot -ChildPath 'tests/TestAdapter/PcxPlatform.Test.ps1'
    $testRootMarker = Join-Path -Path $repoRoot -ChildPath 'tests/.pcx-test-root'

    $env:PCX_PLATFORM_MODULE = (Resolve-Path -LiteralPath $testAdapterPath).Path
    $env:PCX_ALLOW_REAL_WRITES = $null
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE

    Import-Module -Name $modulePath -Force

    $pcxModule = Get-Module -Name 'Pcx'
    $script:GetPlatform = $pcxModule.ExportedCommands['Get-PcxPlatform']
    $script:PlatformRead = $pcxModule.ExportedCommands['Invoke-PcxPlatformRead']
    $script:PlatformWrite = $pcxModule.ExportedCommands['Invoke-PcxPlatformWrite']
    $script:PlatformDelete = $pcxModule.ExportedCommands['Invoke-PcxPlatformDelete']
    $script:PlatformMove = $pcxModule.ExportedCommands['Invoke-PcxPlatformMove']

    $script:platformFunctionNames = @(
        'Get-PcxPlatform'
        'Invoke-PcxPlatformRead'
        'Invoke-PcxPlatformWrite'
        'Invoke-PcxPlatformDelete'
        'Invoke-PcxPlatformMove'
    )
    $script:platformFunctionNamesSorted = @($script:platformFunctionNames | Sort-Object)

    function New-PcxPlatformState {
        # Seeds the adapter's state file. Key conventions mirror the adapter:
        # services/tasks/files are keyed by the lowercased identifier.
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [hashtable] $Registry = @{},
            [hashtable] $Services = @{},
            [hashtable] $Tasks = @{},
            [hashtable] $Files = @{}
        )

        $document = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = $Registry
            services = $Services
            tasks    = $Tasks
            files    = $Files
        }

        $directory = [System.IO.Path]::GetDirectoryName($Path)
        if ($directory -and -not [System.IO.Directory]::Exists($directory)) {
            $null = [System.IO.Directory]::CreateDirectory($directory)
        }

        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 8 -Compress), $utf8)
        $env:PCX_TEST_STATE_FILE = $Path
        return $Path
    }

    function New-PcxPlatformStatePath {
        param([Parameter(Mandatory = $true)][string] $Name)
        return (Join-Path -Path $TestDrive -ChildPath $Name)
    }
}

Describe 'pcx platform adapter surface' {

    It 'exposes the same five names from the real module and the fixture adapter' {
        $exportedPlatformNames = @(
            $pcxModule.ExportedCommands.Keys |
                Where-Object { $_ -like '*PcxPlatform*' } |
                Sort-Object
        )

        $exportedPlatformNames | Should -Be $script:platformFunctionNamesSorted

        $descriptor = & $script:GetPlatform

        $descriptor.Name | Should -BeExactly 'test'
        @($descriptor.Functions | Sort-Object) | Should -Be $script:platformFunctionNamesSorted
        $descriptor.ModulePath | Should -Be $env:PCX_PLATFORM_MODULE
        $descriptor.StateFile | Should -Not -BeNullOrEmpty
    }

    It 'returns the real descriptor when fixture mode is off' {
        $previousTestRun = $env:PCX_TEST_RUN
        try {
            $env:PCX_TEST_RUN = $null

            $descriptor = & $script:GetPlatform

            $descriptor.Name | Should -BeExactly 'real'
            $descriptor.ModulePath | Should -Be $realAdapterPath
            @($descriptor.Functions | Sort-Object) | Should -Be $script:platformFunctionNamesSorted
            $descriptor.StateFile | Should -BeNullOrEmpty
        }
        finally {
            $env:PCX_TEST_RUN = $previousTestRun
        }
    }

    It 'fails closed when fixture mode cannot load the adapter' {
        $previousModule = $env:PCX_PLATFORM_MODULE
        try {
            $env:PCX_PLATFORM_MODULE = $null
            { & $script:GetPlatform } | Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-ADAPTER*'

            $env:PCX_PLATFORM_MODULE = (Join-Path -Path $TestDrive -ChildPath 'missing-adapter.ps1')
            { & $script:GetPlatform } | Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-ADAPTER*'
        }
        finally {
            $env:PCX_PLATFORM_MODULE = $previousModule
        }
    }
}

Describe 'pcx platform registry round-trip' {

    BeforeEach {
        $script:registryStatePath = New-PcxPlatformStatePath -Name ('registry-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxPlatformState -Path $script:registryStatePath
        $script:registryTarget = @{
            Kind = 'registry'
            Path = 'HKCU:\Software\PcxTest\RoundTrip'
            Name = 'Level'
        }
    }

    It 'reads absent, writes, reads the value, deletes, and reads absent again' {
        $before = & $script:PlatformRead -Target $script:registryTarget
        $before.exists | Should -BeFalse

        $writeTarget = @{
            Kind  = 'registry'
            Path  = $script:registryTarget.Path
            Name  = $script:registryTarget.Name
            Type  = 'dword'
            Value = 3
        }
        $written = & $script:PlatformWrite -Target $writeTarget
        $written.applied | Should -BeTrue

        $after = & $script:PlatformRead -Target $script:registryTarget
        $after.exists | Should -BeTrue
        $after.type | Should -BeExactly 'dword'
        $after.data | Should -Be 3

        $deleted = & $script:PlatformDelete -Target $script:registryTarget
        $deleted.deleted | Should -BeTrue

        $final = & $script:PlatformRead -Target $script:registryTarget
        $final.exists | Should -BeFalse
        $final.data | Should -BeNullOrEmpty
    }

    It 'round-trips every supported value type' {
        $cases = @(
            @{ Type = 'string'; Value = 'plain'; Expected = 'plain' }
            @{ Type = 'expandstring'; Value = '%TEMP%\pcx'; Expected = '%TEMP%\pcx' }
            @{ Type = 'dword'; Value = 42; Expected = 42 }
            @{ Type = 'qword'; Value = 5000000000; Expected = [long]5000000000 }
            @{ Type = 'binary'; Value = [byte[]](0, 1, 254, 255); Expected = 'AAH+/w==' }
            @{ Type = 'multistring'; Value = [string[]]@('one', 'two'); Expected = @('one', 'two') }
        )

        foreach ($case in $cases) {
            $target = @{
                Kind  = 'registry'
                Path  = 'HKLM:\SOFTWARE\PcxTest\Types'
                Name  = ('value-' + $case.Type)
                Type  = $case.Type
                Value = $case.Value
            }

            $null = & $script:PlatformWrite -Target $target
            $state = & $script:PlatformRead -Target $target

            $state.exists | Should -BeTrue -Because "type $($case.Type) must round-trip"
            $state.type | Should -BeExactly $case.Type

            if ($case.Type -eq 'binary') {
                ([System.Convert]::ToBase64String([byte[]]$state.data)) | Should -BeExactly $case.Expected
            }
            elseif ($case.Type -eq 'multistring') {
                @($state.data) | Should -Be $case.Expected
            }
            else {
                $state.data | Should -Be $case.Expected
            }
        }
    }

    It 'refuses to delete a value that does not exist' {
        { & $script:PlatformDelete -Target $script:registryTarget } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-MISSING*'
    }

    It 'refuses an unknown registry value type' {
        $target = @{ Kind = 'registry'; Path = 'HKCU:\Software\PcxTest'; Name = 'Bad'; Type = 'float'; Value = 1 }

        { & $script:PlatformWrite -Target $target } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
    }

    It 'refuses a registry path outside HKCU and HKLM' {
        $target = @{ Kind = 'registry'; Path = 'HHIVE:\Software\PcxTest'; Name = 'X' }

        { & $script:PlatformRead -Target $target } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
    }
}

Describe 'pcx platform service round-trip' {

    BeforeEach {
        $script:serviceStatePath = New-PcxPlatformStatePath -Name ('service-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxPlatformState -Path $script:serviceStatePath -Services @{
            'pcxtestspooler' = @{ name = 'PcxTestSpooler'; controlSet = 'ControlSet002'; start = 2 }
        }
        $script:serviceTarget = @{ Kind = 'service'; Name = 'PcxTestSpooler' }
    }

    It 'reads Start with its resolved control set and writes Manual then Disabled' {
        $before = & $script:PlatformRead -Target $script:serviceTarget
        $before.exists | Should -BeTrue
        $before.start | Should -Be 2
        $before.controlSet | Should -BeExactly 'ControlSet002'

        $null = & $script:PlatformWrite -Target @{ Kind = 'service'; Name = 'PcxTestSpooler'; Start = 4 }
        (& $script:PlatformRead -Target $script:serviceTarget).start | Should -Be 4

        $applied = & $script:PlatformWrite -Target @{ Kind = 'service'; Name = 'PcxTestSpooler'; Start = 3 }
        $applied.applied | Should -BeTrue
        (& $script:PlatformRead -Target $script:serviceTarget).start | Should -Be 3
    }

    It 'refuses a Start value Set-Service cannot express' {
        { & $script:PlatformWrite -Target @{ Kind = 'service'; Name = 'PcxTestSpooler'; Start = 1 } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
    }

    It 'refuses a write to a service that does not exist' {
        { & $script:PlatformWrite -Target @{ Kind = 'service'; Name = 'PcxTestAbsent'; Start = 4 } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-MISSING*'
    }

    It 'refuses a service name that smuggles a path separator' {
        { & $script:PlatformRead -Target @{ Kind = 'service'; Name = '..\PcxTestSpooler' } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
    }
}

Describe 'pcx platform task round-trip' {

    BeforeEach {
        $script:taskStatePath = New-PcxPlatformStatePath -Name ('task-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxPlatformState -Path $script:taskStatePath -Tasks @{
            '\pcxtest\roundtrip' = @{ path = '\PcxTest\RoundTrip'; enabled = $true; state = 'Ready' }
        }
        $script:taskTarget = @{ Kind = 'task'; Path = '\PcxTest\RoundTrip' }
    }

    It 'reads enabled and toggles it off and on again' {
        $before = & $script:PlatformRead -Target $script:taskTarget
        $before.exists | Should -BeTrue
        $before.enabled | Should -BeTrue
        $before.state | Should -BeExactly 'Ready'

        $null = & $script:PlatformWrite -Target @{ Kind = 'task'; Path = '\PcxTest\RoundTrip'; Enabled = $false }
        $disabled = & $script:PlatformRead -Target $script:taskTarget
        $disabled.enabled | Should -BeFalse
        $disabled.state | Should -BeExactly 'Disabled'

        $null = & $script:PlatformWrite -Target @{ Kind = 'task'; Path = '\PcxTest\RoundTrip'; Enabled = $true }
        (& $script:PlatformRead -Target $script:taskTarget).enabled | Should -BeTrue
    }

    It 'requires a boolean Enabled and refuses a non-boolean' {
        { & $script:PlatformWrite -Target @{ Kind = 'task'; Path = '\PcxTest\RoundTrip' } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
        { & $script:PlatformWrite -Target @{ Kind = 'task'; Path = '\PcxTest\RoundTrip'; Enabled = 'false' } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
    }

    It 'never deletes a scheduled task' {
        { & $script:PlatformDelete -Target $script:taskTarget } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-OPERATION*'
    }

    It 'refuses a task path without a leading backslash' {
        { & $script:PlatformRead -Target @{ Kind = 'task'; Path = 'PcxTest\RoundTrip' } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
    }
}

Describe 'pcx platform file round-trip' {

    BeforeEach {
        $script:fileStatePath = New-PcxPlatformStatePath -Name ('file-' + [guid]::NewGuid().ToString('n') + '.json')
        $script:fileBytes = [System.Text.Encoding]::UTF8.GetBytes('pcx-quarantine-bytes')
        $script:fileSource = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'startup\pcx-startup.lnk'))
        $script:fileDestination = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'quarantine\pcx-startup.lnk'))

        $null = New-PcxPlatformState -Path $script:fileStatePath -Files @{
            ($script:fileSource.ToLowerInvariant()) = @{
                path           = $script:fileSource
                contentBase64  = [System.Convert]::ToBase64String($script:fileBytes)
                attributes     = 'Archive'
                isReparsePoint = $false
            }
            ($script:fileDestination.ToLowerInvariant()) = @{
                path           = $script:fileDestination
                contentBase64  = [System.Convert]::ToBase64String([byte[]](1, 2, 3))
                attributes     = 'Archive'
                isReparsePoint = $false
            }
        }
    }

    It 'reads size, sha256 and attributes, moves without overwrite, then deletes' {
        $before = & $script:PlatformRead -Target @{ Kind = 'file'; Path = $script:fileSource }
        $before.exists | Should -BeTrue
        $before.length | Should -Be $script:fileBytes.Length
        $before.sha256 | Should -BeExactly (Get-PcxSha256 -Bytes $script:fileBytes)
        $before.attributes | Should -BeExactly 'Archive'
        $before.isReparsePoint | Should -BeFalse

        # A destination that already exists is a refusal, not an overwrite.
        { & $script:PlatformMove -Target @{ Kind = 'file'; Path = $script:fileSource; Destination = $script:fileDestination } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'

        $freeDestination = Join-Path -Path $TestDrive -ChildPath 'quarantine\pcx-startup-moved.lnk'
        $moved = & $script:PlatformMove -Target @{ Kind = 'file'; Path = $script:fileSource; Destination = $freeDestination }
        $moved.moved | Should -BeTrue

        (& $script:PlatformRead -Target @{ Kind = 'file'; Path = $script:fileSource }).exists | Should -BeFalse

        $afterMove = & $script:PlatformRead -Target @{ Kind = 'file'; Path = $freeDestination }
        $afterMove.exists | Should -BeTrue
        $afterMove.sha256 | Should -BeExactly $before.sha256

        $null = & $script:PlatformDelete -Target @{ Kind = 'file'; Path = $freeDestination }
        (& $script:PlatformRead -Target @{ Kind = 'file'; Path = $freeDestination }).exists | Should -BeFalse
    }

    It 'reports reparse points and never hashes a directory' {
        $directoryPath = Join-Path -Path $TestDrive -ChildPath 'junction-like'
        $null = New-PcxPlatformState -Path $script:fileStatePath -Files @{
            ($directoryPath.ToLowerInvariant()) = @{
                path           = $directoryPath
                attributes     = 'Directory, ReparsePoint'
                isReparsePoint = $true
            }
        }

        $state = & $script:PlatformRead -Target @{ Kind = 'file'; Path = $directoryPath }
        $state.exists | Should -BeTrue
        $state.isReparsePoint | Should -BeTrue
        $state.length | Should -BeNullOrEmpty
        $state.sha256 | Should -BeNullOrEmpty
    }

    It 'reports an unreadable file with a verdict instead of throwing' {
        $lockedPath = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'locked\thumbcache_32.db'))
        $null = New-PcxPlatformState -Path $script:fileStatePath -Files @{
            ($lockedPath.ToLowerInvariant()) = @{
                path           = $lockedPath
                contentBase64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('thumb-bytes'))
                attributes     = 'Archive'
                isReparsePoint = $false
                unreadable     = $true
            }
        }

        $state = & $script:PlatformRead -Target @{ Kind = 'file'; Path = $lockedPath }

        $state.exists | Should -BeTrue
        $state.length | Should -Be 11
        $state.sha256 | Should -BeNullOrEmpty
        $state.readStatus | Should -BeExactly 'unavailable'
        [string]$state.readReason | Should -Not -BeNullOrEmpty
    }

    It 'never writes file content and never deletes a missing file' {
        { & $script:PlatformWrite -Target @{ Kind = 'file'; Path = $script:fileSource } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-OPERATION*'
        { & $script:PlatformDelete -Target @{ Kind = 'file'; Path = (Join-Path $TestDrive 'absent.bin') } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-MISSING*'
    }
}

Describe 'pcx platform quote and ampersand targets stay literal' {

    It 'round-trips a registry value name and data containing a quote and an ampersand' {
        $statePath = New-PcxPlatformStatePath -Name ('literal-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxPlatformState -Path $statePath

        $target = @{
            Kind  = 'registry'
            Path  = 'HKCU:\Software\PcxT&st"Q'
            Name  = 'a&b"c'
            Type  = 'string'
            Value = 'x&y"z'
        }

        $null = & $script:PlatformWrite -Target $target
        $state = & $script:PlatformRead -Target @{ Kind = 'registry'; Path = $target.Path; Name = $target.Name }

        $state.exists | Should -BeTrue
        $state.path | Should -BeExactly 'HKCU:\Software\PcxT&st"Q'
        $state.name | Should -BeExactly 'a&b"c'
        $state.data | Should -BeExactly 'x&y"z'

        # The state file is data, not a command line: it still parses as JSON
        # and still holds the literal characters.
        $document = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($statePath))
        $record = @($document.registry.PSObject.Properties)[0].Value
        $record.name | Should -BeExactly 'a&b"c'
        $record.data | Should -BeExactly 'x&y"z'
    }
}

Describe 'pcx platform fail-closed test adapter' {

    BeforeEach {
        $statePath = New-PcxPlatformStatePath -Name ('closed-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxPlatformState -Path $statePath
    }

    It 'throws on an unknown target kind for every operation' {
        $unknown = @{ Kind = 'process'; Path = 'anything' }

        { & $script:PlatformRead -Target $unknown } | Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-KIND*'
        { & $script:PlatformWrite -Target $unknown } | Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-KIND*'
        { & $script:PlatformDelete -Target $unknown } | Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-KIND*'
        { & $script:PlatformMove -Target $unknown } | Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-KIND*'
    }

    It 'throws when the target carries no kind' {
        { & $script:PlatformRead -Target @{ Path = 'x' } } | Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
        { & $script:PlatformRead -Target $null } | Should -Throw
    }

    It 'throws on an operation a known kind does not support' {
        { & $script:PlatformMove -Target @{ Kind = 'registry'; Path = 'HKCU:\Software\X'; Name = 'y' } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-OPERATION*'
        { & $script:PlatformDelete -Target @{ Kind = 'service'; Name = 'Anything' } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-OPERATION*'
        { & $script:PlatformMove -Target @{ Kind = 'file'; Path = (Join-Path $TestDrive 'a.bin') } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TARGET*'
    }

    It 'throws on a malformed state file instead of returning success' {
        [System.IO.File]::WriteAllText($env:PCX_TEST_STATE_FILE, '{ not json ')

        { & $script:PlatformRead -Target @{ Kind = 'file'; Path = (Join-Path $TestDrive 'a.bin') } } |
            Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-STATE*'
    }
}

Describe 'pcx platform real adapter refuses writes' {

    BeforeAll {
        $copyDirectory = Join-Path -Path $TestDrive -ChildPath 'real-adapter-copy'
        $null = [System.IO.Directory]::CreateDirectory($copyDirectory)
        $script:realAdapterCopy = Join-Path -Path $copyDirectory -ChildPath 'PcxPlatform.ps1'
        [System.IO.File]::Copy($realAdapterPath, $script:realAdapterCopy, $true)

        $script:guardTargetPath = 'HKCU:\Software\pcx-platform-guard-' + [guid]::NewGuid().ToString('n')
    }

    It 'proves this checkout carries the test-root marker' {
        [System.IO.File]::Exists($testRootMarker) | Should -BeTrue
    }

    It 'refuses a real write with no arming capability and performs no OS call' {
        $previousTestRun = $env:PCX_TEST_RUN
        $previousArm = $env:PCX_ALLOW_REAL_WRITES
        try {
            $env:PCX_TEST_RUN = $null
            $env:PCX_ALLOW_REAL_WRITES = $null

            # The copy lives outside the repository, so only arming can stop it.
            . $script:realAdapterCopy

            (Test-Path -LiteralPath $script:guardTargetPath) | Should -BeFalse

            $target = @{ Kind = 'registry'; Path = $script:guardTargetPath; Name = 'Value'; Type = 'dword'; Value = 1 }

            { Write-PcxPlatformState -Target $target } |
                Should -Throw -ExceptionType ([System.UnauthorizedAccessException]) -ExpectedMessage '*PCX-E-PLATFORM-NOARM*'
            { Delete-PcxPlatformState -Target $target } |
                Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-NOARM*'
            { Move-PcxPlatformState -Target @{ Kind = 'file'; Path = (Join-Path $TestDrive 'a.bin'); Destination = (Join-Path $TestDrive 'b.bin') } } |
                Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-NOARM*'

            # Refusal happened before any OS call: the key was never created.
            (Test-Path -LiteralPath $script:guardTargetPath) | Should -BeFalse
        }
        finally {
            $env:PCX_TEST_RUN = $previousTestRun
            $env:PCX_ALLOW_REAL_WRITES = $previousArm
        }
    }

    It 'refuses a real write when the arming variable is not exactly 1' {
        $previousTestRun = $env:PCX_TEST_RUN
        $previousArm = $env:PCX_ALLOW_REAL_WRITES
        try {
            $env:PCX_TEST_RUN = $null
            $env:PCX_ALLOW_REAL_WRITES = '0'

            . $script:realAdapterCopy

            { Write-PcxPlatformState -Target @{ Kind = 'registry'; Path = $script:guardTargetPath; Name = 'Value'; Type = 'dword'; Value = 1 } } |
                Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-NOARM*'

            (Test-Path -LiteralPath $script:guardTargetPath) | Should -BeFalse
        }
        finally {
            $env:PCX_TEST_RUN = $previousTestRun
            $env:PCX_ALLOW_REAL_WRITES = $previousArm
        }
    }

    It 'refuses with PCX-E-PLATFORM-TESTRUN when the sentinel is set, before any other check' {
        $previousTestRun = $env:PCX_TEST_RUN
        $previousArm = $env:PCX_ALLOW_REAL_WRITES
        try {
            $env:PCX_TEST_RUN = '1'
            $env:PCX_ALLOW_REAL_WRITES = '1'

            . $script:realAdapterCopy

            { Write-PcxPlatformState -Target @{ Kind = 'registry'; Path = $script:guardTargetPath; Name = 'Value'; Type = 'dword'; Value = 1 } } |
                Should -Throw -ExceptionType ([System.UnauthorizedAccessException]) -ExpectedMessage '*PCX-E-PLATFORM-TESTRUN*'

            (Test-Path -LiteralPath $script:guardTargetPath) | Should -BeFalse
        }
        finally {
            $env:PCX_TEST_RUN = $previousTestRun
            $env:PCX_ALLOW_REAL_WRITES = $previousArm
        }
    }

    It 'refuses through the module router as well, not only through a dot-sourced copy' {
        $previousTestRun = $env:PCX_TEST_RUN
        $previousArm = $env:PCX_ALLOW_REAL_WRITES
        try {
            $env:PCX_TEST_RUN = $null
            $env:PCX_ALLOW_REAL_WRITES = '1'

            { & $script:PlatformWrite -Target @{ Kind = 'registry'; Path = $script:guardTargetPath; Name = 'Value'; Type = 'dword'; Value = 1 } } |
                Should -Throw -ExceptionType ([System.UnauthorizedAccessException]) -ExpectedMessage '*PCX-E-PLATFORM-TESTROOT*'

            (Test-Path -LiteralPath $script:guardTargetPath) | Should -BeFalse
        }
        finally {
            $env:PCX_TEST_RUN = $previousTestRun
            $env:PCX_ALLOW_REAL_WRITES = $previousArm
        }
    }

    It 'still refuses when a scratch test clears the sentinel, because the repository marker blocks it' {
        $previousTestRun = $env:PCX_TEST_RUN
        $previousArm = $env:PCX_ALLOW_REAL_WRITES
        try {
            # Scratch test condition: the sticky sentinel is emptied by hand.
            $env:PCX_TEST_RUN = $null
            # Even full arming must not help inside a test checkout.
            $env:PCX_ALLOW_REAL_WRITES = '1'

            . $realAdapterPath

            { Write-PcxPlatformState -Target @{ Kind = 'registry'; Path = $script:guardTargetPath; Name = 'Value'; Type = 'dword'; Value = 1 } } |
                Should -Throw -ExceptionType ([System.UnauthorizedAccessException]) -ExpectedMessage '*PCX-E-PLATFORM-TESTROOT*'
            { Delete-PcxPlatformState -Target @{ Kind = 'file'; Path = (Join-Path $TestDrive 'a.bin') } } |
                Should -Throw -ExpectedMessage '*PCX-E-PLATFORM-TESTROOT*'

            (Test-Path -LiteralPath $script:guardTargetPath) | Should -BeFalse
        }
        finally {
            $env:PCX_TEST_RUN = $previousTestRun
            $env:PCX_ALLOW_REAL_WRITES = $previousArm
        }
    }
}

Describe 'pcx platform real adapter reads' {
    # Reads are safe and are never refused, so they can run against the live
    # machine. Writes stay blocked by the refusal suite above.

    BeforeAll {
        $copyDirectory = Join-Path -Path $TestDrive -ChildPath 'real-adapter-read'
        $null = [System.IO.Directory]::CreateDirectory($copyDirectory)
        $script:realReaderCopy = Join-Path -Path $copyDirectory -ChildPath 'PcxPlatform.ps1'
        [System.IO.File]::Copy($realAdapterPath, $script:realReaderCopy, $true)
    }

    It 'reads a real registry value with its type' {
        . $script:realReaderCopy

        $state = Read-PcxPlatformState -Target @{ Kind = 'registry'; Path = 'HKLM:\SYSTEM\Select'; Name = 'Current' }

        $state.exists | Should -BeTrue
        $state.type | Should -BeExactly 'dword'
        $state.data | Should -BeOfType ([int])
    }

    It 'reads a real service Start value and keeps the control set with it' {
        . $script:realReaderCopy

        $serviceName = (Get-Service | Sort-Object -Property Name | Select-Object -First 1).Name
        $serviceName | Should -Not -BeNullOrEmpty

        $state = Read-PcxPlatformState -Target ([pscustomobject]@{ Kind = 'service'; Name = $serviceName })

        $state.exists | Should -BeTrue
        $state.controlSet | Should -Match '^ControlSet[0-9]{3}$'
        $state.start | Should -BeOfType ([int])
        $state.path | Should -BeExactly ('HKLM:\SYSTEM\{0}\Services\{1}' -f $state.controlSet, $serviceName)
    }

    It 'reads a real scheduled task through its full path' {
        . $script:realReaderCopy

        $task = Get-ScheduledTask -ErrorAction SilentlyContinue | Select-Object -First 1
        $task | Should -Not -BeNullOrEmpty

        $fullPath = [string]$task.TaskPath + [string]$task.TaskName
        $state = Read-PcxPlatformState -Target ([pscustomobject]@{ Kind = 'task'; Path = $fullPath })

        $state.exists | Should -BeTrue
        $state.enabled | Should -BeOfType ([bool])
        $state.path | Should -BeExactly $fullPath
    }

    It 'reads a real file hash and attributes' {
        . $script:realReaderCopy

        $state = Read-PcxPlatformState -Target @{ Kind = 'file'; Path = $modulePath }

        $state.exists | Should -BeTrue
        $state.length | Should -Be ((Get-Item -LiteralPath $modulePath).Length)
        $state.sha256 | Should -BeExactly (Get-PcxSha256 -Path $modulePath)
        $state.attributes | Should -Not -BeNullOrEmpty
        $state.isReparsePoint | Should -BeFalse
    }

    It 'never throws on a file Windows holds open and reports a verdict' {
        . $script:realReaderCopy

        $lockedPath = Join-Path -Path $TestDrive -ChildPath 'real-adapter-read\locked.bin'
        [System.IO.File]::WriteAllText($lockedPath, 'locked-bytes', (New-Object System.Text.UTF8Encoding -ArgumentList $false))
        $stream = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $state = Read-PcxPlatformState -Target @{ Kind = 'file'; Path = $lockedPath }

            $state.exists | Should -BeTrue
            $state.sha256 | Should -BeNullOrEmpty
            $state.readStatus | Should -BeExactly 'unavailable'
            [string]$state.readReason | Should -Not -BeNullOrEmpty
        }
        finally {
            $stream.Close()
        }

        # The verdict leaves the file alone: it hashes normally once released.
        $released = Read-PcxPlatformState -Target @{ Kind = 'file'; Path = $lockedPath }
        $released.sha256 | Should -BeExactly (Get-PcxSha256 -Path $lockedPath)
    }
}

Describe 'pcx platform static safety scan' {

    BeforeAll {
        # Tokens are assembled from fragments so this suite does not match itself.
        $script:bannedTokens = @(
            ('cmd' + ' /c')
            ('reg' + '.exe')
            ('sc' + '.exe')
            ('schtasks' + '.exe')
            ('Invoke' + '-Expression')
        )
        $script:removeItemToken = 'Remove' + '-Item'
        $script:moveFileToken = 'MoveFileEx' + 'W'

        $scanFiles = New-Object System.Collections.Generic.List[string]
        $scanFiles.Add((Join-Path -Path $repoRoot -ChildPath 'pcx.ps1'))
        $scanFiles.Add((Join-Path -Path $repoRoot -ChildPath 'tests/run.ps1'))

        foreach ($directory in @('src/pcx', 'tests/TestAdapter')) {
            foreach ($file in (Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath $directory) -Recurse -File)) {
                if ($file.Extension -eq '.ps1' -or $file.Extension -eq '.psm1') {
                    $scanFiles.Add($file.FullName)
                }
            }
        }

        $script:scanSet = @($scanFiles | Where-Object { [System.IO.File]::Exists($_) } | Sort-Object -Unique)
    }

    It 'never calls a console utility or evaluates an expression' {
        foreach ($file in $script:scanSet) {
            $source = [System.IO.File]::ReadAllText($file)
            foreach ($token in $script:bannedTokens) {
                $source | Should -Not -Match ([regex]::Escape($token)) -Because "$file must not use the banned token '$token'"
            }
        }
    }

    It 'keeps the file delete cmdlet inside PcxPlatform.ps1 only' {
        foreach ($file in $script:scanSet) {
            $source = [System.IO.File]::ReadAllText($file)
            if ([System.IO.Path]::GetFileName($file) -eq 'PcxPlatform.ps1') {
                $source | Should -Match ([regex]::Escape($script:removeItemToken))
                continue
            }
            $source | Should -Not -Match ([regex]::Escape($script:removeItemToken)) -Because "$file must not delete files"
        }
    }

    It 'keeps the native move inside PcxPlatform.ps1 and PcxJson.ps1 only' {
        foreach ($file in $script:scanSet) {
            $name = [System.IO.Path]::GetFileName($file)
            $source = [System.IO.File]::ReadAllText($file)
            if ($name -eq 'PcxPlatform.ps1' -or $name -eq 'PcxJson.ps1') {
                continue
            }
            $source | Should -Not -Match ([regex]::Escape($script:moveFileToken)) -Because "$file must not move files"
        }
    }

    It 'proves the scanner would catch a banned call' {
        # Guard against a scan that silently matches nothing.
        $sample = 'x' + ('cmd' + ' /c') + ' y'
        $sample | Should -Match ([regex]::Escape(('cmd' + ' /c')))
    }
}

AfterAll {
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
}
