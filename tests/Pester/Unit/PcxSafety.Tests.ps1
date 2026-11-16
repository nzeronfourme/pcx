<#
.SYNOPSIS
    Static safety scan and documentation contract (todo 15).

.DESCRIPTION
    The plan's verification scan (line 96) applied to the whole product:

      * no direct OS write cmdlet outside PcxPlatform.ps1; the only exception is
        PcxJson.Write-PcxJsonAtomic writing its own temp file,
      * no Invoke-Expression, no bcdedit /set, no .reg merge,
      * no Remove-Item outside PcxPlatform.ps1,
      * MoveFileEx/MoveFileExW only in PcxPlatform.ps1 and PcxJson.ps1,
      * no reg.exe / sc.exe / schtasks.exe / cmd /c / standalone -Command,
      * no ri / del / rm / erase aliases and no [IO.File]::Delete or
        [IO.Directory]::Delete,
      * byte transport only in PcxJson.ps1, one Start-Process -Verb RunAs site
        per write path, and no HTML.

    The documentation contract proves the skill implements the three-step
    script in 200 lines or fewer, the catalog reference mirrors
    config/actions/*.json, and INSTALL.md is a pinned manifest whose SHA-256
    values match the working tree with no binary and no .omo/ path.
#>

BeforeAll {
    if ($env:PCX_TEST_RUN -ne '1') {
        throw "PCX_TEST_RUN must be '1' before the suite starts. Run tests through tests/run.ps1."
    }

    $env:PCX_TEST_RUN = '1'

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../../')).Path
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'src/pcx/Pcx.psm1'
    $testAdapterPath = Join-Path -Path $repoRoot -ChildPath 'tests/TestAdapter/PcxPlatform.Test.ps1'

    $env:PCX_PLATFORM_MODULE = (Resolve-Path -LiteralPath $testAdapterPath).Path
    $env:PCX_ALLOW_REAL_WRITES = $null

    Import-Module -Name $modulePath -Force
    $script:Sha256 = (Get-Module -Name 'Pcx').ExportedCommands['Get-PcxSha256']

    $script:RepoRoot = $repoRoot.TrimEnd([char]'\', [char]'/')
    $script:PlatformFile = 'PcxPlatform.ps1'
    $script:JsonFile = 'PcxJson.ps1'

    $productFiles = @()
    $productFiles += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pcx') -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    $productFiles += @(Get-Item -LiteralPath (Join-Path $repoRoot 'pcx.ps1'))

    $script:ProductFiles = @(
        $productFiles |
            Sort-Object -Property FullName |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    Path = $_.FullName
                    Text = [System.IO.File]::ReadAllText($_.FullName)
                }
            }
    )

    $script:ProductWriteCmdlets = @(
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty'
        'Set-Item', 'New-Item', 'Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Clear-Item'
        'Set-Service', 'Start-Service', 'Stop-Service', 'New-Service', 'Remove-Service'
        'Set-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask'
        'Enable-ScheduledTask', 'Disable-ScheduledTask'
        'Set-Content', 'Add-Content', 'Out-File', 'Set-Acl'
    )

    function Get-PcxSafetyRelativePath {
        # Path.GetRelativePath is .NET Core only; every scanned file is under
        # the repository root, so a prefix cut is enough and works on 5.1.
        param([Parameter(Mandatory = $true)][string] $Path)

        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full.StartsWith($script:RepoRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            $full = $full.Substring($script:RepoRoot.Length + 1)
        }

        return ($full -replace '\\', '/')
    }

    function Get-PcxSafetyCommandPattern {
        param([Parameter(Mandatory = $true)][string] $Name)

        return ('(?<![\w-])' + [regex]::Escape($Name) + '(?![\w])')
    }

    function Get-PcxSafetyShippedFiles {
        # The files INSTALL.md must pin: product, docs, config and the test
        # suite. install-time state, .omo/ and the manifest itself are excluded.
        $files = New-Object System.Collections.Generic.List[string]
        foreach ($name in @('pcx.ps1', 'LICENSE', 'README.md', 'README.ru.md', 'SKILL.md', 'SAFETY.md', 'SAFETY.ru.md', 'INSTALL.ru.md', 'command/pcx.md', 'agent/pcx.md', '.gitattributes')) {
            [void]$files.Add($name)
        }

        foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'references') -File -Filter '*.md')) {
            [void]$files.Add((Get-PcxSafetyRelativePath -Path $item.FullName))
        }
        foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'config') -Recurse -File -Filter '*.json')) {
            [void]$files.Add((Get-PcxSafetyRelativePath -Path $item.FullName))
        }
        foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src/pcx') -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
            [void]$files.Add((Get-PcxSafetyRelativePath -Path $item.FullName))
        }
        foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'tests') -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.json') })) {
            [void]$files.Add((Get-PcxSafetyRelativePath -Path $item.FullName))
        }
        [void]$files.Add('tests/.pcx-test-root')

        return , ([string[]]($files | Sort-Object -Unique))
    }

    function Get-PcxInstallManifest {
        # Parses "| \`path\` | \`sha256\` |" rows from INSTALL.md.
        $installPath = Join-Path $script:RepoRoot 'INSTALL.md'
        $text = [System.IO.File]::ReadAllText($installPath)

        $rows = [ordered]@{}
        foreach ($line in ($text -split "`r?`n")) {
            $match = [regex]::Match($line, '^\|\s*`([^`]+)`\s*\|\s*`([0-9a-fA-F]{64})`\s*\|\s*$')
            if (-not $match.Success) { continue }
            $rows[$match.Groups[1].Value] = $match.Groups[2].Value.ToLowerInvariant()
        }

        return $rows
    }

    function Test-PcxInstallReleaseField {
        <#
        .SYNOPSIS
            Validates the "Release commit id:" field of an INSTALL.md text.

        .DESCRIPTION
            Exactly one field must exist, and its value must be either the
            pre-release placeholder or a real 40-hex commit id. Any other value
            is a fake claim, and a second 40-hex commit anywhere else in the
            text is a contradictory claim; both are rejected.
        #>
        param([Parameter(Mandatory = $true)][string] $Text)

        $placeholder = '<filled by the release process>'

        $fields = [regex]::Matches($Text, '(?m)^Release commit id:[ \t]*(.+?)[ \t]*$')
        if ($fields.Count -ne 1) { return $false }

        $value = ($fields[0].Groups[1].Value -replace '`', '').Trim()
        if ($value -ne $placeholder -and $value -notmatch '^[0-9a-f]{40}$') { return $false }

        $elsewhere = [regex]::Replace($Text, '(?m)^Release commit id:.*$', '')
        return ($elsewhere -notmatch '\b[0-9a-fA-F]{40}\b')
    }
}

Describe 'product static safety scan' {

    It 'keeps every direct OS write cmdlet inside PcxPlatform.ps1' {
        foreach ($file in $script:ProductFiles) {
            if ($file.Name -eq $script:PlatformFile) { continue }

            foreach ($cmdlet in $script:ProductWriteCmdlets) {
                $file.Text | Should -Not -Match (Get-PcxSafetyCommandPattern -Name $cmdlet) `
                    -Because "$($file.Name) must route writes through PcxPlatform.ps1, not $cmdlet"
            }
        }
    }

    It 'keeps Remove-Item inside PcxPlatform.ps1 only' {
        foreach ($file in $script:ProductFiles) {
            if ($file.Name -eq $script:PlatformFile) { continue }
            $file.Text | Should -Not -Match (Get-PcxSafetyCommandPattern -Name 'Remove-Item') -Because "$($file.Name) must never delete directly"
        }
    }

    It 'never evaluates a string or merges a registry file' {
        foreach ($file in $script:ProductFiles) {
            $file.Text | Should -Not -Match (Get-PcxSafetyCommandPattern -Name 'Invoke-Expression')
            $file.Text | Should -Not -Match '(?i)bcdedit'
            $file.Text | Should -Not -Match '(?i)regedit'
            $file.Text | Should -Not -Match '(?i)Windows Registry Editor Version'
        }
    }

    It 'keeps MoveFileEx and byte transport in the two allowed files' {
        foreach ($file in $script:ProductFiles) {
            $allowedMove = ($file.Name -eq $script:PlatformFile) -or ($file.Name -eq $script:JsonFile)
            if (-not $allowedMove) {
                $file.Text | Should -Not -Match 'MoveFileEx' -Because 'only PcxPlatform.ps1 and PcxJson.ps1 may call MoveFileEx'
            }

            if ($file.Name -ne $script:JsonFile) {
                $file.Text | Should -Not -Match 'WriteAllText|WriteAllBytes|FileStream' -Because 'byte transport belongs to PcxJson.ps1'
            }
        }
    }

    It 'never shells out through a native tool or a command string' {
        $banned = @(
            ('reg' + '\.exe')
            ('sc' + '\.exe')
            ('schtasks' + '\.exe')
            ('cmd' + ' /c')
        )

        foreach ($file in $script:ProductFiles) {
            foreach ($pattern in $banned) {
                $file.Text | Should -Not -Match $pattern -Because "$($file.Name) must not shell out"
            }

            # -CommandName is a parameter and PCX-E-COMMAND is a code; only a
            # real -Command <value> parameter is banned.
            $file.Text | Should -Not -Match '(?<![A-Za-z])-Command\s'
        }
    }

    It 'never uses the destructive aliases or System.IO delete APIs' {
        foreach ($file in $script:ProductFiles) {
            $file.Text | Should -Not -Match '(?<![\w-])(ri|del|rm|erase)(?![\w-])'
            $file.Text | Should -Not -Match '\[(System\.)?IO\.File\]::Delete'
            $file.Text | Should -Not -Match '\[(System\.)?IO\.Directory\]::Delete'
        }
    }

    It 'makes exactly one Start-Process -Verb RunAs site per write path' {
        $uacFiles = @('Invoke-PcxApply.ps1', 'Invoke-PcxUndo.ps1')
        $callPattern = '(?<![\w-])Start-Process\s+-FilePath(?![\w])'

        foreach ($file in $script:ProductFiles) {
            if ($uacFiles -contains $file.Name) {
                $count = ([regex]::Matches($file.Text, $callPattern)).Count
                $count | Should -Be 1 -Because "$($file.Name) must launch at most one elevated child"
                $file.Text | Should -Match 'Start-Process\s+-FilePath[^\r\n]*-Verb RunAs'
                continue
            }

            $file.Text | Should -Not -Match $callPattern -Because "$($file.Name) must not launch processes"
        }
    }

    It 'ships Markdown output only, with no HTML in the product' {
        foreach ($file in $script:ProductFiles) {
            $file.Text | Should -Not -Match '(?i)<html|<form|<table'
        }
    }
}

Describe 'skill and documentation contract' {

    It 'keeps SKILL.md at 200 lines or fewer with exactly three steps' {
        $skillPath = Join-Path $script:RepoRoot 'SKILL.md'
        [System.IO.File]::Exists($skillPath) | Should -BeTrue

        $lines = @([System.IO.File]::ReadAllLines($skillPath))
        $lines.Count | Should -BeLessOrEqual 200

        $text = $lines -join "`n"
        foreach ($step in @('## Step 1', '## Step 2', '## Step 3')) {
            $text | Should -Match ([regex]::Escape($step))
        }
        $text | Should -Not -Match ([regex]::Escape('## Step 4'))

        $text | Should -Match '(?i)agent explains,\s+machine\s+proves'
        $text | Should -Match '(?i)effect not promised'
        $text | Should -Match '(?i)stop'
        $text | Should -Match '(?i)resume'
        $text | Should -Match '(?i)already good'
        $text | Should -Match '(?i)top causes'
        $text | Should -Match '(?i)do not hand the scan'
        $text | Should -Match '(?i)plain chat message'
        $text | Should -Match '(?i)question card'
        $text | Should -Match '(?i)N\+1'
        $text | Should -Match '(?i)table pcx returned'
        $text | Should -Match '(?i)never propose creating a restore point'
        $text | Should -Match '(?i)compact machine summary'
        $text | Should -Match '(?i)top 15 by RAM'
    }

    It 'mandates the investigation checklist and the probe families' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'SKILL.md'))

        foreach ($row in @('processes', 'startup', 'tasks', 'storage', 'network', 'updates', 'drivers', 'power', 'events', 'security')) {
            $text | Should -Match ('(?i)\b' + [regex]::Escape($row) + '\b') -Because "the checklist must name $row"
        }

        foreach ($family in @('platform', 'counter', 'event', 'intent', 'environment')) {
            $text | Should -Match ('(?i)\b' + [regex]::Escape($family) + '\b') -Because "deep investigation must name the $family probe family"
        }

        $text | Should -Match '(?i)outside the catalog'
        $text | Should -Match '(?i)fast path'
        $text | Should -Match '(?i)never hide'
    }

    It 'puts the triggers in the first 35 words of the skill description' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'SKILL.md'))
        $match = [regex]::Match($text, '(?m)^description:\s*(.+)$')
        $match.Success | Should -BeTrue

        $words = @($match.Groups[1].Value -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $words.Count | Should -BeGreaterOrEqual 35
        $head = (($words[0..34]) -join ' ').ToLowerInvariant()

        $head | Should -Match 'install'
        $head | Should -Match 'tune'
        $head | Should -Match 'doctor'
    }

    It 'mirrors the 13 actions and 8 manual entries in references/catalog.md' {
        $catalogPath = Join-Path $script:RepoRoot 'references/catalog.md'
        [System.IO.File]::Exists($catalogPath) | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($catalogPath)

        $actionIds = @()
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'config/actions') -File -Filter '*.json' | Where-Object { $_.Name -ne 'manual.json' })) {
            $document = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file.FullName))
            foreach ($action in @($document.actions)) {
                $actionIds += [string]$action.id
                $text | Should -Match ([regex]::Escape([string]$action.id))
            }
        }

        $actionIds.Count | Should -Be 13

        $manual = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'config/actions/manual.json')))
        $manualIds = @($manual.entries | ForEach-Object { [string]$_.id })
        $manualIds.Count | Should -Be 8
        foreach ($id in $manualIds) {
            $text | Should -Match ([regex]::Escape($id))
        }
    }

    It 'runs the scan inside the /pcx command and keeps the run in this session' {
        $commandPath = Join-Path $script:RepoRoot 'command/pcx.md'
        [System.IO.File]::Exists($commandPath) | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($commandPath)

        # The command itself runs the scan through a shell block; the model
        # cannot delegate what already ran, and subagent:false keeps the run in
        # the user's session.
        $text | Should -Match '(?m)^subagent: false'
        $text | Should -Match '(?m)^agent: pcx'
        $text | Should -Match 'Invoke-PcxTune'
        $text | Should -Match '!\x60'
        $text | Should -Match 'PCX_SCAN_FILE'
        $text | Should -Match 'data\.table'
        $text | Should -Match '--out'
        $text | Should -Match '(?i)machine summary'
        $text | Should -Match '(?i)never use the'
        $text | Should -Match '(?i)task tool'

        $text | Should -Match '(?i)same table'
        $text | Should -Match '(?i)N\+1'
        $text | Should -Match '(?i)numbers only'
        $text | Should -Match '(?i)restore point'
        $text | Should -Match '(?i)already good'
        $text | Should -Match '(?i)plain chat message'
        $text | Should -Match '(?i)question card'
    }

    It 'ships an OpenCode agent that cannot delegate with the task tool' {
        $agentPath = Join-Path $script:RepoRoot 'agent/pcx.md'
        [System.IO.File]::Exists($agentPath) | Should -BeTrue

        $text = [System.IO.File]::ReadAllText($agentPath)
        $text | Should -Match '(?m)^mode: primary'
        $text | Should -Match '(?m)^permission:'
        $text | Should -Match '(?im)^\s+task:\s*deny'
    }

    It 'ships README.md in English and Russian' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'README.md'))
        $text | Should -Match '## English'

        # Assembled from code points so this assertion is identical on
        # PowerShell 5.1, which reads BOM-less scripts as ANSI.
        $russian = '## ' + (-join @(0x0420, 0x0443, 0x0441, 0x0441, 0x043A, 0x0438, 0x0439 | ForEach-Object { [char]$_ }))
        $text | Should -Match ([regex]::Escape($russian))
    }

    It 'documents the safety model' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'SAFETY.md'))
        foreach ($topic in @('Threat model', 'Fixture-only', 'A1', 'Windows Server', 'control set', 'effect not promised', 'one UAC', '.pcx-test-root')) {
            $text | Should -Match ([regex]::Escape($topic))
        }
    }

    It 'documents how to investigate in references/method.md' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'references/method.md'))
        foreach ($topic in @('tune', 'probe', 'events', 'WHEA', 'processes', 'services', 'bugs', 'never automates')) {
            $text | Should -Match ([regex]::Escape($topic))
        }
    }
}

Describe 'INSTALL.md pinned manifest' {

    BeforeAll {
        $script:InstallPath = Join-Path $script:RepoRoot 'INSTALL.md'
        $script:InstallText = [System.IO.File]::ReadAllText($script:InstallPath)
        $script:Manifest = Get-PcxInstallManifest
    }

    It 'states installation, no binaries, no auto-update, and the doctor command' {
        $script:InstallText | Should -Match 'pwsh -File'
        $script:InstallText | Should -Match 'pcx\.ps1 doctor'
        $script:InstallText | Should -Match '(?i)no binaries'
        $script:InstallText | Should -Match '(?i)no auto-update'
        $script:InstallText | Should -Match '(?i)release process'
    }

    It 'accepts only the release placeholder or a real 40-hex commit id' {
        # Build a placeholder-state copy so the assertions do not depend on
        # whether the shipped INSTALL.md is pre- or post-release.
        $placeholder = '<filled by the release process>'
        $placeholderLine = 'Release commit id: ' + [char]96 + $placeholder + [char]96
        $placeholderText = [regex]::Replace($script:InstallText, '(?m)^Release commit id:.*$', $placeholderLine)

        (Test-PcxInstallReleaseField -Text $placeholderText) | Should -BeTrue -Because 'the pre-release placeholder is legitimate'

        # The release process may fill a real full commit id into that field.
        $real = '0123456789abcdef0123456789abcdef01234567'
        $released = $placeholderText -replace [regex]::Escape($placeholder), $real
        (Test-PcxInstallReleaseField -Text $released) | Should -BeTrue -Because 'a filled release field carrying a real 40-hex commit id is legitimate'

        # A short or invented value is still a fake claim.
        $fake = $placeholderText -replace [regex]::Escape($placeholder), 'abc123'
        (Test-PcxInstallReleaseField -Text $fake) | Should -BeFalse -Because 'a short or invented id is a fake claim'

        # A second, contradictory commit claim elsewhere is refused too.
        $contradictory = $placeholderText + "`nExtra commit: $real`n"
        (Test-PcxInstallReleaseField -Text $contradictory) | Should -BeFalse -Because 'a second 40-hex claim contradicts the release field'
    }

    It 'lists every shipped file and no binary or .omo/ path' {
        $shipped = Get-PcxSafetyShippedFiles
        $listed = @($script:Manifest.Keys | Sort-Object)

        ($listed -join "`n") | Should -BeExactly (($shipped | Sort-Object) -join "`n")

        $binaryExtensions = @('.exe', '.dll', '.bin', '.zip', '.msi', '.msix', '.cab', '.pfx', '.png', '.jpg', '.jpeg', '.ico', '.gif', '.db', '.docx', '.pdf')
        foreach ($path in $listed) {
            $path.StartsWith('.omo/') | Should -BeFalse -Because 'install state is never shipped'
            $path.Contains('.omo/') | Should -BeFalse
            [System.IO.Path]::GetExtension($path).ToLowerInvariant() | Should -Not -BeIn $binaryExtensions
        }
    }

    It 'matches every listed SHA-256 against the working tree' {
        $script:Manifest.Count | Should -BeGreaterThan 0

        foreach ($path in @($script:Manifest.Keys)) {
            $fullPath = Join-Path $script:RepoRoot $path
            [System.IO.File]::Exists($fullPath) | Should -BeTrue -Because "$path is listed in INSTALL.md"

            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $head = [System.Text.Encoding]::UTF8.GetString($bytes)
            $head.Contains([char]0) | Should -BeFalse -Because "$path is listed as a text file"

            (& $script:Sha256 -Path $fullPath) | Should -BeExactly $script:Manifest[$path] -Because "$path changed after the manifest was pinned"
        }
    }
}
