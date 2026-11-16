<#
.SYNOPSIS
    Envelope constructors and the stderr progress writer.

.DESCRIPTION
    Exactly one JSON object goes to stdout per pcx invocation; progress lines go
    to stderr only (Write-PcxProgress). Exit codes:

        0  ok
        1  error        (PCX-E-* codes)
        2  refused      (PCX-E-* or PCX-POLICY-* codes)
        3  undo refused (drift, policy, journal or UAC check; nothing was
                         reverted)

    The envelope is an ordered map with the fixed shape
        schema / version / status / command / exitCode / data / diagnostics
    so consumers can rely on field names and order. This file is the single
    definition of that shape; Pcx.psm1 only delegates here.
#>

Set-StrictMode -Version 2.0

$script:PcxSchemaVersion = 'pcx/1'
$script:PcxProductVersion = '0.0.0'

$script:PcxExitOk = 0
$script:PcxExitError = 1
$script:PcxExitRefused = 2
$script:PcxExitUndoRefused = 3

function Assert-PcxDiagnosticCode {
    # Internal: codes are namespaced so callers can branch without parsing text.
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string[]] $Prefixes
    )

    foreach ($prefix in $Prefixes) {
        if ($Code.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            return
        }
    }

    throw [System.ArgumentException]::new("PCX-E-CODE: diagnostic code '$Code' must start with one of: $($Prefixes -join ', ').")
}

function New-PcxEnvelope {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'error', 'refused')][string] $Status,
        [Parameter(Mandatory = $true)][string] $CommandName,
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [hashtable] $Data = @{},
        [object[]] $Diagnostics = @()
    )

    return [ordered]@{
        schema      = $script:PcxSchemaVersion
        version     = $script:PcxProductVersion
        status      = $Status
        command     = $CommandName
        exitCode    = $ExitCode
        data        = $Data
        diagnostics = $Diagnostics
    }
}

function New-PcxResult {
    param(
        [Parameter(Mandatory = $true)][int] $ExitCode,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Envelope
    )

    return [pscustomobject]@{
        ExitCode = $ExitCode
        Envelope = $Envelope
    }
}

function New-PcxError {
    <#
    .SYNOPSIS
        Builds an error result (exit 1) with one PCX-E-* diagnostic.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $CommandName,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message
    )

    Assert-PcxDiagnosticCode -Code $Code -Prefixes @('PCX-E-')

    $diagnostics = @(
        [ordered]@{
            code    = $Code
            message = $Message
        }
    )

    return New-PcxResult -ExitCode $script:PcxExitError -Envelope (New-PcxEnvelope -Status 'error' -CommandName $CommandName -ExitCode $script:PcxExitError -Diagnostics $diagnostics)
}

function New-PcxRefusal {
    <#
    .SYNOPSIS
        Builds a refused result (exit 2) with one PCX-E-* or PCX-POLICY-* diagnostic.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $CommandName,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message
    )

    Assert-PcxDiagnosticCode -Code $Code -Prefixes @('PCX-E-', 'PCX-POLICY-')

    $diagnostics = @(
        [ordered]@{
            code    = $Code
            message = $Message
        }
    )

    return New-PcxResult -ExitCode $script:PcxExitRefused -Envelope (New-PcxEnvelope -Status 'refused' -CommandName $CommandName -ExitCode $script:PcxExitRefused -Diagnostics $diagnostics)
}

function Write-PcxProgress {
    <#
    .SYNOPSIS
        Writes one progress line to stderr; stdout stays a single JSON object.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string] $Message
    )

    [Console]::Error.WriteLine("pcx: $Message")
}
