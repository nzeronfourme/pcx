<#
.SYNOPSIS
    `pcx doctor`: read-only environment and state report.

.DESCRIPTION
    Reports PowerShell version and edition, Windows build/UBR, module load
    status, the resolved state directory and whether it exists, and fixture
    mode. Strictly read-only:

      * never calls Initialize-PcxState, so it never creates the state tree,
      * reads the OS version from the registry (no Win32_Product, no WMI),
      * takes no dependency on Pester.

    Returns a pcx result object (ExitCode + Envelope) with status ok.
#>

Set-StrictMode -Version 2.0

function Invoke-PcxDoctor {
    param()

    $versionTable = $PSVersionTable

    $powershellEdition = if ($versionTable.ContainsKey('PSEdition')) { [string]$versionTable['PSEdition'] } else { 'Desktop' }

    $osInfo = [ordered]@{
        name    = $null
        version = $null
        build   = $null
        ubr     = $null
        source  = $null
    }

    try {
        $osKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $osProperties = Get-ItemProperty -LiteralPath $osKey -ErrorAction Stop

        $osInfo['name'] = [string]$osProperties.PSObject.Properties['ProductName'].Value
        $osInfo['version'] = [string]$osProperties.PSObject.Properties['DisplayVersion'].Value
        $osInfo['build'] = [string]$osProperties.PSObject.Properties['CurrentBuildNumber'].Value

        $ubrProperty = $osProperties.PSObject.Properties['UBR']
        if ($null -ne $ubrProperty) {
            $osInfo['ubr'] = [int]$ubrProperty.Value
        }

        $osInfo['source'] = 'registry'
    }
    catch {
        $osVersion = [System.Environment]::OSVersion.Version
        $osInfo['build'] = [string]$osVersion.Build
        $osInfo['version'] = [string]$osVersion
        $osInfo['source'] = 'environment'
    }

    $loadedModule = Get-Module -Name 'Pcx' -ErrorAction SilentlyContinue | Select-Object -First 1
    $moduleInfo = if ($null -ne $loadedModule) {
        [ordered]@{
            loaded  = $true
            name    = [string]$loadedModule.Name
            path    = [string]$loadedModule.Path
            version = [string]$loadedModule.Version
        }
    }
    else {
        [ordered]@{
            loaded  = $false
            name    = 'Pcx'
            path    = $null
            version = $null
        }
    }

    $stateRoot = Get-PcxStateRoot
    $stateInfo = [ordered]@{
        root          = $stateRoot
        exists        = [System.IO.Directory]::Exists($stateRoot)
        scans         = Get-PcxStatePath -Kind 'scans'
        journal       = Get-PcxStatePath -Kind 'journal'
        quarantine    = Get-PcxStatePath -Kind 'quarantine'
        subdirsExists = [System.IO.Directory]::Exists((Get-PcxStatePath -Kind 'scans'))
    }

    $testRunValue = [System.Environment]::GetEnvironmentVariable('PCX_TEST_RUN')
    $fixtureInfo = [ordered]@{
        active         = ($testRunValue -eq '1')
        testRun        = $testRunValue
        platformModule = [System.Environment]::GetEnvironmentVariable('PCX_PLATFORM_MODULE')
    }

    $data = [ordered]@{
        product    = [ordered]@{
            name    = 'pcx'
            version = $script:PcxProductVersion
            schema  = $script:PcxSchemaVersion
        }
        powershell = [ordered]@{
            version = [string]$versionTable['PSVersion']
            edition = $powershellEdition
            host    = [string]$Host.Name
        }
        os         = $osInfo
        module     = $moduleInfo
        state      = $stateInfo
        fixture    = $fixtureInfo
    }

    return New-PcxResult -ExitCode $script:PcxExitOk -Envelope (New-PcxEnvelope -Status 'ok' -CommandName 'doctor' -ExitCode $script:PcxExitOk -Data $data)
}
