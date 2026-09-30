[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$ResultPath = '',
    [switch]$ElevatedApply,
    [string]$RequesterSid = '',
    [switch]$CiNoElevation,
    [switch]$CiNoRelaunch,
    [switch]$CiCancelBeforeProtected,
    [switch]$CiPrivacyFailureProbe,
    [switch]$CiProtectedChildFailureProbe,
    [switch]$ReconcileFieldBaselineOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

$ExpectedVersion = '3.0.0-rc.1'
$ExpectedCode = [int64]30001001
$ExpectedChannel = 'preview'
$BaselineVersion = '3.0.0-phase5.2.1'
$BaselineCode = [int64]30000621
$AcceptedPreviousPreviews = @(
    [pscustomobject]@{ version = '3.0.0-phase6.4.0-preview'; versionCode = [int64]30000740 },
    [pscustomobject]@{ version = '3.0.0-phase6.4.1-preview'; versionCode = [int64]30000741 },
    [pscustomobject]@{ version = '3.0.0-phase6.4.3-preview'; versionCode = [int64]30000743 }
)
$GuardianSnapshotPath = Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair\guardian-known-good.json'
$StateDir = Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$ProgramDir = Join-Path $env:ProgramData 'TailscaleQuickRepair'
$VersionPath = Join-Path $StateDir 'version.user.json'
$MarkerPath = Join-Path $StateDir 'protected-update.json'
$AutoRepairSettingsPath = Join-Path $StateDir 'auto-repair.json'
$RestartRegistryPath = 'HKCU:\Software\TailscaleQuickRepair'
$RestartRegistryName = 'PendingRestartVersionCode'
$script:WorkRoots = New-Object 'Collections.Generic.List[string]'
$script:LeaseType = $null
$script:LeaseHeld = $false

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $OutputDirectory 'phase6.4-field-result.json'
}
try {
    # UAC can launch the elevated child with a different current directory.
    # Freeze the result location before any child process starts so both
    # processes always read and write the same privacy-safe result file.
    $ResultPath = [IO.Path]::GetFullPath($ResultPath)
} catch {
    throw 'The Phase 6.4 field result path could not be resolved safely.'
}

$result = [ordered]@{
    schema = 1
    version = $ExpectedVersion
    versionCode = $ExpectedCode
    stage = 'preflight'
    baselineVerified = $false
    bridgeVerified = $false
    bridgeApplied = $false
    bridgeRefreshed = $false
    installedCandidateVerified = $false
    integrityBaselineRetired = $false
    elevationRequested = $false
    elevationCancelled = $false
    protectedUnchangedOnCancel = $false
    requesterIdentityVerified = $false
    protectedPackageVerified = $false
    protectedApplied = $false
    restartAcknowledged = $false
    autoRepairWasOff = $false
    passed = $false
    error = ''
}

function Save-Result {
    try {
        $parent = Split-Path -Parent $ResultPath
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    } catch {}
}

function Fail([string]$Message) {
    $result.error = $Message
    Save-Result
    throw $Message
}

function New-WorkRoot([string]$Name) {
    $root = Join-Path $env:TEMP ($Name + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $script:WorkRoots.Add($root)
    return $root
}

function Get-OneCandidate([string]$Pattern) {
    $items = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter $Pattern -File -ErrorAction Stop)
    if ($items.Count -ne 1) { Fail "Expected exactly one candidate file matching $Pattern." }
    return $items[0].FullName
}

function Assert-Sidecar([string]$File) {
    $sidecar = $File + '.sha256'
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { Fail "Missing SHA-256 sidecar for $([IO.Path]::GetFileName($File))." }
    $expected = ([IO.File]::ReadAllText($sidecar,[Text.Encoding]::ASCII)).Trim().ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') { Fail 'Candidate SHA-256 sidecar is invalid.' }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) { Fail "Candidate file hash mismatch: $([IO.Path]::GetFileName($File))." }
}

function Expand-Candidate([string]$Zip,[bool]$AllowProgram,[bool]$RequireMarker) {
    Assert-Sidecar $Zip
    $root = New-WorkRoot 'TqrFieldPreview'
    Expand-Archive -LiteralPath $Zip -DestinationPath $root -Force
    $manifestPath = Join-Path $root 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Fail 'Candidate package manifest is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($manifest.schema -ne 1 -or [string]$manifest.version -cne $ExpectedVersion -or [int64]$manifest.versionCode -ne $ExpectedCode) {
        Fail 'Candidate package identity does not match the release-candidate preview.'
    }
    $declared = @($manifest.files)
    if ($declared.Count -lt 1) { Fail 'Candidate package contains no declared files.' }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $markerCount = 0
    foreach ($entry in $declared) {
        $relative = ([string]$entry.path).Replace('\\','/')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('..') -or $relative.StartsWith('/') -or $relative.Contains(':')) {
            Fail 'Candidate package contains an unsafe path.'
        }
        if (-not $seen.Add($relative)) { Fail 'Candidate package contains a duplicate path.' }
        if (-not $AllowProgram -and $relative.StartsWith('program/',[StringComparison]::OrdinalIgnoreCase)) {
            Fail 'The ordinary preview package unexpectedly contains protected program files.'
        }
        if ($relative -ieq 'app/protected-update.json') { $markerCount++ }
        $file = Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Fail "Candidate package file is missing: $relative" }
        if ((Get-Item -LiteralPath $file).Length -ne [int64]$entry.size) { Fail "Candidate package file size mismatch: $relative" }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne ([string]$entry.sha256).ToLowerInvariant()) {
            Fail "Candidate package file hash mismatch: $relative"
        }
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $members = New-Object 'Collections.Generic.List[string]'
        $manifestMembers = 0
        foreach ($zipEntry in $archive.Entries) {
            $name = ([string]$zipEntry.FullName).Replace('\','/')
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('..') -or $name.StartsWith('/') -or $name.Contains(':')) {
                Fail 'Candidate archive contains an unsafe member path.'
            }
            if ([string]::IsNullOrEmpty([string]$zipEntry.Name)) {
                continue
            }
            if ($name -ceq 'package-manifest.json') {
                $manifestMembers++
                continue
            }
            $members.Add($name)
        }
        if ($manifestMembers -ne 1) { Fail 'Candidate archive must contain exactly one package manifest.' }
        if ($members.Count -ne $seen.Count) {
            Fail "Candidate archive membership count does not match its manifest ($($members.Count) archive files / $($seen.Count) declared)."
        }
        foreach ($relative in $members) {
            if (-not $seen.Contains($relative)) { Fail "Candidate archive contains an undeclared payload file: $relative" }
        }
    }
    finally {
        $archive.Dispose()
    }
    if ($RequireMarker -and $markerCount -ne 1) {
        Fail 'The ordinary preview package must contain exactly one protected-update marker.'
    }
    if ($RequireMarker) {
        $markerPath = Join-Path $root 'app\protected-update.json'
        try { $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { Fail 'The protected-update marker is unreadable.' }
        $markerNames = @($marker.PSObject.Properties.Name)
        if (
            $markerNames.Count -ne 3 -or
            'schema' -notin $markerNames -or
            'versionCode' -notin $markerNames -or
            'channel' -notin $markerNames -or
            $marker.schema -isnot [int] -or
            [int]$marker.schema -ne 2 -or
            [int64]$marker.versionCode -ne $ExpectedCode -or
            [string]$marker.channel -cne $ExpectedChannel
        ) {
            Fail 'The ordinary preview package has the wrong protected-update channel binding.'
        }
    }
    if (-not $RequireMarker -and $markerCount -ne 0) { Fail 'The protected Setup package must not contain the bridge-only marker.' }
    return [pscustomobject]@{ root=$root; manifest=$manifest }
}

function Invoke-Private([Type]$Type,[string]$Name,[object[]]$Arguments=@()) {
    $method = $Type.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    if (-not $method) { Fail "Required preview boundary is missing: $Name" }
    $native = New-Object object[] $Arguments.Count
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($null -eq $Arguments[$i]) { $native[$i] = $null }
        else { $native[$i] = $Arguments[$i].PSObject.BaseObject }
    }
    try { return ,($method.Invoke($null,$native)) }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        throw $ex
    }
}

function Current-Sid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity -or -not $identity.User) { Fail 'The current Windows account could not be verified.' }
    $sid = $identity.User.Value
    if ($sid -notmatch '^S-1-[0-9-]+$') { Fail 'The current Windows SID is invalid.' }
    return $sid
}

function Assert-AutoRepairOff {
    if (-not (Test-Path -LiteralPath $AutoRepairSettingsPath -PathType Leaf)) {
        $result.autoRepairWasOff = $true
        return
    }
    try {
        $settings = Get-Content -LiteralPath $AutoRepairSettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $names = @($settings.PSObject.Properties.Name)
        if ('enabled' -notin $names -or $settings.enabled -isnot [bool]) { Fail 'Auto Repair settings are not readable safely.' }
        if ([bool]$settings.enabled) { Fail 'Turn Auto Repair off before the initial Phase 6.4 field upgrade.' }
        $result.autoRepairWasOff = $true
    } catch { Fail 'Auto Repair settings could not be verified. No field upgrade was started.' }
}

function Assert-NoQuickRepairUi {
    $busy = $false
    try {
        foreach ($p in Get-CimInstance Win32_Process -ErrorAction Stop) {
            $name = [string]$p.Name
            $line = [string]$p.CommandLine
            if ($name -ieq 'TailscaleQuickRepair.exe' -or $line -match 'Tailscale-Repair-UI\.ps1') { $busy = $true; break }
        }
    } catch { Fail 'Could not verify that Quick Repair is closed.' }
    if ($busy) { Fail 'Exit Quick Repair from its tray menu before running the Phase 6.4 field preview.' }
}

function Get-ProtectedBaselineHashes {
    $required = @('Repair-Backend.ps1','Auto-Repair-Monitor.ps1','TailscaleQuickRepair.Operations.dll')
    $hashes = [ordered]@{}
    foreach ($name in $required) {
        $path = Join-Path $ProgramDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Fail 'The installed protected field baseline is incomplete. No field upgrade was started.'
        }
        $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($hashes.Count -ne $required.Count) { Fail 'The protected baseline could not be captured completely.' }
    return $hashes
}

function Assert-ProtectedHashesUnchanged($Before) {
    $required = @('Repair-Backend.ps1','Auto-Repair-Monitor.ps1','TailscaleQuickRepair.Operations.dll')
    if (-not $Before -or $Before.Count -ne $required.Count) { return $false }
    foreach ($name in $required) {
        if ($Before.Keys -notcontains $name) { return $false }
        $path = Join-Path $ProgramDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Before[$name]) { return $false }
    }
    return $true
}

function Assert-CiFieldMode {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean') {
        Fail 'CI field mode is restricted to the disposable GitHub acceptance runner.'
    }
}

function Read-InstalledVersion {
    if (-not (Test-Path -LiteralPath $VersionPath -PathType Leaf)) { Fail 'Quick Repair is not installed for this Windows account.' }
    try { return (Get-Content -LiteralPath $VersionPath -Raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { Fail 'The installed Quick Repair version record is invalid.' }
}

function Assert-PreviousPreviewKnownGood([int64]$ExpectedPreviousCode) {
    if (-not (Test-Path -LiteralPath $GuardianSnapshotPath -PathType Leaf)) {
        Fail 'The installed previous preview has no established known-good integrity baseline.'
    }
    if (((Get-Item -LiteralPath $GuardianSnapshotPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'The previous preview known-good record is redirected.'
    }

    $installedManifest = Join-Path $StateDir 'integrity-manifest.json'
    if (-not (Test-Path -LiteralPath $installedManifest -PathType Leaf)) {
        Fail 'The installed previous preview has no integrity manifest.'
    }
    if (((Get-Item -LiteralPath $installedManifest).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'The installed previous preview integrity manifest is redirected.'
    }

    try {
        $snapshot = Get-Content -LiteralPath $GuardianSnapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Fail 'The previous preview known-good record is unreadable.'
    }

    $recordedHash = ([string]$snapshot.integrityManifestSha256).ToLowerInvariant()
    if ([int]$snapshot.schema -ne 1 -or [int64]$snapshot.versionCode -ne $ExpectedPreviousCode -or
        $recordedHash -notmatch '^[0-9a-f]{64}$') {
        Fail 'The previous preview known-good record does not match the accepted preview identity.'
    }

    $actualHash = (Get-FileHash -LiteralPath $installedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $recordedHash) {
        Fail 'The previous preview integrity manifest does not match its known-good record.'
    }
}

function Get-InstalledCandidateTarget([string]$Relative) {
    $relativePath = $Relative.Replace('\','/')
    if ($relativePath -ceq 'version.json') { return $VersionPath }
    if ($relativePath.StartsWith('app/',[StringComparison]::OrdinalIgnoreCase)) {
        return (Join-Path $StateDir $relativePath.Substring(4).Replace('/',[IO.Path]::DirectorySeparatorChar))
    }
    if ($relativePath.StartsWith('program/',[StringComparison]::OrdinalIgnoreCase)) {
        return (Join-Path $ProgramDir $relativePath.Substring(8).Replace('/',[IO.Path]::DirectorySeparatorChar))
    }
    Fail 'Protected candidate contains an unsupported installed path.'
}

function Assert-ExactInstalledCandidate($protected) {
    $installed = Read-InstalledVersion
    if ([string]$installed.version -cne $ExpectedVersion -or [int64]$installed.versionCode -ne $ExpectedCode) {
        Fail 'Field reconciliation requires the exact installed release-candidate preview.'
    }
    if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
        Fail 'Field reconciliation refused an unfinished protected-update marker.'
    }

    foreach ($entry in @($protected.manifest.files)) {
        $relative = ([string]$entry.path).Replace('\','/')
        $target = Get-InstalledCandidateTarget $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Fail 'The installed Phase 6.4 candidate is incomplete.'
        }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = ([string]$entry.sha256).ToLowerInvariant()
        if ($actual -cne $expected) {
            Fail 'The installed Phase 6.4 candidate does not match the verified field package.'
        }
    }
}

function Retire-StaleFieldGuardianBaseline($candidate) {
    $candidateManifest = Join-Path $candidate.root 'app\integrity-manifest.json'
    if (-not (Test-Path -LiteralPath $candidateManifest -PathType Leaf)) {
        Fail 'The verified field candidate is missing its integrity manifest.'
    }
    $candidateHash = (Get-FileHash -LiteralPath $candidateManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    $snapshotPath = Join-Path $StateDir 'guardian-known-good.json'
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { return $false }

    if (((Get-Item -LiteralPath $snapshotPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'Field reconciliation refused a redirected known-good record.'
    }

    try {
        $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Fail 'Field reconciliation refused an unreadable known-good record.'
    }

    $recordedHash = ([string]$snapshot.integrityManifestSha256).ToLowerInvariant()
    if ([int]$snapshot.schema -ne 1 -or [int64]$snapshot.versionCode -le 0 -or
        $recordedHash -notmatch '^[0-9a-f]{64}$') {
        Fail 'Field reconciliation refused invalid known-good metadata.'
    }

    if ([int64]$snapshot.versionCode -gt $ExpectedCode) {
        Fail 'Field reconciliation refused a known-good record from a newer version.'
    }
    if ([int64]$snapshot.versionCode -ne $ExpectedCode -or $recordedHash -ceq $candidateHash) {
        return $false
    }

    $previousPath = Join-Path $StateDir 'guardian-known-good.previous.json'
    if (Test-Path -LiteralPath $previousPath) {
        if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf) -or
            ((Get-Item -LiteralPath $previousPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail 'Field reconciliation refused an unsafe predecessor record.'
        }
    }

    $temp = $previousPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $replaceBackup = $previousPath + '.' + [Guid]::NewGuid().ToString('N') + '.replace-backup'
    try {
        $bytes = [IO.File]::ReadAllBytes($snapshotPath)
        $stream = [IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $previousPath) {
            # .NET Framework on Windows does not accept a null backup path for
            # File.Replace. Use a same-directory temporary backup so replacing
            # an existing predecessor remains atomic, then discard that older
            # predecessor only after the replacement succeeds.
            [IO.File]::Replace($temp,$previousPath,$replaceBackup)
            [IO.File]::Delete($replaceBackup)
        }
        else {
            [IO.File]::Move($temp,$previousPath)
        }
        [IO.File]::Delete($snapshotPath)
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }

    $result.integrityBaselineRetired = $true
    return $true
}

function Apply-BridgePackage($ordinary,[string]$UpdaterSource,[string]$UpdaterError) {
    if (-not (Test-Path -LiteralPath $UpdaterSource -PathType Leaf)) { Fail $UpdaterError }
    $tempUpdater = Join-Path (New-WorkRoot 'TqrFieldUpdater') 'TailscaleQuickRepairUpdater.exe'
    Copy-Item -LiteralPath $UpdaterSource -Destination $tempUpdater -Force
    $type = [Reflection.Assembly]::LoadFile($tempUpdater).GetType('Program')
    if (-not $type) { Fail 'The selected updater host is not valid.' }
    $manifest = Invoke-Private $type 'ReadPackageManifest' @($ordinary.root)
    if ([string]$manifest.Version -cne $ExpectedVersion -or [int64]$manifest.VersionCode -ne $ExpectedCode) { Fail 'The staged package identity is wrong.' }
    $files = Invoke-Private $type 'VerifyPackageFiles' @($ordinary.root,$manifest)
    if (@($files).Count -lt 1) { Fail 'The updater rejected the preview bridge.' }
    $lease = [bool](Invoke-Private $type 'TryAcquireOperationLock' @('update'))
    if (-not $lease) { Fail 'Another Quick Repair operation is active. No bridge was applied.' }
    $script:LeaseType = $type
    $script:LeaseHeld = $true
    try {
        [void](Invoke-Private $type 'ApplyTransaction' @($files,[string]$manifest.Version,[int64]$manifest.VersionCode))
    } finally {
        [void](Invoke-Private $type 'ReleaseOperationLock')
        $script:LeaseHeld = $false
    }
    $after = Read-InstalledVersion
    if ([int64]$after.versionCode -ne $ExpectedCode -or [string]$after.version -cne $ExpectedVersion -or
        -not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        Fail 'The updater did not leave the expected protected bridge state.'
    }
    $result.bridgeApplied = $true
}

function Stage-Bridge($ordinary) {
    $installed = Read-InstalledVersion
    Assert-NoQuickRepairUi

    if ([int64]$installed.versionCode -eq $ExpectedCode -and [string]$installed.version -ceq $ExpectedVersion -and
        (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        # A retry of the same unpublished candidate refreshes every verified
        # user-level bridge byte before protected Setup continues.
        $candidateUpdater = Join-Path $ordinary.root 'app\TailscaleQuickRepairUpdater.exe'
        Apply-BridgePackage $ordinary $candidateUpdater 'The verified candidate updater is missing.'
        $result.bridgeRefreshed = $true
        return
    }

    if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
        Fail 'A different protected field update is still unfinished. Complete that handoff before staging this candidate.'
    }
    $pending = Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction SilentlyContinue
    if ($pending -and $null -ne $pending.$RestartRegistryName) {
        Fail 'A previous protected update is still awaiting restart acknowledgement.'
    }

    $isPublicBaseline = ([int64]$installed.versionCode -eq $BaselineCode -and [string]$installed.version -ceq $BaselineVersion)
    $previousPreviewMatches = @($AcceptedPreviousPreviews | Where-Object {
        [int64]$installed.versionCode -eq [int64]$_.versionCode -and
        [string]$installed.version -ceq [string]$_.version
    })
    if ($previousPreviewMatches.Count -gt 1) {
        Fail 'Accepted previous-preview policy is ambiguous.'
    }
    $isPreviousPreview = ($previousPreviewMatches.Count -eq 1)
    if (-not $isPublicBaseline -and -not $isPreviousPreview) {
        Fail 'Field preview staging requires the genuine public baseline, an explicitly accepted previous preview, or an already-staged current bridge.'
    }

    if ($isPreviousPreview) {
        Assert-PreviousPreviewKnownGood ([int64]$previousPreviewMatches[0].versionCode)
    }

    $result.baselineVerified = $true
    $installedUpdater = Join-Path $StateDir 'TailscaleQuickRepairUpdater.exe'
    Apply-BridgePackage $ordinary $installedUpdater 'The installed updater for the accepted field baseline is missing.'
}

function Apply-Protected($protected,[string]$ExpectedRequesterSid) {
    $result.stage = 'protected_admin'
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'The protected field stage is not running with administrator approval.'
    }

    $result.stage = 'protected_identity'
    $currentSid = Current-Sid
    if ([string]::IsNullOrWhiteSpace($ExpectedRequesterSid) -or $currentSid -cne $ExpectedRequesterSid) {
        Fail 'Administrator approval used a different Windows account. Protected changes were refused.'
    }
    $result.requesterIdentityVerified = $true

    if ($CiProtectedChildFailureProbe) {
        Assert-CiFieldMode
        $result.stage = 'protected_ci_failure_probe'
        throw [InvalidOperationException]::new('CI protected child failure probe.')
    }

    $installedSetup = Join-Path $StateDir 'TailscaleQuickRepairSetup.exe'
    if (-not (Test-Path -LiteralPath $installedSetup -PathType Leaf)) { Fail 'The refreshed Setup host is missing after bridge staging.' }

    # Production Setup relocates itself before replacing the installed Setup
    # executable. The developer-only field harness invokes the protected core
    # by reflection, so mirror that same lock boundary with a detached copy.
    $detachedRoot = New-WorkRoot 'TqrFieldSetupHost'
    $setup = Join-Path $detachedRoot 'TailscaleQuickRepairSetup.exe'
    Copy-Item -LiteralPath $installedSetup -Destination $setup -Force
    if ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $installedSetup -Algorithm SHA256).Hash) {
        Fail 'The detached Setup host did not match the staged installed Setup.'
    }

    $type = [Reflection.Assembly]::LoadFile($setup).GetType('PublicSetupHost')
    if (-not $type) { Fail 'The refreshed Setup host is invalid.' }
    [void](Invoke-Private $type 'RequireRequesterIdentity' @($ExpectedRequesterSid))

    $result.stage = 'protected_recovery'
    [void](Invoke-Private $type 'RecoverInterruptedFileTransaction')

    $result.stage = 'protected_package_read'
    $manifest = Invoke-Private $type 'ReadPackageManifest' @($protected.root)
    if ([string]$manifest.Version -cne $ExpectedVersion -or [int64]$manifest.VersionCode -ne $ExpectedCode) { Fail 'The protected package identity is wrong.' }

    $result.stage = 'protected_package_verify'
    $files = Invoke-Private $type 'VerifyPackage' @($protected.root,$manifest)

    $result.stage = 'protected_marker'
    [void](Invoke-Private $type 'ValidateProtectedUpdateMarker' @([int64]$manifest.VersionCode,$ExpectedChannel))
    $result.protectedPackageVerified = $true

    $result.stage = 'protected_context'
    $peer = [string](Invoke-Private $type 'ReadConfiguredPeer')
    $startup = [bool](Invoke-Private $type 'IsStartupEnabled')

    $result.stage = 'protected_lease'
    $lease = [bool](Invoke-Private $type 'TryAcquireUpgradeOperationLock')
    if (-not $lease) { Fail 'Another Quick Repair operation is active. Protected changes were not started.' }
    $script:LeaseType = $type
    $script:LeaseHeld = $true
    $work = New-WorkRoot 'TqrFieldProtected'

    try {
        $result.stage = 'protected_stop_ui'
        [void](Invoke-Private $type 'StopQuickRepair')

        $result.stage = 'protected_files'
        try {
            [void](Invoke-Private $type 'ApplyFiles' @($files,$work))
        } catch {
            $message = [string]$_.Exception.Message
            $code = [int]$_.Exception.HResult
            if ($code -eq -2147024864) {
                $result.stage = 'protected_files_locked'
            } elseif ($code -eq -2147024891 -or $_.Exception -is [UnauthorizedAccessException]) {
                $result.stage = 'protected_files_access'
            } elseif ($message -match 'recovery|journal|backup') {
                $result.stage = 'protected_files_recovery'
            } elseif ($message -match 'temporary path|setup\.new') {
                $result.stage = 'protected_files_temporary'
            } elseif ($message -match 'unexpected content|unexpected type|redirected|unsupported link|legacy migration') {
                $result.stage = 'protected_files_layout'
            }
            throw
        }

        $result.stage = 'protected_integration'
        [void](Invoke-Private $type 'CompleteInstalledIntegration' @($peer,$startup,$true,[int64]$manifest.VersionCode))
        $result.protectedApplied = $true

        if (-not $CiNoRelaunch) {
            $result.stage = 'protected_relaunch'
            [void](Invoke-Private $type 'StartQuickRepair')
        }

        $result.stage = 'protected_complete'
    } finally {
        [void](Invoke-Private $type 'ReleaseOperationLock')
        $script:LeaseHeld = $false
    }
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ($ElevatedApply) {
        $result.stage = 'protected_elevated_preflight'
        Save-Result
    }
    if ($CiPrivacyFailureProbe) {
        Assert-CiFieldMode
        throw [InvalidOperationException]::new(('CI privacy probe local path: ' + $env:USERPROFILE))
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { Fail 'The validated candidate folder was not found.' }
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $ordinaryZip = Get-OneCandidate ('TailscaleQuickRepair-' + $ExpectedVersion + '.zip')
    $setupZip = Get-OneCandidate ('TailscaleQuickRepair-SetupPackage-' + $ExpectedVersion + '.zip')
    $ordinary = Expand-Candidate $ordinaryZip $false $true
    $protected = Expand-Candidate $setupZip $true $false
    $result.bridgeVerified = $true
    $result.protectedPackageVerified = $true

    if ($ReconcileFieldBaselineOnly) {
        if ($ElevatedApply -or $CiNoElevation -or $CiNoRelaunch -or $CiCancelBeforeProtected -or
            $CiPrivacyFailureProbe -or $CiProtectedChildFailureProbe) {
            Fail 'Field baseline reconciliation cannot be combined with another field mode.'
        }

        $result.stage = 'field_baseline_reconcile'
        Assert-AutoRepairOff
        Assert-NoQuickRepairUi
        Assert-ExactInstalledCandidate $protected
        $result.installedCandidateVerified = $true

        $pending = Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction SilentlyContinue
        if ($pending -and $null -ne $pending.$RestartRegistryName) {
            Fail 'Field reconciliation requires the restarted app to acknowledge the protected update first.'
        }
        $result.restartAcknowledged = $true

        [void](Retire-StaleFieldGuardianBaseline $protected)
        $result.stage = 'field_baseline_complete'
        $result.passed = $true
        Save-Result
        Write-Host 'Phase 6.4 field baseline reconciliation completed successfully.'
        exit 0
    }

    if ($ElevatedApply) {
        $result.stage = 'protected_apply'
        Apply-Protected $protected $RequesterSid
        $result.passed = $true
        Save-Result
        exit 0
    }

    $result.stage = 'baseline'
    Assert-AutoRepairOff
    $sid = Current-Sid
    $protectedBefore = Get-ProtectedBaselineHashes
    Stage-Bridge $ordinary

    if ($CiCancelBeforeProtected) {
        if ($CiNoElevation) { Fail 'Only one CI protected-stage mode may be selected.' }
        Assert-CiFieldMode
        $result.stage = 'ci_uac_cancel'
        $result.elevationRequested = $true
        $result.elevationCancelled = $true
        $result.protectedUnchangedOnCancel = Assert-ProtectedHashesUnchanged $protectedBefore
        if (-not $result.protectedUnchangedOnCancel) {
            Fail 'The simulated approval cancellation did not preserve the complete protected baseline.'
        }
        $result.error = ''
        Save-Result
        exit 2
    }

    if ($CiNoElevation) {
        Assert-CiFieldMode
        $result.stage = 'ci_protected_apply'
        Apply-Protected $protected $sid
    } else {
        $result.stage = 'uac'
        $result.elevationRequested = $true
        Save-Result
        $powershell = Join-Path $PSHOME 'powershell.exe'
        $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -OutputDirectory "' + $OutputDirectory + '" -ResultPath "' + $ResultPath + '" -ElevatedApply -RequesterSid "' + $sid + '"'
        if ($CiProtectedChildFailureProbe) {
            Assert-CiFieldMode
            $args += ' -CiProtectedChildFailureProbe -CiNoRelaunch'
        }
        try {
            if ($CiProtectedChildFailureProbe) {
                $probeWorkingDirectory = Join-Path $env:WINDIR 'System32'
                $process = Start-Process -FilePath $powershell -ArgumentList $args -WorkingDirectory $probeWorkingDirectory -PassThru -ErrorAction Stop
            } else {
                $process = Start-Process -FilePath $powershell -ArgumentList $args -WorkingDirectory $OutputDirectory -Verb RunAs -PassThru -ErrorAction Stop
            }

            # Start-Process -Wait on Windows can wait for the descendant process
            # tree. Protected Setup intentionally relaunches resident Quick Repair,
            # so waiting that way can hold the field console open indefinitely.
            # Wait only for the direct elevated child, with a bounded timeout.
            if (-not $process.WaitForExit(180000)) {
                $result.stage = 'protected_child_timeout'
                $result.error = 'The elevated protected field stage did not exit within the allowed time.'
                Save-Result
                throw 'The protected field stage timed out.'
            }
        } catch {
            if (-not $CiProtectedChildFailureProbe -and ($_.Exception.HResult -eq -2147467259 -or $_.Exception.Message -match 'cancel')) {
                $result.elevationCancelled = $true
                $result.protectedUnchangedOnCancel = Assert-ProtectedHashesUnchanged $protectedBefore
                if (-not $result.protectedUnchangedOnCancel) {
                    Fail 'Windows approval was cancelled, but protected files did not remain unchanged.'
                }
                $result.error = ''
                Save-Result
                Write-Host 'Windows approval was cancelled. The verified user-level bridge remains staged; protected files were unchanged. Rerun this field tool to retry.'
                exit 2
            }
            throw
        }

        $child = $null
        if (Test-Path -LiteralPath $ResultPath -PathType Leaf) {
            try {
                $candidate = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $candidateStage = [string]$candidate.stage
                if ([int]$candidate.schema -eq 1 -and
                    [string]$candidate.version -ceq $ExpectedVersion -and
                    [int64]$candidate.versionCode -eq $ExpectedCode -and
                    $candidateStage.StartsWith('protected_',[StringComparison]::Ordinal)) {
                    $child = $candidate
                }
            } catch {
                $child = $null
            }
        }

        if (-not $process -or $process.ExitCode -ne 0) {
            if ($child) {
                $result.stage = [string]$child.stage
                $result.requesterIdentityVerified = [bool]$child.requesterIdentityVerified
                $result.protectedPackageVerified = [bool]$child.protectedPackageVerified
                $result.protectedApplied = [bool]$child.protectedApplied
                $result.error = 'The elevated protected field stage failed. The recorded stage identifies the boundary.'
            } else {
                $result.stage = 'protected_failed'
                $result.error = 'The elevated protected field stage failed before returning a readable safe result.'
            }
            Save-Result
            throw 'The protected field stage did not complete.'
        }

        if ($child) {
            if (-not [bool]$child.passed -or -not [bool]$child.protectedApplied) { Fail 'The elevated protected stage did not report success.' }
            $result.requesterIdentityVerified = [bool]$child.requesterIdentityVerified
            $result.protectedPackageVerified = [bool]$child.protectedPackageVerified
            $result.protectedApplied = [bool]$child.protectedApplied
        } else {
            Fail 'The elevated protected stage did not return a readable result.'
        }
    }

    $result.stage = 'restart_acknowledgement'
    if (-not $CiNoRelaunch) {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 500
            $pending = Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction SilentlyContinue
            if (-not $pending -or $null -eq $pending.$RestartRegistryName) { $result.restartAcknowledged = $true; break }
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $result.restartAcknowledged) { Fail 'The preview installed, but the restarted app did not acknowledge the protected update.' }
    }

    if (Test-Path -LiteralPath $MarkerPath) { Fail 'The protected-update marker still exists after protected completion.' }
    $installed = Read-InstalledVersion
    if ([int64]$installed.versionCode -ne $ExpectedCode -or [string]$installed.version -cne $ExpectedVersion) { Fail 'The installed preview version record is wrong.' }
    $result.passed = $true
    $result.stage = 'complete'
    Save-Result
    Write-Host 'Release candidate field preview completed successfully.'
    exit 0
}
catch {
    if ([string]::IsNullOrWhiteSpace([string]$result.error)) {
        $result.error = 'Unexpected field-preview failure. No raw exception details were saved.'
    }
    Save-Result
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($script:LeaseHeld -and $script:LeaseType) {
        try { [void](Invoke-Private $script:LeaseType 'ReleaseOperationLock') } catch {}
    }
    foreach ($root in @($script:WorkRoots.ToArray())) {
        try { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } } catch {}
    }
}
