param(
    [string]$OutputDirectory,
    [switch]$SourceComponents,
    [string]$EvidenceDirectory='test-evidence'
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Native Windows PowerShell 5.1 required.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$cases=New-Object 'Collections.Generic.List[object]'
$jobs=New-Object 'Collections.Generic.List[object]'
$scope=if($SourceComponents){'Native source components and WPF dispatcher with synthetic observations; not a packaged application or release acceptance'}else{'Packaged background collection and WPF dispatcher with synthetic observations; not physical reboot or complete desktop acceptance'}
$resultName=if($SourceComponents){'passive-startup-work-source-results.json'}else{'passive-startup-work-results.json'}
$root=Join-Path $env:TEMP ('TqrStartupWork-'+[Guid]::NewGuid().ToString('N'))
$window=$null;$pulse=$null;$passed=$false
function Check([bool]$Value,[string]$Name){
    if(-not $Value){
        # Fixed state names and numeric fixture counters only; never script
        # output, local paths, exception text or device observations.
        $state='Missing';$finished=$false;$hasSample=$false
        if($script:passiveStartupWork){
            $state=[string]$script:passiveStartupWork.State
            $finished=[bool]$script:passiveStartupWork.IsFinished
            $hasSample=$null -ne $script:passiveStartupWork.ReadSample()
        }
        if($state -notin @('Missing','Pending','Completed','Failed','Cancelled','TimedOut')){$state='Unknown'}
        $timerRunning=$script:passiveStartupTimer -and $script:passiveStartupTimer.IsEnabled
        $detail='state={0}; finished={1}; sample={2}; timer={3}; presented={4}; notified={5}; generation={6}; ticket={7}' -f $state,$finished,$hasSample,[bool]$timerRunning,[int]$script:presented,[int]$script:notified,[int]$script:passiveStartupGeneration,[int]$script:passiveStartupTicket
        throw ('FAILED startup worker: '+$Name+' ('+$detail+')')
    }
    $cases.Add([pscustomobject]@{name=$Name;passed=$true})
    Write-Host ('PASS startup worker: '+$Name)
}
function Pump([int]$Milliseconds){
    $frame=New-Object Windows.Threading.DispatcherFrame
    $end=New-Object Windows.Threading.DispatcherTimer
    $end.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $end.Add_Tick({$end.Stop();$frame.Continue=$false}.GetNewClosure())
    $end.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
    $end.Stop()
}
function Wait-Finished($Work){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not $Work.IsFinished -and $watch.ElapsedMilliseconds -lt 6000){Pump 25}
    Check $Work.IsFinished 'Worker releases its runspace after completion or cancellation'
}
function New-Work([int]$Budget=8000){
    $work=New-Object Tqr.PassiveStartupWork $Budget
    $jobs.Add($work)
    return $work
}
function Reset-Fixture {
    if($script:passiveStartupTimer){$script:passiveStartupTimer.Stop()}
    if($script:passiveStartupWork){$script:passiveStartupWork.Cancel();Wait-Finished $script:passiveStartupWork}
    $script:passiveStartupWork=$null;$script:passiveStartupTimer=$null
    $script:passiveStartupStarted=$false;$script:passiveStartupGeneration=0;$script:passiveStartupTicket=-1
    $script:repairActive=$false;$script:updateDownloadActive=$false;$script:pendingProtectedUpdateStarted=$false
    $script:allowFullExit=$false;$global:TqrUiShutdownRequested=$false;$script:lastData=$null
    $script:presented=0;$script:notified=0;$script:pulses=0
}
try {
    New-Item -ItemType Directory -Path $root,$EvidenceDirectory -Force|Out-Null
    $dll=Join-Path $root 'app\TailscaleQuickRepair.Operations.dll'
    if($SourceComponents){
        # Compile the exact source, without contacting an update feed or loading
        # the application. This is independent component evidence only.
        $repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        New-Item -ItemType Directory -Path (Split-Path $dll) -Force|Out-Null
        $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if(-not (Test-Path -LiteralPath $compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
        $arguments=@('/nologo','/target:library','/optimize+',('/out:'+ $dll),
            ('/reference:'+ [Management.Automation.PowerShell].Assembly.Location),
            (Join-Path $repo 'src\native\PassiveStartupHealth.cs'),
            (Join-Path $repo 'src\native\PassiveStartupWork.cs'))
        & $compiler @arguments
        Check ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $dll)) 'Native startup source compiles'
        $transform=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'add-passive-startup-health.ps1'),[Text.Encoding]::UTF8)
        $match=[regex]::Match($transform,"(?ms)^\`$functions=@'\r?\n(?<body>.*?)\r?\n'@")
        Check $match.Success 'Exact startup function definitions are available for component testing'
        $text=$match.Groups['body'].Value
    }else{
        if([string]::IsNullOrWhiteSpace($OutputDirectory)){throw 'A candidate package directory is required.'}
        $zip=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-*.zip' -File|Where-Object Name -notlike '*SetupPackage*')
        Check ($zip.Count -eq 1) 'One exact candidate package'
        Expand-Archive -LiteralPath $zip[0].FullName -DestinationPath $root
        $text=[IO.File]::ReadAllText((Join-Path $root 'app\Tailscale-Repair-UI.ps1'),[Text.Encoding]::UTF8)
    }
    Add-Type -Path $dll
    Check ($null -ne ('Tqr.PassiveStartupWork' -as [type])) 'Native library includes the background collector'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Startup functions parse natively'
    foreach($name in @('Test-PassiveStartupPresentationAllowed','Stop-PassiveStartupHealth','Invoke-PassiveStartupHealth','Receive-PassiveStartupHealth')){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        Check ($nodes.Count -eq 1) ('One tested '+$name)
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    # External observation is synthetic. Dispatch, cancellation, generation
    # checks and receipt use the exact selected source or package functions.
    function Initialize-OperationGate {}
    function Get-PassiveStartupCollectionScript {return 'param($ConfigPath,$TargetConfigured,$OperationsLibraryPath,$UpdaterHostPath,$SetupHostPath,$AdvancedDiagnosticsPath,$NativeHostPath,$RepairInstallPath,$BackendPath,$BackendLauncherPath,$UiLauncherPath,$StartMenuShortcutPath,$TaskName)'+"`n"+$script:fixtureScript}
    function Apply-PassiveStartupPresentation {param($Decision,$Health,$EngineCheck);$script:presented++;$label.Text=$Decision.Status}
    function Request-SmartNotification {param($Code,$Stamp);$script:notified++;return 'suppressed'}
    $Peer='';$ConfigPath=Join-Path $root 'missing-config.json'
    $OperationsLibraryPath=$dll;$UpdaterHostPath='';$SetupHostPath='';$AdvancedDiagnosticsPath=''
    $NativeHostPath='';$RepairInstallPath='';$BackendPath='';$BackendLauncherPath=''
    $UiLauncherPath='';$StartMenuShortcutPath='';$TaskName=''
    $sampleScript=@'
$o=New-Object Tqr.PassiveStartupObservation
$o.AppFilesReady=$true;$o.EngineReady=$true;$o.Config='Configured'
$o.Service='Running';$o.Startup='Automatic';$o.Client='Running';$o.Backend='Running'
$o.LocalIp=(@('100','100','10','20') -join '.');$o.Version='1.90.0'
$s=New-Object Tqr.PassiveStartupSample
$s.Observation=$o
$s
'@
    $window=New-Object Windows.Window
    $window.Width=360;$window.Height=140;$window.ShowInTaskbar=$false
    $label=New-Object Windows.Controls.TextBlock
    $window.Content=$label;$window.Show()
    $pulse=New-Object Windows.Threading.DispatcherTimer
    $pulse.Interval=[TimeSpan]::FromMilliseconds(25)
    $pulse.Add_Tick({$script:pulses++;$label.Text='Dispatcher active'})
    $pulse.Start()

    Reset-Fixture
    $direct=New-Work
    $script:passiveStartupWork=$direct
    Check ($direct.TryStart($sampleScript,@{})) 'Direct typed observation starts without UI dispatch'
    Wait-Finished $direct
    $directSample=$direct.ReadSample()
    Check ($direct.State -eq 'Completed' -and $null -ne $directSample) 'Background runspace returns a typed sample'
    $decision=[Tqr.PassiveStartupHealth]::Evaluate($directSample.Observation)
    Check ($decision.Status -eq 'Healthy' -and [string]::IsNullOrEmpty($decision.NotificationCode)) 'Collected healthy sample stays silent'
    $expectedIp=@('100','100','10','20') -join '.'
    Check ($directSample.Observation.LocalIp -ceq $expectedIp -and $directSample.Observation.Version -ceq '1.90.0') 'Typed worker retains only validated local self metadata'
    $directSample.Observation.Backend='Unknown';$directSample.Observation.LocalIp=(@('100','64','0','1') -join '.');$directSample.Observation.Version='changed'
    $again=$direct.ReadSample()
    Check ($again.Observation.Backend -eq 'Running' -and $again.Observation.LocalIp -ceq $expectedIp -and $again.Observation.Version -ceq '1.90.0') 'Returned samples cannot mutate retained observations or local metadata'
    Reset-Fixture
    $script:fixtureScript='Start-Sleep -Milliseconds 1500'+"`n"+$sampleScript
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-PassiveStartupHealth
    Check ($watch.ElapsedMilliseconds -lt 750) 'Startup returns before delayed observation finishes'
    $first=$script:passiveStartupWork
    Check ($null -ne $first -and $first.State -eq 'Pending') 'Startup dispatch creates a pending observation'
    Check ($null -ne $script:passiveStartupTimer -and $script:passiveStartupTimer.IsEnabled) 'Startup result timer is running'
    $jobs.Add($first)
    Invoke-PassiveStartupHealth
    Check ([object]::ReferenceEquals($first,$script:passiveStartupWork)) 'Repeated startup requests do not create overlapping workers'
    Pump 500
    Check ($script:pulses -ge 3 -and $script:presented -eq 0) 'WPF continues processing events while observation is delayed'
    $watch.Restart()
    while($script:presented -eq 0 -and $watch.ElapsedMilliseconds -lt 7000){Pump 50}
    Check ($script:presented -eq 1 -and $script:notified -eq 0) 'One healthy local sample is presented without a notification'
    Pump 200
    Check ($script:presented -eq 1) 'Completed observation is not presented twice'
    Wait-Finished $first

    foreach($flag in @('repairActive','updateDownloadActive','pendingProtectedUpdateStarted','allowFullExit','shutdown','fullCheck')){
        Reset-Fixture
        $script:fixtureScript='Start-Sleep -Milliseconds 700'+"`n"+$sampleScript
        Invoke-PassiveStartupHealth
        $work=$script:passiveStartupWork;$jobs.Add($work)
        if($flag -eq 'shutdown'){$global:TqrUiShutdownRequested=$true}
        elseif($flag -eq 'fullCheck'){$script:lastData=[pscustomobject]@{done=$true}}
        else{Set-Variable -Scope Script -Name $flag -Value $true}
        Pump 200
        Check ($script:presented -eq 0 -and $script:notified -eq 0 -and $work.State -eq 'Cancelled') ('No passive result or notification during '+$flag)
        Wait-Finished $work
    }

    Reset-Fixture
    $script:fixtureScript='Start-Sleep -Milliseconds 700'+"`n"+$sampleScript
    Invoke-PassiveStartupHealth
    $work=$script:passiveStartupWork;$jobs.Add($work)
    Stop-PassiveStartupHealth
    $script:repairActive=$true;$script:repairActive=$false;$script:lastData=$null
    Pump 250
    Receive-PassiveStartupHealth
    Check ($script:presented -eq 0 -and $script:notified -eq 0) 'A start and reset between timer ticks cannot revive an old sample'
    Wait-Finished $work

    $work=New-Work 200
    Check ($work.TryStart('[Threading.Thread]::Sleep(1200)'+"`n"+$sampleScript,@{})) 'Timed observation starts'
    Pump 400
    Check ($work.State -eq 'TimedOut' -and $null -eq $work.ReadSample()) 'Expired observations cannot be presented as fresh health'
    Check (-not $work.TryStart($sampleScript,@{})) 'A timed-out observation cannot spawn replacement work'
    $watch.Restart();$work.Dispose()
    Check ($watch.ElapsedMilliseconds -lt 250) 'Disposal never waits on an outstanding collector'
    Wait-Finished $work

    foreach($scriptText in @("throw 'Synthetic failure'", "'Unexpected output'", ($sampleScript+"`n"+$sampleScript))){
        $work=New-Work
        Check ($work.TryStart($scriptText,@{})) 'Negative result fixture starts'
        Wait-Finished $work
        Check ($work.State -eq 'Failed' -and $null -eq $work.ReadSample()) 'Errors, extra output and untyped output do not escape the collector'
    }
    $safeDetailSource="$"+"o.LocalIp=(@('100','100','10','20') -join '.');$"+"o.Version='1.90.0'"
    $unsafeDetailSource="$"+"o.LocalIp=(@('192','168','1','5') -join '.');$"+"o.Version='bad version <x>'"
    $unsafeDetails=$sampleScript.Replace($safeDetailSource,$unsafeDetailSource)
    $work=New-Work
    Check ($work.TryStart($unsafeDetails,@{})) 'Unsafe local-detail fixture starts'
    Wait-Finished $work
    $unsafeSample=$work.ReadSample()
    Check ([string]::IsNullOrEmpty($unsafeSample.Observation.LocalIp) -and [string]::IsNullOrEmpty($unsafeSample.Observation.Version)) 'Worker boundary discards non-Tailscale IPs and unsafe version text'
    $work=New-Work
    Check ($work.TryStart($sampleScript.Replace("$"+"o.Backend='Running'","$"+"o.Backend='unexpected-local-value'"),@{})) 'Typed allowlist fixture starts'
    Wait-Finished $work
    Check ($work.ReadSample().Observation.Backend -eq 'Unknown') 'Unrecognised observation text is reduced to Unknown'
    $work.Cancel()
    Check ($null -eq $work.ReadSample()) 'Cancellation discards a completed but unconsumed sample'

    # A separate native test process must exit even with delayed collection.
    # It does not load the product UI or access a Tailscale service.
    $exitExe=Join-Path (Split-Path $dll) 'StartupExitProbe.exe'
    $exitSource=@'
using System;
using System.Collections;
using System.Threading;
public static class StartupExitProbe {
    public static void Main() {
        var work = new Tqr.PassiveStartupWork(15000);
        if (!work.TryStart("[Threading.Thread]::Sleep(30000)", new Hashtable())) Environment.Exit(2);
        Thread.Sleep(300);
        work.Cancel();
    }
}
'@
    Add-Type -TypeDefinition $exitSource -ReferencedAssemblies @($dll,[Management.Automation.PowerShell].Assembly.Location,'System.dll') -OutputAssembly $exitExe -OutputType WindowsApplication
    $process=Start-Process -FilePath $exitExe -WindowStyle Hidden -PassThru
    try {
        # The synthetic collection sleeps for 30 seconds and the worker timeout
        # is 15 seconds. A 10-second host-exit bound therefore still proves the
        # cancellation path released the process rather than natural completion
        # or the deadline, while avoiding a false failure from a busy CI runner.
        $exitWatch=[Diagnostics.Stopwatch]::StartNew()
        $exited=$process.WaitForExit(10000)
        $exitWatch.Stop()
        Write-Host ('Passive cancellation native-host exit: '+[int]$exitWatch.ElapsedMilliseconds+' ms')
        Check ($exited -and $process.ExitCode -eq 0 -and $exitWatch.ElapsedMilliseconds -lt 10000) 'A cancelled passive collector releases its native host before the worker timeout'
    } finally {
        if(-not $process.HasExited){$process.Kill();$process.WaitForExit(2000)|Out-Null}
        $process.Dispose()
    }
    $passed=$true
} finally {
    if($pulse){$pulse.Stop()}
    if($script:passiveStartupTimer){$script:passiveStartupTimer.Stop()}
    foreach($job in $jobs){$job.Dispose()}
    if($window){$window.Close()}
    # Only this synthetic, uniquely owned directory is removed.
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{passed=$passed;source=$env:GITHUB_SHA;scope=$scope;sourceComponents=[bool]$SourceComponents;cases=@($cases.ToArray())}|
        ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $EvidenceDirectory $resultName) -Encoding UTF8
}
if(-not $passed){throw 'Passive startup worker checks failed.'}