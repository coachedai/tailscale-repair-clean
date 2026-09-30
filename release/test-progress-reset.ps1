param([Parameter(Mandatory=$true)][string]$UiPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Native Windows PowerShell 5.1 required.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
$root=Join-Path $env:TEMP ('TQR-ProgressTest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$cases=New-Object 'Collections.Generic.List[object]';$frames=New-Object 'Collections.Generic.List[object]'
$window=$null;$attachedChild=$null
function Check([bool]$Pass,[string]$Name){if(-not $Pass){throw "FAILED progress reset: $Name"};$cases.Add([pscustomobject]@{name=$Name;passed=$true});Write-Host "PASS progress: $Name"}
try{
    $text=[IO.File]::ReadAllText($UiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Final package parses on Windows PowerShell 5.1'
    $names=@('Get-ObservationCaption','Update-RemoteObservation','Update-AdvancedObservation',
        'Set-UncheckedDetails','Apply-PassiveStartupDetails','Test-PassiveStartupPresentationAllowed','Stop-PassiveStartupHealth','Get-Brush','Set-Badge','Set-Step','Set-ActionButton','Show-ImmediateRunState','Get-RepairAttachmentFloor',
        'Update-RepairObservation','Attach-To-RunningRepair','Start-Repair','Start-RepairCore','Apply-State','Update-HeroAndAction',
        'Update-CardsAndPath','Update-Diagnostics','Get-RunDurationText','Get-AdvancedValue','Reset-AdvancedProgress',
        'Stop-AdvancedDiagnostics','Complete-AdvancedDiagnostics','Update-AdvancedDiagnostics','Start-AdvancedDiagnostics')
    foreach($name in $names){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if($nodes.Count -ne 1){throw "Ambiguous final function: $name"}
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    # Only external scheduler/service, telemetry destinations and lease operations
    # are fixtures. Start/reset, file acceptance, Apply-State, UI and diagnostic
    # child launch are actual final package implementations.
    function Get-RepairTaskState {return $script:fixtureTaskState}
    function Get-ActiveOperationLock {param([switch]$RecoverStale);return $script:fixtureOwner}
    function Ensure-EngineReadyCached {return $true}
    function Invoke-RepairTask {$script:scheduledCount++;return $true}
    function Acquire-UiOperationLock {param($Kind,$Minutes);return $true}
    function Release-UiOperationLock {param($Kind);$script:releasedCount++}
    function Update-TrayStatus {param($Data)}
    function Update-TrayFreshness {}
    function Update-LastCheckedText {}
    function Set-ConnectionInsight {param($Text,$Tone)}
    function Record-CompletedHistory {param($Data);if($Data.done){$script:completedSideEffects++}}
    function Update-ConnectionIntelligence {param($Data)}
    $xm=[regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    [xml]$x=$xm.Groups['xaml'].Value;$reader=New-Object Xml.XmlNodeReader $x
    $window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
    foreach($node in $x.SelectNodes('//*[@*[local-name()="Name"]]')){
        $attr=$node.Attributes | Where-Object {$_.LocalName -eq 'Name'} | Select-Object -First 1
        $control=$window.FindName($attr.Value);if($control){Set-Variable -Name $attr.Value -Value $control}
    }
    $window.WindowState='Normal';$window.WindowStartupLocation='Manual';$window.Left=30;$window.Top=30
    $window.Width=1100;$window.Height=850;$window.ShowInTaskbar=$false;$window.Show()
    Add-Type -ReferencedAssemblies @('WindowsBase','PresentationCore','PresentationFramework') -TypeDefinition @'
using System;
using System.Windows.Threading;
public static class TqrProgressPump {
 public static void Run(int ms) {
  DispatcherFrame frame=new DispatcherFrame();
  DispatcherTimer timer=new DispatcherTimer(DispatcherPriority.Background);
  timer.Interval=TimeSpan.FromMilliseconds(ms);
  timer.Tick+=delegate {timer.Stop();frame.Continue=false;};
  timer.Start();Dispatcher.PushFrame(frame);
 }
}
'@
    function Pump([int]$Ms=40){[TqrProgressPump]::Run($Ms);$window.UpdateLayout()}
    $StateFile=Join-Path $root 'state.json';$Peer='fixture-peer';$peerDisplay=$Peer
    $script:fixtureTaskState='Ready';$script:fixtureOwner=$null;$script:scheduledCount=0;$script:releasedCount=0
    $script:completedSideEffects=0;$script:repairActive=$false;$script:lastData=$null
    $script:launchUtc=[DateTime]::UtcNow;$script:repairResultNotBeforeUtc=$script:launchUtc
    $script:lastAppliedStateWriteUtc=[DateTime]::MinValue;$script:lastAcceptedRepairStampUtc=[DateTime]::MinValue
    $script:reliabilityEvents=New-Object 'Collections.Generic.List[string]';$script:connectionEvents=New-Object 'Collections.Generic.List[string]'
    function State([bool]$Done,[int]$Progress,[DateTime]$Stamp){
        [pscustomobject]@{done=$Done;progress=$Progress;updatedUtc=$Stamp.ToString('o');mode=$(if($Done){'success'}else{'checking'});
            status=$(if($Done){'Fixture completed'}else{'Fixture checking'});detail='Synthetic check';phase='fixture';
            client=$(if($Progress -ge 22){'Running'}else{'Unknown'});service=$(if($Progress -ge 40){'Running'}else{'Unknown'});
            backend=$(if($Progress -ge 88){'Running'}else{'Unknown'});peerReachable=$(if($Done){'Reachable'}else{'Unknown'});
            peerOnline='Unknown';route=$(if($Done){'Direct'}else{''});latency=$(if($Done){'11 ms'}else{''});repairPerformed=$false;events=@()}
    }
    function Write-State($Data){Start-Sleep -Milliseconds 3;[IO.File]::WriteAllText($StateFile,($Data|ConvertTo-Json -Compress))}
    function Pending-Rail {return $PathLine1.Background.Color -eq (Get-Brush 'Border').Color -and $PathLine2.Background.Color -eq (Get-Brush 'Border').Color -and $PathLine3.Background.Color -eq (Get-Brush 'Border').Color}
    $tick=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$stateTimer' -and $n.Member.Value -eq 'Add_Tick'},$true))
    Check ($tick.Count -eq 1) 'One actual packaged main-state timer callback'
    $stateTick=$tick[0].Arguments[0].ScriptBlock.GetScriptBlock()
    $old=State $true 100 ([DateTime]::UtcNow.AddMilliseconds(-150));Write-State $old
    $oldHash=(Get-FileHash $StateFile).Hash
    Start-Repair
    Check (Pending-Rail) 'Starting a check clears all completed rail segments immediately'
    Check ($script:repairActive -and -not $PrimaryButton.IsEnabled) 'Check stays busy before worker dispatch'
    & $stateTick;Pump
    Check ($script:lastData -eq $null -and $script:completedSideEffects -eq 0 -and (Pending-Rail)) 'Unseen terminal result inside the old one-second window is not repainted'
    Check ((Get-FileHash $StateFile).Hash -eq $oldHash) 'Previous result evidence is preserved instead of deleted'
    Start-Repair;Pump
    Check ($script:scheduledCount -eq 1) 'Repeated click while checking does not schedule another repair'
    $step=State $false 5 ([DateTime]::UtcNow);Write-State $step;& $stateTick;Pump
    Check ($script:lastData.progress -eq 5 -and $AppDot.Fill.Color -eq (Get-Brush 'Blue').Color -and $PeerDot.Fill.Color -eq (Get-Brush 'Faint').Color) 'Fresh initial state activates only the measured starting stage'
    $step=State $false 88 ([DateTime]::UtcNow);Write-State $step;& $stateTick;Pump
    Check ($script:lastData.progress -eq 88 -and $PathLine3.Background.Color -eq (Get-Brush 'Blue').Color -and -not $PrimaryButton.IsEnabled) 'Fresh peer-stage progress remains a running check'
    $done=State $true 100 ([DateTime]::UtcNow);Write-State $done;& $stateTick;Pump
    Check ($script:completedSideEffects -eq 1 -and $PrimaryButton.IsEnabled -and $PathLine3.Background.Color -eq (Get-Brush 'Green').Color) 'Only a fresh final result completes the check'
    Start-Repair;& $stateTick;Pump
    Check ($script:scheduledCount -eq 2 -and $script:repairActive -and (Pending-Rail)) 'Rapid second completed check starts with a pending rail, not a full bar'
    [IO.File]::SetLastWriteTimeUtc($StateFile,[DateTime]::UtcNow);& $stateTick
    Check ($script:lastData -eq $null -and $script:completedSideEffects -eq 1) 'Touching the old file cannot make its embedded terminal stamp new'
    $current=State $false 22 ([DateTime]::UtcNow);Write-State $current;& $stateTick
    $accepted=$script:lastAcceptedRepairStampUtc
    Write-State $done;& $stateTick
    Check ($script:lastData.progress -eq 22 -and $script:lastAcceptedRepairStampUtc -eq $accepted) 'A late prior terminal result cannot replace newer progress'
    $future=State $true 100 ([DateTime]::UtcNow.AddMinutes(1));Write-State $future;& $stateTick
    Check ($script:lastAcceptedRepairStampUtc -eq $accepted) 'Future-dated terminal state is not accepted'
    $invalid=State $false 10 ([DateTime]::UtcNow);$invalid.done='false';Write-State $invalid;& $stateTick
    Check ($script:lastAcceptedRepairStampUtc -eq $accepted) 'A string false cannot be mistaken for a completed boolean'
    [IO.File]::WriteAllText($StateFile,'{unfinished');& $stateTick
    Check ($script:repairActive -and $script:lastAcceptedRepairStampUtc -eq $accepted) 'Partial JSON leaves current progress and the worker untouched'
    $wrong=State $true 100 ([DateTime]::UtcNow);$wrong|Add-Member NoteProperty peer 'different-fixture';Write-State $wrong;& $stateTick
    Check ($script:repairActive -and $script:lastAcceptedRepairStampUtc -eq $accepted) 'An explicitly different peer cannot complete this check'
    $done=State $true 100 ([DateTime]::UtcNow);Write-State $done;& $stateTick
    Start-Repair;Pump
    $done=State $true 100 ([DateTime]::UtcNow);Write-State $done;& $stateTick
    Check ($script:completedSideEffects -eq 3 -and $PrimaryButton.IsEnabled) 'A genuinely fast worker may complete without an intermediate poll'

    # Existing-worker attach uses a real owned synthetic process start timestamp.
    $sleep=Join-Path $root 'sleep.ps1';[IO.File]::WriteAllText($sleep,'Start-Sleep -Seconds 10')
    $p=New-Object Diagnostics.ProcessStartInfo
    $p.FileName=Join-Path $PSHOME 'powershell.exe';$p.UseShellExecute=$false;$p.CreateNoWindow=$true
    $p.Arguments='-NoProfile -NonInteractive -File "'+$sleep+'"';$attachedChild=[Diagnostics.Process]::Start($p)
    $script:fixtureOwner=[pscustomobject]@{kind='repair';ownerPid=$attachedChild.Id};$script:fixtureTaskState='Running'
    $previousSchedules=$script:scheduledCount;$script:lastData=$null
    Check (Attach-To-RunningRepair) 'Running task attaches rather than launching another worker'
    Write-State $done;& $stateTick
    Check ($script:repairActive -and $script:lastData -eq $null) 'Attach rejects results older than the live worker process'
    $attached=State $false 40 ([DateTime]::UtcNow);Write-State $attached;& $stateTick
    Check ($script:lastData.progress -eq 40 -and $script:scheduledCount -eq $previousSchedules) 'Current attached-worker progress is accepted without another scheduler call'
    $attached=State $true 100 ([DateTime]::UtcNow);Write-State $attached;& $stateTick
    Check ($PrimaryButton.IsEnabled) 'Current attached-worker completion is shown'
    Check ((Attach-To-RunningRepair) -and $HeroTitle.Text -eq 'Fixture completed') 'Reattaching during worker cleanup keeps the known terminal result steady'
    $attachedChild.Kill();$attachedChild.WaitForExit();$attachedChild.Dispose();$attachedChild=$null
    $script:fixtureTaskState='Ready';$script:fixtureOwner=$null

    # Actual diagnostic button + launcher, with a delayed file-output worker only.
    # The real network/diagnostic worker is covered separately by the permanent suite.
    $AdvancedDiagnosticsPath=Join-Path $root 'diagnostic-fixture.ps1'
    [IO.File]::WriteAllText($AdvancedDiagnosticsPath,@'
param([string]$Peer,[string]$OutputPath,[string]$RunId)
Start-Sleep -Milliseconds 1300
@{runId=$RunId;done=$false;progress=15;summary='Fixture measuring';updatedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content $OutputPath
Start-Sleep -Milliseconds 700
@{runId=$RunId;done=$true;progress=100;summary='Fixture diagnosis completed';severity='good';detail='Fixture only';updatedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content $OutputPath
'@)
    $AdvancedDiagnosticsStateFile=Join-Path $root 'advanced.json';$script:advancedDiagnosticsProcess=$null
    $script:advancedDiagnosticsTimer=$null;$script:advancedDiagnosticsOwnsOperation=$false
    $DetailsPanel.Visibility='Visible';$AdvancedDiagnosticsPanel.Visibility='Visible';$script:repairActive=$false
    $handler=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$AdvancedDiagnosticsButton' -and $n.Member.Value -eq 'Add_Click'},$true))
    Check ($handler.Count -eq 1) 'One actual diagnostic button handler'
    $AdvancedDiagnosticsButton.Add_Click($handler[0].Arguments[0].ScriptBlock.GetScriptBlock())
    foreach($run in 1..2){
        $AdvancedDiagnosticsProgress.Value=100;Pump
        $AdvancedDiagnosticsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $id=$script:advancedDiagnosticsRunId
        for($frame=0;$frame -lt 5;$frame++){
            Pump 60
            $track=$AdvancedDiagnosticsProgress.Template.FindName('PART_Track',$AdvancedDiagnosticsProgress)
            $indicator=$AdvancedDiagnosticsProgress.Template.FindName('PART_Indicator',$AdvancedDiagnosticsProgress)
            $frames.Add([pscustomobject]@{run=$run;frame=$frame;value=$AdvancedDiagnosticsProgress.Value;fill=$indicator.ActualWidth;track=$track.ActualWidth})
            if($AdvancedDiagnosticsProgress.Value -ne 0 -or $indicator.ActualWidth -gt 0.5){throw 'Previous full diagnostic bar was rendered before fresh progress.'}
        }
        Check ($AdvancedDiagnosticsProgress.Value -eq 0 -and -not $AdvancedDiagnosticsButton.IsEnabled) "Diagnostic run $run resets the actual rendered fill before new measurements"
        if($run -eq 2){
            $stored=Get-Content $AdvancedDiagnosticsStateFile -Raw | ConvertFrom-Json
            Check ($stored.runId -ne $id -and $stored.done) 'Second diagnostics run preserves but excludes the previous result file'
            Update-AdvancedDiagnostics
            Check ($AdvancedDiagnosticsProgress.Value -eq 0) 'Prior diagnostic terminal ID cannot repaint full progress'
        }
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not $AdvancedDiagnosticsButton.IsEnabled -and [DateTime]::UtcNow -lt $deadline){Pump 80}
        Check ($AdvancedDiagnosticsButton.IsEnabled -and $AdvancedDiagnosticsSummary.Text -eq 'Fixture diagnosis completed') "Diagnostic run $run completes through the real timer and renderer"
    }
    Check ($HeroTitle.Text -eq 'Fixture completed') 'Optional diagnostic progress never replaces the main connection verdict'
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'progress-frames.json'),($frames.ToArray()|ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'progress-reset-results.json'),(@{passed=$true;scope='Actual final PowerShell 5.1/WPF start, timer, file-gating, rendering and child launch; scheduler/lease and delayed diagnostic output are fixtures';cases=$cases.ToArray()}|ConvertTo-Json -Depth 7))
}catch{
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'progress-reset-results.json'),(@{passed=$false;failure=$_.Exception.Message;cases=$cases.ToArray();frames=$frames.ToArray()}|ConvertTo-Json -Depth 7));throw
}finally{
    if($script:advancedDiagnosticsTimer){$script:advancedDiagnosticsTimer.Stop()}
    if($script:advancedDiagnosticsProcess){try{if(-not $script:advancedDiagnosticsProcess.HasExited){$script:advancedDiagnosticsProcess.Kill()};$script:advancedDiagnosticsProcess.Dispose()}catch{}}
    if($attachedChild){try{if(-not $attachedChild.HasExited){$attachedChild.Kill()};$attachedChild.Dispose()}catch{}}
    if($window){$window.Close()}
}
