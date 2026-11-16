<#
.SYNOPSIS
    Skeleton suite for todo 1: module load, entry envelope, module tree, fixture mode.
#>

BeforeAll {
    if ($env:PCX_TEST_RUN -ne '1') {
        throw "PCX_TEST_RUN must be '1' before the suite starts. Run tests through tests/run.ps1."
    }

    # Sticky fixture mode, re-asserted for every suite.
    $env:PCX_TEST_RUN = '1'

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../../')).Path
    $entryScript = Join-Path -Path $repoRoot -ChildPath 'pcx.ps1'
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Pcx.psm1'
    $testAdapterPath = Join-Path -Path $repoRoot -ChildPath 'tests/TestAdapter/PcxPlatform.Test.ps1'

    $env:PCX_PLATFORM_MODULE = (Resolve-Path -LiteralPath $testAdapterPath).Path

    $hostExecutable = (Get-Process -Id $PID).Path

    function Invoke-PcxEntry {
        param([Parameter(Mandatory = $true)][string[]] $Arguments)

        $stdout = & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $entryScript @Arguments 2>$null

        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Lines    = @($stdout | Where-Object { $null -ne $_ -and ([string]$_).Trim().Length -gt 0 })
        }
    }
}

Describe 'pcx repository skeleton' {

    It 'loads the pcx module and exposes the dispatch surface' {
        Import-Module -Name $modulePath -Force

        (Get-Command -Name 'Invoke-PcxDispatch' -ErrorAction Stop).Name | Should -Be 'Invoke-PcxDispatch'
        (Get-Command -Name 'New-PcxRefusal' -ErrorAction Stop).Name | Should -Be 'New-PcxRefusal'
    }

    It 'has the src/pcx module tree' {
        Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'src/pcx') | Should -BeTrue
        Test-Path -LiteralPath $modulePath | Should -BeTrue
    }

    It 'prints exactly one JSON envelope and exits 0 for --help' {
        $result = Invoke-PcxEntry -Arguments @('--help')

        $result.ExitCode | Should -Be 0
        $result.Lines.Count | Should -Be 1

        $envelope = $result.Lines[0] | ConvertFrom-Json
        $envelope.schema | Should -Be 'pcx/1'
        $envelope.status | Should -Be 'ok'
        $envelope.command | Should -Be 'help'
        $envelope.exitCode | Should -Be 0
        @($envelope.data.commands) | Should -Contain 'doctor'
        @($envelope.data.commands) | Should -Contain 'tune'
        @($envelope.data.commands) | Should -Contain 'undo'
    }

    It 'refuses to arm real writes while PCX_TEST_RUN is set' {
        $env:PCX_TEST_RUN = '1'

        $result = Invoke-PcxEntry -Arguments @('undo', '--item', 'skeleton-noop')

        $result.ExitCode | Should -Be 2
        $result.Lines.Count | Should -Be 1

        $envelope = $result.Lines[0] | ConvertFrom-Json
        $envelope.status | Should -Be 'refused'
        $envelope.diagnostics[0].code | Should -Be 'PCX-E-ARM-TESTRUN'
    }
}
