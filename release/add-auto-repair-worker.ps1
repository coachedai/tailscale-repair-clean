param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-Function([string]$Name,[string]$Body) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($script:text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Final UI does not parse before automatic worker integration.'}
    $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
    if($nodes.Count -ne 1){throw "Expected one $Name definition."}
    $n=$nodes[0];$script:text=$script:text.Remove($n.Extent.StartOffset,$n.Extent.EndOffset-$n.Extent.StartOffset).Insert($n.Extent.StartOffset,$Body)
}
Replace-Function 'Get-AutoRepairEnabled' @'
function Get-AutoRepairEnabled {
    try {
        Initialize-OperationGate
        return ([Tqr.AutoRepairPolicyStore]::ReadEnabled($StateDir) -eq $true)
    } catch { return $false }
}
'@
Replace-Function 'Set-AutoRepairEnabled' @'
function Set-AutoRepairEnabled {
    param([bool]$Enabled)
    try {
        Initialize-OperationGate
        return [Tqr.AutoRepairPolicyStore]::SetEnabled($StateDir,$Enabled,[DateTime]::UtcNow)
    } catch { return $false }
}
'@
Replace-Function 'Invoke-AutoRepairMonitorNow' @'
function Invoke-AutoRepairMonitorNow {
    $scheduler=$null;$folder=$null;$task=$null;$definition=$null;$principal=$null;$actions=$null;$action=$null;$running=$null
    try {
        Initialize-OperationGate
        if([Tqr.AutoRepairPolicyStore]::ReadEnabled($StateDir) -ne $true){return $false}
        # Schedule the existing protected monitor, never a user-level worker that
        # then invokes the general peer-repair task. No elevation is requested here.
        $scheduler=New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect();$folder=$scheduler.GetFolder('\');$task=$folder.GetTask($AutoRepairTaskName)
        if(-not $task -or -not $task.Enabled){return $false}
        $definition=$task.Definition;$principal=$definition.Principal
        $me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $identity=[string]$principal.UserId
        $sid=if($identity -match '^S-1-'){$identity}else{([Security.Principal.NTAccount]::new($identity)).Translate([Security.Principal.SecurityIdentifier]).Value}
        if($sid -cne $me -or [int]$principal.LogonType -ne 3 -or [int]$principal.RunLevel -ne 1){return $false}
        $actions=$definition.Actions
        if([int]$actions.Count -ne 1){return $false}
        $action=$actions.Item(1)
        $launcher=Join-Path $env:ProgramData 'TailscaleQuickRepair\Launch-Auto-Repair-Monitor.vbs'
        $wscript=Join-Path $env:SystemRoot 'System32\wscript.exe'
        [Tqr.AutoRepairRecords]::CheckPath($launcher)
        if(-not (Test-Path -LiteralPath $launcher -PathType Leaf) -or [int]$action.Type -ne 0 -or
            [string]$action.Path -ine $wscript -or [string]$action.Arguments -cne ('"'+$launcher+'"') -or
            [string]$action.WorkingDirectory -ine (Split-Path -Parent $launcher)){return $false}
        if([Tqr.AutoRepairPolicyStore]::ReadEnabled($StateDir) -ne $true){return $false}
        $running=$task.Run($null)
        return ($null -ne $running)
    } catch { return $false }
    finally {
        foreach($item in @($running,$action,$actions,$principal,$definition,$task,$folder,$scheduler)){
            if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}
        }
    }
}
'@
Replace-Function 'Update-AutoRepairStatus' @'
function Update-AutoRepairStatus {
    try {
        Initialize-OperationGate
        $AutoRepairLastRepairText.Visibility=[Windows.Visibility]::Collapsed
        $AutoRepairTriggerText.Visibility=[Windows.Visibility]::Collapsed
        $enabled=[Tqr.AutoRepairPolicyStore]::ReadEnabled($StateDir)
        if($null -eq $enabled){
            $AutoRepairStatusText.Text='Settings unavailable - nothing changed'
            $AutoRepairStatusText.Foreground=Get-Brush 'Amber';return
        }
        if(-not $enabled){$AutoRepairStatusText.Text='Off';$AutoRepairStatusText.Foreground=Get-Brush 'Faint';return}
        if(-not (Refresh-AutoRepairAvailability)){
            $AutoRepairStatusText.Text='Background monitor unavailable'
            $AutoRepairStatusText.Foreground=Get-Brush 'Amber';return
        }
        $AutoRepairTriggerText.Visibility=[Windows.Visibility]::Visible
        $state=[Tqr.AutoRepairRecords]::Current($StateDir)
        if(-not $state){
            $AutoRepairStatusText.Text='Enabled - waiting for a verified local check'
            $AutoRepairStatusText.Foreground=Get-Brush 'Muted';return
        }
        $stamp=[DateTime]::ParseExact($state.lastCheckedUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $age=[DateTime]::UtcNow-$stamp
        if($age.TotalSeconds -lt -5 -or $age.TotalMinutes -gt 10){
            $AutoRepairStatusText.Text='Enabled - previous observation is not current'
            $AutoRepairStatusText.Foreground=Get-Brush 'Muted';return
        }
        $tone='Muted'
        switch($state.status){
            'healthy' {$label=if($state.recoveryConfirmed){'Local recovery confirmed'}else{'Local Tailscale healthy'};$tone='Green'}
            'cooldown' {$label='Recovery cooldown - '+[int]$state.cooldownRemainingMinutes+' min';$tone='Amber'}
            'manual' {$label='Needs your attention';$tone='Amber'}
            'error' {$label='Recovery not confirmed';$tone='Amber'}
            'disabled' {$label='Automatic repair stopped'}
            'busy' {$label='Waiting for another operation'}
            'repairing' {
                $owner=Get-ActiveOperation
                $label=if($owner){'Local recovery in progress'}else{'Previous recovery did not confirm completion'}
                if(-not $owner){$tone='Amber'}
            }
            default {$label=if($state.reason -eq 'confirming_fault'){'Waiting to confirm a local fault'}else{'Local health not confirmed'}}
        }
        $AutoRepairStatusText.Text=$label;$AutoRepairStatusText.Foreground=Get-Brush $tone
        if($state.status -in @('manual','error','disabled')){
            $why=switch($state.reason){
                'disconnected' {'Tailscale is disconnected; connect it when ready.'}
                'sign_in' {'Sign in to Tailscale before trying again.'}
                'approval' {'This device needs approval in Tailscale.'}
                'other_user' {'Another user is using Tailscale.'}
                'service_disabled' {'The disabled service was left unchanged.'}
                'off' {'Disabled before the next recovery action.'}
                'interrupted' {'The environment changed; no further action was started.'}
                'retry_limit' {'Automatic retry limit reached; check Tailscale manually.'}
                default {'No further automatic action was started.'}
            }
            $AutoRepairLastRepairText.Text=$why
            $AutoRepairLastRepairText.Visibility=[Windows.Visibility]::Visible
        }
    } catch {
        $AutoRepairStatusText.Text='Status unavailable'
        $AutoRepairStatusText.Foreground=Get-Brush 'Amber'
    }
}
'@
# Preserve the established legacy adapter tests while requiring typed worker
# recovery evidence for the integrated worker. Unknown schemas never alert.
$needle='            $status=[string]$state.status'
if(([regex]::Matches($text,[regex]::Escape($needle))).Count -ne 1){throw 'Expected one automatic notification adapter.'}
$text=$text.Replace($needle,@'
            if($state.PSObject.Properties.Name -contains 'schema'){
                if($state.schema -isnot [int] -or $state.schema -notin @(2,3)){return}
                $state=[Tqr.AutoRepairRecords]::Current($StateDir)
                if(-not $state){return}
                if($state.status -eq 'healthy' -and -not $state.recoveryConfirmed){return}
            }
            $status=[string]$state.status
'@)
# A failed preference write must not visually promise that repair is disabled.
$old='        [void](Set-AutoRepairEnabled $false)'
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'Expected one automatic repair disable event.'}
$text=$text.Replace($old,@'
        if(-not (Set-AutoRepairEnabled $false)){
            $script:initializingAutoRepair=$true
            try{$AutoRepairCheckBox.IsChecked=Get-AutoRepairEnabled}finally{$script:initializingAutoRepair=$false}
            $AutoRepairStatusText.Text='Could not save the change - previous preference preserved'
            $AutoRepairStatusText.Foreground=Get-Brush 'Amber'
            return
        }
'@)
Replace-Function 'Test-AutoRepairSmartEnabled' @'
function Test-AutoRepairSmartEnabled {
    try {
        return (-not $script:allowFullExit -and -not $global:TqrUiShutdownRequested -and
            $script:autoRepairAvailable -and [Tqr.AutoRepairPolicyStore]::ReadEnabled($StateDir) -eq $true)
    } catch { return $false }
}
'@
Replace-Function 'Queue-AutoRepairSmartCheck' @'
function Queue-AutoRepairSmartCheck {
    param([string]$Reason,[int]$DelaySeconds=10)
    try {
        Initialize-OperationGate
        if(-not $script:autoEventClock){$script:autoEventClock=[Diagnostics.Stopwatch]::StartNew()}
        if(-not $script:autoEventQueue){$script:autoEventQueue=New-Object Tqr.AutoRepairEventQueue}
        $enabled=Test-AutoRepairSmartEnabled
        $script:autoEventQueue.Signal($script:autoEventClock.ElapsedMilliseconds,$DelaySeconds,$enabled)
        if(-not $script:autoEventQueue.Pending){return}
        if(-not $script:autoRepairTriggerTimer){
            $script:autoRepairTriggerTimer=New-Object Windows.Threading.DispatcherTimer
            $script:autoRepairTriggerTimer.Interval=[TimeSpan]::FromSeconds(1)
            $script:autoRepairTriggerTimer.Add_Tick({ Invoke-AutoRepairEventTick })
        }
        if(-not $script:autoRepairTriggerTimer.IsEnabled){$script:autoRepairTriggerTimer.Start()}
    } catch { }
}
function Invoke-AutoRepairEventTick {
    try {
        $enabled=Test-AutoRepairSmartEnabled
        $busy=$script:repairActive -or $null -ne (Get-ActiveOperation)
        if($script:autoEventQueue.Take($script:autoEventClock.ElapsedMilliseconds,$enabled,$busy)){
            $started=Invoke-AutoRepairMonitorNow
            if($started){
                $AutoRepairStatusText.Text='Local check requested'
                $AutoRepairStatusText.Foreground=Get-Brush 'Muted'
            }
            else {
                $AutoRepairStatusText.Text='Could not start local check'
                $AutoRepairStatusText.Foreground=Get-Brush 'Amber'
            }
        }
    } catch { if($script:autoEventQueue){$script:autoEventQueue.Cancel()} }
    finally {
        if(-not $script:autoEventQueue -or -not $script:autoEventQueue.Pending){
            if($script:autoRepairTriggerTimer){$script:autoRepairTriggerTimer.Stop()}
        }
    }
}
'@
# Reconciliation is secondary and cannot run a local/peer probe. A UI reader must
# never turn a live worker's progress into an interrupted-outcome event.
$historyAnchor='            $view = [Tqr.LocalHistory]::Read($StateDir)'
if(([regex]::Matches($text,[regex]::Escape($historyAnchor))).Count -ne 1){throw 'Expected one History view.'}
$text=$text.Replace($historyAnchor,@'
            $script:autoHistoryReconcileUnavailable = -not [Tqr.AutoRepairBackground]::Reconcile($StateDir,$false)
            $view = [Tqr.LocalHistory]::Read($StateDir)
'@)
# Manual enable/check actions must not remain on a false 'checking' state when
# the verified scheduler route refuses or fails to launch the protected task.
$manualDispatch=@'
            Initialize-AutoRepairLocalWatch
            Invoke-AutoRepairMonitorNow
'@
$manualDispatchFeedback=@'
            Initialize-AutoRepairLocalWatch
            if(-not (Invoke-AutoRepairMonitorNow)){
                $AutoRepairStatusText.Text='Could not start local check'
                $AutoRepairStatusText.Foreground=Get-Brush 'Amber'
            }
'@
if(([regex]::Matches($text,[regex]::Escape($manualDispatch))).Count -ne 2){throw 'Expected two manual automatic-repair dispatch actions.'}
$text=$text.Replace($manualDispatch,$manualDispatchFeedback)

$historyWarning="            if (`$script:historyWriteUnavailable) { `$HistoryText.Text += [Environment]::NewLine + 'The latest event could not be saved.' }"
if(([regex]::Matches($text,[regex]::Escape($historyWarning))).Count -ne 1){throw 'Expected one History write warning.'}
$text=$text.Replace($historyWarning,$historyWarning+[Environment]::NewLine+@'
            elseif ($script:autoHistoryReconcileUnavailable) { $HistoryText.Text += [Environment]::NewLine + 'Background activity could not be reconciled. Existing history was preserved.' }
'@)
[void][scriptblock]::Create($text)
[IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Protected local worker routing and truthful Automation state applied.'
