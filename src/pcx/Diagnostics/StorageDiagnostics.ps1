<#
.SYNOPSIS
    Storage diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-StorageFindings -Environment -Scan. Fixture values
    come from the scan state; live CIM probes and the capped folder walk run
    only when PCX_TEST_RUN is empty. The largest-consumer walk is bounded:
    depth 2, at most 500 entries, a hard 2 s budget, then it degrades to an
    unavailable finding. No console output, no global state, no external
    binaries. ASCII only, 5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxStorageTopConsumers {
    <#
    .SYNOPSIS
        Bounded folder walk: depth 2, max 500 entries, hard 2 s budget.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]] $Roots,
        [Parameter(Mandatory = $false)][int] $MaxDepth = 2,
        [Parameter(Mandatory = $false)][int] $MaxEntries = 500,
        [Parameter(Mandatory = $false)][int] $BudgetMs = 2000
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $queue = New-Object System.Collections.Queue
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        if (Test-Path -LiteralPath $root) {
            $queue.Enqueue([pscustomobject]@{ Path = $root; Depth = 0 })
        }
    }

    $entries = @()
    $truncated = $false

    while ($queue.Count -gt 0) {
        if ($watch.ElapsedMilliseconds -ge $BudgetMs -or $entries.Count -ge $MaxEntries) {
            $truncated = $true
            break
        }

        $node = $queue.Dequeue()
        try {
            $children = @(Get-ChildItem -LiteralPath $node.Path -Directory -Force -ErrorAction Stop)
        }
        catch {
            continue
        }

        foreach ($child in $children) {
            if ($watch.ElapsedMilliseconds -ge $BudgetMs -or $entries.Count -ge $MaxEntries) {
                $truncated = $true
                break
            }

            $size = $null
            try {
                $files = @(Get-ChildItem -LiteralPath $child.FullName -File -Force -ErrorAction Stop)
                $total = [long]0
                foreach ($file in $files) {
                    if ($watch.ElapsedMilliseconds -ge $BudgetMs) {
                        break
                    }

                    $total += [long]$file.Length
                }

                $size = $total
            }
            catch {
                $size = $null
            }

            $entries += [pscustomobject]@{ Path = [string]$child.FullName; Bytes = $size }
            if ($node.Depth -lt $MaxDepth) {
                $queue.Enqueue([pscustomobject]@{ Path = [string]$child.FullName; Depth = ($node.Depth + 1) })
            }
        }
    }

    $watch.Stop()

    $sorted = @($entries | Sort-Object -Property Bytes -Descending | Select-Object -First 5)
    return [ordered]@{
        entries      = $sorted
        counted      = $entries.Count
        truncated    = $truncated
        elapsedMs    = $watch.ElapsedMilliseconds
        maxDepth     = $MaxDepth
        maxEntries   = $MaxEntries
        budgetMs     = $BudgetMs
    }
}

function Read-PcxStorageProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $state = Get-PcxPolicyMember -Object $Scan -Name 'state'
    if ($null -eq $state) {
        $state = $Scan
    }

    $storage = Get-PcxPolicyMember -Object $state -Name 'storage'
    $freeBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $storage -Name 'freeBytes')
    $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $storage -Name 'totalBytes')
    $freePercent = ConvertTo-PcxCollectorDouble -Value (Get-PcxPolicyMember -Object $storage -Name 'freePercent')

    $volumeIssueCount = $null
    $volumeDetails = @()
    $topConsumers = $null

    if ($liveOk) {
        if ($null -eq $freeBytes -or $null -eq $totalBytes) {
            try {
                $systemRoot = [System.IO.Path]::GetPathRoot([System.Environment]::SystemDirectory)
                $systemDrive = $systemRoot.TrimEnd([char]'\', [char]'/')
                $disks = @(Get-CimInstance -ClassName 'Win32_LogicalDisk' -ErrorAction Stop)
                $disk = $disks | Where-Object { [string](Get-PcxPolicyMember -Object $_ -Name 'DeviceID') -ieq $systemDrive } | Select-Object -First 1
                if ($null -ne $disk) {
                    $freeBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $disk -Name 'FreeSpace')
                    $totalBytes = ConvertTo-PcxCollectorLong -Value (Get-PcxPolicyMember -Object $disk -Name 'Size')
                }
            }
            catch {
                $freeBytes = $null
                $totalBytes = $null
            }
        }

        try {
            $volumes = @(Get-CimInstance -ClassName 'Win32_Volume' -ErrorAction Stop)
            $issues = 0
            $details = @()
            foreach ($volume in $volumes) {
                $status = [string](Get-PcxPolicyMember -Object $volume -Name 'Status')
                $label = [string](Get-PcxPolicyMember -Object $volume -Name 'DriveLetter')
                if (-not [string]::IsNullOrWhiteSpace($status) -and $status -ine 'OK') {
                    $issues++
                    $details += ('volume ' + $label + ' reports ' + $status)
                }
            }

            $volumeIssueCount = $issues
            $volumeDetails = $details
        }
        catch {
            $volumeIssueCount = $null
            $volumeDetails = @()
        }

        $roots = @()
        foreach ($name in @('LOCALAPPDATA', 'PROGRAMDATA')) {
            $value = [System.Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $roots += $value
            }
        }

        if ($roots.Count -gt 0) {
            try {
                $topConsumers = Read-PcxStorageTopConsumers -Roots $roots -MaxDepth 2 -MaxEntries 500 -BudgetMs 2000
            }
            catch {
                $topConsumers = $null
            }
        }
    }

    if ($null -eq $freePercent -and $null -ne $freeBytes -and $null -ne $totalBytes -and $totalBytes -gt 0) {
        $freePercent = [math]::Round(([double]$freeBytes / [double]$totalBytes) * 100, 2)
    }

    return [ordered]@{
        freeBytes       = $freeBytes
        totalBytes      = $totalBytes
        freePercent     = $freePercent
        volumeIssues    = $volumeIssueCount
        volumeDetails   = $volumeDetails
        topConsumers    = $topConsumers
    }
}

function Get-StorageFindings {
    <#
    .SYNOPSIS
        Builds the three read-only storage findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxStorageProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.freePercent) {
            $findings += New-PcxFinding -Section 'storage' -Id 'system-free-space' -Severity 'unavailable' `
                -TitleKey 'finding.storage.system-free-space.title' -DetailKey 'finding.storage.system-free-space.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the system drive free space could not be read'; source = 'fixture:state.storage' })
        }
        elseif ($probe.freePercent -lt 10) {
            $findings += New-PcxFinding -Section 'storage' -Id 'system-free-space' -Severity 'critical' `
                -TitleKey 'finding.storage.system-free-space.title' -DetailKey 'finding.storage.system-free-space.detail' `
                -Evidence ([ordered]@{ status = 'measured'; freePercent = $probe.freePercent; freeBytes = $probe.freeBytes; source = 'fixture:state.storage' })
        }
        elseif ($probe.freePercent -lt 20) {
            $findings += New-PcxFinding -Section 'storage' -Id 'system-free-space' -Severity 'warn' `
                -TitleKey 'finding.storage.system-free-space.title' -DetailKey 'finding.storage.system-free-space.detail' `
                -Evidence ([ordered]@{ status = 'measured'; freePercent = $probe.freePercent; freeBytes = $probe.freeBytes; source = 'fixture:state.storage' })
        }
        else {
            $findings += New-PcxFinding -Section 'storage' -Id 'system-free-space' -Severity 'good' `
                -TitleKey 'finding.storage.system-free-space.title' -DetailKey 'finding.storage.system-free-space.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; freePercent = $probe.freePercent; freeBytes = $probe.freeBytes; source = 'fixture:state.storage' })
        }

        if ($null -eq $probe.volumeIssues) {
            $findings += New-PcxFinding -Section 'storage' -Id 'volume-health' -Severity 'unavailable' `
                -TitleKey 'finding.storage.volume-health.title' -DetailKey 'finding.storage.volume-health.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the volume status could not be read'; source = 'cim:Win32_Volume' })
        }
        elseif ($probe.volumeIssues -gt 0) {
            $findings += New-PcxFinding -Section 'storage' -Id 'volume-health' -Severity 'warn' `
                -TitleKey 'finding.storage.volume-health.title' -DetailKey 'finding.storage.volume-health.detail' `
                -Evidence ([ordered]@{ status = 'measured'; issues = $probe.volumeIssues; details = @($probe.volumeDetails | Select-Object -First 5); source = 'cim:Win32_Volume' })
        }
        else {
            $findings += New-PcxFinding -Section 'storage' -Id 'volume-health' -Severity 'good' `
                -TitleKey 'finding.storage.volume-health.title' -DetailKey 'finding.storage.volume-health.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; issues = 0; source = 'cim:Win32_Volume' })
        }

        if ($null -eq $probe.topConsumers) {
            $findings += New-PcxFinding -Section 'storage' -Id 'top-space-consumers' -Severity 'unavailable' `
                -TitleKey 'finding.storage.top-space-consumers.title' -DetailKey 'finding.storage.top-space-consumers.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the folder walk did not run or exceeded its budget'; source = 'filesystem:bounded-walk' })
        }
        else {
            $topPaths = @($probe.topConsumers.entries | ForEach-Object { [ordered]@{ path = [string]$_.Path; bytes = $_.Bytes } })
            $findings += New-PcxFinding -Section 'storage' -Id 'top-space-consumers' -Severity 'info' `
                -TitleKey 'finding.storage.top-space-consumers.title' -DetailKey 'finding.storage.top-space-consumers.detail' `
                -Evidence ([ordered]@{ status = 'measured'; top = $topPaths; counted = $probe.topConsumers.counted; truncated = $probe.topConsumers.truncated; elapsedMs = $probe.topConsumers.elapsedMs; source = 'filesystem:bounded-walk' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'storage' -Id 'storage-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('storage probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:storage' }))
    }
}
