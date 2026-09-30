param(
    [switch]$StartInTray
)

$ErrorActionPreference = 'Stop'

$StateDir = Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$ConfigPath = Join-Path $StateDir 'config.json'
$Peer = ''

try {
    if (Test-Path -LiteralPath $ConfigPath) {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $candidate = [string]$config.peer

        if (
            -not [string]::IsNullOrWhiteSpace($candidate) -and
            $candidate.Length -le 255 -and
            $candidate -notmatch '[\r\n]'
        ) {
            $Peer = $candidate.Trim()
        }
    }
}
catch {}

$TaskName = 'Tailscale Quick Repair'
$ProductVersion = '3.0.0-phase2.2.1'
$ProductVersionCode = [int64]30000211
$StableUpdateManifestApiUrl = 'https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/latest.json?ref=main'
$PreviewUpdateManifestApiUrl = 'https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/preview.json?ref=preview'
$UpdateChannelRegistryPath = 'HKCU:\Software\TailscaleQuickRepair'
$UpdateChannelRegistryName = 'UpdateChannel'
$BackendPath = Join-Path $env:ProgramData 'TailscaleQuickRepair\Repair-Backend.ps1'
$BackendLauncherPath = Join-Path $env:ProgramData 'TailscaleQuickRepair\Launch-Tailscale-Backend.vbs'
$RepairInstallPath = Join-Path $env:ProgramData 'TailscaleQuickRepair\Repair-Installation.ps1'
$StateFile = Join-Path $StateDir 'state.json'
$UiLauncherPath = Join-Path $StateDir 'Launch-Tailscale-Quick-Repair.vbs'
$NativeHostPath = Join-Path $StateDir 'TailscaleQuickRepair.exe'
$StartMenuShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Tailscale Quick Repair.lnk'
$StartupLauncherPath = Join-Path $StateDir 'Launch-Tailscale-Quick-Repair-Startup.vbs'
$StartupRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$StartupRegistryName = 'Tailscale Quick Repair'
$AdvancedDiagnosticsPath = Join-Path $StateDir 'Advanced-Diagnostics.ps1'
$AdvancedDiagnosticsStateFile = Join-Path $env:TEMP 'TailscaleQuickRepair-AdvancedDiagnostics.json'
$AutoRepairTaskName = 'Tailscale Quick Repair Auto Monitor'
$AutoRepairSettingsPath = Join-Path $StateDir 'auto-repair.json'
$AutoRepairStatePath = Join-Path $StateDir 'auto-repair-state.json'
$AutoRepairMonitorPath = Join-Path $env:ProgramData 'TailscaleQuickRepair\Auto-Repair-Monitor.ps1'
$UpdaterHostPath = Join-Path $StateDir 'TailscaleQuickRepairUpdater.exe'
$UpdateInstallerPath = Join-Path $env:ProgramData 'TailscaleQuickRepair\Update-Installer.ps1'
$UpdateResultPath = Join-Path $StateDir 'update-result.json'
$OperationLockPath = Join-Path $StateDir 'operation.lock'
$OperationsLibraryPath = Join-Path $StateDir 'TailscaleQuickRepair.Operations.dll'

# ------------------------------------------------------------------
# Single-instance behaviour.
# A second click focuses the existing window instead of opening a copy.
# ------------------------------------------------------------------
$createdNew = $false
$instanceMutex = New-Object System.Threading.Mutex(
    $true,
    'Local\TailscaleQuickRepair.UI',
    [ref]$createdNew
)

$activateEvent = New-Object System.Threading.EventWaitHandle(
    $false,
    [System.Threading.EventResetMode]::AutoReset,
    'Local\TailscaleQuickRepair.Activate'
)

if (-not $createdNew) {
    try { $activateEvent.Set() | Out-Null } catch {}
    try { $activateEvent.Dispose() } catch {}
    try { $instanceMutex.Dispose() } catch {}
    return
}

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --------------------------------------------------------------
    # Helpers
    # --------------------------------------------------------------
    function Get-Brush {
        param([string]$Name)

        try {
            return $window.Resources[$Name]
        }
        catch {
            return [System.Windows.Media.Brushes]::Transparent
        }
    }

    function Set-Badge {
        param(
            $Border,
            $TextBlock,
            [string]$Text,
            [string]$Tone = 'idle'
        )

        $TextBlock.Text = $Text

        switch ($Tone) {
            'success' {
                $Border.Background = Get-Brush 'GreenSoft'
                $TextBlock.Foreground = Get-Brush 'Green'
            }
            'warning' {
                $Border.Background = Get-Brush 'AmberSoft'
                $TextBlock.Foreground = Get-Brush 'Amber'
            }
            'failure' {
                $Border.Background = Get-Brush 'RedSoft'
                $TextBlock.Foreground = Get-Brush 'Red'
            }
            'checking' {
                $Border.Background = Get-Brush 'BlueSoft'
                $TextBlock.Foreground = Get-Brush 'Blue'
            }
            'repairing' {
                $Border.Background = Get-Brush 'PurpleSoft'
                $TextBlock.Foreground = Get-Brush 'Purple'
            }
            default {
                $Border.Background = Get-Brush 'Surface3'
                $TextBlock.Foreground = Get-Brush 'Muted'
            }
        }
    }

    function Set-Step {
        param(
            $Dot,
            $TextBlock,
            [string]$State
        )

        switch ($State) {
            'good' {
                $Dot.Fill = Get-Brush 'Green'
                $TextBlock.Foreground = Get-Brush 'Green'
            }
            'warn' {
                $Dot.Fill = Get-Brush 'Amber'
                $TextBlock.Foreground = Get-Brush 'Amber'
            }
            'bad' {
                $Dot.Fill = Get-Brush 'Red'
                $TextBlock.Foreground = Get-Brush 'Red'
            }
            'active' {
                $Dot.Fill = Get-Brush 'Blue'
                $TextBlock.Foreground = Get-Brush 'Blue'
            }
            default {
                $Dot.Fill = Get-Brush 'Faint'
                $TextBlock.Foreground = Get-Brush 'Muted'
            }
        }
    }

    function Fade-In {
        param(
            [System.Windows.UIElement]$Element,
            [double]$From = 0.55,
            [int]$Milliseconds = 170
        )

        if (-not $Element) { return }

        try {
            if (-not [System.Windows.SystemParameters]::ClientAreaAnimation) {
                $Element.Opacity = 1
                return
            }
            $Element.Opacity = $From
            $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
            $animation.From = $From
            $animation.To = 1
            $animation.Duration = [TimeSpan]::FromMilliseconds($Milliseconds)
            $Element.BeginAnimation(
                [System.Windows.UIElement]::OpacityProperty,
                $animation
            )
        }
        catch {
            try { $Element.Opacity = 1 } catch {}
        }
    }

    function Test-TailscaleClientProcess {
        return [bool](Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue)
    }

    function Get-TailscaleService {
        return Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    }

    function Ensure-TailscaleClient {
        if (Test-TailscaleClientProcess) {
            return 'Running'
        }

        $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale-ipn.exe'

        if (-not (Test-Path -LiteralPath $candidate)) {
            return 'Missing'
        }

        try {
            Start-Process -FilePath $candidate -WindowStyle Hidden | Out-Null
        }
        catch {
            return 'Failed'
        }

        $deadline = (Get-Date).AddSeconds(7)

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250

            if (Test-TailscaleClientProcess) {
                return 'Started'
            }
        }

        return 'Failed'
    }

    function Invoke-RepairTask {
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $folder = $null
        $task = $null

        try {
            $scheduler.Connect()
            $folder = $scheduler.GetFolder('\')
            $task = $folder.GetTask($TaskName)

            if (-not $task) {
                throw 'The protected repair task is missing.'
            }

            [void]$task.Run($null)
            return $true
        }
        finally {
            foreach ($obj in @($task, $folder, $scheduler)) {
                if ($obj) {
                    try {
                        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)
                    } catch {}
                }
            }
        }
    }

    function Invoke-AutoRepairMonitorNow {
        if (-not (Test-Path -LiteralPath $AutoRepairMonitorPath)) {
            return $false
        }

        try {
            $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $powershellPath
            $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $AutoRepairMonitorPath + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            [void][System.Diagnostics.Process]::Start($psi)
            return $true
        }
        catch {
            return $false
        }
    }

    # --------------------------------------------------------------
    # XAML
    # --------------------------------------------------------------
    [xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Tailscale Quick Repair"
    WindowState="Maximized"
    WindowStyle="SingleBorderWindow"
    ResizeMode="CanResize"
    MinWidth="1000"
    MinHeight="720"
    Background="#0A0D12"
    Foreground="#F7F8FA"
    FontFamily="Segoe UI"
    UseLayoutRounding="True"
    SnapsToDevicePixels="True"
    KeyboardNavigation.TabNavigation="Continue"
    KeyboardNavigation.ControlTabNavigation="Continue"
    TextOptions.TextFormattingMode="Display"
    TextOptions.TextRenderingMode="ClearType">

    <Window.Resources>
        <SolidColorBrush x:Key="Bg" Color="#0A0D12"/>
        <SolidColorBrush x:Key="Surface" Color="#11151B"/>
        <SolidColorBrush x:Key="Surface2" Color="#151A21"/>
        <SolidColorBrush x:Key="Surface3" Color="#1B222D"/>
        <SolidColorBrush x:Key="Border" Color="#29313C"/>
        <SolidColorBrush x:Key="Text" Color="#F7F8FA"/>
        <SolidColorBrush x:Key="Value" Color="#D8E0EA"/>
        <SolidColorBrush x:Key="Muted" Color="#8F9BA8"/>
        <SolidColorBrush x:Key="Faint" Color="#667386"/>
        <SolidColorBrush x:Key="Blue" Color="#0866FF"/>
        <SolidColorBrush x:Key="BlueHover" Color="#1B74FF"/>
        <SolidColorBrush x:Key="BluePressed" Color="#0759DE"/>
        <SolidColorBrush x:Key="BlueSoft" Color="#13274A"/>
        <SolidColorBrush x:Key="Green" Color="#5EE0AF"/>
        <SolidColorBrush x:Key="GreenSoft" Color="#112820"/>
        <SolidColorBrush x:Key="Amber" Color="#F2C55C"/>
        <SolidColorBrush x:Key="AmberSoft" Color="#2B2414"/>
        <SolidColorBrush x:Key="Red" Color="#FF6B78"/>
        <SolidColorBrush x:Key="RedSoft" Color="#2C171B"/>
        <SolidColorBrush x:Key="Purple" Color="#B9A7FF"/>
        <SolidColorBrush x:Key="PurpleSoft" Color="#241D36"/>

        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="{StaticResource Blue}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="24,0"/>
            <Setter Property="Height" Value="48"/>
            <Setter Property="MinWidth" Value="178"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border
                            x:Name="ButtonBorder"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="9">
                            <ContentPresenter
                                HorizontalAlignment="Center"
                                VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource BlueHover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource BluePressed}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#78A9FF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#1A2433"/>
                                <Setter Property="Foreground" Value="#6E829F"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SecondaryButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Background" Value="{StaticResource Surface3}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="24,0"/>
            <Setter Property="Height" Value="48"/>
            <Setter Property="MinWidth" Value="178"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border
                            x:Name="ButtonBorder"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="9">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#222C3B"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#18202C"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#52667F"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#161C25"/>
                                <Setter Property="Foreground" Value="#667386"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="GhostButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="#9CB0CC"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="MinHeight" Value="24"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border
                            x:Name="GhostBorder"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="5"
                            Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="#C8D6E8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Foreground" Value="#7F93AF"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="GhostBorder" Property="BorderBrush" Value="#43546A"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#4C5868"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Background="{StaticResource Bg}">
        <ScrollViewer
            x:Name="MainScrollViewer"
            VerticalScrollBarVisibility="Auto"
            HorizontalScrollBarVisibility="Disabled"
            Background="{StaticResource Bg}">
            <Grid MaxWidth="1180" Margin="36,0,36,30">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Brand -->
                <Grid Grid.Row="0" Margin="0,24,0,26">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border
                        Width="44"
                        Height="44"
                        CornerRadius="8"
                        Background="#121925"
                        VerticalAlignment="Center">
                        <Canvas Width="28" Height="28" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <Ellipse Width="5" Height="5" Fill="{StaticResource Blue}" Canvas.Left="11.5" Canvas.Top="1"/>
                            <Ellipse Width="5" Height="5" Fill="{StaticResource Blue}" Canvas.Left="2" Canvas.Top="6"/>
                            <Ellipse Width="5" Height="5" Fill="{StaticResource Blue}" Canvas.Left="21" Canvas.Top="6"/>
                            <Ellipse Width="5" Height="5" Fill="{StaticResource Blue}" Canvas.Left="11.5" Canvas.Top="11.5"/>
                            <Ellipse Width="5" Height="5" Fill="{StaticResource Blue}" Canvas.Left="2" Canvas.Top="17"/>
                            <Ellipse Width="5" Height="5" Fill="{StaticResource Blue}" Canvas.Left="21" Canvas.Top="17"/>
                            <Ellipse Width="5" Height="5" Fill="{StaticResource Blue}" Canvas.Left="11.5" Canvas.Top="22"/>
                        </Canvas>
                    </Border>

                    <StackPanel Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
                        <TextBlock
                            Text="Tailscale Quick Repair"
                            FontSize="22"
                            FontWeight="SemiBold"
                            Foreground="{StaticResource Text}"/>
                        <TextBlock
                            Text="Connection health &amp; repair"
                            Margin="0,3,0,0"
                            FontSize="12"
                            Foreground="{StaticResource Muted}"/>
                    </StackPanel>
                </Grid>

                <!-- Hero -->
                <Border
                    Grid.Row="1"
                    Background="{StaticResource Surface}"
                    BorderBrush="{StaticResource Border}"
                    BorderThickness="1"
                    CornerRadius="10"
                    Padding="28,28"
                    Margin="0,0,0,20">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel>
                            <Border
                                x:Name="HeroBadge"
                                HorizontalAlignment="Left"
                                Background="{StaticResource BlueSoft}"
                                CornerRadius="8"
                                Padding="10,6"
                                Margin="0,0,0,18">
                                <TextBlock
                                    x:Name="HeroBadgeText"
                                    Text="READY"
                                    FontSize="10"
                                    FontWeight="Bold"
                                    Foreground="{StaticResource Blue}"/>
                            </Border>

                            <TextBlock
                                x:Name="HeroTitle"
                                Text="Ready to check"
                                FontSize="30"
                                FontWeight="SemiBold"
                                Foreground="{StaticResource Text}"/>

                            <TextBlock
                                x:Name="HeroDetail"
                                Text="Check Tailscale and repair only what is necessary."
                                Margin="0,10,0,0"
                                FontSize="14"
                                Foreground="{StaticResource Muted}"
                                TextWrapping="Wrap"/>

                            <TextBlock
                                x:Name="LastCheckedText"
                                Margin="0,9,0,0"
                                FontSize="11"
                                Foreground="{StaticResource Faint}"
                                Visibility="Collapsed"/>
                        </StackPanel>

                        <Button
                            x:Name="PrimaryButton"
                            AutomationProperties.Name="Primary Quick Repair action"
                            AutomationProperties.HelpText="Runs the current Quick Repair check or repair action."
                            Grid.Column="1"
                            Style="{StaticResource PrimaryButtonStyle}"
                            Content="Start Repair"
                            Margin="28,0,0,0"
                            VerticalAlignment="Center"/>
                    </Grid>
                </Border>

                <!-- Steps -->
                <Grid Grid.Row="2" Margin="28,0,28,20">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="AppDot" Width="7" Height="7" Fill="{StaticResource Faint}"/>
                        <TextBlock x:Name="AppStep" Text="App" Margin="10,0,0,0" FontSize="12" Foreground="{StaticResource Muted}"/>
                    </StackPanel>

                    <Border x:Name="PathLine1" Grid.Column="1" Height="1" Margin="18,0" Background="{StaticResource Border}" VerticalAlignment="Center"/>

                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="ServiceDot" Width="7" Height="7" Fill="{StaticResource Faint}"/>
                        <TextBlock x:Name="ServiceStep" Text="Service" Margin="10,0,0,0" FontSize="12" Foreground="{StaticResource Muted}"/>
                    </StackPanel>

                    <Border x:Name="PathLine2" Grid.Column="3" Height="1" Margin="18,0" Background="{StaticResource Border}" VerticalAlignment="Center"/>

                    <StackPanel Grid.Column="4" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="BackendDot" Width="7" Height="7" Fill="{StaticResource Faint}"/>
                        <TextBlock x:Name="BackendStep" Text="Tailscale" Margin="10,0,0,0" FontSize="12" Foreground="{StaticResource Muted}"/>
                    </StackPanel>

                    <Border x:Name="PathLine3" Grid.Column="5" Height="1" Margin="18,0" Background="{StaticResource Border}" VerticalAlignment="Center"/>

                    <StackPanel Grid.Column="6" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="PeerDot" Width="7" Height="7" Fill="{StaticResource Faint}"/>
                        <TextBlock x:Name="PeerStep" Text="Peer" Margin="10,0,0,0" FontSize="12" Foreground="{StaticResource Muted}"/>
                    </StackPanel>
                </Grid>

                <!-- Cards -->
                <Grid Grid.Row="3" Margin="0,0,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="22"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border
                        Grid.Column="0"
                        Background="{StaticResource Surface}"
                        BorderBrush="{StaticResource Border}"
                        BorderThickness="1"
                        CornerRadius="10"
                        Padding="28,26">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="36"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel>
                                    <TextBlock Text="This PC" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                    <TextBlock Text="Local Tailscale" Margin="0,4,0,0" FontSize="13" Foreground="{StaticResource Muted}"/>
                                </StackPanel>

                                <Border
                                    x:Name="LocalBadge"
                                    Grid.Column="1"
                                    CornerRadius="8"
                                    Padding="11,6"
                                    Background="{StaticResource Surface3}"
                                    VerticalAlignment="Top">
                                    <TextBlock
                                        x:Name="LocalBadgeText"
                                        Text="NOT CHECKED"
                                        FontSize="10"
                                        FontWeight="Bold"
                                        Foreground="{StaticResource Muted}"/>
                                </Border>
                            </Grid>

                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="APP" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Faint}"/>
                                    <TextBlock x:Name="LocalAppValue" Text="—" Margin="0,8,0,0" FontSize="14" Foreground="{StaticResource Value}"/>
                                </StackPanel>

                                <StackPanel Grid.Column="1">
                                    <TextBlock Text="SERVICE" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Faint}"/>
                                    <TextBlock x:Name="LocalServiceValue" Text="—" Margin="0,8,0,0" FontSize="14" Foreground="{StaticResource Value}"/>
                                </StackPanel>

                                <StackPanel Grid.Column="2">
                                    <TextBlock Text="BACKEND" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Faint}"/>
                                    <TextBlock x:Name="LocalBackendValue" Text="—" Margin="0,8,0,0" FontSize="14" Foreground="{StaticResource Value}"/>
                                </StackPanel>
                            </Grid>
                        </Grid>
                    </Border>

                    <Border
                        Grid.Column="2"
                        Background="{StaticResource Surface}"
                        BorderBrush="{StaticResource Border}"
                        BorderThickness="1"
                        CornerRadius="10"
                        Padding="28,26">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="36"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel>
                                    <TextBlock x:Name="RemoteTitle" Text="Remote machine" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                    <TextBlock x:Name="RemotePeerIpText" Text="Not configured" Margin="0,4,0,0" FontSize="13" Foreground="{StaticResource Muted}"/>
                                </StackPanel>

                                <Border
                                    x:Name="RemoteBadge"
                                    Grid.Column="1"
                                    CornerRadius="8"
                                    Padding="11,6"
                                    Background="{StaticResource Surface3}"
                                    VerticalAlignment="Top">
                                    <TextBlock
                                        x:Name="RemoteBadgeText"
                                        Text="NOT CHECKED"
                                        FontSize="10"
                                        FontWeight="Bold"
                                        Foreground="{StaticResource Muted}"/>
                                </Border>
                            </Grid>

                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="STATUS" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Faint}"/>
                                    <TextBlock x:Name="RemoteStatusValue" Text="—" Margin="0,8,0,0" FontSize="14" Foreground="{StaticResource Value}"/>
                                </StackPanel>

                                <StackPanel Grid.Column="1">
                                    <TextBlock Text="ROUTE" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Faint}"/>
                                    <TextBlock x:Name="RemoteRouteValue" Text="—" Margin="0,8,0,0" FontSize="14" Foreground="{StaticResource Value}"/>
                                </StackPanel>

                                <StackPanel Grid.Column="2">
                                    <TextBlock Text="LATENCY" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Faint}"/>
                                    <TextBlock x:Name="RemoteLatencyValue" Text="—" Margin="0,8,0,0" FontSize="14" Foreground="{StaticResource Value}"/>
                                </StackPanel>
                            </Grid>

                            <TextBlock
                                x:Name="ConnectionInsightText"
                                Grid.Row="3"
                                Margin="0,15,0,0"
                                FontSize="11.5"
                                Foreground="{StaticResource Faint}"
                                Visibility="Collapsed"
                                TextWrapping="Wrap"/>
                        </Grid>
                    </Border>
                </Grid>

                <!-- Details -->
                <Grid Grid.Row="4" Margin="0,14,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Button
                        x:Name="DetailsButton"
                        AutomationProperties.Name="Details"
                        AutomationProperties.HelpText="Shows or hides connection details, automation, maintenance and diagnostics."
                        Style="{StaticResource GhostButtonStyle}"
                        Content="Details  ›"
                        HorizontalAlignment="Left"
                        Margin="8,0,0,0"/>

                    <Grid
                        x:Name="DetailsPanel"
                        Grid.Row="1"
                        Visibility="Collapsed"
                        Margin="0,14,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0" Height="1" Background="{StaticResource Border}"/>

                        <Grid
                            Grid.Row="1"
                            Margin="22,22,22,8">

                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <!-- Connection + session -->
                            <Grid Grid.Row="0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="34"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="34"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="Local" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                    <Grid Margin="0,16,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="110"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Text="Client" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="1" Text="Service" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="2" Text="Startup" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="3" Text="Backend" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="4" Text="Tailscale IP" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="5" Text="Version" Foreground="{StaticResource Faint}"/>
                                        <TextBlock x:Name="DetailClient" Grid.Row="0" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailService" Grid.Row="1" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailStartup" Grid.Row="2" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailBackend" Grid.Row="3" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailLocalIp" Grid.Row="4" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailVersion" Grid.Row="5" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                    </Grid>
                                </StackPanel>

                                <StackPanel Grid.Column="2">
                                    <TextBlock Text="Remote" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                    <Grid Margin="0,16,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="92"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Text="Device" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="1" Text="Peer IP" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="2" Text="Recent" Foreground="{StaticResource Faint}"/>
                                        <TextBlock x:Name="DetailPeerName" Grid.Row="0" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailPeerIp" Grid.Row="1" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailConnectionTrend" Grid.Row="2" Grid.Column="1" Text="—" Foreground="{StaticResource Value}" TextTrimming="CharacterEllipsis"/>
                                    </Grid>
                                    <StackPanel Visibility="Collapsed">
                                        <TextBlock x:Name="DetailPeerStatus" Text="—"/>
                                        <TextBlock x:Name="DetailRoute" Text="—"/>
                                        <TextBlock x:Name="DetailLatency" Text="—"/>
                                    </StackPanel>
                                </StackPanel>

                                <StackPanel Grid.Column="4">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Text="This session" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                        <Button x:Name="CopyButton" Grid.Column="1" Style="{StaticResource GhostButtonStyle}" Content="Copy"/>
                                    </Grid>

                                    <TextBlock
                                        x:Name="SessionText"
                                        Margin="0,16,0,0"
                                        FontSize="12"
                                        LineHeight="20"
                                        Foreground="{StaticResource Muted}"
                                        TextWrapping="Wrap"
                                        Text="No repair actions yet."/>
                                </StackPanel>
                            </Grid>

                            <!-- Automation + maintenance -->
                            <Grid Grid.Row="1" Margin="0,30,0,0">
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="1"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Border
                                    Grid.Row="0"
                                    Height="1"
                                    Background="{StaticResource Border}"/>

                                <Grid Grid.Row="1" Margin="0,22,0,0">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="44"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>

                                    <StackPanel Grid.Column="0">
                                        <TextBlock
                                            Text="Automation"
                                            FontSize="15"
                                            FontWeight="SemiBold"
                                            Foreground="{StaticResource Text}"/>

                                        <CheckBox
                                            x:Name="StartWithWindowsCheckBox"
                                            AutomationProperties.Name="Start with Windows"
                                            AutomationProperties.HelpText="Starts Quick Repair quietly in the tray when you sign in."
                                            Margin="0,14,0,0"
                                            Foreground="{StaticResource Value}"
                                            FontSize="12"
                                            VerticalContentAlignment="Center"
                                            Content="Start with Windows"/>

                                        <TextBlock
                                            Margin="22,5,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Text="Starts quietly in the tray."
                                            TextWrapping="Wrap"/>

                                        <CheckBox
                                            x:Name="AutoRepairCheckBox"
                                            AutomationProperties.Name="Automatic repair"
                                            AutomationProperties.HelpText="Monitors local Tailscale health and runs the proven repair only when needed."
                                            Margin="0,18,0,0"
                                            Foreground="{StaticResource Value}"
                                            FontSize="12"
                                            VerticalContentAlignment="Center"
                                            Content="Automatic repair"/>

                                        <TextBlock
                                            Margin="22,5,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Text="Repairs local Tailscale only when needed, with a 5-minute fallback."
                                            TextWrapping="Wrap"/>

                                        <TextBlock
                                            x:Name="AutoRepairStatusText"
                                            Margin="22,5,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Text="Off"
                                            TextWrapping="Wrap"/>

                                        <TextBlock
                                            x:Name="AutoRepairLastRepairText"
                                            Margin="22,4,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Visibility="Collapsed"
                                            TextWrapping="Wrap"/>

                                        <TextBlock
                                            x:Name="AutoRepairTriggerText"
                                            Margin="22,4,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Visibility="Collapsed"
                                            Text="Smart triggers active · network / resume / local service &amp; client"
                                            TextWrapping="Wrap"/>

                                        <Button
                                            x:Name="AutoRepairCheckNowButton"
                                            AutomationProperties.Name="Run auto-repair check now"
                                            AutomationProperties.HelpText="Runs the local Auto Repair health check immediately."
                                            Margin="12,8,0,0"
                                            HorizontalAlignment="Left"
                                            Style="{StaticResource GhostButtonStyle}"
                                            Content="Check local health now"/>
                                    </StackPanel>

                                    <StackPanel Grid.Column="2">
                                        <TextBlock
                                            Text="Maintenance"
                                            FontSize="15"
                                            FontWeight="SemiBold"
                                            Foreground="{StaticResource Text}"/>

                                        <Button
                                            x:Name="RepairInstallationButton"
                                            AutomationProperties.Name="Repair Quick Repair installation"
                                            AutomationProperties.HelpText="Rebuilds Quick Repair shell integration, tasks and launchers."
                                            Margin="0,14,0,0"
                                            HorizontalAlignment="Left"
                                            Style="{StaticResource GhostButtonStyle}"
                                            Content="Repair installation"/>

                                        <TextBlock
                                            Margin="12,4,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Text="Rebuilds Quick Repair's Windows integration. Administrator approval required."
                                            TextWrapping="Wrap"/>

                                        <CheckBox
                                            x:Name="EarlyAccessUpdatesCheckBox"
                                            AutomationProperties.Name="Early-access updates"
                                            AutomationProperties.HelpText="Checks the trusted Early-access channel for release candidates before public release."
                                            Margin="0,18,0,0"
                                            Foreground="{StaticResource Value}"
                                            FontSize="12"
                                            VerticalContentAlignment="Center"
                                            Content="Early-access updates"/>

                                        <TextBlock
                                            Margin="22,5,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Text="Release candidates before the public channel. Opt-in only."
                                            TextWrapping="Wrap"/>

                                        <Border
                                            Margin="0,20,0,0"
                                            Height="1"
                                            Background="{StaticResource Border}"/>

                                        <TextBlock
                                            x:Name="UpdateStatusText"
                                            Margin="0,16,0,0"
                                            FontSize="11"
                                            Foreground="{StaticResource Muted}"
                                            Text="Current 3.0.0-phase2.2.1 · Check GitHub for updates."
                                            TextWrapping="Wrap"/>

                                        <TextBlock
                                            x:Name="UpdateDetailText"
                                            Margin="0,4,0,0"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Faint}"
                                            Visibility="Collapsed"
                                            TextWrapping="Wrap"/>

                                        <StackPanel
                                            Margin="0,8,0,0"
                                            Orientation="Horizontal"
                                            HorizontalAlignment="Left">
                                            <Button
                                                x:Name="CheckForUpdatesButton"
                                                AutomationProperties.Name="Check for Quick Repair updates"
                                                AutomationProperties.HelpText="Checks the selected trusted Quick Repair update channel on GitHub."
                                                Style="{StaticResource GhostButtonStyle}"
                                                Content="Check for updates"/>

                                            <Button
                                                x:Name="UpdateNowButton"
                                                AutomationProperties.Name="Install Quick Repair update"
                                                AutomationProperties.HelpText="Downloads, verifies and installs the available Quick Repair update."
                                                Margin="8,0,0,0"
                                                Visibility="Collapsed"
                                                Style="{StaticResource PrimaryButtonStyle}"
                                                Content="Update now"/>
                                        </StackPanel>
                                    </StackPanel>
                                </Grid>
                            </Grid>
                        </Grid>

                        <!-- Advanced diagnostics is intentionally isolated from the
                             core repair/check engine. It is optional and read-only. -->
                        <Grid
                            Grid.Row="2"
                            Margin="22,24,22,10">

                            <Grid.RowDefinitions>
                                <RowDefinition Height="1"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Border
                                Grid.Row="0"
                                Height="1"
                                Background="{StaticResource Border}"/>

                            <Grid Grid.Row="1" Margin="0,18,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="18"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel>
                                    <TextBlock
                                        Text="Advanced diagnostics"
                                        FontSize="15"
                                        FontWeight="SemiBold"
                                        Foreground="{StaticResource Text}"/>
                                    <TextBlock
                                        Text="Optional, read-only network analysis. It never changes the main health result or network settings."
                                        Margin="0,5,0,0"
                                        FontSize="10.5"
                                        Foreground="{StaticResource Faint}"
                                        TextWrapping="Wrap"/>
                                </StackPanel>

                                <Button
                                    x:Name="AdvancedCopyButton"
                                    AutomationProperties.Name="Copy advanced diagnostics report"
                                    Grid.Column="1"
                                    Visibility="Collapsed"
                                    Style="{StaticResource GhostButtonStyle}"
                                    Content="Copy report"/>

                                <Button
                                    x:Name="AdvancedDiagnosticsButton"
                                    AutomationProperties.Name="Run advanced diagnostics"
                                    AutomationProperties.HelpText="Runs optional read-only network diagnostics."
                                    Grid.Column="3"
                                    Style="{StaticResource GhostButtonStyle}"
                                    Content="Run diagnostics"/>
                            </Grid>

                            <StackPanel
                                x:Name="AdvancedDiagnosticsPanel"
                                Grid.Row="2"
                                Visibility="Collapsed"
                                Margin="0,16,0,0">

                                <TextBlock
                                    x:Name="AdvancedDiagnosticsSummary"
                                    FontSize="11.5"
                                    Foreground="{StaticResource Muted}"
                                    TextWrapping="Wrap"/>

                                <ProgressBar
                                    x:Name="AdvancedDiagnosticsProgress"
                                    Height="2"
                                    Margin="0,10,0,0"
                                    Minimum="0"
                                    Maximum="100"
                                    Value="0"
                                    Foreground="{StaticResource Blue}"
                                    Background="{StaticResource Border}"/>

                                <Grid Margin="0,16,0,0">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="34"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="34"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>

                                    <StackPanel Grid.Column="0">
                                        <TextBlock Text="Network" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Value}"/>
                                        <TextBlock
                                            x:Name="AdvancedNetworkText"
                                            Margin="0,7,0,0"
                                            FontFamily="Consolas"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Muted}"
                                            TextWrapping="Wrap"/>
                                    </StackPanel>

                                    <StackPanel Grid.Column="2">
                                        <TextBlock Text="Peer" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Value}"/>
                                        <TextBlock
                                            x:Name="AdvancedPeerText"
                                            Margin="0,7,0,0"
                                            FontFamily="Consolas"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Muted}"
                                            TextWrapping="Wrap"/>
                                    </StackPanel>

                                    <StackPanel Grid.Column="4">
                                        <TextBlock Text="Environment" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Value}"/>
                                        <TextBlock
                                            x:Name="AdvancedEnvironmentText"
                                            Margin="0,7,0,0"
                                            FontFamily="Consolas"
                                            FontSize="10.5"
                                            Foreground="{StaticResource Muted}"
                                            TextWrapping="Wrap"/>
                                    </StackPanel>
                                </Grid>
                            </StackPanel>
                        </Grid>
                    </Grid>
                </Grid>

                <Border Grid.Row="5" Height="1" Background="Transparent"/>
            </Grid>
        </ScrollViewer>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # --------------------------------------------------------------
    # Bind UI controls
    # --------------------------------------------------------------
    $HeroBadge = $window.FindName('HeroBadge')
    $HeroBadgeText = $window.FindName('HeroBadgeText')
    $HeroTitle = $window.FindName('HeroTitle')
    $HeroDetail = $window.FindName('HeroDetail')
    $LastCheckedText = $window.FindName('LastCheckedText')
    $PrimaryButton = $window.FindName('PrimaryButton')

    $AppDot = $window.FindName('AppDot')
    $ServiceDot = $window.FindName('ServiceDot')
    $BackendDot = $window.FindName('BackendDot')
    $PeerDot = $window.FindName('PeerDot')

    $AppStep = $window.FindName('AppStep')
    $ServiceStep = $window.FindName('ServiceStep')
    $BackendStep = $window.FindName('BackendStep')
    $PeerStep = $window.FindName('PeerStep')

    $PathLine1 = $window.FindName('PathLine1')
    $PathLine2 = $window.FindName('PathLine2')
    $PathLine3 = $window.FindName('PathLine3')

    $LocalBadge = $window.FindName('LocalBadge')
    $LocalBadgeText = $window.FindName('LocalBadgeText')
    $LocalAppValue = $window.FindName('LocalAppValue')
    $LocalServiceValue = $window.FindName('LocalServiceValue')
    $LocalBackendValue = $window.FindName('LocalBackendValue')

    $RemoteTitle = $window.FindName('RemoteTitle')
    $RemotePeerIpText = $window.FindName('RemotePeerIpText')
    $RemoteBadge = $window.FindName('RemoteBadge')
    $RemoteBadgeText = $window.FindName('RemoteBadgeText')
    $RemoteStatusValue = $window.FindName('RemoteStatusValue')
    $RemoteRouteValue = $window.FindName('RemoteRouteValue')
    $RemoteLatencyValue = $window.FindName('RemoteLatencyValue')
    $ConnectionInsightText = $window.FindName('ConnectionInsightText')

    $DetailsButton = $window.FindName('DetailsButton')
    $DetailsPanel = $window.FindName('DetailsPanel')
    $MainScrollViewer = $window.FindName('MainScrollViewer')
    $CopyButton = $window.FindName('CopyButton')
    $DetailClient = $window.FindName('DetailClient')
    $DetailService = $window.FindName('DetailService')
    $DetailStartup = $window.FindName('DetailStartup')
    $DetailBackend = $window.FindName('DetailBackend')
    $DetailLocalIp = $window.FindName('DetailLocalIp')
    $DetailVersion = $window.FindName('DetailVersion')
    $DetailPeerName = $window.FindName('DetailPeerName')
    $DetailPeerIp = $window.FindName('DetailPeerIp')
    $DetailPeerStatus = $window.FindName('DetailPeerStatus')
    $DetailRoute = $window.FindName('DetailRoute')
    $DetailLatency = $window.FindName('DetailLatency')
    $DetailConnectionTrend = $window.FindName('DetailConnectionTrend')
    $SessionText = $window.FindName('SessionText')
    $StartWithWindowsCheckBox = $window.FindName('StartWithWindowsCheckBox')
    $AutoRepairCheckBox = $window.FindName('AutoRepairCheckBox')
    $AutoRepairStatusText = $window.FindName('AutoRepairStatusText')
    $AutoRepairLastRepairText = $window.FindName('AutoRepairLastRepairText')
    $AutoRepairTriggerText = $window.FindName('AutoRepairTriggerText')
    $AutoRepairCheckNowButton = $window.FindName('AutoRepairCheckNowButton')
    $RepairInstallationButton = $window.FindName('RepairInstallationButton')
    $UpdateStatusText = $window.FindName('UpdateStatusText')
    $UpdateDetailText = $window.FindName('UpdateDetailText')
    $CheckForUpdatesButton = $window.FindName('CheckForUpdatesButton')
    $UpdateNowButton = $window.FindName('UpdateNowButton')
    $EarlyAccessUpdatesCheckBox = $window.FindName('EarlyAccessUpdatesCheckBox')
    $AdvancedDiagnosticsButton = $window.FindName('AdvancedDiagnosticsButton')
    $AdvancedCopyButton = $window.FindName('AdvancedCopyButton')
    $AdvancedDiagnosticsPanel = $window.FindName('AdvancedDiagnosticsPanel')
    $AdvancedDiagnosticsSummary = $window.FindName('AdvancedDiagnosticsSummary')
    $AdvancedDiagnosticsProgress = $window.FindName('AdvancedDiagnosticsProgress')
    $AdvancedNetworkText = $window.FindName('AdvancedNetworkText')
    $AdvancedPeerText = $window.FindName('AdvancedPeerText')
    $AdvancedEnvironmentText = $window.FindName('AdvancedEnvironmentText')

    $peerDisplay = if ([string]::IsNullOrWhiteSpace($Peer)) {
        'Not configured'
    } else {
        $Peer
    }

    $RemotePeerIpText.Text = $peerDisplay
    $DetailPeerIp.Text = $peerDisplay

    try {
        $RepairInstallationButton.IsEnabled = (
            Test-Path -LiteralPath $RepairInstallPath
        )
    } catch {}

    # --------------------------------------------------------------
    # Runtime state
    # --------------------------------------------------------------
    $script:repairActive = $false
    $script:actionMode = 'repair'
    $script:launchUtc = [DateTime]::UtcNow
    $script:lastFreshStateUtc = $null
    $script:lastAppliedStateWriteUtc = [DateTime]::MinValue
    $script:lastData = $null
    $script:lastCompletedAt = [DateTime]::MinValue
    $script:lastDuration = ''
    $script:lastRepairSummary = ''
    $script:copyDiagnosticsText = ''
    $script:detailsOpen = $false
    $script:notifiedForCurrentRun = $false
    $script:lastHeroSignature = ''
    $script:lastUpdateSignature = ''
    $script:lastRenderedState = ''
    $script:environmentStale = $false
    $script:environmentStaleReason = ''
    $script:lastEnvironmentChangedAt = [DateTime]::MinValue
    $script:reliabilityEvents = New-Object 'System.Collections.Generic.List[string]'

    # Connection intelligence is deliberately session-only.
    $script:connectionSamples = New-Object 'System.Collections.Generic.List[object]'
    $script:connectionEvents = New-Object 'System.Collections.Generic.List[string]'
    $script:lastConnectionInsight = ''
    $script:lastProcessedConnectionStamp = ''

    # VPN-safe environment watcher: polling runs on the WPF dispatcher rather
    # than subscribing PowerShell delegates to native worker-thread events.
    $script:lastReliabilityPollAt = [DateTime]::MinValue
    $script:lastNetworkSignature = ''

    $script:hiddenToTray = $false
    $script:allowFullExit = $false
    $script:trayHintShown = $false
    $script:notifyIcon = $null
    $script:trayMenu = $null
    $script:trayStatusItem = $null
    $script:trayFreshnessItem = $null
    $script:trayCheckItem = $null
    $script:trayCopyStatusItem = $null
    $script:trayCopyPeerIpItem = $null
    $script:trayOpenItem = $null
    $script:trayExitItem = $null

    $script:advancedDiagnosticsProcess = $null
    $script:advancedDiagnosticsTimer = $null
    $script:advancedDiagnosticsRunId = ''
    $script:advancedDiagnosticsStartedAt = [DateTime]::MinValue
    $script:advancedDiagnosticsReport = ''

    $script:autoRepairAvailable = $false
    $script:autoRepairAvailabilityCheckedAt = [DateTime]::MinValue
    $script:initializingAutoRepair = $false

    # Smart Auto Repair trigger coordinator. Session-only and local-only.
    $script:autoRepairTriggerTimer = $null
    $script:autoRepairLocalWatchTimer = $null
    $script:autoRepairTriggerReason = ''
    $script:autoRepairTriggerQueuedAt = [DateTime]::MinValue
    $script:autoRepairLastTriggerAt = [DateTime]::MinValue
    $script:autoRepairLastServiceState = ''
    $script:autoRepairLastClientState = ''
    $script:autoRepairWatchInitialized = $false

    # Trusted GitHub update channel + staged self-update.
    $script:updateCheckActive = $false
    $script:updateWebClient = $null
    $script:updateCheckTask = $null
    $script:updateCheckTimer = $null
    $script:updateCheckStartedAt = [DateTime]::MinValue
    $script:updateManifest = $null
    $script:updateChannel = 'stable'
    $script:updateCheckChannel = ''
    $script:updateManifestChannel = ''
    $script:initializingUpdateChannel = $false

    $script:updateDownloadActive = $false
    $script:updateDownloadClient = $null
    $script:updateDownloadTask = $null
    $script:updateDownloadTimer = $null
    $script:updatePackagePath = ''
    $script:updateExpectedSize = [int64]0

    $script:actionMode = 'repair'
    $script:engineHealthy = $false
    $script:lastEngineCheckAt = [DateTime]::MinValue
    $script:residentRuntimeStarted = $false
    $script:startupInitializationDone = $false

    function Get-LatencyMilliseconds {
        param($Value)

        if ([string]$Value -match '^([0-9]+(?:\.[0-9]+)?)') {
            return [double]$Matches[1]
        }

        return [double]::NaN
    }

    function Get-RouteClass {
        param([string]$Route)

        if ([string]::IsNullOrWhiteSpace($Route)) {
            return 'Unknown'
        }

        if ($Route -eq 'Direct') {
            return 'Direct'
        }

        if ($Route -like 'Relay*') {
            return 'Relay'
        }

        if ($Route -like '*peer relay*') {
            return 'Peer relay'
        }

        return $Route
    }

    function Add-ConnectionEvent {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return
        }

        try {
            $script:connectionEvents.Add("$(Get-Date -Format 'HH:mm') · $Text")

            while ($script:connectionEvents.Count -gt 4) {
                $script:connectionEvents.RemoveAt(0)
            }
        } catch {}
    }

    function Set-ConnectionInsight {
        param(
            [string]$Text,
            [string]$Tone = 'muted'
        )

        $script:lastConnectionInsight = $Text

        if ([string]::IsNullOrWhiteSpace($Text)) {
            $ConnectionInsightText.Text = ''
            $ConnectionInsightText.Visibility = [System.Windows.Visibility]::Collapsed
            $DetailConnectionTrend.Text = '—'
            $DetailConnectionTrend.Foreground = Get-Brush 'Value'
            return
        }

        $ConnectionInsightText.Text = $Text
        $ConnectionInsightText.Visibility = [System.Windows.Visibility]::Visible
        $DetailConnectionTrend.Text = $Text

        switch ($Tone) {
            'good' {
                $ConnectionInsightText.Foreground = Get-Brush 'Green'
                $DetailConnectionTrend.Foreground = Get-Brush 'Green'
            }

            'warn' {
                $ConnectionInsightText.Foreground = Get-Brush 'Amber'
                $DetailConnectionTrend.Foreground = Get-Brush 'Amber'
            }

            default {
                $ConnectionInsightText.Foreground = Get-Brush 'Faint'
                $DetailConnectionTrend.Foreground = Get-Brush 'Value'
            }
        }

        Fade-In $ConnectionInsightText 0.55 170
    }

    function Update-ConnectionIntelligence {
        param($Data)

        if (
            -not $Data -or
            -not [bool]$Data.done -or
            [string]$Data.peerReachable -ne 'Reachable'
        ) {
            return
        }

        $route = if ($Data.route) { [string]$Data.route } else { 'Unknown' }
        $routeClass = Get-RouteClass $route
        $latency = Get-LatencyMilliseconds $Data.latency

        $stamp = "$route|$([string]$Data.latency)|$($script:lastCompletedAt.Ticks)"

        if ($stamp -eq $script:lastProcessedConnectionStamp) {
            return
        }

        $script:lastProcessedConnectionStamp = $stamp

        $previous = if ($script:connectionSamples.Count -gt 0) {
            $script:connectionSamples[$script:connectionSamples.Count - 1]
        }
        else {
            $null
        }

        $previousAverage = [double]::NaN

        if ($script:connectionSamples.Count -gt 0) {
            $numericSamples = @(
                $script:connectionSamples |
                    ForEach-Object { [double]$_.LatencyMs } |
                    Where-Object { -not [double]::IsNaN($_) }
            )

            if ($numericSamples.Count -gt 0) {
                $previousAverage = [double](
                    $numericSamples |
                    Measure-Object -Average
                ).Average
            }
        }

        $sample = [pscustomobject]@{
            Time = Get-Date
            Route = $route
            RouteClass = $routeClass
            LatencyMs = $latency
        }

        $script:connectionSamples.Add($sample)

        while ($script:connectionSamples.Count -gt 6) {
            $script:connectionSamples.RemoveAt(0)
        }

        if (-not $previous) {
            # First result silently establishes the session baseline.
            Set-ConnectionInsight '' 'muted'
            return
        }

        $previousRoute = [string]$previous.Route
        $previousRouteClass = [string]$previous.RouteClass

        if ($previousRouteClass -ne $routeClass) {
            if ($previousRouteClass -eq 'Relay' -and $routeClass -eq 'Direct') {
                $message = 'Connection improved · Relay → Direct'

                if (-not [double]::IsNaN($latency)) {
                    $message += " · $([Math]::Round($latency)) ms"
                }

                Set-ConnectionInsight $message 'good'
                Add-ConnectionEvent $message
                return
            }

            if ($previousRouteClass -eq 'Direct' -and $routeClass -eq 'Relay') {
                $message = 'Connection changed · Direct → Relay'

                if (-not [double]::IsNaN($latency)) {
                    $message += " · $([Math]::Round($latency)) ms"
                }

                Set-ConnectionInsight $message 'warn'
                Add-ConnectionEvent $message
                return
            }

            $message = "Connection path changed · $previousRouteClass → $routeClass"
            Set-ConnectionInsight $message 'warn'
            Add-ConnectionEvent $message
            return
        }

        if (
            $routeClass -eq 'Relay' -and
            $previousRoute -ne $route
        ) {
            $message = "Relay changed · $previousRoute → $route"
            Set-ConnectionInsight $message 'warn'
            Add-ConnectionEvent $message
            return
        }

        if (
            -not [double]::IsNaN($latency) -and
            -not [double]::IsNaN($previousAverage)
        ) {
            $baseline = [Math]::Max(1.0, $previousAverage)
            $delta = $latency - $baseline

            if (
                $delta -ge 35 -and
                $latency -ge ($baseline * 1.7)
            ) {
                $message = "Latency increased · ~$([Math]::Round($baseline)) → $([Math]::Round($latency)) ms"
                Set-ConnectionInsight $message 'warn'
                Add-ConnectionEvent $message
                return
            }

            if (
                $delta -le -25 -and
                $latency -le ($baseline * 0.7)
            ) {
                $message = "Latency improved · ~$([Math]::Round($baseline)) → $([Math]::Round($latency)) ms"
                Set-ConnectionInsight $message 'good'
                Add-ConnectionEvent $message
                return
            }

            $recent = @(
                $script:connectionSamples |
                    ForEach-Object { [double]$_.LatencyMs } |
                    Where-Object { -not [double]::IsNaN($_) }
            )

            $sessionAverage = if ($recent.Count -gt 0) {
                [Math]::Round(
                    [double](
                        $recent |
                        Measure-Object -Average
                    ).Average
                )
            }
            else {
                [Math]::Round($latency)
            }

            if ($routeClass -eq 'Direct') {
                Set-ConnectionInsight "Stable this session · Direct · ~$sessionAverage ms" 'muted'
            }
            elseif ($routeClass -eq 'Relay') {
                Set-ConnectionInsight "Stable this session · $route · ~$sessionAverage ms" 'warn'
            }
            else {
                Set-ConnectionInsight "Stable this session · ~$sessionAverage ms" 'muted'
            }

            return
        }

        Set-ConnectionInsight "Stable this session · $routeClass" 'muted'
    }

    function Add-ReliabilityEvent {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) { return }

        try {
            $script:reliabilityEvents.Add(
                "$(Get-Date -Format 'HH:mm') · $Text"
            )

            while ($script:reliabilityEvents.Count -gt 6) {
                $script:reliabilityEvents.RemoveAt(0)
            }
        }
        catch {}
    }

    function Mark-CurrentResultStale {
        param([string]$Reason)

        if (
            -not $script:lastData -or
            -not [bool]$script:lastData.done
        ) {
            return
        }

        $script:environmentStale = $true
        $script:environmentStaleReason = $Reason
        $script:lastEnvironmentChangedAt = Get-Date
        Add-ReliabilityEvent $Reason
        Update-LastCheckedText
        Update-TrayFreshness
    }

    function Get-NetworkEnvironmentSignature {
        try {
            $parts = New-Object 'System.Collections.Generic.List[string]'

            foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if (
                    $nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback -or
                    $nic.Name -match '(?i)Tailscale' -or
                    $nic.Description -match '(?i)Tailscale'
                ) {
                    continue
                }

                if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
                    continue
                }

                $ipParts = @()
                $gatewayParts = @()

                try {
                    $props = $nic.GetIPProperties()

                    $ipParts = @(
                        $props.UnicastAddresses |
                            ForEach-Object { [string]$_.Address } |
                            Where-Object { $_ } |
                            Sort-Object -Unique
                    )

                    $gatewayParts = @(
                        $props.GatewayAddresses |
                            ForEach-Object { [string]$_.Address } |
                            Where-Object { $_ -and $_ -ne '0.0.0.0' -and $_ -ne '::' } |
                            Sort-Object -Unique
                    )
                } catch {}

                $parts.Add(
                    "$($nic.Id)|$($nic.NetworkInterfaceType)|$($ipParts -join ',')|$($gatewayParts -join ',')"
                )
            }

            return (
                $parts |
                    Sort-Object |
                    ForEach-Object { $_ }
            ) -join ';'
        }
        catch {
            return ''
        }
    }

    function Register-ReliabilityWatchers {
        $script:lastReliabilityPollAt = Get-Date
        $script:lastNetworkSignature = Get-NetworkEnvironmentSignature
    }

    function Poll-ReliabilityEnvironment {
        $now = Get-Date

        try {
            # A long gap in this dispatcher timer is a safe proxy for sleep/resume.
            if (
                $script:lastReliabilityPollAt -ne [DateTime]::MinValue -and
                ($now - $script:lastReliabilityPollAt).TotalSeconds -gt 25
            ) {
                Mark-CurrentResultStale 'PC resumed from sleep'
                Queue-AutoRepairSmartCheck `
                    -Reason 'PC resumed from sleep' `
                    -DelaySeconds 8
            }

            $script:lastReliabilityPollAt = $now

            $signature = Get-NetworkEnvironmentSignature

            if ([string]::IsNullOrWhiteSpace($script:lastNetworkSignature)) {
                $script:lastNetworkSignature = $signature
                return
            }

            if (
                -not [string]::IsNullOrWhiteSpace($signature) -and
                $signature -ne $script:lastNetworkSignature
            ) {
                $script:lastNetworkSignature = $signature

                Mark-CurrentResultStale 'Network changed'
                Queue-AutoRepairSmartCheck `
                    -Reason 'Network changed' `
                    -DelaySeconds 10
            }
        }
        catch {}
    }

    function Unregister-ReliabilityWatchers {
        $script:lastReliabilityPollAt = [DateTime]::MinValue
        $script:lastNetworkSignature = ''
    }

    function Get-TrayFreshnessText {
        if ($script:lastCompletedAt -eq [DateTime]::MinValue) {
            return 'Not checked yet'
        }

        $age = (Get-Date) - $script:lastCompletedAt

        if ($script:environmentStale) {
            $reason = if ([string]::IsNullOrWhiteSpace($script:environmentStaleReason)) {
                'environment changed'
            } else {
                $script:environmentStaleReason.ToLowerInvariant()
            }

            return "Previous result · $reason"
        }

        if ($age.TotalSeconds -lt 60) {
            return 'Checked just now'
        }

        if ($age.TotalMinutes -lt 60) {
            $minutes = [Math]::Max(1, [int][Math]::Floor($age.TotalMinutes))
            return "Checked $minutes min ago"
        }

        $hours = [Math]::Max(1, [int][Math]::Floor($age.TotalHours))
        return "Checked $hours h ago"
    }

    function Update-TrayFreshness {
        if (-not $script:trayFreshnessItem) { return }

        try {
            $freshText = Get-TrayFreshnessText
            $script:trayFreshnessItem.Text = $freshText

            if (
                $script:trayCheckItem -and
                (
                    $script:environmentStale -or
                    (
                        $script:lastCompletedAt -ne [DateTime]::MinValue -and
                        ((Get-Date) - $script:lastCompletedAt).TotalMinutes -ge 5
                    )
                )
            ) {
                $script:trayCheckItem.Font = New-Object System.Drawing.Font(
                    $script:trayCheckItem.Font,
                    [System.Drawing.FontStyle]::Bold
                )
            }
            elseif ($script:trayCheckItem) {
                $script:trayCheckItem.Font = New-Object System.Drawing.Font(
                    $script:trayCheckItem.Font,
                    [System.Drawing.FontStyle]::Regular
                )
            }
        }
        catch {}
    }

    function Update-LastCheckedText {
        if (-not $LastCheckedText) { return }

        if ($script:lastCompletedAt -eq [DateTime]::MinValue) {
            $LastCheckedText.Text = ''
            $LastCheckedText.Visibility = [System.Windows.Visibility]::Collapsed
            return
        }

        $LastCheckedText.Visibility = [System.Windows.Visibility]::Visible

        if ($script:environmentStale) {
            $reason = if ([string]::IsNullOrWhiteSpace($script:environmentStaleReason)) {
                'environment changed'
            } else {
                $script:environmentStaleReason.ToLowerInvariant()
            }

            $LastCheckedText.Text = "Previous result · $reason · check again"
            $LastCheckedText.Foreground = Get-Brush 'Amber'
            return
        }

        $age = (Get-Date) - $script:lastCompletedAt

        if ($age.TotalSeconds -lt 60) {
            $LastCheckedText.Text = 'Checked just now'
        }
        elseif ($age.TotalMinutes -lt 60) {
            $minutes = [Math]::Max(1, [int][Math]::Floor($age.TotalMinutes))
            $LastCheckedText.Text = "Checked $minutes min ago"
        }
        else {
            $hours = [Math]::Max(1, [int][Math]::Floor($age.TotalHours))
            $LastCheckedText.Text = "Checked $hours h ago"
        }

        $LastCheckedText.Foreground = Get-Brush 'Faint'
    }

    function Test-AutoRepairSmartEnabled {
        try {
            return (
                $AutoRepairCheckBox.IsEnabled -and
                [bool]$AutoRepairCheckBox.IsChecked -and
                $script:autoRepairAvailable
            )
        }
        catch {
            return $false
        }
    }

    function Queue-AutoRepairSmartCheck {
        param(
            [string]$Reason,
            [int]$DelaySeconds = 6
        )

        if (-not (Test-AutoRepairSmartEnabled)) {
            return
        }

        if ($script:repairActive) {
            return
        }

        $now = Get-Date

        # Coalesce noisy network events and avoid hammering Task Scheduler.
        if (
            $script:autoRepairLastTriggerAt -ne [DateTime]::MinValue -and
            ($now - $script:autoRepairLastTriggerAt).TotalSeconds -lt 10
        ) {
            return
        }

        $script:autoRepairTriggerReason = $Reason
        $script:autoRepairTriggerQueuedAt = $now

        if (
            $script:autoRepairTriggerTimer -and
            $script:autoRepairTriggerTimer.IsEnabled
        ) {
            # Proton/WireGuard-style adapter transitions can produce a burst of
            # changes. Keep one queued timer and simply retain the latest reason.
            return
        }

        $script:autoRepairTriggerTimer = New-Object Windows.Threading.DispatcherTimer
        $script:autoRepairTriggerTimer.Interval = [TimeSpan]::FromSeconds(
            [Math]::Max(1, $DelaySeconds)
        )

        $script:autoRepairTriggerTimer.Add_Tick({
            try {
                $script:autoRepairTriggerTimer.Stop()

                if (
                    -not (Test-AutoRepairSmartEnabled) -or
                    $script:repairActive
                ) {
                    return
                }

                $script:autoRepairLastTriggerAt = Get-Date

                $AutoRepairStatusText.Text = "Enabled · smart check · $($script:autoRepairTriggerReason)"
                $AutoRepairStatusText.Foreground = Get-Brush 'Blue'

                Add-ReliabilityEvent "Auto Repair check queued · $($script:autoRepairTriggerReason)"
                Update-Diagnostics $script:lastData

                Invoke-AutoRepairMonitorNow
            }
            catch {}
        })

        $script:autoRepairTriggerTimer.Start()
    }

    function Initialize-AutoRepairLocalWatch {
        try {
            $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
            $script:autoRepairLastServiceState = if ($service) {
                [string]$service.Status
            } else {
                'Missing'
            }

            $script:autoRepairLastClientState = if (
                Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue
            ) {
                'Running'
            } else {
                'Closed'
            }

            $script:autoRepairWatchInitialized = $true
        }
        catch {
            $script:autoRepairWatchInitialized = $false
        }
    }

    function Check-AutoRepairLocalTransitions {
        if (-not (Test-AutoRepairSmartEnabled)) {
            return
        }

        try {
            $service = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
            $serviceState = if ($service) {
                [string]$service.Status
            } else {
                'Missing'
            }

            $clientState = if (
                Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue
            ) {
                'Running'
            } else {
                'Closed'
            }

            if (-not $script:autoRepairWatchInitialized) {
                $script:autoRepairLastServiceState = $serviceState
                $script:autoRepairLastClientState = $clientState
                $script:autoRepairWatchInitialized = $true
                return
            }

            if (
                $script:autoRepairLastServiceState -eq 'Running' -and
                $serviceState -ne 'Running'
            ) {
                Queue-AutoRepairSmartCheck `
                    -Reason "Tailscale service changed to $serviceState" `
                    -DelaySeconds 2
            }

            if (
                $script:autoRepairLastClientState -eq 'Running' -and
                $clientState -eq 'Closed'
            ) {
                Queue-AutoRepairSmartCheck `
                    -Reason 'Tailscale desktop client closed' `
                    -DelaySeconds 2
            }

            $script:autoRepairLastServiceState = $serviceState
            $script:autoRepairLastClientState = $clientState
        }
        catch {}
    }

    function Test-StartWithWindows {
        try {
            $value = (
                Get-ItemProperty `
                    -Path $StartupRegistryPath `
                    -Name $StartupRegistryName `
                    -ErrorAction Stop
            ).$StartupRegistryName

            return -not [string]::IsNullOrWhiteSpace([string]$value)
        }
        catch {
            return $false
        }
    }

    function Set-StartWithWindows {
        param([bool]$Enabled)

        if ($Enabled) {
            if (
                -not (Test-Path -LiteralPath $NativeHostPath) -and
                -not (Test-Path -LiteralPath $StartupLauncherPath)
            ) {
                return $false
            }

            try {
                if (Test-Path -LiteralPath $NativeHostPath) {
                    $command = '"' + $NativeHostPath + '" --start-in-tray'
                }
                else {
                    $command = 'wscript.exe "' + $StartupLauncherPath + '"'
                }

                New-ItemProperty `
                    -Path $StartupRegistryPath `
                    -Name $StartupRegistryName `
                    -Value $command `
                    -PropertyType String `
                    -Force | Out-Null

                return $true
            }
            catch {
                return $false
            }
        }

        try {
            Remove-ItemProperty `
                -Path $StartupRegistryPath `
                -Name $StartupRegistryName `
                -ErrorAction SilentlyContinue

            return $true
        }
        catch {
            return $false
        }
    }

    function Test-AutoRepairAvailable {
        if (-not (Test-Path -LiteralPath $AutoRepairMonitorPath)) {
            return $false
        }

        $scheduler = $null
        $folder = $null
        $task = $null

        try {
            $scheduler = New-Object -ComObject 'Schedule.Service'
            $scheduler.Connect()
            $folder = $scheduler.GetFolder('\')
            $task = $folder.GetTask($AutoRepairTaskName)
            return [bool]$task
        }
        catch {
            return $false
        }
        finally {
            foreach ($obj in @($task, $folder, $scheduler)) {
                if ($obj) {
                    try {
                        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)
                    } catch {}
                }
            }
        }
    }

    function Refresh-AutoRepairAvailability {
        param([switch]$Force)

        if (
            -not $Force -and
            $script:autoRepairAvailabilityCheckedAt -ne [DateTime]::MinValue -and
            ((Get-Date) - $script:autoRepairAvailabilityCheckedAt).TotalSeconds -lt 20
        ) {
            return $script:autoRepairAvailable
        }

        $script:autoRepairAvailable = Test-AutoRepairAvailable
        $script:autoRepairAvailabilityCheckedAt = Get-Date

        $AutoRepairCheckBox.IsEnabled = $script:autoRepairAvailable
        $AutoRepairCheckNowButton.IsEnabled = (
            $script:autoRepairAvailable -and
            [bool]$AutoRepairCheckBox.IsChecked
        )

        return $script:autoRepairAvailable
    }

    function Get-AutoRepairEnabled {
        try {
            $settings = Read-JsonFileSafe `
                -Path $AutoRepairSettingsPath `
                -RemoveIfInvalid

            if (-not $settings) {
                return $false
            }

            return [bool]$settings.enabled
        }
        catch {
            return $false
        }
    }

    function Set-AutoRepairEnabled {
        param([bool]$Enabled)

        try {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

            $obj = [ordered]@{
                enabled = $Enabled
                updatedUtc = [DateTime]::UtcNow.ToString('o')
            }

            Write-JsonFileAtomic `
                -Path $AutoRepairSettingsPath `
                -Value $obj

            return $true
        }
        catch {
            return $false
        }
    }

    function Read-JsonFileSafe {
        param(
            [Parameter(Mandatory=$true)]
            [string]$Path,

            [switch]$RemoveIfInvalid
        )

        if (-not (Test-Path -LiteralPath $Path)) {
            return $null
        }

        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                $raw = [IO.File]::ReadAllText($Path)

                if ([string]::IsNullOrWhiteSpace($raw)) {
                    return $null
                }

                return ($raw | ConvertFrom-Json -ErrorAction Stop)
            }
            catch {
                if ($attempt -lt 2) {
                    Start-Sleep -Milliseconds 20
                }
            }
        }

        if ($RemoveIfInvalid) {
            try {
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            } catch {}
        }

        return $null
    }

    function Write-JsonFileAtomic {
        param(
            [Parameter(Mandatory=$true)]
            [string]$Path,

            [Parameter(Mandatory=$true)]
            $Value
        )

        $directory = Split-Path -Parent $Path

        if ($directory) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $tempPath = "$Path.$PID.tmp"
        $json = $Value | ConvertTo-Json -Depth 8 -Compress
        $encoding = New-Object System.Text.UTF8Encoding($false)

        try {
            [IO.File]::WriteAllText($tempPath, $json, $encoding)
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
        }
        finally {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    function Initialize-OperationGate {
        if (-not ('Tqr.OperationGate' -as [type])) {
            Add-Type -Path $OperationsLibraryPath -ErrorAction Stop
        }
    }

    function Get-ActiveOperationLock {
        param([switch]$RecoverStale)
        try {
            Initialize-OperationGate
            return [Tqr.OperationGate]::Inspect($StateDir)
        }
        catch {
            # Inspection never deletes a marker or treats an unreadable owner as idle.
            return [pscustomobject]@{ kind = 'operation ownership verification'; ownerPid = 0 }
        }
    }

    function Acquire-UiOperationLock {
        param([Parameter(Mandatory=$true)][string]$Kind, [int]$Minutes = 3)
        try {
            Initialize-OperationGate
            if ($script:uiOperationLease) { return $false }
            $script:uiOperationLease = [Tqr.OperationGate]::TryAcquire($StateDir, $Kind)
            if (-not $script:uiOperationLease) { return $false }
            $script:uiOperationKind = $Kind
            return $true
        }
        catch { return $false }
    }

    function Release-UiOperationLock {
        param([string]$Kind = '')
        if (-not $script:uiOperationLease) { return }
        if ($Kind -and $script:uiOperationLease.Kind -ne $Kind) { return }
        $script:uiOperationLease.Dispose()
        $script:uiOperationLease = $null
        $script:uiOperationKind = ''
    }

    function Update-AutoRepairStatus {
        try {
            if (-not (Refresh-AutoRepairAvailability)) {
                $AutoRepairCheckBox.IsChecked = $false
                $AutoRepairStatusText.Text = 'Unavailable · Repair installation can restore the background monitor.'
                $AutoRepairStatusText.Foreground = Get-Brush 'Amber'
                $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Collapsed
                $AutoRepairTriggerText.Visibility = [System.Windows.Visibility]::Collapsed
                return
            }

            if (-not (Get-AutoRepairEnabled)) {
                $AutoRepairStatusText.Text = 'Off'
                $AutoRepairStatusText.Foreground = Get-Brush 'Faint'
                $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Collapsed
                $AutoRepairTriggerText.Visibility = [System.Windows.Visibility]::Collapsed
                return
            }

            $AutoRepairTriggerText.Visibility = [System.Windows.Visibility]::Visible

            if (-not (Test-Path -LiteralPath $AutoRepairStatePath)) {
                $AutoRepairStatusText.Text = 'Enabled · waiting for the first background check'
                $AutoRepairStatusText.Foreground = Get-Brush 'Muted'
                $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Collapsed
                $AutoRepairTriggerText.Visibility = [System.Windows.Visibility]::Visible
                return
            }

            $state = Read-JsonFileSafe -Path $AutoRepairStatePath

            if (-not $state) {
                $AutoRepairStatusText.Text = 'Enabled · waiting for a clean background state'
                $AutoRepairStatusText.Foreground = Get-Brush 'Muted'
                return
            }

            $checked = [DateTime]::MinValue

            try {
                if ($state.lastCheckedUtc) {
                    $checked = [DateTime]::Parse([string]$state.lastCheckedUtc).ToLocalTime()
                }
            }
            catch {}

            $fresh = if ($checked -eq [DateTime]::MinValue) {
                'not checked yet'
            }
            else {
                $age = (Get-Date) - $checked

                if ($age.TotalMinutes -lt 1) {
                    'checked just now'
                }
                elseif ($age.TotalHours -lt 1) {
                    "checked $([Math]::Max(1, [int]$age.TotalMinutes)) min ago"
                }
                else {
                    "checked $([Math]::Max(1, [int]$age.TotalHours)) h ago"
                }
            }

            switch ([string]$state.status) {
                'healthy' {
                    $AutoRepairStatusText.Text = "Enabled · healthy · $fresh"
                    $AutoRepairStatusText.Foreground = Get-Brush 'Green'
                }
                'repaired' {
                    $AutoRepairStatusText.Text = "Enabled · repaired · $fresh"
                    $AutoRepairStatusText.Foreground = Get-Brush 'Green'
                }
                'cooldown' {
                    $minutes = [int]$state.cooldownRemainingMinutes
                    $AutoRepairStatusText.Text = "Enabled · recovery cooldown · $minutes min"
                    $AutoRepairStatusText.Foreground = Get-Brush 'Amber'
                }
                'busy' {
                    $AutoRepairStatusText.Text = "Enabled · waiting for another Quick Repair operation · $fresh"
                    $AutoRepairStatusText.Foreground = Get-Brush 'Muted'
                }
                'manual' {
                    $AutoRepairStatusText.Text = "Enabled · needs your attention · $fresh"
                    $AutoRepairStatusText.Foreground = Get-Brush 'Amber'
                }
                'error' {
                    $AutoRepairStatusText.Text = "Enabled · monitor error · $fresh"
                    $AutoRepairStatusText.Foreground = Get-Brush 'Red'
                }
                default {
                    $AutoRepairStatusText.Text = "Enabled · $fresh"
                    $AutoRepairStatusText.Foreground = Get-Brush 'Muted'
                }
            }

            if ($state.lastRepairUtc) {
                try {
                    $lastRepair = [DateTime]::Parse([string]$state.lastRepairUtc).ToLocalTime()
                    $reason = [string]$state.lastRepairReason
                    $age = (Get-Date) - $lastRepair

                    $when = if ($age.TotalMinutes -lt 1) {
                        'just now'
                    }
                    elseif ($age.TotalHours -lt 1) {
                        "$([Math]::Max(1, [int]$age.TotalMinutes)) min ago"
                    }
                    else {
                        "$([Math]::Max(1, [int]$age.TotalHours)) h ago"
                    }

                    $AutoRepairLastRepairText.Text = if ($reason) {
                        "Last recovery $when · $reason"
                    }
                    else {
                        "Last recovery $when"
                    }

                    $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Visible
                }
                catch {
                    $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Collapsed
                }
            }
            else {
                $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
        catch {
            $AutoRepairStatusText.Text = 'Status unavailable'
            $AutoRepairStatusText.Foreground = Get-Brush 'Faint'
        }
    }

    function Initialize-AutoRepairUi {
        $available = Refresh-AutoRepairAvailability -Force

        $script:initializingAutoRepair = $true

        try {
            if ($available) {
                $AutoRepairCheckBox.IsChecked = Get-AutoRepairEnabled
            }
            else {
                $AutoRepairCheckBox.IsChecked = $false
                $AutoRepairCheckNowButton.IsEnabled = $false
                $AutoRepairStatusText.Text = 'Unavailable · Repair installation can restore the background monitor.'
                $AutoRepairStatusText.Foreground = Get-Brush 'Amber'
                $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Collapsed
                return
            }

            if ([bool]$AutoRepairCheckBox.IsChecked) {
                $AutoRepairCheckNowButton.IsEnabled = $true
                Update-AutoRepairStatus
            }
            else {
                $AutoRepairCheckNowButton.IsEnabled = $false
                $AutoRepairStatusText.Text = 'Off'
                $AutoRepairStatusText.Foreground = Get-Brush 'Faint'
                $AutoRepairLastRepairText.Visibility = [System.Windows.Visibility]::Collapsed
                $AutoRepairTriggerText.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
        finally {
            $script:initializingAutoRepair = $false
        }
    }

    function Set-ActionButton {
        param(
            [string]$Text,
            [string]$Mode,
            [bool]$Enabled = $true,
            [string]$Visual = 'secondary'
        )

        $script:actionMode = $Mode
        $PrimaryButton.Content = $Text
        $PrimaryButton.IsEnabled = $Enabled

        if ($Visual -eq 'primary') {
            $PrimaryButton.Style = $window.Resources['PrimaryButtonStyle']
        }
        else {
            $PrimaryButton.Style = $window.Resources['SecondaryButtonStyle']
        }
    }

    function Test-RepairEngine {
        $result = [ordered]@{
            Healthy = $false
            Message = ''
            Repairable = $false
        }

        $repairToolAvailable = Test-Path -LiteralPath $RepairInstallPath

        if (-not (Test-Path -LiteralPath $BackendPath)) {
            $result.Message = 'The repair engine is missing.'
            $result.Repairable = $repairToolAvailable
            return [pscustomobject]$result
        }

        if (-not (Test-Path -LiteralPath $BackendLauncherPath)) {
            $result.Message = 'The repair launcher is missing.'
            $result.Repairable = $repairToolAvailable
            return [pscustomobject]$result
        }

        try {
            $scriptText = Get-Content -LiteralPath $BackendPath -Raw -ErrorAction Stop
            [void][scriptblock]::Create($scriptText)
        }
        catch {
            $result.Message = 'The repair engine could not be validated.'
            $result.Repairable = $repairToolAvailable
            return [pscustomobject]$result
        }

        $desktopShortcut = Join-Path `
            ([Environment]::GetFolderPath('Desktop')) `
            'Fix Tailscale.lnk'

        $shortcutTarget = if (Test-Path -LiteralPath $NativeHostPath) {
            $NativeHostPath
        }
        else {
            $UiLauncherPath
        }

        foreach ($shortcut in @($desktopShortcut, $StartMenuShortcutPath)) {
            if (Test-Path -LiteralPath $shortcut) {
                try {
                    $shell = New-Object -ComObject WScript.Shell
                    $shortcutInfo = $null

                    try {
                        $shortcutInfo = $shell.CreateShortcut($shortcut)

                        if (
                            [string]::Compare(
                                [string]$shortcutInfo.TargetPath,
                                [string]$shortcutTarget,
                                $true
                            ) -ne 0
                        ) {
                            $result.Message = 'A Quick Repair shortcut is not configured correctly.'
                            $result.Repairable = $repairToolAvailable
                            return [pscustomobject]$result
                        }
                    }
                    finally {
                        if ($shortcutInfo) {
                            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcutInfo)
                        }

                        if ($shell) {
                            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
                        }
                    }
                }
                catch {
                    $result.Message = 'A Quick Repair shortcut could not be verified.'
                    $result.Repairable = $repairToolAvailable
                    return [pscustomobject]$result
                }
            }
        }

        # Shell identity is validated transactionally by setup/maintenance.
        # Avoid child-process verification here so normal app startup stays fast.


        $scheduler = $null
        $folder = $null
        $task = $null
        $definition = $null
        $actions = $null
        $action = $null

        try {
            $scheduler = New-Object -ComObject 'Schedule.Service'
            $scheduler.Connect()
            $folder = $scheduler.GetFolder('\')
            $task = $folder.GetTask($TaskName)

            if (-not $task) {
                $result.Message = 'The elevated repair task is missing.'
                $result.Repairable = $repairToolAvailable
                return [pscustomobject]$result
            }

            $definition = $task.Definition
            $actions = $definition.Actions

            if ($actions.Count -lt 1) {
                $result.Message = 'The repair task has no action configured.'
                $result.Repairable = $repairToolAvailable
                return [pscustomobject]$result
            }

            $action = $actions.Item(1)
            $execute = [string]$action.Path
            $arguments = [string]$action.Arguments

            if (
                $execute -notmatch 'wscript(\.exe)?$' -or
                $arguments -notlike '*Launch-Tailscale-Backend.vbs*'
            ) {
                $result.Message = 'The repair task is not configured correctly.'
                $result.Repairable = $repairToolAvailable
                return [pscustomobject]$result
            }
        }
        catch {
            $result.Message = 'The protected repair task could not be verified.'
            $result.Repairable = $repairToolAvailable
            return [pscustomobject]$result
        }
        finally {
            foreach ($obj in @($action, $actions, $definition, $task, $folder, $scheduler)) {
                if ($obj) {
                    try {
                        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)
                    } catch {}
                }
            }
        }

        $result.Healthy = $true
        $result.Message = 'Repair engine ready'
        return [pscustomobject]$result
    }

    function Show-EngineIssue {
        param($Check)

        Set-Badge $HeroBadge $HeroBadgeText 'NEEDS ATTENTION' 'failure'
        $HeroTitle.Text = 'Quick Repair needs maintenance'
        $HeroDetail.Text = [string]$Check.Message

        Set-Badge $LocalBadge $LocalBadgeText 'UNAVAILABLE' 'failure'
        Set-Badge $RemoteBadge $RemoteBadgeText 'WAITING' 'idle'

        if ([bool]$Check.Repairable) {
            Set-ActionButton 'Repair installation' 'repair-install' $true 'primary'
        }
        else {
            Set-ActionButton 'Unavailable' 'repair' $false
        }
    }

    function Refresh-EngineCheck {
        $engineCheck = Test-RepairEngine
        $script:engineHealthy = [bool]$engineCheck.Healthy
        $script:lastEngineCheckAt = Get-Date

        if (-not $script:engineHealthy) {
            Show-EngineIssue $engineCheck
            return $false
        }

        return $true
    }

    function Ensure-EngineReadyCached {
        if (
            $script:engineHealthy -and
            $script:lastEngineCheckAt -ne [DateTime]::MinValue -and
            ((Get-Date) - $script:lastEngineCheckAt).TotalMinutes -lt 10
        ) {
            return $true
        }

        return (Refresh-EngineCheck)
    }

    function Invoke-InstallationRepair {
        if (-not (Test-Path -LiteralPath $RepairInstallPath)) {
            [System.Windows.MessageBox]::Show(
                'The maintenance component is missing. Reinstall Quick Repair to restore it.',
                'Tailscale Quick Repair',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return
        }

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $RepairInstallPath + '"'
            $psi.Verb = 'runas'
            $psi.UseShellExecute = $true

            [System.Diagnostics.Process]::Start($psi) | Out-Null

            $window.Dispatcher.BeginInvoke(
                [Action]{
                    Set-Badge $HeroBadge $HeroBadgeText 'MAINTENANCE' 'repairing'
                    $HeroTitle.Text = 'Repair installation opened'
                    $HeroDetail.Text = 'Approve the Windows prompt, then run the check again when maintenance finishes.'
                    Set-ActionButton 'Check Again' 'repair' $true
                }
            ) | Out-Null
        }
        catch {
            [System.Windows.MessageBox]::Show(
                'Windows did not start installation repair. Nothing was changed.',
                'Tailscale Quick Repair',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
        }
    }

    function Update-DetailsToggleText {
        if ($DetailsPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            $DetailsButton.Content = 'Hide details  ↑'
        }
        else {
            $DetailsButton.Content = 'Details  ›'
        }
    }

    function Restore-ScrollOffset {
        param([double]$Offset)

        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded,
            [Action]{
                try {
                    $MainScrollViewer.ScrollToVerticalOffset($Offset)
                } catch {}
            }
        ) | Out-Null
    }

    function Get-AdvancedValue {
        param($Result, [string]$Name)

        try {
            if ($Result.PSObject.Properties.Name -contains $Name) {
                $value = [string]$Result.$Name

                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return $value
                }
            }
        }
        catch {}

        return 'Unknown'
    }

    function Stop-AdvancedDiagnostics {
        try {
            if (
                $script:advancedDiagnosticsProcess -and
                -not $script:advancedDiagnosticsProcess.HasExited
            ) {
                $script:advancedDiagnosticsProcess.Kill()
            }
        } catch {}

        $script:advancedDiagnosticsProcess = $null

        try {
            if ($script:advancedDiagnosticsTimer) {
                $script:advancedDiagnosticsTimer.Stop()
            }
        } catch {}

        if ($script:advancedDiagnosticsOwnsOperation) {
            Release-UiOperationLock -Kind 'diagnostics'
            $script:advancedDiagnosticsOwnsOperation = $false
        }
    }

    function Complete-AdvancedDiagnostics {
        param(
            $Result,
            [string]$FallbackSummary = ''
        )

        if ($script:advancedDiagnosticsTimer) {
            try { $script:advancedDiagnosticsTimer.Stop() } catch {}
        }

        $script:advancedDiagnosticsProcess = $null

        if ($script:advancedDiagnosticsOwnsOperation) {
            Release-UiOperationLock -Kind 'diagnostics'
            $script:advancedDiagnosticsOwnsOperation = $false
        }

        $AdvancedDiagnosticsProgress.Value = 100
        $AdvancedDiagnosticsButton.Content = 'Run again'
        $AdvancedDiagnosticsButton.IsEnabled = $true
        $AdvancedCopyButton.Visibility = [System.Windows.Visibility]::Visible

        if ($Result) {
            $summary = Get-AdvancedValue $Result 'summary'

            if (
                $summary -eq 'Unknown' -and
                -not [string]::IsNullOrWhiteSpace($FallbackSummary)
            ) {
                $summary = $FallbackSummary
            }

            $AdvancedDiagnosticsSummary.Text = $summary

            $severity = Get-AdvancedValue $Result 'severity'

            if ($severity -eq 'good') {
                $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Green'
            }
            elseif ($severity -eq 'warn') {
                $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Amber'
            }
            elseif ($severity -eq 'bad') {
                $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Red'
            }
            else {
                $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Muted'
            }

            $AdvancedNetworkText.Text = @(
                "UDP        $(Get-AdvancedValue $Result 'udp')"
                "IPv4       $(Get-AdvancedValue $Result 'ipv4')"
                "IPv6       $(Get-AdvancedValue $Result 'ipv6')"
                "Nearest    $(Get-AdvancedValue $Result 'nearestDerp')"
            ) -join [Environment]::NewLine

            $AdvancedPeerText.Text = @(
                "Path       $(Get-AdvancedValue $Result 'path')"
                "Discovery  $(Get-AdvancedValue $Result 'disco')"
                "Tunnel     $(Get-AdvancedValue $Result 'tsmp')"
                "ICMP       $(Get-AdvancedValue $Result 'icmp')"
                "Peer API   $(Get-AdvancedValue $Result 'peerApi')"
            ) -join [Environment]::NewLine

            $vpnText = 'None detected'

            try {
                if ($Result.otherVpns -and @($Result.otherVpns).Count -gt 0) {
                    $vpnText = @($Result.otherVpns) -join ', '
                }
            }
            catch {}

            $AdvancedEnvironmentText.Text = @(
                "NAT mapping  $(Get-AdvancedValue $Result 'mapping')"
                "Port map     $(Get-AdvancedValue $Result 'portMapping')"
                "Other VPN    $vpnText"
            ) -join [Environment]::NewLine

            $script:advancedDiagnosticsReport = @(
                'Tailscale Quick Repair - Advanced diagnostics'
                "Summary: $summary"
                ''
                'Network'
                $AdvancedNetworkText.Text
                ''
                'Peer'
                $AdvancedPeerText.Text
                ''
                'Environment'
                $AdvancedEnvironmentText.Text
            ) -join [Environment]::NewLine
        }
        else {
            $AdvancedDiagnosticsSummary.Text = if ($FallbackSummary) {
                $FallbackSummary
            }
            else {
                'Advanced diagnostics could not complete.'
            }

            $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Amber'
            $AdvancedNetworkText.Text = 'Unavailable'
            $AdvancedPeerText.Text = 'Unavailable'
            $AdvancedEnvironmentText.Text = 'Unavailable'
            $script:advancedDiagnosticsReport = $AdvancedDiagnosticsSummary.Text
        }
    }

    function Update-AdvancedDiagnostics {
        try {
            if (-not (Test-Path -LiteralPath $AdvancedDiagnosticsStateFile)) {
                return
            }

            $result = Get-Content `
                -LiteralPath $AdvancedDiagnosticsStateFile `
                -Raw `
                -ErrorAction Stop |
                ConvertFrom-Json `
                    -ErrorAction Stop

            if (
                $script:advancedDiagnosticsRunId -and
                [string]$result.runId -ne $script:advancedDiagnosticsRunId
            ) {
                return
            }

            $progress = 0
            try { $progress = [int]$result.progress } catch {}

            $AdvancedDiagnosticsProgress.Value = [Math]::Min(100, [Math]::Max(0, $progress))

            $summary = Get-AdvancedValue $result 'summary'
            $AdvancedDiagnosticsSummary.Text = $summary

            if ([bool]$result.done) {
                Complete-AdvancedDiagnostics $result
            }
        }
        catch {}
    }

    function Start-AdvancedDiagnostics {
        if ([string]::IsNullOrWhiteSpace($Peer)) {
            $AdvancedDiagnosticsSummary.Text = 'Remote peer is not configured.'
            $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Amber'
            return
        }

        if ($script:repairActive) {
            return
        }

        if (
            $script:advancedDiagnosticsProcess -and
            -not $script:advancedDiagnosticsProcess.HasExited
        ) {
            return
        }

        if (-not (Test-Path -LiteralPath $AdvancedDiagnosticsPath)) {
            $AdvancedDiagnosticsPanel.Visibility = [System.Windows.Visibility]::Visible
            Complete-AdvancedDiagnostics $null 'The Advanced Diagnostics component is missing. Run Repair installation to restore it.'
            return
        }

        try {
            Stop-AdvancedDiagnostics

            if (-not (Acquire-UiOperationLock -Kind 'diagnostics' -Minutes 2)) {
                $activeOperation = Get-ActiveOperationLock -RecoverStale
                $kind = if ($activeOperation) { [string]$activeOperation.kind } else { 'another operation' }
                $AdvancedDiagnosticsPanel.Visibility = [System.Windows.Visibility]::Visible
                $AdvancedDiagnosticsSummary.Text = "Quick Repair is busy with $kind. Try diagnostics again when it finishes."
                $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Amber'
                return
            }

            $script:advancedDiagnosticsOwnsOperation = $true
            $script:advancedDiagnosticsRunId = [Guid]::NewGuid().ToString('N')
            $script:advancedDiagnosticsStartedAt = Get-Date
            $script:advancedDiagnosticsReport = ''

            Remove-Item `
                -LiteralPath $AdvancedDiagnosticsStateFile `
                -Force `
                -ErrorAction SilentlyContinue

            $AdvancedDiagnosticsPanel.Visibility = [System.Windows.Visibility]::Visible
            $AdvancedCopyButton.Visibility = [System.Windows.Visibility]::Collapsed
            $AdvancedDiagnosticsProgress.Value = 2
            $AdvancedDiagnosticsSummary.Text = 'Preparing read-only network diagnostics…'
            $AdvancedDiagnosticsSummary.Foreground = Get-Brush 'Muted'
            $AdvancedNetworkText.Text = 'Waiting…'
            $AdvancedPeerText.Text = 'Waiting…'
            $AdvancedEnvironmentText.Text = 'Waiting…'
            $AdvancedDiagnosticsButton.Content = 'Running…'
            $AdvancedDiagnosticsButton.IsEnabled = $false

            $powershellPath = Join-Path `
                $env:SystemRoot `
                'System32\WindowsPowerShell\v1.0\powershell.exe'

            $arguments = @(
                '-NoLogo'
                '-NoProfile'
                '-NonInteractive'
                '-WindowStyle'
                'Hidden'
                '-ExecutionPolicy'
                'Bypass'
                '-File'
                ('"' + $AdvancedDiagnosticsPath + '"')
                '-Peer'
                ('"' + $Peer + '"')
                '-OutputPath'
                ('"' + $AdvancedDiagnosticsStateFile + '"')
                '-RunId'
                ('"' + $script:advancedDiagnosticsRunId + '"')
            ) -join ' '

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $powershellPath
            $psi.Arguments = $arguments
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

            $script:advancedDiagnosticsProcess = [System.Diagnostics.Process]::Start($psi)

            if (-not $script:advancedDiagnosticsProcess) {
                throw 'The diagnostic worker did not start.'
            }

            $script:advancedDiagnosticsTimer = New-Object Windows.Threading.DispatcherTimer
            $script:advancedDiagnosticsTimer.Interval = [TimeSpan]::FromMilliseconds(300)

            $script:advancedDiagnosticsTimer.Add_Tick({
                try {
                    Update-AdvancedDiagnostics

                    if (
                        $script:advancedDiagnosticsStartedAt -ne [DateTime]::MinValue -and
                        ((Get-Date) - $script:advancedDiagnosticsStartedAt).TotalSeconds -gt 25
                    ) {
                        Stop-AdvancedDiagnostics
                        Complete-AdvancedDiagnostics $null 'Advanced diagnostics timed out. The main Quick Repair result was not affected.'
                        return
                    }

                    if (
                        $script:advancedDiagnosticsProcess -and
                        $script:advancedDiagnosticsProcess.HasExited
                    ) {
                        Update-AdvancedDiagnostics

                        if ($AdvancedDiagnosticsButton.IsEnabled -eq $false) {
                            Complete-AdvancedDiagnostics $null 'Advanced diagnostics ended before a complete result was returned.'
                        }
                    }
                }
                catch {}
            })

            $script:advancedDiagnosticsTimer.Start()
        }
        catch {
            Stop-AdvancedDiagnostics
            Complete-AdvancedDiagnostics $null 'Advanced diagnostics could not start. The main Quick Repair result was not affected.'
        }
    }

    function Get-RepairTaskState {
        $scheduler = $null
        $folder = $null
        $task = $null

        try {
            $scheduler = New-Object -ComObject 'Schedule.Service'
            $scheduler.Connect()
            $folder = $scheduler.GetFolder('\')
            $task = $folder.GetTask($TaskName)

            if (-not $task) { return 'Missing' }

            switch ([int]$task.State) {
                1 { return 'Disabled' }
                2 { return 'Queued' }
                3 { return 'Ready' }
                4 { return 'Running' }
                default { return 'Unknown' }
            }
        }
        catch {
            return 'Missing'
        }
        finally {
            foreach ($obj in @($task, $folder, $scheduler)) {
                if ($obj) {
                    try {
                        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)
                    } catch {}
                }
            }
        }
    }

    function Attach-To-RunningRepair {
        if ((Get-RepairTaskState) -ne 'Running') {
            return $false
        }

        $script:repairActive = $true
        $script:launchUtc = [DateTime]::UtcNow.AddMinutes(-1)
        $script:runStartedAt = Get-Date
        $script:lastFreshStateUtc = $null
        $script:lastAppliedStateWriteUtc = [DateTime]::MinValue

        Set-Badge $HeroBadge $HeroBadgeText 'CHECKING' 'checking'
        $HeroTitle.Text = 'Checking Tailscale'
        $HeroDetail.Text = 'A repair check is already running. Reconnecting to it now.'
        Set-ActionButton 'Working…' 'repair' $false

        return $true
    }

    function Reset-Ui {
        param([switch]$SkipEngineCheck)

        Set-Badge $HeroBadge $HeroBadgeText 'READY' 'checking'
        $HeroTitle.Text = 'Ready to check'
        $HeroDetail.Text = 'Check Tailscale and repair only what is necessary.'
        $LastCheckedText.Visibility = [System.Windows.Visibility]::Collapsed

        $preflight = Get-LocalPreflight

        Set-Badge $LocalBadge $LocalBadgeText 'NOT CHECKED' 'idle'
        Set-Badge $RemoteBadge $RemoteBadgeText 'NOT CHECKED' 'idle'
        $RemoteTitle.Text = 'Remote machine'

        $LocalAppValue.Text = [string]$preflight.Client
        $LocalServiceValue.Text = [string]$preflight.Service
        $LocalBackendValue.Text = '—'

        $RemoteStatusValue.Text = '—'
        $RemoteRouteValue.Text = '—'
        $RemoteLatencyValue.Text = '—'
        $RemoteLatencyValue.Foreground = Get-Brush 'Value'
        $RemoteLatencyValue.ToolTip = $null
        Set-ConnectionInsight '' 'muted'

        Set-Step $AppDot $AppStep (if ([string]$preflight.Client -eq 'Running') { 'good' } elseif ([string]$preflight.Client -eq 'Closed') { 'warn' } else { 'bad' })
        Set-Step $ServiceDot $ServiceStep (if ([string]$preflight.Service -eq 'Running') { 'good' } elseif ([string]$preflight.Service -eq 'Stopped') { 'warn' } elseif ([string]$preflight.Service -eq 'Missing') { 'bad' } else { 'idle' })
        Set-Step $BackendDot $BackendStep 'idle'
        Set-Step $PeerDot $PeerStep 'idle'

        $PathLine1.Background = Get-Brush 'Border'
        $PathLine2.Background = Get-Brush 'Border'
        $PathLine3.Background = Get-Brush 'Border'

        Update-Diagnostics $null

        Set-ActionButton 'Start Repair' 'repair' $true

        $script:repairActive = $false
        $script:lastData = $null
        $script:lastCompletedAt = [DateTime]::MinValue
        $script:lastDuration = ''
        $script:lastRepairSummary = ''
        $script:lastFreshStateUtc = $null
        $script:environmentStale = $false
        $script:environmentStaleReason = ''
        $script:lastEnvironmentChangedAt = [DateTime]::MinValue

        if (-not $SkipEngineCheck) {
            [void](Refresh-EngineCheck)
        }
    }

    function Update-Diagnostics {
        param($Data)

        if (-not $Data) {
            foreach ($field in @(
                $DetailClient,
                $DetailService,
                $DetailStartup,
                $DetailBackend,
                $DetailLocalIp,
                $DetailVersion,
                $DetailPeerName,
                $DetailPeerStatus,
                $DetailRoute,
                $DetailLatency,
                $DetailConnectionTrend
            )) {
                $field.Text = '—'
            }

            $DetailPeerIp.Text = $peerDisplay
            $DetailRoute.Foreground = Get-Brush 'Value'
            $SessionText.Text = 'No repair actions yet.'
            $script:copyDiagnosticsText = ''
            return
        }

        $peerName = [string]$Data.peerName
        if ([string]::IsNullOrWhiteSpace($peerName)) {
            $peerName = 'Remote machine'
        }

        $peerStatus = if ([string]$Data.peerReachable -eq 'Reachable') {
            'Reachable'
        } elseif ([string]$Data.peerOnline -eq 'Offline') {
            'Offline'
        } elseif ([bool]$Data.done) {
            'Unreachable'
        } else {
            'Checking'
        }

        $DetailClient.Text = if ($Data.client) { [string]$Data.client } else { '—' }
        $DetailService.Text = if ($Data.service) { [string]$Data.service } else { '—' }
        $DetailStartup.Text = if ($Data.startup) { [string]$Data.startup } else { '—' }
        $DetailBackend.Text = if ($Data.backend) { [string]$Data.backend } else { '—' }
        $DetailLocalIp.Text = if ($Data.localIp) { [string]$Data.localIp } else { '—' }
        $DetailVersion.Text = if ($Data.version) { [string]$Data.version } else { '—' }
        $DetailPeerName.Text = $peerName
        $DetailPeerIp.Text = $peerDisplay
        $DetailPeerStatus.Text = $peerStatus
        $DetailRoute.Text = if ($Data.route) { [string]$Data.route } else { '—' }
        $DetailLatency.Text = if ($Data.latency) { [string]$Data.latency } else { '—' }

        if ([string]$Data.route -like 'Relay*') {
            $DetailRoute.Foreground = Get-Brush 'Amber'
        } else {
            $DetailRoute.Foreground = Get-Brush 'Value'
        }

        $eventsText = ''

        if ($Data.events) {
            $eventsText = @($Data.events) -join [Environment]::NewLine
        }

        $SessionText.Text = if ($eventsText) {
            $eventsText
        }
        elseif ([bool]$Data.done) {
            if ([bool]$Data.repairPerformed) {
                'Repair completed.'
            }
            else {
                'No repair needed.'
            }
        }
        else {
            'Check in progress.'
        }

        if ($script:reliabilityEvents.Count -gt 0) {
            $reliabilityText = @(
                $script:reliabilityEvents |
                    Select-Object -Last 4 |
                    ForEach-Object { "• $_" }
            ) -join [Environment]::NewLine

            $SessionText.Text += [Environment]::NewLine +
                [Environment]::NewLine +
                $reliabilityText
        }

        if ($script:connectionEvents.Count -gt 0) {
            $connectionText = @(
                $script:connectionEvents |
                    Select-Object -Last 4 |
                    ForEach-Object { "• $_" }
            ) -join [Environment]::NewLine

            $SessionText.Text += [Environment]::NewLine +
                [Environment]::NewLine +
                $connectionText
        }

        $script:copyDiagnosticsText = @(
            'Tailscale Quick Repair'
            ''
            'Local'
            "Client: $($DetailClient.Text)"
            "Service: $($DetailService.Text)"
            "Startup: $($DetailStartup.Text)"
            "Backend: $($DetailBackend.Text)"
            "Tailscale IP: $($DetailLocalIp.Text)"
            "Version: $($DetailVersion.Text)"
            ''
            'Remote'
            "Device: $($DetailPeerName.Text)"
            "Peer IP: $Peer"
            "Status: $($DetailPeerStatus.Text)"
            "Route: $($DetailRoute.Text)"
            "Latency: $($DetailLatency.Text)"
            "Session trend: $($DetailConnectionTrend.Text)"
            ''
            'This session'
            $SessionText.Text
        ) -join [Environment]::NewLine
    }

    function Update-CardsAndPath {
        param($Data)

        $LocalAppValue.Text = if ($Data.client) { [string]$Data.client } else { 'Unknown' }
        $LocalServiceValue.Text = if ($Data.service) { [string]$Data.service } else { 'Unknown' }
        $LocalBackendValue.Text = if ($Data.backend) { [string]$Data.backend } else { 'Unknown' }

        if (
            [string]$Data.client -eq 'Running' -and
            [string]$Data.service -eq 'Running' -and
            [string]$Data.backend -eq 'Running'
        ) {
            Set-Badge $LocalBadge $LocalBadgeText 'HEALTHY' 'success'
        } elseif (
            [string]$Data.mode -eq 'repairing' -or
            [bool]$Data.repairPerformed
        ) {
            Set-Badge $LocalBadge $LocalBadgeText 'REPAIRING' 'repairing'
        } elseif (
            [string]$Data.client -eq 'Closed' -or
            [string]$Data.service -eq 'Stopped'
        ) {
            Set-Badge $LocalBadge $LocalBadgeText 'ATTENTION' 'warning'
        } else {
            Set-Badge $LocalBadge $LocalBadgeText 'CHECKING' 'checking'
        }

        $remoteName = [string]$Data.peerName
        if ([string]::IsNullOrWhiteSpace($remoteName)) {
            $remoteName = 'Remote machine'
        }

        $RemoteTitle.Text = $remoteName

        if ([string]$Data.peerReachable -eq 'Reachable') {
            Set-Badge $RemoteBadge $RemoteBadgeText 'REACHABLE' 'success'
            $RemoteStatusValue.Text = 'Reachable'
        } elseif ([string]$Data.peerOnline -eq 'Offline') {
            Set-Badge $RemoteBadge $RemoteBadgeText 'OFFLINE' 'warning'
            $RemoteStatusValue.Text = 'Offline'
        } elseif ([bool]$Data.done) {
            Set-Badge $RemoteBadge $RemoteBadgeText 'UNREACHABLE' 'failure'
            $RemoteStatusValue.Text = 'Unreachable'
        } else {
            Set-Badge $RemoteBadge $RemoteBadgeText 'WAITING' 'checking'
            $RemoteStatusValue.Text = if ([string]$Data.peerOnline -eq 'Online') {
                'Online'
            } else {
                'Checking'
            }
        }

        $RemoteRouteValue.Text = if ($Data.route) { [string]$Data.route } else { '—' }
        $RemoteLatencyValue.Text = if ($Data.latency) { [string]$Data.latency } else { '—' }

        if ([string]$Data.route -like 'Relay*') {
            $RemoteRouteValue.Foreground = Get-Brush 'Amber'
        } else {
            $RemoteRouteValue.Foreground = Get-Brush 'Value'
        }

        $latencyMs = $null

        if ([string]$Data.latency -match '^([0-9]+)') {
            $latencyMs = [int]$Matches[1]
        }

        if ($null -ne $latencyMs) {
            if ($latencyMs -ge 100) {
                $RemoteLatencyValue.Foreground = Get-Brush 'Amber'
                $RemoteLatencyValue.ToolTip = 'Higher latency. Connection is still reachable.'
            } else {
                $RemoteLatencyValue.Foreground = Get-Brush 'Green'
                $RemoteLatencyValue.ToolTip = 'Healthy latency.'
            }
        } else {
            $RemoteLatencyValue.Foreground = Get-Brush 'Value'
            $RemoteLatencyValue.ToolTip = $null
        }

        $appStepState = if ([string]$Data.client -eq 'Running') {
            'good'
        } elseif ([string]$Data.client -eq 'Closed') {
            'warn'
        } elseif ([bool]$Data.done -and [string]$Data.mode -eq 'failure') {
            'bad'
        } elseif ([int]$Data.progress -ge 1) {
            'active'
        } else {
            'idle'
        }
        Set-Step $AppDot $AppStep $appStepState

        $serviceStepState = if ([string]$Data.service -eq 'Running') {
            'good'
        } elseif ([string]$Data.service -eq 'Stopped') {
            'warn'
        } elseif ([bool]$Data.done -and [string]$Data.mode -eq 'failure') {
            'bad'
        } elseif ([int]$Data.progress -ge 22) {
            'active'
        } else {
            'idle'
        }
        Set-Step $ServiceDot $ServiceStep $serviceStepState

        if ([string]$Data.backend -eq 'Running') {
            Set-Step $BackendDot $BackendStep 'good'
        } elseif ([bool]$Data.done -and [string]$Data.mode -eq 'failure') {
            Set-Step $BackendDot $BackendStep 'bad'
        } elseif ([string]$Data.mode -eq 'repairing' -or [int]$Data.progress -ge 48) {
            Set-Step $BackendDot $BackendStep 'active'
        } else {
            Set-Step $BackendDot $BackendStep 'idle'
        }

        if ([string]$Data.peerReachable -eq 'Reachable') {
            Set-Step $PeerDot $PeerStep 'good'
        } elseif ([string]$Data.peerOnline -eq 'Offline') {
            Set-Step $PeerDot $PeerStep 'warn'
        } elseif ([bool]$Data.done -and [string]$Data.mode -eq 'failure') {
            Set-Step $PeerDot $PeerStep 'bad'
        } elseif ([int]$Data.progress -ge 88) {
            Set-Step $PeerDot $PeerStep 'active'
        }

        $PathLine1.Background = if (
            [string]$Data.client -eq 'Running' -and
            [string]$Data.service -eq 'Running'
        ) {
            Get-Brush 'Green'
        } elseif (
            [string]$Data.client -eq 'Running' -and
            -not [bool]$Data.done -and
            [int]$Data.progress -ge 22
        ) {
            Get-Brush 'Blue'
        } else {
            Get-Brush 'Border'
        }

        $PathLine2.Background = if (
            [string]$Data.service -eq 'Running' -and
            [string]$Data.backend -eq 'Running'
        ) {
            Get-Brush 'Green'
        } elseif (
            [string]$Data.service -eq 'Running' -and
            -not [bool]$Data.done -and
            [int]$Data.progress -ge 40
        ) {
            Get-Brush 'Blue'
        } else {
            Get-Brush 'Border'
        }

        $PathLine3.Background = if (
            [string]$Data.peerReachable -eq 'Reachable'
        ) {
            Get-Brush 'Green'
        } elseif (
            [string]$Data.backend -eq 'Running' -and
            -not [bool]$Data.done -and
            [int]$Data.progress -ge 88
        ) {
            Get-Brush 'Blue'
        } else {
            Get-Brush 'Border'
        }
    }

    function Get-UpdateChannel {
        try {
            $value = (Get-ItemProperty -LiteralPath $UpdateChannelRegistryPath -Name $UpdateChannelRegistryName -ErrorAction Stop).$UpdateChannelRegistryName
            if ([string]$value -ceq 'preview') { return 'preview' }
        }
        catch {}
        return 'stable'
    }

    function Set-UpdateChannel {
        param([string]$Channel)

        if ($Channel -ceq 'preview') {
            try {
                New-Item -Path $UpdateChannelRegistryPath -Force | Out-Null
                New-ItemProperty -LiteralPath $UpdateChannelRegistryPath -Name $UpdateChannelRegistryName -Value 'preview' -PropertyType String -Force | Out-Null
                return $true
            }
            catch { return $false }
        }

        if ($Channel -ceq 'stable') {
            try {
                Remove-ItemProperty -LiteralPath $UpdateChannelRegistryPath -Name $UpdateChannelRegistryName -ErrorAction SilentlyContinue
                return $true
            }
            catch { return $false }
        }

        return $false
    }

    function Get-UpdateManifestApiUrl {
        param([string]$Channel)

        switch ($Channel) {
            'stable' { return $StableUpdateManifestApiUrl }
            'preview' { return $PreviewUpdateManifestApiUrl }
            default { throw 'Unsupported Quick Repair update channel.' }
        }
    }

    function Clear-UpdateSelectionForChannelChange {
        $script:updateManifest = $null
        $script:updateManifestChannel = ''
        $UpdateNowButton.Visibility = [System.Windows.Visibility]::Collapsed
        $UpdateStatusText.Text = if ((Get-UpdateChannel) -ceq 'preview') { 'Early-access updates enabled' } else { 'Stable updates enabled' }
        $UpdateStatusText.Foreground = Get-Brush 'Muted'
        $UpdateDetailText.Text = 'Check for updates to refresh this channel.'
        $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
    }

    function Reset-UpdateInstallState {
        try {
            if ($script:updateDownloadTimer) {
                $script:updateDownloadTimer.Stop()
            }
        } catch {}

        try {
            if ($script:updateDownloadClient) {
                $script:updateDownloadClient.Dispose()
            }
        } catch {}

        $script:updateDownloadActive = $false
        $script:updateDownloadClient = $null
        $script:updateDownloadTask = $null
        $script:updateDownloadTimer = $null
        $script:updateExpectedSize = [int64]0
    }

    function Complete-UpdateCheck {
        param(
            [string]$Status,
            [string]$Detail = '',
            [string]$Tone = 'muted'
        )

        $script:updateCheckActive = $false

        try {
            if ($script:updateCheckTimer) {
                $script:updateCheckTimer.Stop()
            }
        } catch {}

        try {
            if ($script:updateWebClient) {
                $script:updateWebClient.Dispose()
            }
        } catch {}

        $script:updateCheckTimer = $null
        $script:updateCheckTask = $null
        $script:updateWebClient = $null

        $UpdateStatusText.Text = $Status

        switch ($Tone) {
            'good' { $UpdateStatusText.Foreground = Get-Brush 'Green' }
            'warn' { $UpdateStatusText.Foreground = Get-Brush 'Amber' }
            'bad' { $UpdateStatusText.Foreground = Get-Brush 'Red' }
            default { $UpdateStatusText.Foreground = Get-Brush 'Muted' }
        }

        if ([string]::IsNullOrWhiteSpace($Detail)) {
            $UpdateDetailText.Text = ''
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Collapsed
        }
        else {
            $UpdateDetailText.Text = $Detail
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
        }

        $CheckForUpdatesButton.Content = 'Check again'
        $CheckForUpdatesButton.IsEnabled = $true
        if ($EarlyAccessUpdatesCheckBox) { $EarlyAccessUpdatesCheckBox.IsEnabled = $true }
    }

    function Start-UpdateCheck {
        if ($script:updateCheckActive -or $script:updateDownloadActive) {
            return
        }

        $script:updateCheckActive = $true
        $script:updateCheckStartedAt = Get-Date
        $script:updateManifest = $null
        $script:updateManifestChannel = ''
        $script:updateCheckChannel = Get-UpdateChannel
        $script:updateChannel = $script:updateCheckChannel
        $manifestApiUrl = Get-UpdateManifestApiUrl $script:updateCheckChannel

        $UpdateNowButton.Visibility = [System.Windows.Visibility]::Collapsed
        $UpdateStatusText.Text = 'Checking for updates…'
        $UpdateStatusText.Foreground = Get-Brush 'Blue'
        $UpdateDetailText.Visibility = [System.Windows.Visibility]::Collapsed
        $CheckForUpdatesButton.Content = 'Checking…'
        $CheckForUpdatesButton.IsEnabled = $false
        if ($EarlyAccessUpdatesCheckBox) { $EarlyAccessUpdatesCheckBox.IsEnabled = $false }

        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor
                [Net.SecurityProtocolType]::Tls12

            $script:updateWebClient = New-Object System.Net.WebClient

            try {
                $script:updateWebClient.Proxy =
                    [System.Net.WebRequest]::DefaultWebProxy

                if ($script:updateWebClient.Proxy) {
                    $script:updateWebClient.Proxy.Credentials =
                        [System.Net.CredentialCache]::DefaultNetworkCredentials
                }
            }
            catch {}

            $script:updateWebClient.Headers.Add(
                'User-Agent',
                "TailscaleQuickRepair/$ProductVersion"
            )
            $script:updateWebClient.Headers.Add(
                'Accept',
                'application/vnd.github+json'
            )
            $script:updateWebClient.Headers.Add(
                'X-GitHub-Api-Version',
                '2022-11-28'
            )
            $script:updateWebClient.Headers.Add(
                'Cache-Control',
                'no-cache'
            )

            $script:updateCheckTask =
                $script:updateWebClient.DownloadStringTaskAsync(
                    [Uri]$manifestApiUrl
                )

            if (-not $script:updateCheckTask) {
                throw 'The GitHub API request could not start.'
            }

            $script:updateCheckTimer = New-Object Windows.Threading.DispatcherTimer
            $script:updateCheckTimer.Interval = [TimeSpan]::FromMilliseconds(150)

            $script:updateCheckTimer.Add_Tick({
                try {
                    if (
                        $script:updateCheckStartedAt -ne [DateTime]::MinValue -and
                        ((Get-Date) - $script:updateCheckStartedAt).TotalSeconds -gt 12
                    ) {
                        try {
                            if ($script:updateWebClient) {
                                $script:updateWebClient.CancelAsync()
                            }
                        } catch {}

                        Complete-UpdateCheck `
                            -Status 'Could not check for updates' `
                            -Detail 'GitHub did not respond in time. Nothing was changed.' `
                            -Tone 'warn'
                        return
                    }

                    if (
                        -not $script:updateCheckTask -or
                        -not $script:updateCheckTask.IsCompleted
                    ) {
                        return
                    }

                    if ($script:updateCheckTask.IsCanceled) {
                        Complete-UpdateCheck `
                            -Status 'Could not check for updates' `
                            -Detail 'The GitHub request was cancelled. Nothing was changed.' `
                            -Tone 'warn'
                        return
                    }

                    if ($script:updateCheckTask.IsFaulted) {
                        $reason = 'GitHub API request failed.'

                        try {
                            $message = [string](
                                $script:updateCheckTask.Exception.GetBaseException().Message
                            )

                            if (-not [string]::IsNullOrWhiteSpace($message)) {
                                if ($message.Length -gt 110) {
                                    $message = $message.Substring(0, 110).TrimEnd() + '…'
                                }

                                $reason = "GitHub API request failed · $message"
                            }
                        }
                        catch {}

                        Complete-UpdateCheck `
                            -Status 'Could not check for updates' `
                            -Detail "$reason Nothing was changed." `
                            -Tone 'warn'
                        return
                    }

                    $apiRaw = [string]$script:updateCheckTask.Result
                    $apiFile = $apiRaw | ConvertFrom-Json -ErrorAction Stop
                    $expectedApiPath = if ($script:updateCheckChannel -ceq 'preview') { 'updates/preview.json' } else { 'updates/latest.json' }

                    if (
                        [string]$apiFile.encoding -ne 'base64' -or
                        [string]$apiFile.path -cne $expectedApiPath -or
                        [string]::IsNullOrWhiteSpace([string]$apiFile.content)
                    ) {
                        throw 'GitHub returned an unexpected update-channel response.'
                    }

                    $encoded = ([string]$apiFile.content) -replace '\s', ''
                    $bytes = [Convert]::FromBase64String($encoded)
                    $manifestText = [Text.Encoding]::UTF8.GetString($bytes)
                    $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop

                    if (
                        [int]$manifest.schema -ne 1 -or
                        [string]::IsNullOrWhiteSpace([string]$manifest.version) -or
                        [int64]$manifest.versionCode -le 0
                    ) {
                        throw 'The update manifest is not valid.'
                    }

                    if ($script:updateCheckChannel -ceq 'preview' -and [string]$manifest.channel -cne 'preview') {
                        throw 'The Early-access manifest channel is invalid.'
                    }

                    if (-not [bool]$manifest.published) {
                        $noReleaseDetail = if ($script:updateCheckChannel -ceq 'preview') { 'No newer Early-access release is published right now.' } else { 'No newer public release is published right now.' }
                        Complete-UpdateCheck `
                            -Status 'Update channel connected' `
                            -Detail $noReleaseDetail `
                            -Tone 'good'
                        return
                    }

                    if ([int64]$manifest.versionCode -gt $ProductVersionCode) {
                        $packageUrl = [string]$manifest.package.url
                        $packageHash = ([string]$manifest.package.sha256).ToLowerInvariant()
                        $packageSize = [int64]$manifest.package.size

                        $packageUri = $null

                        if (-not [Uri]::TryCreate(
                            $packageUrl,
                            [UriKind]::Absolute,
                            [ref]$packageUri
                        )) {
                            throw 'The update package URL is invalid.'
                        }

                        if (
                            $packageUri.Scheme -ne 'https' -or
                            $packageUri.Host -ne 'github.com' -or
                            $packageUri.AbsolutePath -notlike '/coachedai/tailscale-repair-clean/releases/download/*' -or
                            $packageHash -notmatch '^[a-f0-9]{64}$' -or
                            $packageSize -le 0
                        ) {
                            throw 'The update package metadata failed trust validation.'
                        }

                        $script:updateManifest = $manifest
                        $script:updateManifestChannel = $script:updateCheckChannel
                        $UpdateNowButton.Visibility = [System.Windows.Visibility]::Visible

                        $notes = [string]$manifest.notes
                        if ([string]::IsNullOrWhiteSpace($notes)) {
                            $notes = 'A newer Quick Repair release is available.'
                        }

                        Complete-UpdateCheck `
                            -Status "Update available · $([string]$manifest.version)" `
                            -Detail $notes `
                            -Tone 'warn'
                        return
                    }

                    Complete-UpdateCheck `
                        -Status "You're up to date" `
                        -Detail "Current version: $ProductVersion" `
                        -Tone 'good'
                }
                catch {
                    $script:updateManifest = $null
                    $script:updateManifestChannel = ''
                    $UpdateNowButton.Visibility = [System.Windows.Visibility]::Collapsed

                    Complete-UpdateCheck `
                        -Status 'Could not check for updates' `
                        -Detail 'The GitHub update response could not be validated. Nothing was changed.' `
                        -Tone 'warn'
                }
            })

            $script:updateCheckTimer.Start()
        }
        catch {
            $script:updateManifest = $null
            $UpdateNowButton.Visibility = [System.Windows.Visibility]::Collapsed

            Complete-UpdateCheck `
                -Status 'Could not check for updates' `
                -Detail 'The update check could not start. Nothing was changed.' `
                -Tone 'warn'
        }
    }

    function Start-UpdateInstall {
        if (
            $script:updateDownloadActive -or
            $script:repairActive -or
            -not $script:updateManifest
        ) {
            return
        }

        if (
            -not (Test-Path -LiteralPath $UpdaterHostPath) -or
            -not (Test-Path -LiteralPath $UpdateInstallerPath)
        ) {
            $UpdateStatusText.Text = 'Updater components are missing'
            $UpdateStatusText.Foreground = Get-Brush 'Amber'
            $UpdateDetailText.Text = 'Run Repair installation once, then check for updates again.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            return
        }

        $version = [string]$script:updateManifest.version
        $notes = [string]$script:updateManifest.notes

        if ([string]::IsNullOrWhiteSpace($notes)) {
            $notes = 'Install the available Quick Repair update?'
        }

        Add-Type -AssemblyName System.Windows.Forms

        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Install Tailscale Quick Repair $version?`r`n`r`n$notes`r`n`r`nThe package will be verified before anything is replaced.",
            'Tailscale Quick Repair',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        try {
            $packageUrl = [string]$script:updateManifest.package.url
            $expectedHash = ([string]$script:updateManifest.package.sha256).ToLowerInvariant()
            $expectedSize = [int64]$script:updateManifest.package.size
            $targetCode = [int64]$script:updateManifest.versionCode

            $packageName = "TailscaleQuickRepair-update-$targetCode.zip"
            $script:updatePackagePath = Join-Path $env:TEMP $packageName
            $script:updateExpectedSize = $expectedSize

            Remove-Item `
                -LiteralPath $script:updatePackagePath `
                -Force `
                -ErrorAction SilentlyContinue

            $script:updateDownloadActive = $true
            $UpdateStatusText.Text = "Downloading · $version"
            $UpdateStatusText.Foreground = Get-Brush 'Blue'
            $UpdateDetailText.Text = 'Downloading the verified GitHub release package…'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            $CheckForUpdatesButton.IsEnabled = $false
            $UpdateNowButton.IsEnabled = $false
            $UpdateNowButton.Content = 'Downloading…'

            $script:updateDownloadClient = New-Object System.Net.WebClient

            try {
                $script:updateDownloadClient.Proxy =
                    [System.Net.WebRequest]::DefaultWebProxy

                if ($script:updateDownloadClient.Proxy) {
                    $script:updateDownloadClient.Proxy.Credentials =
                        [System.Net.CredentialCache]::DefaultNetworkCredentials
                }
            }
            catch {}

            $script:updateDownloadClient.Headers.Add(
                'User-Agent',
                "TailscaleQuickRepair/$ProductVersion"
            )

            $script:updateDownloadTask =
                $script:updateDownloadClient.DownloadFileTaskAsync(
                    [Uri]$packageUrl,
                    $script:updatePackagePath
                )

            $script:updateDownloadTimer = New-Object Windows.Threading.DispatcherTimer
            $script:updateDownloadTimer.Interval = [TimeSpan]::FromMilliseconds(180)

            $script:updateDownloadTimer.Add_Tick({
                try {
                    if (
                        $script:updateExpectedSize -gt 0 -and
                        (Test-Path -LiteralPath $script:updatePackagePath)
                    ) {
                        $length = (Get-Item -LiteralPath $script:updatePackagePath).Length
                        $percent = [Math]::Min(
                            99,
                            [Math]::Max(
                                0,
                                [int](($length / $script:updateExpectedSize) * 100)
                            )
                        )

                        $UpdateDetailText.Text = "Downloading release package · $percent%"
                    }

                    if (
                        -not $script:updateDownloadTask -or
                        -not $script:updateDownloadTask.IsCompleted
                    ) {
                        return
                    }

                    if (
                        $script:updateDownloadTask.IsCanceled -or
                        $script:updateDownloadTask.IsFaulted -or
                        -not (Test-Path -LiteralPath $script:updatePackagePath)
                    ) {
                        Reset-UpdateInstallState
                        $CheckForUpdatesButton.IsEnabled = $true
                        $UpdateNowButton.IsEnabled = $true
                        $UpdateNowButton.Content = 'Update now'

                        $UpdateStatusText.Text = 'Update download failed'
                        $UpdateStatusText.Foreground = Get-Brush 'Amber'
                        $UpdateDetailText.Text = 'Nothing was changed. Check your connection and try again.'
                        return
                    }

                    $UpdateStatusText.Text = 'Verifying update…'
                    $UpdateDetailText.Text = 'Checking SHA-256 before installation.'

                    $actualHash = (
                        Get-FileHash `
                            -LiteralPath $script:updatePackagePath `
                            -Algorithm SHA256
                    ).Hash.ToLowerInvariant()

                    if ($actualHash -ne $expectedHash) {
                        Remove-Item `
                            -LiteralPath $script:updatePackagePath `
                            -Force `
                            -ErrorAction SilentlyContinue

                        Reset-UpdateInstallState
                        $CheckForUpdatesButton.IsEnabled = $true
                        $UpdateNowButton.IsEnabled = $true
                        $UpdateNowButton.Content = 'Update now'

                        $UpdateStatusText.Text = 'Update verification failed'
                        $UpdateStatusText.Foreground = Get-Brush 'Red'
                        $UpdateDetailText.Text = 'The downloaded package hash did not match. Nothing was installed.'
                        return
                    }

                    $tempUpdater = Join-Path $env:TEMP (
                        'TailscaleQuickRepairUpdater-' +
                        [Guid]::NewGuid().ToString('N') +
                        '.exe'
                    )
                    $tempScript = Join-Path $env:TEMP (
                        'TailscaleQuickRepairUpdate-' +
                        [Guid]::NewGuid().ToString('N') +
                        '.ps1'
                    )

                    Copy-Item -LiteralPath $UpdaterHostPath -Destination $tempUpdater -Force
                    Copy-Item -LiteralPath $UpdateInstallerPath -Destination $tempScript -Force

                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = $tempUpdater
                    $psi.Arguments = @(
                        '--script'
                        ('"' + $tempScript + '"')
                        '--package'
                        ('"' + $script:updatePackagePath + '"')
                        '--sha256'
                        ('"' + $expectedHash + '"')
                        '--version-code'
                        ([string]$targetCode)
                        '--current-pid'
                        ([string]$PID)
                    ) -join ' '
                    $psi.UseShellExecute = $true

                    $updaterProcess = [System.Diagnostics.Process]::Start($psi)

                    if (-not $updaterProcess) {
                        throw 'The updater could not start.'
                    }

                    Reset-UpdateInstallState

                    $UpdateStatusText.Text = 'Installing update…'
                    $UpdateStatusText.Foreground = Get-Brush 'Blue'
                    $UpdateDetailText.Text = 'Administrator approval may be requested. Quick Repair will restart automatically.'

                    $script:allowFullExit = $true

                    $window.Dispatcher.BeginInvoke(
                        [System.Windows.Threading.DispatcherPriority]::Background,
                        [Action]{
                            $window.Close()
                        }
                    ) | Out-Null
                }
                catch {
                    Reset-UpdateInstallState
                    $CheckForUpdatesButton.IsEnabled = $true
                    $UpdateNowButton.IsEnabled = $true
                    $UpdateNowButton.Content = 'Update now'

                    $UpdateStatusText.Text = 'Could not start update'
                    $UpdateStatusText.Foreground = Get-Brush 'Amber'
                    $UpdateDetailText.Text = 'Nothing was changed. Try again.'
                    $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
                }
            })

            $script:updateDownloadTimer.Start()
        }
        catch {
            Reset-UpdateInstallState
            $CheckForUpdatesButton.IsEnabled = $true
            $UpdateNowButton.IsEnabled = $true
            $UpdateNowButton.Content = 'Update now'

            $UpdateStatusText.Text = 'Could not start update'
            $UpdateStatusText.Foreground = Get-Brush 'Amber'
            $UpdateDetailText.Text = 'Nothing was changed.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
        }
    }

    function Show-UpdateResult {
        if (-not (Test-Path -LiteralPath $UpdateResultPath)) {
            return
        }

        try {
            $result = Get-Content -LiteralPath $UpdateResultPath -Raw | ConvertFrom-Json
            Remove-Item -LiteralPath $UpdateResultPath -Force -ErrorAction SilentlyContinue

            if ([bool]$result.success) {
                $UpdateStatusText.Text = "Updated successfully - $([string]$result.version)"
                $UpdateStatusText.Foreground = Get-Brush 'Green'
                $UpdateDetailText.Text = 'The verified update was installed and Quick Repair restarted normally.'
                $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            }
            else {
                $UpdateStatusText.Text = 'Update was rolled back'
                $UpdateStatusText.Foreground = Get-Brush 'Amber'
                $UpdateDetailText.Text = [string]$result.message
                $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            }
        }
        catch {}
    }

    function Update-HeroAndAction {
        param($Data)

        $mode = [string]$Data.mode
        $progress = [int]$Data.progress
        $done = [bool]$Data.done

        $newHeroTitle = [string]$Data.status
        $newHeroDetail = [string]$Data.detail

        if ($HeroTitle.Text -ne $newHeroTitle) {
            $HeroTitle.Text = $newHeroTitle
        }

        if ($HeroDetail.Text -ne $newHeroDetail) {
            $HeroDetail.Text = $newHeroDetail
        }

        if ($mode -eq 'success') {
            Set-Badge $HeroBadge $HeroBadgeText 'HEALTHY' 'success'
        } elseif ($mode -eq 'warning') {
            Set-Badge $HeroBadge $HeroBadgeText 'ATTENTION' 'warning'
        } elseif ($mode -eq 'failure') {
            Set-Badge $HeroBadge $HeroBadgeText 'NEEDS ATTENTION' 'failure'
        } elseif ($mode -eq 'repairing') {
            Set-Badge $HeroBadge $HeroBadgeText 'REPAIRING' 'repairing'
        } else {
            Set-Badge $HeroBadge $HeroBadgeText 'CHECKING' 'checking'
        }

        if ($done) {
            if ($mode -eq 'success') {
                Set-ActionButton 'Check Again' 'repair' $true
            } elseif (
                [string]$Data.client -eq 'Closed' -or
                [string]$Data.backend -in @('NeedsLogin', 'Stopped')
            ) {
                Set-ActionButton 'Open Tailscale' 'open' $true 'primary'
            } else {
                Set-ActionButton 'Try Again' 'repair' $true 'primary'
            }
        } else {
            Set-ActionButton 'Working…' 'repair' $false
        }
    }

    function Get-LocalPreflight {
        $client = if (Test-TailscaleClientProcess) { 'Running' } else { 'Closed' }
        $service = Get-TailscaleService
        $serviceState = if ($service) { [string]$service.Status } else { 'Missing' }

        return [pscustomobject]@{
            Client = $client
            Service = $serviceState
        }
    }

    function Get-PreflightText {
        param($Preflight)

        if (
            [string]$Preflight.Client -eq 'Running' -and
            [string]$Preflight.Service -eq 'Running'
        ) {
            return 'Ready for a full check.'
        }

        if (
            [string]$Preflight.Client -eq 'Closed' -and
            [string]$Preflight.Service -eq 'Running'
        ) {
            return 'The Tailscale desktop client is closed. Quick Repair will reopen it if needed.'
        }

        if ([string]$Preflight.Service -eq 'Stopped') {
            return 'The Tailscale service is stopped. Quick Repair can recover it.'
        }

        if ([string]$Preflight.Service -eq 'Missing') {
            return 'The Tailscale Windows service is not installed.'
        }

        return 'Ready to check.'
    }

    function Get-RunDurationText {
        param([DateTime]$StartedAt)

        if ($StartedAt -eq [DateTime]::MinValue) { return '' }

        $seconds = ((Get-Date) - $StartedAt).TotalSeconds

        if ($seconds -lt 0) { return '' }

        if ($seconds -lt 10) {
            return ('{0:N1}s' -f $seconds)
        }

        return ('{0:N0}s' -f $seconds)
    }

    function Update-TrayStatus {
        param($Data)

        if (-not $script:trayStatusItem) { return }

        try {
            $statusText = 'Ready'
            $color = [System.Drawing.Color]::FromArgb(70, 80, 92)

            if ($Data) {
                if (-not [bool]$Data.done) {
                    $statusText = 'Checking…'
                    $color = [System.Drawing.Color]::FromArgb(16, 90, 190)
                }
                elseif (
                    [string]$Data.mode -eq 'success' -and
                    [string]$Data.peerReachable -eq 'Reachable'
                ) {
                    $route = if ($Data.route) { [string]$Data.route } else { 'Connected' }
                    $latency = if ($Data.latency) { [string]$Data.latency } else { '' }

                    $statusText = 'Healthy · ' + $route

                    if ($latency) {
                        $statusText += ' · ' + $latency
                    }

                    $color = [System.Drawing.Color]::FromArgb(24, 128, 88)
                }
                elseif ([string]$Data.mode -eq 'warning') {
                    $statusText = 'Attention'
                    $color = [System.Drawing.Color]::FromArgb(175, 120, 20)
                }
                elseif ([string]$Data.mode -eq 'failure') {
                    $statusText = 'Needs attention'
                    $color = [System.Drawing.Color]::FromArgb(180, 65, 72)
                }
                elseif ([bool]$Data.repairPerformed) {
                    $statusText = 'Repaired'
                    $color = [System.Drawing.Color]::FromArgb(24, 128, 88)
                }
            }

            $script:trayStatusItem.Text = $statusText
            $script:trayStatusItem.ForeColor = $color
            $script:notifyIcon.Text = 'Quick Repair · ' + ($statusText -replace ' · .*$', '')
            Update-TrayFreshness
        }
        catch {}
    }

    function Build-TrayMenu {
        if ($script:trayMenu) {
            try { $script:trayMenu.Dispose() } catch {}
        }

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.ShowImageMargin = $false
        $menu.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $script:trayStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Ready')
        $script:trayStatusItem.Enabled = $false
        $script:trayStatusItem.Font = New-Object System.Drawing.Font(
            'Segoe UI',
            9,
            [System.Drawing.FontStyle]::Bold
        )

        $script:trayFreshnessItem = New-Object System.Windows.Forms.ToolStripMenuItem('Not checked yet')
        $script:trayFreshnessItem.Enabled = $false
        $script:trayFreshnessItem.ForeColor = [System.Drawing.Color]::Gray

        $script:trayCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem('Check now')
        $script:trayCopyStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Copy status')
        $script:trayCopyPeerIpItem = New-Object System.Windows.Forms.ToolStripMenuItem('Copy peer IP')
        $script:trayOpenItem = New-Object System.Windows.Forms.ToolStripMenuItem('Open Quick Repair')
        $script:trayExitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')

        $script:trayOpenItem.Font = New-Object System.Drawing.Font(
            'Segoe UI',
            9,
            [System.Drawing.FontStyle]::Bold
        )

        [void]$menu.Items.Add($script:trayStatusItem)
        [void]$menu.Items.Add($script:trayFreshnessItem)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        [void]$menu.Items.Add($script:trayCheckItem)
        [void]$menu.Items.Add($script:trayCopyStatusItem)
        [void]$menu.Items.Add($script:trayCopyPeerIpItem)
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        [void]$menu.Items.Add($script:trayOpenItem)
        [void]$menu.Items.Add($script:trayExitItem)

        $script:trayMenu = $menu
        $script:notifyIcon.ContextMenuStrip = $menu

        $menu.Add_Opening({
            $script:trayCopyStatusItem.Text = 'Copy status'
            Update-TrayFreshness
        })

        $script:trayCheckItem.Add_Click({
            $window.Dispatcher.BeginInvoke(
                [Action]{
                    Restore-FromTray
                    Start-Repair
                }
            ) | Out-Null
        })

        $script:trayCopyStatusItem.Add_Click({
            $window.Dispatcher.BeginInvoke(
                [Action]{
                    try {
                        $data = $script:lastData

                        if (-not $data) {
                            $copyText = 'Tailscale Quick Repair' + [Environment]::NewLine + 'No completed check yet.'
                        }
                        else {
                            $remoteName = [string]$data.peerName
                            if ([string]::IsNullOrWhiteSpace($remoteName)) { $remoteName = 'Remote machine' }

                            $statusText = if ([string]$data.peerReachable -eq 'Reachable') {
                                'Reachable'
                            } elseif ([string]$data.peerOnline -eq 'Offline') {
                                'Offline'
                            } elseif ([bool]$data.done) {
                                'Unreachable'
                            } else {
                                'Checking'
                            }

                            $copyText = @(
                                'Tailscale Quick Repair'
                                "Result: $([string]$data.status)"
                                "Freshness: $(Get-TrayFreshnessText)"
                                ''
                                'Local'
                                "App: $([string]$data.client)"
                                "Service: $([string]$data.service)"
                                "Backend: $([string]$data.backend)"
                                "Tailscale IP: $($data.localIp)"
                                ''
                                'Remote'
                                "Device: $remoteName"
                                "Peer IP: $Peer"
                                "Status: $statusText"
                                "Route: $($data.route)"
                                "Latency: $($data.latency)"
                            ) -join [Environment]::NewLine
                        }

                        [System.Windows.Clipboard]::SetText($copyText)
                        $script:trayCopyStatusItem.Text = 'Copied ✓'
                    }
                    catch {
                        try { $script:trayCopyStatusItem.Text = 'Copy failed' } catch {}
                    }
                }
            ) | Out-Null
        })

        $script:trayCopyPeerIpItem.Add_Click({
            $window.Dispatcher.BeginInvoke(
                [Action]{
                    try {
                        [System.Windows.Clipboard]::SetText($Peer)
                        $script:trayCopyPeerIpItem.Text = 'Copied ✓'
                    } catch {
                        try { $script:trayCopyPeerIpItem.Text = 'Copy failed' } catch {}
                    }
                }
            ) | Out-Null
        })

        $script:trayOpenItem.Add_Click({
            $window.Dispatcher.BeginInvoke(
                [Action]{
                    Restore-FromTray
                }
            ) | Out-Null
        })

        $script:trayExitItem.Add_Click({
            $window.Dispatcher.BeginInvoke(
                [Action]{
                    $script:allowFullExit = $true
                    $window.Close()
                }
            ) | Out-Null
        })
    }

    function Initialize-TrayIcon {
        if ($script:notifyIcon) { return }

        $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:notifyIcon.Visible = $true
        $script:notifyIcon.Text = 'Quick Repair · Ready'

        try {
            $tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale-ipn.exe'

            if (Test-Path -LiteralPath $tailscaleExe) {
                $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($tailscaleExe)
                $script:notifyIcon.Icon = $icon
            }
            else {
                $script:notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
            }
        }
        catch {
            $script:notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
        }

        Build-TrayMenu

        $script:notifyIcon.Add_MouseClick({
            param($sender, $eventArgs)

            if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                $window.Dispatcher.BeginInvoke(
                    [Action]{
                        Restore-FromTray
                    }
                ) | Out-Null
            }
        })
    }

    function Move-ToTray {
        try {
            Initialize-TrayIcon
            $window.Hide()
            $window.ShowInTaskbar = $false
            $script:hiddenToTray = $true
        }
        catch {}
    }

    function Restore-FromTray {
        try {
            $window.Opacity = 1
            $window.ShowInTaskbar = $true
            $window.Show()
            $window.WindowState = [System.Windows.WindowState]::Maximized
            $window.Activate()
            $window.Topmost = $true
            $window.Topmost = $false
            $window.Focus()
            $script:hiddenToTray = $false
        }
        catch {}
    }

    function Open-TailscaleContextually {
        try {
            $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale-ipn.exe'

            if (Test-Path -LiteralPath $candidate) {
                Start-Process -FilePath $candidate | Out-Null
            }
        }
        catch {}
    }

    function Show-ImmediateRunState {
        $script:repairActive = $true
        $script:environmentStale = $false
        $script:environmentStaleReason = ''
        $script:launchUtc = [DateTime]::UtcNow
        $script:runStartedAt = Get-Date
        $script:lastDuration = ''
        $script:notifiedForCurrentRun = $false
        $script:lastFreshStateUtc = $null
        $script:lastAppliedStateWriteUtc = [DateTime]::MinValue
        $script:lastData = $null

        Set-ConnectionInsight '' 'muted'
        $LastCheckedText.Visibility = [System.Windows.Visibility]::Collapsed

        Set-Badge $HeroBadge $HeroBadgeText 'CHECKING' 'checking'
        $HeroTitle.Text = 'Checking Tailscale'
        $HeroDetail.Text = 'Starting the check…'

        Set-Badge $LocalBadge $LocalBadgeText 'CHECKING' 'checking'
        Set-Badge $RemoteBadge $RemoteBadgeText 'WAITING' 'checking'

        Set-Step $AppDot $AppStep 'active'
        Set-Step $ServiceDot $ServiceStep 'idle'
        Set-Step $BackendDot $BackendStep 'idle'
        Set-Step $PeerDot $PeerStep 'idle'

        $PathLine1.Background = Get-Brush 'Border'
        $PathLine2.Background = Get-Brush 'Border'
        $PathLine3.Background = Get-Brush 'Border'

        Set-ActionButton 'Working…' 'repair' $false
        Update-TrayStatus $null
        Update-TrayFreshness
    }

    function Start-RepairCore {
        if (Attach-To-RunningRepair) {
            return
        }

        if (-not (Ensure-EngineReadyCached)) {
            $script:repairActive = $false
            return
        }

        # Preserve the previous result until the newly owned backend publishes.

        $script:lastAppliedStateWriteUtc = [DateTime]::MinValue
        $script:launchUtc = [DateTime]::UtcNow

        $HeroDetail.Text = 'Starting the protected check.'

        try {
            [void](Invoke-RepairTask)
        }
        catch {
            $script:repairActive = $false

            Set-Badge $HeroBadge $HeroBadgeText 'NEEDS ATTENTION' 'failure'
            $HeroTitle.Text = 'Could not start repair'
            $HeroDetail.Text = $_.Exception.Message
            Set-ActionButton 'Try Again' 'repair' $true
        }
    }

    function Start-Repair {
        if ($script:repairActive) {
            return
        }

        $activeOperation = Get-ActiveOperationLock -RecoverStale
        if ($activeOperation) {
            if ([string]$activeOperation.kind -eq 'repair' -and (Attach-To-RunningRepair)) {
                return
            }

            $kind = [string]$activeOperation.kind
            if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'another Quick Repair operation' }
            Set-Badge $HeroBadge $HeroBadgeText 'BUSY' 'warning'
            $HeroTitle.Text = 'Quick Repair is busy'
            $HeroDetail.Text = "Wait for $kind to finish, then run the check again."
            Set-ActionButton 'Try Again' 'repair' $true
            return
        }

        # Immediate visual response. Actual scheduler/client work starts only
        # after this frame has been handed back to WPF.
        Show-ImmediateRunState

        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{
                Start-RepairCore
            }
        ) | Out-Null
    }

    function Apply-State {
        param($Data)

        if (-not $Data) { return }

        $script:lastData = $Data
        Update-HeroAndAction $Data
        Update-CardsAndPath $Data
        Update-ConnectionIntelligence $Data
        Update-Diagnostics $Data
        Update-TrayStatus $Data

        if ([bool]$Data.done) {
            $script:repairActive = $false
            $script:environmentStale = $false
            $script:environmentStaleReason = ''
            $script:lastCompletedAt = Get-Date
            $script:lastDuration = Get-RunDurationText $script:runStartedAt

            Update-LastCheckedText
            Update-TrayFreshness

            if (
                -not $script:notifiedForCurrentRun -and
                [bool]$Data.repairPerformed
            ) {
                $script:notifiedForCurrentRun = $true
            }
        }
    }

    # --------------------------------------------------------------
    # Timers
    # --------------------------------------------------------------
    $stateTimer = New-Object Windows.Threading.DispatcherTimer
    $stateTimer.Interval = [TimeSpan]::FromMilliseconds(150)

    $stateTimer.Add_Tick({
        try {
            if (Test-Path -LiteralPath $StateFile) {
                $stateItem = Get-Item -LiteralPath $StateFile -ErrorAction Stop

                if (
                    $stateItem.LastWriteTimeUtc -ge $script:launchUtc.AddSeconds(-1) -and
                    $stateItem.LastWriteTimeUtc -gt $script:lastAppliedStateWriteUtc
                ) {
                    $data = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop |
                        ConvertFrom-Json -ErrorAction Stop

                    $script:lastAppliedStateWriteUtc = $stateItem.LastWriteTimeUtc
                    $script:lastFreshStateUtc = [DateTime]::UtcNow
                    Apply-State $data
                }
            }

            if ($script:repairActive) {
                $taskState = Get-RepairTaskState

                if ($taskState -notin @('Running','Queued') -and
                    -not $script:lastFreshStateUtc -and
                    ([DateTime]::UtcNow - $script:launchUtc).TotalSeconds -gt 4) {
                    $script:repairActive = $false
                    Set-Badge $HeroBadge $HeroBadgeText 'ATTENTION' 'warning'
                    $HeroTitle.Text = 'The check did not start'
                    $HeroDetail.Text = 'No new repair result was returned. Let any other Quick Repair operation finish, then try again.'
                    Set-ActionButton 'Try Again' 'repair' $true
                    return
                }

                if (
                    $taskState -ne 'Running' -and
                    $script:lastFreshStateUtc -and
                    (([DateTime]::UtcNow - $script:lastFreshStateUtc).TotalSeconds -gt 2)
                ) {
                    $script:repairActive = $false

                    if (
                        $script:lastData -and
                        -not [bool]$script:lastData.done
                    ) {
                        Set-Badge $HeroBadge $HeroBadgeText 'ATTENTION' 'warning'
                        $HeroTitle.Text = 'The check ended early'
                        $HeroDetail.Text = 'The repair worker stopped before returning a final result. You can safely try again.'
                        Set-ActionButton 'Try Again' 'repair' $true 'primary'
                    }
                }
            }
        }
        catch {}
    })

    # Smart Auto Repair local watcher.
    # It performs only cheap local service/process checks — no peer/network probe.
    $script:autoRepairLocalWatchTimer = New-Object Windows.Threading.DispatcherTimer
    $script:autoRepairLocalWatchTimer.Interval = [TimeSpan]::FromSeconds(10)
    $script:autoRepairLocalWatchTimer.Add_Tick({
        Poll-ReliabilityEnvironment
        Check-AutoRepairLocalTransitions
    })

    # UI-only: reads the local auto-repair state file.
    $script:autoRepairUiTimer = New-Object Windows.Threading.DispatcherTimer
    $script:autoRepairUiTimer.Interval = [TimeSpan]::FromSeconds(5)
    $script:autoRepairUiTimer.Add_Tick({
        if ($DetailsPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            Update-AutoRepairStatus
        }
    })

    $freshnessTimer = New-Object Windows.Threading.DispatcherTimer
    $freshnessTimer.Interval = [TimeSpan]::FromSeconds(20)
    $freshnessTimer.Add_Tick({
        Update-LastCheckedText
        Update-TrayFreshness
    })

    $activationTimer = New-Object Windows.Threading.DispatcherTimer
    $activationTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $activationTimer.Add_Tick({
        try {
            if ($activateEvent.WaitOne(0)) {
                Restore-FromTray
            }
        }
        catch {}
    })

    # --------------------------------------------------------------
    # Events
    # --------------------------------------------------------------
    $CopyButton.Add_Click({
        if ($script:copyDiagnosticsText) {
            try {
                [System.Windows.Clipboard]::SetText($script:copyDiagnosticsText)
                $CopyButton.Content = 'Copied ✓'
            } catch {}
        }
    })

    $AdvancedDiagnosticsButton.Add_Click({
        Start-AdvancedDiagnostics
    })

    $AdvancedCopyButton.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($script:advancedDiagnosticsReport)) {
            try {
                [System.Windows.Clipboard]::SetText($script:advancedDiagnosticsReport)
                $AdvancedCopyButton.Content = 'Copied ✓'
            } catch {}
        }
    })

    $RepairInstallationButton.Add_Click({
        Invoke-InstallationRepair
    })

    $CheckForUpdatesButton.Add_Click({
        Start-UpdateCheck
    })

    $UpdateNowButton.Add_Click({
        Start-UpdateInstall
    })

    $EarlyAccessUpdatesCheckBox.Add_Checked({
        if ($script:initializingUpdateChannel) { return }
        if (Set-UpdateChannel 'preview') {
            $script:updateChannel = 'preview'
            Clear-UpdateSelectionForChannelChange
        }
        else {
            $script:initializingUpdateChannel = $true
            try { $EarlyAccessUpdatesCheckBox.IsChecked = $false }
            finally { $script:initializingUpdateChannel = $false }
        }
    })

    $EarlyAccessUpdatesCheckBox.Add_Unchecked({
        if ($script:initializingUpdateChannel) { return }
        if (Set-UpdateChannel 'stable') {
            $script:updateChannel = 'stable'
            Clear-UpdateSelectionForChannelChange
        }
        else {
            $script:initializingUpdateChannel = $true
            try { $EarlyAccessUpdatesCheckBox.IsChecked = $true }
            finally { $script:initializingUpdateChannel = $false }
        }
    })

    $PrimaryButton.Add_Click({
        switch ($script:actionMode) {
            'open' { Open-TailscaleContextually }
            'repair' { Start-Repair }
            'repair-install' { Invoke-InstallationRepair }
            default {}
        }
    })

    $DetailsButton.Add_Click({
        $offset = $MainScrollViewer.VerticalOffset

        if ($DetailsPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            $DetailsPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $DetailsButton.Content = 'Details  ›'
            Restore-ScrollOffset $offset
        } else {
            $CopyButton.Content = 'Copy'
            Update-Diagnostics $script:lastData
            Initialize-AutoRepairUi
            $DetailsPanel.Opacity = 0
            $DetailsPanel.Visibility = [System.Windows.Visibility]::Visible
            $DetailsButton.Content = 'Hide details  ↑'
            Fade-In $DetailsPanel 0.72 160
            Restore-ScrollOffset $offset
        }
    })

    $StartWithWindowsCheckBox.Add_Checked({
        if (Set-StartWithWindows $true) {
            $StartWithWindowsCheckBox.IsChecked = $true
        }
        else {
            $StartWithWindowsCheckBox.IsChecked = $false
        }
    })

    $StartWithWindowsCheckBox.Add_Unchecked({
        [void](Set-StartWithWindows $false)
    })

    $AutoRepairCheckBox.Add_Checked({
        if ($script:initializingAutoRepair) { return }

        if (-not (Refresh-AutoRepairAvailability -Force)) {
            $script:initializingAutoRepair = $true
            try { $AutoRepairCheckBox.IsChecked = $false }
            finally { $script:initializingAutoRepair = $false }
            Update-AutoRepairStatus
            return
        }

        if (Set-AutoRepairEnabled $true) {
            $AutoRepairCheckNowButton.IsEnabled = $true
            $AutoRepairTriggerText.Visibility = [System.Windows.Visibility]::Visible
            $AutoRepairStatusText.Text = 'Enabled · checking local Tailscale…'
            $AutoRepairStatusText.Foreground = Get-Brush 'Blue'
            Initialize-AutoRepairLocalWatch
            Invoke-AutoRepairMonitorNow
        }
        else {
            $script:initializingAutoRepair = $true
            try { $AutoRepairCheckBox.IsChecked = $false }
            finally { $script:initializingAutoRepair = $false }
        }
    })

    $AutoRepairCheckBox.Add_Unchecked({
        if ($script:initializingAutoRepair) { return }

        [void](Set-AutoRepairEnabled $false)
        $AutoRepairCheckNowButton.IsEnabled = $false
        $AutoRepairTriggerText.Visibility = [System.Windows.Visibility]::Collapsed
        $script:autoRepairWatchInitialized = $false

        if ($script:autoRepairTriggerTimer) {
            try { $script:autoRepairTriggerTimer.Stop() } catch {}
        }

        Update-AutoRepairStatus
    })

    $AutoRepairCheckNowButton.Add_Click({
        if (
            -not $script:repairActive -and
            (Refresh-AutoRepairAvailability -Force) -and
            [bool]$AutoRepairCheckBox.IsChecked
        ) {
            $AutoRepairStatusText.Text = 'Enabled · checking local Tailscale…'
            $AutoRepairStatusText.Foreground = Get-Brush 'Blue'
            Initialize-AutoRepairLocalWatch
            Invoke-AutoRepairMonitorNow
        }
    })

    function Start-ResidentRuntime {
        if ($script:residentRuntimeStarted) {
            return
        }

        $script:residentRuntimeStarted = $true
        Reset-Ui -SkipEngineCheck

        $stateTimer.Start()
        $script:autoRepairLocalWatchTimer.Start()
        $script:autoRepairUiTimer.Start()
        $freshnessTimer.Start()
        $activationTimer.Start()
    }

    function Queue-StartupInitialization {
        if ($script:startupInitializationDone) {
            return
        }

        $script:startupInitializationDone = $true

        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{
                Initialize-AutoRepairUi
                Register-ReliabilityWatchers
                Initialize-AutoRepairLocalWatch
                Show-UpdateResult
                [void](Get-ActiveOperationLock -RecoverStale)

                if (-not (Attach-To-RunningRepair)) {
                    [void](Refresh-EngineCheck)
                }
            }
        ) | Out-Null
    }

    $window.Add_Loaded({
        Start-ResidentRuntime
        $window.Opacity = 1
    })

    $window.Add_ContentRendered({
        Queue-StartupInitialization
    })

    $window.Add_StateChanged({
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            $window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{
                    Move-ToTray
                }
            ) | Out-Null
        }
    })

    $window.Add_Closing({
        param($sender, $eventArgs)

        if (-not $script:allowFullExit) {
            $eventArgs.Cancel = $true

            $window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{
                    Move-ToTray
                }
            ) | Out-Null
        }
    })

    $window.Add_Closed({
        $script:allowFullExit = $true
        try { Unregister-ReliabilityWatchers } catch {}
        try { $stateTimer.Stop() } catch {}
        try {
            if ($script:autoRepairUiTimer) {
                $script:autoRepairUiTimer.Stop()
            }
        } catch {}
        try {
            if ($script:autoRepairLocalWatchTimer) {
                $script:autoRepairLocalWatchTimer.Stop()
            }
        } catch {}
        try {
            if ($script:autoRepairTriggerTimer) {
                $script:autoRepairTriggerTimer.Stop()
            }
        } catch {}
        try { Stop-AdvancedDiagnostics } catch {}
        try { Remove-Item -LiteralPath $AdvancedDiagnosticsStateFile -Force -ErrorAction SilentlyContinue } catch {}
        try {
            if ($script:updateCheckTimer) {
                $script:updateCheckTimer.Stop()
            }
        } catch {}
        try {
            if ($script:updateWebClient) {
                $script:updateWebClient.CancelAsync()
                $script:updateWebClient.Dispose()
            }
        } catch {}
        try {
            if ($script:updateDownloadTimer) {
                $script:updateDownloadTimer.Stop()
            }
        } catch {}
        try {
            if ($script:updateDownloadClient) {
                $script:updateDownloadClient.CancelAsync()
                $script:updateDownloadClient.Dispose()
            }
        } catch {}
        try { $freshnessTimer.Stop() } catch {}
        try { $activationTimer.Stop() } catch {}
        try {
            if ($script:notifyIcon) {
                $script:notifyIcon.Visible = $false
                $script:notifyIcon.Dispose()
            }
        } catch {}
        try {
            if ($script:trayMenu) {
                $script:trayMenu.Dispose()
            }
        } catch {}
        try { $activateEvent.Dispose() } catch {}
        try { $instanceMutex.ReleaseMutex() } catch {}
        try { $instanceMutex.Dispose() } catch {}
    })

    # --------------------------------------------------------------
    # Init
    # --------------------------------------------------------------
    $StartWithWindowsCheckBox.IsChecked = Test-StartWithWindows
    $script:initializingUpdateChannel = $true
    try {
        $script:updateChannel = Get-UpdateChannel
        $EarlyAccessUpdatesCheckBox.IsChecked = ($script:updateChannel -ceq 'preview')
    }
    finally { $script:initializingUpdateChannel = $false }

    Initialize-TrayIcon
    Update-TrayStatus $null
    Update-TrayFreshness
    Reset-Ui -SkipEngineCheck

    $wpfApp = [System.Windows.Application]::Current
    $ownsWpfApp = $false

    if (-not $wpfApp) {
        $wpfApp = New-Object System.Windows.Application
        $ownsWpfApp = $true
    }

    $wpfApp.Add_DispatcherUnhandledException({
        param($sender, $eventArgs)

        try {
            # UI-event failures should not kill the native shell or the
            # protected repair task. Surface a controlled recovery state.
            $script:repairActive = $false

            Set-Badge $HeroBadge $HeroBadgeText 'ATTENTION' 'warning'
            $HeroTitle.Text = 'Quick Repair recovered from a UI error'
            $HeroDetail.Text = 'The repair engine was not affected. You can safely try the check again.'
            Set-ActionButton 'Try Again' 'repair' $true

            Add-ReliabilityEvent 'A UI event error was contained without stopping Quick Repair.'
            Update-Diagnostics $script:lastData

            $eventArgs.Handled = $true
        }
        catch {
            $eventArgs.Handled = $false
        }
    })

    $wpfApp.Add_SessionEnding({
        param($sender, $eventArgs)

        # Windows logoff/shutdown must always be allowed to close the resident app.
        $script:allowFullExit = $true
    })

    $wpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
    $wpfApp.MainWindow = $window

    if ($StartInTray) {
        # Application.Run(window) makes the WPF main window visible before
        # Loaded can move it to the tray. Start resident state against the
        # hidden Window and enter the dispatcher without showing that Window.
        $window.ShowInTaskbar = $false
        $script:hiddenToTray = $true
        Start-ResidentRuntime
        Queue-StartupInitialization
    }

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
}
catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms

        $detail = [string]$_.Exception.Message

        if ($detail.Length -gt 220) {
            $detail = $detail.Substring(0, 220).TrimEnd() + '…'
        }

        $message = @(
            'Tailscale Quick Repair could not load its interface.'
            ''
            'The repair backend and Tailscale installation were not changed.'
            ''
            'Try reopening Quick Repair. If the problem continues, run Repair installation or the latest rollback package.'
        ) -join [Environment]::NewLine

        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $message += [Environment]::NewLine +
                [Environment]::NewLine +
                "Technical detail: $detail"
        }

        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Tailscale Quick Repair',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {}

    try { $activateEvent.Dispose() } catch {}
    try { $instanceMutex.ReleaseMutex() } catch {}
    try { $instanceMutex.Dispose() } catch {}
}
