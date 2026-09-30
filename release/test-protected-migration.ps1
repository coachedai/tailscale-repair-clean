param([Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$EvidenceDirectory='.\test-evidence')
$ErrorActionPreference='Stop'
# Run ONLY after this exact disposable job has installed and permission-tested
# its own product files. No configurable system root or production-PC mode.
$releaseValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$developmentValidation=($env:GITHUB_REF_NAME -ceq 'work/public')
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   -not ($developmentValidation -or $releaseValidation) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or [string]::IsNullOrEmpty($env:GITHUB_RUN_ID) -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Disposable migration lab refused this environment.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if((git -C $repo rev-parse HEAD).Trim() -cne $env:GITHUB_SHA -or
   (git -C $repo remote get-url origin).Trim() -notmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$' -or
   ((Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json).publish -and -not $releaseValidation)){throw 'Exact unpublished isolated source required.'}
$publishMetadata=Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json
$candidateChannel=[string]$publishMetadata.channel
if($candidateChannel -notin @('stable','preview')){throw 'Candidate update channel is invalid.'}
$evidence=(Resolve-Path $EvidenceDirectory).Path
foreach($name in @('native-windows-results.json','native-permission-results.json')){
    $prior=Get-Content (Join-Path $evidence $name) -Raw|ConvertFrom-Json
    if($prior.passed -isnot [bool] -or -not $prior.passed -or $prior.source -cne $env:GITHUB_SHA){throw 'Same-source installation and permission acceptance required.'}
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Disposable administrator context required.'}
$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
if(-not(Test-Path -LiteralPath $program -PathType Container) -or (Get-Item -LiteralPath $program).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Expected owned installed root unavailable.'}
if(Get-Service Tailscale -ErrorAction SilentlyContinue){throw 'Earlier lab vendor installation must be removed.'}
$scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$folder=$scheduler.GetFolder('\')
foreach($name in @('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')){
    $found=$false;try{[void]$folder.GetTask($name);$found=$true}catch{}
    if($found){throw 'Earlier owned tasks must be removed before isolated path tests.'}
}
# Same volume permits evidence-preserving renames, never recursive deletion.
$work=Join-Path (Split-Path -Parent $program) ('TqrSetupFixture-'+[Guid]::NewGuid().ToString('N'))
$security=New-Object Security.AccessControl.DirectorySecurity
$security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
[void][IO.Directory]::CreateDirectory($work,$security)
$original=Join-Path $work 'original-program'
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false;$restored=$false;$lease=$false;$moved=$false;$fixtureActive=$false;$stage='prepare';$failure=$null
$programNames=@('Auto-Repair-Monitor.ps1','Repair-Backend.ps1','TailscaleQuickRepair.Operations.dll','Launch-Auto-Repair-Monitor.vbs','Launch-Tailscale-Backend.vbs')
function Check([bool]$Value,[string]$Name){
    $script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Native migration assertion failed.'}
    Write-Host "PASS Setup migration: $Name"
}
function Invoke-Setup([string]$Name,[object[]]$Arguments=@()){
    $script:stage='setup_'+$Name
    $native=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$native[$i]=$null}else{$native[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    $method=$setupType.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $method){throw 'Expected packaged Setup boundary unavailable.'}
    return ,($method.Invoke($null,$native))
}
function FileHash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Descriptor([string]$Path){
    return (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Owner,Group,Access')
}
function ProtectedAcl([string]$Path){
    $acl=Get-Acl -LiteralPath $Path
    if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544'){return $false}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 3){return $false}
    $seen=@{}
    foreach($rule in $rules){
        if($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow){return $false}
        $sid=$rule.IdentityReference.Value;if($seen.ContainsKey($sid)){return $false};$seen[$sid]=$true
        if($sid -in @('S-1-5-18','S-1-5-32-544')){if([int64]$rule.FileSystemRights -ne 2032127){return $false}}
        elseif($sid -eq 'S-1-5-32-545'){if([int64]$rule.FileSystemRights -ne 1179817){return $false}}
        else{return $false}
    }
    return $true
}
function AdminOnlyAcl([string]$Path){
    $acl=Get-Acl -LiteralPath $Path
    if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544'){return $false}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $seen=@{}
    foreach($rule in $rules){
        if($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow){return $false}
        $sid=$rule.IdentityReference.Value
        if($sid -notin @('S-1-5-18','S-1-5-32-544')){return $false}
        $seen[$sid]=$true
    }
    return $seen.ContainsKey('S-1-5-18') -and $seen.ContainsKey('S-1-5-32-544')
}
function New-Fixture([bool]$CopyKnown=$true){
    if(Test-Path -LiteralPath $program){throw 'Previous test evidence was not archived.'}
    $script:fixtureActive=$true
    [void][IO.Directory]::CreateDirectory($program)
    if($CopyKnown){foreach($name in $programNames){[IO.File]::Copy((Join-Path $original $name),(Join-Path $program $name),$false)}}
}
function Archive-Fixture([string]$Name){
    if(-not $script:fixtureActive){return}
    $destination=Join-Path $work $Name
    if(Test-Path -LiteralPath $destination){throw 'Fixture evidence destination already exists.'}
    $attributes=[IO.File]::GetAttributes($program)
    if($attributes -band [IO.FileAttributes]::Directory){[IO.Directory]::Move($program,$destination)}
    else{[IO.File]::Move($program,$destination)}
    $script:fixtureActive=$false
}
function Must-Refuse([string]$Name){
    $refused=$false
    try{[void](Invoke-Setup 'PrepareProtectedRoot')}catch{
        $ex=$_.Exception;while($ex.InnerException){$ex=$ex.InnerException}
        if($ex -is [IO.IOException] -or $ex -is [UnauthorizedAccessException]){$refused=$true}else{throw}
    }
    Check $refused ($Name+' is refused by the actual packaged preflight')
}
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zips=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*SetupPackage-*.zip')
    Check ($zips.Count -eq 1) 'One exact protected development package is selected'
    $package=Join-Path $work 'package';Expand-Archive -LiteralPath $zips[0].FullName -DestinationPath $package
    $setupType=[Reflection.Assembly]::LoadFile((Join-Path $package 'app/TailscaleQuickRepairSetup.exe')).GetType('PublicSetupHost')
    $packageManifest=Invoke-Setup 'ReadPackageManifest' @($package)
    $verified=Invoke-Setup 'VerifyPackage' @($package,$packageManifest)
    $manifest=Get-Content (Join-Path $package 'package-manifest.json') -Raw|ConvertFrom-Json
    foreach($name in $programNames){Check (Test-Path -LiteralPath (Join-Path $program $name) -PathType Leaf) ('Original owned installation contains '+$name)}
    $originalHashes=@{};foreach($name in $programNames){$originalHashes[$name]=FileHash (Join-Path $program $name)}
    $lease=[bool](Invoke-Setup 'TryAcquireOperationLock' @('setup'))
    Check $lease 'The actual Setup operation lease protects the entire test transaction'
    [IO.Directory]::Move($program,$original);$moved=$true

    New-Fixture
    $sid=$identity.User.Value
    $legacyRoot=New-Object Security.AccessControl.DirectorySecurity
    $legacyRoot.SetSecurityDescriptorSddlForm(('O:'+ $sid +'G:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;BU)'))
    [IO.Directory]::SetAccessControl($program,$legacyRoot)
    foreach($name in $programNames){
        $legacyFile=New-Object Security.AccessControl.FileSecurity
        $legacyFile.SetSecurityDescriptorSddlForm(('O:'+ $sid +'G:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;BU)'))
        [IO.File]::SetAccessControl((Join-Path $program $name),$legacyFile)
    }
    Check (-not (ProtectedAcl $program)) 'Permissive prior-layout fixture is observably different from the protected target'
    [void](Invoke-Setup 'PrepareProtectedRoot')
    Check (ProtectedAcl $program) 'Prior-layout fixture migrates to the exact protected root ownership and grants'
    foreach($name in $programNames){
        Check ((ProtectedAcl (Join-Path $program $name)) -and (FileHash (Join-Path $program $name)) -ceq $originalHashes[$name]) ('Permission migration preserves bytes and protects '+$name)
    }
    $aclBefore=Descriptor $program;[void](Invoke-Setup 'PrepareProtectedRoot')
    Check ((Descriptor $program) -ceq $aclBefore) 'Repeated permission preparation is idempotent'
    Archive-Fixture 'migrated-layout'

    # Reproduce the long-lived field layout: current protected payload plus
    # exact pre-protected 2.0 lineage leftovers. The upgrade must preserve the
    # legacy bytes in a locked sibling archive while leaving unknown content
    # refusal intact.
    $legacyArchive=Join-Path $env:ProgramData 'TailscaleQuickRepair.Legacy'
    if(Test-Path -LiteralPath $legacyArchive){throw 'Legacy migration archive must not pre-exist in the disposable fixture.'}
    New-Fixture
    $legacyFiles=@(
        'Launch-Tailscale-Auto-Repair.vbs','Launch-Tailscale-Monitor.vbs','NativeHost.cs',
        'Repair-Installation.ps1','Repair-Tailscale.ps1','Tailscale-Repair-UI.ps1','version.json'
    )
    $legacyDirs=@('Rollback-2.0-Final','Rollback-2.0-RC1','Rollback-2.0-RC3.1','Rollback-2.0-RC3.2')
    $legacyHashes=@{}
    foreach($name in $legacyFiles){
        $path=Join-Path $program $name
        [IO.File]::WriteAllText($path,('legacy-field-file:'+ $name))
        $legacyHashes[$name]=FileHash $path
    }
    foreach($name in $legacyDirs){
        $dir=Join-Path $program $name;[void][IO.Directory]::CreateDirectory($dir)
        $leaf=Join-Path $dir 'payload.keep';[IO.File]::WriteAllText($leaf,('legacy-field-dir:'+ $name))
        $legacyHashes[$name]=FileHash $leaf
    }
    $marker=Join-Path $app 'protected-update.json'
    [IO.File]::WriteAllText($marker,((@{schema=2;versionCode=[int64]$manifest.versionCode;channel=$candidateChannel}|ConvertTo-Json -Compress)))
    $legacyApply=Join-Path $work 'long-lived-apply';[void][IO.Directory]::CreateDirectory($legacyApply)
    [void](Invoke-Setup 'ApplyFiles' @($verified,$legacyApply))
    Check (Test-Path -LiteralPath $legacyArchive -PathType Container) 'Long-lived upgrade creates the fixed protected legacy archive'
    Check (AdminOnlyAcl $legacyArchive) 'Legacy archive is administrator and SYSTEM only'
    foreach($name in $legacyFiles){
        $active=Join-Path $program $name;$archived=Join-Path $legacyArchive $name
        Check (-not(Test-Path -LiteralPath $active) -and (Test-Path -LiteralPath $archived -PathType Leaf) -and (FileHash $archived) -ceq $legacyHashes[$name]) ('Legacy migration preserves file '+$name)
    }
    foreach($name in $legacyDirs){
        $active=Join-Path $program $name;$leaf=Join-Path (Join-Path $legacyArchive $name) 'payload.keep'
        Check (-not(Test-Path -LiteralPath $active) -and (Test-Path -LiteralPath $leaf -PathType Leaf) -and (FileHash $leaf) -ceq $legacyHashes[$name]) ('Legacy migration preserves rollback directory '+$name)
    }
    $legacyApply2=Join-Path $work 'long-lived-reapply';[void][IO.Directory]::CreateDirectory($legacyApply2)
    [void](Invoke-Setup 'ApplyFiles' @($verified,$legacyApply2))
    Check (AdminOnlyAcl $legacyArchive) 'Repeated long-lived upgrade leaves the protected legacy archive stable'
    Remove-Item -LiteralPath $marker -Force
    [IO.Directory]::Move($legacyArchive,(Join-Path $work 'long-lived-legacy-archive'))
    Archive-Fixture 'long-lived-layout'

    # Exact legacy names must not migrate outside a protected-update handoff.
    New-Fixture
    $noMarkerLegacy=Join-Path $program 'Repair-Tailscale.ps1'
    [IO.File]::WriteAllText($noMarkerLegacy,'legacy evidence without a handoff marker')
    $noMarkerHash=FileHash $noMarkerLegacy
    $noMarkerApply=Join-Path $work 'legacy-without-marker-apply';[void][IO.Directory]::CreateDirectory($noMarkerApply)
    $refused=$false
    try{[void](Invoke-Setup 'ApplyFiles' @($verified,$noMarkerApply))}catch{
        $ex=$_.Exception;while($ex.InnerException){$ex=$ex.InnerException}
        if($ex -is [IO.IOException] -or $ex -is [UnauthorizedAccessException]){$refused=$true}else{throw}
    }
    Check $refused 'Known legacy content is refused when no protected handoff marker exists'
    Check ((FileHash $noMarkerLegacy) -ceq $noMarkerHash -and -not(Test-Path -LiteralPath $legacyArchive)) 'No-marker refusal preserves legacy evidence in place'
    Archive-Fixture 'legacy-without-marker'

    # Even with a valid protected handoff marker, an unrelated top-level name
    # must block before any known legacy entry is moved.
    New-Fixture
    [IO.File]::WriteAllText($marker,((@{schema=2;versionCode=[int64]$manifest.versionCode;channel=$candidateChannel}|ConvertTo-Json -Compress)))
    $knownLegacy=Join-Path $program 'Repair-Tailscale.ps1';[IO.File]::WriteAllText($knownLegacy,'known legacy evidence')
    $unknownLegacy=Join-Path $program 'do-not-touch.keep';[IO.File]::WriteAllText($unknownLegacy,'unrelated evidence')
    $knownHash=FileHash $knownLegacy;$unknownHash=FileHash $unknownLegacy
    $unknownApply=Join-Path $work 'unknown-with-marker';[void][IO.Directory]::CreateDirectory($unknownApply)
    $refused=$false
    try{[void](Invoke-Setup 'ApplyFiles' @($verified,$unknownApply))}catch{
        $ex=$_.Exception;while($ex.InnerException){$ex=$ex.InnerException}
        if($ex -is [IO.IOException] -or $ex -is [UnauthorizedAccessException]){$refused=$true}else{throw}
    }
    Check $refused 'Valid handoff still refuses unrelated protected-root content'
    Check ((FileHash $knownLegacy) -ceq $knownHash -and (FileHash $unknownLegacy) -ceq $unknownHash -and -not(Test-Path -LiteralPath $legacyArchive)) 'Unknown-content refusal occurs before moving known legacy evidence'
    Remove-Item -LiteralPath $marker -Force
    Archive-Fixture 'unknown-with-valid-marker'

    foreach($kind in @('unknown-file','interrupted-copy','nested-content')){
        New-Fixture
        $leaf=switch($kind){'unknown-file'{'unexpected.keep'};'interrupted-copy'{'Repair-Backend.ps1.setup.new'};default{'nested'}}
        $extra=Join-Path $program $leaf
        if($kind -eq 'nested-content'){[void][IO.Directory]::CreateDirectory($extra);$extra=Join-Path $extra 'evidence.keep'}
        [IO.File]::WriteAllText($extra,'test-owned evidence must survive')
        $rootAcl=Descriptor $program;$extraAcl=Descriptor $extra;$hash=FileHash $extra
        Must-Refuse $kind
        Check ((FileHash $extra) -ceq $hash -and (Descriptor $extra) -ceq $extraAcl -and (Descriptor $program) -ceq $rootAcl) ($kind+' content and security evidence remain unchanged')
        Archive-Fixture $kind
    }

    New-Fixture
    $locked=Join-Path $program 'Repair-Backend.ps1';$hash=FileHash $locked;$aclBefore=Descriptor $program
    $handle=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{Must-Refuse 'Locked protected input'}finally{$handle.Dispose()}
    Check ((FileHash $locked) -ceq $hash -and (Descriptor $program) -ceq $aclBefore) 'Locked-input refusal preserves bytes and root permissions'
    Archive-Fixture 'locked-input'

    foreach($kind in @('hardlink','file-symlink')){
        New-Fixture $false
        $target=Join-Path $work ($kind+'-outside.txt');[IO.File]::WriteAllText($target,'separate test-owned file')
        $link=Join-Path $program 'Repair-Backend.ps1'
        $type=if($kind -eq 'hardlink'){'HardLink'}else{'SymbolicLink'}
        [void](New-Item -ItemType $type -Path $link -Target $target)
        $targetAcl=Descriptor $target;$targetHash=FileHash $target;$rootAcl=Descriptor $program
        Must-Refuse $kind
        Check ((FileHash $target) -ceq $targetHash -and (Descriptor $target) -ceq $targetAcl -and (Descriptor $program) -ceq $rootAcl) ($kind+' cannot redirect permission changes onto the separate target')
        Archive-Fixture $kind
    }
    $outside=Join-Path $work 'junction-target';[void][IO.Directory]::CreateDirectory($outside)
    $sentinel=Join-Path $outside 'untouched.txt';[IO.File]::WriteAllText($sentinel,'separate test directory')
    $outsideAcl=Descriptor $outside;$sentinelHash=FileHash $sentinel
    $fixtureActive=$true;[void](New-Item -ItemType Junction -Path $program -Target $outside)
    Must-Refuse 'Redirected protected root'
    Check ((Descriptor $outside) -ceq $outsideAcl -and (FileHash $sentinel) -ceq $sentinelHash) 'Root junction refusal preserves the separate directory and contents'
    Archive-Fixture 'root-junction'

    $fixtureActive=$true;[IO.File]::WriteAllText($program,'not a directory')
    $hash=FileHash $program;Must-Refuse 'Regular file occupying the protected root'
    Check ((FileHash $program) -ceq $hash) 'Wrong root type is preserved instead of deleted'
    Archive-Fixture 'root-file'

    [IO.Directory]::Move($original,$program);$moved=$false;$restored=$true
    foreach($name in $programNames){Check ((FileHash (Join-Path $program $name)) -ceq $originalHashes[$name]) ('Restored original installation preserves '+$name)}
    # Test exact same-package reapplication separately from the synthetic legacy
    # ACL fixture. This is not full historical-version or interactive Setup acceptance.
    $localHashes=@{}
    foreach($name in @('auto-repair.json','auto-repair-policy.json','auto-repair-state.json','health-history.json','guardian-known-good.json')){
        $path=Join-Path $app $name;if(Test-Path -LiteralPath $path -PathType Leaf){$localHashes[$name]=FileHash $path}
    }
    Check ($localHashes.ContainsKey('auto-repair.json')) 'Actual ordinary-user preference record exists before reapplication'
    foreach($pass in @(1,2)){
        $apply=Join-Path $work ('reapply-'+$pass);[void][IO.Directory]::CreateDirectory($apply)
        [void](Invoke-Setup 'ApplyFiles' @($verified,$apply))
        $allMatch=$true
        foreach($f in $manifest.files){
            $target=[string](Invoke-Setup 'ResolveInstallTarget' @([string]$f.path))
            if((FileHash $target) -ine $f.sha256){$allMatch=$false}
        }
        Check $allMatch ('Actual Setup reapplication '+$pass+' preserves exact manifest file bytes')
        $allProtected=ProtectedAcl $program
        foreach($name in $programNames){$allProtected=$allProtected -and (ProtectedAcl (Join-Path $program $name))}
        Check $allProtected ('Actual Setup reapplication '+$pass+' retains protected ownership and grants')
        $allLocal=$true
        foreach($name in $localHashes.Keys){if((FileHash (Join-Path $app $name)) -cne $localHashes[$name]){$allLocal=$false}}
        Check $allLocal ('Actual Setup reapplication '+$pass+' preserves existing preferences and local evidence')
    }
    $passed=$true
}catch{
    $codes=New-Object 'Collections.Generic.List[object]'
    for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$codes.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($codes.ToArray())}
}finally{
    try{
        if($fixtureActive){Archive-Fixture ('failed-fixture-'+[Guid]::NewGuid().ToString('N'))}
        if($moved){[IO.Directory]::Move($original,$program);$moved=$false;$restored=$true}
    }catch{$restored=$false}
    $leaseReleased=$true
    if($lease){try{[void](Invoke-Setup 'ReleaseOperationLock')}catch{$leaseReleased=$false}}
    $cases.Add([pscustomobject]@{name='Original owned installation restored without deleting failed fixture evidence';passed=$restored})
    $cases.Add([pscustomobject]@{name='Actual Setup lease released by its owner';passed=$leaseReleased})
    [pscustomobject]@{
        passed=($passed -and $restored -and $leaseReleased);source=$env:GITHUB_SHA;
        scope='Actual packaged Setup permission preflight and exact same-package reapplication in an owned disposable Windows installation';
        cases=@($cases.ToArray());failure=$failure;
        limits=@('Prior-layout migration is a deliberately permissive synthetic ACL fixture, not a full older-version upgrade',
          'No hostile concurrent replacement race or cross-account acceptance is claimed',
          'No interactive Setup, UAC, task migration, network change, reboot, rollback or power-loss certification',
          'Only typed assertions are uploaded; all test files and links are retained on the disposable runner')
    }|ConvertTo-Json -Depth 9|Set-Content (Join-Path $evidence 'protected-migration-results.json') -Encoding UTF8
}
if(-not $passed -or -not $restored -or -not $leaseReleased){throw 'Protected migration acceptance failed; evidence is preserved.'}
