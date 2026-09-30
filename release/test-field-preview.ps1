param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EvidenceDirectory='.\upgrade-evidence'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$EvidenceDirectory=$EvidenceDirectory.Trim()
$development=($env:GITHUB_REF_NAME -ceq 'work/3.0')
$release=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or -not($development -or $release) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Field preview acceptance refused this environment.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if((git -C $repo rev-parse HEAD).Trim() -cne $env:GITHUB_SHA){throw 'Exact source required.'}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$lab=Join-Path $env:RUNNER_TEMP ('TqrFieldPreview-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($lab)
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair';$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$recovery=Join-Path $env:ProgramData 'TailscaleQuickRepair.SetupRecovery'
$cases=New-Object 'Collections.Generic.List[object]';$passed=$false;$failure=$null;$stage='preflight';$child=$null;$cleanup=$true
function Check([bool]$Value,[string]$Name){$script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value});if(-not $Value){throw 'Field preview assertion failed.'};Write-Host ('PASS field preview: '+$Name)}
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Check (-not(Test-Path $app) -and -not(Test-Path $program)) 'Field preview starts from an empty disposable Quick Repair installation'
    Check (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Hosted acceptance process has administrator rights for the no-UAC core path'

    $legacyUrl='https://github.com/coachedai/tailscale-repair-clean/releases/download/v3.0.0-phase5.2.1/TailscaleQuickRepair-SetupPackage-3.0.0-phase5.2.1.zip'
    $legacyHash='bad4deb522afd9442e918cacde1f58cc1509635de3be172626846060516df470'
    $legacyZip=Join-Path $lab 'legacy.zip'
    $wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','TqrFieldPreviewAcceptance');$wc.DownloadFile($legacyUrl,$legacyZip);$wc.Dispose()
    Check ((Get-Item $legacyZip).Length -eq 140164 -and (Get-FileHash $legacyZip).Hash -ieq $legacyHash) 'Pinned published 5.2.1 package is unchanged'
    $legacy=Join-Path $lab 'legacy';Expand-Archive -LiteralPath $legacyZip -DestinationPath $legacy
    $legacyManifest=Get-Content (Join-Path $legacy 'package-manifest.json') -Raw|ConvertFrom-Json
    Check ($legacyManifest.version -ceq '3.0.0-phase5.2.1' -and [int64]$legacyManifest.versionCode -eq 30000621) 'Fixture starts from genuine released 5.2.1 metadata'

    $ordinary=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-3.0.0-rc.1.zip' -File)
    $protected=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-SetupPackage-3.0.0-rc.1.zip' -File)
    Check ($ordinary.Count -eq 1 -and $protected.Count -eq 1) 'Exact RC1 ordinary and protected packages are present'

    $fieldSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'field-preview.ps1'))
    [void][scriptblock]::Create($fieldSource)
    Check $true 'Field preview parses under Windows PowerShell 5.1 before any field mutation'
    Check ($fieldSource -notmatch 'Start-Process[^\r\n]+-PassThru\s+-Wait') 'Field preview never waits on the relaunched Quick Repair descendant tree'
    Check ($fieldSource -match '\.WaitForExit\(180000\)') 'Field preview bounds the direct protected-child wait'

    $ordinaryRoot=Join-Path $lab 'candidate-ordinary'
    Expand-Archive -LiteralPath $ordinary[0].FullName -DestinationPath $ordinaryRoot
    $candidateSetup=Join-Path $ordinaryRoot 'app\TailscaleQuickRepairSetup.exe'
    Check (Test-Path -LiteralPath $candidateSetup -PathType Leaf) 'Ordinary candidate contains the refreshed installed Setup host'
    $candidateSetupHash=(Get-FileHash -LiteralPath $candidateSetup -Algorithm SHA256).Hash.ToLowerInvariant()

    $installReport=Join-Path $lab 'InstallLegacy.json'
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "'+(Join-Path $PSScriptRoot 'protected-handoff-child.ps1')+'" -Phase InstallLegacy -LegacyPackage "'+$legacy+'" -CurrentPackage "'+$legacy+'" -Report "'+$installReport+'"'
    $child=[Diagnostics.Process]::Start($psi)
    Check ($child.WaitForExit(120000) -and $child.ExitCode -eq 0) 'Genuine released Setup core installs the 5.2.1 baseline'
    $child.Dispose();$child=$null
    $installed=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($installed.version -ceq '3.0.0-phase5.2.1' -and [int64]$installed.versionCode -eq 30000621) 'Field harness sees the genuine 5.2.1 installed baseline'

    $protectedBaseline=[ordered]@{}
    foreach($name in @('Repair-Backend.ps1','Auto-Repair-Monitor.ps1','TailscaleQuickRepair.Operations.dll')){
        $path=Join-Path $program $name
        Check (Test-Path -LiteralPath $path -PathType Leaf) ('Published 5.2.1 protected baseline contains '+$name)
        $protectedBaseline[$name]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $privacyReport=Join-Path $evidence 'field-preview-privacy-probe.json'
    $privacyPsi=New-Object Diagnostics.ProcessStartInfo
    $privacyPsi.FileName=Join-Path $PSHOME 'powershell.exe';$privacyPsi.UseShellExecute=$false;$privacyPsi.CreateNoWindow=$true
    $privacyPsi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'field-preview.ps1')+'" -OutputDirectory "'+(Resolve-Path $OutputDirectory).Path+'" -ResultPath "'+$privacyReport+'" -CiPrivacyFailureProbe'
    $child=[Diagnostics.Process]::Start($privacyPsi)
    Check ($child.WaitForExit(30000) -and $child.ExitCode -eq 1 -and (Test-Path -LiteralPath $privacyReport -PathType Leaf)) 'Field preview privacy probe fails before mutation'
    $child.Dispose();$child=$null
    $privacyRaw=Get-Content -LiteralPath $privacyReport -Raw
    $privacy=$privacyRaw|ConvertFrom-Json
    Check ($privacy.passed -is [bool] -and -not $privacy.passed -and $privacy.error -ceq 'Unexpected field-preview failure. No raw exception details were saved.') 'Unexpected field failure persists only a curated error'
    Check ([string]::IsNullOrEmpty($env:USERPROFILE) -or -not $privacyRaw.Contains($env:USERPROFILE)) 'Field result does not persist the local user profile path'
    $stillBaseline=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ([int64]$stillBaseline.versionCode -eq 30000621 -and -not(Test-Path (Join-Path $app 'protected-update.json'))) 'Privacy probe cannot stage or mutate the installed baseline'

    $cancelReport=Join-Path $evidence 'field-preview-cancel-results.json'
    $cancelPsi=New-Object Diagnostics.ProcessStartInfo
    $cancelPsi.FileName=Join-Path $PSHOME 'powershell.exe';$cancelPsi.UseShellExecute=$false;$cancelPsi.CreateNoWindow=$true
    $cancelPsi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'field-preview.ps1')+'" -OutputDirectory "'+(Resolve-Path $OutputDirectory).Path+'" -ResultPath "'+$cancelReport+'" -CiCancelBeforeProtected -CiNoRelaunch'
    $child=[Diagnostics.Process]::Start($cancelPsi)
    Check ($child.WaitForExit(180000) -and $child.ExitCode -eq 2 -and (Test-Path -LiteralPath $cancelReport -PathType Leaf)) 'Field preview simulates UAC cancellation only after the verified bridge is staged'
    $child.Dispose();$child=$null
    $cancel=Get-Content -LiteralPath $cancelReport -Raw|ConvertFrom-Json
    Check ($cancel.baselineVerified -and $cancel.bridgeVerified -and $cancel.bridgeApplied -and $cancel.elevationRequested -and $cancel.elevationCancelled -and $cancel.protectedUnchangedOnCancel -and -not $cancel.protectedApplied) 'Cancellation result records the complete pre-protected boundary'
    foreach($name in $protectedBaseline.Keys){
        $path=Join-Path $program $name
        $expectedHash=[string]$protectedBaseline[$name]
        Check ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedHash) ('Cancellation preserves protected 5.2.1 hash for '+$name)
    }
    $staged=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ([int64]$staged.versionCode -eq 30001001 -and (Test-Path (Join-Path $app 'protected-update.json') -PathType Leaf)) 'Cancellation leaves only the verified RC1 bridge staged for retry'
    $cancelMarker=Get-Content (Join-Path $app 'protected-update.json') -Raw|ConvertFrom-Json
    Check ([int]$cancelMarker.schema -eq 2 -and [int64]$cancelMarker.versionCode -eq 30001001 -and [string]$cancelMarker.channel -ceq 'preview') 'Cancellation preserves the exact schema-2 Preview handoff marker'

    $installedSetup=Join-Path $app 'TailscaleQuickRepairSetup.exe'
    Check ((Get-FileHash -LiteralPath $installedSetup -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $candidateSetupHash) 'Initial bridge stages the exact candidate Setup host'
    [IO.File]::WriteAllText($installedSetup,'stale same-version field bridge')
    Check ((Get-FileHash -LiteralPath $installedSetup -Algorithm SHA256).Hash.ToLowerInvariant() -cne $candidateSetupHash) 'Fixture simulates an older build of the same 6.4 bridge'

    $childFailureName='field-preview-protected-child-failure.json'
    $childFailureReport=Join-Path $evidence $childFailureName
    $childFailurePsi=New-Object Diagnostics.ProcessStartInfo
    $childFailurePsi.FileName=Join-Path $PSHOME 'powershell.exe';$childFailurePsi.UseShellExecute=$false;$childFailurePsi.CreateNoWindow=$true
    $childFailurePsi.WorkingDirectory=$evidence
    $childFailurePsi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'field-preview.ps1')+'" -OutputDirectory "'+(Resolve-Path $OutputDirectory).Path+'" -ResultPath ".\'+$childFailureName+'" -CiProtectedChildFailureProbe -CiNoRelaunch'
    $child=[Diagnostics.Process]::Start($childFailurePsi)
    Check ($child.WaitForExit(180000) -and $child.ExitCode -eq 1 -and (Test-Path -LiteralPath $childFailureReport -PathType Leaf)) 'Field preview preserves a protected child failure when parent and protected child working directories differ'
    $child.Dispose();$child=$null
    $childFailureRaw=Get-Content -LiteralPath $childFailureReport -Raw
    $childFailure=$childFailureRaw|ConvertFrom-Json
    Check ($childFailure.stage -ceq 'protected_ci_failure_probe' -and $childFailure.requesterIdentityVerified -and -not $childFailure.protectedApplied) 'Parent retains the exact privacy-safe protected child stage'
    Check ($childFailure.bridgeRefreshed -and (Get-FileHash -LiteralPath $installedSetup -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $candidateSetupHash) 'Same-version field retry refreshes the exact candidate bridge before protected Setup'
    Check ($childFailure.error -ceq 'The elevated protected field stage failed. The recorded stage identifies the boundary.') 'Parent replaces elevated child failure text with a curated field error'
    Check ([string]::IsNullOrEmpty($env:USERPROFILE) -or -not $childFailureRaw.Contains($env:USERPROFILE)) 'Protected child failure result does not persist the local user profile path'
    foreach($name in $protectedBaseline.Keys){
        $path=Join-Path $program $name
        $expectedHash=[string]$protectedBaseline[$name]
        Check ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expectedHash) ('Protected child failure preserves baseline hash for '+$name)
    }
    Check (Test-Path (Join-Path $app 'protected-update.json') -PathType Leaf) 'Protected child failure leaves the verified bridge marker available for retry'

    $report=Join-Path $evidence 'field-preview-results.json'
    $fieldPsi=New-Object Diagnostics.ProcessStartInfo
    $fieldPsi.FileName=Join-Path $PSHOME 'powershell.exe';$fieldPsi.UseShellExecute=$false;$fieldPsi.CreateNoWindow=$true
    $fieldPsi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'field-preview.ps1')+'" -OutputDirectory "'+(Resolve-Path $OutputDirectory).Path+'" -ResultPath "'+$report+'" -CiNoElevation -CiNoRelaunch'
    $child=[Diagnostics.Process]::Start($fieldPsi)
    Check ($child.WaitForExit(180000) -and $child.ExitCode -eq 0 -and (Test-Path -LiteralPath $report -PathType Leaf)) 'Field preview retry completes its disposable no-UAC protected core path'
    $child.Dispose();$child=$null
    $field=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
    Check ($field.passed -is [bool] -and $field.passed -and -not $field.baselineVerified -and $field.bridgeVerified -and $field.bridgeApplied -and $field.bridgeRefreshed) 'Field preview retry refreshes the staged bridge without pretending the baseline was reverified'
    Check ($field.requesterIdentityVerified -and $field.protectedPackageVerified -and $field.protectedApplied) 'Field preview retry records same-user protected package completion'
    Check (-not $field.restartAcknowledged) 'CI no-relaunch mode never manufactures physical restart acknowledgement'
    Check (-not(Test-Path (Join-Path $app 'protected-update.json'))) 'Protected completion removes the exact bridge marker'
    $candidate=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($candidate.version -ceq '3.0.0-rc.1' -and [int64]$candidate.versionCode -eq 30001001) 'Field preview leaves the exact candidate version installed'
    $pending=Get-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name PendingRestartVersionCode -ErrorAction Stop
    Check ([int64]$pending.PendingRestartVersionCode -eq 30001001) 'Protected completion persists the exact restart acknowledgement boundary'

    $setupRoot=Join-Path $lab 'candidate-setup';Expand-Archive -LiteralPath $protected[0].FullName -DestinationPath $setupRoot
    $manifest=Get-Content (Join-Path $setupRoot 'package-manifest.json') -Raw|ConvertFrom-Json
    $candidateIntegrity=Join-Path $setupRoot 'app\integrity-manifest.json'
    Check (Test-Path -LiteralPath $candidateIntegrity -PathType Leaf) 'Protected candidate contains the exact installed integrity manifest'
    $candidateIntegrityHash=(Get-FileHash -LiteralPath $candidateIntegrity -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach($entry in @($manifest.files)){
        $relative=([string]$entry.path).Replace('\\','/')
        if($relative -eq 'version.json'){$target=Join-Path $app 'version.user.json'}
        elseif($relative.StartsWith('app/')){$target=Join-Path $app $relative.Substring(4)}
        elseif($relative.StartsWith('program/')){$target=Join-Path $program $relative.Substring(8)}
        else{throw 'Unexpected setup path in acceptance fixture.'}
        Check ((Test-Path $target -PathType Leaf) -and (Get-FileHash $target).Hash.ToLowerInvariant() -ceq ([string]$entry.sha256).ToLowerInvariant()) ('Installed candidate hash matches '+$relative)
    }

    Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name PendingRestartVersionCode -ErrorAction Stop
    $guardianSnapshot=Join-Path $app 'guardian-known-good.json'
    $guardianPrevious=Join-Path $app 'guardian-known-good.previous.json'
    $staleGuardianHash=('0' * 64) -join ''
    $olderGuardianHash=('f' * 64) -join ''
    Check ($staleGuardianHash -cne $candidateIntegrityHash -and $olderGuardianHash -cne $candidateIntegrityHash) 'Fixture Guardian hashes differ from the exact candidate manifest'
    [ordered]@{
        schema=1
        versionCode=30001001
        integrityManifestSha256=$staleGuardianHash
        verifiedReleaseFiles=1
        startupEnabled=$true
        repairEngineReady=$true
        autoRepairAvailable=$true
        verifiedUtc=[DateTime]::UtcNow.ToString('o')
    }|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $guardianSnapshot -Encoding UTF8
    [ordered]@{
        schema=1
        versionCode=30000743
        integrityManifestSha256=$olderGuardianHash
        verifiedReleaseFiles=1
        startupEnabled=$true
        repairEngineReady=$true
        autoRepairAvailable=$true
        verifiedUtc=[DateTime]::UtcNow.AddMinutes(-5).ToString('o')
    }|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $guardianPrevious -Encoding UTF8
    Check (Test-Path -LiteralPath $guardianPrevious -PathType Leaf) 'Fixture includes an existing Guardian predecessor before reconciliation'

    $reconcileReport=Join-Path $evidence 'field-preview-baseline-reconcile.json'
    $reconcilePsi=New-Object Diagnostics.ProcessStartInfo
    $reconcilePsi.FileName=Join-Path $PSHOME 'powershell.exe'
    $reconcilePsi.UseShellExecute=$false
    $reconcilePsi.CreateNoWindow=$true
    $reconcilePsi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'field-preview.ps1')+'" -OutputDirectory "'+(Resolve-Path $OutputDirectory).Path+'" -ResultPath "'+$reconcileReport+'" -ReconcileFieldBaselineOnly'
    $child=[Diagnostics.Process]::Start($reconcilePsi)
    Check ($child.WaitForExit(60000) -and $child.ExitCode -eq 0 -and (Test-Path -LiteralPath $reconcileReport -PathType Leaf)) 'Field post-install reconciliation completes without replaying Setup'
    $child.Dispose();$child=$null

    $reconcile=Get-Content -LiteralPath $reconcileReport -Raw|ConvertFrom-Json
    Check ($reconcile.passed -and $reconcile.installedCandidateVerified -and $reconcile.integrityBaselineRetired -and $reconcile.restartAcknowledged) 'Field post-install reconciliation verifies exact installed bytes and retires only the stale preview baseline'
    Check (-not(Test-Path -LiteralPath $guardianSnapshot) -and (Test-Path -LiteralPath $guardianPrevious -PathType Leaf)) 'Post-install reconciliation leaves Guardian ready to establish the exact candidate baseline'
    $retiredGuardian=Get-Content -LiteralPath $guardianPrevious -Raw|ConvertFrom-Json
    Check ([string]$retiredGuardian.integrityManifestSha256 -ceq $staleGuardianHash) 'Reconciliation atomically replaces an existing predecessor with the stale same-version Guardian record'
    Check (@(Get-ChildItem -LiteralPath $app -Filter 'guardian-known-good.previous.json.*.replace-backup' -File -ErrorAction SilentlyContinue).Count -eq 0) 'Reconciliation removes its temporary predecessor replacement backup'

    # Exercise every explicitly accepted previous-preview identity. The fixture
    # changes only version/Guardian identity around already-verified installed
    # candidate bytes; this tests strict staging policy without claiming to
    # recreate either historical preview package byte-for-byte.
    foreach($previousPreview in @(
        [pscustomobject]@{label='6.4.0';version='3.0.0-phase6.4.0-preview';code=[int64]30000740},
        [pscustomobject]@{label='6.4.1';version='3.0.0-phase6.4.1-preview';code=[int64]30000741},
        [pscustomobject]@{label='6.4.3';version='3.0.0-phase6.4.3-preview';code=[int64]30000743}
    )){
        Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name PendingRestartVersionCode -ErrorAction SilentlyContinue
        [ordered]@{
            product='Tailscale Quick Repair'
            version=[string]$previousPreview.version
            versionCode=[int64]$previousPreview.code
            channel='preview'
            updateSchema=1
            configSchema=2
        }|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $app 'version.user.json') -Encoding UTF8
        [ordered]@{
            schema=1
            versionCode=[int64]$previousPreview.code
            integrityManifestSha256=$candidateIntegrityHash
            verifiedReleaseFiles=1
            startupEnabled=$true
            repairEngineReady=$true
            autoRepairAvailable=$true
            verifiedUtc=[DateTime]::UtcNow.ToString('o')
        }|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $guardianSnapshot -Encoding UTF8

        $previewBaselineHashes=[ordered]@{}
        foreach($name in @('Repair-Backend.ps1','Auto-Repair-Monitor.ps1','TailscaleQuickRepair.Operations.dll')){
            $path=Join-Path $program $name
            $previewBaselineHashes[$name]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        $previewKey=([string]$previousPreview.label).Replace('.','-')
        $previewCancelReport=Join-Path $evidence ('field-preview-'+$previewKey+'-cancel.json')
        $previewCancelPsi=New-Object Diagnostics.ProcessStartInfo
        $previewCancelPsi.FileName=Join-Path $PSHOME 'powershell.exe'
        $previewCancelPsi.UseShellExecute=$false
        $previewCancelPsi.CreateNoWindow=$true
        $previewCancelPsi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'field-preview.ps1')+'" -OutputDirectory "'+(Resolve-Path $OutputDirectory).Path+'" -ResultPath "'+$previewCancelReport+'" -CiCancelBeforeProtected -CiNoRelaunch'
        $child=[Diagnostics.Process]::Start($previewCancelPsi)
        Check ($child.WaitForExit(180000) -and $child.ExitCode -eq 2 -and (Test-Path -LiteralPath $previewCancelReport -PathType Leaf)) ('Accepted '+$previousPreview.label+' preview can stage the uniquely versioned RC1 bridge before simulated UAC cancellation')
        $child.Dispose();$child=$null
        $previewCancel=Get-Content -LiteralPath $previewCancelReport -Raw|ConvertFrom-Json
        Check ($previewCancel.baselineVerified -and $previewCancel.bridgeApplied -and $previewCancel.elevationCancelled -and $previewCancel.protectedUnchangedOnCancel) ($previousPreview.label+' transition records the verified pre-protected boundary')
        $previewStaged=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
        Check ([string]$previewStaged.version -ceq '3.0.0-rc.1' -and [int64]$previewStaged.versionCode -eq 30001001 -and (Test-Path (Join-Path $app 'protected-update.json') -PathType Leaf)) ($previousPreview.label+' transition stages only the new RC1 user bridge')
        $previewMarker=Get-Content (Join-Path $app 'protected-update.json') -Raw|ConvertFrom-Json
        Check ([int]$previewMarker.schema -eq 2 -and [int64]$previewMarker.versionCode -eq 30001001 -and [string]$previewMarker.channel -ceq 'preview') ($previousPreview.label+' staging carries the exact Preview channel into the protected handoff')
        foreach($name in $previewBaselineHashes.Keys){
            $path=Join-Path $program $name
            Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$previewBaselineHashes[$name]) ($previousPreview.label+' cancellation preserves protected hash for '+$name)
        }

        $previewCompleteReport=Join-Path $evidence ('field-preview-'+$previewKey+'-complete.json')
        $previewCompletePsi=New-Object Diagnostics.ProcessStartInfo
        $previewCompletePsi.FileName=Join-Path $PSHOME 'powershell.exe'
        $previewCompletePsi.UseShellExecute=$false
        $previewCompletePsi.CreateNoWindow=$true
        $previewCompletePsi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'field-preview.ps1')+'" -OutputDirectory "'+(Resolve-Path $OutputDirectory).Path+'" -ResultPath "'+$previewCompleteReport+'" -CiNoElevation -CiNoRelaunch'
        $child=[Diagnostics.Process]::Start($previewCompletePsi)
        Check ($child.WaitForExit(180000) -and $child.ExitCode -eq 0 -and (Test-Path -LiteralPath $previewCompleteReport -PathType Leaf)) ('Staged RC1 bridge can complete protected Setup from accepted '+$previousPreview.label+' preview')
        $child.Dispose();$child=$null
        $previewComplete=Get-Content -LiteralPath $previewCompleteReport -Raw|ConvertFrom-Json
        Check ($previewComplete.passed -and $previewComplete.bridgeRefreshed -and $previewComplete.protectedApplied) ($previousPreview.label+' retry completes through the same protected candidate path')
        $previewFinal=Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
        Check ([string]$previewFinal.version -ceq '3.0.0-rc.1' -and [int64]$previewFinal.versionCode -eq 30001001 -and -not(Test-Path (Join-Path $app 'protected-update.json'))) ($previousPreview.label+' transition finishes at the unique RC1 identity')
        $previewPending=Get-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name PendingRestartVersionCode -ErrorAction Stop
        Check ([int64]$previewPending.PendingRestartVersionCode -eq 30001001) ($previousPreview.label+' protected completion writes the unique RC1 restart acknowledgement')
        Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name PendingRestartVersionCode -ErrorAction Stop
    }

    $passed=$true
}catch{
    $chain=New-Object 'Collections.Generic.List[object]';for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}finally{
    if($child){try{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(5000)}}catch{$cleanup=$false};$child.Dispose()}
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name PendingRestartVersionCode -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Tailscale Quick Repair' -ErrorAction SilentlyContinue
    foreach($shortcut in @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Tailscale Quick Repair.lnk'),
        (Join-Path $app 'Launch-Tailscale-Quick-Repair-Startup.vbs')
    )){try{Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue}catch{$cleanup=$false}}
    $scheduler=$null;$folder=$null
    try{
        $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$folder=$scheduler.GetFolder('\')
        foreach($name in @('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')){
            $task=$null
            try{$task=$folder.GetTask($name);$task.Enabled=$false;$folder.DeleteTask($name,0)}catch{if($_.Exception.HResult -ne -2147024894){$cleanup=$false}}
            finally{if($task){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)}catch{}}}
        }
    }catch{$cleanup=$false}
    finally{foreach($item in @($folder,$scheduler)){if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}}}
    foreach($path in @($app,$program,$recovery,$lab)){try{if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}catch{$cleanup=$false}}
    $cases.Add([pscustomobject]@{name='Field preview acceptance removes only fixture-owned Quick Repair state';passed=$cleanup})
    [pscustomobject]@{
        passed=($passed -and $cleanup)
        source=$env:GITHUB_SHA
        candidate='3.0.0-rc.1'
        cases=@($cases.ToArray())
        failure=$failure
        scope='Developer-only local-package field path; production manifest and trust policy remain unchanged'
        limits=@('Hosted CI bypasses the visual UAC prompt but uses the same protected core','Physical UAC approve/cancel/retry remains field acceptance','The field helper is not included in public update or Setup packages')
    }|ConvertTo-Json -Depth 8|Set-Content (Join-Path $evidence 'field-preview-acceptance.json') -Encoding UTF8
}
if(-not $passed -or -not $cleanup){throw 'Field preview acceptance failed; inspect preserved evidence.'}
