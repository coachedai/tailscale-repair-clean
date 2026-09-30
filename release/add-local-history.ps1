param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
$text = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Old,[string]$New) {
    if ([regex]::Matches($script:text,[regex]::Escape($Old)).Count -ne 1) {
        throw ('History transform anchor is missing or duplicated: ' + $Old.Substring(0,[Math]::Min(75,$Old.Length)))
    }
    $script:text = $script:text.Replace($Old,$New)
}
Replace-One '<TextBlock Text="Changes and repair actions from this app session."' '<TextBlock x:Name="ActivityDescriptionText" Text="Changes and repairs this session."'
Replace-One '<Button x:Name="CopyButton" Grid.Column="1" Style="{StaticResource GhostButtonStyle}" Content="Copy"/>' @'
<StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
    <Button x:Name="HistoryButton" Style="{StaticResource GhostButtonStyle}" Content="History"
            Margin="0,0,10,0" AutomationProperties.Name="Show recent local history"/>
    <Button x:Name="CopyButton" Style="{StaticResource GhostButtonStyle}" Content="Copy"/>
</StackPanel>
'@
Replace-One 'Text="No activity yet."/>' @'
Text="No activity yet."/>
<ScrollViewer x:Name="HistoryPanel" Visibility="Collapsed" MaxHeight="170" Margin="0,16,0,0"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <TextBlock x:Name="HistoryText" FontSize="12" LineHeight="20" TextWrapping="Wrap"
               Foreground="{StaticResource Muted}" Text="No saved activity yet."/>
</ScrollViewer>
'@
$historyFunctions = @'
    function Initialize-LocalHistory {
        if (-not ('Tqr.LocalHistory' -as [type])) {
            Add-Type -Path $OperationsLibraryPath -ErrorAction Stop
        }
    }

    function Write-LocalHistoryEvent {
        param([string]$Code,[int]$Before = -1,[int]$After = -1)
        try {
            Initialize-LocalHistory
            if (-not [Tqr.LocalHistory]::Record($StateDir,$Code,$Before,$After)) {
                $script:historyWriteUnavailable = $true
            } else { $script:historyWriteUnavailable = $false }
        } catch { $script:historyWriteUnavailable = $true }
    }

    function Update-LocalHistoryView {
        try {
            Initialize-LocalHistory
            $view = [Tqr.LocalHistory]::Read($StateDir)
            if ($view.Status -ne 'ready') {
                $HistoryText.Text = 'Saved history is unavailable. Existing records were left untouched.'
                $script:historyCopyText = ''
                return
            }
            $lines = @()
            foreach ($entry in @($view.Entries)) {
                $stamp = [DateTime]::ParseExact($entry.utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
                $label = if ($stamp.Date -eq (Get-Date).Date) { $stamp.ToString('HH:mm') } else { $stamp.ToString('dd MMM HH:mm') }
                $lines += $label + ' - ' + [Tqr.LocalHistory]::Describe($entry)
            }
            $HistoryText.Text = if ($lines.Count -gt 0) { $lines -join [Environment]::NewLine } else { 'No saved activity yet.' }
            if ($script:historyWriteUnavailable) { $HistoryText.Text += [Environment]::NewLine + 'The latest event could not be saved.' }
            $script:historyCopyText = $HistoryText.Text
        } catch {
            $HistoryText.Text = 'Saved history is unavailable. Connection checks are unaffected.'
            $script:historyCopyText = ''
        }
    }

    function Record-CompletedHistory {
        param($Data)
        try {
            if (-not $Data -or -not [bool]$Data.done) { return }
            $stamp = [string]$Data.updatedUtc
            if ([string]::IsNullOrWhiteSpace($stamp) -or $stamp -eq $script:historyLastStamp) { return }
            $script:historyLastStamp = $stamp
            $outcome = if ([string]$Data.mode -eq 'success') { 'check_healthy' } else { 'check_attention' }
            if ([bool]$Data.repairPerformed) { Write-LocalHistoryEvent 'repair_completed' }
            elseif ($outcome -ne $script:historyLastOutcome) { Write-LocalHistoryEvent $outcome }
            $script:historyLastOutcome = $outcome
            if ([string]$Data.peerReachable -eq 'Reachable') {
                $route = if ([string]$Data.route -eq 'Direct') { 'Direct' } elseif ([string]$Data.route -like 'Relay*') { 'Relay' } else { 'Unknown' }
                $latency = -1
                if ([string]$Data.latency -match '^([0-9]{1,6})\s*ms$') { $latency = [int]$Matches[1] }
                if ($script:historyLastRoute -and $script:historyLastRoute -ne $route -and $route -ne 'Unknown') {
                    Write-LocalHistoryEvent ('route_' + $route.ToLowerInvariant())
                }
                elseif ($script:historyLastRoute -eq $route -and $script:historyLastLatency -ge 0 -and $latency -ge 0) {
                    $before = [int]$script:historyLastLatency
                    if ($latency - $before -ge 35 -and $latency -ge ([Math]::Max(1,$before)*1.7)) {
                        Write-LocalHistoryEvent 'latency_up' $before $latency
                    }
                    elseif ($before - $latency -ge 25 -and $latency -le ($before*0.7)) {
                        Write-LocalHistoryEvent 'latency_down' $before $latency
                    }
                }
                $script:historyLastRoute = $route
                $script:historyLastLatency = $latency
            }
            if ($script:historyVisible) { Update-LocalHistoryView }
        } catch { $script:historyWriteUnavailable = $true }
    }

'@
# Inject outside all Setup/function-replacement spans. Final native tests execute
# these packaged definitions and events; textual markers alone are insufficient.
Replace-One '    function Add-ReliabilityEvent {' ($historyFunctions + '    function Add-ReliabilityEvent {')
Replace-One "    `$script:connectionEvents = New-Object 'System.Collections.Generic.List[string]'" @'
    $script:historyVisible = $false
    $script:historyWriteUnavailable = $false
    $script:historyLastStamp = ''
    $script:historyLastOutcome = ''
    $script:historyLastRoute = ''
    $script:historyLastLatency = -1
    $script:historyCopyText = ''
    $HistoryButton = $window.FindName('HistoryButton')
    $HistoryPanel = $window.FindName('HistoryPanel')
    $HistoryText = $window.FindName('HistoryText')
    $ActivityDescriptionText = $window.FindName('ActivityDescriptionText')
    $script:connectionEvents = New-Object 'System.Collections.Generic.List[string]'
'@
Replace-One '        Update-ConnectionIntelligence $Data' @'
        Record-CompletedHistory $Data
        Update-ConnectionIntelligence $Data
'@
Replace-One '    $CopyButton.Add_Click({' @'
    $HistoryButton.Add_Click({
        try {
            $script:historyVisible = -not $script:historyVisible
            if ($script:historyVisible) {
                Update-LocalHistoryView
                $HistoryPanel.Visibility = [Windows.Visibility]::Visible
                $SessionText.Visibility = [Windows.Visibility]::Collapsed
                $HistoryButton.Content = 'This session'
                $ActivityDescriptionText.Text = 'Last 40 events, up to 30 days. Stored only on this PC.'
            } else {
                $HistoryPanel.Visibility = [Windows.Visibility]::Collapsed
                $SessionText.Visibility = [Windows.Visibility]::Visible
                $HistoryButton.Content = 'History'
                $ActivityDescriptionText.Text = 'Changes and repairs this session.'
            }
            $CopyButton.Content = 'Copy'
        } catch {}
    })

    $CopyButton.Add_Click({
        if ($script:historyVisible) {
            if ($script:historyCopyText) {
                try { [Windows.Clipboard]::SetText($script:historyCopyText); $CopyButton.Content = 'Copied' } catch {}
            }
            return
        }
'@
Replace-One "        `$script:Peer = `$candidate" @'
        Write-LocalHistoryEvent 'target_changed'
        $script:historyLastRoute = ''
        $script:historyLastOutcome = ''
        $script:historyLastStamp = ''
        $script:connectionSamples.Clear()
        $script:connectionEvents.Clear()
        $script:lastProcessedConnectionStamp = ''
        $script:Peer = $candidate
'@
Replace-One '        Add-ReliabilityEvent $Reason' @'
        Write-LocalHistoryEvent 'environment_changed'
        Add-ReliabilityEvent $Reason
'@
Replace-One '            if ([bool]$result.success) {' @'
            if ([bool]$result.success) {
                Write-LocalHistoryEvent 'update_installed'
'@
Replace-One "                `$UpdateStatusText.Text = 'Update was rolled back'" @'
                Write-LocalHistoryEvent 'update_failed'
                $UpdateStatusText.Text = 'Update needs attention'
'@
Replace-One "                `$GuardianStatusText.Text = 'Healthy'" @'
                Write-LocalHistoryEvent 'integrity_ok'
                $GuardianStatusText.Text = 'Healthy'
'@
Replace-One "                `$GuardianStatusText.Text = if (`$issues.Count -eq 1) {" @'
                Write-LocalHistoryEvent 'integrity_attention'
                $GuardianStatusText.Text = if ($issues.Count -eq 1) {
'@

# Earlier build-time here-strings can be read using the Windows ANSI code page.
# Normalize only the four known progress labels in the FINAL delivered script,
# before its SHA-256 is generated. No handler logic or error text is replaced.
foreach ($label in @(
    @{ Control = 'UpdateNowButton.Content'; Text = 'Updating'; Count = 2 },
    @{ Control = 'UpdateStatusText.Text'; Text = 'Installing system update'; Count = 1 },
    @{ Control = 'UpdateStatusText.Text'; Text = 'Installing update'; Count = 1 }
)) {
    $pattern = '(?m)^(?<prefix>\s*\$' + [regex]::Escape($label.Control) + '\s*=\s*)''' +
        [regex]::Escape($label.Text) + '[^''\r\n]*''\r?$'
    $matches = [regex]::Matches($text,$pattern)
    if ($matches.Count -ne [int]$label.Count) {
        throw ('Final update label coverage changed: ' + $label.Text)
    }
    $replacement = [string]$label.Text + '...'
    $text = [regex]::Replace($text,$pattern,[Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $match.Groups['prefix'].Value + "'" + $replacement + "'"
    })
}
[void][scriptblock]::Create($text)
[IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Local history and clean progress labels added to the final packaged UI.'
