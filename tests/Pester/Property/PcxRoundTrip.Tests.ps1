<#
.SYNOPSIS
    Property-style target round-trips (todo 15).

.DESCRIPTION
    For every target kind the suite generates a set of valid targets and a set
    of invalid ones.

    Every accepted target must survive snapshot -> apply -> verify -> undo with
    canonical SHA-256 equality (registry, service, task) or byte SHA-256
    equality (file quarantine). Every rejected target must produce a typed
    PCX-POLICY-* code: a policy refusal or a grammar error, never a silent pass.

    A1 file targets are allowed by policy but are explicitly not restorable, so
    they are asserted as manifest-only instead of being round-tripped.

    Fixture adapter only; no test touches the live OS.
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
    $script:GetTargetState = $script:Module.ExportedCommands['Get-PcxTargetState']
    $script:NewSnapshot = $script:Module.ExportedCommands['New-PcxSnapshot']
    $script:CompareState = $script:Module.ExportedCommands['Compare-PcxState']
    $script:RestoreSnapshot = $script:Module.ExportedCommands['Restore-PcxSnapshot']
    $script:PlatformWrite = $script:Module.ExportedCommands['Invoke-PcxPlatformWrite']
    $script:PlatformMove = $script:Module.ExportedCommands['Invoke-PcxPlatformMove']
    $script:TestTarget = $script:Module.ExportedCommands['Test-PcxTarget']
    $script:CanonicalJson = $script:Module.ExportedCommands['ConvertTo-PcxCanonicalJson']
    $script:Sha256 = $script:Module.ExportedCommands['Get-PcxSha256']
    $script:GetCatalog = $script:Module.ExportedCommands['Get-PcxCatalog']

    $script:LocalAppData = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'env/Local'))
    $script:AppData = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'env/Roaming'))
    $script:ProgramData = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'env/ProgramData'))
    $script:StartupRoot = Join-Path -Path $script:AppData -ChildPath 'Microsoft\Windows\Start Menu\Programs\Startup'
    $script:ExplorerRoot = Join-Path -Path $script:LocalAppData -ChildPath 'Microsoft\Windows\Explorer'

    $script:Profile = [ordered]@{
        managed      = $false
        sMode        = $false
        devDrive     = $false
        anticheat    = $false
        build        = 26100
        environment  = [ordered]@{
            LOCALAPPDATA = $script:LocalAppData
            APPDATA      = $script:AppData
            PROGRAMDATA  = $script:ProgramData
            SYSTEMROOT   = 'C:\Windows'
        }
        serviceFacts = [ordered]@{
            PcxPropSvcA = [ordered]@{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
            PcxPropSvcB = [ordered]@{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
        }
    }

    $script:AdvancedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $script:CdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $script:HagsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'

    function Get-PcxRoundTripRegistryKey {
        param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Name)

        return ($Path.ToLowerInvariant() + [char]0x1F + $Name.ToLowerInvariant())
    }

    function New-PcxRoundTripState {
        # Writes one fresh adapter state file and points the adapter at it.
        param(
            [Parameter(Mandatory = $true)][string] $Name,
            [hashtable] $Registry = @{},
            [hashtable] $Services = @{},
            [hashtable] $Tasks = @{},
            [hashtable] $Files = @{}
        )

        $path = Join-Path -Path $TestDrive -ChildPath ('roundtrip-' + $Name + '-' + [guid]::NewGuid().ToString('N') + '.json')
        $document = [ordered]@{
            schema   = 'pcx-platform-test/1'
            registry = $Registry
            services = $Services
            tasks    = $Tasks
            files    = $Files
        }

        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $document -Depth 8 -Compress), $utf8)
        $env:PCX_TEST_STATE_FILE = $path
        return $path
    }

    function Get-PcxRoundTripHash {
        param([Parameter(Mandatory = $true)][object] $State)

        return (& $script:Sha256 -Text (& $script:CanonicalJson -InputObject $State))
    }

    function Get-PcxRoundTripCaseLabel {
        param([Parameter(Mandatory = $true)][object] $Case)

        $parts = @([string]$Case['Kind'])
        foreach ($key in @('Name', 'Path')) {
            if ($Case.ContainsKey($key) -and -not [string]::IsNullOrEmpty([string]$Case[$key])) {
                $parts += [string]$Case[$key]
            }
        }

        return ($parts -join ' ')
    }

    function New-PcxRoundTripTarget {
        param([Parameter(Mandatory = $true)][object] $Case)

        $target = [ordered]@{ Kind = [string]$Case.Kind }
        if ($Case.Kind -eq 'registry') {
            $target['Path'] = [string]$Case.Path
            $target['Name'] = [string]$Case.Name
            $target['Type'] = [string]$Case.Type
            $target['Value'] = $Case.Value
        }
        elseif ($Case.Kind -eq 'service') {
            $target['Name'] = [string]$Case.Name
            $target['Start'] = [int]$Case.Start
        }
        elseif ($Case.Kind -eq 'task') {
            $target['Path'] = [string]$Case.Path
            $target['Enabled'] = [bool]$Case.Enabled
        }
        else {
            $target['Path'] = [string]$Case.Path
            $target['Role'] = 'quarantine'
        }

        return $target
    }

    function New-PcxRoundTripSeed {
        # Seeds the adapter state so the target has a realistic pre-state.
        param([Parameter(Mandatory = $true)][object] $Case)

        $buckets = @{ Registry = @{}; Services = @{}; Tasks = @{}; Files = @{} }

        switch ([string]$Case.Kind) {
            'registry' {
                if ($null -ne $Case.Pre) {
                    $buckets.Registry[(Get-PcxRoundTripRegistryKey -Path ([string]$Case.Path) -Name ([string]$Case.Name))] = [ordered]@{
                        path = [string]$Case.Path
                        name = [string]$Case.Name
                        type = [string]$Case.Type
                        data = $Case.Pre
                    }
                }
            }
            'service' {
                $buckets.Services[([string]$Case.Name).ToLowerInvariant()] = [ordered]@{
                    name       = [string]$Case.Name
                    controlSet = 'ControlSet001'
                    start      = [int]$Case.Pre
                }
            }
            'task' {
                $buckets.Tasks[([string]$Case.Path).ToLowerInvariant()] = [ordered]@{
                    path    = [string]$Case.Path
                    enabled = $true
                    state   = 'Ready'
                }
            }
            'file' {
                $buckets.Files[([string]$Case.Path).ToLowerInvariant()] = [ordered]@{
                    path           = [string]$Case.Path
                    contentBase64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Case.Content))
                    attributes     = 'Archive'
                    isReparsePoint = $false
                }
            }
        }

        return $buckets
    }

    function Invoke-PcxRoundTripCase {
        # snapshot -> apply -> verify -> undo, then canonical/byte equality.
        param([Parameter(Mandatory = $true)][object] $Case)

        $name = ([string]$Case.Kind) + '-' + [guid]::NewGuid().ToString('N')
        $buckets = New-PcxRoundTripSeed -Case $Case
        $null = New-PcxRoundTripState -Name $name -Registry $buckets.Registry -Services $buckets.Services -Tasks $buckets.Tasks -Files $buckets.Files

        $target = New-PcxRoundTripTarget -Case $Case
        $decision = & $script:TestTarget -Target $target -Profile $script:Profile
        $decision.allowed | Should -BeTrue -Because "generated target '$name' must be accepted before the round-trip"

        $pre = & $script:GetTargetState -Target $target
        $preHash = Get-PcxRoundTripHash -State $pre

        if ([string]$Case.Kind -eq 'file') {
            $destination = Join-Path -Path $TestDrive -ChildPath ('quarantine/' + [guid]::NewGuid().ToString('N') + '.bin')
            $null = & $script:PlatformMove -Target @{ Kind = 'file'; Path = [string]$Case.Path; Destination = $destination }
            $post = & $script:GetTargetState -Target $target
            $snapshot = & $script:NewSnapshot -Target @{ Kind = 'file'; Path = [string]$Case.Path; RestorePath = $destination } -PreState $pre -PostState $post
        }
        else {
            $snapshot = & $script:NewSnapshot -Target $target
            $null = & $script:PlatformWrite -Target $target
        }

        $current = & $script:GetTargetState -Target $target
        (& $script:CompareState -Recorded $snapshot['post'] -Current $current)['status'] | Should -BeExactly 'equal' -Because 'apply must reach the expected post-state'

        $restore = & $script:RestoreSnapshot -Snapshot $snapshot
        $restore['status'] | Should -BeExactly 'restored'

        $after = & $script:GetTargetState -Target $target
        (& $script:CompareState -Recorded $snapshot['pre'] -Current $after)['status'] | Should -BeExactly 'equal' -Because 'undo must restore the recorded pre-state'
        (Get-PcxRoundTripHash -State $after) | Should -BeExactly $preHash -Because 'canonical SHA-256 equality is the undo proof'

        if ([string]$Case.Kind -eq 'file') {
            $after['exists'] | Should -BeTrue
            $after['sha256'] | Should -BeExactly $pre['sha256']
        }
    }

    $script:AcceptedCases = @(
        @{ Kind = 'registry'; Path = $script:AdvancedPath; Name = 'PcxPropAbsent'; Type = 'dword'; Value = 1; Pre = $null }
        @{ Kind = 'registry'; Path = $script:AdvancedPath; Name = 'PcxPropDword'; Type = 'dword'; Value = 5; Pre = 2 }
        @{ Kind = 'registry'; Path = $script:CdmPath; Name = 'PcxPropString'; Type = 'string'; Value = 'new'; Pre = 'old' }
        @{ Kind = 'registry'; Path = $script:HagsPath; Name = 'HwSchMode'; Type = 'dword'; Value = 2; Pre = 1 }
        @{ Kind = 'service'; Name = 'PcxPropSvcA'; Start = 3; Pre = 2 }
        @{ Kind = 'service'; Name = 'PcxPropSvcB'; Start = 4; Pre = 3 }
        @{ Kind = 'task'; Path = '\PcxProp\Alpha'; Enabled = $false; Pre = $true }
        @{ Kind = 'task'; Path = '\PcxProp\Beta'; Enabled = $false; Pre = $true }
        @{ Kind = 'file'; Path = (Join-Path $script:StartupRoot 'PropOne.lnk'); Content = 'prop-one-bytes' }
        @{ Kind = 'file'; Path = (Join-Path $script:StartupRoot 'PropTwo.lnk'); Content = 'prop-two-bytes' }
    )

    $script:RejectedCases = @(
        @{ Kind = 'registry'; Path = 'HKCU:\Environment'; Name = 'Path'; Start = $null; Expected = 'PCX-POLICY-HKCU-DEFAULT-DENY' }
        @{ Kind = 'registry'; Path = 'HKCU:\Software\Classes\PcxProp'; Name = 'Val'; Expected = 'PCX-POLICY-HKCU-DEFAULT-DENY' }
        @{ Kind = 'registry'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Name = 'PcxProp'; Expected = 'PCX-POLICY-HKLM-VALUE' }
        @{ Kind = 'registry'; Path = $script:AdvancedPath; Name = ''; Expected = 'PCX-POLICY-REGISTRY-VALUE' }
        @{ Kind = 'registry'; Path = 'HKCU:\Software\..\Windows'; Name = 'Val'; Expected = 'PCX-POLICY-GRAMMAR' }
        @{ Kind = 'registry'; Path = $script:AdvancedPath; Name = 'Pcx*'; Expected = 'PCX-POLICY-GRAMMAR' }
        @{ Kind = 'service'; Name = 'WinDefend'; Start = 4; Expected = 'PCX-POLICY-SECURITY' }
        @{ Kind = 'service'; Name = 'tcpip'; Start = 4; Expected = 'PCX-POLICY-DRIVER' }
        @{ Kind = 'service'; Name = 'PcxPropSvcA'; Start = 2; Expected = 'PCX-POLICY-SERVICE-START' }
        @{ Kind = 'service'; Name = 'PcxPropUnknownSvc'; Start = 4; Expected = 'PCX-POLICY-BLAST-RADIUS' }
        @{ Kind = 'task'; Path = '\Microsoft\Windows\Defrag\ScheduledDefrag'; Enabled = $false; Expected = 'PCX-POLICY-TASK-SYSTEM' }
        @{ Kind = 'task'; Path = '\PcxProp\Alpha'; Enabled = $true; Expected = 'PCX-POLICY-TASK-ENABLE' }
        @{ Kind = 'task'; Path = 'PcxProp\NoLeadingSlash'; Enabled = $false; Expected = 'PCX-POLICY-GRAMMAR' }
        @{ Kind = 'task'; Path = '\PcxProp\Pcx*'; Enabled = $false; Expected = 'PCX-POLICY-GRAMMAR' }
        @{ Kind = 'file'; Path = (Join-Path $script:LocalAppData 'Documents\report.docx'); Role = 'a1'; Expected = 'PCX-POLICY-FILE-ROOT' }
        @{ Kind = 'file'; Path = (Join-Path $script:AppData 'Desktop\shortcut.lnk'); Role = 'quarantine'; Expected = 'PCX-POLICY-QUARANTINE-ROOT' }
        @{ Kind = 'file'; Path = (Join-Path $script:StartupRoot '..\Other\x.lnk'); Role = 'quarantine'; Expected = 'PCX-POLICY-GRAMMAR' }
        @{ Kind = 'file'; Path = (Join-Path $script:StartupRoot 'Prop*.lnk'); Role = 'a1'; Expected = 'PCX-POLICY-GRAMMAR' }
        @{ Kind = 'file'; Path = (Join-Path $script:StartupRoot 'PropOne.lnk'); Role = 'quarantine'; Reparse = $true; Expected = 'PCX-POLICY-REPARSE' }
        @{ Kind = 'file'; Path = (Join-Path $script:StartupRoot 'PropOne.lnk'); Role = 'delete'; Expected = 'PCX-POLICY-GRAMMAR' }
    )
}

Describe 'accepted targets round-trip' {

    It 'round-trips every generated <Kind> target' -TestCases @(@{ Kind = 'registry' }, @{ Kind = 'service' }, @{ Kind = 'task' }, @{ Kind = 'file' }) -Test {
        param($Kind)

        $cases = @($script:AcceptedCases | Where-Object { $_.Kind -eq $Kind })
        $cases.Count | Should -BeGreaterThan 0

        foreach ($case in $cases) {
            $label = Get-PcxRoundTripCaseLabel -Case $case
            try {
                Invoke-PcxRoundTripCase -Case $case
            }
            catch {
                throw "round-trip failed for '$label': $($_.Exception.Message)"
            }
        }
    }
}

Describe 'rejected targets carry a typed code' {

    It 'rejects every generated <Kind> target with a PCX-POLICY code' -TestCases @(@{ Kind = 'registry' }, @{ Kind = 'service' }, @{ Kind = 'task' }, @{ Kind = 'file' }) -Test {
        param($Kind)

        $cases = @($script:RejectedCases | Where-Object { $_.Kind -eq $Kind })
        $cases.Count | Should -BeGreaterThan 0

        foreach ($case in $cases) {
            $target = [ordered]@{ Kind = $case.Kind }
            switch ($case.Kind) {
                'registry' {
                    $target['Path'] = [string]$case.Path
                    $target['Name'] = [string]$case.Name
                }
                'service' {
                    $target['Name'] = [string]$case.Name
                    $target['Start'] = [int]$case.Start
                }
                'task' {
                    $target['Path'] = [string]$case.Path
                    $target['Enabled'] = [bool]$case.Enabled
                }
                'file' {
                    $target['Path'] = [string]$case.Path
                    $target['Role'] = [string]$case.Role
                    if ($case.ContainsKey('Reparse') -and $case.Reparse) { $target['Reparse'] = $true }
                }
            }

            $decision = & $script:TestTarget -Target $target -Profile $script:Profile

            $label = Get-PcxRoundTripCaseLabel -Case $case
            [bool]$decision.allowed | Should -BeFalse -Because "$label must be rejected"
            [string]$decision.code | Should -Match '^PCX-POLICY-' -Because "$label must carry a typed policy or grammar code"
            [string]$decision.code | Should -BeExactly ([string]$case.Expected) -Because "$label must fail for the documented reason"
        }
    }
}

Describe 'A1 is allowed but never claims to be restorable' {

    It 'allows an OS-regenerable cache delete and declares manifest-only inverse' {
        $target = [ordered]@{
            Kind = 'file'
            Path = (Join-Path $script:ExplorerRoot 'thumbcache_32.db')
            Role = 'a1'
        }

        (& $script:TestTarget -Target $target -Profile $script:Profile).allowed | Should -BeTrue

        $action = @((& $script:GetCatalog).actions | Where-Object { [string]$_.id -eq 'thumbnails' })
        $action.Count | Should -Be 1
        [string]$action[0].inverse | Should -BeExactly 'manifest-only'
    }
}

Describe 'generator coverage' {

    It 'covers all four kinds with both accepted and rejected cases' {
        foreach ($kind in @('registry', 'service', 'task', 'file')) {
            @($script:AcceptedCases | Where-Object { $_.Kind -eq $kind }).Count | Should -BeGreaterThan 0
            @($script:RejectedCases | Where-Object { $_.Kind -eq $kind }).Count | Should -BeGreaterThan 0
        }
    }
}
