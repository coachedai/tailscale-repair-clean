param(
    [ValidateSet('InstallLegacy','ApplyBridge','CheckSetupMarker')][string]$Phase,
    [string]$LegacyPackage,
    [string]$CurrentPackage,
    [string]$Report
)
$ErrorActionPreference='Stop'
$releaseValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$developmentValidation=($env:GITHUB_REF_NAME -ceq 'work/3.0')
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   -not ($developmentValidation -or $releaseValidation) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or -not $env:GITHUB_RUN_ID -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Protected handoff child refused this environment.'}

$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false;$lease=$false;$failure=$null;$stage='start'
function Check([bool]$Value,[string]$Name){$script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value});if(-not $Value){throw 'Protected handoff assertion failed.'}}
function Invoke-Private($Type,[string]$Name,[object[]]$Arguments=@()){
    $script:stage='invoke_'+$Name
    $method=$Type.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $method){throw 'Expected private boundary missing.'}
    $native=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$native[$i]=$null}else{$native[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    return ,($method.Invoke($null,$native))
}
try{
    if($Phase -eq 'InstallLegacy'){
        Check (-not(Test-Path $app) -and -not(Test-Path $program)) 'Legacy handoff fixture starts from empty product roots'
        $type=[Reflection.Assembly]::LoadFile((Join-Path $LegacyPackage 'app\TailscaleQuickRepairSetup.exe')).GetType('PublicSetupHost')
        $lease=[bool](Invoke-Private $type 'TryAcquireOperationLock' @('setup'))
        Check $lease 'Published Setup acquires its real operation lease'
        $manifest=Invoke-Private $type 'ReadPackageManifest' @($LegacyPackage)
        $files=Invoke-Private $type 'VerifyPackage' @($LegacyPackage,$manifest)
        $work=Join-Path $env:TEMP ('TqrLegacyHandoff-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
        [void](Invoke-Private $type 'ApplyFiles' @($files,$work))
        [void](Invoke-Private $type 'WriteLocalConfig' @('handoff-fixture.invalid'))
        Check ((Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json).version -ceq '3.0.0-phase5.2.1') 'Published 5.2.1 files are genuinely installed'
        Check (Test-Path (Join-Path $program 'Repair-Backend.ps1')) 'Published protected backend exists before the bridge'
    }
    elseif($Phase -eq 'ApplyBridge'){
        $installedUpdater=Join-Path $app 'TailscaleQuickRepairUpdater.exe'
        $releasedUpdater=Join-Path $LegacyPackage 'app\TailscaleQuickRepairUpdater.exe'
        Check ((Get-FileHash $installedUpdater).Hash -ceq (Get-FileHash $releasedUpdater).Hash) 'Installed updater matches the genuine published 5.2.1 bytes'

        $installedUi=Join-Path $app 'Tailscale-Repair-UI.ps1'
        $uiText=[IO.File]::ReadAllText($installedUi,[Text.Encoding]::UTF8)
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($uiText,[ref]$tokens,[ref]$errors)
        $updateFunctions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Start-UpdateInstall'},$true))
        Check ($errors.Count -eq 0 -and $updateFunctions.Count -eq 1) 'Published 5.2.1 installed UI has one parsed Update now action'
        $route=[string]$updateFunctions[0].Extent.Text
        Check ($route.Contains('Copy-Item -LiteralPath $UpdaterHostPath -Destination $tempUpdater -Force') -and
            $route.Contains('$psi.FileName = $tempUpdater') -and
            $route.Contains("'--silent'") -and $route.Contains("'--current-pid'") -and $route.Contains("'--current-code'")) 'Published Update now route copies the updater to TEMP before replacement'

        $tempUpdater=Join-Path $env:TEMP ('TailscaleQuickRepairUpdater-5.2.1-'+[Guid]::NewGuid().ToString('N')+'.exe')
        Copy-Item -LiteralPath $installedUpdater -Destination $tempUpdater -Force
        Check ((Get-FileHash $tempUpdater).Hash -ceq (Get-FileHash $installedUpdater).Hash) 'TEMP updater copy is byte-for-byte identical to the installed 5.2.1 updater'
        $type=[Reflection.Assembly]::LoadFile($tempUpdater).GetType('Program')

        $synthetic='{"schema":1,"published":true,"version":"fixture","versionCode":2,"requiresSetup":false,"protectedHandoff":true,"package":{"url":"https://github.com/coachedai/tailscale-repair-clean/releases/download/vfixture/package.zip","sha256":"'+('a'*64)+'","size":1}}'
        $parsed=Invoke-Private $type 'DeserializeObject' @($synthetic)
        Check ($parsed.ContainsKey('protectedHandoff') -and -not [bool](Invoke-Private $type 'ReadBool' @($parsed,'requiresSetup'))) 'Published 5.2.1 updater parser accepts an extra protectedHandoff field while retaining requiresSetup false'
        $manifest=Invoke-Private $type 'ReadPackageManifest' @($CurrentPackage)
        $files=Invoke-Private $type 'VerifyPackageFiles' @($CurrentPackage,$manifest)
        Check (@($files).Count -gt 0) 'Published updater accepts the staged ordinary package'
        $lease=[bool](Invoke-Private $type 'TryAcquireOperationLock' @('update'))
        Check $lease 'TEMP 5.2.1 updater acquires the real update operation lease'
        [void](Invoke-Private $type 'ApplyTransaction' @($files,[string]$manifest.Version,[int64]$manifest.VersionCode))
        Check ((Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json).versionCode -eq [int64]$manifest.VersionCode) 'Published updater advances the user-level package to the staged version'
        Check (Test-Path (Join-Path $app 'protected-update.json') -PathType Leaf) 'Published updater installs the protected-update handoff marker'
        Check ((Get-FileHash $installedUpdater).Hash -ceq (Get-FileHash (Join-Path $CurrentPackage 'app\TailscaleQuickRepairUpdater.exe')).Hash) 'TEMP updater safely replaces the installed updater with the staged bytes'
        [void](Invoke-Private $type 'ReleaseOperationLock');$lease=$false
        Remove-Item -LiteralPath $tempUpdater -Force -ErrorAction SilentlyContinue
    }
    else{
        $type=[Reflection.Assembly]::LoadFile((Join-Path $app 'TailscaleQuickRepairSetup.exe')).GetType('PublicSetupHost')
        $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        [void](Invoke-Private $type 'RequireRequesterIdentity' @($currentSid))
        Check $true 'Refreshed Setup accepts the initiating Windows SID'
        $configHash=(Get-FileHash (Join-Path $app 'config.json')).Hash
        $markerHash=(Get-FileHash (Join-Path $app 'protected-update.json')).Hash
        $differentSid=if($currentSid -cne 'S-1-5-18'){'S-1-5-18'}else{'S-1-5-32-544'}
        $identityRefused=$false
        try{[void](Invoke-Private $type 'RequireRequesterIdentity' @($differentSid))}catch{$identityRefused=$true}
        Check $identityRefused 'Refreshed Setup refuses a different valid Windows SID before migration'
        Check ((Get-FileHash (Join-Path $app 'config.json')).Hash -ceq $configHash -and
            (Get-FileHash (Join-Path $app 'protected-update.json')).Hash -ceq $markerHash) 'Identity refusal leaves target and handoff evidence unchanged'

        $holderScript=Join-Path $env:TEMP ('TqrHandoffLease-'+[Guid]::NewGuid().ToString('N')+'.ps1')
        $ready=$holderScript+'.ready'
        [IO.File]::WriteAllText($holderScript,@'
param([string]$Dll,[string]$Root,[string]$Ready,[string]$Kind,[int]$HoldMilliseconds)
Add-Type -Path $Dll
$lease=[Tqr.OperationGate]::TryAcquire($Root,$Kind)
if(-not $lease){exit 31}
try{
    [IO.File]::WriteAllText($Ready,'ready')
    Start-Sleep -Milliseconds $HoldMilliseconds
}finally{$lease.Dispose()}
'@)
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.Arguments='-NoProfile -NonInteractive -File "'+$holderScript+'" -Dll "'+(Join-Path $app 'TailscaleQuickRepair.Operations.dll')+'" -Root "'+$app+'" -Ready "'+$ready+'" -Kind update -HoldMilliseconds 1500'
        $holder=[Diagnostics.Process]::Start($psi)
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
        Check (Test-Path $ready) 'A separate old-updater owner holds the real operation lease'
        $wait=[Diagnostics.Stopwatch]::StartNew()
        $acquired=[bool](Invoke-Private $type 'TryAcquireUpgradeOperationLock')
        Check ($acquired -and $wait.ElapsedMilliseconds -ge 1000 -and $wait.ElapsedMilliseconds -lt 10000) 'Refreshed Setup waits only for the finishing update owner and then acquires safely'
        [void](Invoke-Private $type 'ReleaseOperationLock');$lease=$false
        Check ($holder.WaitForExit(10000) -and $holder.ExitCode -eq 0) 'Previous updater owner exits normally without its lock being stolen'
        $holder.Dispose();Remove-Item $ready -Force -ErrorAction SilentlyContinue

        # An unrelated live operation is different from the updater handoff.
        # Setup must refuse immediately rather than waiting, deleting or taking
        # ownership of that operation.
        $repairReady=$holderScript+'.repair.ready'
        $repairPsi=New-Object Diagnostics.ProcessStartInfo
        $repairPsi.FileName=Join-Path $PSHOME 'powershell.exe';$repairPsi.UseShellExecute=$false;$repairPsi.CreateNoWindow=$true
        $repairPsi.Arguments='-NoProfile -NonInteractive -File "'+$holderScript+'" -Dll "'+(Join-Path $app 'TailscaleQuickRepair.Operations.dll')+'" -Root "'+$app+'" -Ready "'+$repairReady+'" -Kind repair -HoldMilliseconds 2500'
        $repairHolder=[Diagnostics.Process]::Start($repairPsi)
        $repairDeadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not(Test-Path $repairReady) -and [DateTime]::UtcNow -lt $repairDeadline){Start-Sleep -Milliseconds 25}
        Check (Test-Path $repairReady) 'A separate repair owner holds the real operation lease'
        $refusalWatch=[Diagnostics.Stopwatch]::StartNew()
        $refused=-not [bool](Invoke-Private $type 'TryAcquireUpgradeOperationLock')
        Check ($refused -and $refusalWatch.ElapsedMilliseconds -lt 1500) 'Refreshed Setup refuses an unrelated live operation without waiting through it'
        $owner=[Tqr.OperationGate]::Inspect($app)
        Check ($owner -and $owner.kind -ceq 'repair' -and $owner.ownerPid -eq $repairHolder.Id) 'Unrelated operation ownership remains unchanged after Setup refusal'
        Check ($repairHolder.WaitForExit(10000) -and $repairHolder.ExitCode -eq 0) 'Unrelated repair owner exits normally after refusal'
        $repairHolder.Dispose();Remove-Item $holderScript,$repairReady -Force -ErrorAction SilentlyContinue

        $marker=Get-Content (Join-Path $app 'protected-update.json') -Raw|ConvertFrom-Json
        $wrong=$false
        try{[void](Invoke-Private $type 'ValidateProtectedUpdateMarker' @([int64]$marker.versionCode+1,[string]$marker.channel))}catch{$wrong=$true}
        Check $wrong 'Refreshed Setup rejects a handoff marker for another release'
        $wrongChannel=$false
        $otherChannel=if([string]$marker.channel -ceq 'preview'){'stable'}else{'preview'}
        try{[void](Invoke-Private $type 'ValidateProtectedUpdateMarker' @([int64]$marker.versionCode,$otherChannel))}catch{$wrongChannel=$true}
        Check $wrongChannel 'Refreshed Setup rejects a handoff marker from another update channel'
        [void](Invoke-Private $type 'ValidateProtectedUpdateMarker' @([int64]$marker.versionCode,[string]$marker.channel))
        Check $true 'Refreshed Setup accepts the exact staged release and channel marker'
        Check (([string](Invoke-Private $type 'ReadConfiguredPeer')).Trim() -ceq 'handoff-fixture.invalid') 'Upgrade mode can reuse the existing configured target'
        [void](Invoke-Private $type 'WriteRestartPending' @([int64]$marker.versionCode))
        $restartKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\TailscaleQuickRepair',$false)
        try{
            $restartValue=$restartKey.GetValue('PendingRestartVersionCode',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $restartKind=$restartKey.GetValueKind('PendingRestartVersionCode')
            Check ($restartKind -eq [Microsoft.Win32.RegistryValueKind]::QWord -and [int64]$restartValue -eq [int64]$marker.versionCode) 'Refreshed Setup persists the exact pending restart version as a QWORD'
        }finally{if($restartKey){$restartKey.Dispose()}}
        [void](Invoke-Private $type 'RemoveProtectedUpdateMarker')
        Check (-not(Test-Path (Join-Path $app 'protected-update.json'))) 'Protected marker is removed only by the refreshed Setup completion boundary'
    }
    $passed=$true
}catch{
    $chain=New-Object 'Collections.Generic.List[object]'
    for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}finally{
    if($lease){
        try{
            $t=[Reflection.Assembly]::LoadFile((Join-Path $LegacyPackage 'app\TailscaleQuickRepairSetup.exe')).GetType('PublicSetupHost')
            [void](Invoke-Private $t 'ReleaseOperationLock')
        }catch{$passed=$false}
    }
    [pscustomobject]@{passed=$passed;source=$env:GITHUB_SHA;phase=$Phase;cases=@($cases.ToArray());failure=$failure}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Report -Encoding UTF8
}
if(-not $passed){exit 21}
