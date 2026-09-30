param([Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$EvidenceDirectory='.\test-evidence')
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Native Windows PowerShell 5.1 required.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Web.Extensions
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$root=Join-Path $env:TEMP ('TQR-Background-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$cases=New-Object 'Collections.Generic.List[object]';$passed=$false
$scheduler=$null;$testFolder=$null;$registered=$null;$folderName='';$child=$null
$fixtureTaskNames=New-Object 'Collections.Generic.List[string]'
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw "FAILED background: $Name"}
    Write-Host "PASS background: $Name"
}
function JsonWrite([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($false)))}
function NewRoot([string]$Name){$p=Join-Path $root $Name;New-Item -ItemType Directory -Path $p|Out-Null;JsonWrite (Join-Path $p 'auto-repair.json') @{enabled=$true};return $p}
function ReadCodes([string]$Path){return @([Tqr.LocalHistory]::Read($Path).Entries|ForEach-Object code)}
try {
    $zip=@(Get-ChildItem $OutputDirectory -Filter '*SetupPackage-*.zip');Check ($zip.Count -eq 1) 'One exact protected development package'
    $package=Join-Path $root 'package';Expand-Archive $zip[0].FullName $package
    $dll=Join-Path $package 'program\TailscaleQuickRepair.Operations.dll'
    Add-Type -Path $dll
    $loaded=[IO.Path]::GetFullPath([Tqr.AutoRepairBackground].Assembly.Location)
    $expectedDll=[IO.Path]::GetFullPath($dll)
    Check ($loaded -ieq $expectedDll) 'Background tests load the actual protected package assembly'
    Check ((Get-FileHash $loaded).Hash -eq (Get-FileHash $expectedDll).Hash) 'Loaded assembly bytes match the exact protected package'
    # A native machine fixture executes every real worker/policy/history boundary.
    $code=@'
using System;
using System.Diagnostics;
using System.IO;
using Tqr;
namespace BackgroundFixture {
public class Machine : IAutoRepairMachine {
    public DateTime Now=DateTime.UtcNow.AddMinutes(-3);
    public string Root;
    public int Reads,Starts,Stops,Opens;
    public bool DisableAfterStop,Incomplete;
    public AutoHealth H=new AutoHealth {Service="Running",Client="Running",Backend="Running",Startup="Automatic"};
    public DateTime UtcNow {get{return Now;}}
    public bool CanContinue {get{return true;}}
    public bool CanMutate {get{return true;}}
    public AutoHealth Observe(){Reads++;return H;}
    public bool OpenClient(Action authorize){authorize();Opens++;H.Client="Running";return true;}
    public bool StartService(Action authorize){authorize();Starts++;H.Service="Running";H.Backend=Incomplete?"Unknown":"Running";return true;}
    public bool StopService(Action authorize){authorize();Stops++;H.Service="Stopped";H.Backend="Unknown";
        if(DisableAfterStop)File.WriteAllText(Path.Combine(Root,"auto-repair.json"),"{\"enabled\":false}");return true;}
    public void Pause(){Now=Now.AddMilliseconds(500);}
}
public class Clock {public long ElapsedMilliseconds;}
public class NotificationSettings {public string Status="ready";public bool Enabled=true;}
public class NotificationCenter {public NotificationSettings State=new NotificationSettings();public NotificationSettings Settings(){return State;}}
}
'@
    $source=Join-Path $root 'fixture.cs';[IO.File]::WriteAllText($source,$code)
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $fixture=Join-Path $root 'BackgroundFixture.dll'
    & $compiler /nologo /target:library ('/reference:'+$dll) ('/out:'+$fixture) $source
    Check ($LASTEXITCODE -eq 0) 'Native machine and monotonic-clock fixtures compile against the final package'
    Add-Type -Path $fixture
    function Machine([string]$Path,[string]$Fault='healthy'){
        $m=New-Object BackgroundFixture.Machine;$m.Root=$Path
        if($Fault -eq 'service'){$m.H.Service='Stopped';$m.H.Backend='Unknown'}
        if($Fault -eq 'backend'){$m.H.Backend='Starting'}
        if($Fault -eq 'client'){$m.H.Client='Closed'}
        return $m
    }
    function Run($m){return [Tqr.AutoRepairWorker]::ExecuteScheduled($m.Root,$m)}
    foreach($fault in @('service','backend','client')){
        $m=Machine (NewRoot $fault) $fault
        $a=Run $m;Check ((ReadCodes $m.Root).Count -eq 0) "$fault initial fault observation does not invent a repair history entry"
        $reads=$m.Reads;$m.Now=$m.Now.AddSeconds(20);$b=Run $m
        Check ($b.runId -eq $a.runId -and $m.Reads -eq $reads) "$fault event burst reuses evidence without another local CLI observation"
        $m.Now=$m.Now.AddSeconds(45);$b=Run $m
        Check ($b.recoveryConfirmed -and $b.schema -eq 3) "$fault scheduled follow-up confirms actual local recovery"
        $codes=ReadCodes $m.Root
        $expected=switch($fault){'service'{3};'backend'{4};'client'{3}}
        Check ($codes.Count -eq $expected -and $codes -contains 'auto_attempt' -and $codes -contains 'auto_recovered') "$fault history persists reservation actions and confirmed outcome with no UI running"
        Check (($codes -contains 'auto_service_started') -eq ($fault -ne 'client')) "$fault history identifies service starts without guessing from a success status"
        Check (($codes -contains 'auto_service_stopped') -eq ($fault -eq 'backend')) "$fault history identifies only completed service stops"
        Check (($codes -contains 'auto_client_opened') -eq ($fault -eq 'client')) "$fault history identifies only completed client opens"
        $hash=(Get-FileHash (Join-Path $m.Root 'health-history.json')).Hash
        for($i=0;$i -lt 5;$i++){[void][Tqr.AutoRepairBackground]::Reconcile($m.Root,$false)}
        Check ((Get-FileHash (Join-Path $m.Root 'health-history.json')).Hash -eq $hash) "$fault repeated reconciliation is idempotent and does not rewrite History"
        $m.Now=$m.Now.AddMinutes(1);[void](Run $m)
        Check ((ReadCodes $m.Root).Count -eq $expected) "$fault later routine healthy checks do not produce background history spam"
    }
    $m=Machine (NewRoot 'cancelled') 'backend';$m.DisableAfterStop=$true
    [void](Run $m);$m.Now=$m.Now.AddSeconds(65);$r=Run $m;$codes=ReadCodes $m.Root
    Check ($r.actionsCompleted -eq 1 -and $codes -contains 'auto_service_stopped' -and $codes -notcontains 'auto_service_started') 'Opt-out between stop/start records the completed stop only'
    Check ($codes -contains 'auto_unconfirmed' -and $codes -notcontains 'auto_recovered') 'Partial cancelled recovery never becomes a successful history outcome'
    $m=Machine (NewRoot 'locked-history') 'service'
    $history=Join-Path $m.Root 'health-history.json'
    [void][Tqr.LocalHistory]::Record($m.Root,'check_healthy',-1,-1)
    $saved=[IO.File]::ReadAllBytes($history);$hold=[IO.File]::Open($history,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{[void](Run $m);$m.Now=$m.Now.AddSeconds(65);$r=Run $m;Check $r.recoveryConfirmed 'Locked secondary History cannot fail the real worker outcome'}finally{$hold.Dispose()}
    Check ([Tqr.AutoRepairBackground]::Reconcile($m.Root,$false)) 'Reopening can reconcile the bounded saved outcome after History unlocks'
    Check ((ReadCodes $m.Root) -contains 'auto_recovered') 'Reconciled recovery survives absence of the UI during the repair'
    $saved=[IO.File]::ReadAllBytes($history);[IO.File]::WriteAllText($history,'{damaged')
    Check (-not [Tqr.AutoRepairBackground]::Reconcile($m.Root,$false) -and [IO.File]::ReadAllText($history) -ceq '{damaged') 'Damaged History is preserved instead of silently reset during reconciliation'
    [IO.File]::WriteAllBytes($history,$saved)
    $prev=Join-Path $m.Root 'health-history.previous.json';$prevSaved=[IO.File]::ReadAllBytes($prev);[IO.File]::WriteAllText($prev,'{damaged-predecessor')
    Check (-not [Tqr.LocalHistory]::Record($m.Root,'update_installed',-1,-1) -and [IO.File]::ReadAllText($prev) -ceq '{damaged-predecessor') 'Damaged History predecessor is not overwritten by a new background or UI event'
    [IO.File]::WriteAllBytes($prev,$prevSaved)
    # Validate schema-2 compatibility and refuse fabricated new completed actions.
    $copyRoot=NewRoot 'schema-compatibility';$old=Get-Content (Join-Path $m.Root 'auto-repair-state.json') -Raw|ConvertFrom-Json
    $old.schema=2
    foreach($name in @('reservedUtc','action1','action2','action3','action1Utc','action2Utc','action3Utc')){$old.PSObject.Properties.Remove($name)}
    JsonWrite (Join-Path $copyRoot 'auto-repair-state.json') $old
    Check ($null -ne [Tqr.AutoRepairRecords]::Current($copyRoot)) 'Older development schema-2 snapshots remain readable without inferred action names'
    Check ([Tqr.AutoRepairBackground]::Reconcile($copyRoot,$false) -and (ReadCodes $copyRoot).Count -eq 0) 'Schema-2 action counts do not manufacture exact-action history'
    $badRoot=NewRoot 'bad-action';$new=Get-Content (Join-Path $m.Root 'auto-repair-state.json') -Raw|ConvertFrom-Json
    $new.action1='injected-private-string';JsonWrite (Join-Path $badRoot 'auto-repair-state.json') $new
    Check ($null -eq [Tqr.AutoRepairRecords]::Current($badRoot) -and -not [Tqr.AutoRepairBackground]::Reconcile($badRoot,$false)) 'Arbitrary action strings cannot cross the typed record and History boundary'
    # An abandoned snapshot is not a confirmed completed repair.
    $interrupted=NewRoot 'interrupted';$r=New-Object Tqr.AutoRepairResult
    $r.runId=[Guid]::NewGuid().ToString('N');$r.lastCheckedUtc=[DateTime]::UtcNow.AddSeconds(-40).ToString('o');$r.reservedUtc=$r.lastCheckedUtc
    $r.phase='Reserved';$r.reason='service_stopped'
    [Tqr.AutoRepairRecords]::Save($interrupted,$r)
    [void][Tqr.AutoRepairBackground]::Reconcile($interrupted,$false)
    Check ((ReadCodes $interrupted) -notcontains 'auto_interrupted') 'UI read alone cannot label pending work as interrupted'
    Check (-not [Tqr.AutoRepairBackground]::Reconcile($interrupted,$true)) 'Abandoned-outcome reconciliation requires the real operation lease'
    $lease=[Tqr.OperationGate]::TryAcquire($interrupted,'maintenance')
    try{Check ([Tqr.AutoRepairBackground]::Reconcile($interrupted,$true)) 'A new verified owner reconciles an abandoned snapshot'}finally{$lease.Dispose()}
    Check ((ReadCodes $interrupted) -contains 'auto_interrupted' -and (ReadCodes $interrupted) -notcontains 'auto_recovered') 'Missing completion is reported as unconfirmed, never successful recovery'
    # Retention and event identity stay bounded under mixed UI/background records.
    for($i=0;$i -lt 50;$i++){[void][Tqr.LocalHistory]::Record($m.Root, $(if($i%2){'route_direct'}else{'route_relay'}),-1,-1)}
    $before=(Get-FileHash $history).Hash;[void][Tqr.AutoRepairBackground]::Reconcile($m.Root,$false)
    Check ((ReadCodes $m.Root).Count -eq 40 -and (Get-Item $history).Length -lt 32768) 'Background and UI History share the original 40-entry byte bound'
    Check ((Get-FileHash $history).Hash -eq $before) 'Reconciliation does not resurrect events evicted by newer retained activity'

    # Prolonged History unavailability is deliberately bounded rather than
    # pretending to provide a lossless audit journal. Worker/result state keeps
    # only current + previous snapshots, so after three completed outcomes while
    # History is locked, reopening may recover the newest two only. The oldest
    # must never be resurrected later.
    $boundedRoot=NewRoot 'bounded-history-gap'
    $boundedGate=Join-Path $boundedRoot 'health-history.gate'
    $gateSeed=[IO.File]::Open($boundedGate,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite);$gateSeed.Dispose()
    $gateHold=[IO.File]::Open($boundedGate,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        for($i=0;$i -lt 3;$i++){
            $stamp=[DateTime]::UtcNow.AddSeconds(-50+$i*10)
            $done=New-Object Tqr.AutoRepairResult
            $done.runId=[Guid]::NewGuid().ToString('N')
            $done.reservedUtc=$stamp.ToString('o')
            $done.action1='service_started'
            $done.action1Utc=$stamp.AddSeconds(1).ToString('o')
            $done.actionsAttempted=1;$done.actionsCompleted=1
            $done.lastCheckedUtc=$stamp.AddSeconds(2).ToString('o')
            $done.lastRepairUtc=$done.lastCheckedUtc;$done.lastRepairReason='local_recovery'
            $done.status='healthy';$done.reason='local_recovery';$done.phase='Complete'
            $done.service='Running';$done.client='Running';$done.backend='Running';$done.recoveryConfirmed=$true
            [Tqr.AutoRepairRecords]::Save($boundedRoot,$done)
        }
        Check (-not(Test-Path (Join-Path $boundedRoot 'health-history.json'))) 'Three worker outcomes can complete while secondary History remains unavailable'
    } finally { $gateHold.Dispose() }
    Check ([Tqr.AutoRepairBackground]::Reconcile($boundedRoot,$false)) 'History reconciliation resumes after the prolonged store lock is released'
    $boundedCodes=ReadCodes $boundedRoot
    Check ($boundedCodes.Count -eq 6 -and
        @($boundedCodes|Where-Object {$_ -eq 'auto_attempt'}).Count -eq 2 -and
        @($boundedCodes|Where-Object {$_ -eq 'auto_service_started'}).Count -eq 2 -and
        @($boundedCodes|Where-Object {$_ -eq 'auto_recovered'}).Count -eq 2) 'Bounded replay restores only current and previous outcomes after a longer History gap'
    $boundedHash=(Get-FileHash (Join-Path $boundedRoot 'health-history.json')).Hash
    for($i=0;$i -lt 4;$i++){[void][Tqr.AutoRepairBackground]::Reconcile($boundedRoot,$false)}
    Check ((Get-FileHash (Join-Path $boundedRoot 'health-history.json')).Hash -eq $boundedHash -and (ReadCodes $boundedRoot).Count -eq 6) 'Older outcome beyond the replay window never resurrects after later reconciliation'

    # A persistently damaged History file is also secondary. Preserve those exact
    # bytes while multiple worker outcomes advance, then prove repair can resume
    # from the bounded current/previous result snapshots after the known-good
    # History bytes are restored.
    $damagedRoot=NewRoot 'prolonged-damaged-history'
    Check ([Tqr.LocalHistory]::Record($damagedRoot,'check_healthy',-1,-1)) 'Damaged-History fixture starts from one valid typed event'
    $damagedPath=Join-Path $damagedRoot 'health-history.json'
    $damagedGood=[IO.File]::ReadAllBytes($damagedPath)
    [IO.File]::WriteAllText($damagedPath,'{persistently-damaged-history')
    for($i=0;$i -lt 3;$i++){
        $stamp=[DateTime]::UtcNow.AddSeconds(-45+$i*10)
        $done=New-Object Tqr.AutoRepairResult
        $done.runId=[Guid]::NewGuid().ToString('N')
        $done.reservedUtc=$stamp.ToString('o')
        $done.action1='client_opened';$done.action1Utc=$stamp.AddSeconds(1).ToString('o')
        $done.actionsAttempted=1;$done.actionsCompleted=1
        $done.lastCheckedUtc=$stamp.AddSeconds(2).ToString('o')
        $done.lastRepairUtc=$done.lastCheckedUtc;$done.lastRepairReason='local_recovery'
        $done.status='healthy';$done.reason='local_recovery';$done.phase='Complete'
        $done.service='Running';$done.client='Running';$done.backend='Running';$done.recoveryConfirmed=$true
        [Tqr.AutoRepairRecords]::Save($damagedRoot,$done)
        Check ([IO.File]::ReadAllText($damagedPath) -ceq '{persistently-damaged-history') ('Worker outcome '+($i+1)+' preserves the damaged History bytes exactly')
    }
    Check (-not [Tqr.AutoRepairBackground]::Reconcile($damagedRoot,$false) -and
        [IO.File]::ReadAllText($damagedPath) -ceq '{persistently-damaged-history') 'Repeated reconciliation cannot reset or bless persistently damaged History'
    [IO.File]::WriteAllBytes($damagedPath,$damagedGood)
    Check ([Tqr.AutoRepairBackground]::Reconcile($damagedRoot,$false)) 'Restoring known-good History bytes allows bounded background reconciliation to resume'
    $damagedCodes=ReadCodes $damagedRoot
    Check ($damagedCodes.Count -eq 7 -and $damagedCodes[0] -eq 'check_healthy' -and
        @($damagedCodes|Where-Object {$_ -eq 'auto_attempt'}).Count -eq 2 -and
        @($damagedCodes|Where-Object {$_ -eq 'auto_client_opened'}).Count -eq 2 -and
        @($damagedCodes|Where-Object {$_ -eq 'auto_recovered'}).Count -eq 2) 'Recovered damaged History keeps its old valid event and only the newest two background outcomes'

    # Real separate PowerShell process executes the delivered protected entry.
    $entryRoot=NewRoot 'exited-ui';$entryState=Join-Path $entryRoot 'TailscaleQuickRepair';New-Item -ItemType Directory $entryState|Out-Null
    JsonWrite (Join-Path $entryState 'auto-repair.json') @{enabled=$true}
    Copy-Item $dll (Join-Path $entryRoot 'TailscaleQuickRepair.Operations.dll')
    $entryText=[IO.File]::ReadAllText((Join-Path $package 'program\Auto-Repair-Monitor.ps1'))
    $needle='$machine = New-Object Tqr.WindowsAutoRepairMachine'
    Check (($entryText.Split(@($needle),[StringSplitOptions]::None).Length-1) -eq 1) 'Delivered entry has one replaceable OS discovery boundary, not an alternative repair algorithm'
    $replacement='$machine = New-Object BackgroundFixture.Machine; $machine.Root=$root; $machine.H.Service="Stopped"; $machine.H.Backend="Unknown"; $machine.Now=[DateTime]::UtcNow.AddMinutes(-1); [void][Tqr.AutoRepairPolicyStore]::Observe($root,$machine.H,$machine.Now.AddSeconds(-65),$false)'
    $entryText=$entryText.Replace($needle,$replacement)
    $entry=Join-Path $entryRoot 'entry.ps1';[IO.File]::WriteAllText($entry,$entryText)
    $launch=Join-Path $entryRoot 'launch.ps1'
    [IO.File]::WriteAllText($launch,('$env:LOCALAPPDATA="'+$entryRoot+'";Add-Type -Path "'+(Join-Path $entryRoot 'TailscaleQuickRepair.Operations.dll')+'";Add-Type -Path "'+$fixture+'";& "'+$entry+'"'))
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.Arguments='-NoProfile -NonInteractive -File "'+$launch+'"';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $child=[Diagnostics.Process]::Start($psi)
    Check ($child.WaitForExit(15000) -and $child.ExitCode -eq 0) 'Native protected-entry child completes without any resident Quick Repair UI'
    Check ((ReadCodes $entryState) -contains 'auto_service_started' -and (ReadCodes $entryState) -contains 'auto_recovered') 'Separate background process leaves exact-action and outcome History for the next UI session'
    # Monotonic bounded event episodes. No timer manufactures a peer probe.
    $q=New-Object Tqr.AutoRepairEventQueue
    $q.Signal(0,2,$false);Check (-not $q.Pending) 'Opt-out never queues an event episode'
    $q.Signal(0,2,$true);Check (-not $q.Take(9000,$true,$false)) 'Local transition gets a minimum settling interval'
    $q.Signal(9000,10,$true);Check (-not $q.Take(18000,$true,$false)) 'Event bursts coalesce and settle after the latest signal'
    Check ($q.Take(19000,$true,$false)) 'Settled episode permits one local dispatch'
    Check (-not $q.Take(20000,$true,$false)) 'Repeated timer ticks cannot hammer the task scheduler'
    foreach($at in @(30000,45000,60000,75000)){[void]$q.Take($at,$true,$false)}
    Check ($q.Take(79000,$true,$false) -and -not $q.Pending) 'One bounded follow-up permits confirmation then ends the episode'
    $q.Signal(80000,10,$true);$q.Cancel();$q.Signal(81000,10,$true)
    Check (-not $q.Take(92000,$true,$false)) 'Preference toggling retains minimum dispatch spacing'
    $q=New-Object Tqr.AutoRepairEventQueue;$q.Signal(0,10,$true)
    Check (-not $q.Take(10000,$true,$true) -and $q.Pending) 'Busy manual repair retains a bounded pending local check'
    Check ($q.Take(20000,$true,$false)) 'Queued local check can proceed when the real owner finishes'
    $q=New-Object Tqr.AutoRepairEventQueue;$q.Signal(0,10,$true);[void]$q.Take(1000,$true,$false)
    Check (-not $q.Take(40000,$true,$false)) 'A long dispatcher pause defers rather than immediately replaying a stale trigger'
    Check (-not $q.Take(130000,$true,$false) -and -not $q.Pending) 'Expired event episode is dropped in favour of the five-minute fallback'
    $q.Signal(140000,10,$true);Check (-not $q.Take(139000,$false,$false) -and -not $q.Pending) 'Opt-out clears an existing event episode'
    # Load actual final WPF functions and exercise the registered native timer.
    $ui=[IO.File]::ReadAllText((Join-Path $package 'app\Tailscale-Repair-UI.ps1'))
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Final background-enabled UI parses on native PowerShell'
    foreach($name in @('Test-AutoRepairSmartEnabled','Queue-AutoRepairSmartCheck','Invoke-AutoRepairEventTick','Update-LocalHistoryView','Initialize-LocalHistory','Observe-SmartAutoNotification','Get-AutoRepairEnabled')){
        $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Check ($nodes.Count -eq 1) "One actual packaged $name function after all transforms"
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    function Initialize-OperationGate{}
    function Get-ActiveOperation{return $null}
    function Get-Brush([string]$Name){return [Windows.Media.Brushes]::Gray}
    function Invoke-AutoRepairMonitorNow{$script:dispatches++;return $true}
    $StateDir=$entryState;$OperationsLibraryPath=$dll;$script:autoRepairAvailable=$true;$script:allowFullExit=$false;$global:TqrUiShutdownRequested=$false;$script:repairActive=$false
    $script:autoEventClock=New-Object BackgroundFixture.Clock;$script:autoEventQueue=New-Object Tqr.AutoRepairEventQueue;$script:dispatches=0
    $AutoRepairStatusText=New-Object Windows.Controls.TextBlock;$HistoryText=New-Object Windows.Controls.TextBlock
    Queue-AutoRepairSmartCheck -Reason 'Synthetic network transition' -DelaySeconds 10
    $script:autoEventClock.ElapsedMilliseconds=10000
    $frame=New-Object Windows.Threading.DispatcherFrame;$endTimer=New-Object Windows.Threading.DispatcherTimer
    $endTimer.Interval=[TimeSpan]::FromMilliseconds(1300);$endTimer.Add_Tick({$frame.Continue=$false;$endTimer.Stop()});$endTimer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
    Check ($script:dispatches -eq 1 -and $AutoRepairStatusText.Text -eq 'Local check requested') 'Actual final native WPF timer dispatches only the local monitor route'
    function Invoke-AutoRepairMonitorNow{$script:dispatches++;return $false}
    $script:autoEventQueue=New-Object Tqr.AutoRepairEventQueue
    Queue-AutoRepairSmartCheck -Reason 'Synthetic refused local check' -DelaySeconds 10
    $script:autoEventClock.ElapsedMilliseconds+=10000
    Invoke-AutoRepairEventTick
    Check ($script:dispatches -eq 2 -and $AutoRepairStatusText.Text -eq 'Could not start local check') 'Actual final event route reports a refused scheduler launch instead of claiming a request started'
    $script:autoEventQueue.Cancel();Invoke-AutoRepairEventTick
    JsonWrite (Join-Path $StateDir 'auto-repair.json') @{enabled=$false}
    Invoke-AutoRepairEventTick
    Check (-not $script:autoRepairTriggerTimer.IsEnabled -and -not $script:autoEventQueue.Pending -and $script:dispatches -eq 2) 'Disabling during a queued follow-up stops the real timer without another dispatch'
    Update-LocalHistoryView
    Check ($HistoryText.Text.Contains('Automatic repair started the Tailscale service') -and $HistoryText.Text.Contains('Automatic local recovery confirmed')) 'Next UI session renders the background actions in the existing History column'
    $originalResult=[IO.File]::ReadAllBytes((Join-Path $StateDir 'auto-repair-state.json'))
    [IO.File]::WriteAllText((Join-Path $StateDir 'auto-repair-state.json'),'{unreadable')
    Update-LocalHistoryView
    Check ($HistoryText.Text.Contains('Background activity could not be reconciled.')) 'Unavailable background evidence is distinguished from a failed History write'
    [IO.File]::WriteAllBytes((Join-Path $StateDir 'auto-repair-state.json'),$originalResult)
    Update-LocalHistoryView
    Check (-not $HistoryText.Text.Contains('Background activity could not be reconciled.')) 'Reconciliation warning clears after evidence becomes readable without a new repair'
    # Exercise the actual packaged notification adapter with new-schema snapshots.
    # Its sink is harmless; global rate/shell gates remain in the unchanged suite.
    function Request-SmartNotification {param([string]$Code,[string]$Stamp) $script:notificationCalls.Add($Code);return $true}
    $script:notificationCalls=New-Object 'Collections.Generic.List[string]'
    $script:notificationCenter=New-Object BackgroundFixture.NotificationCenter
    $AutoRepairStatePath=Join-Path $StateDir 'auto-repair-state.json'
    JsonWrite (Join-Path $StateDir 'auto-repair.json') @{enabled=$true}
    $script:notificationStartedUtc=[DateTime]::UtcNow
    Observe-SmartAutoNotification
    Check ($script:notificationCalls.Count -eq 0) 'A new UI session does not replay notifications from already completed background recovery'
    $script:notificationStartedUtc=[DateTime]::UtcNow.AddMinutes(-5)
    Observe-SmartAutoNotification
    Check ($script:notificationCalls.Count -eq 1 -and $script:notificationCalls[0] -eq 'auto_recovered') 'A fresh observed schema-3 recovery requests one generic recovery notification'
    Observe-SmartAutoNotification
    Check ($script:notificationCalls.Count -eq 1) 'Repeated local-state ticks cannot announce the same recovery twice'
    $r=[Tqr.AutoRepairRecords]::Current($StateDir)
    $r.recoveryConfirmed=$false;$r.lastRepairUtc='';$r.lastRepairReason='';$r.status='healthy';$r.reason='local_running'
    [Tqr.AutoRepairRecords]::Save($StateDir,$r)
    Observe-SmartAutoNotification
    Check ($script:notificationCalls.Count -eq 1) 'Healthy observation without recovery confirmation does not announce repair success'
    [IO.File]::WriteAllBytes($AutoRepairStatePath,$originalResult)
    $script:notificationLastRecovery='';$script:notificationCenter.State.Enabled=$false
    Observe-SmartAutoNotification
    Check ($script:notificationCalls.Count -eq 1) 'Opt-out suppresses new-schema recovery notifications'
    $script:notificationCenter.State.Enabled=$true
    $invalid=Get-Content $AutoRepairStatePath -Raw|ConvertFrom-Json;$invalid.recoveryConfirmed='true'
    JsonWrite $AutoRepairStatePath $invalid
    Observe-SmartAutoNotification
    Check ($script:notificationCalls.Count -eq 1) 'A string recovery flag cannot bypass the typed result reader into notifications'
    [IO.File]::WriteAllBytes($AutoRepairStatePath,$originalResult)
    # Invoke the actual packaged Setup schedule builder on a real COM task.
    $setupAssembly=[Reflection.Assembly]::LoadFile((Join-Path $package 'app\TailscaleQuickRepairSetup.exe'))
    $method=$setupAssembly.GetType('PublicSetupHost').GetMethod('ConfigureAutoMonitorSchedule',[Reflection.BindingFlags]'NonPublic,Static')
    Check ($null -ne $method) 'Native Setup exposes one internal schedule-construction boundary for testing'
    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$definition=$scheduler.NewTask(0)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [void]$method.Invoke($null,@($definition,[DateTime]::Now,$sid))
    [xml]$xml=$definition.XmlText;$ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    Check ($xml.SelectNodes('//t:Triggers/*',$ns).Count -eq 4) 'Actual Setup constructs fallback, user-logon, system and network event triggers'
    Check ($xml.SelectSingleNode('//t:TimeTrigger/t:Repetition/t:Interval',$ns).InnerText -eq 'PT5M' -and $null -eq $xml.SelectSingleNode('//t:TimeTrigger/t:Repetition/t:Duration',$ns)) 'Five-minute fallback has no finite expiry'
    Check ($xml.SelectSingleNode('//t:LogonTrigger/t:UserId',$ns).InnerText -eq $sid -and $xml.SelectSingleNode('//t:LogonTrigger/t:Delay',$ns).InnerText -eq 'PT30S') 'Logon check is scoped to the installed user and delayed for settling'
    Check (@($xml.SelectNodes('//t:EventTrigger/t:Delay',$ns)|Where-Object InnerText -ne 'PT30S').Count -eq 0) 'OS event checks wait thirty seconds rather than mutating immediately'
    Check (@($xml.SelectNodes('//t:EventTrigger/t:Repetition/t:Duration',$ns)|Where-Object InnerText -ne 'PT2M').Count -eq 0) 'Event follow-up repetition is bounded independently of the five-minute fallback'
    Check (-not $definition.Settings.WakeToRun -and -not $definition.Settings.StartWhenAvailable -and -not $definition.Settings.RunOnlyIfNetworkAvailable) 'Fallback does not wake the PC, require a remote-network condition or replay a missed time occurrence'
    # Register only uniquely named harmless test tasks. Production task names,
    # event channels and services are never changed in this acceptance fixture.
    $folderName='TqrFixture-'+[Guid]::NewGuid().ToString('N');$testFolder=$scheduler.GetFolder('\').CreateFolder($folderName,$null)

    # First prove that a time occurrence already missed before registration is
    # NOT replayed. Its next normal PT5M occurrence remains several minutes away.
    $missedTask=$scheduler.NewTask(0);$missedTask.Principal.UserId=$sid;$missedTask.Principal.LogonType=3;$missedTask.Principal.RunLevel=0
    $missedTask.Settings.Enabled=$true;$missedTask.Settings.MultipleInstances=2;$missedTask.Settings.ExecutionTimeLimit='PT1M'
    [void]$method.Invoke($null,@($missedTask,[DateTime]::Now.AddMinutes(-2),$sid))
    for($i=1;$i -le $missedTask.Triggers.Count;$i++){if([int]$missedTask.Triggers.Item($i).Type -ne 1){$missedTask.Triggers.Item($i).Enabled=$false}}
    $missedMarker=Join-Path $root 'missed-fallback-fired';$missedVbs=Join-Path $root 'missed-fallback.vbs'
    [IO.File]::WriteAllText($missedVbs,('Set f=CreateObject("Scripting.FileSystemObject").CreateTextFile("'+$missedMarker+'",True)'+[Environment]::NewLine+'f.Write "fired"'+[Environment]::NewLine+'f.Close'))
    $missedAction=$missedTask.Actions.Create(0);$missedAction.Path=Join-Path $env:WINDIR 'System32\wscript.exe';$missedAction.Arguments='"'+$missedVbs+'"';$missedAction.WorkingDirectory=$root
    $registered=$testFolder.RegisterTaskDefinition('MissedFallback',$missedTask,2,$null,$null,3,$null);$fixtureTaskNames.Add('MissedFallback')
    Check ($null -ne $registered) 'Native Task Scheduler accepts the no-catch-up fallback definition'
    Start-Sleep -Seconds 8
    Check (-not(Test-Path $missedMarker)) 'A missed fallback occurrence is not replayed after registration'
    $registered.Enabled=$false;$testFolder.DeleteTask('MissedFallback',0);[void]$fixtureTaskNames.Remove('MissedFallback')

    # Then prove the same schedule still executes a genuinely future occurrence.
    # ConfigureAutoMonitorSchedule adds one minute, so -45 seconds yields a start
    # boundary about fifteen seconds in the future without changing PT5M.
    $task=$scheduler.NewTask(0);$task.Principal.UserId=$sid;$task.Principal.LogonType=3;$task.Principal.RunLevel=0
    $task.Settings.Enabled=$true;$task.Settings.MultipleInstances=2;$task.Settings.ExecutionTimeLimit='PT1M'
    [void]$method.Invoke($null,@($task,[DateTime]::Now.AddSeconds(-45),$sid))
    for($i=1;$i -le $task.Triggers.Count;$i++){if([int]$task.Triggers.Item($i).Type -ne 1){$task.Triggers.Item($i).Enabled=$false}}
    $marker=Join-Path $root 'fallback-fired';$vbs=Join-Path $root 'fallback.vbs'
    [IO.File]::WriteAllText($vbs,('Set f=CreateObject("Scripting.FileSystemObject").CreateTextFile("'+$marker+'",True)'+[Environment]::NewLine+'f.Write "fired"'+[Environment]::NewLine+'f.Close'))
    $action=$task.Actions.Create(0);$action.Path=Join-Path $env:WINDIR 'System32\wscript.exe';$action.Arguments='"'+$vbs+'"';$action.WorkingDirectory=$root
    $registered=$testFolder.RegisterTaskDefinition('HarmlessFallback',$task,2,$null,$null,3,$null);$fixtureTaskNames.Add('HarmlessFallback')
    Check ($null -ne $registered) 'Native Task Scheduler accepts and registers the exact future fallback construction with a harmless action'
    $limit=[DateTime]::UtcNow.AddSeconds(45)
    while(-not(Test-Path $marker) -and [DateTime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 200}
    Check ((Test-Path $marker) -and (Get-Content $marker -Raw) -eq 'fired') 'A normally scheduled future fallback fires its harmless action with no Quick Repair UI'
    $registered.Enabled=$false;$testFolder.DeleteTask('HarmlessFallback',0);[void]$fixtureTaskNames.Remove('HarmlessFallback')
    $removedFolder=$folderName
    $scheduler.GetFolder('\').DeleteFolder($folderName,0);$folderName=''
    $stillExists=$false
    try{[void]$scheduler.GetFolder('\'+$removedFolder);$stillExists=$true}catch{}
    Check (-not $stillExists) 'Only the dedicated native scheduler fixture is removed after acceptance'
    $passed=$true
}
finally {
    if($script:autoRepairTriggerTimer){$script:autoRepairTriggerTimer.Stop()}
    if($child){try{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(1000)}}catch{};$child.Dispose()}
    if($folderName -and $scheduler){
        foreach($name in @($fixtureTaskNames.ToArray())){try{$testFolder.DeleteTask($name,0)}catch{}}
        try{$scheduler.GetFolder('\').DeleteFolder($folderName,0)}catch{}
    }
    [pscustomobject]@{passed=$passed;scope='Actual packaged background worker History, monotonic event queue, WPF timer and native Setup trigger construction; harmless native fallback task';cases=@($cases.ToArray());limits=@('Service and client actions are fixtures','No real OS sleep, network or service event is deliberately generated','Timer fixture advances initial start time, not the five-minute repetition interval','No elevated Setup, alternate-admin, whole-PC power loss or guaranteed notification delivery claim','Reconciliation is bounded to current and previous worker snapshots, not an unlimited outage journal')}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $evidence 'auto-background-results.json') -Encoding UTF8
}
