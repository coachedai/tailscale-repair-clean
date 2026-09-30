param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter(Mandatory=$true)]
    [string]$Version,

    [Parameter(Mandatory=$true)]
    [int64]$VersionCode
)

$ErrorActionPreference = 'Stop'

function Replace-ExactOnce {
    param(
        [string]$Text,
        [string]$Find,
        [string]$Replace,
        [string]$Description
    )

    $index = $Text.IndexOf($Find, [StringComparison]::Ordinal)

    if ($index -lt 0) {
        throw "UI polish marker was not found: $Description"
    }

    return $Text.Remove($index, $Find.Length).Insert($index, $Replace)
}

function Replace-RegexOnce {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Replace,
        [string]$Description
    )

    $match = [regex]::Match($Text, $Pattern)

    if (-not $match.Success) {
        throw "UI polish pattern was not found: $Description"
    }

    return $Text.Remove($match.Index, $match.Length).Insert($match.Index, $Replace)
}

$text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)

$text = Replace-RegexOnce `
    -Text $text `
    -Pattern '(?m)^\$ProductVersion\s*=\s*''[^'']+''\s*$' `
    -Replace ('$ProductVersion = ''' + $Version + '''') `
    -Description 'product version'

$text = Replace-RegexOnce `
    -Text $text `
    -Pattern '(?m)^\$ProductVersionCode\s*=\s*\[int64\]\d+\s*$' `
    -Replace ('$ProductVersionCode = [int64]' + $VersionCode) `
    -Description 'product version code'

# Keep this replacement ASCII-only so Windows PowerShell 5.1 never depends on
# source-file encoding to identify the existing middle-dot separator.
$text = Replace-RegexOnce `
    -Text $text `
    -Pattern 'Text="Current [^"]*Check GitHub for updates\."' `
    -Replace ('Text="Current ' + $Version + ' - Check GitHub for updates."') `
    -Description 'maintenance version label'

$text = Replace-ExactOnce `
    -Text $text `
    -Find 'VerticalScrollBarVisibility="Auto"' `
    -Replace 'VerticalScrollBarVisibility="Hidden"' `
    -Description 'main scrollbar visibility'

$text = Replace-ExactOnce `
    -Text $text `
    -Find @'
HorizontalScrollBarVisibility="Disabled"
            Background="{StaticResource Bg}">
'@ `
    -Replace @'
HorizontalScrollBarVisibility="Disabled"
            PanningMode="VerticalOnly"
            Background="{StaticResource Bg}">
'@ `
    -Description 'main vertical panning'

# Normalize only the semantic Remote-details header. This makes the later
# public-target transform independent of cosmetic indentation in source.
$remoteHeaderPattern = '(?s)<StackPanel\s+Grid\.Column="2">\s*<TextBlock\s+Text="Remote"\s+FontSize="15"\s+FontWeight="SemiBold"\s+Foreground="\{StaticResource Text\}"\s*/>\s*<Grid\s+Margin="0,16,0,0">'
$remoteHeaderNormalized = @'
<StackPanel Grid.Column="2">
                                <TextBlock Text="Remote" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                <Grid Margin="0,16,0,0">
'@
$text = Replace-RegexOnce `
    -Text $text `
    -Pattern $remoteHeaderPattern `
    -Replace $remoteHeaderNormalized `
    -Description 'Remote details header normalization'

# UI-only 2.3.5 polish. Do not touch repair tasks, setup routing, networking or
# the proven repair engine. Keep new display strings ASCII-only for Windows
# PowerShell 5.1 packaging safety.
$activityHeader = @'
<StackPanel>
                                            <TextBlock Text="Activity" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                            <TextBlock Text="Changes and repair actions from this app session."
                                                       Margin="0,4,0,0"
                                                       FontSize="11"
                                                       Foreground="{StaticResource Faint}"
                                                       TextWrapping="Wrap"/>
                                        </StackPanel>
'@
$text = Replace-ExactOnce `
    -Text $text `
    -Find '<TextBlock Text="This session" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>' `
    -Replace $activityHeader `
    -Description 'activity heading'

$text = Replace-ExactOnce `
    -Text $text `
    -Find 'Text="No repair actions yet."/>' `
    -Replace 'Text="No activity yet."/>' `
    -Description 'activity empty state'

$text = Replace-RegexOnce `
    -Text $text `
    -Pattern '(?s)\s*\$eventsText = ''''\s*\r?\n\s*if \(\$Data\.events\) \{.*?\r?\n\s*\$script:copyDiagnosticsText = @\(' `
    -Replace @'

        $activityItems = @()

        if ($Data.events) {
            foreach ($eventLine in @($Data.events)) {
                $line = [string]$eventLine

                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                # Reachability is already visible in Remote. Keep Activity for
                # changes and repair actions rather than duplicating status.
                if ($line -match '\s+Peer reachable(?: via .+)?$') {
                    continue
                }

                $activityItems += $line
            }
        }

        if ($script:reliabilityEvents.Count -gt 0) {
            $activityItems += @(
                $script:reliabilityEvents |
                    Select-Object -Last 3
            )
        }

        if ($script:connectionEvents.Count -gt 0) {
            $activityItems += @(
                $script:connectionEvents |
                    Select-Object -Last 3
            )
        }

        $activityItems = @(
            $activityItems |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Select-Object -Unique |
                Select-Object -Last 5
        )

        if ($activityItems.Count -gt 0) {
            $SessionText.Text = @(
                $activityItems |
                    ForEach-Object { '- ' + [string]$_ }
            ) -join [Environment]::NewLine
        }
        elseif ([bool]$Data.done) {
            $SessionText.Text = if ([bool]$Data.repairPerformed) {
                'Repair completed successfully.'
            }
            else {
                'No changes were needed.'
            }
        }
        else {
            $SessionText.Text = 'Check in progress.'
        }

        $script:copyDiagnosticsText = @(
'@ `
    -Description 'activity feed logic'

$text = Replace-RegexOnce `
    -Text $text `
    -Pattern '(?m)^\s*''This session''\s*$' `
    -Replace "            'Activity'" `
    -Description 'activity copy heading'

# Reserve the small status rows instead of collapsing them. This keeps the
# hero and connection cards at one stable height while a check is running.
$lastCheckedXaml = @'
                            <TextBlock
                                x:Name="LastCheckedText"
                                Margin="0,9,0,0"
                                MinHeight="14"
                                FontSize="11"
                                Foreground="{StaticResource Faint}"
                                Visibility="Hidden"/>
'@
$text = Replace-RegexOnce `
    -Text $text `
    -Pattern '(?s)\s*<TextBlock\s+x:Name="LastCheckedText"\s+Margin="0,9,0,0"\s+FontSize="11"\s+Foreground="\{StaticResource Faint\}"\s+Visibility="Collapsed"/>' `
    -Replace ([Environment]::NewLine + $lastCheckedXaml.TrimEnd("`r", "`n")) `
    -Description 'stable hero freshness row'

$connectionInsightXaml = @'
                            <TextBlock
                                x:Name="ConnectionInsightText"
                                Grid.Row="3"
                                Margin="0,15,0,0"
                                MinHeight="18"
                                FontSize="11.5"
                                Foreground="{StaticResource Faint}"
                                Visibility="Hidden"
                                TextWrapping="Wrap"/>
'@
$text = Replace-RegexOnce `
    -Text $text `
    -Pattern '(?s)\s*<TextBlock\s+x:Name="ConnectionInsightText"\s+Grid\.Row="3"\s+Margin="0,15,0,0"\s+FontSize="11\.5"\s+Foreground="\{StaticResource Faint\}"\s+Visibility="Collapsed"\s+TextWrapping="Wrap"/>' `
    -Replace ([Environment]::NewLine + $connectionInsightXaml.TrimEnd("`r", "`n")) `
    -Description 'stable connection insight row'

$text = $text.Replace(
    '$LastCheckedText.Visibility = [System.Windows.Visibility]::Collapsed',
    '$LastCheckedText.Visibility = [System.Windows.Visibility]::Hidden'
)

$text = Replace-ExactOnce `
    -Text $text `
    -Find '$ConnectionInsightText.Visibility = [System.Windows.Visibility]::Collapsed' `
    -Replace '$ConnectionInsightText.Visibility = [System.Windows.Visibility]::Hidden' `
    -Description 'stable connection insight visibility'

# 2.3.6 Tray Exit-only hardening. Keep repair/setup/network behavior frozen.
# Let the WinForms context-menu click unwind before WPF tears down the window
# and tray resources. This avoids shutdown-time errors from the live menu.
$text = Replace-ExactOnce `
    -Text $text `
    -Find @'
        $script:trayExitItem.Add_Click({
            $window.Dispatcher.BeginInvoke(
                [Action]{
                    $script:allowFullExit = $true
                    $window.Close()
                }
            ) | Out-Null
        })
'@ `
    -Replace @'
        $script:trayExitItem.Add_Click({
            try {
                $script:allowFullExit = $true

                if ($script:notifyIcon) {
                    $script:notifyIcon.ContextMenuStrip = $null
                    $script:notifyIcon.Visible = $false
                }

                if ($script:trayMenu) {
                    $script:trayMenu.Close()
                }

                $window.Dispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
                    [Action]{
                        try { $window.Close() } catch {}
                    }
                ) | Out-Null
            }
            catch {
                try { $window.Close() } catch {}
            }
        })
'@ `
    -Description 'tray exit idle shutdown'

# Tell the native host that the WPF lifetime reached a normal close. The host
# can then distinguish a harmless shutdown-time PowerShell stream entry from a
# genuine failure to load the app.
$text = Replace-ExactOnce `
    -Text $text `
    -Find @'
    if ($ownsWpfApp) {
        if ($StartInTray) {
            [void]$wpfApp.Run()
        }
        else {
            [void]$wpfApp.Run($window)
        }
    }
    elseif ($StartInTray) {
        # NativeHost normally owns the WPF Application. Preserve a hidden
        # startup path if hosted inside an already-running WPF dispatcher.
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $window.Add_Closed({
            try { $frame.Continue = $false } catch {}
        })
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    else {
        [void]$window.ShowDialog()
    }
'@ `
    -Replace @'
    if ($ownsWpfApp) {
        if ($StartInTray) {
            [void]$wpfApp.Run()
        }
        else {
            [void]$wpfApp.Run($window)
        }
    }
    elseif ($StartInTray) {
        # NativeHost normally owns the WPF Application. Preserve a hidden
        # startup path if hosted inside an already-running WPF dispatcher.
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $window.Add_Closed({
            try { $frame.Continue = $false } catch {}
        })
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    else {
        [void]$window.ShowDialog()
    }

    $global:TqrUiClosedNormally = $true
'@ `
    -Description 'native host normal-close marker'

# Phase 3 Guardian foundation: explicit lifecycle markers. These are behind-
# the-scenes state signals only; they do not change repair/network behavior.
$text = Replace-ExactOnce `
    -Text $text `
    -Find @'
        $script:trayExitItem.Add_Click({
            try {
                $script:allowFullExit = $true

                if ($script:notifyIcon) {
'@ `
    -Replace @'
        $script:trayExitItem.Add_Click({
            try {
                $script:allowFullExit = $true
                $global:TqrUiShutdownRequested = $true

                if ($script:notifyIcon) {
'@ `
    -Description 'tray shutdown lifecycle marker'

$text = Replace-ExactOnce `
    -Text $text `
    -Find @'
    $window.Add_Closed({
        $script:allowFullExit = $true
'@ `
    -Replace @'
    $window.Add_Closed({
        $script:allowFullExit = $true
        $global:TqrUiShutdownRequested = $true
'@ `
    -Description 'window closed lifecycle marker'

$text = Replace-ExactOnce `
    -Text $text `
    -Find @'
        # Windows logoff/shutdown must always be allowed to close the resident app.
        $script:allowFullExit = $true
    })
'@ `
    -Replace @'
        # Windows logoff/shutdown must always be allowed to close the resident app.
        $script:allowFullExit = $true
        $global:TqrUiShutdownRequested = $true
    })
'@ `
    -Description 'session ending lifecycle marker'


# Phase 3.1 Integrity Guardian foundation. Read-only: inspect Quick Repair's
# own install/configuration/integration and surface one compact Maintenance
# status. Do not change repair, setup, updater or network behavior.
$guardianMaintenanceOld = @'
                                        <Button
                                            x:Name="RepairInstallationButton"
                                            AutomationProperties.Name="Repair Quick Repair installation"
                                            AutomationProperties.HelpText="Rebuilds Quick Repair shell integration, tasks and launchers."
                                            Margin="0,14,0,0"
                                            HorizontalAlignment="Left"
                                            Style="{StaticResource GhostButtonStyle}"
                                            Content="Repair installation"/>
'@

$guardianMaintenanceNew = @'
                                        <Grid Margin="0,14,0,0">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>

                                            <StackPanel>
                                                <TextBlock
                                                    Text="System integrity"
                                                    FontSize="12"
                                                    Foreground="{StaticResource Value}"/>
                                                <TextBlock
                                                    x:Name="GuardianStatusText"
                                                    Margin="0,4,0,0"
                                                    MinHeight="15"
                                                    FontSize="10.5"
                                                    Foreground="{StaticResource Faint}"
                                                    Text="Ready to check"/>
                                            </StackPanel>

                                            <Button
                                                x:Name="GuardianCheckButton"
                                                Grid.Column="1"
                                                AutomationProperties.Name="Check Quick Repair system integrity"
                                                AutomationProperties.HelpText="Runs a read-only check of Quick Repair files, configuration and Windows integration."
                                                VerticalAlignment="Center"
                                                Style="{StaticResource GhostButtonStyle}"
                                                Content="Check"/>
                                        </Grid>

                                        <TextBlock
                                            x:Name="GuardianDetailText"
                                            Margin="0,5,0,0"
                                            MinHeight="15"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Text="Quick Repair files, configuration and Windows integration."
                                            TextWrapping="Wrap"/>

                                        <Button
                                            x:Name="RepairInstallationButton"
                                            AutomationProperties.Name="Repair Quick Repair installation"
                                            AutomationProperties.HelpText="Rebuilds Quick Repair shell integration, tasks and launchers."
                                            Margin="0,18,0,0"
                                            HorizontalAlignment="Left"
                                            Style="{StaticResource GhostButtonStyle}"
                                            Content="Repair installation"/>
'@
$text = Replace-ExactOnce -Text $text -Find $guardianMaintenanceOld -Replace $guardianMaintenanceNew -Description 'Guardian Maintenance UI'

$guardianBindingOld = @'
    $RepairInstallationButton = $window.FindName('RepairInstallationButton')
    $UpdateStatusText = $window.FindName('UpdateStatusText')
'@
$guardianBindingNew = @'
    $GuardianStatusText = $window.FindName('GuardianStatusText')
    $GuardianDetailText = $window.FindName('GuardianDetailText')
    $GuardianCheckButton = $window.FindName('GuardianCheckButton')
    $RepairInstallationButton = $window.FindName('RepairInstallationButton')
    $UpdateStatusText = $window.FindName('UpdateStatusText')
'@
$text = Replace-ExactOnce -Text $text -Find $guardianBindingOld -Replace $guardianBindingNew -Description 'Guardian control bindings'

$guardianStateOld = @'
    $script:repairActive = $false
    $script:actionMode = 'repair'
'@
$guardianStateNew = @'
    $script:repairActive = $false
    $script:lastGuardianCheckAt = [DateTime]::MinValue
    $script:lastGuardianResult = $null
    $script:actionMode = 'repair'
'@
$text = Replace-ExactOnce -Text $text -Find $guardianStateOld -Replace $guardianStateNew -Description 'Guardian runtime state'

$guardianFunctions = ''

$text = Replace-ExactOnce -Text $text -Find '    function Update-DetailsToggleText {' -Replace ($guardianFunctions + '    function Update-DetailsToggleText {') -Description 'Guardian integrity functions'

$guardianEventOld = @'
    $RepairInstallationButton.Add_Click({
        Invoke-InstallationRepair
    })
'@
$guardianEventNew = @'
    $GuardianCheckButton.Add_Click({
        if (-not $GuardianCheckButton.IsEnabled) {
            return
        }

        $GuardianCheckButton.IsEnabled = $false
        $GuardianStatusText.Text = 'Checking...'
        $GuardianStatusText.Foreground = Get-Brush 'Blue'
        $GuardianDetailText.Text = 'Verifying release files, configuration and Windows integration.'
        $GuardianDetailText.Foreground = Get-Brush 'Faint'

        $issues = New-Object 'System.Collections.Generic.List[string]'
        $safeFixes = New-Object 'System.Collections.Generic.List[string]'
        $verifiedReleaseFiles = 0
        $guardianLease = $null
        $integrityManifestSha256 = ''
        $snapshotEstablished = $false
        $snapshotConfirmed = $false

        try {
            Initialize-OperationGate
            $guardianLease = [Tqr.OperationGate]::TryAcquire($StateDir, 'integrity')
            if (-not $guardianLease) {
                $GuardianStatusText.Text = 'Waiting for another operation'
                $GuardianDetailText.Text = 'Let the current Quick Repair operation finish, then check integrity again.'
                return
            }
            $requiredFiles = @(
                $NativeHostPath,
                $OperationsLibraryPath,
                (Join-Path $StateDir 'Tailscale-Repair-UI.ps1'),
                $UpdaterHostPath,
                $SetupHostPath,
                $AdvancedDiagnosticsPath,
                $BackendPath,
                $AutoRepairMonitorPath
            )

            foreach ($file in $requiredFiles) {
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    [void]$issues.Add("Missing component: $([IO.Path]::GetFileName($file))")
                }
            }

            if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
                [void]$issues.Add('Target configuration is missing.')
            }
            elseif ([string]::IsNullOrWhiteSpace($Peer)) {
                [void]$issues.Add('Target configuration is invalid.')
            }

            $installedVersionPath = Join-Path $StateDir 'version.user.json'
            if (-not (Test-Path -LiteralPath $installedVersionPath -PathType Leaf)) {
                [void]$issues.Add('Installed version metadata is missing.')
            }
            else {
                try {
                    $installedVersion = Get-Content -LiteralPath $installedVersionPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ([int64]$installedVersion.versionCode -ne $ProductVersionCode) {
                        [void]$issues.Add('Installed version metadata does not match this build.')
                    }
                }
                catch {
                    [void]$issues.Add('Installed version metadata is invalid.')
                }
            }

            if (Test-Path -LiteralPath (Join-Path $StateDir 'Update.pending') -PathType Leaf) {
                [void]$issues.Add('An interrupted update marker is still present.')
            }

            $integrityManifestPath = Join-Path $StateDir 'integrity-manifest.json'
            if (-not (Test-Path -LiteralPath $integrityManifestPath -PathType Leaf)) {
                [void]$issues.Add('Release integrity manifest is missing.')
            }
            else {
                try {
                    $integrityManifest = Get-Content -LiteralPath $integrityManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $integrityManifestSha256 = (Get-FileHash -LiteralPath $integrityManifestPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()

                    if (
                        [string]$integrityManifest.product -cne 'Tailscale Quick Repair' -or
                        [string]$integrityManifest.version -cne $ProductVersion -or
                        [int]$integrityManifest.schema -ne 1 -or
                        [int64]$integrityManifest.versionCode -ne $ProductVersionCode -or
                        [string]$integrityManifest.algorithm -ne 'SHA256'
                    ) {
                        throw 'Release integrity metadata does not match this build.'
                    }

                    $expectedNames = @('Tailscale-Repair-UI.ps1','TailscaleQuickRepairUpdater.exe','TailscaleQuickRepairSetup.exe','TailscaleQuickRepair.Operations.dll')
                    if ([string]$integrityManifest.profile -eq 'setup') {
                        $expectedNames += 'TailscaleQuickRepair.exe','Advanced-Diagnostics.ps1'
                    }
                    elseif ([string]$integrityManifest.profile -ne 'update') {
                        throw 'Release integrity profile is unsupported.'
                    }
                    $fileNames = @($integrityManifest.files | ForEach-Object { [string]$_.path })
                    if ($fileNames.Count -ne $expectedNames.Count -or
                        @($fileNames | Sort-Object -Unique).Count -ne $expectedNames.Count -or
                        @($fileNames | Where-Object { $_ -notin $expectedNames }).Count -ne 0) {
                        throw 'Release integrity file coverage is incomplete or duplicated.'
                    }
                    foreach ($entry in @($integrityManifest.files)) {
                        $name = [string]$entry.path
                        $expectedHash = ([string]$entry.sha256).ToLowerInvariant()
                        $expectedSize = [int64]$entry.size

                        if (
                            [string]::IsNullOrWhiteSpace($name) -or
                            $name -notin $expectedNames -or
                            $name -match '[\\/]' -or
                            $expectedHash.Length -ne 64 -or
                            $expectedHash -match '[^a-f0-9]' -or
                            $expectedSize -lt 0
                        ) {
                            throw 'Release integrity manifest contains invalid file metadata.'
                        }

                        $candidate = Join-Path $StateDir $name
                        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                            [void]$issues.Add("Release file is missing: $name")
                            continue
                        }

                        if (((Get-Item -LiteralPath $candidate -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            throw 'Release files cannot use a reparse point.'
                        }
                        if ((Get-Item -LiteralPath $candidate -ErrorAction Stop).Length -ne $expectedSize) {
                            [void]$issues.Add("Release file size changed: $name")
                            continue
                        }

                        $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                        if ($actualHash -ne $expectedHash) {
                            [void]$issues.Add("Release file integrity failed: $name")
                            continue
                        }

                        $verifiedReleaseFiles++
                    }
                }
                catch {
                    $manifestReason = [string]$_.Exception.Message
                    if ([string]::IsNullOrWhiteSpace($manifestReason)) {
                        $manifestReason = 'Release integrity manifest is invalid.'
                    }
                    [void]$issues.Add($manifestReason)
                }
            }

            if (-not (Test-Path -LiteralPath $StartMenuShortcutPath -PathType Leaf)) {
                [void]$issues.Add('Start Menu integration is missing.')
            }

            try {
                if (Test-StartWithWindows) {
                    $startupValue = [string](Get-ItemProperty -Path $StartupRegistryPath -Name $StartupRegistryName -ErrorAction Stop).$StartupRegistryName
                    $canonicalStartup = '"' + $NativeHostPath + '" --start-in-tray'
                    $legacyStartup = '"' + $NativeHostPath + '" --tray'

                    if ($startupValue -ieq $canonicalStartup) {
                        # Canonical and healthy.
                    }
                    elseif ($startupValue -ieq $legacyStartup -and $issues.Count -eq 0) {
                        New-ItemProperty -Path $StartupRegistryPath -Name $StartupRegistryName -Value $canonicalStartup -PropertyType String -Force | Out-Null
                        [void]$safeFixes.Add('Windows startup command repaired.')
                    }
                    else {
                        [void]$issues.Add('Windows startup integration is not configured correctly.')
                    }
                }
            }
            catch {
                [void]$issues.Add('Windows startup integration could not be verified.')
            }

            try {
                $engine = Test-RepairEngine
                if (-not [bool]$engine.Healthy) {
                    $message = [string]$engine.Message
                    if ([string]::IsNullOrWhiteSpace($message)) {
                        $message = 'Protected repair integration needs maintenance.'
                    }
                    [void]$issues.Add($message)
                }
            }
            catch {
                [void]$issues.Add('Protected repair integration could not be verified.')
            }

            try {
                if (-not (Test-AutoRepairAvailable)) {
                    [void]$issues.Add('Automatic repair integration is unavailable.')
                }
            }
            catch {
                [void]$issues.Add('Automatic repair integration could not be verified.')
            }

            $snapshotPath = Join-Path $StateDir 'guardian-known-good.json'
            $snapshot = $null

            if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
                try {
                    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    $snapshot = $null
                    [void]$issues.Add('Known-good baseline could not be read. The previous record was preserved.')
                }
            }

            if ($snapshot -and (
                [int]$snapshot.schema -ne 1 -or [int64]$snapshot.versionCode -le 0 -or
                [int64]$snapshot.versionCode -gt $ProductVersionCode -or
                ([string]$snapshot.integrityManifestSha256).Length -ne 64 -or
                [string]$snapshot.integrityManifestSha256 -match '[^a-fA-F0-9]' -or
                [int]$snapshot.verifiedReleaseFiles -le 0)) {
                [void]$issues.Add('Known-good baseline metadata is invalid. The previous record was preserved.')
            }
            if ($issues.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($integrityManifestSha256)) {
                if ($snapshot -and [int64]$snapshot.versionCode -eq $ProductVersionCode -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.integrityManifestSha256) -and [string]$snapshot.integrityManifestSha256 -ne $integrityManifestSha256) {
                    [void]$issues.Add('Known-good release record changed unexpectedly.')
                }
                else {
                    $snapshotEstablished = (-not $snapshot -or [int64]$snapshot.versionCode -ne $ProductVersionCode)
                    $snapshotConfirmed = -not $snapshotEstablished

                    $snapshotValue = [ordered]@{
                        schema = 1
                        versionCode = $ProductVersionCode
                        integrityManifestSha256 = $integrityManifestSha256
                        verifiedReleaseFiles = $verifiedReleaseFiles
                        startupEnabled = [bool](Test-StartWithWindows)
                        repairEngineReady = $true
                        autoRepairAvailable = $true
                        verifiedUtc = [DateTime]::UtcNow.ToString('o')
                    }

                    $snapshotTemp = $snapshotPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
                    $snapshotBackup = Join-Path $StateDir 'guardian-known-good.previous.json'
                    try {
                        foreach ($recordPath in @($snapshotPath,$snapshotBackup)) {
                            if ((Test-Path -LiteralPath $recordPath) -and
                                ((Get-Item -LiteralPath $recordPath).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                                throw 'Known-good records cannot use a reparse point.'
                            }
                        }
                        $snapshotJson = $snapshotValue | ConvertTo-Json -Depth 4
                        $snapshotBytes = [Text.Encoding]::UTF8.GetBytes($snapshotJson)
                        $snapshotStream = [IO.File]::Open($snapshotTemp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                        try { $snapshotStream.Write($snapshotBytes,0,$snapshotBytes.Length); $snapshotStream.Flush($true) }
                        finally { $snapshotStream.Dispose() }
                        if (Test-Path -LiteralPath $snapshotPath) { [IO.File]::Replace($snapshotTemp,$snapshotPath,$snapshotBackup) }
                        else { [IO.File]::Move($snapshotTemp,$snapshotPath) }
                    }
                    finally {
                        if (Test-Path -LiteralPath $snapshotTemp) { Remove-Item -LiteralPath $snapshotTemp -Force -ErrorAction SilentlyContinue }
                    }
                }
            }

            $script:lastGuardianCheckAt = Get-Date

            if ($issues.Count -eq 0) {
                $GuardianStatusText.Text = 'Healthy'
                $GuardianStatusText.Foreground = Get-Brush 'Green'
                $healthyParts = New-Object 'System.Collections.Generic.List[string]'
                if ($verifiedReleaseFiles -gt 0) { [void]$healthyParts.Add("$verifiedReleaseFiles release files verified with SHA-256.") }
                if ($snapshotEstablished) { [void]$healthyParts.Add('Known-good baseline established.') }
                elseif ($snapshotConfirmed) { [void]$healthyParts.Add('Known-good baseline confirmed.') }
                if ($safeFixes.Count -gt 0) { [void]$healthyParts.Add(($safeFixes -join ' ')) }
                [void]$healthyParts.Add('Windows integration checked.')
                $GuardianDetailText.Text = $healthyParts -join ' '
                $GuardianDetailText.Foreground = Get-Brush 'Faint'
            }
            else {
                $GuardianStatusText.Text = if ($issues.Count -eq 1) {
                    '1 issue needs attention'
                }
                else {
                    "$($issues.Count) issues need attention"
                }

                $GuardianStatusText.Foreground = Get-Brush 'Amber'
                $GuardianDetailText.Text = @($issues | Select-Object -First 2) -join '; '
                $GuardianDetailText.Foreground = Get-Brush 'Amber'
            }
        }
        catch {
            $GuardianStatusText.Text = 'Check incomplete'
            $GuardianStatusText.Foreground = Get-Brush 'Amber'

            $reason = [string]$_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = 'Guardian could not complete the integrity check.'
            }
            elseif ($reason.Length -gt 150) {
                $reason = $reason.Substring(0,150).TrimEnd() + '...'
            }

            $GuardianDetailText.Text = $reason
            $GuardianDetailText.Foreground = Get-Brush 'Amber'
        }
        finally {
            if ($guardianLease) { try { $guardianLease.Dispose() } catch {} }
            try { $GuardianCheckButton.IsEnabled = $true } catch {}
        }
    })

    $RepairInstallationButton.Add_Click({
        Invoke-InstallationRepair
    })
'@
$text = Replace-ExactOnce -Text $text -Find $guardianEventOld -Replace $guardianEventNew -Description 'Guardian check event'

$guardianDetailsOld = @'
            $CopyButton.Content = 'Copy'
            Update-Diagnostics $script:lastData
            Initialize-AutoRepairUi
'@
$guardianDetailsNew = @'
            try { $CopyButton.Content = 'Copy' } catch {}
            try { Update-Diagnostics $script:lastData } catch {}
            try { Initialize-AutoRepairUi } catch {}
'@
$text = Replace-ExactOnce -Text $text -Find $guardianDetailsOld -Replace $guardianDetailsNew -Description 'Guardian Details refresh'




$guardianStartupOld = @'
                if (-not (Attach-To-RunningRepair)) {
                    [void](Refresh-EngineCheck)
                }
'@
$guardianStartupNew = @'
                if (-not (Attach-To-RunningRepair)) {
                    [void](Refresh-EngineCheck)
                }
'@
$text = Replace-ExactOnce -Text $text -Find $guardianStartupOld -Replace $guardianStartupNew -Description 'Guardian startup check'


$themeAnchor = @'
    Add-Type -AssemblyName System.Drawing

    # --------------------------------------------------------------
    # Helpers
'@

$themeReplacement = @'
    Add-Type -AssemblyName System.Drawing

    if (-not ('QuickRepairWindowTheme' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class QuickRepairWindowTheme
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr hwnd,
        int attribute,
        ref int value,
        int size
    );

    public static void Apply(IntPtr hwnd)
    {
        try
        {
            int enabled = 1;
            DwmSetWindowAttribute(hwnd, 20, ref enabled, sizeof(int));
            DwmSetWindowAttribute(hwnd, 19, ref enabled, sizeof(int));

            // DWM COLORREF uses 0x00BBGGRR.
            int caption = 0x00120D0A;
            int text = 0x00FFFFFF;

            DwmSetWindowAttribute(hwnd, 35, ref caption, sizeof(int));
            DwmSetWindowAttribute(hwnd, 36, ref text, sizeof(int));
        }
        catch
        {
        }
    }
}
"@
    }

    function Set-DarkWindowChrome {
        param([System.Windows.Window]$TargetWindow)

        if (-not $TargetWindow) {
            return
        }

        try {
            $interop = New-Object System.Windows.Interop.WindowInteropHelper($TargetWindow)
            [QuickRepairWindowTheme]::Apply($interop.Handle)
        }
        catch {}
    }

    function Set-QuickRepairWindowIcon {
        param([System.Windows.Window]$TargetWindow)

        if (-not $TargetWindow) {
            return
        }

        $icon = $null

        try {
            if (-not (Test-Path -LiteralPath $NativeHostPath -PathType Leaf)) {
                return
            }

            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($NativeHostPath)

            if (-not $icon) {
                return
            }

            $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $icon.Handle,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
            )

            if ($source) {
                $source.Freeze()
                $TargetWindow.Icon = $source
            }
        }
        catch {}
        finally {
            if ($icon) {
                try { $icon.Dispose() } catch {}
            }
        }
    }

    # --------------------------------------------------------------
    # Helpers
'@

$text = Replace-ExactOnce `
    -Text $text `
    -Find $themeAnchor `
    -Replace $themeReplacement `
    -Description 'dark window chrome helper'

$windowLoadAnchor = @'
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # --------------------------------------------------------------
    # Bind UI controls
'@

$windowLoadReplacement = @'
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $global:TqrUiStartedSuccessfully = $true

    $window.Add_SourceInitialized({
        Set-DarkWindowChrome $window
        Set-QuickRepairWindowIcon $window
    })

    # --------------------------------------------------------------
    # Bind UI controls
'@

$text = Replace-ExactOnce `
    -Text $text `
    -Find $windowLoadAnchor `
    -Replace $windowLoadReplacement `
    -Description 'dark title-bar hook'

foreach ($required in @(
    'QuickRepairWindowTheme',
    'VerticalScrollBarVisibility="Hidden"',
    ('Current ' + $Version + ' - Check GitHub for updates.'),
    ('$ProductVersion = ''' + $Version + ''''),
    ('$ProductVersionCode = [int64]' + $VersionCode),
    'Text="Activity"',
    'Check in progress.',
    'MinHeight="14"',
    'MinHeight="18"',
    'DispatcherPriority]::ApplicationIdle',
    'TqrUiClosedNormally',
    'TqrUiStartedSuccessfully',
    'TqrUiShutdownRequested',
    'Set-QuickRepairWindowIcon',
    'System integrity',
    'GuardianStatusText',
    'Ready to check',
    'Guardian could not complete the integrity check.',
    'Verifying release files, configuration and Windows integration.',
    '$verifiedReleaseFiles++',
    'integrity-manifest.json',
    'release files verified with SHA-256',
    '[void]$issues.Add(',
    'guardian-known-good.json',
    'Known-good baseline established.',
    'Windows startup command repaired.',
    '--start-in-tray'
)) {
    if ($text -notmatch [regex]::Escape($required)) {
        throw "UI polish verification failed: $required"
    }
}

# Guard this release as UI-only. These strings belong to repair/setup behavior
# and must not be introduced by the polish transform.
foreach ($forbidden in @(
    'Ensure-SilentRepairIntegration',
    'HardenTaskLaunchers',
    'Launch-Tailscale-Backend.vbs'' -and'
)) {
    if ($text -match [regex]::Escape($forbidden)) {
        throw "UI-only polish unexpectedly contains repair migration code: $forbidden"
    }
}

[void][scriptblock]::Create($text)

$xamlMatch = [regex]::Match(
    $text,
    '(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@'
)

if (-not $xamlMatch.Success) {
    throw 'Could not locate polished Quick Repair XAML.'
}

[xml]$xamlDocument = $xamlMatch.Groups['xaml'].Value

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

$reader = New-Object System.Xml.XmlNodeReader $xamlDocument
$testWindow = $null

try {
    $testWindow = [Windows.Markup.XamlReader]::Load($reader)

    if (-not $testWindow) {
        throw 'Polished WPF XAML validation returned no Window.'
    }
}
finally {
    try { $reader.Close() } catch {}
    try {
        if ($testWindow -is [System.Windows.Window]) {
            $testWindow.Close()
        }
    } catch {}
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($Path, $text, $utf8Bom)

Write-Host "Focused UI polish passed: $Version ($VersionCode)"
