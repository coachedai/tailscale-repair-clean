param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)]
    [ValidateSet('PublicRelease','Development','PrivateDevelopment')][string]$ValidationProfile
)
$ErrorActionPreference='Stop'
$script:text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Before,[string]$After){
    if([regex]::Matches($script:text,[regex]::Escape($Before)).Count -ne 1){
        throw 'Status presentation anchor is missing or ambiguous.'
    }
    $script:text=$script:text.Replace($Before,$After)
}
$functions=@'
    $script:statusPrivatePreview=__PRIVATE_PREVIEW__
    $script:passiveStartupDetails=$null

    function Get-ObservationCaption {
        param([string]$Prefix,[string]$Stamp,[string]$State,[DateTime]$NowUtc=[DateTime]::UtcNow)
        $suffix=switch($State){
            'unchecked' {'not checked'}
            'running' {'checking'}
            'incomplete' {'incomplete'}
            default {'time unavailable'}
        }
        $detail='No completed observation time is available.'
        if($State -in @('completed','previous')){
            $at=[DateTime]::MinValue
            $valid=[DateTime]::TryParseExact($Stamp,'o',[Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,[ref]$at)
            if($valid -and $at.Kind -eq [DateTimeKind]::Utc -and $at.Year -ge 2020 -and
                $at -le $NowUtc.ToUniversalTime().AddMinutes(2)){
                $suffix=$at.ToLocalTime().ToString('HH:mm:ss',[Globalization.CultureInfo]::CurrentCulture)
                if($State -eq 'previous'){$suffix='previous '+$suffix}
                $detail='Recorded '+$at.ToString("yyyy-MM-dd HH:mm:ss 'UTC'",[Globalization.CultureInfo]::InvariantCulture)+'. Each section shows its own observation, not a live measurement.'
            }elseif($State -eq 'previous'){$suffix='previous; time unavailable'}
        }
        return [pscustomobject]@{Text=($Prefix+' · '+$suffix);ToolTip=$detail}
    }

    function Update-RemoteObservation {
        param($Data)
        $state='unchecked';$stamp=''
        if($Data){
            $state='running'
            if($Data.done -is [bool] -and $Data.done){
                $state=if($script:environmentStale){'previous'}else{'completed'}
                $stamp=[string]$Data.updatedUtc
            }
        }
        $view=Get-ObservationCaption 'Remote' $stamp $state
        $RemoteObservationLabel.Text=$view.Text
        $RemoteObservationLabel.ToolTip=$view.ToolTip
        $DetailRoute.ToolTip=$view.ToolTip
        $DetailLatency.ToolTip=$view.ToolTip
    }

    function Update-AdvancedObservation {
        $state=switch($script:supportDiagnosticsState){
            'checking' {'running'}
            'completed' {if($script:supportDiagnosticsStale){'previous'}else{'completed'}}
            'not_run' {'unchecked'}
            default {'incomplete'}
        }
        $stamp=''
        if($script:supportDiagnosticsData){$stamp=[string]$script:supportDiagnosticsData.updatedUtc}
        $view=Get-ObservationCaption 'Advanced diagnostics' $stamp $state
        $AdvancedObservationLabel.Text=$view.Text
        $AdvancedObservationLabel.ToolTip=$view.ToolTip
    }

    function Set-UncheckedDetails {
        foreach($field in @($DetailClient,$DetailService,$DetailStartup,$DetailBackend,
            $DetailLocalIp,$DetailVersion,$DetailPeerName,$DetailPeerStatus,$DetailRoute,
            $DetailLatency,$DetailConnectionTrend)){
            $field.Text='Not checked'
        }
    }

    function Apply-PassiveStartupDetails {
        param($Health,[switch]$AllowFullCheck)
        if(-not $Health -or -not (Test-PassiveStartupPresentationAllowed -AllowFullCheck:$AllowFullCheck)){return}
        $script:passiveStartupDetails=$Health
        $fields=@{Client=$DetailClient;Service=$DetailService;Startup=$DetailStartup;Backend=$DetailBackend}
        foreach($key in $fields.Keys){
            $value=[string]$Health.$key
            $fields[$key].Text=if([string]::IsNullOrWhiteSpace($value)){'Unknown'}else{$value}
        }
        # These values come from the same bounded local --peers=false observation.
        # Remote/peer fields remain untouched until an explicit connection check.
        $DetailLocalIp.Text=if([string]::IsNullOrWhiteSpace([string]$Health.LocalIp)){'Unavailable'}else{[string]$Health.LocalIp}
        $DetailVersion.Text=if([string]::IsNullOrWhiteSpace([string]$Health.Version)){'Unavailable'}else{[string]$Health.Version}
    }

    function Get-UpdateFailureView {
        param([int]$HttpStatus,[bool]$PrivatePreview)
        $status='Could not check for updates'
        $detail='The update request failed. Check the connection and try again. Nothing was changed.'
        $tone='warn'
        if($HttpStatus -eq 404){
            if($PrivatePreview){
                $status='Online updates unavailable for this preview'
                $detail='This private preview uses an update feed that is not accessible yet. Your installed version has not changed.'
                $tone='muted'
            }else{
                $status='Update feed not found'
                $detail='The selected update feed could not be found. Nothing was changed.'
            }
        }elseif($HttpStatus -in @(401,403)){
            $status='Update request refused'
            $detail='GitHub refused the update request. Try again later. Nothing was changed.'
        }elseif($HttpStatus -eq 429){
            $status='Update request limit reached'
            $detail='Wait before checking again. Your installed version has not changed.'
        }elseif($HttpStatus -ge 500 -and $HttpStatus -le 599){
            $status='Update service unavailable'
            $detail='The update service could not complete the request. Try again later. Nothing was changed.'
        }
        return [pscustomobject]@{Status=$status;Detail=$detail;Tone=$tone}
    }

    function Get-UpdateHttpStatus {
        param([Exception]$Failure)
        try{
            if($Failure){
                $cause=$Failure.GetBaseException()
                if($cause -is [Net.WebException] -and $cause.Response -is [Net.HttpWebResponse]){
                    return [int]$cause.Response.StatusCode
                }
            }
        }catch{}
        return 0
    }

'@
$privateLiteral=if($ValidationProfile -ceq 'PrivateDevelopment'){'$true'}else{'$false'}
$functions=$functions.Replace('__PRIVATE_PREVIEW__',$privateLiteral)
Replace-One '    function Update-Diagnostics {' ($functions+'    function Update-Diagnostics {')
Replace-One 'Text="Remote" FontSize="15"' 'x:Name="RemoteObservationLabel" Text="Remote · not checked" TextTrimming="CharacterEllipsis" FontSize="15"'
Replace-One 'Text="Advanced diagnostics"' 'x:Name="AdvancedObservationLabel" Text="Advanced diagnostics · not checked" TextTrimming="CharacterEllipsis"'
Replace-One "    `$DetailClient = `$window.FindName('DetailClient')" @'
    $RemoteObservationLabel=$window.FindName('RemoteObservationLabel')
    $AdvancedObservationLabel=$window.FindName('AdvancedObservationLabel')
    $DetailClient = $window.FindName('DetailClient')
'@
Replace-One @'
    function Update-Diagnostics {
        param($Data)
'@ @'
    function Update-Diagnostics {
        param($Data)
        Update-RemoteObservation $Data
'@
Replace-One @'
            $script:copyDiagnosticsText = ''
            return
'@ @'
            $script:copyDiagnosticsText = ''
            Set-UncheckedDetails
            Apply-PassiveStartupDetails $script:passiveStartupDetails
            return
'@
Replace-One @'
                $LocalBackendValue.Text=[string]$Health.Backend
'@ @'
                $LocalBackendValue.Text=[string]$Health.Backend
                Apply-PassiveStartupDetails $Health -AllowFullCheck:$Manual
'@
Replace-One @'
    function Stop-PassiveStartupHealth {
        $script:passiveStartupGeneration++
'@ @'
    function Stop-PassiveStartupHealth {
        $script:passiveStartupDetails=$null
        $script:passiveStartupGeneration++
'@
Replace-One '    function Update-LastCheckedText {' @'
    function Update-LastCheckedText {
        Update-RemoteObservation $script:lastData
'@
Replace-One "        `$script:supportDiagnosticsStale=`$true" @'
        $script:supportDiagnosticsStale=$true
        Update-AdvancedObservation
'@
Replace-One "        `$script:supportDiagnosticsState=if(`$Result -and `$Result.done -is [bool] -and `$Result.done){'completed'}else{'incomplete'}" @'
        $script:supportDiagnosticsState=if($Result -and $Result.done -is [bool] -and $Result.done){'completed'}else{'incomplete'}
        Update-AdvancedObservation
'@
Replace-One '            $script:advancedDiagnosticsStartedAt = Get-Date' @'
            $script:advancedDiagnosticsStartedAt = Get-Date
            Update-AdvancedObservation
'@
Replace-One @'
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
'@ @'
                        $httpStatus=Get-UpdateHttpStatus $script:updateCheckTask.Exception
                        $failureView=Get-UpdateFailureView $httpStatus $script:statusPrivatePreview
                        Complete-UpdateCheck `
                            -Status $failureView.Status `
                            -Detail $failureView.Detail `
                            -Tone $failureView.Tone
'@

# Keep the summary cards as the primary live state. Expanded Details should
# add technical/context information rather than repeat the same values.
Replace-One 'x:Name="RemoteStatusValue" Text="—"' 'x:Name="RemoteStatusValue" Text="Not checked"'
Replace-One 'x:Name="RemoteRouteValue" Text="—"' 'x:Name="RemoteRouteValue" Text="Not checked"'
Replace-One 'x:Name="RemoteLatencyValue" Text="—"' 'x:Name="RemoteLatencyValue" Text="Not checked"'
Replace-One @'
        $RemoteStatusValue.Text = '—'
        $RemoteRouteValue.Text = '—'
        $RemoteLatencyValue.Text = '—'
'@ @'
        $RemoteStatusValue.Text = 'Not checked'
        $RemoteRouteValue.Text = 'Not checked'
        $RemoteLatencyValue.Text = 'Not checked'
'@

$detailsPattern='(?s)                            <!-- Connection \+ session -->.*?(?=                            <!-- Automation \+ maintenance -->)'
$detailsMatches=[regex]::Matches($script:text,$detailsPattern)
if($detailsMatches.Count -ne 1){throw 'Compact Details block is missing or ambiguous.'}
$detailsCurrent=$detailsMatches[0].Value
foreach($required in @('RemoteObservationLabel','ChangeTargetButton','DetailClient','DetailService','DetailBackend',
    'DetailStartup','DetailLocalIp','DetailVersion','DetailPeerName','DetailPeerIp','DetailPeerStatus',
    'DetailRoute','DetailLatency','DetailConnectionTrend','ActivityDescriptionText','HistoryButton',
    'CopyButton','SessionText','HistoryPanel','HistoryText')){
    if(-not $detailsCurrent.Contains(('x:Name="'+$required+'"'))){throw ('Compact Details dependency missing: '+$required)}
}
$detailsReplacement=@'
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
                                    <TextBlock Text="Local details" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                    <Grid Margin="0,12,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="110"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                            <RowDefinition Height="27"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Text="Startup" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="1" Text="Tailscale IP" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="2" Text="Version" Foreground="{StaticResource Faint}"/>
                                        <TextBlock x:Name="DetailStartup" Grid.Row="0" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailLocalIp" Grid.Row="1" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                        <TextBlock x:Name="DetailVersion" Grid.Row="2" Grid.Column="1" Text="—" Foreground="{StaticResource Value}"/>
                                    </Grid>
                                    <StackPanel x:Name="DetailDuplicateLocalSummary" Visibility="Collapsed">
                                        <TextBlock x:Name="DetailClient" Text="—"/>
                                        <TextBlock x:Name="DetailService" Text="—"/>
                                        <TextBlock x:Name="DetailBackend" Text="—"/>
                                    </StackPanel>
                                </StackPanel>

                                <StackPanel Grid.Column="2">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock x:Name="RemoteObservationLabel" Text="Remote · not checked"
                                                   TextTrimming="CharacterEllipsis" FontSize="15"
                                                   FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                        <Button x:Name="ChangeTargetButton" Grid.Column="1"
                                                Style="{StaticResource GhostButtonStyle}"
                                                AutomationProperties.Name="Change target device"
                                                AutomationProperties.HelpText="Change the Tailscale target used for remote checks."
                                                Content="Change"/>
                                    </Grid>
                                    <Grid Margin="0,12,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="92"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto" MinHeight="27"/>
                                            <RowDefinition Height="Auto" MinHeight="27"/>
                                            <RowDefinition Height="Auto" MinHeight="27"/>
                                        </Grid.RowDefinitions>
                                        <TextBlock Grid.Row="0" Text="Device" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="1" Text="Peer IP" Foreground="{StaticResource Faint}"/>
                                        <TextBlock Grid.Row="2" Text="Recent" Foreground="{StaticResource Faint}"/>
                                        <TextBlock x:Name="DetailPeerName" Grid.Row="0" Grid.Column="1"
                                                   Text="—" Foreground="{StaticResource Value}" TextWrapping="Wrap"/>
                                        <TextBlock x:Name="DetailPeerIp" Grid.Row="1" Grid.Column="1"
                                                   Text="—" Foreground="{StaticResource Value}" TextWrapping="Wrap"/>
                                        <TextBlock x:Name="DetailConnectionTrend" Grid.Row="2" Grid.Column="1"
                                                   Text="—" Foreground="{StaticResource Value}"
                                                   TextWrapping="Wrap"/>
                                    </Grid>
                                    <StackPanel x:Name="DetailDuplicateRemoteSummary" Visibility="Collapsed">
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
                                        <StackPanel>
                                            <TextBlock Text="Activity" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                                            <TextBlock x:Name="ActivityDescriptionText" Text="Changes and repairs this session."
                                                       Margin="0,4,0,0" FontSize="11"
                                                       Foreground="{StaticResource Faint}" TextWrapping="Wrap"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                                            <Button x:Name="HistoryButton" Style="{StaticResource GhostButtonStyle}"
                                                    Content="History" Margin="0,0,10,0"
                                                    AutomationProperties.Name="Show recent local history"/>
                                            <Button x:Name="CopyButton" Style="{StaticResource GhostButtonStyle}" Content="Copy"/>
                                        </StackPanel>
                                    </Grid>

                                    <TextBlock x:Name="SessionText" Margin="0,12,0,0" FontSize="12" LineHeight="20"
                                               Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                                               Text="No activity yet."/>
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
                                                    <Setter.Value>
                                                        <ControlTemplate TargetType="{x:Type RepeatButton}">
                                                            <Border Background="Transparent"/>
                                                        </ControlTemplate>
                                                    </Setter.Value>
                                                </Setter>
                                            </Style>
                                            <Style x:Key="HistoryThumb" TargetType="{x:Type Thumb}">
                                                <Setter Property="MinHeight" Value="28"/>
                                                <Setter Property="Background" Value="{DynamicResource Faint}"/>
                                                <Setter Property="Template">
                                                    <Setter.Value>
                                                        <ControlTemplate TargetType="{x:Type Thumb}">
                                                            <Border x:Name="Grip" Margin="3,1" CornerRadius="3"
                                                                    Background="{TemplateBinding Background}"/>
                                                            <ControlTemplate.Triggers>
                                                                <Trigger Property="IsMouseOver" Value="True">
                                                                    <Setter Property="Background" Value="{DynamicResource Muted}"/>
                                                                </Trigger>
                                                                <Trigger Property="IsDragging" Value="True">
                                                                    <Setter Property="Background" Value="{DynamicResource Value}"/>
                                                                </Trigger>
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
                                                            <Border x:Name="HistoryRail" Background="Transparent" SnapsToDevicePixels="True">
                                                                <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
                                                                    <Track.DecreaseRepeatButton>
                                                                        <RepeatButton Style="{StaticResource HistoryPageButton}"
                                                                                      Command="{x:Static ScrollBar.PageUpCommand}"/>
                                                                    </Track.DecreaseRepeatButton>
                                                                    <Track.Thumb><Thumb Style="{StaticResource HistoryThumb}"/></Track.Thumb>
                                                                    <Track.IncreaseRepeatButton>
                                                                        <RepeatButton Style="{StaticResource HistoryPageButton}"
                                                                                      Command="{x:Static ScrollBar.PageDownCommand}"/>
                                                                    </Track.IncreaseRepeatButton>
                                                                </Track>
                                                            </Border>
                                                        </ControlTemplate>
                                                    </Setter.Value>
                                                </Setter>
                                            </Style>
                                        </ScrollViewer.Resources>
                                        <TextBlock x:Name="HistoryText" FontSize="12" LineHeight="20" TextWrapping="Wrap"
                                                   Foreground="{StaticResource Muted}" Text="No saved activity yet."/>
                                    </ScrollViewer>
                                </StackPanel>
                            </Grid>

'@
$start=$detailsMatches[0].Index
$script:text=$script:text.Substring(0,$start)+$detailsReplacement+$script:text.Substring($start+$detailsMatches[0].Length)

[void][scriptblock]::Create($script:text)
[IO.File]::WriteAllText($Path,$script:text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Local detail consistency, separate observation times and typed update errors applied.'