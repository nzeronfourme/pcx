<#
.SYNOPSIS
    Default-deny policy suite for todo 5: the canonical target grammar, the
    HKCU default-deny surface, the value-level HKLM allow-list, protected
    targets (boot chain, TrustedInstaller, security, drivers, anticheat),
    service blast radius, task and file root rules, the whole-machine profile
    gates, and the proof that the engine reads no machine state.
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

    $pcxModule = Get-Module -Name 'Pcx'
    $script:Module = $pcxModule
    $script:TestTarget = $pcxModule.ExportedCommands['Test-PcxTarget']
    $script:ConvertTarget = $pcxModule.ExportedCommands['ConvertTo-PcxTarget']

    $script:policySourcePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxPolicy.ps1'
    $script:policyDataSourcePath = Join-Path -Path $repoRoot -ChildPath 'config/protected/protected-targets.json'

    function New-PcxPolicyProfile {
        param(
            [hashtable] $Overrides = @{},
            [hashtable] $ServiceFacts = @{}
        )

        $profile = [ordered]@{
            managed      = $false
            sMode        = $false
            devDrive     = $false
            anticheat    = $false
            serviceFacts = $ServiceFacts
            environment  = [ordered]@{
                LOCALAPPDATA = 'C:\Users\tester\AppData\Local'
                APPDATA      = 'C:\Users\tester\AppData\Roaming'
                PROGRAMDATA  = 'C:\ProgramData'
                SYSTEMROOT   = 'C:\Windows'
            }
        }

        foreach ($key in $Overrides.Keys) {
            $profile[$key] = $Overrides[$key]
        }

        return [pscustomobject]$profile
    }

    function Invoke-PcxPolicy {
        param(
            [Parameter(Mandatory = $true)][object] $Target,
            [Parameter(Mandatory = $false)][object] $Profile
        )

        if ($null -eq $Profile) {
            $Profile = New-PcxPolicyProfile
        }

        return (& $script:TestTarget -Target $Target -Profile $Profile)
    }
}

Describe 'pcx policy engine surface' {

    It 'exports exactly the parser and the gate' {
        $exported = @(
            $script:Module.ExportedCommands.Keys |
                Where-Object { $_ -eq 'Test-PcxTarget' -or $_ -eq 'ConvertTo-PcxTarget' } |
                Sort-Object
        )

        $exported | Should -Be @('ConvertTo-PcxTarget', 'Test-PcxTarget')
        $null -eq $script:Module.ExportedCommands['Test-PcxTarget'] | Should -BeFalse
        $null -eq $script:Module.ExportedCommands['ConvertTo-PcxTarget'] | Should -BeFalse
    }

    It 'returns a structured decision, not a bare boolean' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers::HwSchMode'

        $result.PSObject.Properties.Name | Should -Contain 'allowed'
        $result.PSObject.Properties.Name | Should -Contain 'code'
        $result.PSObject.Properties.Name | Should -Contain 'reason'
        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-POLICY-ALLOW'
    }

    It 'loads a schema-tagged protected data file with no wildcards in the path lists' {
        $raw = [System.IO.File]::ReadAllText($script:policyDataSourcePath)
        $document = ConvertFrom-Json -InputObject $raw -ErrorAction Stop

        $document.schema | Should -Be 'pcx-protected/1'
        $raw | Should -Not -Match '\*'
        $raw | Should -Not -Match '\?'

        @($document.files.a1_roots).Count | Should -BeGreaterThan 0
        @($document.files.a2_roots).Count | Should -BeGreaterThan 0
        @($document.registryAllow.hkcuSubkeys).Count | Should -Be 7
        @($document.registryAllow.hklmValues).Count | Should -Be 1
    }
}

Describe 'canonical target grammar' {

    It 'canonicalizes HKEY_CURRENT_USER to HKCU' {
        $target = & $script:ConvertTarget -Target 'HKEY_CURRENT_USER\Environment'
        $target.hive | Should -Be 'HKCU'
        $target.key | Should -Be 'environment'
    }

    It 'canonicalizes HKEY_LOCAL_MACHINE to HKLM' {
        $target = & $script:ConvertTarget -Target 'HKEY_LOCAL_MACHINE\SYSTEM\Foo'
        $target.hive | Should -Be 'HKLM'
        $target.key | Should -Be 'system\foo'
    }

    It 'normalizes separators and case, including a value name after ::' {
        $target = & $script:ConvertTarget -Target 'reg:HKCU/Software/Microsoft/Windows/CurrentVersion/Explorer/Advanced::HideFileExt'
        $target.path | Should -Be 'HKCU\software\microsoft\windows\currentversion\explorer\advanced'
        $target.name | Should -Be 'hidefileext'
    }

    It 'rejects HKCR' {
        { & $script:ConvertTarget -Target 'HKCR\Foo\Bar' } | Should -Throw '*PCX-POLICY-GRAMMAR*'
    }

    It 'rejects HKEY_CLASSES_ROOT' {
        { & $script:ConvertTarget -Target 'HKEY_CLASSES_ROOT\Foo' } | Should -Throw '*PCX-POLICY-GRAMMAR*'
    }

    It 'rejects Registry:: provider paths' {
        { & $script:ConvertTarget -Target 'Registry::HKEY_CURRENT_USER\Environment' } | Should -Throw '*PCX-POLICY-GRAMMAR*'
    }

    It 'rejects a registry target with a trailing separator' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Environment\'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }

    It 'rejects a task target with a trailing separator' {
        $result = Invoke-PcxPolicy -Target 'task:\Pcx\MyTask\'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }

    It 'normalizes a file trailing separator instead of refusing a directory' {
        $target = & $script:ConvertTarget -Target 'file:C:\Windows\SoftwareDistribution\Download\'
        $target.path | Should -Be 'c:\windows\softwaredistribution\download'
    }

    It 'rejects a .. segment' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Software\..\Environment'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }

    It 'rejects a .. segment in a file target' {
        $result = Invoke-PcxPolicy -Target 'file:C:\Windows\SoftwareDistribution\Download\..\..\System32\evil.dll'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }

    It 'rejects a wildcard in a registry target' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\Foo*'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }

    It 'rejects a wildcard in a file target' {
        $result = Invoke-PcxPolicy -Target 'file:C:\Windows\SoftwareDistribution\Download\*.cab'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }

    It 'rejects a target that declares itself a reparse point' {
        $result = Invoke-PcxPolicy -Target @{
            Kind    = 'file'
            Path    = 'C:\Windows\SoftwareDistribution\Download'
            Role    = 'a1'
            Reparse = $true
        }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-REPARSE'
    }

    It 'rejects an unknown target kind' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'process'; Name = 'x' }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }
}

Describe 'HKCU default-deny' {

    It 'refuses the whole HKCU\Software\Classes subtree' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Software\Classes\CLSID\{00000000-0000-0000-0000-000000000000}\InprocServer32::Value'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKCU-DEFAULT-DENY'
    }

    It 'refuses HKCU\Environment' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Environment::Path'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKCU-DEFAULT-DENY'
    }

    It 'refuses a case-folded RunOnce path' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Software\Microsoft\Windows\CurrentVersion\RUNONCE\Evil::Command'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKCU-DEFAULT-DENY'
    }

    It 'refuses HKCU\Software\Microsoft\Windows\CurrentVersion\Run' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run::Agent'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKCU-DEFAULT-DENY'
    }

    It 'refuses HKCU\Software\Policies' {
        $result = Invoke-PcxPolicy -Target 'HKCU\Software\Policies\Microsoft\Windows\Explorer::NoDriveTypeAutoRun'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKCU-DEFAULT-DENY'
    }

    It 'allows a value inside an enumerated HKCU subtree' {
        $result = Invoke-PcxPolicy -Target 'reg:HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced::HideFileExt'
        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-POLICY-ALLOW'
    }

    It 'allows a value inside System\GameConfigStore' {
        $result = Invoke-PcxPolicy -Target 'reg:HKCU\System\GameConfigStore::GameDVR_Enabled'
        $result.allowed | Should -BeTrue
    }

    It 'refuses a key-level target inside an allowed subtree (value-level only)' {
        $result = Invoke-PcxPolicy -Target 'reg:HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-REGISTRY-VALUE'
    }
}

Describe 'HKLM value-level only' {

    It 'allows the single HAGS value' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers::HwSchMode'
        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-POLICY-ALLOW'
        $result.target.kind | Should -Be 'registry'
    }

    It 'refuses any other HKLM value' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer::ShellState'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKLM-VALUE'
    }

    It 'refuses an HKLM CurrentVersion\Run value' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run::Agent'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKLM-VALUE'
    }

    It 'refuses an Explorer\ShellExecuteHooks target' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellExecuteHooks::{ABC}'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKLM-VALUE'
    }

    It 'refuses every other HKLM execution-injection path by construction' {
        $targets = @(
            'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects\{ABC}::Value'
            'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SharedTaskScheduler::{ABC}'
            'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AppKey\1::ShellExecute'
            'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{ABC}::Value'
            'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run::Agent'
            'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders::Common Startup'
        )

        foreach ($target in $targets) {
            $result = Invoke-PcxPolicy -Target $target
            $result.allowed | Should -BeFalse -Because "$target must be unreachable"
            $result.code | Should -Be 'PCX-POLICY-HKLM-VALUE' -Because "no HKLM subtree is writable: $target"
        }
    }

    It 'refuses an HKLM Services Start value passed as reg: (the svc: path is the only route)' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack::Start'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-BOOTCHAIN'
    }

    It 'refuses the HAGS key itself without a value name' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKLM-VALUE'
    }

    It 'refuses a value on the GraphicsDrivers key other than HwSchMode' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers::Other'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HKLM-VALUE'
    }

    It 'refuses an HKU hive target' {
        $result = Invoke-PcxPolicy -Target 'reg:HKU\S-1-5-21\Environment::Path'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-HIVE'
    }
}

Describe 'protected targets' {

    It 'refuses a boot-chain key' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SYSTEM\CurrentControlSet\Control\Session Manager::BootExecute'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-BOOTCHAIN'
    }

    It 'refuses a TrustedInstaller key with PCX-POLICY-ACL' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\SideBySide::Version'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-ACL'
    }

    It 'refuses a security key' {
        $result = Invoke-PcxPolicy -Target 'reg:HKLM\SYSTEM\CurrentControlSet\Control\Lsa::DisableRestrictedAdmin'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-SECURITY'
    }

    It 'refuses a security service' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'WinDefend'; Start = 4 }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-SECURITY'
    }

    It 'refuses a kernel driver service' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'ndis'; Start = 4 }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-DRIVER'
    }

    It 'refuses an anticheat service' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'vgk'; Start = 4 }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-ANTICHEAT'
    }
}

Describe 'service blast radius' {

    It 'refuses a service with a running dependent' {
        $profile = New-PcxPolicyProfile -ServiceFacts @{
            spooler = @{ dependents = 1; listeningPorts = 0; childProcesses = 0 }
        }
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'Spooler'; Start = 4 } -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-BLAST-RADIUS'
    }

    It 'refuses a service with a listening port' {
        $profile = New-PcxPolicyProfile -ServiceFacts @{
            spooler = @{ dependents = 0; listeningPorts = 1; childProcesses = 0 }
        }
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'Spooler'; Start = 4 } -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-BLAST-RADIUS'
    }

    It 'refuses a service with child processes' {
        $profile = New-PcxPolicyProfile -ServiceFacts @{
            spooler = @{ dependents = 0; listeningPorts = 0; childProcesses = 2 }
        }
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'Spooler'; Start = 4 } -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-BLAST-RADIUS'
    }

    It 'refuses a service with no facts (fail closed)' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'Spooler'; Start = 4 }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-BLAST-RADIUS'
    }

    It 'refuses a service with incomplete facts (fail closed)' {
        $profile = New-PcxPolicyProfile -ServiceFacts @{
            spooler = @{ dependents = 0 }
        }
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'Spooler'; Start = 4 } -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-BLAST-RADIUS'
    }

    It 'allows an unprotected service proven to have zero blast radius' {
        $profile = New-PcxPolicyProfile -ServiceFacts @{
            diagtrack = @{ dependents = 0; listeningPorts = 0; childProcesses = 0 }
        }
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'DiagTrack'; Start = 4 } -Profile $profile
        $result.allowed | Should -BeTrue
        $result.code | Should -Be 'PCX-POLICY-ALLOW'
    }

    It 'refuses svc: Start=2 (Automatic)' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'DiagTrack'; Start = 2 }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-SERVICE-START'
    }

    It 'refuses svc: Start=0 and Start=1' {
        foreach ($start in @(0, 1)) {
            $result = Invoke-PcxPolicy -Target @{ Kind = 'service'; Name = 'DiagTrack'; Start = $start }
            $result.allowed | Should -BeFalse
            $result.code | Should -Be 'PCX-POLICY-SERVICE-START'
        }
    }

    It 'refuses a service target with no start value (fail closed)' {
        $result = Invoke-PcxPolicy -Target 'svc:DiagTrack'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-SERVICE-START'
    }
}

Describe 'task policy' {

    It 'refuses any task under \Microsoft\Windows\' {
        $result = Invoke-PcxPolicy -Target @{
            Kind    = 'task'
            Path    = '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
            Enabled = $false
        }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-TASK-SYSTEM'
    }

    It 'refuses a case-folded system task path' {
        $result = Invoke-PcxPolicy -Target @{
            Kind    = 'task'
            Path    = '\MICROSOFT\WINDOWS\Foo'
            Enabled = $false
        }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-TASK-SYSTEM'
    }

    It 'refuses task enabled=true' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'task'; Path = '\Pcx\MyTask'; Enabled = $true }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-TASK-ENABLE'
    }

    It 'refuses a task target with no enabled fact (fail closed)' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'task'; Path = '\Pcx\MyTask' }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-TASK-ENABLE'
    }

    It 'allows disabling a non-system task' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'task'; Path = '\Pcx\MyTask'; Enabled = $false }
        $result.allowed | Should -BeTrue
    }
}

Describe 'file root containment' {

    It 'allows a directory target inside a1_roots' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'file'; Path = 'C:\Windows\SoftwareDistribution\Download'; Role = 'a1' }
        $result.allowed | Should -BeTrue
    }

    It 'allows a concrete cache file inside a1_roots' {
        $result = Invoke-PcxPolicy -Target 'file:C:\Users\tester\AppData\Local\Microsoft\Windows\Explorer\thumbcache_32.db'
        $result.allowed | Should -BeTrue
    }

    It 'refuses an A1 target outside a1_roots' {
        $result = Invoke-PcxPolicy -Target 'file:C:\Users\tester\Documents\notes.txt'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-FILE-ROOT'
    }

    It 'allows a quarantine source inside a2_roots' {
        $result = Invoke-PcxPolicy -Target 'file:quarantine:C:\Users\tester\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\update.lnk'
        $result.allowed | Should -BeTrue
    }

    It 'refuses a quarantine source outside a2_roots' {
        $result = Invoke-PcxPolicy -Target 'file:quarantine:C:\Users\tester\Documents\update.lnk'
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-QUARANTINE-ROOT'
    }

    It 'refuses containment when the profile environment cannot resolve a root' {
        $profile = New-PcxPolicyProfile -Overrides @{ environment = [ordered]@{} }
        $result = Invoke-PcxPolicy -Target 'file:C:\Windows\SoftwareDistribution\Download' -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-FILE-ROOT'
    }

    It 'refuses an unknown file role' {
        $result = Invoke-PcxPolicy -Target @{ Kind = 'file'; Path = 'C:\Windows\SoftwareDistribution\Download'; Role = 'delete' }
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-GRAMMAR'
    }
}

Describe 'whole-machine profile gates' {

    BeforeAll {
        $script:anyTargets = @(
            @{ Kind = 'registry'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode' }
            @{ Kind = 'service'; Name = 'DiagTrack'; Start = 4 }
            @{ Kind = 'task'; Path = '\Pcx\MyTask'; Enabled = $false }
            @{ Kind = 'file'; Path = 'C:\Windows\SoftwareDistribution\Download'; Role = 'a1' }
        )
    }

    It 'refuses every write when the profile is managed' {
        $profile = New-PcxPolicyProfile -Overrides @{ managed = $true }
        foreach ($target in $script:anyTargets) {
            $result = Invoke-PcxPolicy -Target $target -Profile $profile
            $result.allowed | Should -BeFalse
            $result.code | Should -Be 'PCX-POLICY-MANAGED'
        }
    }

    It 'refuses every write when the profile is in S Mode' {
        $profile = New-PcxPolicyProfile -Overrides @{ sMode = $true }
        foreach ($target in $script:anyTargets) {
            $result = Invoke-PcxPolicy -Target $target -Profile $profile
            $result.allowed | Should -BeFalse
            $result.code | Should -Be 'PCX-POLICY-SMODE'
        }
    }

    It 'refuses when managed is unknown (fail closed)' {
        $profile = New-PcxPolicyProfile -Overrides @{ managed = $null }
        $result = Invoke-PcxPolicy -Target $script:anyTargets[0] -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-MANAGED'
    }

    It 'refuses when the profile object is missing (fail closed)' {
        $result = Invoke-PcxPolicy -Target $script:anyTargets[0] -Profile @{}
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-MANAGED'
    }

    It 'refuses every write on a Dev Drive profile' {
        $profile = New-PcxPolicyProfile -Overrides @{ devDrive = $true }
        $result = Invoke-PcxPolicy -Target $script:anyTargets[3] -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-DEVDRIVE'
    }

    It 'refuses every write when anticheat is present' {
        $profile = New-PcxPolicyProfile -Overrides @{ anticheat = $true }
        $result = Invoke-PcxPolicy -Target $script:anyTargets[0] -Profile $profile
        $result.allowed | Should -BeFalse
        $result.code | Should -Be 'PCX-POLICY-ANTICHEAT'
    }

    It 'allows the HAGS value on an explicit desktop profile' {
        $profile = New-PcxPolicyProfile
        $result = Invoke-PcxPolicy -Target $script:anyTargets[0] -Profile $profile
        $result.allowed | Should -BeTrue
    }
}

Describe 'pcx policy purity' {

    BeforeAll {
        $script:policySource = [System.IO.File]::ReadAllText($script:policySourcePath)

        $script:bannedTokens = @(
            'Get-Item'
            'Get-ItemProperty'
            'Get-ChildItem'
            'Get-Service'
            'Get-ScheduledTask'
            'Get-ScheduledTaskInfo'
            'Get-Process'
            'Get-WinEvent'
            'Get-CimInstance'
            'Get-CimClass'
            'Get-ComputerInfo'
            'Get-Volume'
            'Get-PhysicalDisk'
            'Test-Path'
            'Microsoft.Win32.Registry'
            '[System.IO.File]::Exists'
            '[System.IO.Directory]::Exists'
            '[System.IO.File]::ReadAllText'
            '[System.IO.Directory]::GetFiles'
            '[Environment]::GetEnvironmentVariable'
            'Set-ItemProperty'
            'New-ItemProperty'
            'Remove-ItemProperty'
            'New-Item'
            'Remove-Item'
            'Set-Service'
            'Enable-ScheduledTask'
            'Disable-ScheduledTask'
            'Invoke-Expression'
            'Invoke-PcxPlatformRead'
            'Invoke-PcxPlatformWrite'
            'Invoke-PcxPlatformDelete'
            'Invoke-PcxPlatformMove'
            'reg.exe'
            'sc.exe'
            'schtasks.exe'
            'cmd /c'
        )
    }

    It 'contains no machine-state cmdlet, registry API, platform call or shell' {
        foreach ($token in $script:bannedTokens) {
            $script:policySource | Should -Not -Match ([regex]::Escape($token)) -Because "PcxPolicy.ps1 must not use '$token'"
        }
    }

    It 'never probes the file system directly; the only data read goes through Read-PcxJson' {
        $script:policySource | Should -Not -Match ([regex]::Escape('[System.IO.File]'))
        $script:policySource | Should -Not -Match ([regex]::Escape('[System.IO.Directory]'))
        $script:policySource | Should -Match ([regex]::Escape('Read-PcxJson'))
    }

    It 'proves the scanner would catch a banned call' {
        $sample = 'x' + 'Get-Item' + 'y'
        $sample | Should -Match ([regex]::Escape('Get-Item'))
    }
}
