param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$script:text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Old,[string]$New){
    if([regex]::Matches($script:text,[regex]::Escape($Old)).Count -ne 1){
        throw ('Passive startup anchor missing or duplicated: '+$Old.Substring(0,[Math]::Min(100,$Old.Length)))
    }
    $script:text=$script:text.Replace($Old,$New)
}

$functions=@'
    $script:passiveStartupWork=$null
    $script:passiveStartupTimer=$null
    $script:passiveStartupStarted=$false
    $script:passiveStartupManual=$false
    $script:passiveStartupGeneration=0
    $script:passiveStartupTicket=-1

    function Test-PassiveStartupPresentationAllowed {
        param([switch]$AllowFullCheck)
        # Startup results never replace a newer full check. A user-requested
        # local refresh may update only the local presentation, but still has
        # no repair, remote-probe or shared-lock authority.
        if ($global:TqrUiShutdownRequested -or $script:allowFullExit -or $script:repairActive -or
            $script:updateDownloadActive -or $script:pendingProtectedUpdateStarted) { return $false }
        if ($script:lastData -and -not $AllowFullCheck) { return $false }
        return $true
    }

    function Get-PassiveStartupConfigState {
        param([string]$ConfigPath,[bool]$TargetConfigured)
        try {
            if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return 'Missing' }
            if ($TargetConfigured) { return 'Configured' }
            return 'Invalid'
        } catch { return 'Unknown' }
    }

    function Test-PassiveStartupAppFiles {
        foreach($path in @($OperationsLibraryPath,$UpdaterHostPath,$SetupHostPath,$AdvancedDiagnosticsPath,$NativeHostPath)){
            try {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
                $item=Get-Item -LiteralPath $path -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) { return $false }
            } catch { return $false }
        }
        return $true
    }

    function Update-PassiveTrayStatus {
        param($Decision)
        if (-not $Decision -or -not $script:trayStatusItem) { return }
        if (-not (Test-PassiveStartupPresentationAllowed)) { return }
        try {
            $status='Local status unknown'
            $color=[System.Drawing.Color]::FromArgb(70,80,92)
            switch([string]$Decision.Status){
                'Healthy' {$status='Local healthy';$color=[System.Drawing.Color]::FromArgb(24,128,88)}
                'Attention' {$status='Local attention';$color=[System.Drawing.Color]::FromArgb(175,120,20)}
                'Paused' {$status='Local disconnected';$color=[System.Drawing.Color]::FromArgb(120,126,138)}
                'Waiting' {$status='Local check pending';$color=[System.Drawing.Color]::FromArgb(70,80,92)}
            }
            $script:trayStatusItem.Text=$status
            $script:trayStatusItem.ForeColor=$color
            if($script:notifyIcon){$script:notifyIcon.Text='Quick Repair - '+$status}
            Update-TrayFreshness
        } catch {}
    }

    function Apply-PassiveStartupPresentation {
        param($Decision,$Health,$EngineCheck,[switch]$Manual)
        if (-not $Decision -or -not (Test-PassiveStartupPresentationAllowed -AllowFullCheck:$Manual)) { return }
        try {
            if($Health){
                $LocalAppValue.Text=[string]$Health.Client
                $LocalServiceValue.Text=[string]$Health.Service
                $LocalBackendValue.Text=[string]$Health.Backend
                $appState=if([string]$Health.Client -eq 'Running'){'good'}elseif([string]$Health.Client -eq 'Closed'){'warn'}else{'idle'}
                $serviceState=if([string]$Health.Service -eq 'Running'){'good'}elseif([string]$Health.Service -eq 'Stopped'){'warn'}elseif([string]$Health.Service -eq 'Missing'){'bad'}else{'idle'}
                $backendState=if([string]$Health.Backend -eq 'Running'){'good'}elseif([string]$Health.Backend -in @('NeedsLogin','NeedsMachineAuth','InUseOtherUser','Stopped')){'warn'}elseif([string]$Health.Backend -eq 'Starting'){'active'}else{'idle'}
                Set-Step $AppDot $AppStep $appState
                Set-Step $ServiceDot $ServiceStep $serviceState
                Set-Step $BackendDot $BackendStep $backendState
            }

            switch([string]$Decision.Status){
                'Healthy' { Set-Badge $LocalBadge $LocalBadgeText 'LOCAL HEALTHY' 'success' }
                'Attention' { Set-Badge $LocalBadge $LocalBadgeText 'LOCAL ATTENTION' 'warning' }
                'Paused' { Set-Badge $LocalBadge $LocalBadgeText 'DISCONNECTED' 'idle' }
                default { Set-Badge $LocalBadge $LocalBadgeText 'LOCAL CHECK' 'idle' }
            }

            if([string]$Decision.Reason -eq 'quick_repair_maintenance' -and $EngineCheck -and
                (-not $Manual -or -not $script:lastData)){
                Show-EngineIssue $EngineCheck
            }

            # A manual refresh after a completed remote check must not replace
            # the tray's newer overall state; it updates only local UI.
            if(-not $Manual -or -not $script:lastData){Update-PassiveTrayStatus $Decision}
        } catch {}
    }

    function Stop-PassiveStartupHealth {
        $script:passiveStartupGeneration++
        if($script:passiveStartupTimer){$script:passiveStartupTimer.Stop()}
        if($script:passiveStartupWork){$script:passiveStartupWork.Cancel()}
    }

    function Get-PassiveStartupCollectionScript {
        # Reuse only these trusted installed function bodies, in an isolated
        # runspace. No WPF object, target value or raw process output is passed.
        $header='param($ConfigPath,$TargetConfigured,$OperationsLibraryPath,$UpdaterHostPath,$SetupHostPath,$AdvancedDiagnosticsPath,$NativeHostPath,$RepairInstallPath,$BackendPath,$BackendLauncherPath,$UiLauncherPath,$StartMenuShortcutPath,$TaskName)'
        $definitions=@(
            ('function Test-RepairEngine {'+${function:Test-RepairEngine}.ToString()+'}'),
            ('function Test-PassiveStartupAppFiles {'+${function:Test-PassiveStartupAppFiles}.ToString()+'}'),
            ('function Get-PassiveStartupConfigState {'+${function:Get-PassiveStartupConfigState}.ToString()+'}')
        ) -join "`n"
        $body={
            $ErrorActionPreference='Stop'
            $ProgressPreference='SilentlyContinue'
            $engine=Test-RepairEngine
            $machine=New-Object Tqr.WindowsAutoRepairMachine
            $health=$machine.Observe()
            $observation=New-Object Tqr.PassiveStartupObservation
            $observation.AppFilesReady=[bool](Test-PassiveStartupAppFiles)
            $observation.EngineReady=[bool]$engine.Healthy
            $observation.Config=Get-PassiveStartupConfigState $ConfigPath $TargetConfigured
            if($health){
                $observation.Service=[string]$health.Service
                $observation.Startup=[string]$health.Startup
                $observation.Client=[string]$health.Client
                $observation.Backend=[string]$health.Backend
                $observation.LocalIp=[string]$machine.LastLocalIp
                $observation.Version=[string]$machine.LastVersion
            }
            $sample=New-Object Tqr.PassiveStartupSample
            $sample.Observation=$observation
            $sample.EngineRepairable=[bool]$engine.Repairable
            return $sample
        }
        return $header+"`n"+$definitions+"`n"+$body.ToString()
    }

    function Receive-PassiveStartupHealth {
        if(-not $script:passiveStartupWork){return}
        $manual=[bool]$script:passiveStartupManual
        if(-not (Test-PassiveStartupPresentationAllowed -AllowFullCheck:$manual) -or
            $script:passiveStartupTicket -ne $script:passiveStartupGeneration){
            Stop-PassiveStartupHealth
            return
        }
        $state=$script:passiveStartupWork.State
        if($state -eq 'Pending'){return}
        $script:passiveStartupTimer.Stop()
        try {
            $sample=$script:passiveStartupWork.ReadSample()
            if($state -ne 'Completed' -or -not $sample){return}
            if(-not (Test-PassiveStartupPresentationAllowed -AllowFullCheck:$manual) -or
                $script:passiveStartupTicket -ne $script:passiveStartupGeneration){return}
            $observation=$sample.Observation
            $decision=[Tqr.PassiveStartupHealth]::Evaluate($observation)
            $engine=[pscustomobject]@{Healthy=$observation.EngineReady;Repairable=$sample.EngineRepairable;Message='Quick Repair installation could not be verified.'}
            $script:engineHealthy=[bool]$observation.EngineReady
            $script:lastEngineCheckAt=Get-Date
            Apply-PassiveStartupPresentation $decision $observation $engine -Manual:$manual
            if(-not $manual -and -not [string]::IsNullOrWhiteSpace([string]$decision.NotificationCode)){
                [void](Request-SmartNotification ([string]$decision.NotificationCode) ([DateTime]::UtcNow.ToString('o')))
            }
        } finally {
            # Dispose requests cancellation but never joins the worker on WPF.
            $script:passiveStartupWork.Dispose()
            if($manual){
                $script:passiveStartupManual=$false
                $AutoRepairCheckNowButton.Content='Check local health now'
                $AutoRepairCheckNowButton.IsEnabled=$true
            }
        }
    }

    function Invoke-PassiveStartupHealth {
        param([switch]$Refresh)
        if($Refresh){
            if(-not (Test-PassiveStartupPresentationAllowed -AllowFullCheck)){return}
            Stop-PassiveStartupHealth
            $script:passiveStartupStarted=$false
            $script:passiveStartupManual=$true
            $AutoRepairCheckNowButton.Content='Checking local health…'
            $AutoRepairCheckNowButton.IsEnabled=$false
        }elseif($script:passiveStartupStarted -or -not (Test-PassiveStartupPresentationAllowed)){
            return
        }else{
            $script:passiveStartupManual=$false
        }

        $script:passiveStartupStarted=$true
        try {
            Initialize-OperationGate
            $inputs=@{
                ConfigPath=$ConfigPath;TargetConfigured=(-not [string]::IsNullOrWhiteSpace([string]$Peer))
                OperationsLibraryPath=$OperationsLibraryPath;UpdaterHostPath=$UpdaterHostPath
                SetupHostPath=$SetupHostPath;AdvancedDiagnosticsPath=$AdvancedDiagnosticsPath
                NativeHostPath=$NativeHostPath;RepairInstallPath=$RepairInstallPath
                BackendPath=$BackendPath;BackendLauncherPath=$BackendLauncherPath
                UiLauncherPath=$UiLauncherPath;StartMenuShortcutPath=$StartMenuShortcutPath;TaskName=$TaskName
            }
            $script:passiveStartupTicket=$script:passiveStartupGeneration
            $script:passiveStartupWork=New-Object Tqr.PassiveStartupWork 8000
            if(-not $script:passiveStartupWork.TryStart((Get-PassiveStartupCollectionScript),$inputs)){
                $script:passiveStartupStarted=$false
                if($Refresh){
                    $script:passiveStartupManual=$false
                    $AutoRepairCheckNowButton.Content='Check local health now'
                    $AutoRepairCheckNowButton.IsEnabled=$true
                }
                return
            }
            $script:passiveStartupTimer=New-Object System.Windows.Threading.DispatcherTimer
            $script:passiveStartupTimer.Interval=[TimeSpan]::FromMilliseconds(100)
            $script:passiveStartupTimer.Add_Tick({Receive-PassiveStartupHealth})
            $script:passiveStartupTimer.Start()
        } catch {
            $script:passiveStartupStarted=$false
            if($Refresh){
                $script:passiveStartupManual=$false
                $AutoRepairCheckNowButton.Content='Check local health now'
                $AutoRepairCheckNowButton.IsEnabled=$true
            }
            Stop-PassiveStartupHealth
        }
    }


'@

Replace-One 'AutomationProperties.Name="Run auto-repair check now"' 'AutomationProperties.Name="Refresh local Tailscale status"'
Replace-One 'AutomationProperties.HelpText="Runs the local Auto Repair health check immediately."' 'AutomationProperties.HelpText="Refreshes local Tailscale health without checking a remote device or making repairs."'

$legacyButtonGatePattern='(?m)^[ \t]*\$AutoRepairCheckNowButton\.IsEnabled = \$(?:true|false)\r?\n'
$legacyButtonGates=[regex]::Matches($script:text,$legacyButtonGatePattern)
if($legacyButtonGates.Count -ne 5){throw 'Manual local-refresh legacy button gate count changed.'}
$script:text=[regex]::Replace($script:text,$legacyButtonGatePattern,'')

$availabilityPattern='(?ms)^[ \t]*\$AutoRepairCheckNowButton\.IsEnabled = \(\r?\n[ \t]*\$script:autoRepairAvailable -and\r?\n[ \t]*\[bool\]\$AutoRepairCheckBox\.IsChecked\r?\n[ \t]*\)\r?\n'
$availabilityMatches=[regex]::Matches($script:text,$availabilityPattern)
if($availabilityMatches.Count -ne 1){throw 'Manual local-refresh availability gate changed.'}
$script:text=[regex]::Replace($script:text,$availabilityPattern,'')

$manualClickPattern='(?ms)^    \$AutoRepairCheckNowButton\.Add_Click\(\{\r?\n.*?^    \}\)\r?\n(?=\r?\n    function Start-ResidentRuntime)'
$manualClickMatches=[regex]::Matches($script:text,$manualClickPattern)
if($manualClickMatches.Count -ne 1){throw 'Manual local-refresh click boundary changed.'}
$manualClickReplacement=@'
    $AutoRepairCheckNowButton.Add_Click({
        [void](Invoke-PassiveStartupHealth -Refresh)
    })
'@
$script:text=[regex]::Replace($script:text,$manualClickPattern,$manualClickReplacement)
Replace-One '    function Start-ResidentRuntime {' ($functions+'    function Start-ResidentRuntime {')
Replace-One @'
                if (-not (Attach-To-RunningRepair)) {
                    [void](Refresh-EngineCheck)
                }
'@ @'
                if (-not (Attach-To-RunningRepair)) {
                    [void](Invoke-PassiveStartupHealth)
                }
'@

# Invalidate on the operation entry, not just a periodic observation of flags.
# A start/fail/reset cycle between timer ticks must never revive an old sample.
foreach($name in @('Start-Repair','Start-UpdateInstall','Invoke-InstallationRepair')){
    Replace-One ('    function '+$name+' {') ('    function '+$name+" {`n        Stop-PassiveStartupHealth")
}
Replace-One @"
    function Apply-State {
        param(`$Data)
"@ @"
    function Apply-State {
        param(`$Data)
        Stop-PassiveStartupHealth
"@
Replace-One @"
    function Reset-Ui {
        param([switch]`$SkipEngineCheck)
"@ @"
    function Reset-Ui {
        param([switch]`$SkipEngineCheck)
        Stop-PassiveStartupHealth
"@
# Window close-to-tray is not shutdown. Actual exit/session end cancels work.
Replace-One @'
    $window.Add_Closed({
        $script:allowFullExit = $true
'@ @'
    $window.Add_Closed({
        Stop-PassiveStartupHealth
        $script:allowFullExit = $true
'@
Replace-One @'
    $wpfApp.Add_SessionEnding({
        param($sender, $eventArgs)
'@ @'
    $wpfApp.Add_SessionEnding({
        param($sender, $eventArgs)
        Stop-PassiveStartupHealth
'@

foreach($required in @(
    'function Invoke-PassiveStartupHealth',
    'function Update-PassiveTrayStatus',
    '[Tqr.PassiveStartupHealth]::Evaluate',
    'New-Object Tqr.PassiveStartupWork',
    'function Receive-PassiveStartupHealth',
    'New-Object Tqr.WindowsAutoRepairMachine',
    'Request-SmartNotification',
    'Invoke-PassiveStartupHealth -Refresh',
    'Refreshes local Tailscale health without checking a remote device or making repairs.'
)){
    if($script:text -notmatch [regex]::Escape($required)){throw ('Passive startup integration missing: '+$required)}
}

[void][scriptblock]::Create($script:text)
[IO.File]::WriteAllText($Path,$script:text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Local-only passive startup health integrated.'