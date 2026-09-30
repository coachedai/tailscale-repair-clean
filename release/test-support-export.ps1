param([Parameter(Mandatory=$true)][string]$UiPath,[Parameter(Mandatory=$true)][string]$LibraryPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Native Windows PowerShell 5.1 required.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
if(-not ('Tqr.SupportReport' -as [type])){Add-Type -Path $LibraryPath}
$root=Join-Path $env:TEMP ('TQR-ExportTest-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $root|Out-Null
$cases=New-Object 'Collections.Generic.List[object]';$window=$null;$dialog=$null
function Check([bool]$Good,[string]$Name){if(-not $Good){throw "FAILED support export: $Name"};$cases.Add([pscustomobject]@{name=$Name;passed=$true});Write-Host "PASS export: $Name"}
function Fails([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
$now=[DateTime]::UtcNow;$utc=$now.AddSeconds(-3).ToString('o')
function Snapshot {
    return [ordered]@{
        appVersion='3.0.0-rc.12';tailscaleVersion='1.102.3';vpnState='Detected';vpnLabel='Proton VPN';mainState='completed'
        main=[ordered]@{done=$true;updatedUtc=$utc;mode='success';client='Running';service='Running';backend='Running';peerReachable='Reachable';route='Direct';latency='11 ms';repairPerformed=$false;peer='127.0.0.1';device='PRIVATE-SENTINEL';detail='PRIVATE-SENTINEL';token='PRIVATE-SENTINEL'}
        guardian=[ordered]@{state='Healthy';checkedUtc=$utc;verifiedFiles=5;issues=0;baseline='Confirmed';detail='PRIVATE-SENTINEL'}
        diagnosticState='completed';diagnostics=[ordered]@{done=$true;updatedUtc=$utc;netcheckStatus='Complete';udp='Available';ipv4='Available';ipv6='Unavailable';path='Direct';latency='1.5 ms';disco='Reachable';tsmp='Reachable';icmp='Timed out';peerApi='Not supported';mapping='Stable mapping';portMapping='UPnP, NAT-PMP';durationSeconds=4.5;otherVpns=@('PRIVATE-SENTINEL');nearestDerp='PRIVATE-SENTINEL';summary='PRIVATE-SENTINEL';runId='PRIVATE-SENTINEL'}
        history=[ordered]@{schema=1;entries=@([ordered]@{id='PRIVATE-SENTINEL';utc=$utc;code='check_healthy';before=-1;after=-1;message='PRIVATE-SENTINEL'})}
    }
}
function Build($Data,[bool]$History=$false){[Tqr.SupportReport]::Build(($Data|ConvertTo-Json -Depth 8 -Compress),$History,$now)}
try{
    $s=Snapshot;$plain=Build $s;$full=Build $s $true
    Check ($plain.Text -match 'Quick Repair version: 3.0.0-rc.12' -and $plain.Text -match 'Tailscale version: 1.102.3') 'Valid RC/client versions remain useful'
    Check ($plain.Text -notmatch 'PRIVATE-SENTINEL|127[.]0[.]0[.]1|runId|device:|token:') 'Addresses identifiers raw messages and run IDs are excluded'
    Check ($plain.Text -match 'VPN context: Active - Proton VPN') 'Support report includes only the fixed active VPN label already shown by Quick Repair'
    $s=Snapshot;$s.vpnLabel='PRIVATE-SENTINEL';$r=Build $s
    Check ($r.Text -match 'VPN context: Active - VPN tunnel' -and $r.Text -notmatch 'PRIVATE-SENTINEL') 'Unknown VPN labels collapse to a generic fixed value'
    $s=Snapshot;$s.vpnState='NotDetected';$r=Build $s
    Check ($r.Text -match 'VPN context: Not detected') 'Support report distinguishes no detected VPN without probing again'
    Check ($plain.Text -match 'Verified app files: 5' -and $plain.Text -match 'Known-good baseline: Confirmed') 'Guardian result and coverage are represented without file paths'
    Check ($plain.Text -match 'ICMP: Timed out' -and $plain.Text -match 'Peer API: Not supported') 'Independent diagnostic outcomes remain distinct'
    Check ($plain.Text -match 'RECENT ACTIVITY\r\nNot included' -and $full.Text -match 'Connection check passed') 'History is excluded until explicitly selected'
    Check ($full.Text -notmatch 'PRIVATE-SENTINEL') 'Typed history cannot smuggle messages or entry identities'
    $s.main.route='Relay / FRA';$s.diagnostics.path='Relay - LHR';$r=Build $s
    Check ($r.Text -match 'Path: Relay' -and $r.Text -notmatch 'FRA|LHR') 'Relay path remains useful while region identifiers are omitted'
    $s=Snapshot;$s.mainState='checking';$r=Build $s
    Check ($r.Text -match 'Check in progress' -and $r.Text -notmatch 'Desktop client:') 'An active check cannot export the previous completed main result'
    $s.mainState='stale';$r=Build $s
    Check ($r.Text -match 'Historical observation - run a fresh check') 'Network-invalidated observations are explicitly historical'
    $s=Snapshot;$s.main.updatedUtc=$now.AddHours(-2).ToString('o');$r=Build $s
    Check ($r.Text -match 'Historical observation') 'Old timestamps cannot be presented as fresh evidence'
    $s=Snapshot;$s.main.updatedUtc=$now.AddHours(1).ToString('o');$r=Build $s
    Check ($r.Text -match 'No verified observation available' -and $r.Text -notmatch 'Desktop client:') 'Future observation timestamps fail closed'
    $s=Snapshot;$s.main.done='true';$r=Build $s
    Check ($r.Text -notmatch 'Desktop client:') 'A string true is not a completed boolean'
    $s=Snapshot;$s.diagnosticState='checking';$r=Build $s
    Check ($r.Text -notmatch 'ICMP:' -and $r.Text -match 'Check in progress') 'In-progress diagnostics do not export stale peer measurements'
    $s.diagnosticState='incomplete';$r=Build $s
    Check ($r.Text -match 'Inspection incomplete' -and $r.Text -notmatch 'ICMP:') 'Failed diagnostics do not substitute old successful fields'
    $s=Snapshot;$s.main.latency='-1 ms';$s.diagnostics.durationSeconds='PRIVATE-SENTINEL';$r=Build $s
    Check ($r.Text -match 'Latency: Unknown' -and $r.Text -match 'Duration seconds: Unknown') 'Invalid numerical measurements are not coerced into valid results'
    $culture=[Globalization.CultureInfo]::CurrentCulture
    try{[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE');$r=Build (Snapshot);Check ($r.Text -match 'Latency: 1.5 ms') 'Report number formatting is independent of Windows locale'}finally{[Globalization.CultureInfo]::CurrentCulture=$culture}
    $injections=@('PRIVATE-SENTINEL',"Running`nPRIVATE-SENTINEL",'127.0.0.1','fixture.example','C:\private-fixture\file','https://fixture.invalid/private')
    foreach($payload in $injections){
        $s=Snapshot;$s.appVersion=$payload;$s.tailscaleVersion=$payload
        foreach($map in @($s.main,$s.guardian,$s.diagnostics)){
            foreach($key in @($map.Keys)){if($map[$key] -is [string] -and $key -ne 'updatedUtc'){$map[$key]=$payload}}
        }
        $r=Build $s $true
        Check (-not $r.Text.Contains($payload)) 'Untrusted string injection is replaced by fixed vocabulary, not passed through'
    }
    $s=Snapshot;$s.history.entries=@(1..40|ForEach-Object {@{id='not-exported';utc=$now.AddSeconds(-$_).ToString('o');code='check_healthy';before=-1;after=-1}});$r=Build $s $true
    Check (([regex]::Matches($r.Text,' - Connection check passed')).Count -eq 10) 'Optional history is bounded to the newest ten events'
    $s.history.entries+=@{utc=$utc;code='check_healthy'};$r=Build $s $true
    Check ($r.Text -match 'entry limit exceeded' -and $r.Text -notmatch ' - Connection check passed') 'Over-limit history is not partially trusted'
    $s=Snapshot;$s.history.entries[0].code='PRIVATE-SENTINEL';$r=Build $s $true
    Check ($r.Text -notmatch 'PRIVATE-SENTINEL' -and $r.Text -match 'No eligible recorded events') 'Unknown event codes cannot become arbitrary export text'
    Check (Fails {[Tqr.SupportReport]::Build('{broken',$false,$now)}) 'Malformed snapshot is rejected without a raw-text fallback'
    Check (Fails {[Tqr.SupportReport]::Build(('x'*65537),$false,$now)}) 'Snapshot input limit is enforced before deserialization'
    $output=Join-Path $root 'report.txt';$plain.SaveNew($output)
    Check ([IO.File]::ReadAllText($output) -ceq $plain.Text) 'Saved UTF-8 text exactly matches the immutable preview'
    $originalHash=(Get-FileHash $output).Hash
    Check (Fails {$full.SaveNew($output)}) 'Export refuses to clobber an existing destination'
    Check ((Get-FileHash $output).Hash -eq $originalHash) 'Existing report bytes remain unchanged after rejected save'
    Check (Fails {$plain.SaveNew((Join-Path $root 'config.json'))}) 'Export cannot overwrite configuration or create a non-text payload'
    Check (Fails {$plain.SaveNew('relative.txt')}) 'Relative destinations are not accepted'
    Check (Fails {$plain.SaveNew('\\invalid-fixture\share\report.txt')}) 'UNC destinations are refused without attempting a write'
    Check (Fails {$plain.SaveNew((Join-Path $root 'report.txt:extra'))}) 'Alternate stream paths are refused'
    Check (@(Get-ChildItem $root -Filter '.tqr-export-*' -Force).Count -eq 0) 'Successful and rejected saves leave no temporary export files'
    $historyPath=Join-Path $root 'health-history.json';[IO.File]::WriteAllText($historyPath,'{broken')
    $before=(Get-FileHash $historyPath).Hash;$raw=[Tqr.SupportReport]::ReadHistory($root)
    Check ($raw -eq '{broken' -and (Get-FileHash $historyPath).Hash -eq $before) 'History reads never repair or delete a damaged local record'
    [IO.File]::WriteAllText($historyPath,('x'*32769));Check ([Tqr.SupportReport]::ReadHistory($root) -eq '{}') 'Oversized local history is not loaded into export'
    $hold=[IO.File]::Open($historyPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Check ([Tqr.SupportReport]::ReadHistory($root) -eq '{}') 'Locked history becomes unavailable without blocking or changing it'}finally{$hold.Dispose()}
    [IO.File]::WriteAllText($historyPath,((Snapshot).history|ConvertTo-Json -Depth 5))

    $ui=[IO.File]::ReadAllText($UiPath,[Text.Encoding]::UTF8);$tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Final package with export parses on Windows PowerShell 5.1'
    $xmatch=[regex]::Match($ui,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    [xml]$xaml=$xmatch.Groups['xaml'].Value;$reader=New-Object Xml.XmlNodeReader $xaml
    $window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
    $window.WindowState='Normal';$window.WindowStartupLocation='Manual';$window.Left=30;$window.Top=30
    $window.Width=1100;$window.Height=850;$window.ShowInTaskbar=$false;$window.Show()
    Add-Type -ReferencedAssemblies @('PresentationFramework','PresentationCore','WindowsBase','System.Xaml') -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Threading;
public static class TqrExportTestSinks {
 public static string Copied, Destination;
 public static bool FailCopy;
 public static Action<string> Copy=delegate(string text){if(FailCopy)throw new InvalidOperationException("fixture");Copied=text;};
 public static Func<Window,string> Choose=delegate(Window owner){return Destination;};
 public static void Pump(){DispatcherFrame frame=new DispatcherFrame();DispatcherTimer timer=new DispatcherTimer();timer.Interval=TimeSpan.FromMilliseconds(100);timer.Tick+=delegate{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);}
}
'@
    $dialog=[Tqr.SupportReportWindow]::Create($window,$plain,$full,[TqrExportTestSinks]::Copy,[TqrExportTestSinks]::Choose)
    $dialog.Show();[TqrExportTestSinks]::Pump();$grid=$dialog.Content
    $preview=$grid.FindName('ReportPreview');$include=$grid.FindName('IncludeHistory');$status=$grid.FindName('ReportStatus')
    $copyButton=$grid.FindName('CopyReport');$saveButton=$grid.FindName('SaveReport')
    Check ($preview.IsReadOnly -and $preview.Text -ceq $plain.Text -and -not $include.IsChecked) 'Native preview starts with a frozen identifier-free snapshot and history off'
    $copyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ([TqrExportTestSinks]::Copied -ceq $preview.Text) 'Native Copy event sends exactly the selected safe preview'
    $include.IsChecked=$true
    Check ($preview.Text -ceq $full.Text) 'History opt-in switches only to the already sanitized snapshot'
    $copyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ([TqrExportTestSinks]::Copied -ceq $full.Text) 'Copied opt-in report contains typed history but no private identifiers'
    [TqrExportTestSinks]::Destination=$null;$saveButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ($status.Text -match 'cancelled') 'Cancelled Save As creates no report'
    [TqrExportTestSinks]::Destination=Join-Path $root 'selected-report.txt';$saveButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ([IO.File]::ReadAllText([TqrExportTestSinks]::Destination) -ceq $preview.Text -and $status.Text -match 'Saved locally') 'Native Save event writes the exact preview to the chosen new file'
    $saveButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ($status.Text -match 'Could not save' -and $saveButton.IsEnabled) 'A save failure is contained and leaves the preview usable'
    [TqrExportTestSinks]::FailCopy=$true;$copyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ($status.Text -match 'Clipboard unavailable' -and $copyButton.IsEnabled) 'Clipboard failure produces honest feedback without breaking the app'
    [TqrExportTestSinks]::FailCopy=$false
    $tbViewer=$preview.Template.FindName('PART_ContentHost',$preview);$tbViewer.ApplyTemplate()|Out-Null
    $bar=$tbViewer.Template.FindName('PART_VerticalScrollBar',$tbViewer);$bar.ApplyTemplate()|Out-Null
    Check ($bar.Width -eq 12 -and $bar.Template.FindName('HistoryRail',$bar) -ne $null) 'Report preview reuses the slim History scroll theme rather than a white system rail'
    $preview.ScrollToEnd();[TqrExportTestSinks]::Pump()
    Check ($preview.VerticalOffset -gt 0) 'Long report preview scrolls through every retained section'
    $preview.ScrollToHome();[TqrExportTestSinks]::Pump()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$dialog.ActualWidth,[int]$dialog.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($dialog);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $png=[IO.File]::Create((Join-Path $EvidenceDirectory 'support-preview.png'));try{$encoder.Save($png)}finally{$png.Dispose()}
    $grid.FindName('CloseReport').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$dialog=$null
    Check $window.IsVisible 'Closing the report preview leaves the app open'

    foreach($name in @('Get-SupportFields','Get-SupportSnapshot','Show-SupportReport')){
        $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Check ($functions.Count -eq 1) "One actual packaged $name implementation"
        . ([scriptblock]::Create($functions[0].Extent.Text))
    }
    foreach($name in @('AdvancedCopyButton','GuardianStatusText','GuardianDetailText','DetailVersion','HeroTitle')){Set-Variable $name ($window.FindName($name))}
    $ProductVersion='3.0.0-rc.12';$DetailVersion.Text='1.102.3';$script:lastVpnAwarenessState='Detected';$script:lastVpnAwarenessLabel='Proton VPN';$StateDir=$root;$OperationsLibraryPath=$LibraryPath;$Peer='PRIVATE-SENTINEL'
    $script:lastData=[pscustomobject](Snapshot).main;$script:repairActive=$false;$script:environmentStale=$false
    $script:supportDiagnosticsData=[pscustomobject](Snapshot).diagnostics;$script:supportDiagnosticsState='completed';$script:supportDiagnosticsPeer=$Peer;$script:supportDiagnosticsStale=$false
    $GuardianStatusText.Text='Healthy';$GuardianDetailText.Text='5 release files verified with SHA-256. Known-good baseline confirmed. Windows integration checked.';$script:lastGuardianCheckAt=$now
    $HeroTitle.Text='Unchanged main result';$json=Get-SupportSnapshot;$captured=[Tqr.SupportReport]::Build($json,$false,$now)
    Check ($captured.Text -match 'Verified app files: 5' -and $captured.Text -notmatch 'PRIVATE-SENTINEL') 'Actual packaged collector projects main Guardian and diagnostics without raw identities'
    $script:repairActive=$true;$pending=[Tqr.SupportReport]::Build((Get-SupportSnapshot),$false,$now)
    Check ($pending.Text -notmatch 'Desktop client:') 'Packaged collector excludes a completed result while a new repair check is active'
    $script:repairActive=$false;$script:supportDiagnosticsStale=$true;$stale=[Tqr.SupportReport]::Build((Get-SupportSnapshot),$false,$now)
    Check ($stale.Text -match 'Historical observation') 'Packaged collector labels diagnostic snapshots invalidated by network or target changes'
    Check ($captured.Text -ceq [Tqr.SupportReport]::Build($json,$false,$now).Text) 'An open snapshot is unaffected by later live state changes'
    $script:supportReportWindow=$null;$script:exportModalSeen=$false
    $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({if($script:supportReportWindow -and $script:supportReportWindow.Owner -eq $window){$script:exportModalSeen=$true;$script:supportReportWindow.Close()}})
    $events=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$AdvancedCopyButton' -and $n.Member.Value -eq 'Add_Click'},$true))
    Check ($events.Count -eq 1 -and $AdvancedCopyButton.Content -eq 'Share report') 'Existing diagnostic copy action is upgraded to one clear Share report action'
    $AdvancedCopyButton.Add_Click($events[0].Arguments[0].ScriptBlock.GetScriptBlock())
    try{$timer.Start();$AdvancedCopyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}finally{$timer.Stop()}
    Check ($script:exportModalSeen -and $null -eq $script:supportReportWindow -and $HeroTitle.Text -eq 'Unchanged main result') 'Actual packaged Share click opens and closes the native modal without changing health or exporting automatically'
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'sample-support-report.txt'),$full.Text)
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'support-export-results.json'),(@{passed=$true;scope='Native .NET privacy projection/read/save, final WPF preview and packaged Share event; clipboard destination and Save As selection are fixtures';cases=$cases.ToArray()}|ConvertTo-Json -Depth 7))
}catch{
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'support-export-results.json'),(@{passed=$false;failure=$_.Exception.Message;cases=$cases.ToArray()}|ConvertTo-Json -Depth 7));throw
}finally{if($dialog){$dialog.Close()};if($window){$window.Close()}}
