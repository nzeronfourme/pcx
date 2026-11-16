<#
.SYNOPSIS
    Read-only environment detection and the environment-to-policy bridge.

.DESCRIPTION
    Get-PcxEnvironment reports the machine facts the tune table needs: build,
    UBR and edition, S Mode, managed enrollment, VBS/HVCI, BitLocker, Defender,
    firewall, TPM, anticheat, Dev Drive, printers, memory, GPU, HAGS, GameDVR
    and the active power plan.

    Every detection field is an object:
        @{ value = <observed>; status = 'measured' | 'unavailable' | 'unreliable' }
    A failed probe becomes 'unavailable' with value $null. It is never a guessed
    zero and it never throws out of Get-PcxEnvironment.

    Fixture mode is mandatory in tests. When PCX_TEST_RUN is set, a fixture path
    must be supplied with -FixturePath or PCX_ENVIRONMENT_FIXTURE; without one
    the call throws PCX-E-ENVIRONMENT-FIXTURE instead of reading the live OS. A
    fixture path may name a directory, in which case machine.json inside it is
    read.

    The live path is read-only. It uses registry reads and CIM queries, never an
    administrator-only command, and never a command that reconfigures the
    machine. Managed detection reads enrollment/MDM registry markers; it does
    not run a device-registration client.

    Managed means a real MDM/UEM enrollment: a GUID enrollment with a non-empty
    ProviderID that is not a WMI_Bridge* stub and EnrollmentState 1, or an
    OMA-DM account with a non-empty UPN. Empty-provider leftovers and
    PolicyManager\current\device are reported as raw markers but never decide
    the verdict, and the field carries a reason for whichever way it decided.

    Anticheat.present means an ACTIVE session: a known anticheat service or
    kernel driver that is Running. An installed-but-idle client is reported in
    installed and does not block a write.

    ConvertTo-PcxPolicyProfile turns an environment object into the -Profile
    shape Test-PcxTarget already consumes. A fact that is not measured becomes
    $null, which the policy treats as unknown and refuses.
#>

Set-StrictMode -Version 2.0

$script:PcxEnvironmentSchema = 'pcx-environment/1'
$script:PcxEnvironmentFields = @(
    'managed'
    'sMode'
    'vbs'
    'hvci'
    'bitLocker'
    'defender'
    'firewall'
    'tpm'
    'anticheat'
    'devDrive'
    'printers'
    'memory'
    'gpu'
    'hags'
    'gameDvr'
    'powerPlan'
)
$script:PcxEnvironmentOsFields = @('productName', 'build', 'ubr', 'edition')
$script:PcxEnvironmentStatuses = @('measured', 'unavailable', 'unreliable')
$script:PcxEnvironmentAnticheatServices = @(
    'vgk'
    'vgc'
    'EasyAntiCheat'
    'EasyAntiCheat_EOS'
    'BEService'
    'BEDaisy'
    'PnkBstrA'
    'PnkBstrB'
    'FaceitAC'
    'ESEADriver2'
    'mhyprot2'
    'GGProtect'
    'GameGuard'
)
$script:PcxEnvironmentPowerPlans = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate Performance'
}

# ---------------------------------------------------------------------------
# Field constructors and shape helpers
# ---------------------------------------------------------------------------

function New-PcxEnvironmentField {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Status
    )

    return [pscustomobject][ordered]@{
        value  = $Value
        status = $Status
    }
}

function New-PcxEnvironmentMeasured {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return New-PcxEnvironmentUnavailable -Reason 'probe returned no value'
    }

    return New-PcxEnvironmentField -Value $Value -Status 'measured'
}

function New-PcxEnvironmentUnavailable {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Reason)

    return [pscustomobject][ordered]@{
        value  = $null
        status = 'unavailable'
        reason = $Reason
    }
}

function Test-PcxEnvironmentHasMember {
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

function Invoke-PcxEnvironmentProbe {
    # A probe failure is an unavailable field, never a thrown call.
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Probe,
        [Parameter(Mandatory = $true)][string] $Label
    )

    try {
        return (& $Probe)
    }
    catch {
        return New-PcxEnvironmentUnavailable -Reason ("$Label probe failed: $($_.Exception.Message)")
    }
}

function ConvertTo-PcxEnvironmentInteger {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [int]$Value
    }
    catch {
        return $null
    }
}

function Read-PcxEnvironmentRegistryValue {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }

    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Read-PcxEnvironmentRegistryValueState {
    <#
    .SYNOPSIS
        Three-state registry read for policy values (HAGS, VBS, HVCI).

    .DESCRIPTION
        A named-value read throws both when the value is absent and when the
        key is absent or unreadable, so a single null return collapses three
        different facts. This reader separates them: a failed named read is
        followed by a whole-key probe. A readable key means the value is
        absent (outcome 'missing', the caller reports measured off); a second
        failure means the value is unreadable (outcome 'unreadable', the
        caller reports unavailable with the reason). A successful named read
        is outcome 'present' and keeps the raw value.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    }
    catch {
        try {
            $null = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        }
        catch {
            return [pscustomobject][ordered]@{
                outcome = 'unreadable'
                raw     = $null
                reason  = ("the '{0}' value under '{1}' could not be read: {2}" -f $Name, $Path, $_.Exception.Message)
            }
        }

        return [pscustomobject][ordered]@{
            outcome = 'missing'
            raw     = $null
            reason  = ("the '{0}' value under '{1}' is absent on an existing key" -f $Name, $Path)
        }
    }

    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return [pscustomobject][ordered]@{
            outcome = 'missing'
            raw     = $null
            reason  = ("the '{0}' value under '{1}' is absent on an existing key" -f $Name, $Path)
        }
    }

    return [pscustomobject][ordered]@{
        outcome = 'present'
        raw     = $property.Value
        reason  = $null
    }
}

function Get-PcxEnvironmentPaths {
    $map = [ordered]@{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA', 'SYSTEMROOT')) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $map[$name] = [string]$value
        }
    }

    return [pscustomobject]$map
}

# ---------------------------------------------------------------------------
# Fixture loading
# ---------------------------------------------------------------------------

function Assert-PcxEnvironmentField {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object] $Field,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $status = [string](Get-PcxPolicyMember -Object $Field -Name 'status')
    if ($script:PcxEnvironmentStatuses -notcontains $status) {
        throw [System.IO.InvalidDataException]::new("PCX-E-ENVIRONMENT-FIXTURE: '$Path' field '$Name' has no measured/unavailable/unreliable status.")
    }

    if ($status -eq 'measured') {
        if (-not (Test-PcxEnvironmentHasMember -Object $Field -Name 'value')) {
            throw [System.IO.InvalidDataException]::new("PCX-E-ENVIRONMENT-FIXTURE: '$Path' field '$Name' is measured but has no value.")
        }
        if ($null -eq (Get-PcxPolicyMember -Object $Field -Name 'value')) {
            throw [System.IO.InvalidDataException]::new("PCX-E-ENVIRONMENT-FIXTURE: '$Path' field '$Name' is measured with a null value.")
        }
    }
}

function Assert-PcxEnvironmentFixture {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Environment,
        [Parameter(Mandatory = $true)][string] $Path
    )

    if ($null -eq $Environment) {
        throw [System.IO.InvalidDataException]::new("PCX-E-ENVIRONMENT-FIXTURE: '$Path' is empty.")
    }

    $schema = [string](Get-PcxPolicyMember -Object $Environment -Name 'schema')
    if ($schema -ne $script:PcxEnvironmentSchema) {
        throw [System.IO.InvalidDataException]::new("PCX-E-ENVIRONMENT-FIXTURE: '$Path' schema must be '$($script:PcxEnvironmentSchema)' (found '$schema').")
    }

    $os = Get-PcxPolicyMember -Object $Environment -Name 'os'
    foreach ($name in $script:PcxEnvironmentOsFields) {
        Assert-PcxEnvironmentField -Field (Get-PcxPolicyMember -Object $os -Name $name) -Name "os.$name" -Path $Path
    }

    foreach ($name in $script:PcxEnvironmentFields) {
        Assert-PcxEnvironmentField -Field (Get-PcxPolicyMember -Object $Environment -Name $name) -Name $name -Path $Path
    }
}

function Read-PcxEnvironmentFixture {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = $Path
    if ([System.IO.Directory]::Exists($fullPath)) {
        $fullPath = [System.IO.Path]::Combine($fullPath, 'machine.json')
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($fullPath)
    }
    catch {
        throw [System.IO.InvalidDataException]::new("PCX-E-ENVIRONMENT-FIXTURE: '$Path' is not a valid path.", $_.Exception)
    }

    if (-not [System.IO.File]::Exists($fullPath)) {
        throw [System.IO.FileNotFoundException]::new("PCX-E-ENVIRONMENT-FIXTURE: '$fullPath' does not exist.", $fullPath)
    }

    $document = Read-PcxJson -Path $fullPath
    Assert-PcxEnvironmentFixture -Environment $document -Path $fullPath
    return $document
}

# ---------------------------------------------------------------------------
# Live probes (read-only)
# ---------------------------------------------------------------------------

function Get-PcxEnvironmentOsFields {
    $current = $null
    try {
        $current = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    }
    catch {
        $current = $null
    }

    $productName = Get-PcxPolicyMember -Object $current -Name 'ProductName'
    $edition = Get-PcxPolicyMember -Object $current -Name 'EditionID'
    $build = ConvertTo-PcxEnvironmentInteger -Value (Get-PcxPolicyMember -Object $current -Name 'CurrentBuildNumber')
    if ($null -eq $build) {
        $build = ConvertTo-PcxEnvironmentInteger -Value (Get-PcxPolicyMember -Object $current -Name 'CurrentBuild')
    }
    $ubr = ConvertTo-PcxEnvironmentInteger -Value (Get-PcxPolicyMember -Object $current -Name 'UBR')

    return [pscustomobject][ordered]@{
        productName = New-PcxEnvironmentMeasured -Value $productName
        build       = New-PcxEnvironmentMeasured -Value $build
        ubr         = New-PcxEnvironmentMeasured -Value $ubr
        edition     = New-PcxEnvironmentMeasured -Value $edition
    }
}

function Get-PcxEnvironmentSModeField {
    $edition = [string](Read-PcxEnvironmentRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID')
    $skuPolicy = Read-PcxEnvironmentRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'SkuPolicyRequired'

    if ([string]::IsNullOrWhiteSpace($edition) -and $null -eq $skuPolicy) {
        return New-PcxEnvironmentUnavailable -Reason 'neither the edition nor the S Mode policy could be read'
    }

    $isSMode = $false
    $skuPolicyValue = ConvertTo-PcxEnvironmentInteger -Value $skuPolicy
    if ($null -ne $skuPolicyValue -and $skuPolicyValue -eq 1) {
        $isSMode = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($edition) -and $edition -match '^(?i)(CloudEdition|Cloud|EnterpriseS|IoTEnterpriseS|Starter)$') {
        $isSMode = $true
    }

    return New-PcxEnvironmentMeasured -Value $isSMode
}

function Get-PcxEnvironmentManagedObservation {
    # Raw, read-only registry inventory. Nothing here decides "managed": an
    # enrollment key can be a leftover with an empty ProviderID or a
    # WMI_Bridge* SCCM stub, and PolicyManager\current\device exists on most
    # Windows installs. The verdict is derived in
    # Get-PcxEnvironmentManagedField from the provider-carrying rows only.
    $enrollments = New-Object System.Collections.Generic.List[object]
    $omadmAccounts = New-Object System.Collections.Generic.List[object]
    $markers = New-Object System.Collections.Generic.List[string]

    $enrollmentsRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path -LiteralPath $enrollmentsRoot) {
        [void]$markers.Add($enrollmentsRoot)
        foreach ($child in @(Get-ChildItem -LiteralPath $enrollmentsRoot -ErrorAction Stop)) {
            $properties = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction Stop
            $provider = ([string](Get-PcxPolicyMember -Object $properties -Name 'ProviderID')).Trim()
            $state = ConvertTo-PcxEnvironmentInteger -Value (Get-PcxPolicyMember -Object $properties -Name 'EnrollmentState')

            [void]$enrollments.Add([pscustomobject][ordered]@{
                    id              = [string]$child.PSChildName
                    providerId      = $provider
                    enrollmentState = $state
                })
            [void]$markers.Add(('{0}\{1}' -f $enrollmentsRoot, $child.PSChildName))
        }
    }

    $omadmRoot = 'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts'
    if (Test-Path -LiteralPath $omadmRoot) {
        [void]$markers.Add($omadmRoot)
        foreach ($child in @(Get-ChildItem -LiteralPath $omadmRoot -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction SilentlyContinue
            $upn = ([string](Get-PcxPolicyMember -Object $properties -Name 'UPN')).Trim()

            [void]$omadmAccounts.Add([pscustomobject][ordered]@{
                    id  = [string]$child.PSChildName
                    upn = $upn
                })
            [void]$markers.Add(('{0}\{1}' -f $omadmRoot, $child.PSChildName))
        }
    }

    # Presence only: neither of these proves an enrollment on its own.
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM', 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device')) {
        if (Test-Path -LiteralPath $path) {
            [void]$markers.Add($path)
        }
    }

    return [pscustomobject][ordered]@{
        enrollments   = $enrollments.ToArray()
        omadmAccounts = $omadmAccounts.ToArray()
        markers       = $markers.ToArray()
    }
}

function Get-PcxEnvironmentManagedField {
    <#
    .SYNOPSIS
        Managed verdict: a real MDM/UEM enrollment, not a leftover marker.

    .DESCRIPTION
        A GUID enrollment counts only when it carries a non-empty ProviderID
        that is not a WMI_Bridge* stub AND EnrollmentState 1. An OMA-DM account
        with a non-empty UPN is the second positive signal. Empty-provider
        leftovers and PolicyManager\current\device are reported as raw markers
        but never decide the verdict.

    .PARAMETER Enrollments
        Test seam: raw enrollment rows (id, providerId, enrollmentState).

    .PARAMETER OmadmAccounts
        Test seam: raw OMA-DM account rows (id, upn).

    .PARAMETER Markers
        Test seam: raw registry paths observed, kept for transparency.

    .PARAMETER PolicyManagerPresent
        Test seam: whether PolicyManager\current\device was observed. Marker
        only; it never makes the device managed.
    #>
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $Enrollments,
        [Parameter(Mandatory = $false)][AllowNull()][object[]] $OmadmAccounts,
        [Parameter(Mandatory = $false)][AllowNull()][string[]] $Markers,
        [Parameter(Mandatory = $false)][AllowNull()][object] $PolicyManagerPresent
    )

    $seamActive = ($null -ne $Enrollments) -or ($null -ne $OmadmAccounts) -or ($null -ne $Markers) -or ($null -ne $PolicyManagerPresent)

    $enrollmentRows = @()
    $omadmRows = @()
    $markerList = @()

    if ($seamActive) {
        $enrollmentRows = @($Enrollments | Where-Object { $null -ne $_ })
        $omadmRows = @($OmadmAccounts | Where-Object { $null -ne $_ })
        $markerList = @($Markers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        try {
            $observation = Get-PcxEnvironmentManagedObservation
        }
        catch {
            return New-PcxEnvironmentUnavailable -Reason "managed markers probe failed: $($_.Exception.Message)"
        }

        $enrollmentRows = @($observation.enrollments)
        $omadmRows = @($observation.omadmAccounts)
        $markerList = @($observation.markers)
    }

    $signals = New-Object System.Collections.Generic.List[string]

    foreach ($row in $enrollmentRows) {
        $provider = ([string](Get-PcxPolicyMember -Object $row -Name 'providerId')).Trim()
        if ([string]::IsNullOrWhiteSpace($provider)) { continue }
        if ($provider -like 'WMI_Bridge*') { continue }

        $state = ConvertTo-PcxEnvironmentInteger -Value (Get-PcxPolicyMember -Object $row -Name 'enrollmentState')
        if ($null -eq $state -or $state -ne 1) { continue }

        $id = [string](Get-PcxPolicyMember -Object $row -Name 'id')
        [void]$signals.Add(("Enrollments\{0} ProviderID={1} EnrollmentState=1" -f $id, $provider))
    }

    foreach ($row in $omadmRows) {
        $upn = ([string](Get-PcxPolicyMember -Object $row -Name 'upn')).Trim()
        if ([string]::IsNullOrWhiteSpace($upn)) { continue }

        # The UPN itself is never copied into the verdict; only its presence.
        $id = [string](Get-PcxPolicyMember -Object $row -Name 'id')
        [void]$signals.Add(("Provisioning\OMADM\Accounts\{0} has a UPN" -f $id))
    }

    $managed = ($signals.Count -gt 0)

    if ($managed) {
        $reason = 'managed: ' + ($signals -join '; ')
    }
    else {
        $reason = "not managed: {0} enrollment entries, none with a non-bridge ProviderID and EnrollmentState 1; {1} OMA-DM accounts, none with a UPN." -f $enrollmentRows.Count, $omadmRows.Count

        $policyManagerSeen = $false
        if ($null -ne $PolicyManagerPresent) {
            $policyManagerSeen = [bool]$PolicyManagerPresent
        }
        else {
            $policyManagerSeen = @($markerList | Where-Object { $_ -like '*PolicyManager\current\device' }).Count -gt 0
        }
        if ($policyManagerSeen) {
            $reason += ' PolicyManager\current\device exists but is not an MDM marker by itself.'
        }
    }

    return [pscustomobject][ordered]@{
        value       = $managed
        status      = 'measured'
        reason      = $reason
        signals     = $signals.ToArray()
        markers     = $markerList
        enrollments = $enrollmentRows
    }
}

function Get-PcxEnvironmentVbsField {
    $state = Read-PcxEnvironmentRegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity'
    if ($state.outcome -eq 'unreadable') {
        return New-PcxEnvironmentUnavailable -Reason $state.reason
    }

    if ($state.outcome -eq 'present') {
        $value = ConvertTo-PcxEnvironmentInteger -Value $state.raw
        if ($null -eq $value) {
            return New-PcxEnvironmentUnavailable -Reason 'the VBS policy value is not a number'
        }

        return New-PcxEnvironmentMeasured -Value ($value -eq 1)
    }

    return New-PcxEnvironmentMeasured -Value $false
}

function Get-PcxEnvironmentHvciField {
    $state = Read-PcxEnvironmentRegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled'
    if ($state.outcome -eq 'unreadable') {
        return New-PcxEnvironmentUnavailable -Reason $state.reason
    }

    if ($state.outcome -eq 'present') {
        $value = ConvertTo-PcxEnvironmentInteger -Value $state.raw
        if ($null -eq $value) {
            return New-PcxEnvironmentUnavailable -Reason 'the HVCI policy value is not a number'
        }

        return New-PcxEnvironmentMeasured -Value ($value -eq 1)
    }

    return New-PcxEnvironmentMeasured -Value $false
}

function Get-PcxEnvironmentBitLockerField {
    $volumes = @(Get-CimInstance -Namespace 'root\cimv2\security\microsoftvolumeencryption' -ClassName 'Win32_EncryptableVolume' -ErrorAction Stop)

    $items = @()
    $protectedCount = 0
    foreach ($volume in $volumes) {
        $protectionStatus = Get-PcxPolicyMember -Object $volume -Name 'ProtectionStatus'
        $items += [pscustomobject][ordered]@{
            driveLetter      = [string](Get-PcxPolicyMember -Object $volume -Name 'DriveLetter')
            protectionStatus = $protectionStatus
        }

        $statusValue = ConvertTo-PcxEnvironmentInteger -Value $protectionStatus
        if ($null -ne $statusValue -and $statusValue -eq 1) {
            $protectedCount++
        }
    }

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        volumes        = $items
        protectedCount = $protectedCount
        anyProtected   = ($protectedCount -gt 0)
    })
}

function Get-PcxEnvironmentDefenderField {
    $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop)
    $names = @()
    foreach ($product in $products) {
        $names += [string](Get-PcxPolicyMember -Object $product -Name 'displayName')
    }

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        products = $names
        present  = ($names.Count -gt 0)
    })
}

function Get-PcxEnvironmentFirewallField {
    $profiles = @(Get-CimInstance -Namespace 'root\StandardCimv2' -ClassName 'MSFT_NetFirewallProfile' -ErrorAction Stop)
    $map = [ordered]@{}
    $anyEnabled = $false
    foreach ($profile in $profiles) {
        $enabledValue = ConvertTo-PcxEnvironmentInteger -Value (Get-PcxPolicyMember -Object $profile -Name 'Enabled')
        $enabled = ($null -ne $enabledValue -and $enabledValue -eq 1)
        $map[[string](Get-PcxPolicyMember -Object $profile -Name 'Name')] = $enabled
        if ($enabled) {
            $anyEnabled = $true
        }
    }
    $map['anyEnabled'] = $anyEnabled

    return New-PcxEnvironmentMeasured -Value ([pscustomobject]$map)
}

function Get-PcxEnvironmentTpmField {
    $tpm = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
    if ($null -eq $tpm) {
        return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
            present = $false
            ready   = $false
            version = $null
        })
    }

    $enabled = [bool](Get-PcxPolicyMember -Object $tpm -Name 'IsEnabled_InitialValue')
    $activated = [bool](Get-PcxPolicyMember -Object $tpm -Name 'IsActivated_InitialValue')
    $ready = ($enabled -and $activated)

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        present = $true
        ready   = $ready
        version = [string](Get-PcxPolicyMember -Object $tpm -Name 'SpecVersion')
    })
}

function Get-PcxEnvironmentAnticheatRows {
    # Services and kernel drivers both carry an anticheat session; a driver is
    # what an idle client leaves behind (BEDaisy) and what a live one loads
    # (vgk). Read-only CIM, no elevation.
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($className in @('Win32_Service', 'Win32_SystemDriver')) {
        try {
            foreach ($item in @(Get-CimInstance -ClassName $className -ErrorAction Stop)) {
                [void]$rows.Add([pscustomobject][ordered]@{
                        name      = [string](Get-PcxPolicyMember -Object $item -Name 'Name')
                        state     = [string](Get-PcxPolicyMember -Object $item -Name 'State')
                        startMode = [string](Get-PcxPolicyMember -Object $item -Name 'StartMode')
                        kind      = $className
                    })
            }
        }
        catch {
            continue
        }
    }

    if ($rows.Count -eq 0) {
        throw [System.InvalidOperationException]::new('neither Win32_Service nor Win32_SystemDriver could be read')
    }

    return $rows.ToArray()
}

function Get-PcxEnvironmentAnticheatField {
    <#
    .SYNOPSIS
        Anticheat verdict: present means an ACTIVE session, not an install.

    .DESCRIPTION
        present/detected describe known anticheat services and kernel drivers
        that are Running right now. installed lists every known match regardless
        of state, so an idle BattlEye still shows up honestly while not blocking
        a write.

    .PARAMETER Services
        Test seam: raw rows (name, state, startMode).
    #>
    param([Parameter(Mandatory = $false)][AllowNull()][object[]] $Services)

    $rows = @()
    if ($null -ne $Services) {
        $rows = @($Services)
    }
    else {
        $rows = @(Get-PcxEnvironmentAnticheatRows)
    }

    $installed = New-Object System.Collections.Generic.List[string]
    $running = New-Object System.Collections.Generic.List[string]
    $idle = New-Object System.Collections.Generic.List[string]

    foreach ($row in $rows) {
        if ($null -eq $row) { continue }

        $name = ([string](Get-PcxPolicyMember -Object $row -Name 'name')).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($script:PcxEnvironmentAnticheatServices -notcontains $name) { continue }
        if ($installed -contains $name) { continue }

        $state = ([string](Get-PcxPolicyMember -Object $row -Name 'state')).Trim()
        $startMode = ([string](Get-PcxPolicyMember -Object $row -Name 'startMode')).Trim()

        [void]$installed.Add($name)
        if ([string]::Equals($state, 'Running', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$running.Add($name)
        }
        else {
            $label = if ([string]::IsNullOrWhiteSpace($state)) { 'not running' } else { $state }
            if (-not [string]::IsNullOrWhiteSpace($startMode)) { $label = "$label ($startMode)" }
            [void]$idle.Add(("{0} is {1}" -f $name, $label))
        }
    }

    $installedSorted = @($installed | Sort-Object)
    $runningSorted = @($running | Sort-Object)

    if ($runningSorted.Count -gt 0) {
        $reason = 'active: {0} is Running.' -f ($runningSorted -join ', ')
    }
    elseif ($installedSorted.Count -gt 0) {
        $reason = 'installed but idle: {0}; no known anticheat service or driver is Running.' -f ($idle -join '; ')
    }
    else {
        $reason = 'no known anticheat service or driver is installed.'
    }

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
            present   = ($runningSorted.Count -gt 0)
            detected  = $runningSorted
            installed = $installedSorted
            reason    = $reason
        })
}

function Get-PcxEnvironmentDevDriveField {
    $volumes = @(Get-CimInstance -ClassName 'Win32_Volume' -ErrorAction Stop)
    $devVolumes = @()
    foreach ($volume in $volumes) {
        $driveType = ConvertTo-PcxEnvironmentInteger -Value (Get-PcxPolicyMember -Object $volume -Name 'DriveType')
        $fileSystem = [string](Get-PcxPolicyMember -Object $volume -Name 'FileSystem')
        if ($null -ne $driveType -and $driveType -eq 3 -and [string]::Equals($fileSystem, 'ReFS', [System.StringComparison]::OrdinalIgnoreCase)) {
            $devVolumes += [string](Get-PcxPolicyMember -Object $volume -Name 'DriveLetter')
        }
    }

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        present = ($devVolumes.Count -gt 0)
        volumes = $devVolumes
    })
}

function Get-PcxEnvironmentPrintersField {
    $printers = @(Get-CimInstance -ClassName 'Win32_Printer' -ErrorAction Stop)
    if ($printers.Count -eq 1 -and $null -eq $printers[0]) {
        return New-PcxEnvironmentUnavailable -Reason 'the printer probe returned no value'
    }

    return New-PcxEnvironmentMeasured -Value $printers.Count
}

function Get-PcxEnvironmentMemoryField {
    $system = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction Stop
    if ($null -eq $system) {
        return New-PcxEnvironmentUnavailable -Reason 'the computer system record is absent'
    }

    $total = Get-PcxPolicyMember -Object $system -Name 'TotalPhysicalMemory'
    if ($null -eq $total) {
        return New-PcxEnvironmentUnavailable -Reason 'the total physical memory value is absent'
    }

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        totalBytes = [long]$total
    })
}

function Get-PcxEnvironmentGpuField {
    $controllers = @(Get-CimInstance -ClassName 'Win32_VideoController' -ErrorAction Stop)
    $gpus = @()
    foreach ($controller in $controllers) {
        $gpus += [pscustomobject][ordered]@{
            name          = [string](Get-PcxPolicyMember -Object $controller -Name 'Name')
            driverVersion = [string](Get-PcxPolicyMember -Object $controller -Name 'DriverVersion')
            adapterRam    = Get-PcxPolicyMember -Object $controller -Name 'AdapterRAM'
        }
    }

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        controllers = $gpus
    })
}

function Get-PcxEnvironmentHagsField {
    # HwSchMode codes are the field value: 2 = on, 1 = off (the table's
    # is-off predicate and the performance.hags_mode number metric both read
    # the raw code). An absent value on an existing key is reported as
    # measured off, never as unreadable.
    $state = Read-PcxEnvironmentRegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'
    if ($state.outcome -eq 'unreadable') {
        return New-PcxEnvironmentUnavailable -Reason $state.reason
    }

    if ($state.outcome -eq 'present') {
        $value = ConvertTo-PcxEnvironmentInteger -Value $state.raw
        if ($null -eq $value) {
            return New-PcxEnvironmentUnavailable -Reason 'the HAGS value is not a number'
        }

        return New-PcxEnvironmentMeasured -Value $value
    }

    return New-PcxEnvironmentMeasured -Value 1
}

function Get-PcxEnvironmentGameDvrField {
    $appCapture = Read-PcxEnvironmentRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled'
    $gameDvr = Read-PcxEnvironmentRegistryValue -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled'

    if ($null -eq $appCapture -and $null -eq $gameDvr) {
        return New-PcxEnvironmentUnavailable -Reason 'neither GameDVR value could be read'
    }

    $appCaptureValue = ConvertTo-PcxEnvironmentInteger -Value $appCapture
    $gameDvrValue = ConvertTo-PcxEnvironmentInteger -Value $gameDvr
    $enabled = (($null -ne $appCaptureValue -and $appCaptureValue -eq 1) -or ($null -ne $gameDvrValue -and $gameDvrValue -eq 1))

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        appCaptureEnabled = $appCaptureValue
        gameDvrEnabled    = $gameDvrValue
        enabled           = $enabled
    })
}

function Get-PcxEnvironmentPowerPlanField {
    $guid = [string](Read-PcxEnvironmentRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme')
    if ([string]::IsNullOrWhiteSpace($guid)) {
        return New-PcxEnvironmentUnavailable -Reason 'the active power scheme value could not be read'
    }

    $normalized = $guid.Trim().ToLowerInvariant()
    $name = $normalized
    if ($script:PcxEnvironmentPowerPlans.ContainsKey($normalized)) {
        $name = $script:PcxEnvironmentPowerPlans[$normalized]
    }

    return New-PcxEnvironmentMeasured -Value ([pscustomobject][ordered]@{
        guid = $guid
        name = $name
    })
}

function Get-PcxLiveEnvironment {
    return [pscustomobject][ordered]@{
        schema     = $script:PcxEnvironmentSchema
        profile    = 'live'
        capturedAt = [System.DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        os         = Invoke-PcxEnvironmentProbe -Label 'os' -Probe { Get-PcxEnvironmentOsFields }
        sMode      = Invoke-PcxEnvironmentProbe -Label 's-mode' -Probe { Get-PcxEnvironmentSModeField }
        managed    = Invoke-PcxEnvironmentProbe -Label 'managed' -Probe { Get-PcxEnvironmentManagedField }
        vbs        = Invoke-PcxEnvironmentProbe -Label 'vbs' -Probe { Get-PcxEnvironmentVbsField }
        hvci       = Invoke-PcxEnvironmentProbe -Label 'hvci' -Probe { Get-PcxEnvironmentHvciField }
        bitLocker  = Invoke-PcxEnvironmentProbe -Label 'bitlocker' -Probe { Get-PcxEnvironmentBitLockerField }
        defender   = Invoke-PcxEnvironmentProbe -Label 'defender' -Probe { Get-PcxEnvironmentDefenderField }
        firewall   = Invoke-PcxEnvironmentProbe -Label 'firewall' -Probe { Get-PcxEnvironmentFirewallField }
        tpm        = Invoke-PcxEnvironmentProbe -Label 'tpm' -Probe { Get-PcxEnvironmentTpmField }
        anticheat  = Invoke-PcxEnvironmentProbe -Label 'anticheat' -Probe { Get-PcxEnvironmentAnticheatField }
        devDrive   = Invoke-PcxEnvironmentProbe -Label 'dev-drive' -Probe { Get-PcxEnvironmentDevDriveField }
        printers   = Invoke-PcxEnvironmentProbe -Label 'printers' -Probe { Get-PcxEnvironmentPrintersField }
        memory     = Invoke-PcxEnvironmentProbe -Label 'memory' -Probe { Get-PcxEnvironmentMemoryField }
        gpu        = Invoke-PcxEnvironmentProbe -Label 'gpu' -Probe { Get-PcxEnvironmentGpuField }
        hags       = Invoke-PcxEnvironmentProbe -Label 'hags' -Probe { Get-PcxEnvironmentHagsField }
        gameDvr    = Invoke-PcxEnvironmentProbe -Label 'game-dvr' -Probe { Get-PcxEnvironmentGameDvrField }
        powerPlan  = Invoke-PcxEnvironmentProbe -Label 'power-plan' -Probe { Get-PcxEnvironmentPowerPlanField }
        paths      = Get-PcxEnvironmentPaths
    }
}

# ---------------------------------------------------------------------------
# Public: environment detection
# ---------------------------------------------------------------------------

function Get-PcxEnvironment {
    <#
    .SYNOPSIS
        Reports the environment, from a fixture in tests or read-only from the OS.

    .DESCRIPTION
        Fixture resolution order: -FixturePath, then PCX_ENVIRONMENT_FIXTURE.
        In fixture mode (PCX_TEST_RUN set) a missing fixture is a typed refusal,
        never a live read.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][string] $FixturePath)

    $fixture = $FixturePath
    if ([string]::IsNullOrWhiteSpace($fixture)) {
        $fixture = [string]$env:PCX_ENVIRONMENT_FIXTURE
    }

    if (-not [string]::IsNullOrWhiteSpace($fixture)) {
        return Read-PcxEnvironmentFixture -Path $fixture
    }

    if (-not [string]::IsNullOrEmpty($env:PCX_TEST_RUN)) {
        throw [System.InvalidOperationException]::new('PCX-E-ENVIRONMENT-FIXTURE: fixture mode is active (PCX_TEST_RUN) but no fixture path was supplied; refusing to read the live OS.')
    }

    return Get-PcxLiveEnvironment
}

# ---------------------------------------------------------------------------
# Public: environment -> policy profile
# ---------------------------------------------------------------------------

function ConvertTo-PcxEnvironmentBoolFact {
    param([Parameter(Mandatory = $false)][AllowNull()][object] $Field)

    if ($null -eq $Field) {
        return $null
    }

    $status = [string](Get-PcxPolicyMember -Object $Field -Name 'status')
    if ($status -ne 'measured') {
        return $null
    }

    $value = Get-PcxPolicyMember -Object $Field -Name 'value'
    if ($value -is [bool]) {
        return $value
    }

    # Rich probes (dev drive, anticheat) carry a present flag; managed and
    # S Mode are plain booleans.
    if (Test-PcxEnvironmentHasMember -Object $value -Name 'present') {
        $present = Get-PcxPolicyMember -Object $value -Name 'present'
        if ($present -is [bool]) {
            return $present
        }
        if ([string]$present -ieq 'true') { return $true }
        if ([string]$present -ieq 'false') { return $false }
    }

    if ([string]$value -ieq 'true') { return $true }
    if ([string]$value -ieq 'false') { return $false }

    return $null
}

function ConvertTo-PcxPolicyProfile {
    <#
    .SYNOPSIS
        Turns an environment object into the -Profile shape Test-PcxTarget reads.

    .DESCRIPTION
        Non-measured facts become $null (unknown), so the policy fails closed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][object] $Environment)

    $paths = Get-PcxPolicyMember -Object $Environment -Name 'paths'
    $environmentMap = @{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA', 'SYSTEMROOT')) {
        $value = Get-PcxPolicyMember -Object $paths -Name $name
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
            $environmentMap[$name] = $value
        }
    }

    return [pscustomobject][ordered]@{
        managed      = ConvertTo-PcxEnvironmentBoolFact -Field (Get-PcxPolicyMember -Object $Environment -Name 'managed')
        sMode        = ConvertTo-PcxEnvironmentBoolFact -Field (Get-PcxPolicyMember -Object $Environment -Name 'sMode')
        devDrive     = ConvertTo-PcxEnvironmentBoolFact -Field (Get-PcxPolicyMember -Object $Environment -Name 'devDrive')
        anticheat    = ConvertTo-PcxEnvironmentBoolFact -Field (Get-PcxPolicyMember -Object $Environment -Name 'anticheat')
        serviceFacts = @{}
        environment  = $environmentMap
    }
}
