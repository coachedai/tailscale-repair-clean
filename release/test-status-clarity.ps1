param(
    [Parameter(Mandatory=$true)][string]$UiText,
    [Parameter(Mandatory=$true)][Collections.Generic.List[object]]$Cases,
    [Parameter(Mandatory=$true)]
    [ValidateSet('PublicRelease','Development','PrivateDevelopment')][string]$ValidationProfile
)
$ErrorActionPreference='Stop'
function Assert-Status([bool]$Value,[string]$Name){
    $Cases.Add([pscustomobject]@{name=('Status clarity: '+$Name);passed=$Value})
    if(-not $Value){throw ('Status presentation test failed: '+$Name)}
    Write-Host ('PASS status clarity: '+$Name)
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($UiText,[ref]$tokens,[ref]$errors)
Assert-Status ($errors.Count -eq 0) 'Final UI parses before extracting presentation functions'
$names=@('Get-ObservationCaption','Update-RemoteObservation','Update-AdvancedObservation',
    'Set-UncheckedDetails','Apply-PassiveStartupDetails','Get-UpdateFailureView','Get-UpdateHttpStatus',
    'Test-PassiveStartupPresentationAllowed','Apply-PassiveStartupPresentation','Update-Diagnostics')
foreach($name in $names){
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    Assert-Status ($nodes.Count -eq 1) ('One packaged '+$name)
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
foreach($name in $names[0..6]){
    $body=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))[0].Extent.Text
    foreach($forbidden in @('Start-Process','Start-Repair','Invoke-AutoRepairMonitorNow','DownloadString','Set-ItemProperty','WriteAllText')){
        if($body.Contains($forbidden)){throw 'Presentation helper contains a forbidden side effect.'}
    }
}
Assert-Status $true 'Presentation helpers do not start probes, repairs, downloads or settings writes'
$expectedPrivate=if($ValidationProfile -ceq 'PrivateDevelopment'){'$true'}else{'$false'}
Assert-Status ($UiText.Contains('$script:statusPrivatePreview='+$expectedPrivate)) 'Private-preview wording is bound to the verified build profile'
$xaml=[regex]::Match($UiText,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
Assert-Status $xaml.Success 'Delivered XAML is available'
Add-Type -AssemblyName PresentationFramework
$xml=[xml]$xaml.Groups['xaml'].Value
$reader=New-Object System.Xml.XmlNodeReader $xml
$viewWindow=$null
$oldShutdown=$global:TqrUiShutdownRequested
try{
    $viewWindow=[Windows.Markup.XamlReader]::Load($reader)
    foreach($name in @('RemoteObservationLabel','AdvancedObservationLabel','DetailClient','DetailService',
        'DetailStartup','DetailBackend','DetailLocalIp','DetailVersion','DetailVpn','DetailPeerName','DetailPeerIp',
        'DetailPeerStatus','DetailRoute','DetailLatency','DetailConnectionTrend','SessionText',
        'LocalAppValue','LocalServiceValue','LocalBackendValue','RemoteStatusValue','RemoteRouteValue','RemoteLatencyValue',
        'DetailDuplicateLocalSummary','DetailDuplicateRemoteSummary')){
        $control=$viewWindow.FindName($name)
        if(-not $control){throw 'Expected packaged presentation control is missing.'}
        Set-Variable -Name $name -Value $control
    }
    Assert-Status $true 'Both observation labels and their actual WPF controls load'
    Assert-Status ($RemoteStatusValue.Text -ceq 'Not checked' -and $RemoteRouteValue.Text -ceq 'Not checked' -and
        $RemoteLatencyValue.Text -ceq 'Not checked') 'Remote summary uses explicit unchecked values instead of placeholder dashes'
    Assert-Status ($DetailDuplicateLocalSummary.Visibility -eq [Windows.Visibility]::Collapsed -and
        $DetailDuplicateRemoteSummary.Visibility -eq [Windows.Visibility]::Collapsed) 'Expanded Details hides values already shown in the summary cards'
    Assert-Status ($DetailStartup.Visibility -eq [Windows.Visibility]::Visible -and
        $DetailLocalIp.Visibility -eq [Windows.Visibility]::Visible -and
        $DetailVersion.Visibility -eq [Windows.Visibility]::Visible -and
        $DetailVpn.Visibility -eq [Windows.Visibility]::Visible -and
        $DetailConnectionTrend.Visibility -eq [Windows.Visibility]::Visible) 'Expanded Details keeps only extra technical and baseline information visible'
    # Only visual dependencies are stubbed; no complete app script is executed.
    function Get-Brush([string]$Name){return [Windows.Media.Brushes]::Gray}
    function Set-Step {param($Dot,$Step,$State)}
    function Set-Badge {param($Badge,$Text,$Value,$Tone)}
    function Update-PassiveTrayStatus {param($Decision)}
    function Update-VpnAwareness {}
    function Show-EngineIssue {param($Engine);throw 'Unexpected maintenance action in a presentation fixture.'}
    $global:TqrUiShutdownRequested=$false
    $script:allowFullExit=$false;$script:repairActive=$false
    $script:updateDownloadActive=$false;$script:pendingProtectedUpdateStarted=$false
    $script:lastData=$null;$script:passiveStartupDetails=$null
    $peerDisplay='fixture-target.invalid'
    $fixtureIp=@('100','100','10','20') -join '.'
    $DetailPeerIp.Text=$peerDisplay
    Update-Diagnostics $null
    Assert-Status ($DetailService.Text -ceq 'Not checked' -and $DetailPeerStatus.Text -ceq 'Not checked' -and
        $RemoteObservationLabel.Text -ceq 'Remote · not checked') 'Untested local and remote details are explicit'
    $health=New-Object Tqr.PassiveStartupObservation
    $health.AppFilesReady=$true;$health.EngineReady=$true;$health.Config='Configured'
    $health.Client='Running';$health.Service='Running';$health.Backend='Running';$health.Startup='Automatic'
    $health.LocalIp=$fixtureIp;$health.Version='1.90.0'
    $decision=[Tqr.PassiveStartupHealth]::Evaluate($health)
    Apply-PassiveStartupPresentation $decision $health $null
    Assert-Status ($LocalAppValue.Text -ceq $DetailClient.Text -and $LocalServiceValue.Text -ceq $DetailService.Text -and
        $LocalBackendValue.Text -ceq $DetailBackend.Text -and $DetailStartup.Text -ceq 'Automatic') 'Actual passive presentation fills summary and detail consistently'
    Assert-Status ($DetailLocalIp.Text -ceq $fixtureIp -and $DetailVersion.Text -ceq '1.90.0' -and
        $DetailPeerIp.Text -ceq $peerDisplay -and $DetailRoute.Text -ceq 'Not checked') 'Passive results show validated local self metadata without inventing peer observations'
    $health.LocalIp='';$health.Version=''
    Apply-PassiveStartupDetails $health
    Assert-Status ($DetailLocalIp.Text -ceq 'Unavailable' -and $DetailVersion.Text -ceq 'Unavailable') 'Completed local observation distinguishes unavailable metadata from an unrun check'
    $health.LocalIp=$fixtureIp;$health.Version='1.90.0'
    Apply-PassiveStartupDetails $health
    Update-Diagnostics $null
    Assert-Status ($DetailService.Text -ceq 'Running' -and $DetailBackend.Text -ceq 'Running') 'Reopening Details preserves the collected passive sample'
    foreach($flag in @('repairActive','updateDownloadActive','pendingProtectedUpdateStarted','allowFullExit')){
        Set-Variable -Scope Script -Name $flag -Value $true
        $DetailService.Text='retained'
        Apply-PassiveStartupDetails $health
        Assert-Status ($DetailService.Text -ceq 'retained') ('Active '+$flag+' blocks a passive detail overwrite')
        Set-Variable -Scope Script -Name $flag -Value $false
    }
    foreach($done in @($false,$true)){
        $script:lastData=[pscustomobject]@{done=$done};$DetailService.Text='full check'
        Apply-PassiveStartupDetails $health
        Assert-Status ($DetailService.Text -ceq 'full check') 'Newer full-check data keeps precedence over cached startup details'
        $DetailLocalIp.Text='older-local';$DetailVersion.Text='older-version';$DetailPeerStatus.Text='remote-retained'
        Apply-PassiveStartupDetails $health -AllowFullCheck
        Assert-Status ($DetailLocalIp.Text -ceq $fixtureIp -and $DetailVersion.Text -ceq '1.90.0' -and
            $DetailPeerStatus.Text -ceq 'remote-retained') 'Explicit manual refresh updates only local details after a full remote check'
    }
    $script:lastData=$null
    $global:TqrUiShutdownRequested=$true;$DetailService.Text='closing'
    Apply-PassiveStartupDetails $health
    Assert-Status ($DetailService.Text -ceq 'closing') 'Shutdown cannot apply cached local details'
    $global:TqrUiShutdownRequested=$false

    $now=[DateTime]::UtcNow
    $mainAt=$now.AddSeconds(-20);$advancedAt=$now.AddSeconds(-5)
    $main=[pscustomobject]@{done=$true;updatedUtc=$mainAt.ToString('o');route='Relay';latency='60 ms'}
    $script:lastData=$main;$script:environmentStale=$false
    $DetailRoute.Text='Relay';$DetailLatency.Text='60 ms'
    Update-RemoteObservation $main
    $mainLabel=$RemoteObservationLabel.Text
    Assert-Status ($mainLabel -ceq ('Remote · '+$mainAt.ToLocalTime().ToString('HH:mm:ss'))) 'Main connection time comes from its own result timestamp'
    $script:supportDiagnosticsState='completed';$script:supportDiagnosticsStale=$false
    $script:supportDiagnosticsData=[pscustomobject]@{done=$true;updatedUtc=$advancedAt.ToString('o');path='Direct';latency='20 ms'}
    Update-AdvancedObservation
    Assert-Status ($AdvancedObservationLabel.Text -ceq ('Advanced diagnostics · '+$advancedAt.ToLocalTime().ToString('HH:mm:ss')) -and
        $RemoteObservationLabel.Text -ceq $mainLabel -and $DetailRoute.Text -ceq 'Relay' -and $DetailLatency.Text -ceq '60 ms' -and
        [object]::ReferenceEquals($main,$script:lastData)) 'Later diagnostics keep a separate timestamp without changing main data or measurements'
    Assert-Status ($RemoteObservationLabel.ToolTip.Contains($mainAt.ToString('yyyy-MM-dd')) -and
        $AdvancedObservationLabel.ToolTip.Contains('UTC')) 'Tooltips retain dates and the UTC observation time'
    $script:environmentStale=$true;Update-RemoteObservation $main
    $script:supportDiagnosticsStale=$true;Update-AdvancedObservation
    Assert-Status ($RemoteObservationLabel.Text.Contains('previous') -and $AdvancedObservationLabel.Text.Contains('previous')) 'Stale observations are marked previous rather than current'
    Update-RemoteObservation ([pscustomobject]@{done=$false;updatedUtc=$mainAt.ToString('o')})
    $script:supportDiagnosticsState='checking';Update-AdvancedObservation
    Assert-Status ($RemoteObservationLabel.Text -ceq 'Remote · checking' -and
        $AdvancedObservationLabel.Text -ceq 'Advanced diagnostics · checking') 'In-progress checks do not retain a completed-result timestamp'
    $script:supportDiagnosticsState='incomplete';Update-AdvancedObservation
    Assert-Status ($AdvancedObservationLabel.Text.EndsWith('incomplete')) 'Failed diagnostics do not reuse an earlier completion time'
    foreach($stamp in @('','not-a-time',[DateTime]::SpecifyKind($mainAt,[DateTimeKind]::Unspecified).ToString('o'),$now.AddMinutes(10).ToString('o'))){
        $caption=Get-ObservationCaption 'Remote' $stamp 'completed' $now
        Assert-Status ($caption.Text -ceq 'Remote · time unavailable') 'Missing, invalid, non-UTC and implausible future timestamps are not replaced with the current time'
    }

    $private=Get-UpdateFailureView 404 $true
    $public=Get-UpdateFailureView 404 $false
    Assert-Status ($private.Status -ceq 'Online updates unavailable for this preview' -and $private.Tone -ceq 'muted') 'Only known private-preview 404 responses use the expected unavailable state'
    Assert-Status ($public.Status -ceq 'Update feed not found' -and $public.Tone -ceq 'warn') 'Public-build 404 responses remain actual errors'
    foreach($code in @(0,401,403,429,500,503)){
        $failure=Get-UpdateFailureView $code $true
        Assert-Status ($failure.Tone -ceq 'warn' -and $failure.Status -cne $private.Status -and
            -not $failure.Status.Contains('up to date')) 'Other failures are not disguised as private-preview availability'
    }
    Assert-Status ((Get-UpdateHttpStatus ([Net.WebException]::new('synthetic transport failure'))) -eq 0 -and
        (Get-UpdateHttpStatus $null) -eq 0) 'Absent HTTP responses are handled without exposing exception text'
    $start=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Start-UpdateCheck'},$true))[0].Extent.Text
    Assert-Status ($start.Contains('DownloadStringTaskAsync') -and $start.Contains('Get-UpdateHttpStatus') -and
        $start.Contains('Get-UpdateFailureView') -and $start.Contains('The GitHub update response could not be validated.')) 'Retry still performs the real check and retains response validation'
    $stop=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Stop-PassiveStartupHealth'},$true))[0].Extent.Text
    Assert-Status ($stop.Contains('$script:passiveStartupDetails=$null')) 'Operation invalidation clears the cached passive detail sample'
}finally{
    $global:TqrUiShutdownRequested=$oldShutdown
    $reader.Close()
    if($viewWindow){$viewWindow.Close()}
}