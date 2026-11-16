<#
.SYNOPSIS
    Per-user pcx state root and containment guard.

.DESCRIPTION
    The only state location is %LOCALAPPDATA%\pcx with the subdirectories
    scans, journal and quarantine. No machine-wide root, no registry key, no
    ACL claim.

    Every resolved path must stay strictly under %LOCALAPPDATA%\pcx. Paths that
    escape via "..", an absolute/other-drive path, a UNC path or a reparse
    point throw a typed [System.UnauthorizedAccessException] carrying the
    PCX-E-STATE-ESCAPE code.

    Creating the tree is Initialize-PcxState (write paths only). Read-only
    commands such as doctor call Get-PcxStateRoot / Get-PcxStatePath and report
    whether it exists instead of creating it.
#>

Set-StrictMode -Version 2.0

function Get-PcxStateRoot {
    <#
    .SYNOPSIS
        Returns the normalized absolute state root (%LOCALAPPDATA%\pcx).
    #>
    $localAppData = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw [System.InvalidOperationException]::new('PCX-E-STATE-ROOT: LOCALAPPDATA is not set; pcx state has no per-user location.')
    }

    $root = [System.IO.Path]::GetFullPath((Join-Path -Path $localAppData -ChildPath 'pcx'))
    return $root.TrimEnd([char]'\', [char]'/')
}

function Resolve-PcxStateContainedPath {
    <#
    .SYNOPSIS
        Internal: validates that a candidate path is strictly under the state root.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Candidate
    )

    if ($Candidate -match '^[\\/]{2}') {
        throw [System.UnauthorizedAccessException]::new("PCX-E-STATE-ESCAPE: UNC path '$Candidate' is not under the pcx state root.")
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char]'\', [char]'/')
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $prefix = $rootFull + $separator
    if (-not $candidateFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [System.UnauthorizedAccessException]::new("PCX-E-STATE-ESCAPE: path '$candidateFull' is not under the pcx state root '$rootFull'.")
    }

    # Reject reparse points anywhere between the root and the candidate.
    $relative = $candidateFull.Substring($prefix.Length)
    $current = $rootFull
    foreach ($segment in ($relative -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment)) {
            continue
        }
        $current = Join-Path -Path $current -ChildPath $segment
        if ([System.IO.Directory]::Exists($current)) {
            $attributes = [System.IO.File]::GetAttributes($current)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw [System.UnauthorizedAccessException]::new("PCX-E-STATE-ESCAPE: '$current' is a reparse point; the pcx state root must be plain directories.")
            }
        }
    }

    return $candidateFull
}

function Get-PcxStatePath {
    <#
    .SYNOPSIS
        Returns the absolute path of a state subdirectory or a file inside it.

    .PARAMETER Kind
        scans | journal | quarantine

    .PARAMETER ChildPath
        Optional path relative to the kind directory. Anything that resolves
        outside the state root throws.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('scans', 'journal', 'quarantine')][string] $Kind,
        [string] $ChildPath
    )

    if (-not [string]::IsNullOrEmpty($ChildPath)) {
        # Catch absolute, drive-qualified and UNC child paths before Join-Path,
        # which would otherwise silently re-root them (or collapse "\\" to "\").
        if ($ChildPath -match '^[\\/]{2}') {
            throw [System.UnauthorizedAccessException]::new("PCX-E-STATE-ESCAPE: UNC path '$ChildPath' is not a valid child of the pcx state root.")
        }
        if ([System.IO.Path]::IsPathRooted($ChildPath)) {
            throw [System.UnauthorizedAccessException]::new("PCX-E-STATE-ESCAPE: rooted path '$ChildPath' is not a valid child of the pcx state root.")
        }
        if ($ChildPath.Contains(':')) {
            throw [System.UnauthorizedAccessException]::new("PCX-E-STATE-ESCAPE: path '$ChildPath' contains a drive or stream separator and is not a valid child of the pcx state root.")
        }
    }

    $root = Get-PcxStateRoot
    $kindPath = Join-Path -Path $root -ChildPath $Kind

    $candidate = if ([string]::IsNullOrEmpty($ChildPath)) {
        $kindPath
    }
    else {
        Join-Path -Path $kindPath -ChildPath $ChildPath
    }

    return Resolve-PcxStateContainedPath -Root $root -Candidate $candidate
}

function Initialize-PcxState {
    <#
    .SYNOPSIS
        Creates %LOCALAPPDATA%\pcx and its subdirectories; returns their paths.

    .DESCRIPTION
        Call this from write paths only. Read-only commands must not create the
        state tree as a side effect.
    #>
    $root = Get-PcxStateRoot
    $null = [System.IO.Directory]::CreateDirectory($root)

    $paths = [ordered]@{ Root = $root }
    foreach ($kind in @('scans', 'journal', 'quarantine')) {
        $kindPath = Get-PcxStatePath -Kind $kind
        $null = [System.IO.Directory]::CreateDirectory($kindPath)
        $paths[$kind] = $kindPath
    }

    return [pscustomobject]$paths
}
