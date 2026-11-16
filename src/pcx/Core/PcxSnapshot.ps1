<#
.SYNOPSIS
    Value-level snapshot and restore engine for one typed target.

.DESCRIPTION
    This file owns the canonical semantic state of a single target and the
    inverse that puts it back. It never talks to the operating system: every
    observation and every mutation goes through the PcxPlatform boundary
    (Invoke-PcxPlatformRead / Write / Delete / Move), so the engine behaves
    identically against the test adapter and against the live machine.

    Public surface contributed to the Pcx module (exactly these four names):
        Get-PcxTargetState     observe one target's canonical semantic state
        New-PcxSnapshot        record a pre-state plus the expected post-state
        Compare-PcxState       compare two canonical states field by field
        Restore-PcxSnapshot    drift-gated inverse of a recorded snapshot

    State is value-level, per kind, with an exact field set:
        registry  { kind, path, name, exists, type, data }
        service   { kind, name, controlSet, exists, start }
        task      { kind, path, exists, enabled }
        file      { kind, path, exists, sha256, size, attributes }

    No key subtree, no hive, no file-content write. A registry snapshot is the
    existence, type and data of exactly one value; a service snapshot is the
    Start value plus the resolved boot control set; a task snapshot is enabled
    only; a file snapshot is the byte hash, size and attributes, never an ACL
    or an owner claim. Runtime state (service status, process id, dependents'
    state, task last-run state) is excluded by construction: the canonical
    projection copies only the fields listed above and drops everything else.

    A snapshot document is a plain ordered map that Write-PcxJsonAtomic can
    serialize and Read-PcxJson can read back with no live objects:
        { schema, kind, target, pre, post }

    Restore is drift-gated and has no force switch. It re-reads the target,
    refuses with PCX-E-SNAPSHOT-DRIFT if the current state differs from the
    recorded post-state, restores the pre-state, then re-reads and refuses
    with PCX-E-SNAPSHOT-CONFIRM unless the target now matches the pre-state.
    A service whose control set moved since the capture is refused earlier,
    with PCX-E-SNAPSHOT-CONTROLSET.
#>

Set-StrictMode -Version 2.0

$script:PcxSnapshotSchema = 'pcx-snapshot/1'

# ---------------------------------------------------------------------------
# Typed refusal
# ---------------------------------------------------------------------------

function Stop-PcxSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message
    )

    throw [System.InvalidOperationException]::new(('{0}: {1}' -f $Code, $Message))
}

# ---------------------------------------------------------------------------
# Shape helpers (accept ordered maps, hashtables and PSCustomObjects)
# ---------------------------------------------------------------------------

function Get-PcxSnapshotMember {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ($key -is [string] -and [string]::Equals($key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return ,$Object[$key]
            }
        }
        return $null
    }

    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return ,$property.Value
        }
    }

    return $null
}

function Test-PcxSnapshotMember {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ($key -is [string] -and [string]::Equals($key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-PcxSnapshotRequiredString {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $value = Get-PcxSnapshotMember -Object $Object -Name $Name
    if ($null -eq $value -or [string]::IsNullOrEmpty([string]$value)) {
        Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-TARGET' -Message "target.$Name is required."
    }

    return [string]$value
}

function Get-PcxSnapshotKind {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $kind = Get-PcxSnapshotMember -Object $Target -Name 'Kind'
    if ($null -eq $kind -or [string]::IsNullOrWhiteSpace([string]$kind)) {
        Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-TARGET' -Message 'target.Kind is required (registry, service, task or file).'
    }

    switch (([string]$kind).ToLowerInvariant()) {
        'registry' { return 'registry' }
        'service' { return 'service' }
        'task' { return 'task' }
        'file' { return 'file' }
    }

    Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-KIND' -Message "unknown target kind '$kind'; supported: registry, service, task, file."
}

function Copy-PcxSnapshotMap {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Object)

    $map = [ordered]@{}
    if ($null -eq $Object) {
        return $map
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $map[[string]$key] = $Object[$key]
        }
        return $map
    }

    foreach ($property in $Object.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

# ---------------------------------------------------------------------------
# Registry data normalization
# ---------------------------------------------------------------------------

function ConvertTo-PcxSnapshotRegistryData {
    param(
        [Parameter(Mandatory = $true)][string] $Type,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Data
    )

    if ($null -eq $Data) {
        return $null
    }

    switch ($Type.ToLowerInvariant()) {
        'binary' {
            if ($Data -is [byte[]]) {
                return [System.Convert]::ToBase64String($Data)
            }
            if ($Data -is [string]) {
                return $Data
            }
            # An adapter that returns a byte array through a function can hand
            # back an object[] of byte-valued elements; cast it back explicitly.
            return [System.Convert]::ToBase64String([byte[]]$Data)
        }
        'multistring' {
            return ,([string[]]@($Data))
        }
        'dword' {
            return [int]$Data
        }
        'qword' {
            return [long]$Data
        }
        default {
            return [string]$Data
        }
    }
}

function ConvertFrom-PcxSnapshotRegistryData {
    param(
        [Parameter(Mandatory = $true)][string] $Type,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Data
    )

    if ($null -eq $Data) {
        return $null
    }

    switch ($Type.ToLowerInvariant()) {
        'binary' {
            if ($Data -is [byte[]]) {
                return ,$Data
            }
            return ,([System.Convert]::FromBase64String([string]$Data))
        }
        'multistring' {
            return ,([string[]]@($Data))
        }
        'dword' {
            return [int]$Data
        }
        'qword' {
            return [long]$Data
        }
        default {
            return [string]$Data
        }
    }
}

# ---------------------------------------------------------------------------
# Canonical state projection
# ---------------------------------------------------------------------------

function Get-PcxSnapshotStateFieldOrder {
    param([Parameter(Mandatory = $true)][string] $Kind)

    switch ($Kind) {
        'registry' { return @('kind', 'path', 'name', 'exists', 'type', 'data') }
        'service' { return @('kind', 'name', 'controlSet', 'exists', 'start') }
        'task' { return @('kind', 'path', 'exists', 'enabled') }
        'file' { return @('kind', 'path', 'exists', 'sha256', 'size', 'attributes') }
    }

    return @('kind')
}

function ConvertTo-PcxSnapshotCanonicalState {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $State,
        [Parameter(Mandatory = $true)][string] $Kind
    )

    $exists = [bool](Get-PcxSnapshotMember -Object $State -Name 'Exists')

    switch ($Kind) {
        'registry' {
            $canonical = [ordered]@{
                kind   = 'registry'
                path   = [string](Get-PcxSnapshotMember -Object $State -Name 'Path')
                name   = [string](Get-PcxSnapshotMember -Object $State -Name 'Name')
                exists = $exists
                type   = $null
                data   = $null
            }

            if ($exists) {
                $type = [string](Get-PcxSnapshotMember -Object $State -Name 'Type')
                if ([string]::IsNullOrEmpty($type)) {
                    Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-STATE' -Message 'a present registry value has no type.'
                }
                $canonical['type'] = $type.ToLowerInvariant()
                $canonical['data'] = ConvertTo-PcxSnapshotRegistryData -Type $canonical['type'] -Data (Get-PcxSnapshotMember -Object $State -Name 'Data')
            }

            return $canonical
        }
        'service' {
            $canonical = [ordered]@{
                kind       = 'service'
                name       = [string](Get-PcxSnapshotMember -Object $State -Name 'Name')
                controlSet = $null
                exists     = $exists
                start      = $null
            }

            if ($exists) {
                $controlSet = Get-PcxSnapshotMember -Object $State -Name 'ControlSet'
                if ($null -ne $controlSet) {
                    $canonical['controlSet'] = [string]$controlSet
                }

                $start = Get-PcxSnapshotMember -Object $State -Name 'Start'
                if ($null -ne $start) {
                    $canonical['start'] = [int]$start
                }
            }

            return $canonical
        }
        'task' {
            $canonical = [ordered]@{
                kind    = 'task'
                path    = [string](Get-PcxSnapshotMember -Object $State -Name 'Path')
                exists  = $exists
                enabled = $null
            }

            if ($exists) {
                $enabled = Get-PcxSnapshotMember -Object $State -Name 'Enabled'
                if ($null -ne $enabled) {
                    $canonical['enabled'] = [bool]$enabled
                }
            }

            return $canonical
        }
        'file' {
            $canonical = [ordered]@{
                kind       = 'file'
                path       = [string](Get-PcxSnapshotMember -Object $State -Name 'Path')
                exists     = $exists
                sha256     = $null
                size       = $null
                attributes = $null
            }

            if ($exists) {
                $sha256 = Get-PcxSnapshotMember -Object $State -Name 'Sha256'
                if ($null -ne $sha256) {
                    $canonical['sha256'] = ([string]$sha256).ToLowerInvariant()
                }

                $size = Get-PcxSnapshotMember -Object $State -Name 'Size'
                if ($null -eq $size) {
                    $size = Get-PcxSnapshotMember -Object $State -Name 'Length'
                }
                if ($null -ne $size) {
                    $canonical['size'] = [long]$size
                }

                $attributes = Get-PcxSnapshotMember -Object $State -Name 'Attributes'
                if ($null -ne $attributes) {
                    $canonical['attributes'] = [string]$attributes
                }
            }

            return $canonical
        }
    }

    Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-KIND' -Message "unknown state kind '$Kind'."
}

# ---------------------------------------------------------------------------
# Target identity
# ---------------------------------------------------------------------------

function Get-PcxSnapshotIdentity {
    <#
    .SYNOPSIS
        Extracts the stable identity of a target for the snapshot document.

    .DESCRIPTION
        Intent fields (Type/Value/Start/Enabled) are deliberately not part of
        the identity. For a file the identity may carry an optional RestorePath:
        the engine never writes file bytes, so a restore that must bring bytes
        back has to be told where those bytes live. That path is identity-side
        data, not captured state.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Kind
    )

    switch ($Kind) {
        'registry' {
            return [ordered]@{
                kind = 'registry'
                path = (Get-PcxSnapshotRequiredString -Object $Target -Name 'Path')
                name = (Get-PcxSnapshotRequiredString -Object $Target -Name 'Name')
            }
        }
        'service' {
            return [ordered]@{
                kind = 'service'
                name = (Get-PcxSnapshotRequiredString -Object $Target -Name 'Name')
            }
        }
        'task' {
            return [ordered]@{
                kind = 'task'
                path = (Get-PcxSnapshotRequiredString -Object $Target -Name 'Path')
            }
        }
        'file' {
            $path = Get-PcxSnapshotRequiredString -Object $Target -Name 'Path'
            $identity = [ordered]@{
                kind = 'file'
                path = [System.IO.Path]::GetFullPath($path)
            }

            if (Test-PcxSnapshotMember -Object $Target -Name 'RestorePath') {
                $restorePath = [string](Get-PcxSnapshotMember -Object $Target -Name 'RestorePath')
                if (-not [string]::IsNullOrWhiteSpace($restorePath)) {
                    $identity['restorePath'] = [System.IO.Path]::GetFullPath($restorePath)
                }
            }

            return $identity
        }
    }

    Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-KIND' -Message "unknown target kind '$Kind'."
}

function New-PcxSnapshotReadTarget {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Identity)

    switch ([string]$Identity['kind']) {
        'registry' {
            return @{ Kind = 'registry'; Path = $Identity['path']; Name = $Identity['name'] }
        }
        'service' {
            return @{ Kind = 'service'; Name = $Identity['name'] }
        }
        'task' {
            return @{ Kind = 'task'; Path = $Identity['path'] }
        }
        'file' {
            return @{ Kind = 'file'; Path = $Identity['path'] }
        }
    }

    Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-KIND' -Message "unknown identity kind '$($Identity['kind'])'."
}

# ---------------------------------------------------------------------------
# Expected post-state
# ---------------------------------------------------------------------------

function Get-PcxSnapshotExpectedPost {
    <#
    .SYNOPSIS
        Derives the state a target's write fields are expected to produce.

    .DESCRIPTION
        Used when the caller records a snapshot before applying. The post-state
        is the deterministic result of the typed write: a registry value becomes
        present with the target's type and data, a service keeps its control set
        and takes the target's Start, a task keeps its path and takes the
        target's Enabled. A target with no write fields is a verification-only
        snapshot and its post-state equals its pre-state.

        This is what the post-state of a value that did not exist before means:
        pre.exists = false, post.exists = true with the intended type and data.
        Restore then deletes the value and confirms absence.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Kind,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Pre
    )

    $post = Copy-PcxSnapshotMap -Object $Pre

    switch ($Kind) {
        'registry' {
            if ((Test-PcxSnapshotMember -Object $Target -Name 'Type') -and (Test-PcxSnapshotMember -Object $Target -Name 'Value')) {
                $type = [string](Get-PcxSnapshotMember -Object $Target -Name 'Type')
                if (-not [string]::IsNullOrEmpty($type)) {
                    $post['exists'] = $true
                    $post['type'] = $type.ToLowerInvariant()
                    $post['data'] = ConvertTo-PcxSnapshotRegistryData -Type $post['type'] -Data (Get-PcxSnapshotMember -Object $Target -Name 'Value')
                }
            }
        }
        'service' {
            if (Test-PcxSnapshotMember -Object $Target -Name 'Start') {
                $post['exists'] = $true
                $post['start'] = [int](Get-PcxSnapshotMember -Object $Target -Name 'Start')
            }
        }
        'task' {
            if (Test-PcxSnapshotMember -Object $Target -Name 'Enabled') {
                $post['exists'] = $true
                $post['enabled'] = [bool](Get-PcxSnapshotMember -Object $Target -Name 'Enabled')
            }
        }
    }

    return $post
}

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

function Test-PcxSnapshotFieldEqual {
    param(
        [Parameter(Mandatory = $true)][string] $Field,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Left,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Right
    )

    if ($Field -eq 'data') {
        $leftText = ConvertTo-PcxCanonicalJson -InputObject $Left
        $rightText = ConvertTo-PcxCanonicalJson -InputObject $Right
        return [string]::Equals($leftText, $rightText, [System.StringComparison]::Ordinal)
    }

    if ($null -eq $Left -and $null -eq $Right) {
        return $true
    }

    if ($null -eq $Left -or $null -eq $Right) {
        return $false
    }

    if ($Field -eq 'exists' -or $Field -eq 'enabled') {
        return ([bool]$Left) -eq ([bool]$Right)
    }

    if ($Field -eq 'start' -or $Field -eq 'size') {
        return [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::Ordinal)
    }

    return [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------------------
# Public: observe
# ---------------------------------------------------------------------------

function Get-PcxTargetState {
    <#
    .SYNOPSIS
        Observes one target and returns its canonical semantic state.

    .DESCRIPTION
        The only read path is Invoke-PcxPlatformRead. The returned map is the
        exact per-kind field set; runtime state and any extra adapter fields are
        discarded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target
    )

    $kind = Get-PcxSnapshotKind -Target $Target
    $identity = Get-PcxSnapshotIdentity -Target $Target -Kind $kind
    $readTarget = New-PcxSnapshotReadTarget -Identity $identity
    $observed = Invoke-PcxPlatformRead -Target $readTarget

    return ConvertTo-PcxSnapshotCanonicalState -State $observed -Kind $kind
}

# ---------------------------------------------------------------------------
# Public: record
# ---------------------------------------------------------------------------

function New-PcxSnapshot {
    <#
    .SYNOPSIS
        Records a value-level snapshot: the pre-state and the post-state.

    .DESCRIPTION
        With no PreState the target is read now. With no PostState the expected
        post-state is derived from the target's typed write fields (see
        Get-PcxSnapshotExpectedPost). Callers that apply a change outside the
        engine's derivation (a file move, for example) pass the actual post-state
        read back after the change.

        The result is a plain ordered map: no live objects, safe for
        Write-PcxJsonAtomic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $false)][AllowNull()][object] $PreState,
        [Parameter(Mandatory = $false)][AllowNull()][object] $PostState
    )

    $kind = Get-PcxSnapshotKind -Target $Target
    $identity = Get-PcxSnapshotIdentity -Target $Target -Kind $kind

    if ($PSBoundParameters.ContainsKey('PreState') -and $null -ne $PreState) {
        $pre = ConvertTo-PcxSnapshotCanonicalState -State $PreState -Kind $kind
    }
    else {
        $pre = Get-PcxTargetState -Target $identity
    }

    if ($PSBoundParameters.ContainsKey('PostState') -and $null -ne $PostState) {
        $post = ConvertTo-PcxSnapshotCanonicalState -State $PostState -Kind $kind
    }
    else {
        $post = Get-PcxSnapshotExpectedPost -Target $Target -Kind $kind -Pre $pre
    }

    return [ordered]@{
        schema = $script:PcxSnapshotSchema
        kind   = $kind
        target = $identity
        pre    = $pre
        post   = $post
    }
}

# ---------------------------------------------------------------------------
# Public: compare
# ---------------------------------------------------------------------------

function Compare-PcxState {
    <#
    .SYNOPSIS
        Compares a recorded canonical state with a freshly observed one.

    .DESCRIPTION
        Returns a typed result: status 'equal', or status 'drift' with the first
        differing field in the per-kind field order and both values. The
        comparison is on semantic values, never on file bytes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Recorded,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Current
    )

    if ($null -eq $Recorded -or $null -eq $Current) {
        Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-TARGET' -Message 'both a recorded state and a current state are required.'
    }

    $recordedKind = Get-PcxSnapshotKind -Target $Recorded
    $currentKind = Get-PcxSnapshotKind -Target $Current
    if ($recordedKind -ne $currentKind) {
        return [ordered]@{
            status   = 'drift'
            kind     = $recordedKind
            field    = 'kind'
            recorded = $recordedKind
            current  = $currentKind
        }
    }

    $left = ConvertTo-PcxSnapshotCanonicalState -State $Recorded -Kind $recordedKind
    $right = ConvertTo-PcxSnapshotCanonicalState -State $Current -Kind $currentKind

    foreach ($field in (Get-PcxSnapshotStateFieldOrder -Kind $recordedKind)) {
        $recordedValue = Get-PcxSnapshotMember -Object $left -Name $field
        $currentValue = Get-PcxSnapshotMember -Object $right -Name $field
        if (-not (Test-PcxSnapshotFieldEqual -Field $field -Left $recordedValue -Right $currentValue)) {
            return [ordered]@{
                status   = 'drift'
                kind     = $recordedKind
                field    = $field
                recorded = $recordedValue
                current  = $currentValue
            }
        }
    }

    return [ordered]@{
        status = 'equal'
        kind   = $recordedKind
    }
}

# ---------------------------------------------------------------------------
# Restore helpers
# ---------------------------------------------------------------------------

function Restore-PcxSnapshotFile {
    <#
    .SYNOPSIS
        Restores a file target without ever writing file bytes.

    .DESCRIPTION
        Platform file writes do not exist, so the only byte-preserving restore
        is a move from a recorded RestorePath. A file the apply step created is
        removed. A file whose content changed in place cannot be restored and
        is refused, never approximated.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Identity,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Pre,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Post
    )

    if ([bool]$Pre['exists']) {
        if ([bool]$Post['exists']) {
            $sameContent = [string]::Equals([string]$Pre['sha256'], [string]$Post['sha256'], [System.StringComparison]::OrdinalIgnoreCase)
            $sameSize = [string]::Equals([string]$Pre['size'], [string]$Post['size'], [System.StringComparison]::Ordinal)
            $sameAttributes = [string]::Equals([string]$Pre['attributes'], [string]$Post['attributes'], [System.StringComparison]::OrdinalIgnoreCase)
            if ($sameContent -and $sameSize -and $sameAttributes) {
                return
            }

            Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-UNSUPPORTED' -Message 'the file changed in place; pcx never writes file bytes, so this content cannot be restored.'
        }

        if (-not (Test-PcxSnapshotMember -Object $Identity -Name 'restorePath')) {
            Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-UNSUPPORTED' -Message 'the file is gone and the snapshot has no restorePath; byte transport belongs to the caller that moved the bytes.'
        }

        $restorePath = [string](Get-PcxSnapshotMember -Object $Identity -Name 'restorePath')
        $source = Invoke-PcxPlatformRead -Target @{ Kind = 'file'; Path = $restorePath }
        if (-not [bool](Get-PcxSnapshotMember -Object $source -Name 'Exists')) {
            Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-UNSUPPORTED' -Message "the restore source '$restorePath' is absent."
        }

        $sourceSha256 = [string](Get-PcxSnapshotMember -Object $source -Name 'Sha256')
        if (-not [string]::Equals($sourceSha256, [string]$Pre['sha256'], [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-UNSUPPORTED' -Message "the restore source '$restorePath' does not match the recorded SHA-256."
        }

        $null = Invoke-PcxPlatformMove -Target @{
            Kind        = 'file'
            Path        = $restorePath
            Destination = [string]$Pre['path']
        }

        return
    }

    if ([bool]$Post['exists']) {
        $null = Invoke-PcxPlatformDelete -Target @{ Kind = 'file'; Path = [string]$Post['path'] }
    }
}

# ---------------------------------------------------------------------------
# Public: restore
# ---------------------------------------------------------------------------

function Restore-PcxSnapshot {
    <#
    .SYNOPSIS
        Restores one snapshot after proving the target is still in its
        recorded post-state.

    .DESCRIPTION
        Order is deliberate: re-read the target, refuse a moved control set
        before anything else for a service, refuse drift if the current state
        is not the recorded post-state, write the inverse, then re-read and
        refuse unless the target matches the recorded pre-state. There is no
        force switch; drift is terminal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Snapshot
    )

    if ($null -eq $Snapshot) {
        Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-TARGET' -Message 'a snapshot document is required.'
    }

    $kind = Get-PcxSnapshotKind -Target $Snapshot
    $identitySource = Get-PcxSnapshotMember -Object $Snapshot -Name 'Target'
    if ($null -eq $identitySource) {
        Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-TARGET' -Message 'the snapshot has no target identity.'
    }

    $identity = Get-PcxSnapshotIdentity -Target $identitySource -Kind $kind
    $pre = ConvertTo-PcxSnapshotCanonicalState -State (Get-PcxSnapshotMember -Object $Snapshot -Name 'Pre') -Kind $kind
    $post = ConvertTo-PcxSnapshotCanonicalState -State (Get-PcxSnapshotMember -Object $Snapshot -Name 'Post') -Kind $kind

    $current = Get-PcxTargetState -Target $identity

    if ($kind -eq 'service' -and [bool]$pre['exists']) {
        $recordedControlSet = [string]$pre['controlSet']
        if ([string]::IsNullOrEmpty($recordedControlSet)) {
            $recordedControlSet = [string]$post['controlSet']
        }

        if (-not [string]::IsNullOrEmpty($recordedControlSet)) {
            $currentControlSet = [string]$current['controlSet']
            if (-not [string]::Equals($currentControlSet, $recordedControlSet, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-CONTROLSET' -Message "the service control set moved from '$recordedControlSet' to '$currentControlSet'; restore refuses across a control-set change."
            }
        }
    }

    $comparison = Compare-PcxState -Recorded $post -Current $current
    if ([string]$comparison['status'] -ne 'equal') {
        Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-DRIFT' -Message "the target no longer matches the recorded post-state (field '$($comparison['field'])'); drift is terminal."
    }

    switch ($kind) {
        'registry' {
            if ([bool]$pre['exists']) {
                $null = Invoke-PcxPlatformWrite -Target @{
                    Kind  = 'registry'
                    Path  = [string]$identity['path']
                    Name  = [string]$identity['name']
                    Type  = [string]$pre['type']
                    Value = (ConvertFrom-PcxSnapshotRegistryData -Type ([string]$pre['type']) -Data $pre['data'])
                }
            }
            elseif ([bool]$post['exists']) {
                $null = Invoke-PcxPlatformDelete -Target @{
                    Kind = 'registry'
                    Path = [string]$identity['path']
                    Name = [string]$identity['name']
                }
            }
        }
        'service' {
            if (-not [bool]$pre['exists']) {
                Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-UNSUPPORTED' -Message 'a service that did not exist cannot be created by a restore.'
            }

            if ([int]$current['start'] -ne [int]$pre['start']) {
                $null = Invoke-PcxPlatformWrite -Target @{
                    Kind  = 'service'
                    Name  = [string]$identity['name']
                    Start = [int]$pre['start']
                }
            }
        }
        'task' {
            if (-not [bool]$pre['exists']) {
                Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-UNSUPPORTED' -Message 'a task that did not exist cannot be created by a restore.'
            }

            if ([bool]$current['enabled'] -ne [bool]$pre['enabled']) {
                $null = Invoke-PcxPlatformWrite -Target @{
                    Kind    = 'task'
                    Path    = [string]$identity['path']
                    Enabled = [bool]$pre['enabled']
                }
            }
        }
        'file' {
            Restore-PcxSnapshotFile -Identity $identity -Pre $pre -Post $post
        }
    }

    $after = Get-PcxTargetState -Target $identity
    $confirmation = Compare-PcxState -Recorded $pre -Current $after
    if ([string]$confirmation['status'] -ne 'equal') {
        Stop-PcxSnapshot -Code 'PCX-E-SNAPSHOT-CONFIRM' -Message "restore did not reproduce the recorded pre-state (field '$($confirmation['field'])' after '$($confirmation['recorded'])', observed '$($confirmation['current'])')."
    }

    return [ordered]@{
        status   = 'restored'
        kind     = $kind
        target   = $identity
        restored = $after
    }
}
