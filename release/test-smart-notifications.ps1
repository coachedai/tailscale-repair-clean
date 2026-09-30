param([Parameter(Mandatory=$true)][string]$UiPath,[Parameter(Mandatory=$true)][string]$LibraryPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Native Windows PowerShell 5.1 required.' }
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
if (-not ('Tqr.SmartNotifications' -as [type])) { Add-Type -Path $LibraryPath }
$root=Join-Path $env:TEMP ('TQR-NotificationTest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
$time=[DateTime]::UtcNow
function Check([bool]$Value,[string]$Name) {
    if (-not $Value) { throw "FAILED notifications: $Name" }
    $cases.Add([pscustomobject]@{name=$Name;passed=$true}); Write-Host "PASS notifications: $Name"
}
function Center([string]$Name,[bool]$Enabled=$true) {
    $c=New-Object Tqr.SmartNotifications((Join-Path $root $Name),$time.AddSeconds(-10))
    if($Enabled){$null=$c.SetEnabled($true,$time.AddSeconds(-5))}
    return $c
}
try {
    $c=Center 'default' $false
    Check ($c.Settings().Status -eq 'ready' -and -not $c.Settings().Enabled) 'Installing does not opt the user into notifications'
    $r=$c.Prepare('peer_lost',$time.ToString('o'),$time,$true,$true)
    Check ($r.Status -eq 'disabled') 'Disabled preference rejects a meaningful candidate'
    $null=$c.SetEnabled($true,$time)
    $other=New-Object Tqr.SmartNotifications((Join-Path $root 'default'),$time)
    Check $other.Settings().Enabled 'Enabled preference survives a new app instance'
    $r=$other.Prepare('check_healthy',$time.ToString('o'),$time,$true,$true)
    Check ($r.Status -eq 'invalid') 'Routine healthy checks have no notification code'
    foreach($code in @('startup_maintenance','startup_config_attention','startup_tailscale_missing','startup_service_disabled','startup_sign_in','startup_approval','startup_other_user')){
        $description=[Tqr.SmartNotifications]::Describe($code)
        Check ($description -and $description.Warning -and $description.Title -and $description.Body) ('Passive startup notification code is typed and generic: '+$code)
    }
    $r=$other.Prepare('peer_lost',$time.AddSeconds(-1).ToString('o'),$time,$true,$true)
    Check ($r.Status -eq 'stale') 'Previously observed events do not replay on a new launch'
    $r=$other.Prepare('peer_lost',$time.AddMinutes(-11).ToString('o'),$time,$true,$true)
    Check ($r.Status -eq 'stale') 'Old background files do not generate stale notifications'
    $r=$other.Prepare('peer_lost',$time.AddMinutes(1).ToString('o'),$time,$true,$true)
    Check ($r.Status -eq 'stale') 'Future-dated events are not trusted'
    $r=$other.Prepare('peer_lost','not-a-time',$time,$true,$true)
    Check ($r.Status -eq 'invalid') 'Malformed candidate timestamps are rejected'
    $r=$other.Prepare('peer_lost',$time.ToString('o'),$time,$false,$true)
    Check ($r.Status -eq 'suppressed') 'Visible app suppresses redundant notifications'
    $r=$other.Prepare('peer_lost',$time.ToString('o'),$time.AddSeconds(1),$true,$true)
    Check ($r.Status -eq 'duplicate') 'Hiding the app does not replay a foreground event'
    $r=$other.Prepare('peer_recovered',$time.ToString('o'),$time,$true,$false)
    Check ($r.Status -eq 'suppressed') 'Unavailable or quiet Windows shell suppresses alerts'
    $r=$other.Prepare('peer_recovered',$time.ToString('o'),$time,$true,$true)
    Check ($r.Status -eq 'duplicate') 'Quiet-time suppression is not queued for later'
    $c=Center 'rates'
    $r=$c.Prepare('peer_lost',$time.ToString('o'),$time,$true,$true)
    Check ($r.Status -eq 'prepared' -and $r.Warning) 'Valid opted-in background event prepares an actionable prompt'
    $r=$c.Prepare('peer_recovered',$time.AddSeconds(20).ToString('o'),$time.AddSeconds(20),$true,$true)
    Check ($r.Status -eq 'rate_limited') 'Global two-minute cooldown prevents a burst across categories'
    $r=$c.Prepare('peer_lost',$time.AddMinutes(3).ToString('o'),$time.AddMinutes(3),$true,$true)
    Check ($r.Status -eq 'rate_limited') 'Same-category alerts are limited to once per thirty minutes'
    $r=$c.Prepare('update_available',$time.AddMinutes(4).ToString('o'),$time.AddMinutes(4),$true,$true)
    Check ($r.Status -eq 'prepared') 'Another eligible category can alert after global cooldown'
    $r=$c.Prepare('auto_attention',$time.AddMinutes(8).ToString('o'),$time.AddMinutes(8),$true,$true)
    Check ($r.Status -eq 'prepared') 'A third eligible hourly attempt is allowed'
    $r=$c.Prepare('integrity_attention',$time.AddMinutes(12).ToString('o'),$time.AddMinutes(12),$true,$true)
    Check ($r.Status -eq 'rate_limited') 'Maximum three attempts per rolling hour includes all categories'
    $restarted=New-Object Tqr.SmartNotifications((Join-Path $root 'rates'),$time.AddMinutes(14))
    $r=$restarted.Prepare('quality_attention',$time.AddMinutes(15).ToString('o'),$time.AddMinutes(15),$true,$true)
    Check ($r.Status -eq 'rate_limited') 'Restarting cannot reset the hourly budget'
    $null=$restarted.SetEnabled($false,$time.AddMinutes(16));$null=$restarted.SetEnabled($true,$time.AddMinutes(17))
    $r=$restarted.Prepare('quality_attention',$time.AddMinutes(18).ToString('o'),$time.AddMinutes(18),$true,$true)
    Check ($r.Status -eq 'rate_limited') 'Toggling preference cannot reset the budget'
    $r=$restarted.Prepare('quality_attention',$time.AddHours(2).ToString('o'),$time.AddHours(2),$true,$true)
    Check ($r.Status -eq 'prepared') 'Budget becomes available after the rolling window'
    $c=Center 'clock'
    $null=$c.Prepare('peer_lost',$time.AddMinutes(2).ToString('o'),$time.AddMinutes(2),$true,$true)
    $r=$c.Prepare('auto_attention',$time.AddSeconds(5).ToString('o'),$time.AddSeconds(5),$true,$true)
    Check ($r.Status -eq 'clock_changed') 'Clock rollback does not bypass notification rate protection'
    $store=Join-Path $root 'rates\notification-policy.json'
    $raw=Get-Content $store -Raw | ConvertFrom-Json
    Check (@($raw.PSObject.Properties.Name).Count -eq 3 -and @($raw.attempts[0].PSObject.Properties.Name).Count -eq 3) 'Policy persists only schema, preference, typed codes and timestamps'
    Check ((Get-Item $store).Length -le 16384 -and (Get-Content $store -Raw) -notmatch 'fixture|peerIP|token|password|device|message') 'No raw event, target, token or device data is persisted'
    Check (Test-Path (Join-Path $root 'rates\notification-policy.previous.json')) 'Atomic policy update retains one predecessor'
    $c=Center 'broken'
    $bad=Join-Path $root 'broken\notification-policy.json'
    [IO.File]::WriteAllText($bad,'{broken')
    Check ($c.Settings().Status -eq 'unavailable') 'Malformed settings disable notifications rather than guessing a preference'
    $null=$c.SetEnabled($true,$time)
    Check ([IO.File]::ReadAllText($bad) -eq '{broken') 'Unreadable settings are preserved on a failed preference change'
    $c=Center 'locked'
    $gate=Join-Path $root 'locked\notification-policy.gate'
    $held=[IO.File]::Open($gate,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $watch=[Diagnostics.Stopwatch]::StartNew();$r=$c.Prepare('auto_attention',$time.ToString('o'),$time,$true,$true)
        Check ($r.Status -eq 'unavailable' -and $watch.Elapsed.TotalSeconds -lt 2) 'Busy policy fails closed without blocking the UI'
    } finally {$held.Dispose()}
    Check ($c.Settings().Status -eq 'ready') 'Preferences remain readable after temporary contention ends'
    $c=Center 'test'
    $r=$c.Prepare('test',$time.ToString('o'),$time,$false,$true)
    Check ($r.Status -eq 'prepared') 'User-requested test is allowed from the visible app'
    $r=$c.Prepare('test',$time.AddSeconds(1).ToString('o'),$time.AddSeconds(1),$false,$true)
    Check ($r.Status -eq 'rate_limited') 'Test button cannot spam the shell'
    Check ([Tqr.SmartNotifications]::ShellAllowsNotifications() -is [bool]) 'Native Windows quiet-state query returns safely on the runner'

    $text=[IO.File]::ReadAllText($UiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Notification-enabled packaged UI parses on PowerShell 5.1'
    foreach($name in @('Initialize-SmartNotifications','Update-SmartNotificationSettings','Test-SmartNotificationShell','Send-SmartNotificationToShell','Request-SmartNotification','Observe-SmartConnectionNotification','Observe-SmartAutoNotification')) {
        $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Check ($nodes.Count -eq 1) "Exactly one final packaged $name definition"
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    # Replace only the external banner sink and shell availability. Policy, settings,
    # event adapters, WPF controls and click delegates are the real delivered code.
    function Test-SmartNotificationShell { return $script:shellAvailable }
    function Send-SmartNotificationToShell($Prompt) { $script:sent.Add($Prompt); return $true }
    function Get-AutoRepairEnabled { return $true }
    $match=[regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    [xml]$xaml=$match.Groups['xaml'].Value;$reader=New-Object Xml.XmlNodeReader $xaml
    $window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
    $SmartNotificationsCheckBox=$window.FindName('SmartNotificationsCheckBox')
    $SmartNotificationsStatusText=$window.FindName('SmartNotificationsStatusText')
    $TestNotificationButton=$window.FindName('TestNotificationButton')
    $HeroTitle=$window.FindName('HeroTitle');$HeroTitle.Text='Healthy fixture result'
    $StateDir=Join-Path $root 'ui';$OperationsLibraryPath=$LibraryPath
    $script:notificationStartedUtc=[DateTime]::UtcNow.AddMinutes(-1)
    $script:notificationCenter=$null;$script:notificationInitializing=$false;$script:hiddenToTray=$false
    $script:allowFullExit=$false;$global:TqrUiShutdownRequested=$false;$script:shellAvailable=$true
    $script:sent=New-Object 'Collections.Generic.List[object]'
    Initialize-SmartNotifications
    Check (-not $SmartNotificationsCheckBox.IsChecked -and -not $TestNotificationButton.IsEnabled) 'Final packaged controls initialize opt-in and test disabled'
    $assignment=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$notificationChanged'},$true))
    Check ($assignment.Count -eq 1) 'Exactly one actual packaged preference event delegate'
    . ([scriptblock]::Create($assignment[0].Extent.Text))
    $SmartNotificationsCheckBox.Add_Checked($notificationChanged);$SmartNotificationsCheckBox.Add_Unchecked($notificationChanged)
    $SmartNotificationsCheckBox.IsChecked=$true
    Check ($script:notificationCenter.Settings().Enabled -and $TestNotificationButton.IsEnabled) 'Actual WPF enable event saves preference and enables Test'
    $click=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$TestNotificationButton' -and $n.Member.Value -eq 'Add_Click'},$true))
    Check ($click.Count -eq 1) 'Exactly one actual packaged test click event'
    $TestNotificationButton.Add_Click($click[0].Arguments[0].ScriptBlock.GetScriptBlock())
    $TestNotificationButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ($script:sent.Count -eq 1 -and $SmartNotificationsStatusText.Text -match 'Test requested') 'Actual WPF test click requests one typed banner through the sink'
    $TestNotificationButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ($script:sent.Count -eq 1) 'Repeated WPF test click cannot bypass rate limits'
    $SmartNotificationsCheckBox.IsChecked=$false
    $null=Request-SmartNotification 'peer_lost'
    Check ($script:sent.Count -eq 1 -and -not $script:notificationCenter.Settings().Enabled) 'Actual WPF disable event blocks further requests immediately'
    Check ($HeroTitle.Text -eq 'Healthy fixture result') 'Preference and banner handling never modify the main result'

    function Reset-Adapter([string]$Name) {
        $script:notificationStartedUtc=[DateTime]::UtcNow.AddMinutes(-1)
        $script:notificationCenter=New-Object Tqr.SmartNotifications((Join-Path $root $Name),$script:notificationStartedUtc)
        $null=$script:notificationCenter.SetEnabled($true,$script:notificationStartedUtc)
        $script:hiddenToTray=$true;$script:notificationLastPeer='';$script:notificationQualityWarning=$false
        $script:notificationLastAutoStatus='';$script:notificationLastRecovery=''
        $script:sent.Clear()
    }
    Reset-Adapter 'peer-adapter'
    $data=[pscustomobject]@{peerReachable='Reachable';updatedUtc=[DateTime]::UtcNow.ToString('o')}
    $view=[pscustomobject]@{Tone='muted'}
    Observe-SmartConnectionNotification $data $view
    Check ($script:sent.Count -eq 0) 'First healthy completed check is silent through the real adapter'
    $data.peerReachable='Unreachable';$data.updatedUtc=[DateTime]::UtcNow.ToString('o')
    Observe-SmartConnectionNotification $data $view
    Check ($script:sent.Count -eq 1 -and $script:sent[0].Title -match 'Remote check') 'Observed peer loss produces a generic private notification'
    Observe-SmartConnectionNotification $data $view
    Check ($script:sent.Count -eq 1) 'Repeated unchanged loss does not emit a second prompt'
    Reset-Adapter 'auto-adapter'
    $AutoRepairStatePath=Join-Path $root 'auto-fixture.json'
    $repair=[DateTime]::UtcNow.AddSeconds(-20).ToString('o')
    $state=[ordered]@{lastCheckedUtc=[DateTime]::UtcNow.AddSeconds(-10).ToString('o');status='repaired';service='Stopped';client='Running';backend='Unknown';lastRepairUtc=$repair}
    [IO.File]::WriteAllText($AutoRepairStatePath,($state|ConvertTo-Json))
    Observe-SmartAutoNotification
    Check ($script:sent.Count -eq 0) 'Monitor repaired/start-only state is never described as successful recovery'
    $state.status='healthy';$state.service='Running';$state.backend='Unknown'
    [IO.File]::WriteAllText($AutoRepairStatePath,($state|ConvertTo-Json));Observe-SmartAutoNotification
    Check ($script:sent.Count -eq 0) 'Unknown backend cannot confirm background recovery'
    $state.backend='Running';[IO.File]::WriteAllText($AutoRepairStatePath,($state|ConvertTo-Json));Observe-SmartAutoNotification
    Check ($script:sent.Count -eq 1 -and $script:sent[0].Title -eq 'Local recovery confirmed') 'Later explicit healthy monitor result confirms recovery once'
    Observe-SmartAutoNotification
    Check ($script:sent.Count -eq 1) 'Existing local polling cannot repeat the same recovery prompt'
    Reset-Adapter 'shutdown';$script:allowFullExit=$true
    $null=Request-SmartNotification 'auto_attention'
    Check ($script:sent.Count -eq 0) 'No notification is requested after shutdown starts'
    $script:allowFullExit=$false;$script:shellAvailable=$false
    $null=Request-SmartNotification 'peer_lost'
    Check ($script:sent.Count -eq 0) 'Final packaged adapter respects a blocked shell'
    $window.Close()
    $script:notificationCenter=$null
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'smart-notifications-results.json'),(@{passed=$true;scope='Native Windows policy, persistence, shell query and final packaged WPF adapters; visual banner sink is a fixture, not a desktop-delivery claim';cases=$cases.ToArray()}|ConvertTo-Json -Depth 8))
} catch {
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'smart-notifications-results.json'),(@{passed=$false;failure=$_.Exception.Message;cases=$cases.ToArray()}|ConvertTo-Json -Depth 8));throw
}
