param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EvidenceDirectory='.\test-evidence'
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Passive startup gates require native Windows PowerShell 5.1.'}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false
function Check([bool]$Value,[string]$Name){
    if(-not $Value){throw ('FAILED passive startup health: '+$Name)}
    $cases.Add([pscustomobject]@{name=$Name;passed=$true});Write-Host ('PASS passive startup health: '+$Name)
}
function Decision([hashtable]$Values){
    $o=New-Object Tqr.PassiveStartupObservation
    $o.AppFilesReady=$true;$o.EngineReady=$true;$o.Config='Configured'
    $o.Service='Running';$o.Startup='Automatic';$o.Client='Running';$o.Backend='Running'
    foreach($key in $Values.Keys){$o.$key=$Values[$key]}
    return [Tqr.PassiveStartupHealth]::Evaluate($o)
}
$root=Join-Path $env:TEMP ('TqrPassiveStartup-'+[Guid]::NewGuid().ToString('N'))
try{
    $ordinary=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-*.zip' -File|Where-Object Name -notlike '*SetupPackage*')
    Check ($ordinary.Count -eq 1) 'One exact ordinary candidate package is available'
    New-Item -ItemType Directory -Path $root|Out-Null
    Expand-Archive -LiteralPath $ordinary[0].FullName -DestinationPath $root
    $uiPath=Join-Path $root 'app\Tailscale-Repair-UI.ps1'
    $dll=Join-Path $root 'app\TailscaleQuickRepair.Operations.dll'
    Add-Type -Path $dll
    Check ($null -ne ('Tqr.PassiveStartupHealth' -as [type]) -and $null -ne ('Tqr.PassiveStartupObservation' -as [type])) 'Delivered operations DLL contains typed passive startup policy'

    $d=Decision @{}
    Check ($d.Status -eq 'Healthy' -and $d.LocalHealthy -and [string]::IsNullOrEmpty($d.NotificationCode)) 'Healthy local startup is silent'
    $d=Decision @{Config='Missing'}
    Check ($d.Status -eq 'Healthy' -and $d.Reason -eq 'local_healthy_target_missing' -and [string]::IsNullOrEmpty($d.NotificationCode)) 'Missing target does not turn local health into a fault'
    $d=Decision @{Config='Invalid'}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_config_attention') 'Invalid local config is actionable without a network check'
    $d=Decision @{AppFilesReady=$false}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_maintenance') 'Missing Quick Repair files require maintenance'
    $d=Decision @{EngineReady=$false}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_maintenance') 'Broken protected integration requires maintenance'
    $d=Decision @{Service='Missing'}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_tailscale_missing') 'Missing Tailscale is actionable'
    $d=Decision @{Startup='Disabled'}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_service_disabled') 'Disabled Tailscale service is preserved and actionable'
    $d=Decision @{Backend='NeedsLogin'}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_sign_in') 'Sign-in state is preserved and actionable'
    $d=Decision @{Backend='NeedsMachineAuth'}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_approval') 'Approval state is preserved and actionable'
    $d=Decision @{Backend='InUseOtherUser'}
    Check ($d.Status -eq 'Attention' -and $d.NotificationCode -eq 'startup_other_user') 'Another-user state is preserved and actionable'
    $d=Decision @{Backend='Stopped'}
    Check ($d.Status -eq 'Paused' -and $d.Reason -eq 'disconnected' -and [string]::IsNullOrEmpty($d.NotificationCode)) 'Intentional disconnect is quiet and never turned into startup repair'
    $d=Decision @{Service='Stopped';Backend='Unknown'}
    Check ($d.Status -eq 'Waiting' -and [string]::IsNullOrEmpty($d.NotificationCode)) 'Stopped service is observed without startup mutation'
    foreach($backend in @('Starting','NoState','Unknown')){
        $d=Decision @{Backend=$backend}
        Check ($d.Status -eq 'Waiting' -and [string]::IsNullOrEmpty($d.NotificationCode)) ('Backend '+$backend+' remains a quiet settling state')
    }
    $d=Decision @{Client='Closed'}
    Check ($d.Status -eq 'Waiting' -and [string]::IsNullOrEmpty($d.NotificationCode)) 'Closed desktop client is not reopened by passive startup health'

    foreach($code in @('startup_maintenance','startup_config_attention','startup_tailscale_missing','startup_service_disabled','startup_sign_in','startup_approval','startup_other_user')){
        $prompt=[Tqr.SmartNotifications]::Describe($code)
        Check ($prompt -and $prompt.Warning -and -not [string]::IsNullOrWhiteSpace($prompt.Title) -and -not [string]::IsNullOrWhiteSpace($prompt.Body)) ('Typed notification exists for '+$code)
    }

    $text=[IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Delivered passive-health UI parses on Windows PowerShell 5.1'
    foreach($name in @('Test-PassiveStartupPresentationAllowed','Get-PassiveStartupConfigState','Test-PassiveStartupAppFiles','Update-PassiveTrayStatus','Apply-PassiveStartupPresentation','Invoke-PassiveStartupHealth','Get-PassiveStartupCollectionScript','Receive-PassiveStartupHealth','Stop-PassiveStartupHealth')){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        Check ($nodes.Count -eq 1) ('Exactly one delivered '+$name)
    }
    $guard=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-PassiveStartupPresentationAllowed'},$true))
    Check ($guard.Count -eq 1) 'Delivered passive presentation has one operation and freshness guard'
    . ([scriptblock]::Create($guard[0].Extent.Text))
    $global:TqrUiShutdownRequested=$false
    $script:repairActive=$false
    $script:updateDownloadActive=$false
    $script:pendingProtectedUpdateStarted=$false
    $script:lastData=$null
    Check (Test-PassiveStartupPresentationAllowed) 'Idle startup permits a local presentation'
    foreach($flag in @('repairActive','updateDownloadActive','pendingProtectedUpdateStarted')){
        Set-Variable -Name $flag -Value $true -Scope Script
        Check (-not (Test-PassiveStartupPresentationAllowed)) ('Active '+$flag+' prevents passive presentation')
        Set-Variable -Name $flag -Value $false -Scope Script
    }
    $global:TqrUiShutdownRequested=$true
    Check (-not (Test-PassiveStartupPresentationAllowed)) 'Shutdown prevents passive presentation'
    $global:TqrUiShutdownRequested=$false
    foreach($done in @($false,$true)){
        $script:lastData=[pscustomobject]@{done=$done}
        Check (-not (Test-PassiveStartupPresentationAllowed)) 'A newer full-check result is not overwritten by startup health'
        Check (Test-PassiveStartupPresentationAllowed -AllowFullCheck) 'Explicit manual refresh may update local-only presentation after a full check'
        $script:repairActive=$true
        Check (-not (Test-PassiveStartupPresentationAllowed -AllowFullCheck)) 'Manual refresh still refuses an active repair'
        $script:repairActive=$false
    }
    $script:lastData=$null

    $invoke=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-PassiveStartupHealth'},$true))[0].Extent.Text
    foreach($forbidden in @('Start-Repair','Invoke-AutoRepairMonitorNow','Advanced-Diagnostics','Repair-Backend.ps1','tailscale ping','peerReachable','RemoteStatus','route','latency')){
        Check (-not $invoke.Contains($forbidden)) ('Passive startup path excludes '+$forbidden)
    }
    Check ($invoke.Contains('New-Object Tqr.PassiveStartupWork') -and $invoke.Contains('.TryStart(') -and -not $invoke.Contains('$machine.Observe()') -and -not $invoke.Contains('$engine=Test-RepairEngine')) 'Startup dispatch does not collect local state on WPF'
    Check ($invoke.Contains('param([switch]$Refresh)') -and $invoke.Contains('$script:passiveStartupManual=$true')) 'Manual local refresh reuses the same bounded background worker'
    $collection=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-PassiveStartupCollectionScript'},$true))[0].Extent.Text
    $receive=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Receive-PassiveStartupHealth'},$true))[0].Extent.Text
    Check ($collection.Contains('New-Object Tqr.WindowsAutoRepairMachine') -and $receive.Contains('[Tqr.PassiveStartupHealth]::Evaluate')) 'Background collection retains the local observer and pure presentation policy'
    Check ($collection.Contains('$machine.LastLocalIp') -and $collection.Contains('$machine.LastVersion') -and -not $collection.Contains('tailscale ping')) 'Startup reuses the bounded local observer for self IP/version without adding a peer probe'
    foreach($name in @('Start-Repair','Start-UpdateInstall','Invoke-InstallationRepair','Apply-State','Reset-Ui')){
        $function=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        Check ($function.Count -eq 1 -and $function[0].Extent.Text.Contains('Stop-PassiveStartupHealth')) ('Passive results are invalidated at '+$name)
    }
    $queue=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Queue-StartupInitialization'},$true))
    Check ($queue.Count -eq 1 -and $queue[0].Extent.Text.Contains('Invoke-PassiveStartupHealth')) 'Startup queue invokes passive local health once'
    Check (-not $queue[0].Extent.Text.Contains('Start-Repair')) 'Startup queue never starts repair'
    $manualClick=@($ast.FindAll({param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression.Extent.Text -ceq '$AutoRepairCheckNowButton' -and
        $n.Member.Value -eq 'Add_Click'
    },$true))
    Check ($manualClick.Count -eq 1) 'Exactly one packaged Check local health click handler exists'
    $manualHandler=$manualClick[0].Arguments[0].ScriptBlock
    $manualCommands=@($manualHandler.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
    $refreshCommands=@($manualCommands|Where-Object {$_.GetCommandName() -ceq 'Invoke-PassiveStartupHealth'})
    $refreshParameters=@()
    if($refreshCommands.Count -eq 1){
        $refreshParameters=@($refreshCommands[0].CommandElements|Where-Object {
            $_ -is [Management.Automation.Language.CommandParameterAst]
        }|ForEach-Object {$_.ParameterName})
    }
    Check ($refreshCommands.Count -eq 1 -and $refreshParameters.Count -eq 1 -and
        $refreshParameters[0] -ceq 'Refresh') 'Check local health button invokes the read-only local observer'
    foreach($forbidden in @('Invoke-AutoRepairMonitorNow','Start-Repair','Set-AutoRepairEnabled')){
        Check (-not @($manualCommands|Where-Object {$_.GetCommandName() -ceq $forbidden}).Count) ('Manual local refresh never invokes '+$forbidden)
    }
    $manualVariables=@($manualHandler.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst]},$true)|ForEach-Object {$_.VariablePath.UserPath})
    Check ($manualVariables -notcontains 'AutoRepairCheckBox') 'Manual local refresh does not depend on the Automatic Repair checkbox'
    Check ($text.Contains('AutomationProperties.Name="Refresh local Tailscale status"') -and
        $text.Contains('Refreshes local Tailscale health without checking a remote device or making repairs.')) 'Manual local refresh is labelled as read-only and remote-free'
    $receive=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Receive-PassiveStartupHealth'},$true))[0].Extent.Text
    Check ($receive.Contains('if(-not $manual -and') -and $receive.Contains('-Manual:$manual')) 'Manual refresh updates local presentation without emitting automatic startup notifications'

    $validation=Get-Content -LiteralPath (Join-Path $OutputDirectory 'build-validation.json') -Raw|ConvertFrom-Json
    Check ($validation.passed -is [bool] -and $validation.passed -and $validation.source -ceq $env:GITHUB_SHA) 'Status tests use the matching verified build profile'
    & (Join-Path $PSScriptRoot 'test-status-clarity.ps1') -UiText $text -Cases $cases -ValidationProfile $validation.profile
    $setup=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-SetupPackage-*.zip' -File)
    Check ($setup.Count -eq 1) 'One exact Setup package is available for presentation parity'
    $setupRoot=Join-Path $root 'setup-presentation'
    Expand-Archive -LiteralPath $setup[0].FullName -DestinationPath $setupRoot
    $setupText=[IO.File]::ReadAllText((Join-Path $setupRoot 'app/Tailscale-Repair-UI.ps1'),[Text.Encoding]::UTF8)
    & (Join-Path $PSScriptRoot 'test-status-clarity.ps1') -UiText $setupText -Cases $cases -ValidationProfile $validation.profile
    $passed=$true
}finally{
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{
        passed=$passed
        source=$env:GITHUB_SHA
        scope='Typed local-only startup health and user-requested refresh; no peer/network probe and no repair authority'
        cases=@($cases.ToArray())
    }|ConvertTo-Json -Depth 7|Set-Content (Join-Path $EvidenceDirectory 'passive-startup-health-results.json') -Encoding UTF8
}
if(-not $passed){throw 'Passive startup health acceptance failed.'}