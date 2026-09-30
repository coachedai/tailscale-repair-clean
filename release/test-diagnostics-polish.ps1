param([Parameter(Mandatory=$true)][string]$UiPath,[Parameter(Mandatory=$true)][string]$LibraryPath,[Parameter(Mandatory=$true)][string]$WorkerPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Native Windows PowerShell 5.1 required.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
if(-not ('Tqr.DiagnosticAnalysis' -as [type])){Add-Type -Path $LibraryPath}
$root=Join-Path $env:TEMP ('TQR-DiagnosticTest-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root | Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
$window=$null
function Check([bool]$Good,[string]$Name){if(-not $Good){throw "FAILED diagnostics/polish: $Name"};$cases.Add([pscustomobject]@{name=$Name;passed=$true});Write-Host "PASS: $Name"}
function Command([string]$Text,[int]$Code=0){$c=New-Object Tqr.DiagnosticCommand;$c.Output=$Text;$c.ExitCode=$Code;return $c}
function Probe([string]$Via='127.0.0.1:41641',[string]$Type='disco'){[Tqr.DiagnosticAnalysis]::ParseProbe((Command "pong from fixture via $Via in 11ms"),$Type)}
try{
    $direct=Probe;$tunnel=Probe 'TSMP' 'tsmp';$icmp=Probe 'ICMP' 'icmp'
    $api=[Tqr.DiagnosticAnalysis]::ParseProbe((Command 'hit peerapi of fixture at endpoint in 12ms'),'peerapi')
    Check ($direct.Path -eq 'Direct' -and $direct.Status -eq 'Reachable') 'Direct endpoint output is recognized without the literal word direct'
    Check ((Probe '[::1]:41641').Path -eq 'Direct') 'Bracketed IPv6 endpoints identify a direct path'
    Check ((Probe '127.0.0.1:99999').Path -eq 'Unknown') 'Invalid endpoint ports cannot become direct evidence'
    Check ((Probe 'DERP(fra)').Path -eq 'Relay / FRA') 'DERP region is reported without exposing its endpoint'
    Check ((Probe 'peer-relay(endpoint:vni:7)').Path -eq 'Peer relay') 'Peer relay is distinct from DERP and direct'
    Check ((Probe 'something-direct-sounding').Path -eq 'Unknown') 'Unrecognized output does not infer a direct path'
    $sequence=Command "pong from fixture via DERP(fra) in 70ms`npong from fixture via 127.0.0.1:41641 in 11ms"
    Check ([Tqr.DiagnosticAnalysis]::ParseProbe($sequence,'disco').Path -eq 'Direct') 'Last valid reply determines the observed path'
    Check ([Tqr.DiagnosticAnalysis]::ParseProbe((Command 'all good'),'disco').Status -eq 'Unknown') 'Exit zero alone is not proof of a peer reply'
    Check ([Tqr.DiagnosticAnalysis]::ParseProbe((Command 'flag provided but not defined: peerapi' 1),'peerapi').Status -eq 'Not supported') 'Unsupported CLI flags are distinct from an unreachable peer'
    $bad=Command 'timeout' 1
    Check ([Tqr.DiagnosticAnalysis]::ParseProbe($bad,'icmp').Status -eq 'Timed out') 'Probe timeout is reported explicitly'
    $bad=Command 'output';$bad.Truncated=$true
    Check ([Tqr.DiagnosticAnalysis]::ParseProbe($bad,'disco').Status -eq 'Incomplete') 'Truncated output cannot yield a successful probe'
    $culture=[Globalization.CultureInfo]::CurrentCulture
    try{[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE');$fraction=[Tqr.DiagnosticAnalysis]::ParseProbe((Command 'pong from fixture via TSMP in 1.5ms'),'tsmp');Check ($fraction.Latency -eq '2 ms') 'Fractional milliseconds parse independently of Windows locale'}finally{[Globalization.CultureInfo]::CurrentCulture=$culture}
    $net=[Tqr.DiagnosticAnalysis]::ParseNetwork((Command "* UDP: true`n* IPv4: yes, 127.0.0.1:123`n* IPv6: no, unavailable`n* Nearest DERP: London`n* MappingVariesByDestIP: false`n* PortMapping: UPnP, NAT-PMP"))
    Check ($net.status -eq 'Complete' -and $net.ipv6 -eq 'Unavailable' -and $net.nearestDerp -eq 'London') 'Explicit network availability tokens parse without copying IP addresses'
    Check ([Tqr.DiagnosticAnalysis]::ParseNetwork((Command '* IPv4: maybe')).ipv4 -eq 'Unknown') 'Unexpected network values remain unknown rather than available'
    $verdict=[Tqr.DiagnosticAnalysis]::Explain($net,$direct,$tunnel,$icmp,$api)
    Check ($verdict.Severity -eq 'good' -and $verdict.Detail -match 'not a bandwidth or RDP test') 'Healthy probe evidence is distinct from a remote application test'
    Check ([Tqr.DiagnosticAnalysis]::Explain($net,(Probe 'DERP(fra)'),$tunnel,$icmp,$api).Severity -eq 'info') 'A functioning relay is not labeled as failed'
    $unknown=New-Object Tqr.DiagnosticProbe
    Check ([Tqr.DiagnosticAnalysis]::Explain($net,$unknown,$tunnel,$icmp,$api).Summary -match 'path was not identified') 'An unknown diagnostic path cannot borrow Direct from another check'
    Check ([Tqr.DiagnosticAnalysis]::Explain($net,$direct,$tunnel,$unknown,$api).Summary -match 'ICMP was not confirmed') 'ICMP failure is not called a broken tunnel'
    Check ([Tqr.DiagnosticAnalysis]::Explain($net,$direct,$tunnel,$icmp,$unknown).Summary -match 'Peer API was not confirmed') 'Optional Peer API failure has a separate explanation'
    Check ([Tqr.DiagnosticAnalysis]::Explain($net,$direct,$unknown,$icmp,$api).Severity -eq 'warn') 'Discovery alone does not prove a working tunnel probe'
    Check ([Tqr.DiagnosticAnalysis]::Explain($net,$unknown,$unknown,$unknown,$unknown).Severity -eq 'warn') 'Missing evidence never becomes no obvious issue'
    Check (-not [Tqr.DiagnosticAnalysis]::ValidPeer('fixture" --extra') -and -not [Tqr.DiagnosticAnalysis]::ValidPeer('-other') -and [Tqr.DiagnosticAnalysis]::ValidPeer('fixture.example')) 'Peer arguments cannot introduce CLI switches or quotes'
    $fake=Join-Path $root 'fixture-cli.exe'
    $fakeCode=@'
using System;
using System.Threading;
public static class FixtureCli {
 public static int Main(string[] a) {
  string mode=Environment.GetEnvironmentVariable("TQR_DIAG_TEST");
  if(mode=="hang"){Thread.Sleep(5000);return 0;}
  if(mode=="large"){for(int i=0;i<3000;i++)Console.WriteLine(new String('x',100));return 0;}
  if(a[0]=="netcheck"){Console.WriteLine("* UDP: true\n* IPv4: yes\n* IPv6: no\n* Nearest DERP: London\n* MappingVariesByDestIP: false\n* PortMapping: UPnP");return 0;}
  string text=String.Join(" ",a);
  if(text.Contains("--peerapi")){Console.WriteLine("hit peerapi of fixture at endpoint in 11ms");return 0;}
  string via=text.Contains("--tsmp")?"TSMP":text.Contains("--icmp")?"ICMP":"127.0.0.1:41641";
  Console.WriteLine("pong from fixture via "+via+" in 11ms");return 0;
 }
}
'@
    Add-Type -TypeDefinition $fakeCode -OutputAssembly $fake -OutputType ConsoleApplication
    $prior=$env:TQR_DIAG_TEST
    try{
        $env:TQR_DIAG_TEST='normal';$r=[Tqr.DiagnosticAnalysis]::Run($fake,'disco','fixture',3000)
        Check ([Tqr.DiagnosticAnalysis]::ParseProbe($r,'disco').Path -eq 'Direct') 'Hidden native child output is collected and parsed'
        $env:TQR_DIAG_TEST='hang';$watch=[Diagnostics.Stopwatch]::StartNew();$r=[Tqr.DiagnosticAnalysis]::Run($fake,'disco','fixture',150)
        Check ($r.TimedOut -and $watch.Elapsed.TotalSeconds -lt 2) 'A stalled owned child is stopped within its time budget'
        $env:TQR_DIAG_TEST='large';$r=[Tqr.DiagnosticAnalysis]::Run($fake,'netcheck','fixture',3000)
        Check ($r.Truncated -and $r.Output.Length -le 65536) 'Retained CLI output is capped and marked incomplete on overflow'
        $env:TQR_DIAG_TEST='normal'
        $worker=[IO.File]::ReadAllText($WorkerPath,[Text.Encoding]::UTF8);$tk=$null;$er=$null
        $wa=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$tk,[ref]$er)
        Check ($er.Count -eq 0) 'Delivered diagnostic worker parses on Windows PowerShell 5.1'
        $vpnNode=@($wa.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Match-VpnSoftware'},$true))
        Check ($vpnNode.Count -eq 1) 'Delivered diagnostics has one fixed-label VPN software matcher'
        . ([scriptblock]::Create($vpnNode[0].Extent.Text))
        $vpnFixture=@(Match-VpnSoftware @('ProtonVPNService','vpnagent','PanGPS','OpenVPNServiceInteractive','pia-service','WireGuardManager','AcmeVPNService','UnrelatedAudioService'))
        Check ($vpnFixture.Count -eq 7 -and
            $vpnFixture -contains 'Proton VPN' -and
            $vpnFixture -contains 'Cisco Secure Client' -and
            $vpnFixture -contains 'GlobalProtect' -and
            $vpnFixture -contains 'OpenVPN' -and
            $vpnFixture -contains 'Private Internet Access' -and
            $vpnFixture -contains 'WireGuard' -and
            $vpnFixture -contains 'Other VPN software') 'Read-only VPN context covers consumer, protocol, corporate and unknown VPN families without raw-name output'
        Check (@(Match-VpnSoftware @('ProtonVPN','ProtonVPNService')|Where-Object {$_ -eq 'Proton VPN'}).Count -eq 1) 'Multiple components from one VPN collapse to one fixed public label'
        Check ($worker -match 'Detected VPN software is not evidence of an active conflict\.') 'VPN presence is explicitly informational and cannot be presented as a diagnosed conflict'
        $cliNode=@($wa.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-TailscaleCli'},$true))
        Check ($cliNode.Count -eq 1) 'Worker CLI discovery has one injectable fixture boundary'
        $replacement="function Get-TailscaleCli { return '"+$fake.Replace("'","''")+"' }"
        $worker=$worker.Remove($cliNode[0].Extent.StartOffset,$cliNode[0].Extent.EndOffset-$cliNode[0].Extent.StartOffset).Insert($cliNode[0].Extent.StartOffset,$replacement)
        $workerFile=Join-Path $root 'Advanced-Diagnostics.ps1';[IO.File]::WriteAllText($workerFile,$worker)
        Copy-Item $LibraryPath (Join-Path $root 'TailscaleQuickRepair.Operations.dll')
        $state=Join-Path $root 'diagnostics-result.json'
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.Arguments='-NoProfile -NonInteractive -File "'+$workerFile+'" -Peer fixture -OutputPath "'+$state+'" -RunId fixture-run'
        $child=[Diagnostics.Process]::Start($psi)
        try{if(-not $child.WaitForExit(25000)){$child.Kill();throw 'Fixture worker timed out'};Check ($child.ExitCode -eq 0) 'Native worker completes without changing live network state'}finally{$child.Dispose()}
        $workerResult=Get-Content $state -Raw | ConvertFrom-Json
        Check ($workerResult.done -and $workerResult.schema -eq 2 -and $workerResult.path -eq 'Direct' -and $workerResult.severity -eq 'good' -and $workerResult.runId -eq 'fixture-run') 'Actual worker replaces progress with the expected structured completed result'
        Check ((Get-Content $state -Raw) -notmatch '127\.0\.0\.1|pong from|fixture-cli') 'Raw endpoints and CLI output are not persisted in the diagnostic report'
    }finally{$env:TQR_DIAG_TEST=$prior}

    $ui=[IO.File]::ReadAllText($UiPath,[Text.Encoding]::UTF8);$tk=$null;$er=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$tk,[ref]$er)
    Check ($er.Count -eq 0) 'Final themed UI parses on Windows PowerShell 5.1'
    $xm=[regex]::Match($ui,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    [xml]$x=$xm.Groups['xaml'].Value;$reader=New-Object Xml.XmlNodeReader $x
    $window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
    $HistoryPanel=$window.FindName('HistoryPanel');$HistoryText=$window.FindName('HistoryText')
    $DetailsPanel=$window.FindName('DetailsPanel');$DetailsPanel.Visibility='Visible';$HistoryPanel.Visibility='Visible'
    $HistoryText.Text=(1..40|ForEach-Object {"Event $_ - Connection check passed"}) -join "`n"
    # Only the synthetic fixture is positioned/resized. Packaged window defaults are unchanged.
    $window.WindowState='Normal'
    $window.ShowInTaskbar=$false;$window.ShowActivated=$true;$window.WindowStartupLocation='Manual'
    $window.Left=40;$window.Top=0;$window.Width=1100;$window.Height=850
    $window.Show()
    function Settle-Layout {
        $frame=New-Object Windows.Threading.DispatcherFrame
        $timer=New-Object Windows.Threading.DispatcherTimer
        $timer.Interval=[TimeSpan]::FromMilliseconds(120)
        $finish=[EventHandler]({param($sender,$eventArgs) $frame.Continue=$false}.GetNewClosure())
        $timer.Add_Tick($finish)
        try{
            $window.UpdateLayout();$timer.Start()
            [Windows.Threading.Dispatcher]::PushFrame($frame)
            $window.UpdateLayout()
        }finally{$timer.Stop();$timer.Remove_Tick($finish)}
    }
    function Save-HistoryImage([string]$Name){
        $width=[int][Math]::Ceiling($HistoryPanel.ActualWidth);$height=[int][Math]::Ceiling($HistoryPanel.ActualHeight)
        if($width -le 0 -or $height -le 0){return}
        $drawing=New-Object Windows.Media.DrawingVisual;$dc=$drawing.RenderOpen()
        $dc.DrawRectangle($window.Background,$null,[Windows.Rect]::new(0,0,$width,$height))
        $brush=[Windows.Media.VisualBrush]::new($HistoryPanel);$brush.AutoLayoutContent=$false
        $dc.DrawRectangle($brush,$null,[Windows.Rect]::new(0,0,$width,$height));$dc.Close()
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($drawing);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $png=[IO.File]::Create((Join-Path $EvidenceDirectory $Name));try{$encoder.Save($png)}finally{$png.Dispose()}
    }
    Settle-Layout
    $HistoryPanel.ApplyTemplate()|Out-Null;Settle-Layout
    & (Join-Path $PSScriptRoot 'trace-history-scroll.ps1') -Window $window -Viewer $HistoryPanel -EvidenceDirectory $EvidenceDirectory
    Settle-Layout
    $bar=$HistoryPanel.Template.FindName('PART_VerticalScrollBar',$HistoryPanel);$bar.ApplyTemplate()|Out-Null
    $track=$bar.Template.FindName('PART_Track',$bar)
    $rail=$bar.Template.FindName('HistoryRail',$bar)
    Save-HistoryImage 'history-scrollbar.png'
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'history-layout.json'),(@{railAlpha=$rail.Background.Color.A;viewport=$HistoryPanel.ViewportHeight;extent=$HistoryPanel.ExtentHeight;scrollable=$HistoryPanel.ScrollableHeight;width=$HistoryPanel.ActualWidth;height=$HistoryPanel.ActualHeight}|ConvertTo-Json))
    Check ($bar.Width -eq 12 -and $null -ne $track -and $track.Thumb.MinHeight -ge 28) 'History uses a slim themed scrollbar with a usable draggable thumb'
    Check ($null -ne $rail -and $rail.Background.Color.A -eq 0) 'History scrollbar has no opaque system-colored rail'
    Check ($HistoryPanel.ScrollableHeight -gt 0) 'Forty retained events have a real scrollable extent'
    $HistoryPanel.ScrollToEnd();Settle-Layout
    $presenter=$HistoryPanel.Template.FindName('PART_ScrollContentPresenter',$HistoryPanel)
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'history-scroll-end.json'),(@{offset=$HistoryPanel.VerticalOffset;presenterOffset=$presenter.VerticalOffset;canScroll=$presenter.CanVerticallyScroll;ownerMatches=[object]::ReferenceEquals($presenter.ScrollOwner,$HistoryPanel);barValue=$bar.Value}|ConvertTo-Json))
    Save-HistoryImage 'history-scroll-end.png'
    Check ($HistoryPanel.VerticalOffset -gt 0) 'History can scroll to the oldest retained event'
    $HistoryPanel.ScrollToHome();Settle-Layout
    Check ($HistoryPanel.VerticalOffset -eq 0) 'History can return to the newest retained event'
    [Windows.Controls.Primitives.ScrollBar]::PageDownCommand.Execute($null,$bar);Settle-Layout
    Check ($HistoryPanel.VerticalOffset -gt 0) 'Scrollbar page commands still reach the ScrollViewer'
    $HistoryPanel.ScrollToTop();Settle-Layout
    $wheel=[Windows.Input.MouseWheelEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,-120)
    $wheel.RoutedEvent=[Windows.Input.Mouse]::MouseWheelEvent;$HistoryPanel.RaiseEvent($wheel);Settle-Layout
    Check ($HistoryPanel.VerticalOffset -gt 0) 'Mouse-wheel scrolling moves the real History viewport'
    $HistoryPanel.ScrollToTop();Settle-Layout
    $drag=[Windows.Controls.Primitives.DragDeltaEventArgs]::new(0,25)
    $track.Thumb.RaiseEvent($drag);Settle-Layout
    Check ($HistoryPanel.VerticalOffset -gt 0) 'Dragging the themed thumb updates the History offset'
    $HistoryPanel.ScrollToTop();Settle-Layout
    Check ($HistoryPanel.Focusable -and $HistoryPanel.PanningMode -eq 'VerticalOnly') 'Keyboard focus and touch panning remain enabled'
    Save-HistoryImage 'history-scrollbar.png'
    $HistoryText.Text='One saved event';Settle-Layout
    Check ($HistoryPanel.ComputedVerticalScrollBarVisibility -eq 'Collapsed') 'Scrollbar disappears when history fits without scrolling'

    foreach($name in @('Get-ObservationCaption','Update-AdvancedObservation','Get-AdvancedValue','Complete-AdvancedDiagnostics','Update-AdvancedDiagnostics')){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Check ($nodes.Count -eq 1) "One actual packaged $name implementation"
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    function Get-Brush([string]$Name){if($Name -eq 'Green'){return [Windows.Media.Brushes]::Green};if($Name -eq 'Amber'){return [Windows.Media.Brushes]::Orange};return [Windows.Media.Brushes]::Gray}
    foreach($name in @('AdvancedObservationLabel','AdvancedDiagnosticsDetailText','AdvancedDiagnosticsSummary','AdvancedDiagnosticsProgress','AdvancedDiagnosticsButton','AdvancedCopyButton','AdvancedNetworkText','AdvancedPeerText','AdvancedEnvironmentText','HeroTitle')){Set-Variable -Name $name -Value ($window.FindName($name))}
    $HeroTitle.Text='Main connection result unchanged';$script:advancedDiagnosticsTimer=$null;$script:advancedDiagnosticsOwnsOperation=$false
    Complete-AdvancedDiagnostics $workerResult
    Check ($AdvancedObservationLabel.Text -notmatch 'not checked|time unavailable' -and $AdvancedObservationLabel.ToolTip.Contains('UTC')) 'Completed diagnostics display their own valid observation time'
    Check ($AdvancedPeerText.Text -match 'Direct' -and $AdvancedPeerText.Text -match 'Latency\s+11 ms' -and $AdvancedDiagnosticsDetailText.Text -match 'point-in-time') 'Actual packaged result renderer shows measured path latency and explanation'
    Check ($script:advancedDiagnosticsReport -match 'Observed UTC:' -and $script:advancedDiagnosticsReport -match 'Network inspection: Complete') 'Copied report includes observation scope and network completeness'
    Check ($HeroTitle.Text -eq 'Main connection result unchanged') 'Optional diagnostics do not replace the main health result'
    $AdvancedDiagnosticsStateFile=$state;$script:advancedDiagnosticsRunId='a-different-run';$AdvancedDiagnosticsSummary.Text='Keep current run'
    Update-AdvancedDiagnostics
    Check ($AdvancedDiagnosticsSummary.Text -eq 'Keep current run') 'A late result from another run is ignored'
    $script:advancedDiagnosticsRunId='fixture-run';Update-AdvancedDiagnostics
    Check ($AdvancedDiagnosticsSummary.Text -eq $workerResult.summary) 'Current-run worker state reaches the final WPF summary'
    Check ([string]$workerResult.vpnState -in @('Detected','NotDetected','Unknown') -and
        ([string]::IsNullOrWhiteSpace([string]$workerResult.vpnLabel) -or [string]$workerResult.vpnLabel -in @('Proton VPN','NordVPN','Mullvad','ExpressVPN','Surfshark','Private Internet Access','Windscribe','IVPN','TunnelBear','CyberGhost','Cloudflare WARP','Mozilla VPN','hide.me','PureVPN','Hotspot Shield','Cisco Secure Client','GlobalProtect','FortiClient VPN','Ivanti Secure Access','OpenVPN','WireGuard','VPN tunnel','Multiple VPNs'))) 'Diagnostics receives only bounded active VPN context'
    Complete-AdvancedDiagnostics $null 'Fixture inspection incomplete'
    Check ($AdvancedDiagnosticsSummary.Text -eq 'Fixture inspection incomplete' -and $AdvancedPeerText.Text -eq 'Unavailable') 'Incomplete inspection clears obsolete diagnostic measurements without changing health'
    Check ($window.FindName('AdvancedDiagnosticsDetailText') -ne $null -and $ui.Contains('VPN software')) 'Diagnostic explanation has one inline slot and honest VPN labeling'
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'diagnostics-polish-results.json'),(@{passed=$true;scope='Native parser, synthetic CLI worker, final WPF layout/events and result renderer; not a live network, touch-hardware or power-loss test';cases=$cases.ToArray()}|ConvertTo-Json -Depth 8))
}catch{
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'diagnostics-polish-results.json'),(@{passed=$false;failure=$_.Exception.Message;cases=$cases.ToArray()}|ConvertTo-Json -Depth 8));throw
}finally{if($window){$window.Close()}}
