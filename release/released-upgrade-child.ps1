param([ValidateSet('Legacy','Upgrade')][string]$Phase,[ValidateSet('missing','off','on')][string]$Case,[string]$Package,[string]$Report)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or $env:GITHUB_REF_NAME -cne 'work/3.0' -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or -not $env:GITHUB_RUN_ID -or $env:RUNNER_OS -cne 'Windows' -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Disposable released-upgrade child refused this environment.'}
$lab=[IO.Path]::GetFullPath($env:TQR_RELEASED_UPGRADE_ROOT).TrimEnd('\')+'\'
foreach($path in @($Package,$Report)){
    if(-not [IO.Path]::GetFullPath($path).StartsWith($lab,[StringComparison]::OrdinalIgnoreCase)){throw 'Test path outside owned lab.'}
}
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair';$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$names=@('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')
$cases=New-Object 'Collections.Generic.List[object]';$passed=$false;$lease=$false;$failure=$null;$stage='start'
function Check([bool]$Value,[string]$Name){
    $script:stage=$Name;$cases.Add([pscustomobject]@{name=($Case+'/'+$Phase+': '+$Name);passed=$Value})
    if(-not $Value){throw 'Released upgrade assertion failed.'}
    Write-Host ('PASS released upgrade: '+$Name)
}
function Invoke-Setup([string]$Name,[object[]]$Arguments=@()){
    $script:stage='setup_'+$Name;$native=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$native[$i]=$null}else{$native[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    $method=$setup.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $method){throw 'Required packaged Setup boundary missing.'}
    return ,($method.Invoke($null,$native))
}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Import-Function([string]$Text,[string]$Name){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Packaged script did not parse.'}
    $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($f.Count -ne 1){throw 'Expected one packaged function.'}
    return [scriptblock]::Create($f[0].Extent.Text)
}
function Snapshot {
    $values=@{}
    foreach($name in @('config.json','auto-repair.json','auto-repair-state.json','health-history.json','health-history.previous.json','notification-policy.json')){
        $path=Join-Path $app $name
        if(Test-Path -LiteralPath $path){$values[$name]=Hash $path}else{$values[$name]='absent'}
    }
    return $values
}
function All-Same($Before){
    $now=Snapshot
    foreach($key in $Before.Keys){if($now[$key] -cne $Before[$key]){return $false}}
    return $true
}
function Check-Payload {
    $manifest=Get-Content (Join-Path $Package 'package-manifest.json') -Raw|ConvertFrom-Json
    $ok=$true
    foreach($f in $manifest.files){
        $target=[string](Invoke-Setup 'ResolveInstallTarget' @([string]$f.path))
        if((Hash $target) -ine $f.sha256){$ok=$false}
    }
    Check $ok 'Every installed file matches the exact selected release manifest'
}
function Wait-Idle($Task){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while([int]$Task.State -in @(2,4)){
        if($watch.Elapsed.TotalSeconds -gt 120){throw 'Existing task is active; never rerun or kill it to pass.'}
        Start-Sleep -Milliseconds 100
    }
}
try{
    Check (-not (Get-Service Tailscale -ErrorAction SilentlyContinue)) 'No vendor service or tailnet is involved'
    $setupPath=Join-Path $Package 'app/TailscaleQuickRepairSetup.exe'
    $setup=[Reflection.Assembly]::LoadFile($setupPath).GetType('PublicSetupHost')
    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$folder=$scheduler.GetFolder('\')
    if($Phase -eq 'Legacy'){
        Check (-not(Test-Path $app) -and -not(Test-Path $program)) 'Legacy install starts in empty product roots'
        $lease=[bool](Invoke-Setup 'TryAcquireOperationLock' @('setup'));Check $lease 'Published Setup acquires its real operation lease'
        $manifest=Invoke-Setup 'ReadPackageManifest' @($Package)
        $verified=Invoke-Setup 'VerifyPackage' @($Package,$manifest)
        $apply=Join-Path $lab ($Case+'-legacy-apply');[void][IO.Directory]::CreateDirectory($apply)
        [void](Invoke-Setup 'ApplyFiles' @($verified,$apply));Check-Payload
        [void](Invoke-Setup 'WriteLocalConfig' @('upgrade-fixture.invalid'))
        [void](Invoke-Setup 'ConfigureStartup' @($Case -ne 'off'))
        [void](Invoke-Setup 'RegisterRepairTask');[void](Invoke-Setup 'RegisterAutoRepairTask')
        $task=$folder.GetTask($names[1])
        Check ($task.Definition.Triggers.Count -eq 1 -and $task.Definition.Triggers.Item(1).Repetition.Interval -eq 'PT5M') 'Real published task retains its original single fallback trigger'
        # Quiesce only these newly created fixture tasks before seeding opt-in.
        # This tests existing task replacement, not migration of a running job.
        foreach($name in $names){$t=$folder.GetTask($name);$t.Enabled=$false;Wait-Idle $t}
        $ui=[IO.File]::ReadAllText((Join-Path $app 'Tailscale-Repair-UI.ps1'))
        $StateDir=$app;$AutoRepairSettingsPath=Join-Path $app 'auto-repair.json'
        . (Import-Function $ui 'Write-JsonFileAtomic');. (Import-Function $ui 'Set-AutoRepairEnabled')
        if($Case -ne 'missing'){Check (Set-AutoRepairEnabled ($Case -eq 'on')) 'Published UI writes the selected explicit preference'}
        else{Check (-not(Test-Path $AutoRepairSettingsPath)) 'Unconfigured preference stays genuinely absent'}
        Add-Type -Path (Join-Path $app 'TailscaleQuickRepair.Operations.dll')
        Check ([Tqr.LocalHistory]::Record($app,'check_healthy',-1,-1)) 'Published History writer saves the first typed fixture event'
        Check ([Tqr.LocalHistory]::Record($app,'integrity_ok',-1,-1)) 'Published History writer retains an additional typed fixture event'
        $notifications=New-Object Tqr.SmartNotifications($app,[DateTime]::UtcNow)
        Check (($notifications.SetEnabled(($Case -ne 'off'),[DateTime]::UtcNow)).Status -eq 'ready') 'Published notification preference is saved by its actual implementation'
        $AppDir=$app;$StatePath=Join-Path $app 'auto-repair-state.json'
        $worker=[IO.File]::ReadAllText((Join-Path $program 'Auto-Repair-Monitor.ps1'))
        . (Import-Function $worker 'Write-State')
        Write-State -Status 'repaired' -Message 'Synthetic historical task request, not successful recovery.' -RepairStarted $true -Reason 'fixture local check'
        $old=Get-Content $StatePath -Raw|ConvertFrom-Json
        Check ($old.lastRepairUtc -and $old.status -ceq 'repaired') 'Published state writer creates an explicitly synthetic legacy reservation'
        Check ($null -eq $setup.GetMethod('PrepareProtectedRoot',[Reflection.BindingFlags]'NonPublic,Static')) 'Released host predates the new permission-migration routine; old-host upgrade is not certified'
        $baseline=Snapshot
        $baseline|ConvertTo-Json|Set-Content (Join-Path $lab ($Case+'-baseline.json')) -Encoding UTF8
    }else{
        Check ((Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json).version -ceq '3.0.0-phase5.2.1') 'Upgrade begins from genuinely installed published 5.2.1 files'
        foreach($name in $names){$t=$folder.GetTask($name);Check (-not $t.Enabled -and [int]$t.State -notin @(2,4)) 'Existing released task is retained and idle, not deleted before migration'}
        $baseline=@{};$seed=Get-Content (Join-Path $lab ($Case+'-baseline.json')) -Raw|ConvertFrom-Json
        foreach($p in $seed.PSObject.Properties){$baseline[$p.Name]=$p.Value}
        Check (All-Same $baseline) 'All seeded legacy preferences and History survive between native processes'
        $peer=[string](Invoke-Setup 'ReadConfiguredPeer');$startup=[bool](Invoke-Setup 'IsStartupEnabled')
        Check ($peer -ceq 'upgrade-fixture.invalid' -and $startup -eq ($Case -ne 'off')) 'New Setup reads the existing target and startup preference'
        $lease=[bool](Invoke-Setup 'TryAcquireOperationLock' @('setup'));Check $lease 'New Setup uses its real coordinator over the existing installation'
        $manifest=Invoke-Setup 'ReadPackageManifest' @($Package)
        $verified=Invoke-Setup 'VerifyPackage' @($Package,$manifest)
        $apply=Join-Path $lab ($Case+'-upgrade-apply');[void][IO.Directory]::CreateDirectory($apply)
        [void](Invoke-Setup 'ApplyFiles' @($verified,$apply));Check-Payload
        [void](Invoke-Setup 'WriteLocalConfig' @($peer));[void](Invoke-Setup 'ConfigureStartup' @($startup))
        [void](Invoke-Setup 'RegisterRepairTask');[void](Invoke-Setup 'RegisterAutoRepairTask')
        Check (All-Same $baseline) 'New file and task migration preserves every selected preference and local-evidence byte'
        $version=Get-Content (Join-Path $Package 'version.json') -Raw|ConvertFrom-Json
        Check ((Get-Content (Join-Path $app 'version.user.json') -Raw|ConvertFrom-Json).versionCode -eq $version.versionCode) 'Installed version metadata advances to this exact development package'
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach($name in $names){
            $t=$folder.GetTask($name);$d=$t.Definition;$principal=[string]$d.Principal.UserId
            $taskSid=if($principal -match '^S-1-'){$principal}else{([Security.Principal.NTAccount]::new($principal)).Translate([Security.Principal.SecurityIdentifier]).Value}
            Check ($taskSid -ceq $sid -and $d.Principal.RunLevel -eq 1 -and $d.Principal.LogonType -eq 3) 'Migrated task retains the correct highest-interactive user identity'
            $sddl=[string]$t.GetSecurityDescriptor(7)
            [void](Invoke-Setup 'VerifyTaskSecurity' @($sddl,$sid))
            Check $true 'Migrated task satisfies the actual native read/run-only security verifier'
            Check ($d.Actions.Count -eq 1 -and $d.Actions.Item(1).Path -ieq (Join-Path $env:WINDIR 'System32/wscript.exe')) 'Migrated task has exactly one fixed native launcher action'
        }
        $auto=$folder.GetTask($names[1]);$d=$auto.Definition
        Check ($d.Triggers.Count -eq 4 -and $d.Triggers.Item(1).Repetition.Interval -ceq 'PT5M' -and -not [string]$d.Triggers.Item(1).Repetition.Duration) 'Released single-trigger task migrates to four triggers and an indefinite five-minute fallback'
        Check ($folder.GetTask($names[0]).Definition.Triggers.Count -eq 0) 'Manual repair task remains strictly on-demand'
        $acl=Get-Acl $program
        Check ($acl.AreAccessRulesProtected -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-32-544') 'Released installation now has protected administrator-owned program permissions'
        Check ((Hash (Join-Path $program 'TailscaleQuickRepair.Operations.dll')) -ceq (Hash (Join-Path $app 'TailscaleQuickRepair.Operations.dll'))) 'Migrated user and protected libraries have identical bytes'
        Add-Type -Path (Join-Path $app 'TailscaleQuickRepair.Operations.dll')
        Check ([Tqr.AutoRepairPolicyStore]::ReadEnabled($app) -eq ($Case -eq 'on')) 'New reader preserves missing, off and on semantics after the real release upgrade'
        Check ([Tqr.LocalHistory]::Read($app).Status -eq 'ready' -and [Tqr.LocalHistory]::Read($app).Entries.Count -eq 2) 'New library reads both genuine old-library History records'
        $notifications=New-Object Tqr.SmartNotifications($app,[DateTime]::UtcNow)
        Check ($notifications.Settings().Status -eq 'ready' -and $notifications.Settings().Enabled -eq ($Case -ne 'off')) 'New notification reader preserves the old opt-in value without sending a banner'
        $legacy=Get-Content (Join-Path $app 'auto-repair-state.json') -Raw|ConvertFrom-Json
        $oldStamp=[string]$legacy.lastRepairUtc
        [void](Invoke-Setup 'ReleaseOperationLock');$lease=$false
        Wait-Idle $auto;$started=[DateTime]::UtcNow;$running=$auto.Run($null)
        Check ($null -ne $running) 'Migrated real task accepts an on-demand monitor request'
        $watch=[Diagnostics.Stopwatch]::StartNew();$done=$false
        do{
            if($auto.LastRunTime.ToUniversalTime() -ge $started.AddSeconds(-2) -and [int]$auto.State -notin @(2,4)){$done=$true;break}
            Start-Sleep -Milliseconds 100
        }while($watch.Elapsed.TotalSeconds -lt 35)
        Check $done 'Migrated real monitor task completes within the bounded wait'
        if($Case -eq 'on'){
            $result=[Tqr.AutoRepairRecords]::Current($app)
            Check ($result -and $result.status -ceq 'manual' -and $result.reason -ceq 'installation_missing' -and $result.actionsAttempted -eq 0 -and -not $result.recoveryConfirmed) 'Opted-in upgraded worker reports missing vendor software without a repair or false recovery'
            $policy=Get-Content (Join-Path $app 'auto-repair-policy.json') -Raw|ConvertFrom-Json
            Check ($policy.Attempts -eq 1 -and $policy.LastAttempt -ceq $oldStamp -and ([DateTime]::Parse($policy.NextAllowed)-[DateTime]::Parse($oldStamp)).TotalMinutes -eq 15) 'First upgraded worker preserves the actual legacy reservation and fifteen-minute budget'
            Check ([int64]$auto.LastTaskResult -eq 20) 'Migrated task propagates attention rather than successful-recovery status'
            Check ([Tqr.LocalHistory]::Read($app).Entries.Count -eq 2) 'Legacy repaired label does not manufacture new confirmed-recovery History'
        }else{
            Check ((Hash (Join-Path $app 'auto-repair-state.json')) -ceq $baseline['auto-repair-state.json'] -and -not(Test-Path (Join-Path $app 'auto-repair-policy.json'))) 'Missing or off preference leaves the old evidence and retry state untouched'
            Check ([int64]$auto.LastTaskResult -eq 0) 'Migrated opted-out task exits quietly'
        }
    }
    $passed=$true
}catch{
    $chain=New-Object 'Collections.Generic.List[object]'
    for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}finally{
    if($lease){try{[void](Invoke-Setup 'ReleaseOperationLock')}catch{$passed=$false}}
    [pscustomobject]@{passed=$passed;source=$env:GITHUB_SHA;phase=$Phase;scenario=$Case;cases=@($cases.ToArray());failure=$failure}|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $Report -Encoding UTF8
}
if(-not $passed){exit 21}
