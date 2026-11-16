<#
.SYNOPSIS
    Core suite for todo 2: canonical JSON, SHA-256, per-user state, envelope, doctor.
#>

BeforeAll {
    if ($env:PCX_TEST_RUN -ne '1') {
        throw "PCX_TEST_RUN must be '1' before the suite starts. Run tests through tests/run.ps1."
    }

    # Sticky fixture mode, re-asserted for every suite.
    $env:PCX_TEST_RUN = '1'

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../../')).Path
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Pcx.psm1'
    $entryScript = Join-Path -Path $repoRoot -ChildPath 'pcx.ps1'
    $jsonPath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Core/PcxJson.ps1'

    Import-Module -Name $modulePath -Force

    $hostExecutable = (Get-Process -Id $PID).Path

    function Invoke-PcxEntry {
        param([Parameter(Mandatory = $true)][string[]] $Arguments)

        $stdout = & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $entryScript @Arguments 2>$null

        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Lines    = @($stdout | Where-Object { $null -ne $_ -and ([string]$_).Trim().Length -gt 0 })
        }
    }

    # One fixture whose canonical form is pinned below, byte for byte, on both
    # PowerShell 5.1 and PowerShell 7.
    $script:canonicalFixture = [ordered]@{
        z      = 1
        a      = @(2, 'two', $true, $null)
        nested = [ordered]@{ b = 1.5; a = 'x' }
        bytes  = [byte[]](0, 1, 254, 255)
    }

    $script:canonicalExpected = @(
        '{'
        '  "a": ['
        '    2,'
        '    "two",'
        '    true,'
        '    null'
        '  ],'
        '  "bytes": "AAH+/w==",'
        '  "nested": {'
        '    "a": "x",'
        '    "b": 1.5'
        '  },'
        '  "z": 1'
        '}'
    ) -join "`n"

    # Pinned on PS 5.1.22621.4391 and PS 7.6.9: identical bytes on both hosts.
    $script:canonicalExpectedHash = 'a49f409b1b78f115174efefd40a5e9f85fc76a4d7628fce486a75579137ba576'
}

Describe 'pcx canonical JSON' {

    It 'sorts object keys ordinally, indents with two spaces, and uses LF only' {
        $text = ConvertTo-PcxCanonicalJson -InputObject $script:canonicalFixture

        $text | Should -BeExactly $script:canonicalExpected
        ([regex]::Matches($text, "`r")).Count | Should -Be 0
    }

    It 'produces the pinned cross-host hash for the fixed fixture' {
        $text = ConvertTo-PcxCanonicalJson -InputObject $script:canonicalFixture

        (Get-PcxSha256 -Text $text) | Should -BeExactly $script:canonicalExpectedHash
    }

    It 'does not change the hash when only key order changes' {
        $first = ConvertTo-PcxCanonicalJson -InputObject ([ordered]@{ b = 1; a = 2 })
        $second = ConvertTo-PcxCanonicalJson -InputObject ([ordered]@{ a = 2; b = 1 })

        $first | Should -BeExactly $second
        (Get-PcxSha256 -Text $first) | Should -BeExactly (Get-PcxSha256 -Text $second)
    }

    It 'canonicalizes nested objects and arrays deterministically' {
        $value = [ordered]@{
            outer = [ordered]@{
                list = @(@(1, 2), [ordered]@{ y = $false; x = $null })
                empty = @()
                emptyObject = [ordered]@{}
            }
        }

        $expected = @(
            '{'
            '  "outer": {'
            '    "empty": [],'
            '    "emptyObject": {},'
            '    "list": ['
            '      ['
            '        1,'
            '        2'
            '      ],'
            '      {'
            '        "x": null,'
            '        "y": false'
            '      }'
            '    ]'
            '  }'
            '}'
        ) -join "`n"

        ConvertTo-PcxCanonicalJson -InputObject $value | Should -BeExactly $expected
    }

    It 'serializes a byte array as base64' {
        $expected = @('{', '  "b": "AAH+/w=="', '}') -join "`n"

        ConvertTo-PcxCanonicalJson -InputObject ([ordered]@{ b = [byte[]](0, 1, 254, 255) }) | Should -BeExactly $expected
    }

    It 'rejects NaN instead of emitting invalid JSON' {
        { ConvertTo-PcxCanonicalJson -InputObject ([ordered]@{ x = [double]::NaN }) } |
            Should -Throw -ExceptionType ([System.NotSupportedException])
    }

    It 'never uses ConvertTo-Json for canonical output' {
        $source = [System.IO.File]::ReadAllText($jsonPath)
        # Ignore comments: the file's header documents the ban on that cmdlet.
        $code = [regex]::Replace($source, '(?s)<#.*?#>', '')
        $code = ($code -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        $code | Should -Not -Match 'ConvertTo-Json'
    }
}

Describe 'pcx SHA-256 and file IO' {

    It 'writes UTF-8 without BOM and with LF line endings' {
        $path = Join-Path -Path $TestDrive -ChildPath 'canonical.json'

        $null = Write-PcxJsonAtomic -Path $path -InputObject $script:canonicalFixture

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

        $hasBom | Should -BeFalse
        ($bytes -contains 0x0D) | Should -BeFalse
        (Get-PcxSha256 -Path $path) | Should -BeExactly $script:canonicalExpectedHash
    }

    It 'writes atomically, leaves no .tmp, and round-trips' {
        $path = Join-Path -Path $TestDrive -ChildPath 'atomic.json'
        $tempPath = $path + '.tmp'

        $null = Write-PcxJsonAtomic -Path $path -InputObject ([ordered]@{ status = 'ok'; count = 2 })

        [System.IO.File]::Exists($path) | Should -BeTrue
        [System.IO.File]::Exists($tempPath) | Should -BeFalse

        $read = Read-PcxJson -Path $path
        $read.status | Should -BeExactly 'ok'
        $read.count | Should -Be 2
    }

    It 'overwrites a stale .tmp left by an interrupted write' {
        $path = Join-Path -Path $TestDrive -ChildPath 'interrupted.json'
        $tempPath = $path + '.tmp'

        # Destination already holds a good previous document.
        $null = Write-PcxJsonAtomic -Path $path -InputObject ([ordered]@{ generation = 1 })
        $before = [System.IO.File]::ReadAllText($path)

        # Interrupted write: stale temp bytes, destination never replaced.
        [System.IO.File]::WriteAllBytes($tempPath, [byte[]](1..64))
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $before

        # The next write truncates the stale temp and moves the new document in.
        $null = Write-PcxJsonAtomic -Path $path -InputObject ([ordered]@{ generation = 2 })

        [System.IO.File]::Exists($tempPath) | Should -BeFalse
        (Read-PcxJson -Path $path).generation | Should -Be 2
    }

    It 'matches certutil -hashfile for the same file' {
        $path = Join-Path -Path $TestDrive -ChildPath 'certutil.json'
        $null = Write-PcxJsonAtomic -Path $path -InputObject ([ordered]@{ value = 'binary-safe' })

        $certutilHash = $null
        foreach ($line in (& certutil -hashfile $path SHA256)) {
            $candidate = ([string]$line) -replace '\s', ''
            if ($candidate -match '^[0-9a-fA-F]{64}$') {
                $certutilHash = $candidate.ToLowerInvariant()
                break
            }
        }

        $certutilHash | Should -Not -BeNullOrEmpty
        (Get-PcxSha256 -Path $path) | Should -BeExactly $certutilHash
    }

    It 'hashes the exact bytes of a byte array and the UTF-8 form of a string identically' {
        $text = '{"a":1}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)

        (Get-PcxSha256 -Bytes $bytes) | Should -BeExactly (Get-PcxSha256 -Text $text)
    }

    It 'fails typed on malformed JSON rather than returning $null' {
        $path = Join-Path -Path $TestDrive -ChildPath 'malformed.json'
        [System.IO.File]::WriteAllText($path, '{ not json ')

        { Read-PcxJson -Path $path } | Should -Throw -ExceptionType ([System.IO.InvalidDataException])
    }

    It 'fails typed when the JSON file does not exist' {
        $path = Join-Path -Path $TestDrive -ChildPath 'missing.json'

        { Read-PcxJson -Path $path } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }
}

Describe 'pcx per-user state' {

    It 'resolves the state root under LOCALAPPDATA' {
        $root = Get-PcxStateRoot
        $localAppData = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')

        $root | Should -Be (Join-Path -Path $localAppData -ChildPath 'pcx')
        (Get-PcxStatePath -Kind 'scans') | Should -Be (Join-Path -Path $root -ChildPath 'scans')
        (Get-PcxStatePath -Kind 'journal') | Should -Be (Join-Path -Path $root -ChildPath 'journal')
        (Get-PcxStatePath -Kind 'quarantine') | Should -Be (Join-Path -Path $root -ChildPath 'quarantine')
    }

    It 'throws a typed refusal for a traversal child path' {
        { Get-PcxStatePath -Kind 'scans' -ChildPath '..\..\evil.json' } |
            Should -Throw -ExceptionType ([System.UnauthorizedAccessException])
        { Get-PcxStatePath -Kind 'scans' -ChildPath '../../evil.json' } |
            Should -Throw -ExceptionType ([System.UnauthorizedAccessException])
    }

    It 'throws a typed refusal for a different-drive or UNC child path' {
        { Get-PcxStatePath -Kind 'scans' -ChildPath 'D:\evil.json' } |
            Should -Throw -ExceptionType ([System.UnauthorizedAccessException])
        { Get-PcxStatePath -Kind 'scans' -ChildPath '\\server\share\evil.json' } |
            Should -Throw -ExceptionType ([System.UnauthorizedAccessException])
    }

    It 'includes the escape reason in the message' {
        $message = $null
        try {
            $null = Get-PcxStatePath -Kind 'journal' -ChildPath '..\..\escape.json'
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should -Match 'PCX-E-STATE-ESCAPE'
    }

    It 'creates scans, journal and quarantine only when Initialize-PcxState runs' {
        $previous = $env:LOCALAPPDATA
        $sandbox = Join-Path -Path $TestDrive -ChildPath 'sandbox-localappdata'
        $null = [System.IO.Directory]::CreateDirectory($sandbox)

        try {
            $env:LOCALAPPDATA = $sandbox

            $root = Get-PcxStateRoot
            [System.IO.Directory]::Exists($root) | Should -BeFalse

            $created = Initialize-PcxState

            $created.Root | Should -Be $root
            [System.IO.Directory]::Exists($root) | Should -BeTrue
            [System.IO.Directory]::Exists((Join-Path -Path $root -ChildPath 'scans')) | Should -BeTrue
            [System.IO.Directory]::Exists((Join-Path -Path $root -ChildPath 'journal')) | Should -BeTrue
            [System.IO.Directory]::Exists((Join-Path -Path $root -ChildPath 'quarantine')) | Should -BeTrue
        }
        finally {
            $env:LOCALAPPDATA = $previous
        }
    }
}

Describe 'pcx envelope and doctor' {

    It 'returns status ok and the state dir for doctor' {
        $result = Invoke-PcxDispatch -Arguments @('doctor')

        $result.ExitCode | Should -Be 0
        $result.Envelope.status | Should -BeExactly 'ok'
        $result.Envelope.command | Should -BeExactly 'doctor'
        $result.Envelope.data.state.root | Should -Be (Get-PcxStateRoot)
        $result.Envelope.data.state.exists | Should -Be ([System.IO.Directory]::Exists((Get-PcxStateRoot)))
        $result.Envelope.data.powershell.version | Should -Not -BeNullOrEmpty
        $result.Envelope.data.fixture.active | Should -BeTrue
        @($result.Envelope.Keys) | Should -Be @('schema', 'version', 'status', 'command', 'exitCode', 'data', 'diagnostics')
    }

    It 'does not create the state dir as a side effect of doctor' {
        $root = Get-PcxStateRoot
        $existedBefore = [System.IO.Directory]::Exists($root)

        $null = Invoke-PcxDispatch -Arguments @('doctor')

        [System.IO.Directory]::Exists($root) | Should -Be $existedBefore
    }

    It 'refuses an unknown command with exit code 2 and status refused' {
        $result = Invoke-PcxEntry -Arguments @('bogus')

        $result.ExitCode | Should -Be 2
        $result.Lines.Count | Should -Be 1

        $envelope = $result.Lines[0] | ConvertFrom-Json
        $envelope.status | Should -BeExactly 'refused'
        $envelope.exitCode | Should -Be 2
        $envelope.diagnostics[0].code | Should -BeExactly 'PCX-E-COMMAND'
    }

    It 'keeps MoveFileExW inside PcxJson.ps1 (and later PcxPlatform.ps1) only' {
        $coreFiles = @(
            Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'src/pcx') -Recurse -File -Filter '*.ps1' |
                Where-Object { $_.Name -ne 'PcxJson.ps1' -and $_.Name -ne 'PcxPlatform.ps1' }
        )

        foreach ($file in $coreFiles) {
            $source = [System.IO.File]::ReadAllText($file.FullName)
            $source | Should -Not -Match 'MoveFileExW|MoveFileEx\(' -Because "$($file.Name) must not move files"
        }
    }
}
