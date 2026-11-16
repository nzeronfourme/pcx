#Requires -Version 5.1
<#
.SYNOPSIS
    pcx test runner: fixture mode only, Pester 5 only.

.DESCRIPTION
    Runs the Pester suites under tests/Pester and the end-to-end replay under
    tests/E2E with the test platform adapter and the sticky PCX_TEST_RUN
    sentinel. Fails closed (non-zero exit, clear message) when:
      * Pester >= 5.0.0 is unavailable,
      * the real platform adapter is active,
      * no test file matches -Test,
      * a test cleared the sticky sentinel mid-run.

    On success prints adapter=test and exits 0.

.PARAMETER Test
    Substring filter over test file paths, comma-separated for several
    independent filters. -Test Skeleton runs
    tests/Pester/Unit/PcxSkeleton.Tests.ps1; -Test E2E,RoundTrip,Safety runs
    every file whose path contains E2E, RoundTrip or Safety; -Test '*' runs
    everything.
#>

[CmdletBinding()]
param(
    [string] $Test = '*'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pesterRoot = Join-Path -Path $PSScriptRoot -ChildPath 'Pester'
$e2eRoot = Join-Path -Path $PSScriptRoot -ChildPath 'E2E'
$testAdapterPath = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'TestAdapter/PcxPlatform.Test.ps1')).Path
$realAdapterPath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxPlatform.ps1'

function Stop-PcxRunner {
    param([Parameter(Mandatory = $true)][string] $Message)

    [Console]::Error.WriteLine("pcx test runner: FAIL - $Message")
    exit 1
}

# Sticky fixture mode: set before anything else, verified after the run.
$env:PCX_TEST_RUN = '1'
$env:PCX_PLATFORM_MODULE = $testAdapterPath

# Deterministic baseline platform state. The proposal table prints an A1 row
# only when its target exists with a measured size, so a suite that never seeds
# a state file must still see the first Safe row (thumbnails). Suites that need
# their own state set PCX_TEST_STATE_FILE themselves.
$baselineState = Join-Path ([System.IO.Path]::GetTempPath()) ('pcx-runner-state-' + [guid]::NewGuid().ToString('n') + '.json')
$baselineFiles = [ordered]@{}
$baselineContent = [Convert]::ToBase64String((New-Object byte[] 4096))
foreach ($cacheSize in @(32, 96, 256, 1024)) {
    $cachePath = "c:\users\tester\appdata\local\microsoft\windows\explorer\thumbcache_$cacheSize.db"
    $baselineFiles[$cachePath] = [ordered]@{
        path           = $cachePath
        contentBase64  = $baselineContent
        attributes     = 'Archive'
        isReparsePoint = $false
    }
}
$baselineDocument = [ordered]@{
    schema   = 'pcx-platform-test/1'
    registry = @{}
    services = @{}
    tasks    = @{}
    files    = $baselineFiles
}
$baselineUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
[System.IO.File]::WriteAllText($baselineState, (ConvertTo-Json -InputObject $baselineDocument -Depth 8 -Compress), $baselineUtf8)
$env:PCX_TEST_STATE_FILE = $baselineState

try {
    Import-Module -Name Pester -MinimumVersion 5.0.0 -Force -ErrorAction Stop
}
catch {
    Stop-PcxRunner "Pester >= 5.0.0 is required and could not be imported ($($_.Exception.Message)). Install it with: Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser"
}

$pesterModule = Get-Module -Name Pester | Sort-Object -Property Version -Descending | Select-Object -First 1
if ($null -eq $pesterModule -or $pesterModule.Version -lt [version]'5.0.0') {
    $foundVersion = if ($null -eq $pesterModule) { 'none' } else { [string]$pesterModule.Version }
    Stop-PcxRunner "Pester >= 5.0.0 is required but Pester $foundVersion was loaded."
}

$adapter = $env:PCX_PLATFORM_MODULE
if ([string]::IsNullOrWhiteSpace($adapter)) {
    Stop-PcxRunner 'PCX_PLATFORM_MODULE is not set; refusing to run against the real OS adapter.'
}

if (-not [System.IO.Path]::IsPathRooted($adapter)) {
    Stop-PcxRunner "PCX_PLATFORM_MODULE '$adapter' is not an absolute path."
}

if ($adapter -eq $realAdapterPath) {
    Stop-PcxRunner "the real platform adapter is active ($adapter); tests must use $testAdapterPath."
}

if (-not (Test-Path -LiteralPath $adapter)) {
    Stop-PcxRunner "PCX_PLATFORM_MODULE '$adapter' does not exist."
}

$filters = @(
    $Test.Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrEmpty($_) }
)
if ($filters.Count -eq 0) {
    $filters = @('*')
}

$testFiles = @(
    Get-ChildItem -LiteralPath @($pesterRoot, $e2eRoot) -Recurse -File -Filter '*.Tests.ps1' |
        Where-Object {
            $path = $_.FullName
            @($filters | Where-Object { $path -like "*$_*" }).Count -gt 0
        } |
        Sort-Object -Property FullName |
        Select-Object -ExpandProperty FullName
)

if ($testFiles.Count -eq 0) {
    Stop-PcxRunner "no test file under $pesterRoot or $e2eRoot matched -Test '$Test'."
}

$run = Invoke-Pester -Path $testFiles -Output Detailed -PassThru

if ($env:PCX_TEST_RUN -ne '1') {
    Stop-PcxRunner 'a test cleared the sticky PCX_TEST_RUN sentinel; fixture mode is no longer trustworthy.'
}

if ($run.FailedCount -gt 0 -or $run.Result -ne 'Passed') {
    exit 1
}

Write-Host 'adapter=test'
exit 0
