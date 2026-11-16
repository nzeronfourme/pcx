<#
.SYNOPSIS
    pcx test platform adapter: the five platform operations over a JSON state
    file instead of the live OS.

.DESCRIPTION
    Loaded by src/pcx/Core/PcxPlatform.ps1 when PCX_TEST_RUN is set: the real
    adapter reads this file once and turns it into a dynamic module, then calls
    the same five names. Nothing here touches the registry, the service manager,
    the task scheduler or the file system; the only bytes written are the state
    file.

    State file: $env:PCX_TEST_STATE_FILE when set, otherwise
    %TEMP%\pcx-platform-test-state.json.

    Schema (every bucket is a JSON object; key presence means existence):
        registry: "<path lower>|<name lower>" -> { path, name, type, data }
                  type: string | expandstring | dword | qword | binary | multistring
                  binary data is base64, multistring data is an array.
        services: "<name lower>" -> { name, controlSet, start }
        tasks:    "<path lower>" -> { path, enabled, state }
        files:    "<path lower>" -> { path, contentBase64, attributes, isReparsePoint }
                  length and sha256 are derived from contentBase64, exactly as
                  the real adapter derives them from file bytes. A directory
                  record carries sizeBytes and may set sizeTruncated = true:
                  the real adapter sums the tree, the fixture takes the number.
                  A record may set unreadable = true to model a file Windows
                  holds open with a deny-read share: the read then returns
                  exists = true with sha256 = null plus readStatus =
                  'unavailable' and the OS-style readReason, and never throws —
                  mirroring the real adapter's verdict.

    Contract parity with the real adapter:
        * an absent target reads back exists = $false, never an error;
        * a write, delete or move on an absent target throws
          PCX-E-PLATFORM-MISSING;
        * file content is never written; file delete and move are the only
          file mutations;
        * an unknown target kind throws PCX-E-PLATFORM-KIND and an operation a
          kind does not support throws PCX-E-PLATFORM-OPERATION. Nothing
          succeeds by accident.

    This file keeps no script-scope state: every call reloads the state file.
#>

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------

function Get-PcxTestStatePath {
    <#
    .SYNOPSIS
        Resolves the state file path (env override, else a temp file).
    #>
    $configured = [string]$env:PCX_TEST_STATE_FILE
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return [System.IO.Path]::GetFullPath($configured)
    }

    return [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'pcx-platform-test-state.json')
}

function Get-PcxTestRecordValue {
    <#
    .SYNOPSIS
        Reads one member of a record without throwing when it is absent.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Record,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Record) {
        return $null
    }

    $property = $Record.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function ConvertFrom-PcxTestBucket {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Node)

    $map = @{}
    if ($null -eq $Node) {
        return $map
    }

    foreach ($property in $Node.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Read-PcxTestState {
    <#
    .SYNOPSIS
        Reads the whole state file; a missing file is an empty state.
    #>
    $state = [ordered]@{
        registry = @{}
        services = @{}
        tasks    = @{}
        files    = @{}
    }

    $path = Get-PcxTestStatePath
    if (-not [System.IO.File]::Exists($path)) {
        return $state
    }

    try {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    }
    catch {
        throw [System.IO.InvalidDataException]::new("PCX-E-PLATFORM-STATE: cannot read '$path': $($_.Exception.Message)", $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw [System.IO.InvalidDataException]::new("PCX-E-PLATFORM-STATE: '$path' is empty.")
    }

    try {
        $document = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new("PCX-E-PLATFORM-STATE: '$path' is not valid JSON: $($_.Exception.Message)", $_.Exception)
    }

    $state['registry'] = ConvertFrom-PcxTestBucket -Node (Get-PcxTestRecordValue -Record $document -Name 'registry')
    $state['services'] = ConvertFrom-PcxTestBucket -Node (Get-PcxTestRecordValue -Record $document -Name 'services')
    $state['tasks'] = ConvertFrom-PcxTestBucket -Node (Get-PcxTestRecordValue -Record $document -Name 'tasks')
    $state['files'] = ConvertFrom-PcxTestBucket -Node (Get-PcxTestRecordValue -Record $document -Name 'files')

    return $state
}

function Save-PcxTestState {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $State)

    $path = Get-PcxTestStatePath
    $directory = [System.IO.Path]::GetDirectoryName($path)
    if ($directory -and -not [System.IO.Directory]::Exists($directory)) {
        $null = [System.IO.Directory]::CreateDirectory($directory)
    }

    $document = [ordered]@{
        schema   = 'pcx-platform-test/1'
        registry = $State.registry
        services = $State.services
        tasks    = $State.tasks
        files    = $State.files
    }

    $text = ConvertTo-Json -InputObject $document -Depth 8 -Compress
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($path, $text, $utf8)
}

# ---------------------------------------------------------------------------
# Target access
# ---------------------------------------------------------------------------

function Get-PcxTestTargetValue {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($null -eq $Target) {
        return $null
    }

    try {
        $indexed = $Target[$Name]
        if ($null -ne $indexed) {
            # Unary comma: a byte[] or string[] value must not be enumerated by
            # the pipeline on its way out of this function.
            return ,$indexed
        }
    }
    catch {
        # Not indexable (a plain object): fall through to the member lookup.
    }

    $property = $Target.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return ,$property.Value
    }

    return $null
}

function Get-PcxTestTargetKind {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $kind = Get-PcxTestTargetValue -Target $Target -Name 'Kind'
    if ($null -eq $kind -or [string]::IsNullOrWhiteSpace([string]$kind)) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Kind is required (registry, service, task or file).')
    }

    return [string]$kind
}

function Get-PcxTestRequiredString {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $value = Get-PcxTestTargetValue -Target $Target -Name $Name
    if ($null -eq $value -or [string]::IsNullOrEmpty([string]$value)) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: target.$Name is required.")
    }

    return [string]$value
}

function Get-PcxTestRegistryKey {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Name
    )

    # Registry paths and value names are case-insensitive; 0x1F cannot appear in
    # a normal registry path and keeps path/name unambiguous.
    return ($Path.ToLowerInvariant() + [char]0x1F + $Name.ToLowerInvariant())
}

function Resolve-PcxTestRegistryPath {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Get-PcxTestRequiredString -Target $Target -Name 'Path'
    if ($path -notmatch '^(?i)(HKCU|HKLM):\\') {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: registry path '$path' must start with HKCU:\ or HKLM:\.")
    }

    return $path
}

function Resolve-PcxTestServiceName {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $name = Get-PcxTestRequiredString -Target $Target -Name 'Name'
    if ($name.Contains('\') -or $name.Contains('/')) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: service name '$name' must not contain a path separator.")
    }

    return $name
}

function Resolve-PcxTestTaskParts {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Get-PcxTestRequiredString -Target $Target -Name 'Path'
    if (-not $path.StartsWith('\')) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: task path '$path' must start with a backslash.")
    }

    return $path
}

function Resolve-PcxTestFilePath {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $path = Get-PcxTestRequiredString -Target $Target -Name $Name
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: file path '$path' must be absolute.")
    }

    return [System.IO.Path]::GetFullPath($path)
}

function ConvertTo-PcxTestRegistryData {
    param(
        [Parameter(Mandatory = $true)][string] $TypeToken,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value
    )

    if ($null -eq $Value) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: target.Value is required for registry type '$TypeToken'.")
    }

    try {
        switch ($TypeToken.ToLowerInvariant()) {
            'string' { return [string]$Value }
            'expandstring' { return [string]$Value }
            'dword' { return [int]$Value }
            'qword' { return [long]$Value }
            'multistring' { return [string[]]@($Value) }
            'binary' {
                if ($Value -isnot [byte[]]) {
                    throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: binary registry data must be a byte array.')
                }
                return [System.Convert]::ToBase64String($Value)
            }
        }
    }
    catch [System.InvalidCastException] {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: value is not valid for registry type '$TypeToken': $($_.Exception.Message)", $_.Exception)
    }
    catch [System.FormatException] {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: value is not valid for registry type '$TypeToken': $($_.Exception.Message)", $_.Exception)
    }
    catch [System.OverflowException] {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: value does not fit registry type '$TypeToken': $($_.Exception.Message)", $_.Exception)
    }

    throw [System.NotSupportedException]::new("PCX-E-PLATFORM-TARGET: unsupported registry value type '$TypeToken'; allowed: string, expandstring, dword, qword, binary, multistring.")
}

function ConvertFrom-PcxTestRegistryData {
    param(
        [Parameter(Mandatory = $true)][string] $TypeToken,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value
    )

    switch ($TypeToken.ToLowerInvariant()) {
        'dword' {
            if ($null -eq $Value) { return $null }
            return [int]$Value
        }
        'qword' {
            if ($null -eq $Value) { return $null }
            return [long]$Value
        }
        'binary' {
            if ($null -eq $Value -or ([string]$Value).Length -eq 0) { return [byte[]]@() }
            return [System.Convert]::FromBase64String([string]$Value)
        }
        'multistring' {
            if ($null -eq $Value) { return [string[]]@() }
            return [string[]]@($Value)
        }
        default {
            if ($null -eq $Value) { return $null }
            return [string]$Value
        }
    }
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

function Read-PcxPlatformRegistryState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Resolve-PcxTestRegistryPath -Target $Target
    $name = Get-PcxTestRequiredString -Target $Target -Name 'Name'
    $state = Read-PcxTestState
    $record = $state.registry[(Get-PcxTestRegistryKey -Path $path -Name $name)]

    $result = [ordered]@{
        kind   = 'registry'
        path   = $path
        name   = $name
        exists = $false
        type   = $null
        data   = $null
    }

    if ($null -eq $record) {
        return [pscustomobject]$result
    }

    $typeToken = [string](Get-PcxTestRecordValue -Record $record -Name 'type')
    $result.exists = $true
    $result.type = $typeToken
    $result.data = ConvertFrom-PcxTestRegistryData -TypeToken $typeToken -Value (Get-PcxTestRecordValue -Record $record -Name 'data')

    return [pscustomobject]$result
}

function Write-PcxPlatformRegistryState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Resolve-PcxTestRegistryPath -Target $Target
    $name = Get-PcxTestRequiredString -Target $Target -Name 'Name'
    $typeToken = (Get-PcxTestRequiredString -Target $Target -Name 'Type').ToLowerInvariant()
    $data = ConvertTo-PcxTestRegistryData -TypeToken $typeToken -Value (Get-PcxTestTargetValue -Target $Target -Name 'Value')

    $state = Read-PcxTestState
    $state.registry[(Get-PcxTestRegistryKey -Path $path -Name $name)] = [ordered]@{
        path = $path
        name = $name
        type = $typeToken
        data = $data
    }
    Save-PcxTestState -State $state

    return [pscustomobject]@{ kind = 'registry'; path = $path; name = $name; applied = $true }
}

function Remove-PcxPlatformRegistryState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Resolve-PcxTestRegistryPath -Target $Target
    $name = Get-PcxTestRequiredString -Target $Target -Name 'Name'
    $key = Get-PcxTestRegistryKey -Path $path -Name $name

    $state = Read-PcxTestState
    if (-not $state.registry.ContainsKey($key)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: registry value '$name' does not exist under '$path'.")
    }

    $null = $state.registry.Remove($key)
    Save-PcxTestState -State $state

    return [pscustomobject]@{ kind = 'registry'; path = $path; name = $name; deleted = $true }
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

function Read-PcxPlatformServiceState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $name = Resolve-PcxTestServiceName -Target $Target
    $state = Read-PcxTestState
    $record = $state.services[$name.ToLowerInvariant()]

    $result = [ordered]@{
        kind       = 'service'
        name       = $name
        path       = $null
        controlSet = $null
        exists     = $false
        start      = $null
    }

    if ($null -eq $record) {
        return [pscustomobject]$result
    }

    $controlSet = [string](Get-PcxTestRecordValue -Record $record -Name 'controlSet')
    $result.exists = $true
    $result.controlSet = $controlSet
    $result.path = 'HKLM:\SYSTEM\{0}\Services\{1}' -f $controlSet, $name

    $start = Get-PcxTestRecordValue -Record $record -Name 'start'
    if ($null -ne $start) {
        $result.start = [int]$start
    }

    return [pscustomobject]$result
}

function Write-PcxPlatformServiceState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $name = Resolve-PcxTestServiceName -Target $Target
    $startValue = Get-PcxTestTargetValue -Target $Target -Name 'Start'
    if ($null -eq $startValue) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Start is required for a service write.')
    }

    $start = [int]$startValue
    if ($start -lt 2 -or $start -gt 4) {
        throw [System.NotSupportedException]::new("PCX-E-PLATFORM-TARGET: service Start $start cannot be expressed through Set-Service; allowed: 2 (Automatic), 3 (Manual), 4 (Disabled).")
    }

    $state = Read-PcxTestState
    $key = $name.ToLowerInvariant()
    $record = $state.services[$key]
    if ($null -eq $record) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: service '$name' does not exist.")
    }

    $controlSet = [string](Get-PcxTestRecordValue -Record $record -Name 'controlSet')
    $state.services[$key] = [ordered]@{
        name       = $name
        controlSet = $controlSet
        start      = $start
    }
    Save-PcxTestState -State $state

    return [pscustomobject]@{ kind = 'service'; name = $name; path = ('HKLM:\SYSTEM\{0}\Services\{1}' -f $controlSet, $name); start = $start; applied = $true }
}

# ---------------------------------------------------------------------------
# Task
# ---------------------------------------------------------------------------

function Read-PcxPlatformTaskState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Resolve-PcxTestTaskParts -Target $Target
    $state = Read-PcxTestState
    $record = $state.tasks[$path.ToLowerInvariant()]

    $result = [ordered]@{
        kind    = 'task'
        path    = $path
        exists  = $false
        enabled = $null
        state   = $null
    }

    if ($null -eq $record) {
        return [pscustomobject]$result
    }

    $result.exists = $true
    $result.enabled = [bool](Get-PcxTestRecordValue -Record $record -Name 'enabled')
    $result.state = [string](Get-PcxTestRecordValue -Record $record -Name 'state')

    return [pscustomobject]$result
}

function Write-PcxPlatformTaskState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Resolve-PcxTestTaskParts -Target $Target
    $enabledValue = Get-PcxTestTargetValue -Target $Target -Name 'Enabled'
    if ($null -eq $enabledValue) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Enabled is required for a task write.')
    }

    if ($enabledValue -isnot [bool]) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Enabled must be a boolean for a task write.')
    }

    $enabled = [bool]$enabledValue
    $state = Read-PcxTestState
    $key = $path.ToLowerInvariant()
    if (-not $state.tasks.ContainsKey($key)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: scheduled task '$path' does not exist.")
    }

    $state.tasks[$key] = [ordered]@{
        path    = $path
        enabled = $enabled
        state   = $(if ($enabled) { 'Ready' } else { 'Disabled' })
    }
    Save-PcxTestState -State $state

    return [pscustomobject]@{ kind = 'task'; path = $path; enabled = $enabled; applied = $true }
}

# ---------------------------------------------------------------------------
# File
# ---------------------------------------------------------------------------

function Read-PcxPlatformFileState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Resolve-PcxTestFilePath -Target $Target -Name 'Path'
    $state = Read-PcxTestState
    $record = $state.files[$path.ToLowerInvariant()]

    $result = [ordered]@{
        kind           = 'file'
        path           = $path
        exists         = $false
        length         = $null
        size           = $null
        sizeTruncated  = $false
        sha256         = $null
        attributes     = $null
        isReparsePoint = $false
    }

    if ($null -eq $record) {
        return [pscustomobject]$result
    }

    $result.exists = $true
    $result.attributes = [string](Get-PcxTestRecordValue -Record $record -Name 'attributes')
    $result.isReparsePoint = [bool](Get-PcxTestRecordValue -Record $record -Name 'isReparsePoint')

    # A directory record carries its measured size explicitly: the fixture
    # never walks a live tree, so the table sees a deterministic number.
    $sizeBytes = Get-PcxTestRecordValue -Record $record -Name 'sizeBytes'
    if ($null -ne $sizeBytes) {
        $result.size = [long]$sizeBytes
    }
    $result.sizeTruncated = [bool](Get-PcxTestRecordValue -Record $record -Name 'sizeTruncated')

    $contentBase64 = [string](Get-PcxTestRecordValue -Record $record -Name 'contentBase64')
    if (-not [string]::IsNullOrEmpty($contentBase64)) {
        $content = [System.Convert]::FromBase64String($contentBase64)
        $result.length = $content.Length
        $result.sha256 = Get-PcxSha256 -Bytes $content
    }

    # Fixture-only unreadable-file model: the file exists and its metadata is
    # measurable, but its bytes cannot be hashed — exactly the verdict the
    # real adapter returns for a deny-read share. Never throws.
    if ([bool](Get-PcxTestRecordValue -Record $record -Name 'unreadable')) {
        $result.sha256 = $null
        $result['readStatus'] = 'unavailable'
        $result['readReason'] = 'fixture: The process cannot access the file because it is being used by another process.'
    }

    return [pscustomobject]$result
}

function Remove-PcxPlatformFileState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $path = Resolve-PcxTestFilePath -Target $Target -Name 'Path'
    $state = Read-PcxTestState
    $key = $path.ToLowerInvariant()
    if (-not $state.files.ContainsKey($key)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: file '$path' does not exist.")
    }

    # Fixture-only lock: a record may declare locked = true to model a file the
    # OS refuses to delete. The real adapter fails naturally on Windows.
    if ([bool](Get-PcxTestRecordValue -Record $state.files[$key] -Name 'locked')) {
        throw [System.IO.IOException]::new("PCX-E-PLATFORM-LOCKED: file '$path' is locked and cannot be deleted.")
    }

    $null = $state.files.Remove($key)
    Save-PcxTestState -State $state

    return [pscustomobject]@{ kind = 'file'; path = $path; deleted = $true }
}

function Move-PcxPlatformFileState {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Target)

    $source = Resolve-PcxTestFilePath -Target $Target -Name 'Path'
    $destination = Resolve-PcxTestFilePath -Target $Target -Name 'Destination'

    $state = Read-PcxTestState
    $sourceKey = $source.ToLowerInvariant()
    $destinationKey = $destination.ToLowerInvariant()

    if (-not $state.files.ContainsKey($sourceKey)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: '$source' does not exist.")
    }

    if ($state.files.ContainsKey($destinationKey)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-TARGET: destination '$destination' already exists; pcx never overwrites on move.")
    }

    $record = $state.files[$sourceKey]
    $null = $state.files.Remove($sourceKey)
    $state.files[$destinationKey] = [ordered]@{
        path           = $destination
        contentBase64  = [string](Get-PcxTestRecordValue -Record $record -Name 'contentBase64')
        attributes     = [string](Get-PcxTestRecordValue -Record $record -Name 'attributes')
        isReparsePoint = [bool](Get-PcxTestRecordValue -Record $record -Name 'isReparsePoint')
    }
    Save-PcxTestState -State $state

    return [pscustomobject]@{ kind = 'file'; source = $source; destination = $destination; moved = $true }
}

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

function Get-PcxPlatform {
    <#
    .SYNOPSIS
        Describes this adapter. Never a write.
    #>
    return [pscustomobject]@{
        Name       = 'test'
        ModulePath = [string]$env:PCX_PLATFORM_MODULE
        Functions  = @(
            'Get-PcxPlatform'
            'Invoke-PcxPlatformRead'
            'Invoke-PcxPlatformWrite'
            'Invoke-PcxPlatformDelete'
            'Invoke-PcxPlatformMove'
        )
        StateFile  = (Get-PcxTestStatePath)
    }
}

function Invoke-PcxPlatformRead {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $kind = Get-PcxTestTargetKind -Target $Target
    switch ($kind) {
        'registry' { return Read-PcxPlatformRegistryState -Target $Target }
        'service' { return Read-PcxPlatformServiceState -Target $Target }
        'task' { return Read-PcxPlatformTaskState -Target $Target }
        'file' { return Read-PcxPlatformFileState -Target $Target }
        default {
            throw [System.NotSupportedException]::new("PCX-E-PLATFORM-KIND: unknown target kind '$kind'; supported: registry, service, task, file.")
        }
    }
}

function Invoke-PcxPlatformWrite {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $kind = Get-PcxTestTargetKind -Target $Target
    switch ($kind) {
        'registry' { return Write-PcxPlatformRegistryState -Target $Target }
        'service' { return Write-PcxPlatformServiceState -Target $Target }
        'task' { return Write-PcxPlatformTaskState -Target $Target }
        'file' {
            throw [System.NotSupportedException]::new('PCX-E-PLATFORM-OPERATION: file content is never written by the platform; use Invoke-PcxPlatformMove for byte transport or Invoke-PcxPlatformDelete for removal.')
        }
        default {
            throw [System.NotSupportedException]::new("PCX-E-PLATFORM-KIND: unknown target kind '$kind'; supported: registry, service, task, file.")
        }
    }
}

function Invoke-PcxPlatformDelete {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $kind = Get-PcxTestTargetKind -Target $Target
    switch ($kind) {
        'registry' { return Remove-PcxPlatformRegistryState -Target $Target }
        'file' { return Remove-PcxPlatformFileState -Target $Target }
        'service' {
            throw [System.NotSupportedException]::new('PCX-E-PLATFORM-OPERATION: services are never deleted; only Start changes.')
        }
        'task' {
            throw [System.NotSupportedException]::new('PCX-E-PLATFORM-OPERATION: scheduled tasks are never deleted; only enabled changes.')
        }
        default {
            throw [System.NotSupportedException]::new("PCX-E-PLATFORM-KIND: unknown target kind '$kind'; supported: registry, service, task, file.")
        }
    }
}

function Invoke-PcxPlatformMove {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $kind = Get-PcxTestTargetKind -Target $Target
    switch ($kind) {
        'file' { return Move-PcxPlatformFileState -Target $Target }
        default {
            if ($kind -in @('registry', 'service', 'task')) {
                throw [System.NotSupportedException]::new("PCX-E-PLATFORM-OPERATION: a $kind target cannot be moved.")
            }
            throw [System.NotSupportedException]::new("PCX-E-PLATFORM-KIND: unknown target kind '$kind'; supported: registry, service, task, file.")
        }
    }
}
