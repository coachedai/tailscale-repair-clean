param(
    [Parameter(Mandatory=$true)][string]$ReleasedPackage,
    [Parameter(Mandatory=$true)][string]$CandidateInstaller,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
# Exact distribution regression test. Run only on a fresh hosted Windows runner.
# This test invokes real package/install methods, not the interactive Setup entry.
# It is not a troubleshooting script or an installer for an existing workstation.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$expectedRepository='coachedai/tailscale-repair-clean'
$releasedHash='bdd905f8bd9dc771a3a8fd0ec5093157f30a7d0c2a8ac6d578b5ff6fd74626ce'
$candidateHash='ba6c7ee49c01668c79764ff4b986abcac38f21f1cd0699ee17c75df761d27a17'
$payloadHash='f91f962387813765070af7892cf926dc3504778538a8535521a6cb03794cfac6'
# Source inputs are trusted only after exact revision and privacy verification.
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
   $env:GITHUB_REPOSITORY -cne $expectedRepository -or $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
   $env:GITHUB_REF_NAME -notin @('main','work/public') -or [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or $PSVersionTable.PSEdition -cne 'Desktop' -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Disposable Windows migration environment required.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Disposable runner administrator context required.'
}
$repo=[IO.Path]::GetFullPath($env:GITHUB_WORKSPACE)
$origin=git -C $repo remote get-url origin
if($LASTEXITCODE -ne 0 -or $origin -cnotmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$'){
    throw 'Repository remote mismatch.'
}
$head=git -C $repo rev-parse HEAD
if($LASTEXITCODE -ne 0 -or $head -cne $env:GITHUB_SHA){throw 'Checkout identity mismatch.'}
foreach($leaf in @('publish.json','preview-publish.json')){
    $publication=Get-Content -LiteralPath (Join-Path $repo ('release/'+$leaf)) -Raw|ConvertFrom-Json
    if($publication.publish -isnot [bool] -or $publication.publish){throw 'Publication must remain disabled.'}
}
function Require-UnlinkedPath([string]$Path){
    $part=[IO.Path]::GetFullPath($Path)
    while($part){
        if(Test-Path -LiteralPath $part){
            if((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){
                throw 'Redirected fixture path refused.'
            }
        }
        $parent=[IO.Path]::GetDirectoryName($part)
        if($parent -eq $part){break};$part=$parent
    }
}
$runnerRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
foreach($p in @($ReleasedPackage,$CandidateInstaller,$EvidenceDirectory)){
    $full=[IO.Path]::GetFullPath($p)
    if(-not $full.StartsWith($runnerRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Inputs and evidence must be outside the checkout, in runner temporary storage.'}
    Require-UnlinkedPath $full
}
if(Test-Path -LiteralPath (Join-Path $EvidenceDirectory 'released-setup-migration-results.json')){throw 'Existing migration evidence must not be overwritten.'}
function Digest([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
if((Digest $ReleasedPackage) -cne $releasedHash -or (Digest $CandidateInstaller) -cne $candidateHash){
    throw 'The exact released and previously tested candidate bytes are required.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms
$app=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TailscaleQuickRepair'
$program=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TailscaleQuickRepair'
$recovery=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TailscaleQuickRepair.SetupRecovery'
$shortcut=Join-Path ([Environment]::GetFolderPath('Programs')) 'Tailscale Quick Repair.lnk'
$startupKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupValue='Tailscale Quick Repair'
$productRegistry='HKCU:\Software\TailscaleQuickRepair'
if(Test-Path -LiteralPath $productRegistry){throw 'Existing product registry state refused.'}
$taskNames=@('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')
foreach($p in @($app,$program,$recovery,$shortcut)){
    Require-UnlinkedPath $p
    if(Test-Path -LiteralPath $p){throw 'Existing product state must not be used by this test.'}
}
if(Get-Service Tailscale -ErrorAction SilentlyContinue){throw 'An empty runner without Tailscale is required.'}
if(@(Get-Process -Name 'tailscale*','TailscaleQuickRepair*' -ErrorAction SilentlyContinue).Count){throw 'Existing Tailscale processes refused.'}
if(Get-ItemProperty -LiteralPath $startupKey -Name $startupValue -ErrorAction SilentlyContinue){throw 'Existing startup preference refused.'}
foreach($name in $taskNames){
    if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'Existing scheduled product task refused.'}
}
$work=Join-Path $runnerRoot ('TqrReleasedMigration-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false;$owned=$false;$leaseType=$null;$failure='';$failureStage='';$stage='inputs';$cleanupPassed=$false
$flags=[Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
function Check([bool]$Value,[string]$Name){
    $script:stage=$Name
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw [InvalidOperationException]::new('Migration assertion failed.')}
    Write-Host ('PASS released migration: '+$Name)
}
function Native([Type]$Type,[string]$Name,[object[]]$Arguments=@(),[object]$Instance=$null){
    $script:stage='native_'+$Name
    $method=$Type.GetMethod($Name,$flags)
    if(-not $method){throw 'Expected native method missing.'}
    $values=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$values[$i]=$null}else{$values[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    # Reflection does not unwrap PowerShell-adapted values on its own.
    $target=$null
    if($null -ne $Instance){$target=$Instance.PSObject.BaseObject}
    return ,($method.Invoke($target,$values))
}
function Release-Lease {
    if($script:leaseType){[void](Native $script:leaseType 'ReleaseOperationLock');$script:leaseType=$null}
}
function Acquire-Lease([Type]$Type){
    Check ([bool](Native $Type 'TryAcquireOperationLock' @('setup'))) 'Actual native setup lease is acquired'
    $script:leaseType=$Type
}
function Pause-OwnedTasks {
    foreach($name in $taskNames){
        $task=Get-ScheduledTask -TaskName $name -ErrorAction Stop
        Check ($task.State -ne 'Running') 'Fixture task has not run during installation'
        [void](Disable-ScheduledTask -InputObject $task)
    }
}
function Expand-BoundedPackage([string]$Zip,[string]$Destination){
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try{
        if($archive.Entries.Count -ne 12){throw 'Unexpected package entry count.'}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $total=0L
        foreach($entry in $archive.Entries){
            $name=$entry.FullName.Replace('\','/')
            if($name -match '^/|:|(^|/)(\.|\.\.)($|/)|//|/$' -or -not $seen.Add($name) -or
               $entry.Length -le 0 -or $entry.Length -gt 2000000){throw 'Unsafe archive entry refused.'}
            $total+=$entry.Length;if($total -gt 8000000){throw 'Expanded archive limit exceeded.'}
        }
    }finally{$archive.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip,$Destination)
}
function Assert-InstalledFiles($Plan,[string]$Name){
    $allMatch=$true
    foreach($file in $Plan){
        Require-UnlinkedPath $file.Target
        if(-not (Test-Path -LiteralPath $file.Target -PathType Leaf) -or (Digest $file.Target) -cne $file.Sha256){$allMatch=$false}
    }
    Check $allMatch $Name
}
try{
    $oldRoot=Join-Path $work 'rc10'
    Expand-BoundedPackage $ReleasedPackage $oldRoot
    $oldAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $oldRoot 'app/TailscaleQuickRepairSetup.exe')))
    $oldType=$oldAssembly.GetType('PublicSetupHost',$true)
    $newAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($CandidateInstaller))
    $newType=$newAssembly.GetType('PublicSetupHost',$true)
    $embeddedType=$newAssembly.GetType('Tqr.EmbeddedSetupPackage',$true)
    $embedded=Native $embeddedType 'Read'
    Check ($null -ne $embedded) 'Candidate uses its real embedded package'
    $payload=Join-Path $work 'rc11.zip'
    Check ($embeddedType.IsInstanceOfType($embedded.PSObject.BaseObject)) 'Native embedded metadata has the expected runtime type'
    [void](Native $embeddedType 'CopyTo' @([string]$payload) $embedded)
    Check ((Digest $payload) -ceq $payloadHash) 'Embedded candidate matches the previously tested Setup ZIP'
    $newRoot=Join-Path $work 'rc12'
    Expand-BoundedPackage $payload $newRoot
    $oldManifest=Native $oldType 'ReadPackageManifest' @($oldRoot)
    $newManifest=Native $newType 'ReadPackageManifest' @($newRoot)
    $oldFiles=Native $oldType 'VerifyPackage' @($oldRoot,$oldManifest)
    $newFiles=Native $newType 'VerifyPackage' @($newRoot,$newManifest)
    Check ($oldFiles.Count -eq 11 -and $newFiles.Count -eq 11) 'Both native installers verify their complete file lists'
    $oldVersion=Get-Content -LiteralPath (Join-Path $oldRoot 'version.json') -Raw|ConvertFrom-Json
    $newVersion=Get-Content -LiteralPath (Join-Path $newRoot 'version.json') -Raw|ConvertFrom-Json
    Check ($oldVersion.version -ceq '3.0.0-rc.11' -and $oldVersion.versionCode -eq 30001011 -and
           $newVersion.version -ceq '3.0.0-rc.12' -and $newVersion.versionCode -eq 30001012) 'Genuine distribution versions are unchanged'
    Check ($oldVersion.configSchema -eq 2 -and $newVersion.configSchema -eq 2) 'Configuration schema remains compatible'
    foreach($type in @($oldType,$newType)){
        Check ((Native $type 'GetAppDir') -ceq $app -and (Native $type 'GetProgramDir') -ceq $program) 'Native install destinations match the guarded empty roots'
    }
    $owned=$true
    Acquire-Lease $oldType
    [void](Native $oldType 'ApplyFiles' @($oldFiles,$work))
    [void](Native $oldType 'CompleteInstalledIntegration' @('fixture-device.invalid',$true,$false,[int64]30001011))
    Pause-OwnedTasks
    Assert-InstalledFiles $oldFiles 'Real RC11 installer establishes the exact released file baseline'
    Release-Lease
    $peer=[string](Native $oldType 'ReadConfiguredPeer')
    $startup=[bool](Native $oldType 'IsStartupEnabled')
    Check ($peer -ceq 'fixture-device.invalid' -and $startup) 'RC10 native integration reads its installed configuration'
    $config=Join-Path $app 'config.json'
    $settings=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json
    $settings|Add-Member -NotePropertyName fixtureRetainedSetting -NotePropertyValue 'retained'
    [IO.File]::WriteAllText($config,($settings|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    # Typed fixture files test byte preservation; no existing machine records are used.
    $retained=@{'config.json'=(Digest $config)}
    foreach($leaf in @('auto-repair.json','auto-repair-policy.json','health-history.json','notification-policy.json')){
        $path=Join-Path $app $leaf
        if(Test-Path -LiteralPath $path){throw 'Unexpected initialized fixture state requires review.'}
        [IO.File]::WriteAllText($path,'{"schema":1,"fixture":"retained","enabled":false}',(New-Object Text.UTF8Encoding($false)))
        $retained[$leaf]=Digest $path
    }
    $damaged=Join-Path $newRoot 'app/Tailscale-Repair-UI.ps1'
    $originalBytes=[IO.File]::ReadAllBytes($damaged)
    [IO.File]::WriteAllBytes($damaged,[byte[]]($originalBytes+0))
    $refused=$false
    try{[void](Native $newType 'VerifyPackage' @($newRoot,$newManifest))}catch{
        $e=$_.Exception;while($e.InnerException){$e=$e.InnerException}
        $refused=$e -is [IO.InvalidDataException]
    }finally{[IO.File]::WriteAllBytes($damaged,$originalBytes)}
    Check $refused 'A modified RC11 payload is rejected before changing RC10'
    Assert-InstalledFiles $oldFiles 'Rejected payload leaves the RC10 baseline intact'
    Acquire-Lease $newType
    [void](Native $embeddedType 'RefuseDowngrade' @([string]$app) $embedded)
    [void](Native $embeddedType 'RequireTarget' @([int64]30001012) $embedded)
    $script:faultInjected=$false;$interrupted=$false
    $fault=[Action[int]]{param($step) if($step -eq 1){$script:faultInjected=$true;throw [InvalidOperationException]::new('Synthetic transaction interruption.')}}
    try{[void](Native $newType 'ApplyFilesCore' @($newFiles,$work,$fault))}catch{$interrupted=$true}
    Check ($script:faultInjected -and $interrupted) 'Controlled failure occurs after a real candidate file replacement'
    Assert-InstalledFiles $oldFiles 'Native transaction recovery restores the exact RC11 files'
    [void](Native $newType 'ApplyFiles' @($newFiles,$work))
    [void](Native $newType 'CompleteInstalledIntegration' @($peer,$startup,$true,[int64]30001012))
    Pause-OwnedTasks
    Assert-InstalledFiles $newFiles 'Native RC12 migration installs every verified candidate file'
    foreach($leaf in $retained.Keys){Check ((Digest (Join-Path $app $leaf)) -ceq $retained[$leaf]) ('Existing fixture bytes preserved: '+$leaf)}
    Check ((Native $newType 'ReadConfiguredPeer') -ceq $peer -and [bool](Native $newType 'IsStartupEnabled') -eq $startup) 'Target and startup preference survive native migration'
    $installed=Get-Content -LiteralPath (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json
    Check ($installed.version -ceq '3.0.0-rc.12' -and $installed.versionCode -eq 30001012) 'Installed version advances through the real package mapping'
    foreach($leaf in @('TailscaleQuickRepairSetup.exe','TailscaleQuickRepairUpdater.exe')){
        $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $app $leaf)))
        $typename=if($leaf -eq 'TailscaleQuickRepairSetup.exe'){'PublicSetupHost'}else{'Program'}
        $type=$assembly.GetType($typename,$true)
        foreach($channel in @('stable','preview')){
            $suffix=if($channel -eq 'stable'){'latest.json?ref=main'}else{'preview.json?ref=preview'}
            $expected='https://api.github.com/repos/'+$expectedRepository+'/contents/updates/'+$suffix
            Check ((Native $type 'GetManifestApiUrl' @($channel)) -ceq $expected) 'Installed native component resolves only the intended update destination'
        }
    }
    $pending=Get-ItemProperty -LiteralPath $productRegistry -Name PendingRestartVersionCode -ErrorAction Stop
    Check ([int64]$pending.PendingRestartVersionCode -eq 30001012) 'Migration retains the required new-version restart acknowledgement'
    Release-Lease
    $passed=$true
}catch{
    $e=$_.Exception;while($e.InnerException){$e=$e.InnerException}
    $failure=$e.GetType().FullName;$failureStage=$stage
}finally{
    try{Release-Lease}catch{$passed=$false;$failure='LeaseCleanupFailure'}
    if($owned){
        foreach($name in $taskNames){
            $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if($task){[void](Disable-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue)}
        }
    }
    if($passed -and $owned){
        try{
            foreach($p in @($app,$program,$recovery)){
                Require-UnlinkedPath $p
                if(Test-Path -LiteralPath $p){
                    $linked=@(Get-ChildItem -LiteralPath $p -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
                    if($linked.Count){throw 'Unexpected link in owned fixture.'}
                }
            }
            foreach($name in $taskNames){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop}
            Remove-ItemProperty -LiteralPath $startupKey -Name $startupValue -ErrorAction Stop
            if(Test-Path -LiteralPath $productRegistry){Remove-Item -LiteralPath $productRegistry -Recurse -Force -ErrorAction Stop}
            foreach($p in @($shortcut,$app,$program,$recovery)){
                if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop}
            }
            $cleanupPassed=$true
        }catch{$passed=$false;$failure='OwnedFixtureCleanupFailure'}
    }
    [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
    $report=Join-Path $EvidenceDirectory 'released-setup-migration-results.json'
    if(Test-Path -LiteralPath $report){throw 'Refusing to overwrite migration evidence.'}
    [pscustomobject]@{
        schema=1;passed=$passed;testSource=$env:GITHUB_SHA;candidateSource='36bd301fdff27737c2a0e3ad2375ce277ffc955c'
        releasedSha256=$releasedHash;candidateSha256=$candidateHash;payloadSha256=$payloadHash
        cases=@($cases.ToArray());cleanupPassed=$cleanupPassed;failureType=$failure;stage=$stage;failureStage=$failureStage
        interactiveSetupEntryTested=$false;desktopElevationTested=$false;publicFeedVerified=$false
        scope='Exact RC11 files installed by the original native installer, then real RC12 transaction and integration methods on an empty hosted Windows runner. Synthetic local settings. Interactive entry, desktop elevation and public update delivery remain separate.'
    }|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $report -Encoding UTF8
}
if(-not $passed){throw 'Released migration test failed; typed evidence was preserved.'}
Write-Host 'Released RC10-to-RC11 native fixture migration passed. Not interactive desktop or public feed acceptance.'