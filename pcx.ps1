#Requires -Version 5.1
<#
.SYNOPSIS
    pcx entry point: dispatches doctor / tune / undo and owns the real-write
    arming window.

.DESCRIPTION
    No product logic lives here. The module (src/pcx/Pcx.psm1) owns dispatch and
    envelope construction; this script only:
      * imports the module,
      * prints exactly one JSON envelope on stdout,
      * exits with the envelope's exit code,
      * sets PCX_ALLOW_REAL_WRITES=1 inside try/finally, and only for the
        `tune --apply` and `undo` code paths,
      * refuses to arm while PCX_TEST_RUN is set.

    Exit codes: 0 ok, 1 error, 2 refused, 3 undo refused (nothing was reverted).
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pcxModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'src/pcx/Pcx.psm1'
Import-Module -Name $pcxModulePath -Force

$pcxArguments = [string[]]@($args)

function Invoke-PcxArmed {
    # Arming window: PCX_ALLOW_REAL_WRITES exists only for the duration of the
    # write-capable dispatch, and never while PCX_TEST_RUN is set.
    param(
        [Parameter(Mandatory = $true)][string] $CommandName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments
    )

    if ($env:PCX_TEST_RUN) {
        return New-PcxRefusal -CommandName $CommandName -Code 'PCX-E-ARM-TESTRUN' -Message "Refusing to arm PCX_ALLOW_REAL_WRITES while PCX_TEST_RUN is set ('$($env:PCX_TEST_RUN)')."
    }

    $previousValue = $env:PCX_ALLOW_REAL_WRITES

    try {
        $env:PCX_ALLOW_REAL_WRITES = '1'
        return Invoke-PcxDispatch -Arguments $Arguments
    }
    finally {
        if ($null -eq $previousValue) {
            $env:PCX_ALLOW_REAL_WRITES = $null
        }
        else {
            $env:PCX_ALLOW_REAL_WRITES = $previousValue
        }
    }
}

function Invoke-PcxEntry {
    param([AllowEmptyCollection()][string[]] $Arguments = @())

    $command = if ($Arguments.Count -ge 1 -and $Arguments[0]) { [string]$Arguments[0] } else { 'help' }

    $armsRealWrites = ($command -eq 'undo') -or
        ($command -eq 'tune' -and $Arguments -contains '--apply') -or
        ($command -eq 'apply-elevated' -and $Arguments -contains '--run') -or
        ($command -eq 'undo-elevated' -and $Arguments -contains '--run')

    if ($armsRealWrites) {
        return Invoke-PcxArmed -CommandName $command -Arguments $Arguments
    }

    return Invoke-PcxDispatch -Arguments $Arguments
}

$pcxResult = Invoke-PcxEntry -Arguments $pcxArguments

$pcxResult.Envelope | ConvertTo-Json -Compress -Depth 8
exit $pcxResult.ExitCode
