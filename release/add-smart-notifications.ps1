param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$script:text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Old,[string]$New) {
    if ([regex]::Matches($script:text,[regex]::Escape($Old)).Count -ne 1) { throw ('Notification anchor missing or duplicated: ' + $Old.Substring(0,[Math]::Min($Old.Length,100))) }
    $script:text=$script:text.Replace($Old,$New)
}
$old=@'
                                            Content="Check local health now"/>
                                    </StackPanel>
'@
$new=@'
                                            Content="Check local health now"/>
                                        <DockPanel Margin="0,14,0,0" LastChildFill="True">
                                            <Button x:Name="TestNotificationButton" DockPanel.Dock="Right" Content="Test"
                                                Style="{StaticResource GhostButtonStyle}" IsEnabled="False"
                                                AutomationProperties.Name="Test Smart notifications"/>
                                            <CheckBox x:Name="SmartNotificationsCheckBox" Content="Smart notifications"
                                                FontSize="12" Foreground="{StaticResource Value}" VerticalAlignment="Center"
                                                AutomationProperties.Name="Smart notifications"
                                                AutomationProperties.HelpText="Optional alerts for meaningful events while Quick Repair is in the tray. No extra network checks."/>
                                        </DockPanel>
                                        <TextBlock x:Name="SmartNotificationsStatusText" Margin="22,4,0,0" FontSize="10.5"
                                            Foreground="{StaticResource Faint}" TextWrapping="Wrap"
                                            Text="Off. Only meaningful events, never routine healthy checks."/>
                                    </StackPanel>
'@
Replace-One $old $new
Replace-One "    `$HistoryButton = `$window.FindName('HistoryButton')" @'
    $SmartNotificationsCheckBox=$window.FindName('SmartNotificationsCheckBox')
    $SmartNotificationsStatusText=$window.FindName('SmartNotificationsStatusText')
    $TestNotificationButton=$window.FindName('TestNotificationButton')
    $script:notificationCenter=$null
    $script:notificationInitializing=$false
    $script:notificationStartedUtc=[DateTime]::UtcNow
    $script:notificationLastPeer=''
    $script:notificationQualityWarning=$false
    $script:notificationLastAutoStatus=''
    $script:notificationLastRecovery=''
    $script:notificationUpdateCode=0
    $HistoryButton = $window.FindName('HistoryButton')
'@
Replace-One '    function Write-LocalHistoryEvent {' @'
    function Initialize-SmartNotifications {
        try {
            if (-not ('Tqr.SmartNotifications' -as [type])) { Add-Type -Path $OperationsLibraryPath -ErrorAction Stop }
            if (-not $script:notificationCenter) {
                $script:notificationCenter=New-Object Tqr.SmartNotifications($StateDir,$script:notificationStartedUtc)
            }
            Update-SmartNotificationSettings
        } catch {
            $SmartNotificationsStatusText.Text='Notifications unavailable. Connection checks are unaffected.'
            $TestNotificationButton.IsEnabled=$false
        }
    }

    function Update-SmartNotificationSettings {
        $script:notificationInitializing=$true
        try {
            $settings=$script:notificationCenter.Settings()
            $SmartNotificationsCheckBox.IsChecked=($settings.Status -eq 'ready' -and $settings.Enabled)
            $TestNotificationButton.IsEnabled=($settings.Status -eq 'ready' -and $settings.Enabled)
            $SmartNotificationsStatusText.Text=if ($settings.Status -ne 'ready') {
                'Settings unavailable; existing records were left untouched.'
            } elseif ($settings.Enabled) {
                'While in the tray. Windows controls banners and sound.'
            } else { 'Off. Only meaningful events, never routine healthy checks.' }
        } finally { $script:notificationInitializing=$false }
    }

    function Test-SmartNotificationShell {
        return [Tqr.SmartNotifications]::ShellAllowsNotifications()
    }

    function Send-SmartNotificationToShell {
        param($Prompt)
        if (-not $script:notifyIcon -or -not $script:notifyIcon.Visible) { return $false }
        $icon=if ($Prompt.Warning) { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::None }
        $script:notifyIcon.ShowBalloonTip(5000,[string]$Prompt.Title,[string]$Prompt.Body,$icon)
        return $true
    }

    function Request-SmartNotification {
        param([string]$Code,[string]$Stamp=([DateTime]::UtcNow.ToString('o')))
        try {
            if (-not $script:notificationCenter -or $script:allowFullExit -or $global:TqrUiShutdownRequested) { return 'suppressed' }
            $inTray=[bool]$script:hiddenToTray
            $ready=Test-SmartNotificationShell
            $prompt=$script:notificationCenter.Prepare($Code,$Stamp,[DateTime]::UtcNow,$inTray,[bool]$ready)
            if ($prompt.Status -ne 'prepared') { return [string]$prompt.Status }
            if (Send-SmartNotificationToShell $prompt) { return 'requested' }
            return 'unavailable'
        } catch { return 'unavailable' }
    }

    function Observe-SmartConnectionNotification {
        param($Data,$View)
        try {
            if (-not $script:notificationCenter) { return }
            $current=[string]$Data.peerReachable
            $stamp=[string]$Data.updatedUtc
            if ($current -eq 'Unreachable' -and $script:notificationLastPeer -eq 'Reachable') {
                [void](Request-SmartNotification 'peer_lost' $stamp)
            } elseif ($current -eq 'Reachable' -and $script:notificationLastPeer -eq 'Unreachable') {
                [void](Request-SmartNotification 'peer_recovered' $stamp)
            }
            if ($current -in @('Reachable','Unreachable')) { $script:notificationLastPeer=$current }
            $warn=($View.Tone -eq 'warn' -and $current -eq 'Reachable')
            if ($warn -and -not $script:notificationQualityWarning) {
                [void](Request-SmartNotification 'quality_attention' $stamp)
            }
            $script:notificationQualityWarning=$warn
        } catch {}
    }

    function Observe-SmartAutoNotification {
        try {
            if (-not $script:notificationCenter -or -not (Get-AutoRepairEnabled)) { return }
            $settings=$script:notificationCenter.Settings()
            if ($settings.Status -ne 'ready' -or -not $settings.Enabled) { return }
            if (-not (Test-Path -LiteralPath $AutoRepairStatePath -PathType Leaf)) { return }
            $item=Get-Item -LiteralPath $AutoRepairStatePath -ErrorAction Stop
            if ($item.Length -gt 8192 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
            $state=Get-Content -LiteralPath $AutoRepairStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $stamp=[DateTime]::MinValue
            if (-not [Tqr.SmartNotifications]::ParseStamp([string]$state.lastCheckedUtc,[ref]$stamp)) { return }
            if ($stamp -lt $script:notificationStartedUtc -or $stamp -gt [DateTime]::UtcNow.AddSeconds(5) -or $stamp -lt [DateTime]::UtcNow.AddMinutes(-10)) { return }
            $status=[string]$state.status
            if ($status -in @('manual','error') -and $status -ne $script:notificationLastAutoStatus) {
                [void](Request-SmartNotification 'auto_attention' $state.lastCheckedUtc)
            }
            $script:notificationLastAutoStatus=$status
            # In the existing monitor 'repaired' means STARTED, not succeeded.
            # Only a later explicit healthy observation can confirm local recovery.
            $repair=[DateTime]::MinValue
            if ($status -eq 'healthy' -and $state.service -eq 'Running' -and
                $state.client -eq 'Running' -and $state.backend -eq 'Running' -and
                [Tqr.SmartNotifications]::ParseStamp([string]$state.lastRepairUtc,[ref]$repair) -and
                $repair -ge $script:notificationStartedUtc -and $repair -le $stamp -and
                ($stamp-$repair).TotalMinutes -le 10 -and
                [string]$state.lastRepairUtc -ne $script:notificationLastRecovery) {
                $script:notificationLastRecovery=[string]$state.lastRepairUtc
                [void](Request-SmartNotification 'auto_recovered' $state.lastCheckedUtc)
            }
        } catch {}
    }

    function Write-LocalHistoryEvent {
'@
Replace-One '            if (-not $view) { return }' @'
            if (-not $view) { return }
            Observe-SmartConnectionNotification $Data $view
'@
Replace-One '        param([switch]$Stale)' @'
        param([switch]$Stale)
        $script:notificationLastPeer=''
        $script:notificationQualityWarning=$false
'@
Replace-One @'
    $script:autoRepairUiTimer.Add_Tick({
        if ($DetailsPanel.Visibility
'@ @'
    $script:autoRepairUiTimer.Add_Tick({
        Observe-SmartAutoNotification
        if ($DetailsPanel.Visibility
'@
Replace-One '$AutoRepairStatusText.Text = "Enabled · repaired · $fresh"' '$AutoRepairStatusText.Text = "Enabled · recovery started · $fresh"'
Replace-One @'
                        $script:updateManifest = $manifest
                        $script:updateManifestChannel = $script:updateCheckChannel
                        $UpdateNowButton.Visibility
'@ @'
                        $script:updateManifest = $manifest
                        $script:updateManifestChannel = $script:updateCheckChannel
                        if ([int64]$manifest.versionCode -ne $script:notificationUpdateCode) {
                            $script:notificationUpdateCode=[int64]$manifest.versionCode
                            [void](Request-SmartNotification 'update_available')
                        }
                        $UpdateNowButton.Visibility
'@
Replace-One "                Write-LocalHistoryEvent 'integrity_attention'" @'
                Write-LocalHistoryEvent 'integrity_attention'
                [void](Request-SmartNotification 'integrity_attention')
'@
Replace-One "            `$result = Get-Content -LiteralPath `$UpdateResultPath -Raw | ConvertFrom-Json" @'
            $notificationResultStamp=(Get-Item -LiteralPath $UpdateResultPath -ErrorAction Stop).LastWriteTimeUtc.ToString('o')
            $result = Get-Content -LiteralPath $UpdateResultPath -Raw | ConvertFrom-Json
'@
Replace-One "                Write-LocalHistoryEvent 'update_installed'" @'
                Write-LocalHistoryEvent 'update_installed'
                [void](Request-SmartNotification 'update_installed' $notificationResultStamp)
'@
Replace-One "                Write-LocalHistoryEvent 'update_failed'" @'
                Write-LocalHistoryEvent 'update_failed'
                [void](Request-SmartNotification 'update_attention' $notificationResultStamp)
'@
Replace-One '    $HistoryButton.Add_Click({' @'
    $notificationChanged={
        if ($script:notificationInitializing -or -not $script:notificationCenter) { return }
        try {
            $saved=$script:notificationCenter.SetEnabled([bool]$SmartNotificationsCheckBox.IsChecked,[DateTime]::UtcNow)
            $script:notificationStartedUtc=[DateTime]::UtcNow
            $script:notificationLastPeer=''
            $script:notificationQualityWarning=$false
            Update-SmartNotificationSettings
            if ($saved.Status -ne 'ready') { $SmartNotificationsStatusText.Text='Could not save this preference. Existing settings were preserved.' }
        } catch { $SmartNotificationsStatusText.Text='Notifications unavailable. Connection checks are unaffected.' }
    }
    $SmartNotificationsCheckBox.Add_Checked($notificationChanged)
    $SmartNotificationsCheckBox.Add_Unchecked($notificationChanged)
    $TestNotificationButton.Add_Click({
        $outcome=Request-SmartNotification 'test'
        $SmartNotificationsStatusText.Text=switch ($outcome) {
            'requested' { 'Test requested. Windows controls whether it is displayed.' }
            'rate_limited' { 'Test rate-limited. Wait before requesting another notification.' }
            'suppressed' { 'Windows is not accepting notifications right now.' }
            'disabled' { 'Enable Smart notifications before testing.' }
            default { 'Notification unavailable. Connection checks are unaffected.' }
        }
    })

    $HistoryButton.Add_Click({
'@
Replace-One @'
    Initialize-TrayIcon
    Update-TrayStatus $null
'@ @'
    Initialize-TrayIcon
    Initialize-SmartNotifications
    $script:notifyIcon.Add_BalloonTipClicked({
        try {
            if (-not $script:allowFullExit -and -not $global:TqrUiShutdownRequested) { Restore-FromTray }
        } catch {}
    })
    Update-TrayStatus $null
'@
[void][scriptblock]::Create($script:text)
[IO.File]::WriteAllText($Path,$script:text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Opt-in Smart notifications wired after final UI transforms.'
