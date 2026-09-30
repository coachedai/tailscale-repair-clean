param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$script:text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Old,[string]$New){
    if([regex]::Matches($script:text,[regex]::Escape($Old)).Count -ne 1){throw ('Diagnostics polish anchor missing or duplicated: '+$Old.Substring(0,[Math]::Min(90,$Old.Length)))}
    $script:text=$script:text.Replace($Old,$New)
}
Replace-One @'
<ScrollViewer x:Name="HistoryPanel" Visibility="Collapsed" MaxHeight="170" Margin="0,16,0,0"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
'@ @'
<ScrollViewer x:Name="HistoryPanel" Visibility="Collapsed" MaxHeight="170" Margin="0,16,0,0"
              VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
              CanContentScroll="False" PanningMode="VerticalOnly" Focusable="True"
              AutomationProperties.Name="Saved activity history"
              AutomationProperties.HelpText="Scroll to read saved events. Home and End move to the start and end.">
    <ScrollViewer.Resources>
        <Style x:Key="HistoryPageButton" TargetType="{x:Type RepeatButton}">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="IsTabStop" Value="False"/>
            <Setter Property="Template">
                <Setter.Value><ControlTemplate TargetType="{x:Type RepeatButton}"><Border Background="Transparent"/></ControlTemplate></Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="HistoryThumb" TargetType="{x:Type Thumb}">
            <Setter Property="MinHeight" Value="28"/>
            <Setter Property="Background" Value="{DynamicResource Faint}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border x:Name="Grip" Margin="3,1" CornerRadius="3" Background="{TemplateBinding Background}"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource Muted}"/></Trigger>
                            <Trigger Property="IsDragging" Value="True"><Setter Property="Background" Value="{DynamicResource Value}"/></Trigger>
                            <DataTrigger Binding="{Binding Source={x:Static SystemParameters.HighContrast}}" Value="True">
                                <Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.WindowTextBrushKey}}"/>
                            </DataTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Width" Value="12"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <!-- Native ScrollViewer may assign a system Background locally.
                             Paint our transparent rail explicitly instead of inheriting it. -->
                        <Border x:Name="HistoryRail" Background="Transparent" SnapsToDevicePixels="True">
                            <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource HistoryPageButton}" Command="{x:Static ScrollBar.PageUpCommand}"/></Track.DecreaseRepeatButton>
                                <Track.Thumb><Thumb Style="{StaticResource HistoryThumb}"/></Track.Thumb>
                                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource HistoryPageButton}" Command="{x:Static ScrollBar.PageDownCommand}"/></Track.IncreaseRepeatButton>
                            </Track>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </ScrollViewer.Resources>
'@
Replace-One @'
                $HistoryPanel.Visibility = [Windows.Visibility]::Visible
                $SessionText.Visibility
'@ @'
                $HistoryPanel.Visibility = [Windows.Visibility]::Visible
                $HistoryPanel.ScrollToTop()
                $SessionText.Visibility
'@
Replace-One @'
                                <ProgressBar
                                    x:Name="AdvancedDiagnosticsProgress"
'@ @'
                                <TextBlock x:Name="AdvancedDiagnosticsDetailText" Margin="0,5,0,0"
                                    FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                                <ProgressBar
                                    x:Name="AdvancedDiagnosticsProgress"
'@
Replace-One "    `$AdvancedDiagnosticsSummary = `$window.FindName('AdvancedDiagnosticsSummary')" @'
    $AdvancedDiagnosticsDetailText=$window.FindName('AdvancedDiagnosticsDetailText')
    $AdvancedDiagnosticsSummary = $window.FindName('AdvancedDiagnosticsSummary')
'@
Replace-One @'
            $AdvancedDiagnosticsSummary.Text = $summary

            $severity = Get-AdvancedValue $Result 'severity'
'@ @'
            $AdvancedDiagnosticsSummary.Text = $summary
            $explanation=Get-AdvancedValue $Result 'detail'
            if($explanation -eq 'Unknown'){$explanation='Results describe this optional run only; no network settings were changed.'}
            $AdvancedDiagnosticsDetailText.Text=$explanation
            $AdvancedDiagnosticsDetailText.ToolTip='DISCO checks discovery. TSMP checks the encrypted tunnel without the remote OS network stack. ICMP and Peer API are independent probes, not tests of your RDP service.'

            $severity = Get-AdvancedValue $Result 'severity'
'@
Replace-One @'
                "Path       $(Get-AdvancedValue $Result 'path')"
                "Discovery  $(Get-AdvancedValue $Result 'disco')"
'@ @'
                "Path       $(Get-AdvancedValue $Result 'path')"
                "Latency    $(Get-AdvancedValue $Result 'latency')"
                "Discovery  $(Get-AdvancedValue $Result 'disco')"
'@
Replace-One '                "Other VPN    $vpnText"' '                "VPN software $vpnText"'
Replace-One '                "Summary: $summary"' @'
                "Summary: $summary"
                "Explanation: $explanation"
                "Network inspection: $(Get-AdvancedValue $Result 'netcheckStatus')"
                "Observed UTC: $(Get-AdvancedValue $Result 'updatedUtc')"
                "Duration seconds: $(Get-AdvancedValue $Result 'durationSeconds')"
'@
Replace-One "            `$AdvancedNetworkText.Text = 'Unavailable'" @'
            $AdvancedDiagnosticsDetailText.Text='The main connection result is unchanged. No network settings were changed.'
            $AdvancedNetworkText.Text = 'Unavailable'
'@
Replace-One '            $AdvancedDiagnosticsProgress.Value = 2' @'
            $AdvancedDiagnosticsDetailText.Text='Optional read-only probes. Each command has a time limit.'
            $AdvancedDiagnosticsProgress.Value = 2
'@
Replace-One '((Get-Date) - $script:advancedDiagnosticsStartedAt).TotalSeconds -gt 25' '((Get-Date) - $script:advancedDiagnosticsStartedAt).TotalSeconds -gt 30'
Replace-One @'
                    $expectedNames = @('Tailscale-Repair-UI.ps1','TailscaleQuickRepairUpdater.exe','TailscaleQuickRepairSetup.exe','TailscaleQuickRepair.Operations.dll')
'@ @'
                    $expectedNames = @('Tailscale-Repair-UI.ps1','TailscaleQuickRepairUpdater.exe','TailscaleQuickRepairSetup.exe','TailscaleQuickRepair.Operations.dll','Advanced-Diagnostics.ps1')
'@
Replace-One "                        `$expectedNames += 'TailscaleQuickRepair.exe','Advanced-Diagnostics.ps1'" "                        `$expectedNames += 'TailscaleQuickRepair.exe'"
[void][scriptblock]::Create($script:text)
[IO.File]::WriteAllText($Path,$script:text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'History scroll theme and Diagnostics 2.0 presentation applied.'
