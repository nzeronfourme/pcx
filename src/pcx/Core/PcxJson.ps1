<#
.SYNOPSIS
    Canonical JSON, SHA-256, typed JSON reads, and atomic JSON writes.

.DESCRIPTION
    Every hashed or persisted state document goes through this file. Rules:

      * Canonical form: object keys sorted with an ordinal (case-sensitive)
        comparison of UTF-16 code units, which equals UTF-8 byte order for the
        BMP; no locale-dependent number formatting (InvariantCulture); lowercase
        true / false / null; two-space indent with LF ("`n") between tokens; no
        trailing newline. The writer never emits `\u003c`, `\u003e`, `\u0027`
        or `\u0026`, so PowerShell 5.1 and PowerShell 7 produce one identical
        byte stream.
      * Encoding: UTF-8 without BOM.
      * Numbers: integers and decimals use InvariantCulture; float/double use
        the invariant "G17" round-trip form. NaN and Infinity are not JSON and
        throw.
      * Binary: a byte[] value serializes as a base64 string.
      * Read: malformed JSON throws [System.IO.InvalidDataException]; it never
        returns a silent $null.
      * Write: <path>.tmp (FileMode::Create) -> FlushFileBuffers ->
        MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH). A crash
        before the move leaves the previous destination intact; the stale .tmp
        is overwritten by the next write. No delete API is used anywhere.
      * ConvertTo-Json is never used here: it is host-version dependent.

    MoveFileExW appears in this file and in PcxPlatform.ps1.
#>

Set-StrictMode -Version 2.0

$script:PcxUtf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$script:PcxMoveFileReplaceExisting = 0x1
$script:PcxMoveFileWriteThrough = 0x8

# Static, cached P/Invoke surface: compiled once per host process, never per call.
if ($null -eq ('Pcx.Runtime.NativeIo' -as [type])) {
    $nativeIoSource = @'
using System;
using System.Runtime.InteropServices;

namespace Pcx.Runtime
{
    public static class NativeIo
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool FlushFileBuffers(IntPtr hFile);
    }
}
'@
    Add-Type -TypeDefinition $nativeIoSource -Language CSharp
}

function ConvertTo-PcxCanonicalStringToken {
    # JSON string literal. Only quote, backslash and C0 controls are escaped, so
    # the output is byte-identical on every host (no \u003c style escaping).
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')

    foreach ($character in $Value.ToCharArray()) {
        switch ($character) {
            '"' { [void]$builder.Append('\"'); break }
            '\' { [void]$builder.Append('\\'); break }
            "`b" { [void]$builder.Append('\b'); break }
            "`f" { [void]$builder.Append('\f'); break }
            "`n" { [void]$builder.Append('\n'); break }
            "`r" { [void]$builder.Append('\r'); break }
            "`t" { [void]$builder.Append('\t'); break }
            default {
                $code = [int]$character
                if ($code -lt 0x20) {
                    [void]$builder.Append(('\u{0:x4}' -f $code))
                }
                else {
                    [void]$builder.Append($character)
                }
            }
        }
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-PcxCanonicalNumberToken {
    param([Parameter(Mandatory = $true)][object] $Value)

    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    if ($Value -is [double] -or $Value -is [single]) {
        $asDouble = [double]$Value
        if ([double]::IsNaN($asDouble) -or [double]::IsInfinity($asDouble)) {
            throw [System.NotSupportedException]::new('PCX-E-JSON-NUMBER: NaN and Infinity are not representable in canonical JSON.')
        }
        return $asDouble.ToString('G17', $culture)
    }

    return $Value.ToString($culture)
}

function Write-PcxCanonicalValue {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][int] $Depth,
        [Parameter(Mandatory = $true)][System.Text.StringBuilder] $Builder
    )

    $indent = '  ' * $Depth
    $childIndent = '  ' * ($Depth + 1)

    if ($null -eq $Value) {
        [void]$Builder.Append('null')
        return
    }

    if ($Value -is [string]) {
        [void]$Builder.Append((ConvertTo-PcxCanonicalStringToken -Value $Value))
        return
    }

    if ($Value -is [char]) {
        [void]$Builder.Append((ConvertTo-PcxCanonicalStringToken -Value ([string]$Value)))
        return
    }

    if ($Value -is [bool]) {
        [void]$Builder.Append($(if ($Value) { 'true' } else { 'false' }))
        return
    }

    if ($Value -is [byte[]]) {
        [void]$Builder.Append('"')
        [void]$Builder.Append([System.Convert]::ToBase64String($Value))
        [void]$Builder.Append('"')
        return
    }

    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        [void]$Builder.Append((ConvertTo-PcxCanonicalNumberToken -Value $Value))
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keyNames = New-Object System.Collections.Generic.List[string]
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string]) {
                throw [System.NotSupportedException]::new("PCX-E-JSON-KEY: canonical JSON object keys must be strings (found '$($key.GetType().FullName)').")
            }
            [void]$keyNames.Add([string]$key)
        }

        $sortedKeys = $keyNames.ToArray()
        [Array]::Sort($sortedKeys, [System.StringComparer]::Ordinal)

        [void]$Builder.Append('{')
        if ($sortedKeys.Length -eq 0) {
            [void]$Builder.Append('}')
            return
        }

        [void]$Builder.Append("`n")
        for ($index = 0; $index -lt $sortedKeys.Length; $index++) {
            $key = $sortedKeys[$index]
            [void]$Builder.Append($childIndent)
            [void]$Builder.Append((ConvertTo-PcxCanonicalStringToken -Value $key))
            [void]$Builder.Append(': ')
            Write-PcxCanonicalValue -Value $Value[$key] -Depth ($Depth + 1) -Builder $Builder
            if ($index -lt ($sortedKeys.Length - 1)) {
                [void]$Builder.Append(',')
            }
            [void]$Builder.Append("`n")
        }
        [void]$Builder.Append($indent)
        [void]$Builder.Append('}')
        return
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)

        [void]$Builder.Append('[')
        if ($items.Count -eq 0) {
            [void]$Builder.Append(']')
            return
        }

        [void]$Builder.Append("`n")
        for ($index = 0; $index -lt $items.Count; $index++) {
            [void]$Builder.Append($childIndent)
            Write-PcxCanonicalValue -Value $items[$index] -Depth ($Depth + 1) -Builder $Builder
            if ($index -lt ($items.Count - 1)) {
                [void]$Builder.Append(',')
            }
            [void]$Builder.Append("`n")
        }
        [void]$Builder.Append($indent)
        [void]$Builder.Append(']')
        return
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.MemberType -eq 'NoteProperty' -or $property.MemberType -eq 'Property') {
                $map[$property.Name] = $property.Value
            }
        }
        Write-PcxCanonicalValue -Value $map -Depth $Depth -Builder $Builder
        return
    }

    throw [System.NotSupportedException]::new("PCX-E-JSON-TYPE: value of type '$($Value.GetType().FullName)' has no canonical JSON representation.")
}

function ConvertTo-PcxCanonicalJson {
    <#
    .SYNOPSIS
        Serializes one value to canonical JSON text (UTF-8 friendly, LF, no BOM emphasis here).
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowNull()][object] $InputObject
    )

    $builder = New-Object System.Text.StringBuilder
    Write-PcxCanonicalValue -Value $InputObject -Depth 0 -Builder $builder
    return $builder.ToString()
}

function ConvertTo-PcxCanonicalUtf8Bytes {
    # Internal: canonical text encoded as UTF-8 without BOM.
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowNull()][object] $InputObject
    )

    return $script:PcxUtf8NoBom.GetBytes((ConvertTo-PcxCanonicalJson -InputObject $InputObject))
}

function Get-PcxSha256 {
    <#
    .SYNOPSIS
        Lowercase hex SHA-256 over exact bytes, a UTF-8 (no BOM) string, or a file.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Text')][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory = $true, ParameterSetName = 'Bytes')][AllowEmptyCollection()][byte[]] $Bytes,
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')][string] $Path
    )

    switch ($PSCmdlet.ParameterSetName) {
        'Bytes' { $data = $Bytes }
        'Text' { $data = $script:PcxUtf8NoBom.GetBytes($Text) }
        'Path' { $data = [System.IO.File]::ReadAllBytes([System.IO.Path]::GetFullPath($Path)) }
    }

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $algorithm.ComputeHash($data)
    }
    finally {
        $algorithm.Dispose()
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($hashByte in $hashBytes) {
        [void]$builder.Append($hashByte.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    return $builder.ToString()
}

function Read-PcxJson {
    <#
    .SYNOPSIS
        Reads one JSON file to a PowerShell object; throws typed on malformed input.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) {
        throw [System.IO.FileNotFoundException]::new("PCX-E-JSON-NOTFOUND: JSON file '$fullPath' does not exist.", $fullPath)
    }

    $text = [System.IO.File]::ReadAllText($fullPath, $script:PcxUtf8NoBom)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw [System.IO.InvalidDataException]::new("PCX-E-JSON-MALFORMED: JSON file '$fullPath' is empty.")
    }

    try {
        return ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new("PCX-E-JSON-MALFORMED: JSON file '$fullPath' could not be parsed: $($_.Exception.Message)", $_.Exception)
    }
}

function Write-PcxJsonAtomic {
    <#
    .SYNOPSIS
        Writes canonical JSON to <path> atomically via <path>.tmp + MoveFileExW.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][string] $Path,
        [Parameter(Mandatory = $true, Position = 1)][AllowNull()][object] $InputObject
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if ($directory -and -not [System.IO.Directory]::Exists($directory)) {
        $null = [System.IO.Directory]::CreateDirectory($directory)
    }

    $bytes = ConvertTo-PcxCanonicalUtf8Bytes -InputObject $InputObject
    $tempPath = $fullPath + '.tmp'

    # FileMode::Create truncates a stale .tmp from a previous interrupted write.
    $stream = [System.IO.FileStream]::new($tempPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $handle = $stream.SafeFileHandle.DangerousGetHandle()
        if (-not [Pcx.Runtime.NativeIo]::FlushFileBuffers($handle)) {
            $win32Error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw [System.IO.IOException]::new("PCX-E-WRITE-FLUSH: FlushFileBuffers failed for '$tempPath' (Win32 error $win32Error).")
        }
    }
    finally {
        $stream.Dispose()
    }

    $flags = [uint32]($script:PcxMoveFileReplaceExisting -bor $script:PcxMoveFileWriteThrough)
    if (-not [Pcx.Runtime.NativeIo]::MoveFileEx($tempPath, $fullPath, $flags)) {
        $win32Error = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [System.IO.IOException]::new("PCX-E-WRITE-MOVE: MoveFileExW failed moving '$tempPath' to '$fullPath' (Win32 error $win32Error). The stale temporary file is overwritten by the next write.")
    }

    return $fullPath
}
