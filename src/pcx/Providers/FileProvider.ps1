<#
.SYNOPSIS
    File write provider: A1 manifest delete and quarantine move.

.DESCRIPTION
    file: has exactly two actions.

    A1 (delete, irreversible):
      * a concrete file is deleted directly;
      * a directory is deleted file-by-file only after its explicit child tree
        is validated: every entry must exist, no entry may be a reparse point,
        a directory entry must carry Directory in its attributes, a file entry
        must be a regular file with a non-null SHA-256, and every child must be
        strictly inside its parent.
      * the platform boundary has no enumeration operation, so the tree is
        supplied by the caller in Children; the provider still validates every
        entry through Invoke-PcxPlatformRead and never trusts the list.
      * a manifest { path, sha256, size } per deleted entry is written to
        <LOCALAPPDATA>\pcx\journal\<PlanId>-a1-manifest.json. There is NO
        restore promise: the result says restorable = false and
        restoreMode = manifest-only.
      * Verify re-reads every manifest path and requires all absent; any
        residue means FAILED, never COMMITTED.

    Quarantine (inverse of a B action):
      * one concrete regular file inside a2_roots is moved to
        <LOCALAPPDATA>\pcx\quarantine\<PlanId>\<sha256>\<file name>;
      * source and destination must be on the same volume;
      * the directory is created by writing <dir>\quarantine.json through
        Write-PcxJsonAtomic before the move (no direct directory API);
      * Apply returns a snapshot with RestorePath, so Restore-PcxSnapshot moves
        the file back and proves byte identity with SHA-256 equality.

    Never a native cmdlet; the only OS mutation is Invoke-PcxPlatformDelete /
    Invoke-PcxPlatformMove.
#>

Set-StrictMode -Version 2.0

function Get-PcxFileProviderState {
    <#
    .SYNOPSIS
        Read: the canonical state of one concrete path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $null = Get-PcxProviderKind -Target $Target -Expected 'file'
    return Get-PcxTargetState -Target $Target
}

function Invoke-PcxFileProviderApply {
    <#
    .SYNOPSIS
        Apply: policy first, then A1 delete or quarantine move.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile
    )

    $null = Get-PcxProviderKind -Target $Target -Expected 'file'

    $decision = Test-PcxTarget -Target $Target -Profile $Profile
    if (-not [bool]$decision.allowed) {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $decision.target -Code $decision.code -Reason $decision.reason
    }

    $role = [string]$decision.target.role
    if ($role -eq 'quarantine') {
        return Invoke-PcxFileQuarantine -Target $Target -Profile $Profile -Canonical $decision.target
    }
    if ($role -eq 'a1') {
        return Invoke-PcxFileA1Delete -Target $Target -Profile $Profile -Canonical $decision.target
    }

    return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $decision.target -Code 'PCX-POLICY-FILE-ROLE' -Reason "unknown file role '$role'."
}

function Test-PcxFileProviderResult {
    <#
    .SYNOPSIS
        Verify: re-read the manifest paths (A1) or the source and quarantine
        copy (quarantine).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Result)

    if ($null -eq $Result) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-RESULT' -Message 'a provider result is required to verify a file target.'
    }

    $status = [string](Get-PcxSnapshotMember -Object $Result -Name 'status')
    $mode = [string](Get-PcxSnapshotMember -Object $Result -Name 'restoreMode')

    if ($mode -eq 'quarantine') {
        return Test-PcxFileQuarantineResult -Result $Result
    }

    return Test-PcxFileA1Result -Result $Result
}

# ---------------------------------------------------------------------------
# A1 delete
# ---------------------------------------------------------------------------

function New-PcxFileDeletePlan {
    <#
    .SYNOPSIS
        Validates an explicit directory tree and returns the concrete delete
        plan (one regular file per entry, with its SHA-256 and size).

    .DESCRIPTION
        A child whose bytes cannot be fingerprinted (readStatus unavailable)
        is never deleted what could not be proven: it is recorded in the
        -Skipped list with the OS reason and the walk continues. Every other
        invalid child still refuses the whole tree.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $DirectoryPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Children,
        [Parameter(Mandatory = $false)][AllowNull()][ref] $Skipped
    )

    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($child in $Children) {
        if ($null -eq $child) {
            continue
        }

        $declaredChildren = $null
        if ($child -is [string]) {
            $childPathRaw = [string]$child
        }
        else {
            $childPathRaw = [string](Get-PcxSnapshotMember -Object $child -Name 'Path')
            $declaredChildren = Get-PcxSnapshotMember -Object $child -Name 'Children'
        }

        $childPath = Resolve-PcxProviderAbsolutePath -Path $childPathRaw
        if (-not (Test-PcxProviderPathStrictlyUnder -Path $childPath -Root $DirectoryPath)) {
            Stop-PcxProvider -Code 'PCX-E-PROVIDER-FILE-TREE' -Message "child '$childPath' is not strictly inside '$DirectoryPath'."
        }

        $observed = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $childPath }
        if (-not [bool](Get-PcxSnapshotMember -Object $observed -Name 'Exists')) {
            Stop-PcxProvider -Code 'PCX-E-PROVIDER-FILE-TREE' -Message "child '$childPath' does not exist."
        }
        if ([bool](Get-PcxSnapshotMember -Object $observed -Name 'IsReparsePoint')) {
            Stop-PcxProvider -Code 'PCX-POLICY-REPARSE' -Message "child '$childPath' is a reparse point; pcx never follows one."
        }

        $attributes = [string](Get-PcxSnapshotMember -Object $observed -Name 'Attributes')
        $isDirectory = $attributes -match 'Directory'
        $hasChildren = $null -ne $declaredChildren

        if ($isDirectory -or $hasChildren) {
            if (-not $isDirectory) {
                Stop-PcxProvider -Code 'PCX-E-PROVIDER-FILE-TREE' -Message "child '$childPath' is not a directory but carries children."
            }
            if (-not $hasChildren) {
                Stop-PcxProvider -Code 'PCX-E-PROVIDER-FILE-TREE' -Message "directory '$childPath' has no explicit Children list; pcx never enumerates outside the platform boundary."
            }

            $nested = New-PcxFileDeletePlan -DirectoryPath $childPath -Children @($declaredChildren) -Skipped $Skipped
            foreach ($nestedEntry in $nested) {
                [void]$entries.Add($nestedEntry)
            }
            continue
        }

        $sha256 = Get-PcxSnapshotMember -Object $observed -Name 'Sha256'
        $length = Get-PcxSnapshotMember -Object $observed -Name 'Length'
        if ($null -eq $sha256 -or $null -eq $length) {
            $childReadStatus = [string](Get-PcxSnapshotMember -Object $observed -Name 'ReadStatus')
            if ([string]::Equals($childReadStatus, 'unavailable', [System.StringComparison]::OrdinalIgnoreCase)) {
                $childSkipReason = [string](Get-PcxSnapshotMember -Object $observed -Name 'ReadReason')
                if ([string]::IsNullOrWhiteSpace($childSkipReason)) {
                    $childSkipReason = 'the file could not be fingerprinted before deletion.'
                }
                if ($null -ne $Skipped) {
                    [void]$Skipped.Value.Add([ordered]@{
                            path   = $childPath
                            code   = 'PCX-E-PLATFORM-UNREADABLE'
                            reason = $childSkipReason
                        })
                }
                continue
            }
            Stop-PcxProvider -Code 'PCX-E-PROVIDER-FILE-TREE' -Message "child '$childPath' is not a regular file."
        }

        [void]$entries.Add([ordered]@{
                path   = $childPath
                sha256 = ([string]$sha256).ToLowerInvariant()
                size   = [long]$length
            })
    }

    return $entries.ToArray()
}

function Write-PcxFileA1Manifest {
    param(
        [Parameter(Mandatory = $true)][object] $Profile,
        [Parameter(Mandatory = $true)][string] $PlanId,
        [Parameter(Mandatory = $true)][string] $TargetPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Residue,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]] $Skipped = @()
    )

    $journal = [System.IO.Path]::Combine((Get-PcxProviderStateRoot -Profile $Profile), 'journal')
    $manifestPath = [System.IO.Path]::Combine($journal, ($PlanId + '-a1-manifest.json'))

    $document = [ordered]@{
        schema      = 'pcx-a1-manifest/1'
        planId      = $PlanId
        kind        = 'a1'
        restorable  = $false
        restoreMode = 'manifest-only'
        target      = $TargetPath
        entries     = @($Entries)
        residue     = @($Residue)
        skipped     = @($Skipped)
    }

    return Write-PcxJsonAtomic -Path $manifestPath -InputObject $document
}

function Invoke-PcxFileA1Delete {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Canonical
    )

    $path = Resolve-PcxProviderAbsolutePath -Path ([string](Get-PcxSnapshotMember -Object $Target -Name 'Path'))
    try {
        $planId = Resolve-PcxProviderPlanId -Target $Target
    }
    catch {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code (Get-PcxProviderErrorCode -ErrorRecord $_) -Reason $_.Exception.Message
    }

    $observed = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $path }
    if (-not [bool](Get-PcxSnapshotMember -Object $observed -Name 'Exists')) {
        # An absent A1 target is not a failure: the desired post-state (the file
        # is gone) already holds. It is reported as a skip so the item can
        # finish its remaining targets and the user sees the truth per file.
        $absentResult = New-PcxProviderResult -Status 'FAILED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-ALREADY-ABSENT' -Reason "the A1 target '$path' was already absent before the delete."
        $absentResult['skipped'] = @([ordered]@{
                path   = $path
                code   = 'PCX-E-PROVIDER-ALREADY-ABSENT'
                reason = 'already absent before the delete'
            })
        $absentResult['targetPath'] = $path
        $absentResult['planId'] = $planId
        return $absentResult
    }
    if ([bool](Get-PcxSnapshotMember -Object $observed -Name 'IsReparsePoint')) {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-POLICY-REPARSE' -Reason "the A1 target '$path' is a reparse point."
    }

    # Files the pre-state could not fingerprint are skipped, never deleted:
    # without a hash there is nothing to prove the delete against.
    $preSkipped = New-Object System.Collections.Generic.List[object]

    $attributes = [string](Get-PcxSnapshotMember -Object $observed -Name 'Attributes')
    if ($attributes -match 'Directory') {
        $childrenValue = Get-PcxSnapshotMember -Object $Target -Name 'Children'
        if ($null -eq $childrenValue) {
            return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-FILE-TREE' -Reason "directory '$path' has no explicit Children tree; pcx never enumerates outside the platform boundary."
        }

        try {
            $plan = @(New-PcxFileDeletePlan -DirectoryPath $path -Children @($childrenValue) -Skipped ([ref]$preSkipped))
        }
        catch {
            return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code (Get-PcxProviderErrorCode -ErrorRecord $_) -Reason $_.Exception.Message
        }
    }
    else {
        $sha256 = Get-PcxSnapshotMember -Object $observed -Name 'Sha256'
        $length = Get-PcxSnapshotMember -Object $observed -Name 'Length'
        if ($null -eq $sha256 -or $null -eq $length) {
            $singleReadStatus = [string](Get-PcxSnapshotMember -Object $observed -Name 'ReadStatus')
            if ([string]::Equals($singleReadStatus, 'unavailable', [System.StringComparison]::OrdinalIgnoreCase)) {
                $singleSkipReason = [string](Get-PcxSnapshotMember -Object $observed -Name 'ReadReason')
                if ([string]::IsNullOrWhiteSpace($singleSkipReason)) {
                    $singleSkipReason = 'the file could not be fingerprinted before deletion.'
                }
                [void]$preSkipped.Add([ordered]@{
                        path   = $path
                        code   = 'PCX-E-PLATFORM-UNREADABLE'
                        reason = $singleSkipReason
                    })
                $plan = @()
            }
            else {
                return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-FILE-TREE' -Reason "the A1 target '$path' is not a regular file."
            }
        }
        else {
            $plan = @([ordered]@{
                    path   = $path
                    sha256 = ([string]$sha256).ToLowerInvariant()
                    size   = [long]$length
                })
        }
    }

    $deleted = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $residue = New-Object System.Collections.Generic.List[string]
    $failureCode = $null
    $failureReason = $null

    # One file never aborts the rest: a locked (or otherwise undeletable) file
    # is recorded with the OS reason and the loop continues with the next file.
    # An already-absent file is not a failure either: the desired post-state
    # already holds, so it is recorded as skipped, never as residue.
    foreach ($entry in $plan) {
        $entryPath = [string]$entry['path']
        try {
            $null = Invoke-PcxPlatformDelete -Target @{ Kind = 'file'; Path = $entryPath }
            [void]$deleted.Add($entry)
        }
        catch {
            $skipCode = Get-PcxProviderErrorCode -ErrorRecord $_
            if ([string]::IsNullOrWhiteSpace($skipCode)) {
                $skipCode = 'PCX-E-PROVIDER'
            }
            $skipReason = [string]$_.Exception.Message
            if ($skipCode -eq 'PCX-E-PLATFORM-MISSING') {
                $skipReason = 'already absent: ' + $skipReason
            }
            [void]$skipped.Add([ordered]@{
                    path   = $entryPath
                    code   = $skipCode
                    reason = $skipReason
                })
        }
    }

    # Read-back: every entry we believe we deleted must be absent.
    foreach ($entry in $deleted) {
        $state = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = [string]$entry['path'] }
        if ([bool](Get-PcxSnapshotMember -Object $state -Name 'Exists')) {
            $presentPath = [string]$entry['path']
            if (-not $residue.Contains($presentPath)) {
                [void]$residue.Add($presentPath)
            }
        }
    }

    # ToArray, not @($list): PowerShell 5.1 throws over a generic List in an
    # array subexpression.
    $deletedEntries = $deleted.ToArray()
    $skippedEntries = @($preSkipped.ToArray()) + @($skipped.ToArray())
    $residuePaths = $residue.ToArray()

    $manifestPath = $null
    try {
        $manifestPath = Write-PcxFileA1Manifest -Profile $Profile -PlanId $PlanId -TargetPath $path -Entries $deletedEntries -Residue $residuePaths -Skipped $skippedEntries
    }
    catch {
        $failureCode = Get-PcxProviderErrorCode -ErrorRecord $_
        $failureReason = 'the A1 manifest could not be written: ' + $_.Exception.Message
    }

    $skipParts = New-Object System.Collections.Generic.List[string]
    foreach ($skippedEntry in $skippedEntries) {
        [void]$skipParts.Add(([string]$skippedEntry['path'] + ': ' + [string]$skippedEntry['reason']))
    }
    $skipDetails = ($skipParts -join '; ')

    $status = 'COMMITTED'
    $code = $null
    $reason = "deleted $($deletedEntries.Count) file(s); the manifest is manifest-only and not restorable."

    if ($null -ne $failureCode) {
        $status = 'FAILED'
        $code = $failureCode
        $reason = "delete did not complete: $failureReason Residue: $($residuePaths -join ', ')."
    }
    elseif ($residuePaths.Count -gt 0) {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-RESIDUE'
        $reason = "residue remains after the A1 delete: $($residuePaths -join ', ')."
    }
    elseif ($deletedEntries.Count -eq 0 -and $skippedEntries.Count -gt 0) {
        # Nothing was deleted: no partial success is claimed. The refusal
        # carries the first skipped file's typed code.
        $status = 'FAILED'
        $code = [string]$skippedEntries[0]['code']
        if ([string]::IsNullOrWhiteSpace($code)) {
            $code = 'PCX-E-PROVIDER'
        }
        $reason = Get-PcxText -Key 'apply.file.all-skipped' -FormatArgs @($skippedEntries.Count, $skipDetails)
    }
    elseif ($skippedEntries.Count -gt 0) {
        $reason = Get-PcxText -Key 'apply.file.partial' -FormatArgs @(($deletedEntries.Count), (($deletedEntries.Count + $skippedEntries.Count)), ($skippedEntries.Count), $skipDetails)
    }

    $result = New-PcxProviderResult -Status $status -Kind 'file' -Target $Canonical -Code $code -Reason $reason
    $result['manifest'] = $deletedEntries
    $result['manifestPath'] = $manifestPath
    $result['restorable'] = $false
    $result['restoreMode'] = 'manifest-only'
    $result['deleted'] = $deletedEntries
    $result['residue'] = $residuePaths
    $result['skipped'] = $skippedEntries
    $result['targetPath'] = $path
    $result['planId'] = $planId

    return $result
}

function Test-PcxFileA1Result {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Result)

    $manifestValue = Get-PcxSnapshotMember -Object $Result -Name 'manifest'
    $entries = @()
    if ($null -ne $manifestValue) {
        $entries = @($manifestValue)
    }

    $residue = New-Object System.Collections.Generic.List[string]
    $residueValue = Get-PcxSnapshotMember -Object $Result -Name 'residue'
    foreach ($recordedResidue in @($residueValue)) {
        if ($null -ne $recordedResidue -and -not $residue.Contains([string]$recordedResidue)) {
            [void]$residue.Add([string]$recordedResidue)
        }
    }

    foreach ($entry in $entries) {
        $entryPath = [string](Get-PcxSnapshotMember -Object $entry -Name 'path')
        $state = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $entryPath }
        if ([bool](Get-PcxSnapshotMember -Object $state -Name 'Exists')) {
            if (-not $residue.Contains($entryPath)) {
                [void]$residue.Add($entryPath)
            }
        }
    }

    $status = 'COMMITTED'
    $code = $null
    $reason = 'every manifest path is absent.'
    if ($residue.Count -gt 0) {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-RESIDUE'
        $reason = "A1 residue remains: $($residue -join ', ')."
    }
    elseif ([string](Get-PcxSnapshotMember -Object $Result -Name 'status') -ne 'COMMITTED') {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-VERIFY'
        $reason = 'the apply result was not COMMITTED; verify never promotes it.'
    }

    $skippedReport = @()
    $skippedValue = Get-PcxSnapshotMember -Object $Result -Name 'skipped'
    if ($null -ne $skippedValue) {
        $skippedReport = @($skippedValue)
    }

    $verification = New-PcxProviderResult -Status $status -Kind 'file' -Target (Get-PcxSnapshotMember -Object $Result -Name 'target') -Code $code -Reason $reason
    $verification['manifest'] = $entries
    $verification['manifestPath'] = Get-PcxSnapshotMember -Object $Result -Name 'manifestPath'
    $verification['restorable'] = $false
    $verification['restoreMode'] = 'manifest-only'
    $verification['deleted'] = $entries
    $verification['residue'] = $residue.ToArray()
    $verification['skipped'] = $skippedReport

    return $verification
}

# ---------------------------------------------------------------------------
# Quarantine
# ---------------------------------------------------------------------------

function Invoke-PcxFileQuarantine {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Profile,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Canonical
    )

    $source = Resolve-PcxProviderAbsolutePath -Path ([string](Get-PcxSnapshotMember -Object $Target -Name 'Path'))
    try {
        $planId = Resolve-PcxProviderPlanId -Target $Target
    }
    catch {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code (Get-PcxProviderErrorCode -ErrorRecord $_) -Reason $_.Exception.Message
    }

    $observed = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $source }
    if (-not [bool](Get-PcxSnapshotMember -Object $observed -Name 'Exists')) {
        return New-PcxProviderResult -Status 'FAILED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-MISSING' -Reason "the quarantine source '$source' does not exist."
    }
    if ([bool](Get-PcxSnapshotMember -Object $observed -Name 'IsReparsePoint')) {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-POLICY-REPARSE' -Reason "the quarantine source '$source' is a reparse point."
    }

    $attributes = [string](Get-PcxSnapshotMember -Object $observed -Name 'Attributes')
    if ($attributes -match 'Directory') {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-QUARANTINE-DIRECTORY' -Reason "the quarantine source '$source' is a directory; only a concrete file can be quarantined."
    }

    $quarantineReadStatus = [string](Get-PcxSnapshotMember -Object $observed -Name 'ReadStatus')
    if ([string]::Equals($quarantineReadStatus, 'unavailable', [System.StringComparison]::OrdinalIgnoreCase)) {
        $quarantineReadReason = [string](Get-PcxSnapshotMember -Object $observed -Name 'ReadReason')
        if ([string]::IsNullOrWhiteSpace($quarantineReadReason)) {
            $quarantineReadReason = 'the file could not be fingerprinted.'
        }
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-QUARANTINE' -Reason ("the quarantine source '$source' cannot be fingerprinted, so byte-for-byte preservation cannot be proven: " + $quarantineReadReason)
    }

    $sha256 = Get-PcxSnapshotMember -Object $observed -Name 'Sha256'
    $length = Get-PcxSnapshotMember -Object $observed -Name 'Length'
    if ($null -eq $sha256 -or $null -eq $length) {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-QUARANTINE' -Reason "the quarantine source '$source' is not a regular file."
    }

    $quarantineRoot = [System.IO.Path]::Combine((Get-PcxProviderStateRoot -Profile $Profile), 'quarantine')
    $hashDirectory = [System.IO.Path]::Combine([System.IO.Path]::Combine($quarantineRoot, $planId), ([string]$sha256).ToLowerInvariant())
    $destination = [System.IO.Path]::Combine($hashDirectory, [System.IO.Path]::GetFileName($source))
    $metadataPath = [System.IO.Path]::Combine($hashDirectory, 'quarantine.json')

    if ([string]::Equals($destination, $metadataPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-QUARANTINE' -Reason "the source file name collides with the quarantine metadata file."
    }

    $sourceRoot = [System.IO.Path]::GetPathRoot($source)
    $destinationRoot = [System.IO.Path]::GetPathRoot($destination)
    if (-not [string]::Equals($sourceRoot, $destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-PcxProviderResult -Status 'REFUSED' -Kind 'file' -Target $Canonical -Code 'PCX-E-PROVIDER-VOLUME' -Reason "the quarantine source '$sourceRoot' and destination '$destinationRoot' are on different volumes."
    }

    $pre = Get-PcxTargetState -Target @{ Kind = 'file'; Path = $source }

    # Create the destination directory through the sanctioned atomic writer:
    # Write-PcxJsonAtomic creates the parent directory as a side effect, so no
    # provider ever calls a directory API or a native cmdlet.
    try {
        $null = Write-PcxJsonAtomic -Path $metadataPath -InputObject ([ordered]@{
                schema      = 'pcx-quarantine/1'
                planId      = $planId
                source      = $source
                restorePath = $destination
                sha256      = ([string]$sha256).ToLowerInvariant()
                size        = [long]$length
            })
    }
    catch {
        return New-PcxProviderResult -Status 'FAILED' -Kind 'file' -Target $Canonical -Code (Get-PcxProviderErrorCode -ErrorRecord $_) -Reason ('the quarantine directory could not be prepared: ' + $_.Exception.Message)
    }

    try {
        $null = Invoke-PcxPlatformMove -Target @{ Kind = 'file'; Path = $source; Destination = $destination }
    }
    catch {
        return New-PcxProviderResult -Status 'FAILED' -Kind 'file' -Target $Canonical -Code (Get-PcxProviderErrorCode -ErrorRecord $_) -Reason ('the quarantine move failed: ' + $_.Exception.Message)
    }

    $post = Get-PcxTargetState -Target @{ Kind = 'file'; Path = $source }
    $snapshot = New-PcxSnapshot -Target @{ Kind = 'file'; Path = $source; RestorePath = $destination } -PreState $pre -PostState $post

    $sourceAfter = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $source }
    $destinationAfter = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $destination }
    $sourceAbsent = -not [bool](Get-PcxSnapshotMember -Object $sourceAfter -Name 'Exists')
    $destinationExists = [bool](Get-PcxSnapshotMember -Object $destinationAfter -Name 'Exists')
    $destinationSha = [string](Get-PcxSnapshotMember -Object $destinationAfter -Name 'Sha256')
    $expectedSha = [string]$pre['sha256']

    $status = 'COMMITTED'
    $code = $null
    $reason = 'the source is gone and the quarantine copy matches the recorded SHA-256.'
    if (-not ($sourceAbsent -and $destinationExists -and [string]::Equals($destinationSha, $expectedSha, [System.StringComparison]::OrdinalIgnoreCase))) {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-QUARANTINE'
        $reason = "the quarantine read-back failed (source absent: $sourceAbsent; destination exists: $destinationExists; SHA-256 match: $([string]::Equals($destinationSha, $expectedSha, [System.StringComparison]::OrdinalIgnoreCase)))."
    }

    $result = New-PcxProviderResult -Status $status -Kind 'file' -Target $Canonical -Code $code -Reason $reason
    $result['snapshot'] = $snapshot
    $result['pre'] = $pre
    $result['restorable'] = $true
    $result['restoreMode'] = 'quarantine'
    $result['restorePath'] = $destination
    $result['planId'] = $planId

    return $result
}

function Test-PcxFileQuarantineResult {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Result)

    $snapshot = Get-PcxSnapshotMember -Object $Result -Name 'snapshot'
    if ($null -eq $snapshot) {
        Stop-PcxProvider -Code 'PCX-E-PROVIDER-SNAPSHOT' -Message 'a quarantine result must carry a snapshot.'
    }

    $identity = Get-PcxSnapshotMember -Object $snapshot -Name 'target'
    $pre = Get-PcxSnapshotMember -Object $snapshot -Name 'pre'
    $source = [string](Get-PcxSnapshotMember -Object $identity -Name 'path')
    $restorePath = [string](Get-PcxSnapshotMember -Object $identity -Name 'restorePath')
    $expectedSha = [string]$pre['sha256']

    $sourceAfter = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $source }
    $destinationAfter = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $restorePath }
    $sourceAbsent = -not [bool](Get-PcxSnapshotMember -Object $sourceAfter -Name 'Exists')
    $destinationSha = [string](Get-PcxSnapshotMember -Object $destinationAfter -Name 'Sha256')
    $destinationExists = [bool](Get-PcxSnapshotMember -Object $destinationAfter -Name 'Exists')

    $status = 'COMMITTED'
    $code = $null
    $reason = 'the source is absent and the quarantine copy still matches the recorded SHA-256.'
    if (-not ($sourceAbsent -and $destinationExists -and [string]::Equals($destinationSha, $expectedSha, [System.StringComparison]::OrdinalIgnoreCase))) {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-VERIFY'
        $reason = 'the quarantine post-state no longer holds.'
    }
    elseif ([string](Get-PcxSnapshotMember -Object $Result -Name 'status') -ne 'COMMITTED') {
        $status = 'FAILED'
        $code = 'PCX-E-PROVIDER-VERIFY'
        $reason = 'the apply result was not COMMITTED; verify never promotes it.'
    }

    $verification = New-PcxProviderResult -Status $status -Kind 'file' -Target $identity -Code $code -Reason $reason
    $verification['snapshot'] = $snapshot
    $verification['restorable'] = $true
    $verification['restoreMode'] = 'quarantine'
    $verification['restorePath'] = $restorePath

    return $verification
}
