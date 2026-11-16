<#
.SYNOPSIS
    Snapshot and restore suite for todo 4: exact per-kind field sets, registry
    value round-trips including absence, service control-set capture and
    refusal, task identity preservation, file byte identity, terminal drift,
    canonical-JSON documents, and the static safety scan.
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
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE

    Import-Module -Name $modulePath -Force

    $pcxModule = Get-Module -Name 'Pcx'
    $script:Module = $pcxModule
    $script:GetTargetState = $pcxModule.ExportedCommands['Get-PcxTargetState']
    $script:NewSnapshot = $pcxModule.ExportedCommands['New-PcxSnapshot']
    $script:CompareState = $pcxModule.ExportedCommands['Compare-PcxState']
    $script:RestoreSnapshot = $pcxModule.ExportedCommands['Restore-PcxSnapshot']

    $script:PlatformRead = $pcxModule.ExportedCommands['Invoke-PcxPlatformRead']
    $script:PlatformWrite = $pcxModule.ExportedCommands['Invoke-PcxPlatformWrite']
    $script:PlatformDelete = $pcxModule.ExportedCommands['Invoke-PcxPlatformDelete']
    $script:PlatformMove = $pcxModule.ExportedCommands['Invoke-PcxPlatformMove']

    $script:CanonicalJson = $pcxModule.ExportedCommands['ConvertTo-PcxCanonicalJson']
    $script:WriteJsonAtomic = $pcxModule.ExportedCommands['Write-PcxJsonAtomic']
    $script:ReadJson = $pcxModule.ExportedCommands['Read-PcxJson']

    $script:snapshotSourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxSnapshot.ps1'

    function New-PcxSnapshotStatePath {
        param([Parameter(Mandatory = $true)][string] $Name)
        return (Join-Path -Path $TestDrive -ChildPath $Name)
    }

    function New-PcxSnapshotState {
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

    function Read-PcxSnapshotStateDocument {
        param([Parameter(Mandatory = $true)][string] $Path)
        return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) -ErrorAction Stop)
    }

    function Save-PcxSnapshotStateDocument {
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $true)][object] $Document
        )

        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Document -Depth 8 -Compress), $utf8)
    }

    function Get-PcxSnapshotRegistryKey {
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $true)][string] $Name
        )

        return ($Path.ToLowerInvariant() + [char]0x1F + $Name.ToLowerInvariant())
    }
}

Describe 'pcx snapshot registry value' {

    BeforeEach {
        $script:registryStatePath = New-PcxSnapshotStatePath -Name ('snap-registry-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxSnapshotState -Path $script:registryStatePath
        $script:registryTarget = @{
            Kind  = 'registry'
            Path  = 'HKCU:\Software\PcxSnapshot'
            Name  = 'Level'
            Type  = 'dword'
            Value = 5
        }
    }

    It 'captures a non-existent value and restores it to absence' {
        $pre = & $script:GetTargetState -Target $script:registryTarget

        $pre['exists'] | Should -BeFalse
        $pre['type'] | Should -BeNullOrEmpty
        $pre['data'] | Should -BeNullOrEmpty
        @($pre.Keys) | Should -Be @('kind', 'path', 'name', 'exists', 'type', 'data')

        $snapshot = & $script:NewSnapshot -Target $script:registryTarget

        @($snapshot.Keys) | Should -Be @('schema', 'kind', 'target', 'pre', 'post')
        @($snapshot['target'].Keys) | Should -Be @('kind', 'path', 'name')
        (& $script:CompareState -Recorded $pre -Current $snapshot['pre'])['status'] | Should -BeExactly 'equal'
        $snapshot['post']['exists'] | Should -BeTrue
        $snapshot['post']['type'] | Should -BeExactly 'dword'
        $snapshot['post']['data'] | Should -Be 5

        $null = & $script:PlatformWrite -Target $script:registryTarget
        (& $script:GetTargetState -Target $script:registryTarget)['exists'] | Should -BeTrue

        $result = & $script:RestoreSnapshot -Snapshot $snapshot

        $result['status'] | Should -BeExactly 'restored'
        (& $script:GetTargetState -Target $script:registryTarget)['exists'] | Should -BeFalse
    }

    It 'round-trips an existing value to its exact type and data' {
        $key = Get-PcxSnapshotRegistryKey -Path $script:registryTarget.Path -Name $script:registryTarget.Name
        $null = New-PcxSnapshotState -Path $script:registryStatePath -Registry @{
            $key = @{ path = $script:registryTarget.Path; name = $script:registryTarget.Name; type = 'dword'; data = 2 }
        }

        $pre = & $script:GetTargetState -Target $script:registryTarget
        $pre['data'] | Should -Be 2

        $snapshot = & $script:NewSnapshot -Target $script:registryTarget
        $snapshot['post']['data'] | Should -Be 5

        $null = & $script:PlatformWrite -Target $script:registryTarget
        (& $script:GetTargetState -Target $script:registryTarget)['data'] | Should -Be 5

        $null = & $script:RestoreSnapshot -Snapshot $snapshot

        $after = & $script:GetTargetState -Target $script:registryTarget
        $after['exists'] | Should -BeTrue
        $after['type'] | Should -BeExactly 'dword'
        $after['data'] | Should -Be 2
    }

    It 'round-trips binary registry data through base64 canonicalization' {
        $originalBytes = [byte[]](0, 1, 254, 255)
        $target = @{
            Kind  = 'registry'
            Path  = 'HKCU:\Software\PcxSnapshot'
            Name  = 'Blob'
            Type  = 'binary'
            Value = [byte[]](9, 8, 7)
        }

        $key = Get-PcxSnapshotRegistryKey -Path $target.Path -Name $target.Name
        $null = New-PcxSnapshotState -Path $script:registryStatePath -Registry @{
            $key = @{
                path = $target.Path
                name = $target.Name
                type = 'binary'
                data = [System.Convert]::ToBase64String($originalBytes)
            }
        }

        $pre = & $script:GetTargetState -Target $target
        $pre['data'] | Should -BeExactly ([System.Convert]::ToBase64String($originalBytes))

        $snapshot = & $script:NewSnapshot -Target $target
        $null = & $script:PlatformWrite -Target $target
        $null = & $script:RestoreSnapshot -Snapshot $snapshot

        $after = & $script:GetTargetState -Target $target
        $after['type'] | Should -BeExactly 'binary'
        $after['data'] | Should -BeExactly ([System.Convert]::ToBase64String($originalBytes))
    }

    It 'survives a canonical JSON document round-trip and still restores' {
        $snapshot = & $script:NewSnapshot -Target $script:registryTarget

        $documentPath = New-PcxSnapshotStatePath -Name ('snap-doc-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = & $script:WriteJsonAtomic -Path $documentPath -InputObject $snapshot
        $loaded = & $script:ReadJson -Path $documentPath

        $null = & $script:PlatformWrite -Target $script:registryTarget
        $null = & $script:RestoreSnapshot -Snapshot $loaded

        (& $script:GetTargetState -Target $script:registryTarget)['exists'] | Should -BeFalse
    }

    It 'reports equality and the first differing field' {
        $recorded = [ordered]@{ kind = 'registry'; path = 'HKCU:\X'; name = 'Y'; exists = $true; type = 'dword'; data = 1 }
        $same = [ordered]@{ kind = 'registry'; path = 'HKCU:\X'; name = 'Y'; exists = $true; type = 'dword'; data = 1 }
        $different = [ordered]@{ kind = 'registry'; path = 'HKCU:\X'; name = 'Y'; exists = $true; type = 'dword'; data = 2 }

        (& $script:CompareState -Recorded $recorded -Current $same)['status'] | Should -BeExactly 'equal'

        $drift = & $script:CompareState -Recorded $recorded -Current $different
        $drift['status'] | Should -BeExactly 'drift'
        $drift['field'] | Should -BeExactly 'data'
        $drift['recorded'] | Should -Be 1
        $drift['current'] | Should -Be 2
    }
}

Describe 'pcx snapshot service' {

    BeforeEach {
        $script:serviceStatePath = New-PcxSnapshotStatePath -Name ('snap-service-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxSnapshotState -Path $script:serviceStatePath -Services @{
            'pcxtestspooler' = @{ name = 'PcxTestSpooler'; controlSet = 'ControlSet002'; start = 2 }
        }
        $script:serviceTarget = @{ Kind = 'service'; Name = 'PcxTestSpooler'; Start = 4 }
    }

    It 'captures exactly Start and the control set, and nothing else' {
        $snapshot = & $script:NewSnapshot -Target $script:serviceTarget

        @($snapshot['target'].Keys) | Should -Be @('kind', 'name')
        @($snapshot['pre'].Keys) | Should -Be @('kind', 'name', 'controlSet', 'exists', 'start')
        @($snapshot['post'].Keys) | Should -Be @('kind', 'name', 'controlSet', 'exists', 'start')

        $snapshot['pre']['start'] | Should -Be 2
        $snapshot['pre']['controlSet'] | Should -BeExactly 'ControlSet002'
        $snapshot['post']['start'] | Should -Be 4
        $snapshot['post']['controlSet'] | Should -BeExactly 'ControlSet002'

        foreach ($forbidden in @('path', 'state', 'status', 'processId', 'dependencies')) {
            @($snapshot['pre'].Keys) | Should -Not -Contain $forbidden
            @($snapshot['post'].Keys) | Should -Not -Contain $forbidden
        }
    }

    It 'restores Start while keeping the control set' {
        $snapshot = & $script:NewSnapshot -Target $script:serviceTarget
        $null = & $script:PlatformWrite -Target $script:serviceTarget
        (& $script:GetTargetState -Target $script:serviceTarget)['start'] | Should -Be 4

        $result = & $script:RestoreSnapshot -Snapshot $snapshot

        $result['status'] | Should -BeExactly 'restored'
        $after = & $script:GetTargetState -Target $script:serviceTarget
        $after['start'] | Should -Be 2
        $after['controlSet'] | Should -BeExactly 'ControlSet002'
    }

    It 'refuses across a control-set change with PCX-E-SNAPSHOT-CONTROLSET' {
        $snapshot = & $script:NewSnapshot -Target $script:serviceTarget
        $null = & $script:PlatformWrite -Target $script:serviceTarget

        $document = Read-PcxSnapshotStateDocument -Path $script:serviceStatePath
        $document.services.pcxtestspooler.controlSet = 'ControlSet001'
        Save-PcxSnapshotStateDocument -Path $script:serviceStatePath -Document $document

        (& $script:GetTargetState -Target $script:serviceTarget)['controlSet'] | Should -BeExactly 'ControlSet001'

        { & $script:RestoreSnapshot -Snapshot $snapshot } |
            Should -Throw -ExpectedMessage '*PCX-E-SNAPSHOT-CONTROLSET*'

        (& $script:GetTargetState -Target $script:serviceTarget)['start'] | Should -Be 4
    }
}

Describe 'pcx snapshot task' {

    BeforeEach {
        $script:taskStatePath = New-PcxSnapshotStatePath -Name ('snap-task-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxSnapshotState -Path $script:taskStatePath -Tasks @{
            '\pcxtest\roundtrip' = @{ path = '\PcxTest\RoundTrip'; enabled = $true; state = 'Ready' }
        }
        $script:taskTarget = @{ Kind = 'task'; Path = '\PcxTest\RoundTrip'; Enabled = $false }
    }

    It 'captures only path and enabled' {
        $snapshot = & $script:NewSnapshot -Target $script:taskTarget

        @($snapshot['target'].Keys) | Should -Be @('kind', 'path')
        @($snapshot['pre'].Keys) | Should -Be @('kind', 'path', 'exists', 'enabled')
        @($snapshot['post'].Keys) | Should -Be @('kind', 'path', 'exists', 'enabled')
        $snapshot['pre']['enabled'] | Should -BeTrue
        $snapshot['post']['enabled'] | Should -BeFalse
    }

    It 'restores enabled without changing the task identity' {
        $snapshot = & $script:NewSnapshot -Target $script:taskTarget
        $beforeDocument = Read-PcxSnapshotStateDocument -Path $script:taskStatePath
        $beforePath = [string]$beforeDocument.tasks.'\pcxtest\roundtrip'.path

        $null = & $script:PlatformWrite -Target $script:taskTarget
        (& $script:GetTargetState -Target $script:taskTarget)['enabled'] | Should -BeFalse

        $result = & $script:RestoreSnapshot -Snapshot $snapshot
        $result['status'] | Should -BeExactly 'restored'

        $after = & $script:GetTargetState -Target $script:taskTarget
        $after['enabled'] | Should -BeTrue
        $after['path'] | Should -BeExactly $beforePath

        $afterDocument = Read-PcxSnapshotStateDocument -Path $script:taskStatePath
        $keys = @($afterDocument.tasks.PSObject.Properties | ForEach-Object { $_.Name })
        $keys.Count | Should -Be 1
        [string]$afterDocument.tasks.'\pcxtest\roundtrip'.path | Should -BeExactly $beforePath
    }

    It 'never references a TaskCache write or a delete-and-create path' {
        $source = [System.IO.File]::ReadAllText($script:snapshotSourcePath)

        foreach ($token in @('TaskCache', 'Unregister-ScheduledTask', 'Register-ScheduledTask', 'New-ScheduledTask')) {
            $source | Should -Not -Match ([regex]::Escape($token)) -Because "PcxSnapshot.ps1 must not use '$token'"
        }
    }
}

Describe 'pcx snapshot file' {

    BeforeEach {
        $script:fileStatePath = New-PcxSnapshotStatePath -Name ('snap-file-' + [guid]::NewGuid().ToString('n') + '.json')
        $script:filePath = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'move\pcx-target.bin'))
        $script:fileMovePath = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'move\pcx-target.moved.bin'))
        $script:fileOtherPath = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'move\pcx-other.bin'))
        $script:fileBytes = [System.Text.Encoding]::UTF8.GetBytes('pcx-file-bytes')
        $script:otherBytes = [System.Text.Encoding]::UTF8.GetBytes('pcx-other-bytes')

        $null = New-PcxSnapshotState -Path $script:fileStatePath -Files @{
            ($script:filePath.ToLowerInvariant()) = @{
                path           = $script:filePath
                contentBase64  = [System.Convert]::ToBase64String($script:fileBytes)
                attributes     = 'Archive'
                isReparsePoint = $false
            }
            ($script:fileOtherPath.ToLowerInvariant()) = @{
                path           = $script:fileOtherPath
                contentBase64  = [System.Convert]::ToBase64String($script:otherBytes)
                attributes     = 'Archive'
                isReparsePoint = $false
            }
        }
    }

    It 'captures size, SHA-256 and attributes only' {
        $state = & $script:GetTargetState -Target @{ Kind = 'file'; Path = $script:filePath }

        @($state.Keys) | Should -Be @('kind', 'path', 'exists', 'sha256', 'size', 'attributes')
        $state['exists'] | Should -BeTrue
        $state['sha256'] | Should -BeExactly (Get-PcxSha256 -Bytes $script:fileBytes)
        $state['size'] | Should -Be $script:fileBytes.Length
        $state['attributes'] | Should -BeExactly 'Archive'
    }

    It 'restores byte-identically from a recorded move source' {
        $target = @{ Kind = 'file'; Path = $script:filePath }

        $pre = & $script:GetTargetState -Target $target
        $null = & $script:PlatformMove -Target @{ Kind = 'file'; Path = $script:filePath; Destination = $script:fileMovePath }
        $post = & $script:GetTargetState -Target $target
        $post['exists'] | Should -BeFalse

        $snapshot = & $script:NewSnapshot -Target @{ Kind = 'file'; Path = $script:filePath; RestorePath = $script:fileMovePath } -PreState $pre -PostState $post
        $result = & $script:RestoreSnapshot -Snapshot $snapshot
        $result['status'] | Should -BeExactly 'restored'

        $after = & $script:GetTargetState -Target $target
        $after['exists'] | Should -BeTrue
        $after['sha256'] | Should -BeExactly $pre['sha256']
        $after['sha256'] | Should -BeExactly (Get-PcxSha256 -Bytes $script:fileBytes)
        (& $script:GetTargetState -Target @{ Kind = 'file'; Path = $script:fileMovePath })['exists'] | Should -BeFalse
    }

    It 'treats drift as terminal and restores nothing' {
        $target = @{ Kind = 'file'; Path = $script:filePath }

        $pre = & $script:GetTargetState -Target $target
        $null = & $script:PlatformMove -Target @{ Kind = 'file'; Path = $script:filePath; Destination = $script:fileMovePath }
        $post = & $script:GetTargetState -Target $target

        $snapshot = & $script:NewSnapshot -Target @{ Kind = 'file'; Path = $script:filePath; RestorePath = $script:fileMovePath } -PreState $pre -PostState $post

        $null = & $script:PlatformMove -Target @{ Kind = 'file'; Path = $script:fileOtherPath; Destination = $script:filePath }
        $mutated = & $script:GetTargetState -Target $target
        $mutated['exists'] | Should -BeTrue
        $mutated['sha256'] | Should -Not -BeExactly $pre['sha256']

        { & $script:RestoreSnapshot -Snapshot $snapshot } |
            Should -Throw -ExpectedMessage '*PCX-E-SNAPSHOT-DRIFT*'

        (& $script:GetTargetState -Target $target)['sha256'] | Should -BeExactly $mutated['sha256']
        (& $script:GetTargetState -Target @{ Kind = 'file'; Path = $script:fileMovePath })['exists'] | Should -BeTrue
    }
}

Describe 'pcx snapshot safety surface' {

    BeforeAll {
        $script:snapshotSource = [System.IO.File]::ReadAllText($script:snapshotSourcePath)
    }

    It 'never calls a native OS cmdlet or evaluates an expression' {
        $banned = @(
            'Set-ItemProperty'
            'New-ItemProperty'
            'Remove-ItemProperty'
            'Set-Service'
            'Enable-ScheduledTask'
            'Disable-ScheduledTask'
            'Remove-Item'
            'Get-Item'
            'Get-ItemProperty'
            'Get-ScheduledTask'
            'Get-Service'
            'New-Item'
            'Invoke-Expression'
            'reg.exe'
            'sc.exe'
            'schtasks.exe'
            'cmd /c'
        )

        foreach ($token in $banned) {
            $script:snapshotSource | Should -Not -Match ([regex]::Escape($token)) -Because "PcxSnapshot.ps1 must not use '$token'"
        }
    }

    It 'routes every operation through the platform boundary' {
        foreach ($token in @('Invoke-PcxPlatformRead', 'Invoke-PcxPlatformWrite', 'Invoke-PcxPlatformDelete', 'Invoke-PcxPlatformMove')) {
            $script:snapshotSource | Should -Match ([regex]::Escape($token))
        }
    }

    It 'carries no hive save or restore call and never hashes a file' {
        $hiveSave = 'Reg' + 'SaveKey'
        $hiveRestore = 'Reg' + 'RestoreKey'

        $script:snapshotSource | Should -Not -Match ([regex]::Escape($hiveSave))
        $script:snapshotSource | Should -Not -Match ([regex]::Escape($hiveRestore))
        $script:snapshotSource | Should -Not -Match ([regex]::Escape('Get-PcxSha256'))
    }

    It 'produces a snapshot document with no hive-like payload' {
        $statePath = New-PcxSnapshotStatePath -Name ('snap-hive-' + [guid]::NewGuid().ToString('n') + '.json')
        $null = New-PcxSnapshotState -Path $statePath

        $snapshot = & $script:NewSnapshot -Target @{
            Kind  = 'registry'
            Path  = 'HKCU:\Software\PcxSnapshot'
            Name  = 'Tiny'
            Type  = 'dword'
            Value = 1
        }

        $text = & $script:CanonicalJson -InputObject $snapshot

        $text.Contains([char]0) | Should -BeFalse
        $text | Should -Not -Match ([regex]::Escape('Windows Registry Editor Version'))
        $text.Length | Should -BeLessThan 4096
    }

    It 'exports exactly the four snapshot functions' {
        $exported = @(
            $script:Module.ExportedCommands.Keys |
                Where-Object { $_ -like '*Pcx*Snapshot*' -or $_ -eq 'Get-PcxTargetState' -or $_ -eq 'Compare-PcxState' } |
                Sort-Object
        )

        $expected = @('Compare-PcxState', 'Get-PcxTargetState', 'New-PcxSnapshot', 'Restore-PcxSnapshot') | Sort-Object
        $exported | Should -Be $expected
    }
}

AfterAll {
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
}
