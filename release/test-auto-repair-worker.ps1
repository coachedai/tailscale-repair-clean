param([Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$EvidenceDirectory='.\test-evidence')
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Native Windows PowerShell 5.1 required.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Web.Extensions
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$root=Join-Path $env:TEMP ('TQR-WorkerGate-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$script:workerCases=New-Object 'Collections.Generic.List[object]'
$passed=$false;$children=New-Object 'Collections.Generic.List[object]'
function Assert-Worker([bool]$Value,[string]$Name){
    $script:workerCases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw "FAILED worker: $Name"}
    Write-Host "PASS worker: $Name"
}
function Put-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($false)))}
function New-WorkerRoot([string]$Name){
    $path=Join-Path $root $Name;New-Item -ItemType Directory -Path $path|Out-Null
    Put-Json (Join-Path $path 'auto-repair.json') @{enabled=$true}
    return $path
}
function New-Machine([string]$Path,[string]$Fault='healthy'){
    $m=New-Object TqrWorkerFixture.Machine
    $m.Root=$Path
    switch($Fault){
        'service' {$m.Health.Service='Stopped';$m.Health.Backend='Unknown'}
        'client' {$m.Health.Client='Closed'}
        'backend' {$m.Health.Backend='Starting'}
        'unknown' {$m.Health.Backend='Unknown'}
    }
    return $m
}
function Run-Worker($Machine){return [Tqr.AutoRepairWorker]::Execute($Machine.Root,$Machine)}
function Prime-Worker($Machine){[void](Run-Worker $Machine);$Machine.Now=$Machine.Now.AddSeconds(61)}
try{
    $setupZip=@(Get-ChildItem $OutputDirectory -Filter '*SetupPackage-*.zip')
    $appZip=@(Get-ChildItem $OutputDirectory -Filter 'TailscaleQuickRepair-*.zip'|Where-Object Name -notlike '*SetupPackage*')
    Assert-Worker ($setupZip.Count -eq 1 -and $appZip.Count -eq 1) 'Exact ordinary and protected delivery packages are present'
    $setup=Join-Path $root 'package';$ordinary=Join-Path $root 'ordinary'
    Expand-Archive $setupZip[0].FullName $setup;Expand-Archive $appZip[0].FullName $ordinary
    $dll=Join-Path $setup 'program\TailscaleQuickRepair.Operations.dll'
    $appDll=Join-Path $setup 'app\TailscaleQuickRepair.Operations.dll'
    Assert-Worker ((Get-FileHash $dll).Hash -eq (Get-FileHash $appDll).Hash) 'App and protected workers receive the same compiled operations library'
    Add-Type -Path $dll
    Assert-Worker ([IO.Path]::GetFullPath([Tqr.AutoRepairWorker].Assembly.Location) -ieq [IO.Path]::GetFullPath($dll)) 'Worker test executes the exact protected package assembly, not a previously loaded app build'
    Assert-Worker ($null -ne ('Tqr.AutoRepairWorker' -as [type]) -and $null -ne ('Tqr.WindowsAutoRepairMachine' -as [type])) 'Actual packaged library contains the worker and production OS boundary'
    $monitor=Join-Path $setup 'program\Auto-Repair-Monitor.ps1'
    Assert-Worker ((Get-FileHash $monitor).Hash -eq (Get-FileHash (Join-Path $repo 'src\program\Auto-Repair-Monitor.ps1')).Hash) 'Protected package delivers the exact reviewed monitor entry'
    Assert-Worker (-not(Test-Path (Join-Path $ordinary 'program\Auto-Repair-Monitor.ps1'))) 'Ordinary package cannot silently replace the protected monitor'
    $publish=Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json
    $directSetup=($publish.requiresSetup -is [bool] -and [bool]$publish.requiresSetup)
    $protectedHandoff=($publish.PSObject.Properties.Name -contains 'protectedHandoff' -and $publish.protectedHandoff -is [bool] -and [bool]$publish.protectedHandoff)
    Assert-Worker ($directSetup -xor $protectedHandoff) 'Worker-changing release has exactly one protected delivery route'
    if($protectedHandoff){
        Assert-Worker (-not $directSetup -and (Test-Path (Join-Path $ordinary 'app\protected-update.json')) -and
            (Test-Path (Join-Path $ordinary 'app\TailscaleQuickRepairSetup.exe')) -and
            -not(Test-Path (Join-Path $ordinary 'program\Auto-Repair-Monitor.ps1'))) 'Staged handoff carries Setup and marker but no protected worker'
    }
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $web=Join-Path (Split-Path $compiler) 'System.Web.Extensions.dll'
    $fixtureSource=Join-Path $root 'fixture.cs';$fixtureDll=Join-Path $root 'WorkerFixture.dll'
    @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;
using Tqr;
namespace TqrWorkerFixture {
public sealed class Machine : IAutoRepairMachine {
    public string Root,Mode="normal";
    public DateTime Now=DateTime.UtcNow;
    public AutoHealth Health=new AutoHealth { Service="Running",Startup="Automatic",Client="Running",Backend="Running" };
    public int Observations,OutsideLease,Opens,Starts,Stops;
    public bool Continue=true,Mutate=true,CloseClientAfterStart;
    public DateTime UtcNow { get { return Now; } }
    public bool CanContinue { get { return Continue; } }
    public bool CanMutate { get { return Mutate; } }
    public AutoHealth Observe(){
        Observations++;
        OperationState owner=OperationGate.Inspect(Root);
        if(owner==null || owner.kind!="maintenance" || owner.ownerPid!=Process.GetCurrentProcess().Id) OutsideLease++;
        return Health;
    }
    private void Before(Action permission) {
        if(Mode=="disable_before") File.WriteAllText(Path.Combine(Root,"auto-repair.json"),"{\"enabled\":false}");
        if(Mode=="intent_before") Health.Backend="NeedsLogin";
        if(Mode=="environment_before") Continue=false;
        if(Mode=="corrupt_record") File.WriteAllText(Path.Combine(Root,"auto-repair-state.json"),"{fixture-damage");
        if(Mode=="replace_owner") {
            string p=Path.Combine(Root,"operation.lock");JavaScriptSerializer j=new JavaScriptSerializer();
            Dictionary<string,object> state=j.Deserialize<Dictionary<string,object>>(File.ReadAllText(p));
            state["leaseId"]=Guid.NewGuid().ToString("N");File.WriteAllText(p,j.Serialize(state));
        }
        if(Mode=="wait_before") {
            File.WriteAllText(Path.Combine(Root,"fixture-ready"),"ready");
            DateTime end=DateTime.UtcNow.AddSeconds(15);
            while(!File.Exists(Path.Combine(Root,"fixture-release")) && DateTime.UtcNow<end) Thread.Sleep(20);
        }
        permission();
        AutoRepairResult record=AutoRepairRecords.Current(Root);
        if(record==null || record.actionsAttempted<1 || record.recoveryConfirmed || record.phase=="Complete") throw new Exception("No durable action reservation.");
        if(Mode=="throw") throw new Exception("fixture-private-text");
    }
    public bool OpenClient(Action authorize){Before(authorize);Opens++;if(Mode=="action_false") return false;Health.Client="Running";return true;}
    public bool StartService(Action authorize){Before(authorize);Starts++;if(Mode=="action_false") return false;Health.Service="Running";Health.Backend=Mode=="unknown_after"?"Unknown":"Running";if(CloseClientAfterStart)Health.Client="Closed";return true;}
    public bool StopService(Action authorize){Before(authorize);Stops++;if(Mode=="action_false") return false;Health.Service="Stopped";Health.Backend="Unknown";
        if(Mode=="disable_after_stop")File.WriteAllText(Path.Combine(Root,"auto-repair.json"),"{\"enabled\":false}");
        if(Mode=="environment_after_stop")Continue=false;
        return true;
    }
    public void Pause(){Now=Now.AddMilliseconds(500);}
}
public sealed class Principal {public string UserId;public int LogonType=3,RunLevel=1;}
public sealed class TaskAction {public int Type=0;public string Path,Arguments,WorkingDirectory;}
public sealed class Actions {public int Count=1;public TaskAction Action=new TaskAction();public TaskAction Item(int index){if(index!=1)throw new Exception();return Action;}}
public sealed class Definition {public Principal Principal=new Principal();public Actions Actions=new Actions();}
public sealed class Task {public bool Enabled=true;public int Runs;public Definition Definition=new Definition();public object Run(object value){Runs++;return new object();}}
public sealed class Folder {public Task Task=new Task();public Task GetTask(string name){if(name!="Tailscale Quick Repair Auto Monitor")throw new Exception();return Task;}}
public sealed class Scheduler {public Folder Folder=new Folder();public void Connect(){}public Folder GetFolder(string path){if(path!="\\")throw new Exception();return Folder;}}
}
'@|Set-Content $fixtureSource -Encoding UTF8
    & $compiler /nologo /target:library ('/out:'+$fixtureDll) ('/reference:'+$dll) ('/reference:'+$web) $fixtureSource
    Assert-Worker ($LASTEXITCODE -eq 0) 'Native fixture compiles against the actual packaged worker interface'
    Add-Type -Path $fixtureDll
    $path=New-WorkerRoot 'disabled';Put-Json (Join-Path $path 'auto-repair.json') @{enabled=$false};$m=New-Machine $path 'service';$r=Run-Worker $m
    Assert-Worker ($r.status -eq 'disabled' -and $m.Observations -eq 0 -and @(Get-ChildItem $path).Count -eq 1) 'Disabled worker performs no observation, policy write or repair'
    $path=New-WorkerRoot 'healthy';$m=New-Machine $path;$r=Run-Worker $m;$first=$r.runId;$r2=Run-Worker $m
    Assert-Worker ($r.status -eq 'healthy' -and -not $r.recoveryConfirmed -and $m.Starts+$m.Opens+$m.Stops -eq 0) 'Healthy local check never claims to have repaired anything'
    Assert-Worker ($r2.runId -ne $first -and $m.OutsideLease -eq 0) 'Each run has its own ID and every observation holds the real operation lease'
    foreach($state in @('Stopped','NeedsLogin','NeedsMachineAuth','InUseOtherUser','Unknown')){
        $m=New-Machine (New-WorkerRoot ('intent-'+$state)) 'client';$m.Health.Backend=$state;Prime-Worker $m;$r=Run-Worker $m
        Assert-Worker ($m.Starts+$m.Stops+$m.Opens -eq 0 -and $r.status -ne 'healthy') "Actual worker preserves intentional/authentication or unknown state: $state"
    }
    foreach($fault in @('service','client','backend')){
        $m=New-Machine (New-WorkerRoot $fault) $fault
        $first=Run-Worker $m
        Assert-Worker ($first.reason -eq 'confirming_fault' -and $m.Starts+$m.Stops+$m.Opens -eq 0) "$fault first observation cannot dispatch repair"
        $m.Now=$m.Now.AddSeconds(61);$r=Run-Worker $m;$saved=[Tqr.AutoRepairRecords]::Current($m.Root)
        Assert-Worker ($r.recoveryConfirmed -and $saved.recoveryConfirmed -and $r.status -eq 'healthy' -and $r.phase -eq 'Complete') "$fault recovery requires completed action and explicit final Running evidence"
        $expected=if($fault -eq 'backend'){2}else{1}
        Assert-Worker ($r.actionsAttempted -eq $expected -and $r.actionsCompleted -eq $expected -and $m.OutsideLease -eq 0) "$fault actions and counters remain inside the real lease"
        if($fault -eq 'service'){Assert-Worker ($m.Starts -eq 1 -and $m.Stops -eq 0 -and $m.Opens -eq 0) 'Stopped service starts only that service'}
        if($fault -eq 'client'){Assert-Worker ($m.Opens -eq 1 -and $m.Stops -eq 0 -and $m.Starts -eq 0) 'Closed client opens without touching the service'}
        if($fault -eq 'backend'){Assert-Worker ($m.Stops -eq 1 -and $m.Starts -eq 1) 'Backend recovery separately authorizes stop and start'}
    }
    $m=New-Machine (New-WorkerRoot 'three-actions') 'backend';$m.CloseClientAfterStart=$true;Prime-Worker $m;$r=Run-Worker $m
    Assert-Worker ($r.recoveryConfirmed -and $r.actionsCompleted -eq 3 -and $m.Opens -eq 1) 'Backend recovery can reopen the client within the three-action limit'
    foreach($mode in @('action_false','throw','unknown_after')){
        $m=New-Machine (New-WorkerRoot $mode) 'service';Prime-Worker $m;$m.Mode=$mode;$r=Run-Worker $m
        Assert-Worker (-not $r.recoveryConfirmed -and $r.lastRepairUtc -eq '' -and $r.status -eq 'manual') "$mode never reports successful recovery"
        $stored=[IO.File]::ReadAllText((Join-Path $m.Root 'auto-repair-state.json'))
        Assert-Worker (-not $stored.Contains('fixture-private-text')) "$mode does not persist raw exception text"
        $m.Mode='normal';$m.Health.Service='Stopped';$m.Health.Backend='Unknown';$m.Now=$m.Now.AddSeconds(1);$r=Run-Worker $m
        Assert-Worker ($r.status -eq 'cooldown') "$mode consumes its reservation instead of immediately retrying"
    }
    foreach($mode in @('disable_before','intent_before','environment_before','replace_owner','corrupt_record')){
        $m=New-Machine (New-WorkerRoot $mode) 'service';Prime-Worker $m;$m.Mode=$mode;$r=Run-Worker $m
        Assert-Worker ($m.Starts+$m.Opens+$m.Stops -eq 0 -and -not $r.recoveryConfirmed) "$mode at the final action boundary prevents mutation"
        if($mode -eq 'replace_owner'){
            Assert-Worker ((Test-Path (Join-Path $m.Root 'operation.lock')) -and $r.reason -eq 'ownership_changed') 'Lost lease does not delete or reclaim the replacement marker'
        }
        if($mode -eq 'corrupt_record'){
            Assert-Worker ([IO.File]::ReadAllText((Join-Path $m.Root 'auto-repair-state.json')) -ceq '{fixture-damage') 'Last-moment damaged result is preserved instead of forced through'
        }
    }
    foreach($mode in @('disable_after_stop','environment_after_stop')){
        $m=New-Machine (New-WorkerRoot $mode) 'backend';Prime-Worker $m;$m.Mode=$mode;$r=Run-Worker $m
        Assert-Worker ($m.Stops -eq 1 -and $m.Starts -eq 0 -and -not $r.recoveryConfirmed -and $r.actionsCompleted -eq 1) "$mode preserves the partial action without unauthorized restart"
        $record=[Tqr.AutoRepairRecords]::Current($m.Root)
        Assert-Worker ($record.phase -eq 'Complete' -and -not $record.recoveryConfirmed) "$mode records truthful cancellation rather than leaving a successful result"
    }
    foreach($kind in @('repair','setup','update','diagnostics','integrity','maintenance')){
        $path=New-WorkerRoot ('busy-'+$kind);$lease=[Tqr.OperationGate]::TryAcquire($path,$kind);$hash=(Get-FileHash (Join-Path $path 'operation.lock')).Hash
        try{
            $m=New-Machine $path 'service';$r=Run-Worker $m
            Assert-Worker ($r.status -eq 'busy' -and $m.Observations -eq 0 -and $lease.IsCurrent -and (Get-FileHash (Join-Path $path 'operation.lock')).Hash -eq $hash) "Existing $kind owner is preserved without observations or dispatch"
        }finally{$lease.Dispose()}
    }
    foreach($fault in @('damaged','oversized','locked','missing-primary')){
        $m=New-Machine (New-WorkerRoot ('record-'+$fault)) 'service';Prime-Worker $m
        $path=Join-Path $m.Root 'auto-repair-state.json';$hold=$null
        switch($fault){
            'damaged' {[IO.File]::WriteAllText($path,'{broken')}
            'oversized' {[IO.File]::WriteAllText($path,('x'*8193))}
            'locked' {$hold=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
            'missing-primary' {Copy-Item $path (Join-Path $m.Root 'auto-repair-state.previous.json');[IO.File]::Move($path,($path+'.fixture-removed'))}
        }
        try{$r=Run-Worker $m;Assert-Worker (-not $r.recoveryConfirmed -and $m.Starts -eq 0) "$fault result evidence prevents automatic actions"}finally{if($hold){$hold.Dispose()}}
        if($fault -eq 'damaged'){Assert-Worker ([IO.File]::ReadAllText($path) -ceq '{broken') 'Damaged result bytes remain unchanged'}
        if($fault -eq 'oversized'){Assert-Worker ((Get-Item $path).Length -eq 8193) 'Oversized result bytes remain unchanged'}
        if($fault -eq 'missing-primary'){Assert-Worker (-not(Test-Path $path)) 'Missing primary is not silently regenerated over surviving evidence'}
    }
    $m=New-Machine (New-WorkerRoot 'legacy') 'service';$legacy=Join-Path $m.Root 'auto-repair-state.json'
    Put-Json $legacy @{lastCheckedUtc=$m.Now.ToString('o');status='repaired';message='fixture-private-text';service='Stopped';client='Running';backend='Unknown';lastRepairUtc=$m.Now.AddMinutes(-1).ToString('o');lastRepairReason='fixture-private-text';cooldownRemainingMinutes=14}
    $r=Run-Worker $m
    Assert-Worker ($r.status -eq 'cooldown' -and $r.cooldownRemainingMinutes -eq 14 -and $m.Starts -eq 0 -and -not $r.recoveryConfirmed) 'Protected migration preserves the legacy cooldown without claiming recovery'
    $r=Run-Worker $m
    Assert-Worker ($r.status -eq 'cooldown' -and -not ([IO.File]::ReadAllText((Join-Path $m.Root 'auto-repair-policy.json'))).Contains('fixture-private')) 'Migrated budget survives later calls without copying legacy raw text'

    # Execute the actual delivered PowerShell monitor in an isolated child. Only
    # New-Object at the production OS boundary returns the harmless native fixture.
    $entryParent=Join-Path $root 'entry-user';$entryRoot=Join-Path $entryParent 'TailscaleQuickRepair'
    New-Item -ItemType Directory -Path $entryRoot -Force|Out-Null
    Put-Json (Join-Path $entryRoot 'auto-repair.json') @{enabled=$true}
    $harness=Join-Path $root 'entry.ps1'
    @'
param([string]$Monitor,[string]$Fixture,[string]$Library,[string]$UserRoot)
$ErrorActionPreference='Stop'
$env:LOCALAPPDATA=$UserRoot
Add-Type -Path $Library
Add-Type -Path $Fixture
function New-Object {
    param([string]$TypeName)
    if($TypeName -cne 'Tqr.WindowsAutoRepairMachine'){throw 'Unexpected fixture boundary.'}
    $m=[TqrWorkerFixture.Machine]::new();$m.Root=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair';return $m
}
. $Monitor
'@|Set-Content $harness -Encoding UTF8
    $args='-NoProfile -NonInteractive -File "'+$harness+'" -Monitor "'+$monitor+'" -Fixture "'+$fixtureDll+'" -Library "'+$dll+'" -UserRoot "'+$entryParent+'"'
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.Arguments=$args;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($psi);$children.Add($p)
    Assert-Worker ($p.WaitForExit(15000) -and $p.ExitCode -eq 0) 'Actual packaged monitor entry executes the native worker with only the OS boundary substituted'
    $entry=[Tqr.AutoRepairRecords]::Current($entryRoot)
    Assert-Worker ($entry.status -eq 'healthy' -and -not $entry.recoveryConfirmed -and $entry.actionsAttempted -eq 0) 'Delivered entry publishes typed local observation rather than dispatching the general repair task'

    # A real process holds the actual lease while paused immediately before its
    # harmless action. Other processes cannot collide; killing it leaves cooldown.
    $cross=New-Machine (New-WorkerRoot 'cross-process') 'service';Prime-Worker $cross
    $childScript=Join-Path $root 'hold-worker.ps1'
    @'
param([string]$Library,[string]$Fixture,[string]$Root,[string]$Stamp)
$ErrorActionPreference='Stop';Add-Type -Path $Library;Add-Type -Path $Fixture
$m=[TqrWorkerFixture.Machine]::new();$m.Root=$Root;$m.Mode='wait_before';$m.Health.Service='Stopped';$m.Health.Backend='Unknown'
$m.Now=[DateTime]::Parse($Stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
[void][Tqr.AutoRepairWorker]::Execute($Root,$m)
'@|Set-Content $childScript -Encoding UTF8
    $psi.Arguments='-NoProfile -NonInteractive -File "'+$childScript+'" -Library "'+$dll+'" -Fixture "'+$fixtureDll+'" -Root "'+$cross.Root+'" -Stamp "'+$cross.Now.ToString('o')+'"'
    $child=[Diagnostics.Process]::Start($psi);$children.Add($child)
    $until=[DateTime]::UtcNow.AddSeconds(10);$ready=Join-Path $cross.Root 'fixture-ready'
    while(-not(Test-Path $ready) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 20}
    Assert-Worker (Test-Path $ready) 'Real protected-worker fixture reaches its final action boundary while owning the lease'
    $blocked=Run-Worker $cross
    Assert-Worker ($blocked.status -eq 'busy' -and $cross.Starts -eq 0) 'Second process cannot begin an overlapping automatic operation'
    $child.Kill();[void]$child.WaitForExit(5000);$cross.Now=$cross.Now.AddSeconds(1);$after=Run-Worker $cross
    Assert-Worker ($after.status -eq 'cooldown' -and $cross.Starts -eq 0 -and (Test-Path (Join-Path $cross.Root 'operation-recovery.json'))) 'Killed integrated worker preserves its reservation and records actual lease recovery'

    # Real final WPF event handlers and preference code; scheduler is a harmless
    # native COM-shaped fixture. No production task is created or run by CI.
    $uiPath=Join-Path $ordinary 'app\Tailscale-Repair-UI.ps1';$ui=[IO.File]::ReadAllText($uiPath)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$tokens,[ref]$errors)
    Assert-Worker ($errors.Count -eq 0) 'Integrated final packaged UI parses on Windows PowerShell 5.1'
    foreach($name in @('Get-AutoRepairEnabled','Set-AutoRepairEnabled','Invoke-AutoRepairMonitorNow','Update-AutoRepairStatus')){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        Assert-Worker ($nodes.Count -eq 1) "Final UI has exactly one $name implementation"
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    function Initialize-OperationGate {}
    function Refresh-AutoRepairAvailability {param([switch]$Force) return $true}
    function Initialize-AutoRepairLocalWatch {}
    function Get-ActiveOperation {return [Tqr.OperationGate]::Inspect($StateDir)}
    function Get-Brush([string]$Name){return [Windows.Media.Brushes]::Gray}
    $xml=[regex]::Match($ui,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@').Groups['xaml'].Value
    $reader=New-Object Xml.XmlNodeReader ([xml]$xml);$window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
    foreach($name in @('AutoRepairCheckBox','AutoRepairCheckNowButton','AutoRepairStatusText','AutoRepairLastRepairText','AutoRepairTriggerText')){Set-Variable -Name $name -Value $window.FindName($name)}
    $StateDir=New-WorkerRoot 'ui';$AutoRepairTaskName='Tailscale Quick Repair Auto Monitor'
    $oldProgramData=$env:ProgramData;$env:ProgramData=Join-Path $root 'fixture-program-data'
    $launcher=Join-Path $env:ProgramData 'TailscaleQuickRepair\Launch-Auto-Repair-Monitor.vbs'
    New-Item -ItemType Directory -Path (Split-Path $launcher) -Force|Out-Null;[IO.File]::WriteAllText($launcher,'fixture-only')
    $script:fixtureScheduler=[TqrWorkerFixture.Scheduler]::new();$task=$script:fixtureScheduler.Folder.Task
    $task.Definition.Principal.UserId=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $task.Definition.Actions.Action.Path=Join-Path $env:SystemRoot 'System32\wscript.exe'
    $task.Definition.Actions.Action.Arguments='"'+$launcher+'"';$task.Definition.Actions.Action.WorkingDirectory=Split-Path $launcher
    function New-Object {
        param([string]$TypeName,[string]$ComObject)
        if($ComObject -eq 'Schedule.Service'){return $script:fixtureScheduler}
        throw 'Unexpected object creation in the final dispatch fixture.'
    }
    try{
        Assert-Worker (Invoke-AutoRepairMonitorNow) 'Final UI dispatch accepts the exact protected monitor task and current user identity'
        Assert-Worker ($task.Runs -eq 1) 'Accepted UI request dispatches only one protected monitor task'
        $original=$task.Definition.Actions.Action.Arguments;$task.Definition.Actions.Action.Arguments='unexpected'
        Assert-Worker (-not(Invoke-AutoRepairMonitorNow) -and $task.Runs -eq 1) 'Wrong task command cannot be used as a protected dispatch route'
        $task.Definition.Actions.Action.Arguments=$original;$task.Definition.Principal.UserId='S-1-5-18'
        Assert-Worker (-not(Invoke-AutoRepairMonitorNow) -and $task.Runs -eq 1) 'Task registered to another identity is refused without a UAC fallback'
        $task.Definition.Principal.UserId=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $task.Definition.Principal.RunLevel=0
        Assert-Worker (-not(Invoke-AutoRepairMonitorNow)) 'Unprotected task registration is not accepted as the protected worker'
        $task.Definition.Principal.RunLevel=1
        $AutoRepairCheckBox.IsChecked=$false;$AutoRepairCheckNowButton.IsEnabled=$true;$script:repairActive=$false
        $click=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -ceq '$AutoRepairCheckNowButton' -and $n.Member.Value -eq 'Add_Click'},$true))
        Assert-Worker ($click.Count -eq 1) 'Exactly one actual packaged check-local-health WPF event'
        $clickBody=$click[0].Arguments[0].ScriptBlock.Extent.Text
        Assert-Worker ($clickBody.Contains('Invoke-PassiveStartupHealth -Refresh') -and
            -not $clickBody.Contains('Invoke-AutoRepairMonitorNow') -and
            -not $clickBody.Contains('AutoRepairCheckBox.IsChecked')) 'Packaged check-local-health click is read-only and independent of Automatic Repair'
        $script:manualRefreshCalls=0;$script:manualRefreshWasRefresh=$false
        function Invoke-PassiveStartupHealth {
            param([switch]$Refresh)
            $script:manualRefreshCalls++
            $script:manualRefreshWasRefresh=[bool]$Refresh
        }
        $AutoRepairCheckNowButton.Add_Click($click[0].Arguments[0].ScriptBlock.GetScriptBlock())
        $AutoRepairCheckNowButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Worker ($script:manualRefreshCalls -eq 1 -and $script:manualRefreshWasRefresh -and $task.Runs -eq 1) 'Actual packaged WPF check action requests one read-only local refresh without dispatching Auto Repair'
        $task.Definition.Actions.Action.Arguments='unexpected'
        $AutoRepairCheckNowButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Worker ($script:manualRefreshCalls -eq 2 -and $task.Runs -eq 1) 'Manual local refresh remains separate from a refused or broken scheduler route'
        $task.Definition.Actions.Action.Arguments=$original
        Assert-Worker (Set-AutoRepairEnabled $false) 'Native preference writer saves explicit opt-out'
        Assert-Worker (-not(Get-AutoRepairEnabled) -and -not(Invoke-AutoRepairMonitorNow)) 'Opt-out prevents the final UI scheduler call'
        [IO.File]::WriteAllText((Join-Path $StateDir 'auto-repair.json'),'{broken')
        Assert-Worker (-not(Get-AutoRepairEnabled) -and -not(Set-AutoRepairEnabled $true)) 'Malformed settings cannot opt in or be replaced by the UI'
        Assert-Worker ([IO.File]::ReadAllText((Join-Path $StateDir 'auto-repair.json')) -ceq '{broken') 'UI leaves malformed preference evidence intact'
        Update-AutoRepairStatus
        Assert-Worker ($AutoRepairStatusText.Text -eq 'Settings unavailable - nothing changed') 'UI does not mislabel unreadable preferences as Off'
    }finally{$env:ProgramData=$oldProgramData;Remove-Item Function:New-Object;$window.Close()}
    $passed=$true
}finally{
    foreach($p in $children){try{if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(1000)}}catch{};try{$p.Dispose()}catch{}}
    [pscustomobject]@{passed=$passed;scope='Final packaged worker, real coordinator, native child processes and WPF routes; OS mutations and scheduler are harmless fixtures';cases=@($script:workerCases.ToArray());limits=@('No real Tailscale service or VPN is altered','No elevated Setup or alternate-user login acceptance','No whole-PC power-loss guarantee','Event/background History coverage remains separate') }|ConvertTo-Json -Depth 10|Set-Content (Join-Path $evidence 'auto-repair-worker-results.json') -Encoding UTF8
    # Keep exact synthetic evidence on the disposable runner; never clean up a
    # user baseline, marker, service or installed application to obtain a pass.
}