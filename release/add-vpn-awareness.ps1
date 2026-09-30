param(
    [Parameter(Mandatory=$true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw 'VPN awareness requires the packaged Quick Repair UI.'
}

$text = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)

function Replace-One {
    param([string]$Find,[string]$Replace,[string]$Description)
    $first=$text.IndexOf($Find,[StringComparison]::Ordinal)
    if($first -lt 0){throw ('VPN awareness anchor is missing: '+$Description)}
    if($text.IndexOf($Find,$first+$Find.Length,[StringComparison]::Ordinal) -ge 0){
        throw ('VPN awareness anchor is ambiguous: '+$Description)
    }
    $script:text=$text.Remove($first,$Find.Length).Insert($first,$Replace)
}

function Replace-RegexOnce {
    param([string]$Pattern,[string]$Replace,[string]$Description)
    $regex=New-Object Text.RegularExpressions.Regex($Pattern,[Text.RegularExpressions.RegexOptions]::Singleline)
    $matches=$regex.Matches($text)
    if($matches.Count -ne 1){throw ('VPN awareness '+$Description+' match count: '+$matches.Count)}
    $evaluator=[Text.RegularExpressions.MatchEvaluator]{param($m) return $Replace}
    $script:text=$regex.Replace($text,$evaluator,1)
}

$localGridNew=@'
                                    <Grid Margin="0,12,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="110"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Text="Startup" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="1" Text="Tailscale IP" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="2" Text="Version" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="3" Text="VPN" Foreground="{StaticResource Faint}"/>
                                        <TextBlock x:Name="DetailStartup" Grid.Row="0" Grid.Column="1" Text="Not checked" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailLocalIp" Grid.Row="1" Grid.Column="1" Text="Not checked" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailVersion" Grid.Row="2" Grid.Column="1" Text="Not checked" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailVpn" Grid.Row="3" Grid.Column="1" Text="Not checked"
                                                   Foreground="{StaticResource Value}" TextWrapping="Wrap"
                                                   ToolTip="Read-only detection of active non-Tailscale VPN/tunnel adapters. Quick Repair never changes another VPN."/>
                                    </Grid>
'@
$localPattern='(?s)[ \t]*<Grid Margin="0,12,0,0">.*?<TextBlock Grid\.Row="1" Text="Tailscale IP".*?<TextBlock x:Name="DetailVersion".*?</Grid>'
Replace-RegexOnce $localPattern $localGridNew 'Local details VPN row'

$bindingFind='    $DetailVersion = $window.FindName(''DetailVersion'')'
$bindingReplace=$bindingFind+[Environment]::NewLine+'    $DetailVpn = $window.FindName(''DetailVpn'')'
Replace-One $bindingFind $bindingReplace 'VPN control binding'

Replace-One '$DetailLocalIp,$DetailVersion,$DetailPeerName,$DetailPeerStatus,$DetailRoute,' '$DetailLocalIp,$DetailVersion,$DetailVpn,$DetailPeerName,$DetailPeerStatus,$DetailRoute,' 'unchecked VPN state'

$vpnStateAnchor=@'
    $script:lastReliabilityPollAt = [DateTime]::MinValue
    $script:lastNetworkSignature = ''
    $script:passiveLocalRefreshTimer = $null

    $script:hiddenToTray = $false
'@
$vpnStateReplacement=@'
    $script:lastReliabilityPollAt = [DateTime]::MinValue
    $script:lastNetworkSignature = ''
    $script:passiveLocalRefreshTimer = $null
    $script:lastVpnAwarenessSignature = ''
    $script:lastVpnAwarenessState = ''
    $script:lastVpnAwarenessLabel = ''
    $script:lastVpnTransitionDetected = $false
    $script:trayVpnItem = $null

    $script:hiddenToTray = $false
'@
Replace-One $vpnStateAnchor $vpnStateReplacement 'VPN transition state'

$functions=@'
    function Get-VpnAwarenessSnapshot {
        try {
            Initialize-OperationGate
            return [Tqr.VpnAwareness]::Inspect()
        }
        catch {
            return $null
        }
    }

    function Get-VpnTransitionMessage {
        param(
            [string]$PreviousState,
            [string]$CurrentState,
            [string]$Label
        )

        if([string]::IsNullOrWhiteSpace($PreviousState) -or $PreviousState -eq $CurrentState){
            if($PreviousState -eq 'Detected' -and $CurrentState -eq 'Detected' -and -not [string]::IsNullOrWhiteSpace($Label)){
                return 'VPN changed - ' + $Label
            }
            return ''
        }

        if($PreviousState -eq 'NotDetected' -and $CurrentState -eq 'Detected'){
            if([string]::IsNullOrWhiteSpace($Label)){$Label='VPN tunnel'}
            return 'VPN active - ' + $Label
        }

        if($PreviousState -eq 'Detected' -and $CurrentState -eq 'NotDetected'){
            return 'VPN inactive'
        }

        return ''
    }

    function Get-VpnHistoryCode {
        param([string]$PreviousState,[string]$CurrentState)
        if($PreviousState -eq 'NotDetected' -and $CurrentState -eq 'Detected'){return 'vpn_active'}
        if($PreviousState -eq 'Detected' -and $CurrentState -eq 'NotDetected'){return 'vpn_inactive'}
        if($PreviousState -eq 'Detected' -and $CurrentState -eq 'Detected'){return 'vpn_changed'}
        return ''
    }

    function Update-VpnAwareness {
        param([switch]$RecordTransition)

        $script:lastVpnTransitionDetected=$false

        try {
            $snapshot=Get-VpnAwarenessSnapshot
            if(-not $snapshot -or [string]$snapshot.State -eq 'Unknown'){
                $DetailVpn.Text='Unavailable'
                $DetailVpn.ToolTip='VPN detection could not complete. No VPN or network setting was changed.'
                if($script:trayVpnItem){$script:trayVpnItem.Text='VPN - unavailable'}
                return
            }

            $state=[string]$snapshot.State
            $signature=[string]$snapshot.Signature
            $label=''

            if($state -eq 'Detected'){
                $label=[string]$snapshot.Label
                if([string]::IsNullOrWhiteSpace($label)){$label='VPN tunnel'}
                $DetailVpn.Text='Active ' + [char]0x00B7 + ' ' + $label
                $DetailVpn.ToolTip='An active non-Tailscale VPN/tunnel adapter was detected. This is context only and does not prove a conflict. Quick Repair will not modify it.'
                if($script:trayVpnItem){$script:trayVpnItem.Text='VPN - ' + $label}
            }
            else {
                $DetailVpn.Text='Not detected'
                $DetailVpn.ToolTip='No active non-Tailscale VPN/tunnel adapter was recognised. Detection is best-effort and read-only.'
                if($script:trayVpnItem){$script:trayVpnItem.Text='VPN - not detected'}
            }

            $previousSignature=[string]$script:lastVpnAwarenessSignature
            $previousState=[string]$script:lastVpnAwarenessState

            if($RecordTransition -and
                -not [string]::IsNullOrWhiteSpace($previousSignature) -and
                $previousSignature -cne $signature){
                $script:lastVpnTransitionDetected=$true
                $message=Get-VpnTransitionMessage $previousState $state $label
                if(-not [string]::IsNullOrWhiteSpace($message)){
                    Add-ReliabilityEvent $message
                    $historyCode=Get-VpnHistoryCode $previousState $state
                    if(-not [string]::IsNullOrWhiteSpace($historyCode)){
                        try{[void][Tqr.LocalHistory]::Record($StateDir,$historyCode,-1,-1)}catch{}
                    }
                }
            }

            $script:lastVpnAwarenessSignature=$signature
            $script:lastVpnAwarenessState=$state
            $script:lastVpnAwarenessLabel=$label
        }
        catch {
            try {
                $DetailVpn.Text='Unavailable'
                $DetailVpn.ToolTip='VPN detection could not complete. No VPN or network setting was changed.'
                if($script:trayVpnItem){$script:trayVpnItem.Text='VPN - unavailable'}
            } catch {}
        }
    }

'@
Replace-One '    function Get-NetworkEnvironmentSignature {' ($functions+'    function Get-NetworkEnvironmentSignature {') 'VPN awareness functions'

$detailVersionLine='$DetailVersion.Text=if([string]::IsNullOrWhiteSpace([string]$Health.Version)){''Unavailable''}else{[string]$Health.Version}'
Replace-One $detailVersionLine ($detailVersionLine+[Environment]::NewLine+'        Update-VpnAwareness') 'passive VPN refresh'

$networkSignatureLine='        $script:lastNetworkSignature = Get-NetworkEnvironmentSignature'
Replace-One $networkSignatureLine ($networkSignatureLine+[Environment]::NewLine+'        Update-VpnAwareness') 'startup VPN refresh'

Replace-One "                Mark-CurrentResultStale 'PC resumed from sleep'" ("                Mark-CurrentResultStale 'PC resumed from sleep'"+[Environment]::NewLine+'                Update-VpnAwareness -RecordTransition'+[Environment]::NewLine+'                $autoRepairDelaySeconds=if($script:lastVpnTransitionDetected){15}else{8}') 'resume VPN transition refresh'
Replace-One "                Mark-CurrentResultStale 'Network changed'" ("                Mark-CurrentResultStale 'Network changed'"+[Environment]::NewLine+'                Update-VpnAwareness -RecordTransition'+[Environment]::NewLine+'                $autoRepairDelaySeconds=if($script:lastVpnTransitionDetected){20}else{10}') 'network VPN transition refresh'
Replace-One '                    -DelaySeconds 8' '                    -DelaySeconds $autoRepairDelaySeconds' 'resume VPN coexistence delay'
Replace-One '                    -DelaySeconds 10' '                    -DelaySeconds $autoRepairDelaySeconds' 'network VPN coexistence delay'

$trayCreate='$script:trayCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem(''Check now'')'
$trayCreateNew=@'
$script:trayVpnItem = New-Object System.Windows.Forms.ToolStripMenuItem('VPN - not checked')
        $script:trayVpnItem.Enabled = $false
        $script:trayVpnItem.ForeColor = [System.Drawing.Color]::Gray
        $script:trayCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem('Check now')
'@
Replace-One $trayCreate $trayCreateNew.TrimEnd() 'tray VPN context item'

$trayPlace='        [void]$menu.Items.Add($script:trayFreshnessItem)'
$trayPlaceNew=$trayPlace+[Environment]::NewLine+'        [void]$menu.Items.Add($script:trayVpnItem)'
Replace-One $trayPlace $trayPlaceNew 'tray VPN context placement'

Replace-One '"Version: $($DetailVersion.Text)"' ('"Version: $($DetailVersion.Text)"'+[Environment]::NewLine+'            "VPN: $($DetailVpn.Text)"') 'copied local VPN status'

foreach($required in @(
    'x:Name="DetailVpn"',
    '$DetailVpn = $window.FindName(''DetailVpn'')',
    '[Tqr.VpnAwareness]::Inspect()',
    '[char]0x00B7',
    'Quick Repair will not modify it.',
    'Get-VpnTransitionMessage',
    'Get-VpnHistoryCode',
    '[Tqr.LocalHistory]::Record($StateDir,$historyCode,-1,-1)',
    'Update-VpnAwareness -RecordTransition',
    '$script:lastVpnAwarenessLabel',
    '$script:lastVpnTransitionDetected',
    '$autoRepairDelaySeconds=if($script:lastVpnTransitionDetected){20}else{10}',
    '$script:trayVpnItem',
    '"VPN: $($DetailVpn.Text)"'
)){
    if($text -notmatch [regex]::Escape($required)){throw ('VPN awareness verification failed: '+$required)}
}

[void][scriptblock]::Create($text)
$xamlMatch=[regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
if(-not $xamlMatch.Success){throw 'VPN awareness could not locate packaged XAML.'}
[xml]$xaml=$xamlMatch.Groups['xaml'].Value
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
$reader=New-Object System.Xml.XmlNodeReader $xaml
$window=$null
try{
    $window=[Windows.Markup.XamlReader]::Load($reader)
    if(-not $window -or -not $window.FindName('DetailVpn')){throw 'VPN status control did not load.'}
}finally{
    try{$reader.Close()}catch{}
    try{if($window -is [Windows.Window]){$window.Close()}}catch{}
}

[IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Vendor-neutral read-only VPN awareness added.'
