param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EvidenceDirectory='.\upgrade-evidence'
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$releaseValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$developmentValidation=($env:GITHUB_REF_NAME -ceq 'work/public')
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   -not ($developmentValidation -or $releaseValidation) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or -not $env:GITHUB_RUN_ID -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Protected handoff acceptance refused this environment.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if((git -C $repo rev-parse HEAD).Trim() -cne $env:GITHUB_SHA -or
   ((Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json).publish -and -not $releaseValidation)){throw 'Exact isolated source required.'}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$lab=Join-Path $env:RUNNER_TEMP ('TqrProtectedHandoff-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($lab)
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair';$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$cases=New-Object 'Collections.Generic.List[object]';$passed=$false;$failure=$null;$stage='preflight';$child=$null;$cleanup=$true
$identityScheduler=$null;$identityFolder=$null;$identityFolderName='';$identityRoot=''
$identityTask=$null;$identityAction=$null;$registeredIdentityTask=$null
$cleanupFailures=New-Object 'Collections.Generic.List[string]'
$legacyHash='bad4deb522afd9442e918cacde1f58cc1509635de3be172626846060516df470'
function Check([bool]$Value,[string]$Name){$script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value});if(-not $Value){throw 'Protected handoff assertion failed.'};Write-Host ('PASS protected handoff: '+$Name)}
function Expand-Zip([string]$Zip,[string]$Destination){Expand-Archive -LiteralPath $Zip -DestinationPath $Destination;return (Get-Content (Join-Path $Destination 'package-manifest.json') -Raw|ConvertFrom-Json)}
function Run-Child([string]$Phase,[string]$Legacy,[string]$Current){
    $report=Join-Path $lab ($Phase+'.json')
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "'+(Join-Path $PSScriptRoot 'protected-handoff-child.ps1')+'" -Phase '+$Phase+' -LegacyPackage "'+$Legacy+'" -CurrentPackage "'+$Current+'" -Report "'+$report+'"'
    $script:child=[Diagnostics.Process]::Start($psi)
    if(-not $script:child.WaitForExit(120000)){throw 'Owned handoff child exceeded its time bound; no rerun.'}
    $result=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
    foreach($item in $result.cases){$cases.Add($item)}
    Copy-Item $report (Join-Path $evidence ([IO.Path]::GetFileName($report)))
    Check ($script:child.ExitCode -eq 0 -and $result.passed -is [bool] -and $result.passed -and $result.source -cne '') ($Phase+' child passes its full recorded checks')
    $script:child.Dispose();$script:child=$null
}
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem,PresentationFramework
    $publish=Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json
    Check ($publish.PSObject.Properties.Name -contains 'protectedHandoff' -and $publish.protectedHandoff -is [bool] -and [bool]$publish.protectedHandoff) 'Candidate explicitly uses the protected update handoff'
    Check ([string]$publish.channel -ceq 'preview') 'Development protected handoff is explicitly bound to the Preview channel'
    Check ($publish.requiresSetup -is [bool] -and -not [bool]$publish.requiresSetup) 'Legacy-compatible bridge is not blocked by the 5.2.1 direct-Setup gate'
    Check (-not(Test-Path $app) -and -not(Test-Path $program) -and -not(Get-Service Tailscale -ErrorAction SilentlyContinue)) 'Handoff starts on an empty disposable installation'
    $url='https://github.com/coachedai/tailscale-repair-clean/releases/download/v3.0.0-phase5.2.1/TailscaleQuickRepair-SetupPackage-3.0.0-phase5.2.1.zip'
    $zip=Join-Path $lab 'published.zip';$wc=New-Object Net.WebClient;$wc.Headers.Add('User-Agent','TqrProtectedHandoffAcceptance');$wc.DownloadFile($url,$zip);$wc.Dispose()
    Check ((Get-Item $zip).Length -eq 140164 -and (Get-FileHash $zip).Hash -ieq $legacyHash) 'Published 5.2.1 package matches the pinned public release'
    $legacy=Join-Path $lab 'legacy';$old=Expand-Zip $zip $legacy
    Check ($old.version -ceq '3.0.0-phase5.2.1') 'Pinned package identifies the released starting version'
    $ordinary=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-*.zip' -File|Where-Object Name -notlike '*SetupPackage*')
    $setup=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*SetupPackage-*.zip' -File)
    Check ($ordinary.Count -eq 1 -and $setup.Count -eq 1) 'One tested ordinary package and one protected package are reused'
    $bridge=Join-Path $lab 'bridge';$bridgeManifest=Expand-Zip $ordinary[0].FullName $bridge
    $protected=Join-Path $lab 'protected';$protectedManifest=Expand-Zip $setup[0].FullName $protected
    Check ($bridgeManifest.versionCode -eq $protectedManifest.versionCode) 'Bridge and protected package target the same release code'
    Check (-not(Test-Path (Join-Path $protected 'app\protected-update.json'))) 'Full Setup package contains no bridge-only handoff marker'
    Check (@($bridgeManifest.files|Where-Object {[string]$_.path -like 'program/*'}).Count -eq 0) 'Bridge package contains no protected program file'
    $markerEntry=@($bridgeManifest.files|Where-Object {[string]$_.path -ceq 'app/protected-update.json'})
    Check ($markerEntry.Count -eq 1) 'Bridge package carries one protected-update marker'
    $marker=Get-Content (Join-Path $bridge 'app\protected-update.json') -Raw|ConvertFrom-Json
    Check ($marker.schema -eq 2 -and $marker.versionCode -eq $bridgeManifest.versionCode -and [string]$marker.channel -ceq 'preview') 'Bridge marker targets exactly the package version and Preview channel'
    $integrity=Get-Content (Join-Path $bridge 'app\integrity-manifest.json') -Raw|ConvertFrom-Json
    Check (@($integrity.files|Where-Object {[string]$_.path -ceq 'protected-update.json'}).Count -eq 0) 'Transient handoff marker is not required by the permanent app integrity manifest'
    Check ($markerEntry[0].sha256 -ceq (Get-FileHash (Join-Path $bridge 'app\protected-update.json')).Hash.ToLowerInvariant()) 'Outer package manifest protects the exact transient marker bytes'
    Run-Child 'InstallLegacy' $legacy $bridge
    $protectedBefore=@{};foreach($name in @('Repair-Backend.ps1','Auto-Repair-Monitor.ps1')){$protectedBefore[$name]=(Get-FileHash (Join-Path $program $name)).Hash}
    Run-Child 'ApplyBridge' $legacy $bridge
    foreach($name in $protectedBefore.Keys){Check ((Get-FileHash (Join-Path $program $name)).Hash -ceq $protectedBefore[$name]) ('Old updater leaves protected '+$name+' untouched')}
    Check ((Get-FileHash (Join-Path $app 'TailscaleQuickRepairSetup.exe')).Hash -ceq (Get-FileHash (Join-Path $bridge 'app\TailscaleQuickRepairSetup.exe')).Hash) 'Old updater installs the exact refreshed Setup host'
    $ui=[IO.File]::ReadAllText((Join-Path $app 'Tailscale-Repair-UI.ps1'))
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Bridged UI parses on native Windows PowerShell'
    $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-PendingProtectedUpdate'},$true))
    $ackFn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Acknowledge-ProtectedRestart'},$true))
    $resultFn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Show-UpdateResult'},$true))
    Check ($fn.Count -eq 1 -and $ackFn.Count -eq 1 -and $resultFn.Count -eq 1) 'Bridged UI contains one handoff, restart acknowledgement and update-result function'
    $source=$fn[0].Extent.Text
    Check ($source.Contains('$psi.FileName = $SetupHostPath') -and
        $source.Contains('$psi.Arguments = ') -and
        $source.Contains('--upgrade --channel "') -and
        $source.Contains('--target-code ') -and
        $source.Contains('--requester-sid "') -and
        $source.Contains('$markerChannel') -and
        $source.Contains('$requesterSid') -and
        $source.Contains("$psi.Verb = 'runas'") -and
        $source.Contains('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value')) 'Handoff launches only the installed Setup host for the exact channel, version and initiating Windows account'
    Check ($source.Contains('$ProtectedUpdateMarkerPath') -and $source.Contains('[int]$marker.schema -eq 2') -and -not $source.Contains('Repair-Backend.ps1')) 'Handoff uses the channel-bound version marker and never runs a protected script directly'
    Check ($resultFn[0].Extent.Text.Contains('Update downloaded - finishing setup') -and
        $resultFn[0].Extent.Text.Contains('Windows approval is needed to finish the protected part of this update.')) 'Bridge success remains provisional until protected Setup completes'

    # Use an actual second local administrator account to verify the identity
    # boundary. This is a credential-context test, not a visual UAC test. No
    # password, SID, username or profile path is written to uploaded evidence.
    # Exercise the requester-SID boundary under a real foreign elevated
    # Windows identity without introducing test credentials. LocalSystem is a
    # genuine different SID and runs only this fixed disposable test action.
    $requesterSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $identityRoot=Join-Path $env:ProgramData ('TqrIdentity-'+[Guid]::NewGuid().ToString('N'))
    $identitySecurity=New-Object Security.AccessControl.DirectorySecurity
    $identitySecurity.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    [void][IO.Directory]::CreateDirectory($identityRoot,$identitySecurity)
    $identitySetup=Join-Path $identityRoot 'TailscaleQuickRepairSetup.exe'
    $identityDll=Join-Path $identityRoot 'TailscaleQuickRepair.Operations.dll'
    $identityScript=Join-Path $identityRoot 'identity-test.ps1'
    $identityReport=Join-Path $identityRoot 'identity-result.json'
    Copy-Item (Join-Path $app 'TailscaleQuickRepairSetup.exe') $identitySetup
    Copy-Item (Join-Path $app 'TailscaleQuickRepair.Operations.dll') $identityDll
    [IO.File]::WriteAllText($identityScript,@'
param([string]$Dll,[string]$Setup,[string]$RequesterSid,[string]$Report)
$ErrorActionPreference='Stop'
$complete=$false;$different=$false;$systemIdentity=$false;$refused=$false;$failureCode=0
try{
    Add-Type -Path $Dll
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $different=($identity.User -and $identity.User.Value -cne $RequesterSid)
    $systemIdentity=($identity.User -and $identity.User.Value -ceq 'S-1-5-18')
    $type=[Reflection.Assembly]::LoadFile($Setup).GetType('PublicSetupHost')
    $method=$type.GetMethod('RequireRequesterIdentity',[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $method){throw 'Requester identity boundary missing.'}
    try{[void]$method.Invoke($null,@($RequesterSid))}
    catch{
        $ex=$_.Exception
        while($ex.InnerException){$ex=$ex.InnerException}
        $refused=($ex -is [UnauthorizedAccessException])
        $failureCode=$ex.HResult
    }
    $complete=$different -and $systemIdentity -and $refused
}finally{
    [pscustomobject]@{
        complete=$complete
        differentAccount=$different
        privilegedForeignIdentity=$systemIdentity
        refused=$refused
        failureCode=$failureCode
    }|ConvertTo-Json -Compress|Set-Content -LiteralPath $Report -Encoding UTF8
}
if(-not $complete){exit 23}
'@,(New-Object Text.UTF8Encoding($false)))

    $configBefore=(Get-FileHash (Join-Path $app 'config.json')).Hash
    $markerBefore=(Get-FileHash (Join-Path $app 'protected-update.json')).Hash
    $backendBefore=(Get-FileHash (Join-Path $program 'Repair-Backend.ps1')).Hash

    $identityScheduler=New-Object -ComObject 'Schedule.Service';$identityScheduler.Connect()
    $identityFolderName='TqrIdentity-'+[Guid]::NewGuid().ToString('N')
    $identityFolder=$identityScheduler.GetFolder('\').CreateFolder($identityFolderName,$null)
    $identityTask=$identityScheduler.NewTask(0)
    $identityTask.Principal.UserId='S-1-5-18'
    $identityTask.Principal.LogonType=5
    $identityTask.Principal.RunLevel=1
    $identityTask.Settings.Enabled=$true
    $identityTask.Settings.MultipleInstances=2
    $identityTask.Settings.ExecutionTimeLimit='PT1M'
    $identityAction=$identityTask.Actions.Create(0)
    $identityAction.Path=Join-Path $PSHOME 'powershell.exe'
    $identityAction.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$identityScript+
        '" -Dll "'+$identityDll+'" -Setup "'+$identitySetup+'" -RequesterSid "'+$requesterSid+'" -Report "'+$identityReport+'"'
    $identityAction.WorkingDirectory=$identityRoot
    $registeredIdentityTask=$identityFolder.RegisterTaskDefinition('RequesterIdentityCheck',$identityTask,6,$null,$null,5,$null)
    [void]$registeredIdentityTask.Run($null)
    $identityDeadline=[DateTime]::UtcNow.AddSeconds(45)
    while(-not(Test-Path -LiteralPath $identityReport) -and [DateTime]::UtcNow -lt $identityDeadline){Start-Sleep -Milliseconds 100}
    Check (Test-Path -LiteralPath $identityReport -PathType Leaf) 'Foreign privileged identity test produces bounded typed evidence'
    $identityResult=Get-Content -LiteralPath $identityReport -Raw|ConvertFrom-Json
    Copy-Item $identityReport (Join-Path $evidence 'foreign-identity-refusal.json')
    $identityExitWatch=[Diagnostics.Stopwatch]::StartNew()
    while([int]$registeredIdentityTask.State -in @(2,4) -and $identityExitWatch.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 100}
    Check ([int]$registeredIdentityTask.State -notin @(2,4)) 'Foreign identity fixture task fully exits before its final scheduler result is evaluated'
    Check ($identityResult.complete -is [bool] -and $identityResult.complete -and
        $identityResult.differentAccount -and $identityResult.privilegedForeignIdentity -and $identityResult.refused -and
        [int64]$registeredIdentityTask.LastTaskResult -eq 0) 'A real foreign elevated Windows identity is refused by the requester identity boundary'
    Check ((Get-FileHash (Join-Path $app 'config.json')).Hash -ceq $configBefore -and
        (Get-FileHash (Join-Path $app 'protected-update.json')).Hash -ceq $markerBefore -and
        (Get-FileHash (Join-Path $program 'Repair-Backend.ps1')).Hash -ceq $backendBefore) 'Foreign-identity refusal leaves config, handoff evidence and protected backend bytes unchanged'

    Run-Child 'CheckSetupMarker' $legacy $bridge
    Check (-not(Test-Path (Join-Path $app 'protected-update.json'))) 'Refreshed Setup owns marker completion after strict validation'
    Check ((Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json).versionCode -eq $bridgeManifest.versionCode) 'Bridge leaves the user-level app on the intended release code'

    . ([scriptblock]::Create($ackFn[0].Extent.Text))
    function Get-Brush([string]$Name){return [Windows.Media.Brushes]::Gray}
    $script:ackHistory=New-Object 'Collections.Generic.List[string]'
    $script:ackNotifications=New-Object 'Collections.Generic.List[string]'
    function Write-LocalHistoryEvent { param([string]$Code,[int]$Before=-1,[int]$After=-1) $script:ackHistory.Add($Code) }
    function Request-SmartNotification { param([string]$Code,[string]$Stamp) $script:ackNotifications.Add($Code); return 'requested' }
    $RestartRegistryPath='HKCU:\Software\TailscaleQuickRepair'
    $RestartRegistryName='PendingRestartVersionCode'
    $ProductVersionCode=[int64]$bridgeManifest.versionCode
    $ProductVersion=[string]$bridgeManifest.version
    $UpdateStatusText=New-Object Windows.Controls.TextBlock
    $UpdateDetailText=New-Object Windows.Controls.TextBlock

    $acknowledged=Acknowledge-ProtectedRestart
    Check $acknowledged 'The refreshed app acknowledges the exact Setup restart version'
    $afterAck=Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction SilentlyContinue
    Check (-not $afterAck -or $null -eq $afterAck.$RestartRegistryName) 'Successful app restart clears the pending restart value'
    Check ($script:ackHistory.Count -eq 1 -and $script:ackHistory[0] -ceq 'update_installed') 'Installed History is recorded only after the refreshed app acknowledgement'
    Check ($script:ackNotifications.Count -eq 1 -and $script:ackNotifications[0] -ceq 'update_installed') 'Installed notification is requested only after restart acknowledgement'
    Check ($UpdateStatusText.Text -ceq ('Updated successfully - '+$ProductVersion) -and $UpdateDetailText.Text -ceq 'The protected update finished and Quick Repair restarted normally.') 'Acknowledged restart shows the exact ASCII-safe successful update state'

    New-Item -ItemType Directory -Path $RestartRegistryPath -Force|Out-Null
    Set-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -Type QWord -Value ([int64]$ProductVersionCode+1)
    $historyBefore=$script:ackHistory.Count
    Check (-not (Acknowledge-ProtectedRestart)) 'Wrong-version restart acknowledgement is refused'
    $wrongVersion=(Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName).$RestartRegistryName
    Check ([int64]$wrongVersion -eq ([int64]$ProductVersionCode+1) -and $script:ackHistory.Count -eq $historyBefore) 'Wrong-version acknowledgement is preserved and cannot manufacture installed History'

    Set-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -Type String -Value ([string]$ProductVersionCode)
    Check (-not (Acknowledge-ProtectedRestart)) 'Wrong-type restart acknowledgement is refused'
    $wrongType=(Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName).$RestartRegistryName
    Check ($wrongType -is [string] -and $script:ackHistory.Count -eq $historyBefore) 'Wrong-type acknowledgement remains preserved without a false success event'
    Remove-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction SilentlyContinue
    $passed=$true
}catch{
    $chain=New-Object 'Collections.Generic.List[object]';for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}finally{
    if($child){
        try{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(5000)}}catch{$cleanup=$false;$cleanupFailures.Add('child_stop')}
        $child.Dispose()
    }

    if($registeredIdentityTask){
        try{
            $identityCleanupWatch=[Diagnostics.Stopwatch]::StartNew()
            while([int]$registeredIdentityTask.State -in @(2,4) -and $identityCleanupWatch.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 100}
            if([int]$registeredIdentityTask.State -in @(2,4)){throw 'Owned identity task remained active.'}
            $registeredIdentityTask.Enabled=$false
        }catch{$cleanup=$false;$cleanupFailures.Add('identity_task_wait')}
    }
    if($identityFolder){
        try{$identityFolder.DeleteTask('RequesterIdentityCheck',0)}catch{$cleanup=$false;$cleanupFailures.Add('identity_task_delete')}
    }
    foreach($item in @($registeredIdentityTask,$identityAction,$identityTask,$identityFolder)){
        if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}
    }
    $registeredIdentityTask=$null;$identityAction=$null;$identityTask=$null;$identityFolder=$null

    if($identityScheduler -and $identityFolderName){
        try{$identityScheduler.GetFolder('\').DeleteFolder($identityFolderName,0)}catch{$cleanup=$false;$cleanupFailures.Add('identity_folder_delete')}
    }
    if($identityScheduler){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($identityScheduler)}catch{};$identityScheduler=$null}
    if($identityRoot -and (Test-Path -LiteralPath $identityRoot)){
        try{Remove-Item -LiteralPath $identityRoot -Recurse -Force}catch{$cleanup=$false;$cleanupFailures.Add('identity_root_remove')}
    }

    Remove-ItemProperty -LiteralPath 'HKCU:\Software\TailscaleQuickRepair' -Name 'PendingRestartVersionCode' -ErrorAction SilentlyContinue
    $scheduler=$null;$folder=$null
    try{
        $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$folder=$scheduler.GetFolder('\')
        foreach($name in @('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')){
            $t=$null
            try{
                $t=$folder.GetTask($name)
                $taskCleanupWatch=[Diagnostics.Stopwatch]::StartNew()
                while([int]$t.State -in @(2,4) -and $taskCleanupWatch.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 100}
                if([int]$t.State -in @(2,4)){throw 'Owned product task remained active.'}
                $t.Enabled=$false
                $folder.DeleteTask($name,0)
            }catch{
                if($_.Exception.HResult -ne -2147024894){$cleanup=$false;$cleanupFailures.Add('product_task_cleanup')}
            }finally{
                if($t){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($t)}catch{}}
            }
        }
    }catch{$cleanup=$false;$cleanupFailures.Add('product_scheduler_cleanup')}
    finally{
        foreach($item in @($folder,$scheduler)){if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}}
    }

    $cases.Add([pscustomobject]@{name='Only fixture-owned scheduled tasks are removed after the handoff test';passed=$cleanup})
    [pscustomobject]@{passed=($passed -and $cleanup);source=$env:GITHUB_SHA;fromVersion='3.0.0-phase5.2.1';cases=@($cases.ToArray());failure=$failure;
      cleanupFailures=@($cleanupFailures.ToArray());
      scope='Published updater applies only the user-level bridge; refreshed Setup marker and route are verified separately';
      limits=@('No live update manifest is changed','The final protected package is not applied through the public channel in this test','Physical UAC visuals and credential-prompt interaction remain separate field acceptance','A real foreign elevated Windows identity is tested for safe refusal; separate-administrator credential-prompt support remains outside automated acceptance','Existing protected files are compared and left untouched by the old updater')}|ConvertTo-Json -Depth 9|Set-Content (Join-Path $evidence 'protected-handoff-results.json') -Encoding UTF8
}
if(-not $passed -or -not $cleanup){throw 'Protected handoff acceptance failed; inspect preserved evidence.'}
