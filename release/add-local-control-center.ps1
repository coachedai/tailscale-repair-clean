param(
    [Parameter(Mandatory=$true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw 'Local control center requires the packaged Quick Repair UI.'
}

$text = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)

function Replace-One {
    param(
        [Parameter(Mandatory=$true)][string]$Find,
        [Parameter(Mandatory=$true)][string]$Replace,
        [Parameter(Mandatory=$true)][string]$Description
    )

    $first = $text.IndexOf($Find,[StringComparison]::Ordinal)
    if ($first -lt 0) {
        throw ('Local control center anchor is missing: ' + $Description)
    }
    if ($text.IndexOf($Find,$first + $Find.Length,[StringComparison]::Ordinal) -ge 0) {
        throw ('Local control center anchor is ambiguous: ' + $Description)
    }

    $script:text = $text.Remove($first,$Find.Length).Insert($first,$Replace)
}

# Move the existing read-only local refresh out of Automatic Repair and into
# Local details. This reuses the proven RC7 handler; no repair authority is added.
$buttonPattern = '(?s)[ \t]*<Button\s*\r?\n[ \t]*x:Name="AutoRepairCheckNowButton".*?Content="Check local health now"\s*/>\r?\n'
$buttonMatches = [regex]::Matches($text,$buttonPattern)
if ($buttonMatches.Count -ne 1) {
    throw ('Expected one packaged local refresh button; found ' + $buttonMatches.Count + '.')
}
$text = $text.Remove($buttonMatches[0].Index,$buttonMatches[0].Length)

$localHeader = '<TextBlock Text="Local details" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>'
$localHeaderReplacement = @'
<Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Text="Local details" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                                            <Button
                                                x:Name="AutoRepairCheckNowButton"
                                                AutomationProperties.Name="Refresh local Tailscale status"
                                                AutomationProperties.HelpText="Refreshes local Tailscale health without checking a remote device or making repairs."
                                                Margin="0,0,10,0"
                                                Style="{StaticResource GhostButtonStyle}"
                                                Content="Refresh"/>
                                            <Button
                                                x:Name="OpenTailscaleButton"
                                                AutomationProperties.Name="Open Tailscale"
                                                AutomationProperties.HelpText="Opens the installed Tailscale app without changing network settings."
                                                Style="{StaticResource GhostButtonStyle}"
                                                Content="Open Tailscale"/>
                                        </StackPanel>
                                    </Grid>
'@
Replace-One -Find $localHeader -Replace $localHeaderReplacement.TrimEnd() -Description 'Local details header'

$bindingAnchor = '    $AutoRepairCheckNowButton = $window.FindName(''AutoRepairCheckNowButton'')'
$bindingReplacement = @'
    $AutoRepairCheckNowButton = $window.FindName('AutoRepairCheckNowButton')
    $OpenTailscaleButton = $window.FindName('OpenTailscaleButton')
'@
Replace-One -Find $bindingAnchor -Replace $bindingReplacement.TrimEnd() -Description 'local refresh binding'

$eventAnchor = '    $AutoRepairCheckNowButton.Add_Click({'
$eventReplacement = @'
    $OpenTailscaleButton.Add_Click({
        Open-TailscaleContextually
    })

    $AutoRepairCheckNowButton.Add_Click({
'@
Replace-One -Find $eventAnchor -Replace $eventReplacement.TrimEnd() -Description 'local refresh click handler'

# Keep the compact Local-details action compact while the existing asynchronous
# refresh runs and when it returns to idle.
$oldIdle = '$AutoRepairCheckNowButton.Content=''Check local health now'''
$idleCount = [regex]::Matches($text,[regex]::Escape($oldIdle)).Count
if ($idleCount -lt 1) {
    throw 'Local refresh idle-state label was not found.'
}
$text = $text.Replace($oldIdle,'$AutoRepairCheckNowButton.Content=''Refresh''')
$text = $text.Replace('$AutoRepairCheckNowButton.Content=''Checking local health…''','$AutoRepairCheckNowButton.Content=''Refreshing…''')

# A read-only local refresh follows network/VPN adapter changes and resume after
# a short debounce. It cannot probe the selected peer or authorize repair.
$stateAnchor = @'
    $script:lastReliabilityPollAt = [DateTime]::MinValue
    $script:lastNetworkSignature = ''

    $script:hiddenToTray = $false
'@
$stateReplacement = @'
    $script:lastReliabilityPollAt = [DateTime]::MinValue
    $script:lastNetworkSignature = ''
    $script:passiveLocalRefreshTimer = $null

    $script:hiddenToTray = $false
'@
Replace-One -Find $stateAnchor -Replace $stateReplacement.TrimEnd() -Description 'reliability timer state'

$registerAnchor = '    function Register-ReliabilityWatchers {'
$queueFunction = @'
    function Queue-PassiveLocalRefresh {
        param([int]$DelaySeconds = 4)

        try {
            if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }
            if ($DelaySeconds -gt 15) { $DelaySeconds = 15 }

            if ($script:passiveLocalRefreshTimer) {
                try { $script:passiveLocalRefreshTimer.Stop() } catch {}
                $script:passiveLocalRefreshTimer = $null
            }

            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromSeconds($DelaySeconds)
            $timer.Add_Tick({
                $current = $script:passiveLocalRefreshTimer
                if ($current) {
                    try { $current.Stop() } catch {}
                }
                $script:passiveLocalRefreshTimer = $null

                try {
                    if (Test-PassiveStartupPresentationAllowed -AllowFullCheck) {
                        [void](Invoke-PassiveStartupHealth -Refresh)
                    }
                }
                catch {}
            })

            $script:passiveLocalRefreshTimer = $timer
            $timer.Start()
        }
        catch {}
    }

    function Register-ReliabilityWatchers {
'@
Replace-One -Find $registerAnchor -Replace $queueFunction.TrimEnd() -Description 'passive local refresh queue'

$resumeAnchor = "                Mark-CurrentResultStale 'PC resumed from sleep'"
$resumeReplacement = @'
                Mark-CurrentResultStale 'PC resumed from sleep'
                Queue-PassiveLocalRefresh -DelaySeconds 5
'@
Replace-One -Find $resumeAnchor -Replace $resumeReplacement.TrimEnd() -Description 'resume refresh trigger'

$networkAnchor = "                Mark-CurrentResultStale 'Network changed'"
$networkReplacement = @'
                Mark-CurrentResultStale 'Network changed'
                Queue-PassiveLocalRefresh -DelaySeconds 4
'@
Replace-One -Find $networkAnchor -Replace $networkReplacement.TrimEnd() -Description 'network refresh trigger'

$unregisterAnchor = @'
    function Unregister-ReliabilityWatchers {
        $script:lastReliabilityPollAt = [DateTime]::MinValue
        $script:lastNetworkSignature = ''
    }
'@
$unregisterReplacement = @'
    function Unregister-ReliabilityWatchers {
        $script:lastReliabilityPollAt = [DateTime]::MinValue
        $script:lastNetworkSignature = ''
        if ($script:passiveLocalRefreshTimer) {
            try { $script:passiveLocalRefreshTimer.Stop() } catch {}
            $script:passiveLocalRefreshTimer = $null
        }
    }
'@
Replace-One -Find $unregisterAnchor -Replace $unregisterReplacement.TrimEnd() -Description 'reliability watcher cleanup'

# Add an immediate official-app shortcut to the tray. It uses the same bounded
# Program Files path as the existing contextual Open Tailscale action.
$trayCreateAnchor = @'
        $script:trayCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem('Check now')
        $script:trayCopyStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Copy status')
'@
$trayCreateReplacement = @'
        $script:trayCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem('Check now')
        $script:trayOpenTailscaleItem = New-Object System.Windows.Forms.ToolStripMenuItem('Open Tailscale')
        $script:trayCopyStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Copy status')
'@
Replace-One -Find $trayCreateAnchor -Replace $trayCreateReplacement.TrimEnd() -Description 'tray Tailscale action creation'

$trayItemsAnchor = @'
        [void]$menu.Items.Add($script:trayCheckItem)
        [void]$menu.Items.Add($script:trayCopyStatusItem)
'@
$trayItemsReplacement = @'
        [void]$menu.Items.Add($script:trayCheckItem)
        [void]$menu.Items.Add($script:trayOpenTailscaleItem)
        [void]$menu.Items.Add($script:trayCopyStatusItem)
'@
Replace-One -Find $trayItemsAnchor -Replace $trayItemsReplacement.TrimEnd() -Description 'tray Tailscale action placement'

$trayEventAnchor = '        $script:trayCopyStatusItem.Add_Click({'
$trayEventReplacement = @'
        $script:trayOpenTailscaleItem.Add_Click({
            $window.Dispatcher.BeginInvoke(
                [Action]{
                    Open-TailscaleContextually
                }
            ) | Out-Null
        })

        $script:trayCopyStatusItem.Add_Click({
'@
Replace-One -Find $trayEventAnchor -Replace $trayEventReplacement.TrimEnd() -Description 'tray Tailscale action handler'

# Remove a stale major-version reference from the maintenance fallback.
$text = $text.Replace(
    'The maintenance component is missing. Reinstall Quick Repair 2.0 to restore it.',
    'The maintenance component is missing. Reinstall Quick Repair to restore it.'
)

foreach ($required in @(
    'x:Name="OpenTailscaleButton"',
    'Content="Refresh"',
    'Queue-PassiveLocalRefresh -DelaySeconds 4',
    'Queue-PassiveLocalRefresh -DelaySeconds 5',
    'Invoke-PassiveStartupHealth -Refresh',
    '$script:trayOpenTailscaleItem',
    'Open-TailscaleContextually'
)) {
    if ($text -notmatch [regex]::Escape($required)) {
        throw ('Local control center verification failed: ' + $required)
    }
}

if ($text -match [regex]::Escape('Quick Repair 2.0')) {
    throw 'A stale maintenance version label remains in the packaged UI.'
}

[void][scriptblock]::Create($text)
$xamlMatch = [regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
if (-not $xamlMatch.Success) {
    throw 'Local control center could not locate packaged XAML.'
}

[xml]$xamlDocument = $xamlMatch.Groups['xaml'].Value
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
$reader = New-Object System.Xml.XmlNodeReader $xamlDocument
$window = $null
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
    if (-not $window) { throw 'Local control center WPF validation returned no Window.' }
    if (-not $window.FindName('AutoRepairCheckNowButton')) { throw 'Local refresh control is missing.' }
    if (-not $window.FindName('OpenTailscaleButton')) { throw 'Open Tailscale control is missing.' }
}
finally {
    try { $reader.Close() } catch {}
    try { if ($window -is [System.Windows.Window]) { $window.Close() } } catch {}
}

[IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Local control center and smart read-only refresh added.'
