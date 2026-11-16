<#
.SYNOPSIS
    The pcx OS boundary: typed read, write, delete and move for registry,
    service, task and file targets.

.DESCRIPTION
    This file is the only place in the product that touches the operating
    system. Everything else (providers, snapshot, policy, apply, undo) calls the
    five names below and never a native cmdlet.

    Public surface contributed to the Pcx module (exactly these five names):
        Get-PcxPlatform            the active adapter descriptor
        Invoke-PcxPlatformRead     read one target's state
        Invoke-PcxPlatformWrite    apply one value-level change
        Invoke-PcxPlatformDelete   remove one registry value or one file
        Invoke-PcxPlatformMove     move one concrete path

    Target kinds (a target is any object exposing these members):
        registry  Path (HKCU:\ or HKLM:\ key), Name (a non-empty value name; the
                  key's default value is not addressable), Type, Value
        service   Name, Start (2, 3 or 4)
        task      Path (full task path including the task name), Enabled
        file      Path, Destination (move only)

    Fixture mode: when PCX_TEST_RUN is set, the real adapter never writes. The
    four public functions route every call to the adapter named by
    PCX_PLATFORM_MODULE (an absolute path that must define all five names); that
    adapter is expected to be tests/TestAdapter/PcxPlatform.Test.ps1, which
    keeps a JSON state file instead of touching the machine. When fixture mode
    is on and the adapter cannot be loaded, the call fails closed: there is no
    fallback to the real OS.

    Real writes are refused before any OS call when any of these holds:
        * PCX_TEST_RUN is set                              PCX-E-PLATFORM-TESTRUN
        * the module tree contains tests/.pcx-test-root    PCX-E-PLATFORM-TESTROOT
        * PCX_ALLOW_REAL_WRITES is not '1'                 PCX-E-PLATFORM-NOARM
    The arming capability IS the PCX_ALLOW_REAL_WRITES environment variable,
    set by pcx.ps1 only inside its try/finally window around `tune --apply` and
    `undo`. There is no token, nonce or signature: the marker and the sticky
    test sentinel are the structural guarantee, not a secret.

    The write surface is native cmdlets only, always with parameter binding and
    literal paths, so a target that contains a quote or an ampersand stays
    literal data:
        Set-ItemProperty, New-ItemProperty, Remove-ItemProperty,
        Set-Service, Enable-ScheduledTask, Disable-ScheduledTask, Remove-Item,
        and MoveFileEx (P/Invoke, from the cached Pcx.Runtime.NativeIo type that
        PcxJson.ps1 compiles).
    No console utility, no shell, no expression evaluation, no assembled command
    line.

    Reads are safe and are never refused: discovery and doctor need them.
#>

Set-StrictMode -Version 2.0

$script:PcxPlatformDirectory = $PSScriptRoot
$script:PcxPlatformSource = [System.IO.Path]::Combine($PSScriptRoot, 'PcxPlatform.ps1')
$script:PcxPlatformFunctions = @(
    'Get-PcxPlatform'
    'Invoke-PcxPlatformRead'
    'Invoke-PcxPlatformWrite'
    'Invoke-PcxPlatformDelete'
    'Invoke-PcxPlatformMove'
)
$script:PcxTestRootMarker = [System.IO.Path]::Combine('tests', '.pcx-test-root')

# Cached fixture-mode adapter source, keyed by resolved adapter path.
$script:PcxTestAdapterPath = $null
$script:PcxTestAdapterSource = $null

# ---------------------------------------------------------------------------
# Fixture mode resolution
# ---------------------------------------------------------------------------

function Test-PcxPlatformFixtureMode {
    <#
    .SYNOPSIS
        True when the sticky fixture-mode sentinel is set.
    #>
    return (-not [string]::IsNullOrEmpty($env:PCX_TEST_RUN))
}

function Resolve-PcxTestAdapterPath {
    <#
    .SYNOPSIS
        Resolves and validates PCX_PLATFORM_MODULE, or fails closed.
    #>
    $configuredPath = [string]$env:PCX_PLATFORM_MODULE
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        throw [System.InvalidOperationException]::new('PCX-E-PLATFORM-ADAPTER: PCX_TEST_RUN is set but PCX_PLATFORM_MODULE is empty; refusing to fall back to the real OS adapter.')
    }

    if (-not [System.IO.Path]::IsPathRooted($configuredPath)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-ADAPTER: PCX_PLATFORM_MODULE '$configuredPath' is not an absolute path.")
    }

    $adapterPath = [System.IO.Path]::GetFullPath($configuredPath)
    if (-not [System.IO.File]::Exists($adapterPath)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-ADAPTER: PCX_PLATFORM_MODULE '$adapterPath' does not exist.")
    }

    return $adapterPath
}

function Get-PcxTestAdapterSource {
    <#
    .SYNOPSIS
        Reads and validates the adapter source once per path.

    .DESCRIPTION
        PowerShell cannot import a .ps1 as a module, so the adapter is executed
        in a private scope (see Invoke-PcxPlatformAdapter). That scope dies with
        the call, so the adapter can never install itself over this file's
        functions. The source must parse and must define all five names before
        it is ever executed: a missing name is a refusal, never a silent
        fallback to this file's own functions.
    #>
    param([Parameter(Mandatory = $true)][string] $AdapterPath)

    if ($null -ne $script:PcxTestAdapterSource -and
        [string]::Equals($script:PcxTestAdapterPath, $AdapterPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $script:PcxTestAdapterSource
    }

    $script:PcxTestAdapterPath = $null
    $script:PcxTestAdapterSource = $null

    try {
        $source = [System.IO.File]::ReadAllText($AdapterPath, [System.Text.Encoding]::UTF8)
    }
    catch {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-ADAPTER: cannot read '$AdapterPath': $($_.Exception.Message)", $_.Exception)
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    $errorList = @($parseErrors)
    if ($errorList.Count -gt 0) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-ADAPTER: '$AdapterPath' does not parse: $($errorList[0].Message)")
    }

    $definedNames = @(
        $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name }
    )

    foreach ($requiredName in $script:PcxPlatformFunctions) {
        if ($definedNames -notcontains $requiredName) {
            throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-ADAPTER: the adapter '$AdapterPath' does not define '$requiredName'.")
        }
    }

    $script:PcxTestAdapterPath = $AdapterPath
    $script:PcxTestAdapterSource = $source
    return $script:PcxTestAdapterSource
}

function Invoke-PcxPlatformAdapter {
    <#
    .SYNOPSIS
        Runs one adapter operation with the target bound as a parameter.

    .DESCRIPTION
        The adapter is executed in a fresh private scope per call, so its helper
        functions resolve normally while its public names never shadow this
        file's. The target always travels through parameter binding, never
        through a command string.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $FunctionName,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Target
    )

    if ($script:PcxPlatformFunctions -notcontains $FunctionName) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-ADAPTER: '$FunctionName' is not a platform operation.")
    }

    $hasTarget = $PSBoundParameters.ContainsKey('Target')
    $adapterPath = Resolve-PcxTestAdapterPath
    $source = Get-PcxTestAdapterSource -AdapterPath $adapterPath

    $runner = {
        param([string] $AdapterSource, [string] $AdapterFunction, [object] $AdapterTarget, [bool] $BindTarget)

        . ([scriptblock]::Create($AdapterSource))
        if ($BindTarget) {
            return (& $AdapterFunction -Target $AdapterTarget)
        }

        return (& $AdapterFunction)
    }

    return (& $runner $source $FunctionName $Target $hasTarget)
}

# ---------------------------------------------------------------------------
# Write refusal
# ---------------------------------------------------------------------------

function Test-PcxPlatformTestRoot {
    <#
    .SYNOPSIS
        True when a directory in the ancestry contains tests/.pcx-test-root.
    #>
    param([Parameter(Mandatory = $true)][string] $StartDirectory)

    $current = [System.IO.Path]::GetFullPath($StartDirectory)
    while ($true) {
        if ([System.IO.File]::Exists([System.IO.Path]::Combine($current, $script:PcxTestRootMarker))) {
            return $true
        }

        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            return $false
        }

        $current = $parent
    }
}

function Assert-PcxPlatformWritable {
    <#
    .SYNOPSIS
        Throws a typed refusal unless a real OS write is allowed right now.

    .DESCRIPTION
        Runs before any OS call. The three refusals are independent: the marker
        keeps every test checkout inert even when the sentinel is cleared by
        hand, and the arming variable keeps a production checkout inert unless
        pcx.ps1 is inside its write window.
    #>
    param([Parameter(Mandatory = $true)][string] $Operation)

    if (-not [string]::IsNullOrEmpty($env:PCX_TEST_RUN)) {
        throw [System.UnauthorizedAccessException]::new("PCX-E-PLATFORM-TESTRUN: refusing to $Operation while PCX_TEST_RUN is set ('$($env:PCX_TEST_RUN)'); fixture mode never touches the OS.")
    }

    if (Test-PcxPlatformTestRoot -StartDirectory $script:PcxPlatformDirectory) {
        throw [System.UnauthorizedAccessException]::new("PCX-E-PLATFORM-TESTROOT: refusing to $Operation because this checkout contains $($script:PcxTestRootMarker); a test checkout can never make a real write, even with PCX_TEST_RUN cleared.")
    }

    if ($env:PCX_ALLOW_REAL_WRITES -ne '1') {
        throw [System.UnauthorizedAccessException]::new('PCX-E-PLATFORM-NOARM: refusing to ' + $Operation + " because the arming capability was not set by pcx.ps1 (PCX_ALLOW_REAL_WRITES must be '1').")
    }
}

# ---------------------------------------------------------------------------
# Target access helpers
# ---------------------------------------------------------------------------

function Get-PcxPlatformTargetValue {
    # A target is a hashtable or an object exposing the same members; both
    # shapes are accepted, and a missing member is $null, never an exception.
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
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

function Get-PcxPlatformRequiredString {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $value = Get-PcxPlatformTargetValue -Target $Target -Name $Name
    if ($null -eq $value -or [string]::IsNullOrEmpty([string]$value)) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: target.$Name is required.")
    }

    return [string]$value
}

function Get-PcxPlatformTargetKind {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $kind = Get-PcxPlatformTargetValue -Target $Target -Name 'Kind'
    if ($null -eq $kind -or [string]::IsNullOrWhiteSpace([string]$kind)) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Kind is required (registry, service, task or file).')
    }

    return [string]$kind
}

function Resolve-PcxPlatformRegistryPath {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $path = Get-PcxPlatformRequiredString -Target $Target -Name 'Path'
    if ($path -notmatch '^(?i)(HKCU|HKLM):\\') {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: registry path '$path' must start with HKCU:\ or HKLM:\.")
    }

    return $path
}

function Resolve-PcxPlatformServiceName {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $name = Get-PcxPlatformRequiredString -Target $Target -Name 'Name'
    if ($name.Contains('\') -or $name.Contains('/')) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: service name '$name' must not contain a path separator.")
    }

    return $name
}

function Resolve-PcxPlatformTaskParts {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $path = Get-PcxPlatformRequiredString -Target $Target -Name 'Path'
    if (-not $path.StartsWith('\')) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: task path '$path' must start with a backslash.")
    }

    $leaf = Split-Path -Leaf $path
    $directory = Split-Path -Parent $path
    if ([string]::IsNullOrEmpty($leaf) -or [string]::IsNullOrEmpty($directory)) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: task path '$path' must contain a task name.")
    }

    if (-not $directory.EndsWith('\')) {
        $directory = $directory + '\'
    }

    return [pscustomobject]@{ Path = $path; Directory = $directory; Name = $leaf }
}

function Resolve-PcxPlatformFilePath {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Target,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $path = Get-PcxPlatformRequiredString -Target $Target -Name $Name
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        throw [System.ArgumentException]::new("PCX-E-PLATFORM-TARGET: file path '$path' must be absolute.")
    }

    return [System.IO.Path]::GetFullPath($path)
}

function ConvertTo-PcxRegistryValueKind {
    param([Parameter(Mandatory = $true)][string] $Token)

    switch ($Token.ToLowerInvariant()) {
        'string' { return [Microsoft.Win32.RegistryValueKind]::String }
        'expandstring' { return [Microsoft.Win32.RegistryValueKind]::ExpandString }
        'dword' { return [Microsoft.Win32.RegistryValueKind]::DWord }
        'qword' { return [Microsoft.Win32.RegistryValueKind]::QWord }
        'binary' { return [Microsoft.Win32.RegistryValueKind]::Binary }
        'multistring' { return [Microsoft.Win32.RegistryValueKind]::MultiString }
    }

    throw [System.NotSupportedException]::new("PCX-E-PLATFORM-TARGET: unsupported registry value type '$Token'; allowed: string, expandstring, dword, qword, binary, multistring.")
}

function ConvertFrom-PcxRegistryValueKind {
    param([Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind] $Kind)

    switch ([string]$Kind) {
        'String' { return 'string' }
        'ExpandString' { return 'expandstring' }
        'DWord' { return 'dword' }
        'QWord' { return 'qword' }
        'Binary' { return 'binary' }
        'MultiString' { return 'multistring' }
        default { return ([string]$Kind).ToLowerInvariant() }
    }
}

function ConvertTo-PcxRegistryData {
    param(
        [Parameter(Mandatory = $true)][string] $TypeToken,
        [AllowNull()][object] $Value
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
                return $Value
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

    throw [System.NotSupportedException]::new("PCX-E-PLATFORM-TARGET: unsupported registry value type '$TypeToken'.")
}

# ---------------------------------------------------------------------------
# Real adapter: registry
# ---------------------------------------------------------------------------

function Find-PcxRegistryValueName {
    param(
        [Parameter(Mandatory = $true)][object] $Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Name
    )

    foreach ($candidate in $Key.GetValueNames()) {
        if ([string]::Equals($candidate, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $candidate
        }
    }

    return $null
}

function Read-PcxPlatformRegistryState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $path = Resolve-PcxPlatformRegistryPath -Target $Target
    $name = Get-PcxPlatformRequiredString -Target $Target -Name 'Name'

    $state = [ordered]@{
        kind   = 'registry'
        path   = $path
        name   = $name
        exists = $false
        type   = $null
        data   = $null
    }

    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -eq $key) {
        return [pscustomobject]$state
    }

    $resolvedName = Find-PcxRegistryValueName -Key $key -Name $name
    if ($null -eq $resolvedName) {
        return [pscustomobject]$state
    }

    $state.exists = $true
    $state.type = ConvertFrom-PcxRegistryValueKind -Kind $key.GetValueKind($resolvedName)
    $state.data = $key.GetValue($resolvedName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

    return [pscustomobject]$state
}

function Write-PcxPlatformRegistryState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $path = Resolve-PcxPlatformRegistryPath -Target $Target
    $name = Get-PcxPlatformRequiredString -Target $Target -Name 'Name'
    $typeToken = Get-PcxPlatformRequiredString -Target $Target -Name 'Type'
    $valueKind = ConvertTo-PcxRegistryValueKind -Token $typeToken
    $data = ConvertTo-PcxRegistryData -TypeToken $typeToken -Value (Get-PcxPlatformTargetValue -Target $Target -Name 'Value')

    if (-not (Test-Path -LiteralPath $path)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-TARGET: registry key '$path' does not exist; pcx never creates keys.")
    }

    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    $resolvedName = Find-PcxRegistryValueName -Key $key -Name $name

    if ($null -eq $resolvedName) {
        $null = New-ItemProperty -LiteralPath $path -Name $name -Value $data -PropertyType $valueKind -ErrorAction Stop
    }
    else {
        $null = Set-ItemProperty -LiteralPath $path -Name $resolvedName -Value $data -Type $valueKind -ErrorAction Stop
    }

    return [pscustomobject]@{ kind = 'registry'; path = $path; name = $name; applied = $true }
}

function Remove-PcxPlatformRegistryState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $path = Resolve-PcxPlatformRegistryPath -Target $Target
    $name = Get-PcxPlatformRequiredString -Target $Target -Name 'Name'

    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    $resolvedName = $null
    if ($null -ne $key) {
        $resolvedName = Find-PcxRegistryValueName -Key $key -Name $name
    }

    if ($null -eq $resolvedName) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: registry value '$name' does not exist under '$path'.")
    }

    Remove-ItemProperty -LiteralPath $path -Name $resolvedName -ErrorAction Stop

    return [pscustomobject]@{ kind = 'registry'; path = $path; name = $name; deleted = $true }
}

# ---------------------------------------------------------------------------
# Real adapter: service
# ---------------------------------------------------------------------------

function Get-PcxServiceControlSetName {
    <#
    .SYNOPSIS
        Resolves the boot control set (ControlSet00N) from HKLM\SYSTEM\Select.
    #>
    $select = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Select' -ErrorAction Stop
    $current = [int]$select.Current
    return ('ControlSet{0:D3}' -f $current)
}

function Read-PcxPlatformServiceState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $name = Resolve-PcxPlatformServiceName -Target $Target
    $controlSet = Get-PcxServiceControlSetName
    $path = 'HKLM:\SYSTEM\{0}\Services\{1}' -f $controlSet, $name

    $state = [ordered]@{
        kind       = 'service'
        name       = $name
        path       = $path
        controlSet = $controlSet
        exists     = $false
        start      = $null
    }

    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -eq $key) {
        return [pscustomobject]$state
    }

    $state.exists = $true
    $start = $key.GetValue('Start', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -ne $start) {
        $state.start = [int]$start
    }

    return [pscustomobject]$state
}

function Write-PcxPlatformServiceState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $name = Resolve-PcxPlatformServiceName -Target $Target
    $startValue = Get-PcxPlatformTargetValue -Target $Target -Name 'Start'
    if ($null -eq $startValue) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Start is required for a service write.')
    }

    $start = [int]$startValue
    $startupTypes = @{
        2 = 'Automatic'
        3 = 'Manual'
        4 = 'Disabled'
    }

    if (-not $startupTypes.ContainsKey($start)) {
        throw [System.NotSupportedException]::new("PCX-E-PLATFORM-TARGET: service Start $start cannot be expressed through Set-Service; allowed: 2 (Automatic), 3 (Manual), 4 (Disabled).")
    }

    $state = Read-PcxPlatformServiceState -Target $Target
    if (-not $state.exists) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: service '$name' does not exist.")
    }

    $null = Set-Service -Name $name -StartupType $startupTypes[$start] -ErrorAction Stop

    return [pscustomobject]@{ kind = 'service'; name = $name; path = $state.path; start = $start; applied = $true }
}

# ---------------------------------------------------------------------------
# Real adapter: task
# ---------------------------------------------------------------------------

function Read-PcxPlatformTaskState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $parts = Resolve-PcxPlatformTaskParts -Target $Target

    $state = [ordered]@{
        kind    = 'task'
        path    = $parts.Path
        exists  = $false
        enabled = $null
        state   = $null
    }

    $task = Get-ScheduledTask -TaskPath $parts.Directory -TaskName $parts.Name -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [pscustomobject]$state
    }

    $taskState = [string]$task.State
    $state.exists = $true
    $state.state = $taskState
    $state.enabled = -not [string]::Equals($taskState, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)

    return [pscustomobject]$state
}

function Write-PcxPlatformTaskState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $parts = Resolve-PcxPlatformTaskParts -Target $Target
    $enabledValue = Get-PcxPlatformTargetValue -Target $Target -Name 'Enabled'
    if ($null -eq $enabledValue) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Enabled is required for a task write.')
    }

    if ($enabledValue -isnot [bool]) {
        throw [System.ArgumentException]::new('PCX-E-PLATFORM-TARGET: target.Enabled must be a boolean for a task write.')
    }

    $enabled = [bool]$enabledValue
    $state = Read-PcxPlatformTaskState -Target $Target
    if (-not $state.exists) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: scheduled task '$($parts.Path)' does not exist.")
    }

    if ($enabled) {
        $null = Enable-ScheduledTask -TaskPath $parts.Directory -TaskName $parts.Name -ErrorAction Stop
    }
    else {
        $null = Disable-ScheduledTask -TaskPath $parts.Directory -TaskName $parts.Name -ErrorAction Stop
    }

    return [pscustomobject]@{ kind = 'task'; path = $parts.Path; enabled = $enabled; applied = $true }
}

# ---------------------------------------------------------------------------
# Real adapter: file
# ---------------------------------------------------------------------------

# A directory size is a read-only walk. The cap keeps a pathological tree from
# turning one table row into an unbounded scan; a truncated walk is reported as
# a lower bound, never as an exact size.
$script:PcxPlatformDirectoryFileCap = 200000

function Measure-PcxPlatformDirectory {
    <#
    .SYNOPSIS
        Sums regular-file lengths under one directory, never following a
        reparse point.
    #>
    param([Parameter(Mandatory = $true)][string] $Path)

    $total = [long]0
    $files = 0
    $truncated = $false
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)

    while ($stack.Count -gt 0 -and -not $truncated) {
        $current = $stack.Pop()

        try {
            $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($current))
        }
        catch {
            $truncated = $true
            continue
        }

        foreach ($entry in $entries) {
            try {
                $attributes = [System.IO.File]::GetAttributes($entry)
            }
            catch {
                $truncated = $true
                continue
            }

            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push($entry)
                continue
            }

            try {
                $total += ([System.IO.FileInfo]::new($entry)).Length
            }
            catch {
                $truncated = $true
                continue
            }

            $files++
            if ($files -ge $script:PcxPlatformDirectoryFileCap) {
                $truncated = $true
                break
            }
        }
    }

    return [pscustomobject]@{
        size      = $total
        files     = $files
        truncated = $truncated
    }
}

function Read-PcxPlatformFileState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $path = Resolve-PcxPlatformFilePath -Target $Target -Name 'Path'

    $state = [ordered]@{
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

    $isFile = [System.IO.File]::Exists($path)
    $isDirectory = [System.IO.Directory]::Exists($path)
    if (-not ($isFile -or $isDirectory)) {
        return [pscustomobject]$state
    }

    $attributes = [System.IO.File]::GetAttributes($path)
    $state.exists = $true
    $state.attributes = $attributes.ToString()
    $state.isReparsePoint = (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    if ($isDirectory) {
        $measure = Measure-PcxPlatformDirectory -Path $path
        # A tree with nothing readable is not an empty tree: report no size so
        # the caller can say that the size needs administrator rights.
        if ($measure.files -gt 0 -or -not $measure.truncated) {
            $state.size = [long]$measure.size
        }
        $state.sizeTruncated = [bool]$measure.truncated
    }

    if ($isFile) {
        try {
            $state.length = ([System.IO.FileInfo]::new($path)).Length
        }
        catch {
            $state.length = $null
        }
        try {
            $state.sha256 = Get-PcxSha256 -Path $path
        }
        catch {
            # A file Windows holds open with a deny-read share (Explorer and
            # thumbcache_32.db) cannot be hashed. The read must not throw: the
            # provider decides per inverse from this explicit verdict — an A1
            # delete skips the file, a quarantine refuses it.
            $state.sha256 = $null
            $state.readStatus = 'unavailable'
            $state.readReason = $_.Exception.Message
        }
    }

    return [pscustomobject]$state
}

function Remove-PcxPlatformFileState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $path = Resolve-PcxPlatformFilePath -Target $Target -Name 'Path'

    if ([System.IO.Directory]::Exists($path)) {
        throw [System.NotSupportedException]::new("PCX-E-PLATFORM-OPERATION: '$path' is a directory; the platform deletes one concrete file at a time, a directory walk belongs to the provider that owns the root.")
    }

    if (-not [System.IO.File]::Exists($path)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: file '$path' does not exist.")
    }

    Remove-Item -LiteralPath $path -Force -ErrorAction Stop

    return [pscustomobject]@{ kind = 'file'; path = $path; deleted = $true }
}

function Move-PcxPlatformFileState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $source = Resolve-PcxPlatformFilePath -Target $Target -Name 'Path'
    $destination = Resolve-PcxPlatformFilePath -Target $Target -Name 'Destination'

    if (-not ([System.IO.File]::Exists($source) -or [System.IO.Directory]::Exists($source))) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-MISSING: '$source' does not exist.")
    }

    if ([System.IO.File]::Exists($destination) -or [System.IO.Directory]::Exists($destination)) {
        throw [System.InvalidOperationException]::new("PCX-E-PLATFORM-TARGET: destination '$destination' already exists; pcx never overwrites on move.")
    }

    $nativeIoType = 'Pcx.Runtime.NativeIo' -as [type]
    if ($null -eq $nativeIoType) {
        throw [System.InvalidOperationException]::new('PCX-E-PLATFORM-NATIVE: the cached Pcx.Runtime.NativeIo type is missing; PcxJson.ps1 must be loaded before PcxPlatform.ps1.')
    }

    $moveFileWriteThrough = [uint32]0x8
    if (-not [Pcx.Runtime.NativeIo]::MoveFileEx($source, $destination, $moveFileWriteThrough)) {
        $win32Error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [System.IO.IOException]::new("PCX-E-PLATFORM-MOVE: moving '$source' to '$destination' failed (Win32 error $win32Error).")
    }

    return [pscustomobject]@{ kind = 'file'; source = $source; destination = $destination; moved = $true }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

function Read-PcxPlatformState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    $kind = Get-PcxPlatformTargetKind -Target $Target
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

function Write-PcxPlatformState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    # First statement: no OS call happens before this refusal resolves.
    Assert-PcxPlatformWritable -Operation 'write'

    $kind = Get-PcxPlatformTargetKind -Target $Target
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

function Delete-PcxPlatformState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    Assert-PcxPlatformWritable -Operation 'delete'

    $kind = Get-PcxPlatformTargetKind -Target $Target
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

function Move-PcxPlatformState {
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    Assert-PcxPlatformWritable -Operation 'move'

    $kind = Get-PcxPlatformTargetKind -Target $Target
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

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

function Get-PcxPlatform {
    <#
    .SYNOPSIS
        Returns the active adapter descriptor.

    .DESCRIPTION
        In fixture mode this loads the adapter in PCX_PLATFORM_MODULE and returns
        that adapter's own descriptor, so there is one truth about which pathway
        is live. Otherwise it describes the real adapter; it never checks or
        changes write permission.
    #>
    if (Test-PcxPlatformFixtureMode) {
        return (Invoke-PcxPlatformAdapter -FunctionName 'Get-PcxPlatform')
    }

    return [pscustomobject]@{
        Name       = 'real'
        ModulePath = $script:PcxPlatformSource
        Functions  = @($script:PcxPlatformFunctions)
        StateFile  = $null
    }
}

function Invoke-PcxPlatformRead {
    <#
    .SYNOPSIS
        Reads one target's current state. Never a write, never refused.
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    if (Test-PcxPlatformFixtureMode) {
        return Invoke-PcxPlatformAdapter -FunctionName 'Invoke-PcxPlatformRead' -Target $Target
    }

    return Read-PcxPlatformState -Target $Target
}

function Invoke-PcxPlatformWrite {
    <#
    .SYNOPSIS
        Applies one value-level change to one target.
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    if (Test-PcxPlatformFixtureMode) {
        return Invoke-PcxPlatformAdapter -FunctionName 'Invoke-PcxPlatformWrite' -Target $Target
    }

    return Write-PcxPlatformState -Target $Target
}

function Invoke-PcxPlatformDelete {
    <#
    .SYNOPSIS
        Removes one registry value or one concrete file.
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    if (Test-PcxPlatformFixtureMode) {
        return Invoke-PcxPlatformAdapter -FunctionName 'Invoke-PcxPlatformDelete' -Target $Target
    }

    return Delete-PcxPlatformState -Target $Target
}

function Invoke-PcxPlatformMove {
    <#
    .SYNOPSIS
        Moves one concrete path to a destination that must not exist.
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Target)

    if (Test-PcxPlatformFixtureMode) {
        return Invoke-PcxPlatformAdapter -FunctionName 'Invoke-PcxPlatformMove' -Target $Target
    }

    return Move-PcxPlatformState -Target $Target
}
