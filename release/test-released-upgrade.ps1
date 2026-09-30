param([Parameter(Mandatory=$true)][string]$OutputDirectory,[Parameter(Mandatory=$true)][string]$UpstreamEvidence,[string]$EvidenceDirectory='.\upgrade-evidence')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$releaseValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$developmentValidation=($env:GITHUB_REF_NAME -ceq 'work/3.0')
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
   $env:RUNNER_ARCH -cne 'X64' -or $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   -not ($developmentValidation -or $releaseValidation) -or $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or
   -not $env:GITHUB_RUN_ID -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Released-upgrade lab requires a disposable native Windows runner.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if((git -C $repo rev-parse HEAD).Trim() -cne $env:GITHUB_SHA -or
   (git -C $repo remote get-url origin).Trim() -notmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$' -or
   ((Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json).publish -and -not $releaseValidation)){throw 'Exact isolated unpublished development source required.'}
if((Get-Content (Join-Path $UpstreamEvidence 'source-commit.txt') -Raw).Trim() -cne $env:GITHUB_SHA){throw 'Upstream source does not match.'}
foreach($name in @('native-windows-results.json','native-permission-results.json','protected-migration-results.json')){
    $prior=Get-Content (Join-Path $UpstreamEvidence $name) -Raw|ConvertFrom-Json
    if($prior.passed -isnot [bool] -or -not $prior.passed -or $prior.source -cne $env:GITHUB_SHA){throw 'Same-source native acceptance required before released upgrade.'}
}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null;$evidence=(Resolve-Path $EvidenceDirectory).Path
$lab=Join-Path $env:RUNNER_TEMP ('TqrReleasedUpgrade-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($lab)
$env:TQR_RELEASED_UPGRADE_ROOT=$lab
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair';$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$taskNames=@('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')
$cases=New-Object 'Collections.Generic.List[object]';$passed=$false;$cleanup=$true;$child=$null;$owned=$false;$failure=$null;$stage='preflight'
$legacyHash='bad4deb522afd9442e918cacde1f58cc1509635de3be172626846060516df470'
function Check([bool]$Value,[string]$Name){$script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value});if(-not $Value){throw 'Released upgrade assertion failed.'};Write-Host ('PASS released upgrade: '+$Name)}
function Expand-Verified([string]$Zip,[string]$Destination){
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip);$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try{
        $total=0L
        foreach($entry in $archive.Entries){
            $name=$entry.FullName.Replace('\','/');if($name.EndsWith('/')){continue}
            $total+=$entry.Length
            if($name -match '(^/|:|(^|/)\.{1,2}(/|$))' -or -not $seen.Add($name) -or $total -gt 8MB -or $seen.Count -gt 64){throw 'Unsafe or oversized package.'}
        }
    }finally{$archive.Dispose()}
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination
    $manifest=Get-Content (Join-Path $Destination 'package-manifest.json') -Raw|ConvertFrom-Json
    if($manifest.schema -ne 1 -or $seen.Count -ne @($manifest.files).Count+1){throw 'Incorrect package envelope.'}
    $declared=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($f in $manifest.files){
        $name=([string]$f.path).Replace('\','/');$p=Join-Path $Destination $name
        if(-not $seen.Contains($name) -or -not $declared.Add($name) -or $name -eq 'package-manifest.json' -or
           (Get-Item -LiteralPath $p).Length -ne $f.size -or (Get-FileHash -LiteralPath $p).Hash -ine $f.sha256){throw 'Package file failed verification.'}
    }
    return $manifest
}
function Stop-OwnedTasks {
    foreach($name in $taskNames){
        $task=$null;try{$task=$folder.GetTask($name)}catch{}
        if(-not $task){continue}
        $task.Enabled=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
        while([int]$task.State -in @(2,4)){if($watch.Elapsed.TotalSeconds -gt 120){throw 'Owned task remains active; no forced stop.'};Start-Sleep -Milliseconds 100}
        $folder.DeleteTask($name,0)
    }
}
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
    Check ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Empty runner provides legitimate native Setup permissions'
    Check (-not(Test-Path $app) -and -not(Test-Path $program) -and -not(Get-Service Tailscale -ErrorAction SilentlyContinue)) 'No existing installation or vendor service is reused'
    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$folder=$scheduler.GetFolder('\')
    foreach($name in $taskNames){$exists=$false;try{[void]$folder.GetTask($name);$exists=$true}catch{};Check (-not $exists) 'No pre-existing product task is overwritten'}
    $run=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    Check ($null -eq $run.GetValue($taskNames[0])) 'No pre-existing product startup setting is replaced'
    $owned=$true
    $stage='download_pinned_published_package'
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url='https://github.com/coachedai/tailscale-repair-clean/releases/download/v3.0.0-phase5.2.1/TailscaleQuickRepair-SetupPackage-3.0.0-phase5.2.1.zip'
    $zip=Join-Path $lab 'published-5.2.1.zip';$request=[Net.HttpWebRequest]::Create($url)
    $request.UserAgent='TqrDisposableUpgradeAcceptance';$request.Timeout=20000;$request.ReadWriteTimeout=20000
    $response=$null;$input=$null;$output=$null
    try{
        $response=$request.GetResponse()
        if($response.ResponseUri.Scheme -ne 'https' -or $response.ResponseUri.Host -notin @('github.com','release-assets.githubusercontent.com')){throw 'Unexpected release download host.'}
        $input=$response.GetResponseStream();$output=[IO.File]::Open($zip,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 32768;$total=0;$watch=[Diagnostics.Stopwatch]::StartNew()
        while(($n=$input.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$n;if($total -gt 140164 -or $watch.Elapsed.TotalSeconds -gt 60){throw 'Release download exceeded its exact bound.'};$output.Write($buffer,0,$n)}
    }finally{if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()}}
    Check ((Get-Item $zip).Length -eq 140164 -and (Get-FileHash $zip).Hash -ieq $legacyHash) 'Genuine published 5.2.1 ZIP matches its pinned exact size and SHA-256'
    $legacy=Join-Path $lab 'legacy';$old=Expand-Verified $zip $legacy
    Check ($old.version -ceq '3.0.0-phase5.2.1' -and $old.versionCode -eq 30000621) 'Verified released package has the required historical version'
    $newZip=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*SetupPackage-*.zip')
    Check ($newZip.Count -eq 1) 'Exactly one upstream-tested development Setup package is reused without rebuilding'
    $current=Join-Path $lab 'current';$new=Expand-Verified $newZip[0].FullName $current
    $version=Get-Content (Join-Path $repo 'version.json') -Raw|ConvertFrom-Json
    Check ($new.version -ceq $version.version -and $new.versionCode -eq $version.versionCode) 'Candidate package metadata agrees with the exact current source'
    foreach($scenario in @('missing','off','on')){
        foreach($phase in @('Legacy','Upgrade')){
            $stage=$scenario+'_'+$phase;$reportPath=Join-Path $lab ($stage+'.json');$selected=if($phase -eq 'Legacy'){$legacy}else{$current}
            $psi=New-Object Diagnostics.ProcessStartInfo
            $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
            $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "'+(Join-Path $PSScriptRoot 'released-upgrade-child.ps1')+'" -Phase '+$phase+' -Case '+$scenario+' -Package "'+$selected+'" -Report "'+$reportPath+'"'
            $child=[Diagnostics.Process]::Start($psi)
            if(-not $child.WaitForExit(180000)){throw 'Owned upgrade child exceeded its bound; no rerun.'}
            $childResult=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
            foreach($item in $childResult.cases){$cases.Add($item)}
            Copy-Item $reportPath (Join-Path $evidence ([IO.Path]::GetFileName($reportPath)))
            Check ($child.ExitCode -eq 0 -and $childResult.passed -is [bool] -and $childResult.passed -and $childResult.source -ceq $env:GITHUB_SHA -and @($childResult.cases).Count -gt 5) ($stage+' native child passes its complete recorded assertions')
            $child.Dispose();$child=$null
        }
        Stop-OwnedTasks
        $appArchive=Join-Path (Split-Path -Parent $app) ('TqrUpgradeEvidence-'+[Guid]::NewGuid().ToString('N'))
        $programArchive=Join-Path (Split-Path -Parent $program) ('TqrUpgradeEvidence-'+[Guid]::NewGuid().ToString('N'))
        [IO.Directory]::Move($app,$appArchive);[IO.Directory]::Move($program,$programArchive)
        $run.DeleteValue($taskNames[0],$false)
        Check (-not(Test-Path $app) -and -not(Test-Path $program)) ($scenario+' completed installation is archived intact before the next independent scenario')
    }
    $passed=$true
}catch{
    $chain=New-Object 'Collections.Generic.List[object]'
    for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}finally{
    if($child){try{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(5000)}}catch{$cleanup=$false};$child.Dispose()}
    if($owned){try{Stop-OwnedTasks;$run.DeleteValue($taskNames[0],$false)}catch{$cleanup=$false}}
    if($run){$run.Dispose()}
    $cases.Add([pscustomobject]@{name='Only owned tasks and startup registration are removed; installation and failed evidence retained';passed=$cleanup})
    [pscustomobject]@{passed=($passed -and $cleanup);source=$env:GITHUB_SHA;fromVersion='3.0.0-phase5.2.1';legacySha256=$legacyHash;
        scope='Published old Setup installs actual released payload and tasks; separate current Setup core upgrades them; native migrated monitor dispatch';
        cases=@($cases.ToArray());failure=$failure;legacyInstalledHostCertified=$false;
        limits=@('Task quiescence is fixture setup, not a test of upgrading active work','Historical reservation is seeded through the actual old state writer, not evidence of a real past repair',
          'The new Setup executable runs outside installed roots; old installed --upgrade host still needs a verified bridge or handoff before protected release',
          'No full interactive entry, UAC, alternate-admin, old-host delegation, authenticated network, rollback or power-loss acceptance')
    }|ConvertTo-Json -Depth 10|Set-Content (Join-Path $evidence 'released-upgrade-results.json') -Encoding UTF8
    $env:GITHUB_SHA|Set-Content (Join-Path $evidence 'source-commit.txt')
}
if(-not $passed -or -not $cleanup){throw 'Released-upgrade acceptance failed; inspect preserved typed evidence.'}
