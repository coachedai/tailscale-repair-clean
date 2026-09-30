param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][int64]$VersionCode
)

$ErrorActionPreference = 'Stop'

function Replace-ExactOnce {
    param([string]$Text,[string]$Find,[string]$Replace,[string]$Description)
    $index = $Text.IndexOf($Find, [StringComparison]::Ordinal)
    if ($index -lt 0) { throw "Public UI marker was not found: $Description" }
    return $Text.Remove($index, $Find.Length).Insert($index, $Replace)
}

function Replace-RegexLiteralOnce {
    param([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Description)

    $regex = New-Object System.Text.RegularExpressions.Regex(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    $matches = $regex.Matches($Text)

    if ($matches.Count -ne 1) {
        throw "Public UI regex expected one match for $Description; found $($matches.Count)."
    }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $Replacement
    }

    return $regex.Replace($Text, $evaluator, 1)
}

$text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)

$text = [regex]::Replace(
    $text,
    "(?m)^\$ProductVersion\s*=\s*'[^']+'\s*$",
    ('$ProductVersion = ''' + $Version + ''''),
    1
)
$text = [regex]::Replace(
    $text,
    '(?m)^\$ProductVersionCode\s*=\s*\[int64\]\d+\s*$',
    ('$ProductVersionCode = [int64]' + $VersionCode),
    1
)

$statePattern = '(?m)^\$StateDir\s*=\s*Join-Path\s+\$env:LOCALAPPDATA\s+''TailscaleQuickRepair''\s*$'
$stateMatch = [regex]::Match($text, $statePattern)
if (-not $stateMatch.Success) {
    throw 'Public UI marker was not found: native setup host path'
}

$stateReplacement = $stateMatch.Value + [Environment]::NewLine +
    '$SetupHostPath = Join-Path $StateDir ''TailscaleQuickRepairSetup.exe'''
$text = $text.Remove($stateMatch.Index, $stateMatch.Length).Insert($stateMatch.Index, $stateReplacement)

$text = $text.Replace(
    '$command = ''"'' + $NativeHostPath + ''" --tray''',
    '$command = ''"'' + $NativeHostPath + ''" --start-in-tray'''
)

$text = $text.Replace(
    '$repairToolAvailable = Test-Path -LiteralPath $RepairInstallPath',
    '$repairToolAvailable = Test-Path -LiteralPath $SetupHostPath'
)

# Protected tasks use a windowless wscript launcher. Keep the base UI's
# launcher existence check and wscript task validation unchanged.
if ($text -notmatch [regex]::Escape('*Launch-Tailscale-Backend.vbs*')) {
    throw 'Public UI is missing hidden repair-task validation.'
}
$remoteMarker = @'
<StackPanel Grid.Column="2">
                                <TextBlock Text="Remote" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                <Grid Margin="0,16,0,0">
'@
$remoteReplacement = @'
<StackPanel Grid.Column="2">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Text="Remote" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                    <Button
                                        x:Name="ChangeTargetButton"
                                        Grid.Column="1"
                                        Style="{StaticResource GhostButtonStyle}"
                                        AutomationProperties.Name="Change target device"
                                        AutomationProperties.HelpText="Change the Tailscale target used for remote checks."
                                        Content="Change"/>
                                </Grid>
                                <Grid Margin="0,16,0,0">
'@
$text = Replace-ExactOnce $text $remoteMarker $remoteReplacement 'change target button'

$bindingMarker = @'
    $DetailPeerIp = $window.FindName('DetailPeerIp')
    $DetailPeerStatus = $window.FindName('DetailPeerStatus')
'@
$bindingReplacement = @'
    $DetailPeerIp = $window.FindName('DetailPeerIp')
    $ChangeTargetButton = $window.FindName('ChangeTargetButton')
    $DetailPeerStatus = $window.FindName('DetailPeerStatus')
'@
$text = Replace-ExactOnce $text $bindingMarker $bindingReplacement 'change target binding'

$targetFunctions = @'
    function Test-TargetPeerInput {
        param([string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
        $candidate = $Value.Trim()
        if ($candidate.Length -gt 255 -or $candidate -match '[\r\n\s]') { return $false }

        $address = $null
        if ([System.Net.IPAddress]::TryParse($candidate, [ref]$address)) { return $true }

        return [bool]($candidate -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$')
    }

    function Save-TargetPeer {
        param([string]$Value)

        $candidate = if ($Value) { $Value.Trim() } else { '' }
        if (-not (Test-TargetPeerInput $candidate)) {
            throw 'Enter a valid Tailscale IP or MagicDNS name.'
        }

        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        $temp = "$ConfigPath.$PID.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)

        try {
            [IO.File]::WriteAllText(
                $temp,
                ([ordered]@{ peer = $candidate } | ConvertTo-Json -Depth 3),
                $encoding
            )
            Move-Item -LiteralPath $temp -Destination $ConfigPath -Force
        }
        finally {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }

        $script:Peer = $candidate
        $DetailPeerIp.Text = $candidate
        try { $RemotePeerIpText.Text = $candidate } catch {}
        try {
            $script:lastAppliedStateWriteUtc = [DateTime]::MinValue
            $script:lastData = $null
            Reset-Ui -SkipEngineCheck
        } catch {}
    }

    function Show-TargetPeerDialog {
        [xml]$targetXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Target device"
        Width="470" Height="270"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0A0D12" Foreground="#F7F8FA"
        FontFamily="Segoe UI" ShowInTaskbar="False">
    <Border Margin="18" Padding="22" CornerRadius="12"
            Background="#11151B" BorderBrush="#29313C" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Text="Target device" FontSize="18" FontWeight="SemiBold"/>
            <TextBlock Grid.Row="1" Margin="0,6,0,0"
                       Text="Enter the Tailscale IP or MagicDNS name of the PC, server or VPS you want Quick Repair to check."
                       Foreground="#8F9BA8" FontSize="11" TextWrapping="Wrap"/>
            <StackPanel Grid.Row="2" Margin="0,18,0,0">
                <TextBox x:Name="TargetInput" Height="38" Padding="10,7"
                         Background="#151A21" Foreground="#F7F8FA"
                         BorderBrush="#354052" BorderThickness="1" FontSize="13"/>
                <TextBlock x:Name="TargetError" Margin="2,6,0,0"
                           Foreground="#FF6B78" FontSize="10.5" Visibility="Collapsed"/>
            </StackPanel>
            <StackPanel Grid.Row="3" Margin="0,18,0,0" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="CancelTarget" Width="86" Height="34" Margin="0,0,8,0"
                        Background="#1B222D" Foreground="#D8E0EA" BorderBrush="Transparent" Content="Cancel"/>
                <Button x:Name="SaveTarget" Width="100" Height="34"
                        Background="#0866FF" Foreground="White" BorderBrush="Transparent"
                        FontWeight="SemiBold" Content="Save"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

        $reader = New-Object System.Xml.XmlNodeReader $targetXaml
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        $dialog.Owner = $window
        $input = $dialog.FindName('TargetInput')
        $errorText = $dialog.FindName('TargetError')
        $save = $dialog.FindName('SaveTarget')
        $cancel = $dialog.FindName('CancelTarget')
        $input.Text = if ($Peer) { $Peer } else { '' }

        $cancel.Add_Click({ $dialog.DialogResult = $false; $dialog.Close() })
        $save.Add_Click({
            try {
                Save-TargetPeer $input.Text
                $dialog.DialogResult = $true
                $dialog.Close()
            }
            catch {
                $errorText.Text = $_.Exception.Message
                $errorText.Visibility = [System.Windows.Visibility]::Visible
                $input.Focus() | Out-Null
                $input.SelectAll()
            }
        })
        $dialog.Add_ContentRendered({ $input.Focus() | Out-Null; $input.SelectAll() })
        [void]$dialog.ShowDialog()
    }

'@
$text = Replace-ExactOnce $text '    function Invoke-InstallationRepair {' ($targetFunctions + '    function Invoke-InstallationRepair {') 'target functions'

$repairPattern = '(?s)    function Invoke-InstallationRepair \{.*?\r?\n    function Update-DetailsToggleText \{'
$repairReplacement = @'
    function Invoke-InstallationRepair {
        if (-not (Test-Path -LiteralPath $SetupHostPath)) {
            Set-Badge $HeroBadge $HeroBadgeText 'SETUP ISSUE' 'failure'
            $HeroTitle.Text = 'Installation repair is unavailable'
            $HeroDetail.Text = 'Run the latest Tailscale Quick Repair Setup to restore the maintenance component.'
            return
        }

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $SetupHostPath
            $psi.Arguments = '--repair'
            $psi.UseShellExecute = $true
            $process = [System.Diagnostics.Process]::Start($psi)
            if (-not $process) { throw 'The maintenance helper could not start.' }

            Set-Badge $HeroBadge $HeroBadgeText 'MAINTENANCE' 'repairing'
            $HeroTitle.Text = 'Repairing Quick Repair'
            $HeroDetail.Text = 'Approve the Windows prompt. Quick Repair will rebuild its protected integration and reopen automatically.'
            $RepairInstallationButton.IsEnabled = $false
            $script:allowFullExit = $true
            $global:TqrUiShutdownRequested = $true

            $window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{
                    try { $window.Close() } catch {}
                }
            ) | Out-Null
        }
        catch {
            $RepairInstallationButton.IsEnabled = $true
            Set-Badge $HeroBadge $HeroBadgeText 'SETUP ISSUE' 'failure'
            $HeroTitle.Text = 'Could not start installation repair'
            $HeroDetail.Text = $_.Exception.Message
        }
    }

    function Update-DetailsToggleText {
'@
$text = Replace-RegexLiteralOnce `
    -Text $text `
    -Pattern $repairPattern `
    -Replacement $repairReplacement `
    -Description 'native installation repair function'

$eventMarker = @'
    $RepairInstallationButton.Add_Click({
        Invoke-InstallationRepair
    })
'@
$eventReplacement = @'
    $ChangeTargetButton.Add_Click({
        Show-TargetPeerDialog
    })

    $RepairInstallationButton.Add_Click({
        Invoke-InstallationRepair
    })
'@
$text = Replace-ExactOnce $text $eventMarker $eventReplacement 'change target event'

$startupMarker = @'
                Initialize-AutoRepairUi
                Register-ReliabilityWatchers
                Initialize-AutoRepairLocalWatch
                Show-UpdateResult
                [void](Get-ActiveOperationLock -RecoverStale)

                if (-not (Attach-To-RunningRepair)) {
'@
$startupReplacement = @'
                Initialize-AutoRepairUi
                Register-ReliabilityWatchers
                Initialize-AutoRepairLocalWatch
                Show-UpdateResult
                [void](Get-ActiveOperationLock -RecoverStale)

                if (-not $StartInTray -and [string]::IsNullOrWhiteSpace($Peer)) {
                    [void](Show-TargetPeerDialog)
                }

                if (-not (Attach-To-RunningRepair)) {
'@
$text = Replace-ExactOnce $text $startupMarker $startupReplacement 'first run target prompt'

foreach ($required in @(
    '$SetupHostPath',
    'x:Name="ChangeTargetButton"',
    'function Show-TargetPeerDialog',
    'function Save-TargetPeer',
    "`$psi.Arguments = '--repair'",
    '--start-in-tray',
    '*Launch-Tailscale-Backend.vbs*'
)) {
    if ($text -notmatch [regex]::Escape($required)) {
        throw "Public UI verification failed: $required"
    }
}

$headerCount = [regex]::Matches(
    $text,
    '(?m)^param\(\r?\n\s*\[switch\]\$StartInTray\r?\n\)'
).Count
$xamlCount = [regex]::Matches(
    $text,
    '(?m)^\s*\[xml\]\$xaml\s*=\s*@"'
).Count

if ($headerCount -ne 1 -or $xamlCount -ne 1) {
    throw "Packaged UI must contain one script only. Headers=$headerCount Xaml=$xamlCount"
}

[void][scriptblock]::Create($text)
$xamlMatch = [regex]::Match($text, '(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
if (-not $xamlMatch.Success) { throw 'Public UI XAML block was not found.' }
[xml]$xamlDoc = $xamlMatch.Groups['xaml'].Value

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($Path, $text, $utf8Bom)
Write-Host "Public UI transform passed: $Version ($VersionCode)"
