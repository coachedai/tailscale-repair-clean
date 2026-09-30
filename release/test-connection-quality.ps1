param([Parameter(Mandatory=$true)][string]$UiPath,[Parameter(Mandatory=$true)][string]$LibraryPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Native Windows PowerShell 5.1 required.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if (-not ('Tqr.ConnectionQuality' -as [type])) { Add-Type -Path $LibraryPath }
$cases=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAILED connection quality: $Name" }
    $cases.Add([pscustomobject]@{name=$Name;passed=$true}); Write-Host "PASS quality: $Name"
}
$clock=[DateTime]::UtcNow.AddMinutes(-10)
$script:sequence=0
function Observe($Tracker,[string]$Route,[string]$Latency,[string]$Status='Reachable',[string]$Target='fixture') {
    $script:sequence++
    $at=$clock.AddSeconds($script:sequence)
    $Tracker.Observe($Target,$true,$at.ToString('o'),$Status,$Route,$Latency,[DateTime]::UtcNow)
}
try {
    $q=New-Object Tqr.ConnectionQuality
    $v=Observe $q 'Direct' '10 ms'
    Check ($v.ComparableCount -eq 1 -and $v.Tone -eq 'muted' -and $v.Summary -notmatch 'stable') 'First check does not claim stability or continuous monitoring'
    $null=Observe $q 'Direct' '11 ms';$v=Observe $q 'Direct' '12 ms'
    Check ($v.ComparableCount -eq 3 -and $v.Median -eq 11) 'Three comparable checks establish a median baseline'
    $v=Observe $q 'Direct' '80 ms'
    Check ($v.Tone -eq 'muted' -and -not $v.EventCode) 'One high reading does not emit a sustained-quality warning'
    $v=Observe $q 'Direct' '85 ms'
    Check ($v.Tone -eq 'warn' -and $v.EventCode -eq 'latency_up' -and $v.Median -eq 11) 'Two high checks report the increase without inflating the good baseline'
    $v=Observe $q 'Direct' '90 ms'
    Check ($v.Tone -eq 'warn' -and -not $v.EventCode) 'Persistent elevation does not repeat the same session event'
    $v=Observe $q 'Direct' '11 ms'
    Check ($v.Tone -eq 'good' -and $v.Summary -match 'returned') 'Returning to the prior range reports recovery'
    $v=Observe $q 'Relay · FRA' '50 ms'
    Check ($v.ComparableCount -eq 1 -and $v.Median -eq 50 -and $v.EventCode -eq 'route_relay') 'A relay does not inherit the direct-path baseline'
    $null=Observe $q 'Relay · FRA' '51 ms';$v=Observe $q 'Relay · FRA' '49 ms'
    Check ($v.Tone -eq 'muted' -and $v.ComparableCount -eq 3) 'An ordinary reachable relay is not itself a quality failure'
    $v=Observe $q 'Relay · LHR' '9 ms'
    Check ($v.ComparableCount -eq 1 -and $v.Median -eq 9) 'Different relay locations have independent baselines'
    $v=Observe $q 'Peer relay' '16 ms'
    Check ($v.ComparableCount -eq 1 -and $v.EventText -match 'Peer relay') 'Peer relays are distinct from DERP relay observations'
    $v=Observe $q 'Unknown' '15 ms'
    Check ($v.Summary -match 'path not measured' -and $v.ComparableCount -eq 0) 'An unknown path is not reported as a measured stable path'
    $v=Observe $q 'Direct' 'unknown'
    Check ($v.Summary -match 'latency not measured') 'Unknown latency never becomes zero milliseconds'
    $v=Observe $q 'Direct' '0 ms'
    Check ($v.Summary -notmatch 'not measured') 'A real zero-millisecond observation remains valid'
    Check ([double]::IsNaN([Tqr.ConnectionQuality]::ParseLatency('25 Mbps')) -and [double]::IsNaN([Tqr.ConnectionQuality]::ParseLatency('-1 ms'))) 'Latency parser rejects unrelated units and negative values'
    $oldCulture=[Globalization.CultureInfo]::CurrentCulture
    try {
        [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE')
        Check ([Tqr.ConnectionQuality]::ParseLatency('1.5 ms') -eq 1.5) 'Decimal latency parsing is independent of the Windows locale'
    } finally {[Globalization.CultureInfo]::CurrentCulture=$oldCulture}
    $at=$clock.AddSeconds($script:sequence).ToString('o');$count=$q.Count
    $duplicate=$q.Observe('fixture',$true,$at,'Reachable','Direct','0 ms',[DateTime]::UtcNow)
    Check ($null -eq $duplicate -and $q.Count -eq $count) 'Repeated rendering does not create another sample'
    $ignored=$q.Observe('fixture',$false,[DateTime]::UtcNow.ToString('o'),'Reachable','Direct','1 ms',[DateTime]::UtcNow)
    Check ($null -eq $ignored -and $q.Count -eq $count) 'In-progress results do not enter the baseline'
    $ignored=$q.Observe('fixture',$true,$clock.ToString('o'),'Reachable','Direct','1 ms',[DateTime]::UtcNow)
    Check ($null -eq $ignored -and $q.Count -eq $count) 'An out-of-order result cannot replace a newer observation'
    $ignored=$q.Observe('fixture',$true,[DateTime]::UtcNow.AddHours(1).ToString('o'),'Reachable','Direct','1 ms',[DateTime]::UtcNow)
    Check ($null -eq $ignored -and $q.Count -eq $count) 'Future-dated state is not trusted'
    $ignored=$q.Observe('fixture',$true,[DateTime]::UtcNow.AddHours(-1).ToString('o'),'Reachable','Direct','1 ms',[DateTime]::UtcNow)
    Check ($null -eq $ignored -and $q.Count -eq $count) 'Old state outside the comparison horizon is ignored'
    $v=Observe $q 'Direct' '200 ms' 'Reachable' 'new-fixture'
    Check ($q.Count -eq 1 -and $v.ComparableCount -eq 1) 'Changing target does not reuse another target baseline'
    $resetAt=[DateTime]::UtcNow;$q.Reset($resetAt)
    $ignored=$q.Observe('new-fixture',$true,$resetAt.AddSeconds(-1).ToString('o'),'Reachable','Direct','1 ms',$resetAt)
    Check ($null -eq $ignored -and $q.Count -eq 0) 'Network reset rejects delayed pre-change results'
    $v=$q.Observe('new-fixture',$true,$resetAt.AddSeconds(1).ToString('o'),'Reachable','Direct','20 ms',$resetAt.AddSeconds(1))
    Check ($q.Count -eq 1 -and $v.ComparableCount -eq 1) 'Fresh post-change measurement starts its own baseline'
    $v=$q.Observe('new-fixture',$true,$resetAt.AddMinutes(31).ToString('o'),'Reachable','Direct','21 ms',$resetAt.AddMinutes(31))
    Check ($q.Count -eq 1 -and $v.ComparableCount -eq 1) 'A long observation gap cannot retain an expired baseline'
    $q=New-Object Tqr.ConnectionQuality
    $null=Observe $q 'Direct' '10 ms';$v=Observe $q '' '' 'Unreachable'
    Check ($v.Summary -match 'Not reachable' -and $v.EventText) 'Reachability loss is described from an actual completed check'
    $v=Observe $q 'Direct' '10 ms'
    Check ($v.Summary -match 'reachable again') 'A measured peer recovery is distinguished from an online hint'
    $q=New-Object Tqr.ConnectionQuality
    foreach($route in @('Direct','Relay · FRA','Direct','Relay · FRA')) {$v=Observe $q $route '20 ms'}
    Check ($v.Summary -match 'Repeated relay fallback' -and $v.RouteChanges -eq 3) 'Repeated fallbacks describe observed checks, not continuous downtime'
    $v=Observe $q 'Direct' '10 ms'
    Check ($v.Summary -match 'Route switched' -and $v.RouteChanges -eq 4) 'Frequent observed path switching is made visible'
    1..40 | ForEach-Object {$null=Observe $q 'Direct' '10 ms'}
    Check ($q.Count -eq 20) 'Session memory stays bounded to twenty observations'
    $q=New-Object Tqr.ConnectionQuality
    foreach($latency in @('100 ms','101 ms','99 ms','30 ms','29 ms')) {$v=Observe $q 'Direct' $latency}
    Check ($v.EventCode -eq 'latency_down' -and $v.Tone -eq 'good') 'A confirmed latency improvement is reported'

    # Render the final delivered XAML and run the actual packaged presentation
    # functions. No Tailscale CLI, service, network or task is executed here.
    $text=[IO.File]::ReadAllText($UiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Quality-enabled final package parses on Windows PowerShell 5.1'
    foreach($name in @('Get-ObservationCaption','Update-AdvancedObservation','Set-ConnectionInsight','Add-ConnectionEvent','Update-ConnectionIntelligence','Reset-ConnectionQuality','Observe-SmartConnectionNotification','Request-SmartNotification')) {
        $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Check ($nodes.Count -eq 1) "Exactly one final $name function remains after transforms"
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    function Get-Brush([string]$Name) {
        if($Name -eq 'Green'){return [Windows.Media.Brushes]::MediumAquamarine}
        if($Name -eq 'Amber'){return [Windows.Media.Brushes]::Orange}
        return [Windows.Media.Brushes]::Gray
    }
    $xamlMatch=[regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    [xml]$xaml=$xamlMatch.Groups['xaml'].Value
    $reader=New-Object Xml.XmlNodeReader $xaml;$window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
    $ConnectionInsightText=$window.FindName('ConnectionInsightText');$DetailConnectionTrend=$window.FindName('DetailConnectionTrend')
    $HeroTitle=$window.FindName('HeroTitle');$HeroTitle.Text='Fixture healthy result'
    $OperationsLibraryPath=$LibraryPath;$Peer='fixture-ui'
    $script:connectionQuality=$null;$script:connectionEvents=New-Object 'Collections.Generic.List[string]'
    $script:lastConnectionInsight=''
    function Ui-Result([int]$N,[string]$Latency='11 ms',[string]$Route='Direct',[string]$PeerKey='fixture-ui') {
        [pscustomobject]@{done=$true;updatedUtc=$clock.AddMinutes(2).AddSeconds($N).ToString('o');peer=$PeerKey;peerReachable='Reachable';route=$Route;latency=$Latency}
    }
    1..3 | ForEach-Object {Update-ConnectionIntelligence (Ui-Result $_)}
    Check ($DetailConnectionTrend.Text -match 'Typical 11 ms' -and $ConnectionInsightText.Text -match 'baseline ready') 'Actual packaged WPF summary and baseline show different useful information'
    Check ($HeroTitle.Text -eq 'Fixture healthy result') 'Connection analysis cannot overwrite the main health result'
    Update-ConnectionIntelligence (Ui-Result 4 '90 ms');Update-ConnectionIntelligence (Ui-Result 5 '95 ms')
    Check ($ConnectionInsightText.Text -match 'above baseline' -and $HeroTitle.Text -eq 'Fixture healthy result') 'A quality warning stays secondary to actual reachability'
    $savedCount=$script:connectionQuality.Count
    Update-ConnectionIntelligence (Ui-Result 6 '2 ms' 'Direct' 'old-fixture')
    Check ($script:connectionQuality.Count -eq $savedCount) 'Packaged UI rejects state belonging to an old target'
    $AdvancedObservationLabel=$window.FindName('AdvancedObservationLabel')
    Check ($null -ne $AdvancedObservationLabel) 'Final diagnostics observation label exists'
    $script:supportDiagnosticsState='completed';$script:supportDiagnosticsStale=$false
    $script:supportDiagnosticsData=[pscustomobject]@{updatedUtc=[DateTime]::UtcNow.ToString('o')}
    Update-AdvancedObservation
    Reset-ConnectionQuality -Stale
    Check ($AdvancedObservationLabel.Text.Contains('previous')) 'Network changes mark the separate diagnostics observation as previous'
    Check ($script:connectionQuality.Count -eq 0 -and $DetailConnectionTrend.Text -eq 'Waiting for a fresh check') 'Packaged network reset clears comparisons and labels stale evidence'
    Check ($ConnectionInsightText.MinHeight -ge 18) 'Insight retains reserved height instead of collapsing the card'
    Check ($text.Contains('Text="Recent"') -and $ConnectionInsightText.ToolTip -match 'not packet jitter') 'Recent trend labeling explains the scope of the observations'
    $window.Close()
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'connection-quality-results.json'),(@{passed=$true;scope='Native .NET observation analysis and final packaged WPF functions; no live network or services';cases=$cases.ToArray()}|ConvertTo-Json -Depth 8))
} catch {
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'connection-quality-results.json'),(@{passed=$false;failure=$_.Exception.Message;cases=$cases.ToArray()}|ConvertTo-Json -Depth 8)); throw
}
