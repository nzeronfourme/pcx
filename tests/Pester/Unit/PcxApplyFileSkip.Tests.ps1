<#
.SYNOPSIS
    Locked-file skip at the apply layer (file-delete scope only).

.DESCRIPTION
    Fixture-only: a thumbnails plan (one item, four concrete file targets)
    is built from the desktop fixture scan through -Selection and applied in
    agent mode against the test platform adapter.

    Covered here:
      * one locked file plus three free files: the free files are deleted,
        the locked file is listed with its OS reason, and the item reports
        partial counts (COMMITTED with a per-file skipped list);
      * every file locked: the item refuses with the existing typed code,
        zero deletions, no partial success claim;
      * nothing locked: behavior is unchanged (COMMITTED, empty skipped).

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
    $script:Apply = $script:Module.ExportedCommands['Invoke-PcxApply']
    $script:ScanCommand = $script:Module.ExportedCommands['Get-PcxScan']

    $script:DesktopFixture = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment/desktop'
    $script:Scan = & $script:ScanCommand -FixturePath $script:DesktopFixture

    $script:ThumbNames = @('thumbcache_32.db', 'thumbcache_96.db', 'thumbcache_256.db', 'thumbcache_1024.db')

    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:OriginalStateFile = $env:PCX_TEST_STATE_FILE
    $script:FixtureCounter = 0

    function New-PcxFileSkipRecord {
        param(
            [Parameter(Mandatory = $true)][string] $Path,
            [Parameter(Mandatory = $false)][bool] $Locked = $false
        )

        return [ordered]@{
            path           = $Path
            attributes     = 'Archive'
            isReparsePoint = $false
            locked         = $Locked
            contentBase64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('thumb-bytes'))
            sizeBytes      = 200MB
        }
    }

    function New-PcxFileSkipFixture {
        param(
            [Parameter(Mandatory = $false)][string[]] $LockedNames = @(),
            [Parameter(Mandatory = $false)][string[]] $UnreadableNames = @()
        )

        $script:FixtureCounter = [int]$script:FixtureCounter + 1
        $root = Join-Path -Path $TestDrive -ChildPath ('fileskip-' + $script:FixtureCounter + '-' + [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($root)

        $env:LOCALAPPDATA = $root
        $stateFile = Join-Path -Path $root -ChildPath 'state.json'
        $env:PCX_TEST_STATE_FILE = $stateFile

        $files = @{}
        foreach ($name in $script:ThumbNames) {
            $path = [System.IO.Path]::Combine($root, 'Microsoft\Windows\Explorer', $name)
            $record = New-PcxFileSkipRecord -Path $path -Locked ($LockedNames -contains $name)
            if ($UnreadableNames -contains $name) {
                $record['unreadable'] = $true
            }
            $files[$path.ToLowerInvariant()] = $record
        }

        $state = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = @{}
            services = @{}
            tasks    = @{}
            files    = $files
        }
        [System.IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject $state -Depth 8), (New-Object System.Text.UTF8Encoding -ArgumentList $false))

        $profile = [ordered]@{
            managed      = $false
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            build        = 26100
            environment  = [ordered]@{ LOCALAPPDATA = $root; APPDATA = (Join-Path $root 'Roaming'); PROGRAMDATA = 'C:\ProgramData'; SYSTEMROOT = 'C:\Windows' }
            serviceFacts = [ordered]@{}
        }

        $paths = @{}
        foreach ($name in $script:ThumbNames) {
            $paths[$name] = [System.IO.Path]::Combine($root, 'Microsoft\Windows\Explorer', $name)
        }

        return [pscustomobject]@{ Root = $root; StateFile = $stateFile; Profile = $profile; Paths = $paths }
    }

    function Test-PcxFileSkipExists {
        param([Parameter(Mandatory = $true)][object] $Fixture, [Parameter(Mandatory = $true)][string] $Path)

        $text = [System.IO.File]::ReadAllText($Fixture.StateFile, [System.Text.Encoding]::UTF8)
        $document = ConvertFrom-Json -InputObject $text
        return ($null -ne $document.files.PSObject.Properties[$Path.ToLowerInvariant()])
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    $env:PCX_TEST_STATE_FILE = $script:OriginalStateFile
}

Describe 'apply skips locked files per file' {

    It 'deletes the free files, skips the locked one, and reports partial counts' {
        $fixture = New-PcxFileSkipFixture -LockedNames @('thumbcache_32.db')

        $result = & $script:Apply -Selection '1' -Scan $script:Scan -Profile $fixture.Profile -Mode agent

        $result.ok | Should -BeTrue
        $result.status | Should -Be 'done'
        @($result.applied).Count | Should -Be 1
        @($result.itemResults).Count | Should -Be 1

        $item = $result.itemResults[0]
        $item.actionId | Should -Be 'thumbnails'
        $item.status | Should -Be 'COMMITTED'

        @($item.skipped).Count | Should -Be 1
        [string]$item.skipped[0].path | Should -Be $fixture.Paths['thumbcache_32.db']
        [string]$item.skipped[0].code | Should -Be 'PCX-E-PLATFORM-LOCKED'
        [string]$item.skipped[0].reason | Should -Not -BeNullOrEmpty

        @($item.targets).Count | Should -Be 4
        $item.targets[0].ok | Should -BeFalse
        @($item.targets[0].skipped).Count | Should -Be 1

        [string]$item.line | Should -Match 'skipped 1'
        [string]$item.reason | Should -Match 'skipped 1'

        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_32.db']) | Should -BeTrue
        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_96.db']) | Should -BeFalse
        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_256.db']) | Should -BeFalse
        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_1024.db']) | Should -BeFalse
    }

    It 'refuses when every file is locked and deletes nothing' {
        $fixture = New-PcxFileSkipFixture -LockedNames @('thumbcache_32.db', 'thumbcache_96.db', 'thumbcache_256.db', 'thumbcache_1024.db')

        $result = & $script:Apply -Selection '1' -Scan $script:Scan -Profile $fixture.Profile -Mode agent

        @($result.applied).Count | Should -Be 0
        @($result.itemResults).Count | Should -Be 1

        $item = $result.itemResults[0]
        $item.actionId | Should -Be 'thumbnails'
        $item.status | Should -Be 'FAILED'
        $item.status | Should -Not -Be 'COMMITTED'
        [string]$item.code | Should -Be 'PCX-E-PLATFORM-LOCKED'
        @($item.skipped).Count | Should -Be 4
        [string]$item.reason | Should -Match 'no file could be deleted'
        [string]$item.line | Should -Match 'PCX-E-PLATFORM-LOCKED'

        foreach ($name in $script:ThumbNames) {
            (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths[$name]) | Should -BeTrue
        }
    }

    It 'skips a file the pre-state cannot fingerprint and reports it' {
        $fixture = New-PcxFileSkipFixture -UnreadableNames @('thumbcache_32.db')

        $result = & $script:Apply -Selection '1' -Scan $script:Scan -Profile $fixture.Profile -Mode agent

        $result.ok | Should -BeTrue
        $result.status | Should -Be 'done'
        @($result.applied).Count | Should -Be 1
        @($result.itemResults).Count | Should -Be 1

        $item = $result.itemResults[0]
        $item.actionId | Should -Be 'thumbnails'
        $item.status | Should -Be 'COMMITTED'

        @($item.skipped).Count | Should -Be 1
        [string]$item.skipped[0].path | Should -Be $fixture.Paths['thumbcache_32.db']
        [string]$item.skipped[0].code | Should -Be 'PCX-E-PLATFORM-UNREADABLE'
        [string]$item.skipped[0].reason | Should -Match 'being used'

        [string]$item.line | Should -Match 'skipped 1'
        [string]$item.reason | Should -Match 'skipped 1'

        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_32.db']) | Should -BeTrue
        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_96.db']) | Should -BeFalse
        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_256.db']) | Should -BeFalse
        (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths['thumbcache_1024.db']) | Should -BeFalse
    }

    It 'leaves behavior unchanged when nothing is locked' {
        $fixture = New-PcxFileSkipFixture

        $result = & $script:Apply -Selection '1' -Scan $script:Scan -Profile $fixture.Profile -Mode agent

        $result.ok | Should -BeTrue
        @($result.applied).Count | Should -Be 1

        $item = $result.itemResults[0]
        $item.actionId | Should -Be 'thumbnails'
        $item.status | Should -Be 'COMMITTED'
        @($item.skipped).Count | Should -Be 0
        [string]$item.line | Should -Not -Match 'skipped'

        foreach ($name in $script:ThumbNames) {
            (Test-PcxFileSkipExists -Fixture $fixture -Path $fixture.Paths[$name]) | Should -BeFalse
        }
    }
}
