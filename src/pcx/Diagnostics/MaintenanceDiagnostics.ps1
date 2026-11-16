<#
.SYNOPSIS
    Maintenance diagnostics section (optimize-v0.1-discovery todo 4).

.DESCRIPTION
    Read-only builder Get-MaintenanceFindings -Environment -Scan. Update age,
    restore points and pending-reboot state are probed via the registry,
    CIM and Get-WinEvent only when PCX_TEST_RUN is empty; the fixture
    carries no maintenance facts, so fixture runs report unavailable
    findings. Missing data becomes an unavailable finding, never a throw.
    No console output, no global state, no external binaries. ASCII only,
    5.1 compatible.
#>

Set-StrictMode -Version 2.0

function Read-PcxMaintenanceProbe {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    $liveOk = [string]::IsNullOrEmpty($env:PCX_TEST_RUN)

    $updateAgeDays = $null
    $restoreCount = $null
    $restoreLatest = $null
    $pendingReboot = $null
    $rebootReasons = @()

    if ($liveOk) {
        try {
            $installResult = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' -Name 'LastSuccessTime' -ErrorAction Stop
            $lastSuccess = [string](Get-PcxPolicyMember -Object $installResult -Name 'LastSuccessTime')
            if (-not [string]::IsNullOrWhiteSpace($lastSuccess)) {
                $parsed = [System.DateTime]::Parse($lastSuccess, [System.Globalization.CultureInfo]::InvariantCulture)
                $updateAgeDays = [math]::Round(([System.DateTime]::UtcNow - $parsed.ToUniversalTime()).TotalDays, 1)
            }
        }
        catch {
            $updateAgeDays = $null
        }

        if ($null -eq $updateAgeDays) {
            try {
                $events = @(Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 60 -ErrorAction Stop | Where-Object { $_.Id -eq 19 } | Select-Object -First 1)
                if ($events.Count -gt 0 -and $null -ne $events[0].TimeCreated) {
                    $updateAgeDays = [math]::Round(([System.DateTime]::UtcNow - $events[0].TimeCreated.ToUniversalTime()).TotalDays, 1)
                }
            }
            catch {
                $updateAgeDays = $null
            }
        }

        try {
            $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
            $restoreCount = $points.Count
            if ($points.Count -gt 0) {
                $latest = $points | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
                $restoreLatest = $latest.CreationTime.ToString('yyyy-MM-dd')
            }
        }
        catch {
            $restoreCount = $null
            $restoreLatest = $null
        }

        $pendingReboot = $false
        try {
            if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
                $pendingReboot = $true
                $rebootReasons += 'component servicing'
            }
        }
        catch {
            $pendingReboot = $null
        }

        try {
            if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                $pendingReboot = $true
                $rebootReasons += 'windows update'
            }
        }
        catch {
            $pendingReboot = $null
        }

        try {
            $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
            $pending = Get-PcxPolicyMember -Object $sessionManager -Name 'PendingFileRenameOperations'
            if ($null -ne $pending -and @($pending).Count -gt 0) {
                $pendingReboot = $true
                $rebootReasons += 'pending renames'
            }
        }
        catch {
            if ($null -eq $pendingReboot) {
                $pendingReboot = $null
            }
        }
    }

    return [ordered]@{
        updateAgeDays  = $updateAgeDays
        restoreCount   = $restoreCount
        restoreLatest  = $restoreLatest
        pendingReboot  = $pendingReboot
        rebootReasons  = $rebootReasons
    }
}

function Get-MaintenanceFindings {
    <#
    .SYNOPSIS
        Builds the three read-only maintenance findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $false)][AllowNull()][object] $Scan
    )

    try {
        $probe = Read-PcxMaintenanceProbe -Environment $Environment -Scan $Scan
        $findings = @()

        if ($null -eq $probe.updateAgeDays) {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'windows-update-age' -Severity 'unavailable' `
                -TitleKey 'finding.maintenance.windows-update-age.title' -DetailKey 'finding.maintenance.windows-update-age.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'no update install facts are recorded'; source = 'registry:WindowsUpdate/Auto Update' })
        }
        elseif ($probe.updateAgeDays -gt 60) {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'windows-update-age' -Severity 'warn' `
                -TitleKey 'finding.maintenance.windows-update-age.title' -DetailKey 'finding.maintenance.windows-update-age.detail' `
                -Evidence ([ordered]@{ status = 'measured'; days = $probe.updateAgeDays; source = 'registry:WindowsUpdate/Auto Update' })
        }
        elseif ($probe.updateAgeDays -gt 30) {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'windows-update-age' -Severity 'info' `
                -TitleKey 'finding.maintenance.windows-update-age.title' -DetailKey 'finding.maintenance.windows-update-age.detail' `
                -Evidence ([ordered]@{ status = 'measured'; days = $probe.updateAgeDays; source = 'registry:WindowsUpdate/Auto Update' })
        }
        else {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'windows-update-age' -Severity 'good' `
                -TitleKey 'finding.maintenance.windows-update-age.title' -DetailKey 'finding.maintenance.windows-update-age.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; days = $probe.updateAgeDays; source = 'registry:WindowsUpdate/Auto Update' })
        }

        if ($null -eq $probe.restoreCount) {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'restore-points' -Severity 'unavailable' `
                -TitleKey 'finding.maintenance.restore-points.title' -DetailKey 'finding.maintenance.restore-points.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'restore points could not be listed'; source = 'cmdlet:Get-ComputerRestorePoint' })
        }
        elseif ($probe.restoreCount -lt 1) {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'restore-points' -Severity 'warn' `
                -TitleKey 'finding.maintenance.restore-points.title' -DetailKey 'finding.maintenance.restore-points.detail' `
                -Evidence ([ordered]@{ status = 'measured'; count = 0; source = 'cmdlet:Get-ComputerRestorePoint' })
        }
        else {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'restore-points' -Severity 'good' `
                -TitleKey 'finding.maintenance.restore-points.title' -DetailKey 'finding.maintenance.restore-points.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; count = $probe.restoreCount; latest = $probe.restoreLatest; source = 'cmdlet:Get-ComputerRestorePoint' })
        }

        if ($null -eq $probe.pendingReboot) {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'pending-reboot' -Severity 'unavailable' `
                -TitleKey 'finding.maintenance.pending-reboot.title' -DetailKey 'finding.maintenance.pending-reboot.detail' `
                -Evidence ([ordered]@{ status = 'unavailable'; reason = 'the reboot markers could not be read'; source = 'registry:RebootPending' })
        }
        elseif ($probe.pendingReboot -eq $true) {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'pending-reboot' -Severity 'warn' `
                -TitleKey 'finding.maintenance.pending-reboot.title' -DetailKey 'finding.maintenance.pending-reboot.detail' `
                -Evidence ([ordered]@{ status = 'measured'; pending = $true; reasons = @($probe.rebootReasons); source = 'registry:RebootPending' })
        }
        else {
            $findings += New-PcxFinding -Section 'maintenance' -Id 'pending-reboot' -Severity 'good' `
                -TitleKey 'finding.maintenance.pending-reboot.title' -DetailKey 'finding.maintenance.pending-reboot.detail' `
                -AlreadyGood $true `
                -Evidence ([ordered]@{ status = 'measured'; pending = $false; source = 'registry:RebootPending' })
        }

        return @($findings)
    }
    catch {
        return @(New-PcxFinding -Section 'maintenance' -Id 'maintenance-unavailable' -Severity 'unavailable' `
            -TitleKey 'column.what' -DetailKey 'column.evidence' `
            -Evidence ([ordered]@{ status = 'unavailable'; reason = ('maintenance probe failed: ' + [string]$_.Exception.Message); source = 'diagnostics:maintenance' }))
    }
}
