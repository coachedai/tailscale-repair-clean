param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){
    throw 'Reliability transition tests require native Windows PowerShell 5.1.'
}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false
$work=$null
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw ('FAILED reliability transitions: '+$Name)}
    Write-Host ('PASS reliability transitions: '+$Name)
}
try{
    $packages=@(Get-ChildItem -LiteralPath $OutputDirectory -File -Filter 'TailscaleQuickRepair-*.zip' |
        Where-Object{$_.Name -notmatch 'SetupPackage|migration'})
    Check ($packages.Count -eq 1) 'Exactly one normal candidate package is tested'
    $work=Join-Path $env:RUNNER_TEMP ('TqrReliability-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work|Out-Null
    Expand-Archive -LiteralPath $packages[0].FullName -DestinationPath $work
    $uiPath=Join-Path $work 'app\Tailscale-Repair-UI.ps1'
    $text=[IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Final packaged UI parses on native Windows PowerShell'

    $names=@('Register-ReliabilityWatchers','Poll-ReliabilityEnvironment','Unregister-ReliabilityWatchers')
    $functions=@{}
    foreach($name in $names){
        $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
        Check ($nodes.Count -eq 1) ('Exactly one packaged '+$name+' function exists')
        $functions[$name]=$nodes[0].Extent.Text
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }

    $combined=[string]::Join([Environment]::NewLine,@($names|ForEach-Object{$functions[$_]}))
    foreach($forbidden in @('tailscale ping','Start-Repair','Invoke-AutoRepairMonitorNow','Repair-Backend','Set-AutoRepairEnabled')){
        Check ($combined -notmatch [regex]::Escape($forbidden)) ('Reliability watcher never directly invokes '+$forbidden)
    }

    $script:fakeNow=[DateTime]'2026-01-01T12:00:00Z'
    $script:fakeSignature='fixture-network-a'
    $script:events=New-Object Collections.ArrayList
    function Get-Date { return $script:fakeNow }
    function Get-NetworkEnvironmentSignature { return $script:fakeSignature }
    $script:fakeVpnTransition=$false
    $script:lastVpnTransitionDetected=$false
    function Update-VpnAwareness {
        param([switch]$RecordTransition)
        $script:lastVpnTransitionDetected=[bool]$script:fakeVpnTransition
    }
    function Mark-CurrentResultStale([string]$Reason){
        [void]$script:events.Add([pscustomobject]@{kind='stale';reason=$Reason;delay=0})
    }
    function Queue-AutoRepairSmartCheck {
        param([string]$Reason,[int]$DelaySeconds=6)
        [void]$script:events.Add([pscustomobject]@{kind='queue';reason=$Reason;delay=$DelaySeconds})
    }
    function Queue-PassiveLocalRefresh {
        param([int]$DelaySeconds=4)
        [void]$script:events.Add([pscustomobject]@{kind='local-refresh';reason='';delay=$DelaySeconds})
    }

    Register-ReliabilityWatchers
    Check ($script:lastReliabilityPollAt -eq $script:fakeNow -and
        $script:lastNetworkSignature -ceq 'fixture-network-a') 'Registration captures only the current clock and network signature'

    $script:fakeNow=$script:fakeNow.AddSeconds(10)
    Poll-ReliabilityEnvironment
    Check ($script:events.Count -eq 0) 'Normal short polling gap with unchanged network does nothing'

    $script:fakeNow=$script:fakeNow.AddSeconds(30)
    Poll-ReliabilityEnvironment
    $resume=@($script:events | ForEach-Object { $_ })
    Check ($resume.Count -eq 3 -and $resume[0].kind -ceq 'stale' -and
        $resume[0].reason -ceq 'PC resumed from sleep' -and
        $resume[1].kind -ceq 'local-refresh' -and $resume[1].delay -eq 5 -and
        $resume[2].kind -ceq 'queue' -and $resume[2].reason -ceq 'PC resumed from sleep' -and
        $resume[2].delay -eq 8) 'Long dispatcher gap marks the prior result stale, refreshes local state and preserves the bounded Auto Repair trigger'

    $script:events.Clear()
    $script:fakeNow=$script:fakeNow.AddSeconds(5)
    $script:fakeSignature='fixture-network-b'
    Poll-ReliabilityEnvironment
    $changed=@($script:events | ForEach-Object { $_ })
    Check ($changed.Count -eq 3 -and $changed[0].kind -ceq 'stale' -and
        $changed[0].reason -ceq 'Network changed' -and
        $changed[1].kind -ceq 'local-refresh' -and $changed[1].delay -eq 4 -and
        $changed[2].kind -ceq 'queue' -and $changed[2].reason -ceq 'Network changed' -and
        $changed[2].delay -eq 10) 'Network signature change marks the prior result stale, refreshes local state and preserves the bounded Auto Repair trigger'

    $script:events.Clear()
    $script:fakeNow=$script:fakeNow.AddSeconds(5)
    $script:fakeSignature=''
    Poll-ReliabilityEnvironment
    Check ($script:events.Count -eq 0 -and $script:lastNetworkSignature -ceq 'fixture-network-b') 'Transient empty network signature is ignored without erasing the last known signature'

    $script:fakeNow=$script:fakeNow.AddSeconds(5)
    $script:fakeSignature='fixture-network-c'
    Poll-ReliabilityEnvironment
    $recovered=@($script:events | ForEach-Object { $_ })
    Check ($recovered.Count -eq 3 -and $recovered[0].reason -ceq 'Network changed' -and
        $recovered[1].kind -ceq 'local-refresh' -and $recovered[1].delay -eq 4 -and
        $recovered[2].reason -ceq 'Network changed') 'First usable signature after a transient gap is treated as one network transition with one local refresh'

    $script:events.Clear()
    $script:fakeVpnTransition=$true
    $script:fakeNow=$script:fakeNow.AddSeconds(5)
    $script:fakeSignature='fixture-network-vpn'
    Poll-ReliabilityEnvironment
    $vpnChanged=@($script:events | ForEach-Object { $_ })
    Check ($vpnChanged.Count -eq 3 -and $vpnChanged[1].kind -ceq 'local-refresh' -and
        $vpnChanged[1].delay -eq 4 -and $vpnChanged[2].kind -ceq 'queue' -and
        $vpnChanged[2].delay -eq 20) 'VPN transition keeps the immediate read-only local refresh but gives the protected Auto Repair check extra settling time'

    $script:events.Clear()
    $script:fakeNow=$script:fakeNow.AddSeconds(30)
    Poll-ReliabilityEnvironment
    $vpnResume=@($script:events | ForEach-Object { $_ })
    Check ($vpnResume.Count -eq 3 -and $vpnResume[1].kind -ceq 'local-refresh' -and
        $vpnResume[1].delay -eq 5 -and $vpnResume[2].kind -ceq 'queue' -and
        $vpnResume[2].delay -eq 15) 'Resume during VPN context also receives a bounded settling delay before Auto Repair is asked to check'

    $script:fakeVpnTransition=$false
    Unregister-ReliabilityWatchers
    Check ($script:lastReliabilityPollAt -eq [DateTime]::MinValue -and
        [string]::IsNullOrEmpty($script:lastNetworkSignature)) 'Unregister clears only watcher timing/signature state'

    $passed=$true
} finally {
    [pscustomobject]@{
        schema=1
        passed=$passed
        source=$env:GITHUB_SHA
        scope='Synthetic clock and network-signature execution of the final packaged reliability watcher; no physical sleep, VPN transition, remote probe or repair is claimed.'
        cases=@($cases.ToArray())
    }|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'reliability-transition-results.json') -Encoding UTF8
    if($work -and (Test-Path -LiteralPath $work)){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
}