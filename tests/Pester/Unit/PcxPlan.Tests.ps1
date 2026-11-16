<#
.SYNOPSIS
    Internal plan validator (todo 11).

.DESCRIPTION
    Proves the gate before the writer: a stable row selection builds a
    deterministic plan; an agent-discovered target passes only when grammar,
    evidence and policy hold; an agent-discovered state-only B refuses; A1
    derives manifest-only and a Startup-folder B derives quarantine; a
    protected target, a duplicate target and a wildcard refuse; an unsupported
    build family is demoted to Manual and never enters the applyable items,
    while a supported-but-unverified build stays applyable;
    -DryRun writes nothing; a real run writes plan-<id>.json and Test-PcxPlan
    re-validates those exact bytes to the same planHash; altered bytes refuse.
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
    $script:Plan = $script:Module.ExportedCommands['Invoke-PcxPlan']
    $script:TestPlan = $script:Module.ExportedCommands['Test-PcxPlan']
    $script:GetCatalog = $script:Module.ExportedCommands['Get-PcxCatalog']
    $script:ScanCommand = $script:Module.ExportedCommands['Get-PcxScan']

    $script:Catalog = & $script:GetCatalog
    $script:FixtureRoot = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/environment'
    $script:DesktopFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'desktop'
    $script:DesktopMachine = Join-Path -Path $script:DesktopFixture -ChildPath 'machine.json'
    $script:Scan = & $script:ScanCommand -FixturePath $script:DesktopFixture

    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:StateBase = Join-Path -Path $TestDrive -ChildPath 'pcx-plan-state'
    $env:LOCALAPPDATA = $script:StateBase

    # Row 1 is the thumbnails A1 action: seed its four files so the table has a
    # measured, selectable Safe row.
    $script:PlatformStateFile = Join-Path -Path $TestDrive -ChildPath 'plan-platform-state.json'
    $planContent = [Convert]::ToBase64String((New-Object byte[] 4096))
    $planFiles = [ordered]@{}
    foreach ($cacheSize in @(32, 96, 256, 1024)) {
        $cachePath = "c:\users\tester\appdata\local\microsoft\windows\explorer\thumbcache_$cacheSize.db"
        $planFiles[$cachePath] = [ordered]@{
            path           = $cachePath
            contentBase64  = $planContent
            attributes     = 'Archive'
            isReparsePoint = $false
            sizeBytes      = 200MB
        }
    }
    $planState = [ordered]@{
        schema   = 'pcx-platform-test/1'
        registry = @{}
        services = @{}
        tasks    = @{}
        files    = $planFiles
    }
    $planUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($script:PlatformStateFile, (ConvertTo-Json -InputObject $planState -Depth 8 -Compress), $planUtf8)
    $env:PCX_TEST_STATE_FILE = $script:PlatformStateFile

    function New-PcxPlanEnvironment {
        param([Parameter(Mandatory = $false)][int] $Build = 26100)

        $environment = Get-Content -LiteralPath $script:DesktopMachine -Raw | ConvertFrom-Json
        $environment.os.build.value = $Build
        return $environment
    }

    function New-PcxPlanTelemetryEvidence {
        param(
            [Parameter(Mandatory = $false)][string] $Metric = 'storage.system_free_bytes',
            [Parameter(Mandatory = $false)][string] $Domain = 'storage',
            [Parameter(Mandatory = $false)][object] $Value = 123456789,
            [Parameter(Mandatory = $false)][string] $Window = 'instant',
            [Parameter(Mandatory = $false)][AllowNull()][string] $Root
        )

        $evidence = [ordered]@{
            kind   = 'telemetry'
            metric = $Metric
            domain = $Domain
            value  = $Value
            status = 'measured'
            window = $Window
        }
        if (-not [string]::IsNullOrWhiteSpace($Root)) {
            $evidence['root'] = $Root
        }
        return $evidence
    }

    function Get-PcxPlanRefusalCodes {
        param([Parameter(Mandatory = $true)][object] $Result)
        return @($Result.refused | ForEach-Object { [string]$_.code })
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
}

Describe 'plan validator surface' {

    It 'exports Invoke-PcxPlan and Test-PcxPlan but adds no user-facing plan command' {
        ($null -ne $script:Plan) | Should -BeTrue
        ($null -ne $script:TestPlan) | Should -BeTrue

        $help = & $script:Module.ExportedCommands['Invoke-PcxDispatch'] -Arguments @('--help')
        @($help.Envelope.data.commands) -contains 'plan' | Should -BeFalse
    }
}

Describe 'plan from a stable row selection' {

    BeforeAll {
        $script:Env26100 = New-PcxPlanEnvironment -Build 26100
        $script:FirstRun = & $script:Plan -Selection '1' -Scan $script:Scan -Profile $script:Env26100 -DryRun
        $script:SecondRun = & $script:Plan -Selection '1' -Scan $script:Scan -Profile $script:Env26100 -DryRun
    }

    It 'builds one applyable item from row 1' {
        @($script:FirstRun.refused).Count | Should -Be 0
        @($script:FirstRun.items).Count | Should -Be 1
        @($script:FirstRun.demoted).Count | Should -Be 0
        $script:FirstRun.written | Should -BeFalse

        $item = $script:FirstRun.items[0]
        $item.actionId | Should -Be 'thumbnails'
        $item.row | Should -Be 1
        $item.origin | Should -Be 'seed'
        $item.category | Should -Be 'A1'
        $item.inverse | Should -Be 'manifest-only'
        [string]::IsNullOrWhiteSpace([string]$item.user_text_en) | Should -BeFalse
        [string]::IsNullOrWhiteSpace([string]$item.user_text_ru) | Should -BeFalse
        @($item.target).Count | Should -Be 4
    }

    It 'expands %TOKEN% file roots to absolute targets at plan time' {
        foreach ($target in @($script:FirstRun.items[0].target)) {
            ([string]$target.path) | Should -Match '^[a-z]:\\'
            ([string]$target.path) | Should -Not -Match '%'
        }
    }

    It 'derives a stable planHash and planId across two runs' {
        $script:FirstRun.planHash | Should -Match '^[0-9a-f]{64}$'
        $script:FirstRun.planHash | Should -Be $script:SecondRun.planHash
        $script:FirstRun.planId | Should -Be $script:SecondRun.planId
        $script:FirstRun.planId | Should -Match '^[0-9a-f]{16}$'
        $script:FirstRun.planId | Should -Be $script:FirstRun.planHash.Substring(0, 16)
    }

    It 'keeps the plan free of HMAC, nonce and signature material' {
        $json = ConvertTo-Json -InputObject $script:FirstRun.plan -Depth 32 -Compress
        $json | Should -Not -Match '(?i)hmac|nonce|signature|secret'
    }
}

Describe 'proposal validation' {

    BeforeAll {
        $script:Env26100 = New-PcxPlanEnvironment -Build 26100

        $script:A1Proposal = [ordered]@{
            actionId = 'thumbnails'
            target   = [ordered]@{
                Kind = 'file'
                Path = '%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_32.db'
                Role = 'a1'
            }
            evidence = New-PcxPlanTelemetryEvidence -Root 'C:\Users\tester\AppData\Local\Microsoft\Windows\Explorer'
        }

        $script:StartupProposal = [ordered]@{
            actionId = 'startup-shortcut-u4'
            target   = [ordered]@{
                Kind = 'file'
                Path = '%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\OneDrive.lnk'
                Role = 'quarantine'
            }
            evidence = New-PcxPlanTelemetryEvidence -Metric 'intent.userassist_entries' -Domain 'intent' -Value 87 -Window 'all-time' -Root 'C:\Users\tester\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\OneDrive.lnk'
        }

        $script:StateOnlyProposal = [ordered]@{
            actionId = 'tips'
            target   = [ordered]@{
                Kind = 'registry'
                Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                Name = 'SubscribedContent-338389Enabled'
            }
            evidence = [ordered]@{
                kind   = 'state'
                metric = 'ux.tips_enabled'
                domain = 'ux'
                value  = $true
                status = 'measured'
                window = 'instant'
            }
        }
    }

    It 'accepts an agent-discovered target when grammar, evidence and policy hold' {
        $result = & $script:Plan -Proposals @($script:A1Proposal) -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 0
        @($result.items).Count | Should -Be 1
        $result.items[0].origin | Should -Be 'agent-discovered'
        $result.items[0].actionId | Should -Be 'thumbnails'
    }

    It 'refuses an agent-discovered state-only B action' {
        $result = & $script:Plan -Proposals @($script:StateOnlyProposal) -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 1
        (Get-PcxPlanRefusalCodes -Result $result) -contains 'PCX-E-EVIDENCE-STATE-ONLY' | Should -BeTrue
        $result.plan | Should -BeNullOrEmpty
    }

    It 'derives manifest-only for an A1 proposal' {
        $result = & $script:Plan -Proposals @($script:A1Proposal) -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 0
        $result.items[0].inverse | Should -Be 'manifest-only'
    }

    It 'derives quarantine for a Startup-folder B proposal' {
        $result = & $script:Plan -Proposals @($script:StartupProposal) -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 0
        @($result.items).Count | Should -Be 1
        $result.items[0].category | Should -Be 'B'
        $result.items[0].inverse | Should -Be 'quarantine'
    }
}

Describe 'plan refusals' {

    BeforeAll {
        $script:Env26100 = New-PcxPlanEnvironment -Build 26100

        $script:ProtectedProposal = [ordered]@{
            actionId = 'diagtrack-u4'
            target   = [ordered]@{ Kind = 'service'; Name = 'WinDefend'; Start = 4 }
            evidence = New-PcxPlanTelemetryEvidence -Metric 'services.running_count' -Domain 'services' -Value 143
        }

        $script:WildcardProposal = [ordered]@{
            actionId = 'thumbnails'
            target   = [ordered]@{
                Kind = 'file'
                Path = 'C:\Users\tester\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db'
                Role = 'a1'
            }
            evidence = New-PcxPlanTelemetryEvidence -Root 'C:\Users\tester\AppData\Local\Microsoft\Windows\Explorer'
        }
    }

    It 'refuses a protected target' {
        $result = & $script:Plan -Proposals @($script:ProtectedProposal) -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 1
        (Get-PcxPlanRefusalCodes -Result $result) -contains 'PCX-POLICY-SECURITY' | Should -BeTrue
    }

    It 'refuses two items on the same canonical target' {
        $result = & $script:Plan -Selection '1,1' -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 1
        (Get-PcxPlanRefusalCodes -Result $result) -contains 'PCX-E-PLAN-DUPLICATE' | Should -BeTrue
    }

    It 'refuses a wildcard target' {
        $result = & $script:Plan -Proposals @($script:WildcardProposal) -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 1
        (Get-PcxPlanRefusalCodes -Result $result) -contains 'PCX-POLICY-GRAMMAR' | Should -BeTrue
    }

    It 'refuses an unknown action id' {
        $proposal = [ordered]@{
            actionId = 'download-more-ram'
            target   = [ordered]@{ Kind = 'service'; Name = 'DiagTrack'; Start = 4 }
            evidence = New-PcxPlanTelemetryEvidence -Metric 'services.running_count' -Domain 'services' -Value 143
        }

        $result = & $script:Plan -Proposals @($proposal) -Scan $script:Scan -Profile $script:Env26100 -DryRun

        @($result.refused).Count | Should -Be 1
        (Get-PcxPlanRefusalCodes -Result $result) -contains 'PCX-E-PLAN-ACTION' | Should -BeTrue
    }
}

Describe 'build support families' {

    BeforeAll {
        $script:Env22631 = New-PcxPlanEnvironment -Build 22631
        $script:Env19045 = New-PcxPlanEnvironment -Build 19045
        $script:Env17763 = New-PcxPlanEnvironment -Build 17763

        $script:Result22631 = & $script:Plan -Selection '1' -Scan $script:Scan -Profile $script:Env22631 -DryRun
        $script:Result19045 = & $script:Plan -Selection '1' -Scan $script:Scan -Profile $script:Env19045 -DryRun
        $script:Result17763 = & $script:Plan -Selection '1' -Scan $script:Scan -Profile $script:Env17763 -DryRun

        $script:UnsupportedProposal = [ordered]@{
            actionId = 'thumbnails'
            target   = [ordered]@{
                Kind = 'file'
                Path = '%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_32.db'
                Role = 'a1'
            }
            evidence = New-PcxPlanTelemetryEvidence -Root 'C:\Users\tester\AppData\Local\Microsoft\Windows\Explorer'
        }
        $script:Proposal17763 = & $script:Plan -Proposals @($script:UnsupportedProposal) -Scan $script:Scan -Profile $script:Env17763 -DryRun
    }

    It 'accepts a supported-but-unverified build (22631) instead of demoting it' {
        @($script:Result22631.refused).Count | Should -Be 0
        @($script:Result22631.items).Count | Should -Be 1
        @($script:Result22631.demoted).Count | Should -Be 0
        $script:Result22631.items[0].actionId | Should -Be 'thumbnails'
    }

    It 'accepts a Windows 10 2004+ build (19045)' {
        @($script:Result19045.refused).Count | Should -Be 0
        @($script:Result19045.items).Count | Should -Be 1
        @($script:Result19045.demoted).Count | Should -Be 0
    }

    It 'does not accept a row the table demoted on an unsupported build' {
        @($script:Result17763.items | Where-Object { $null -ne $_ }).Count | Should -Be 0
        @($script:Result17763.refused).Count | Should -Be 1
        [string]$script:Result17763.refused[0].code | Should -Be 'PCX-E-PLAN-NOT-APPLYABLE'
    }

    It 'demotes an unsupported-build proposal to Manual with the build reason' {
        @($script:Proposal17763.refused).Count | Should -Be 0
        @($script:Proposal17763.items).Count | Should -Be 0
        @($script:Proposal17763.demoted).Count | Should -Be 1
        $script:Proposal17763.demoted[0].actionId | Should -Be 'thumbnails'
        $script:Proposal17763.demoted[0].reason | Should -Match '17763'
        $script:Proposal17763.demoted[0].reason | Should -Match 'unsupported'
        $script:Proposal17763.demoted[0].reason | Should -Match 'Manual'
    }
}

Describe 'plan write and re-validation' {

    BeforeAll {
        $script:Env26100 = New-PcxPlanEnvironment -Build 26100
        $script:DryRoot = Join-Path -Path $script:StateBase -ChildPath 'dry'
        $script:WriteRoot = Join-Path -Path $script:StateBase -ChildPath 'write'

        $env:LOCALAPPDATA = $script:DryRoot
        $script:DryResult = & $script:Plan -Selection '1' -Scan $script:Scan -Profile $script:Env26100 -DryRun
        $script:DryJournal = Join-Path -Path $script:DryRoot -ChildPath 'pcx\journal'

        $env:LOCALAPPDATA = $script:WriteRoot
        $script:WriteResult = & $script:Plan -Selection '1' -Scan $script:Scan -Profile $script:Env26100
        $script:PlanBytes = [System.IO.File]::ReadAllBytes([string]$script:WriteResult.written)
        $script:Revalidated = & $script:TestPlan -PlanBytes $script:PlanBytes

        $script:PlanText = [System.Text.Encoding]::UTF8.GetString($script:PlanBytes)
        $script:AlteredText = $script:PlanText.Replace('thumbcache_32.db', 'thumbcache_99.db')
        $script:AlteredBytes = [System.Text.Encoding]::UTF8.GetBytes($script:AlteredText)
        $script:AlteredResult = & $script:TestPlan -PlanBytes $script:AlteredBytes
    }

    It 'writes nothing on a dry run' {
        $script:DryResult.written | Should -BeFalse
        (Test-Path -LiteralPath $script:DryJournal) | Should -BeFalse
    }

    It 'writes the plan file named after planId on a real run' {
        $script:WriteResult.written | Should -Not -BeFalse
        (Test-Path -LiteralPath ([string]$script:WriteResult.written)) | Should -BeTrue
        [System.IO.Path]::GetFileName([string]$script:WriteResult.written) | Should -Be ('plan-' + $script:WriteResult.planId + '.json')
    }

    It 're-validates the written bytes to the same planHash' {
        $script:Revalidated.ok | Should -BeTrue
        $script:Revalidated.planHash | Should -Be $script:WriteResult.planHash
        $script:Revalidated.planId | Should -Be $script:WriteResult.planId
        @($script:Revalidated.items).Count | Should -Be @($script:WriteResult.items).Count
    }

    It 'refuses altered bytes' {
        $script:AlteredText | Should -Not -Be $script:PlanText
        $script:AlteredResult.ok | Should -BeFalse
        $script:AlteredResult.code | Should -Be 'PCX-E-PLAN-MISMATCH'
    }

    It 'writes a plan with no HMAC, nonce or signature field' {
        $script:PlanText | Should -Not -Match '(?i)hmac|nonce|signature|secret'
    }
}
