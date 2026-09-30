param(
    [Parameter(Mandatory=$true)][string]$Peer,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$RunId
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$clock=[Diagnostics.Stopwatch]::StartNew()
$script:Result=[ordered]@{
    schema=2;runId=$RunId;done=$false;phase='Starting';progress=2;severity='checking'
    summary='Preparing read-only diagnostics.';detail='';updatedUtc=[DateTime]::UtcNow.ToString('o');durationSeconds=0
    udp='Unknown';ipv4='Unknown';ipv6='Unknown';nearestDerp='Unknown';mapping='Unknown';portMapping='Unknown'
    netcheckStatus='Incomplete';path='Unknown';latency='Unknown';disco='Unknown';tsmp='Unknown';icmp='Unknown';peerApi='Unknown'
    otherVpns=@();vpnState='Unknown';vpnLabel='';error=''
}
function Publish {
    param([string]$Phase,[int]$Progress,[bool]$Done=$false,[string]$Severity='checking',[string]$Summary='')
    $script:Result.phase=$Phase;$script:Result.progress=$Progress;$script:Result.done=$Done;$script:Result.severity=$Severity
    $script:Result.updatedUtc=[DateTime]::UtcNow.ToString('o')
    $script:Result.durationSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,1)
    if($Summary){$script:Result.summary=$Summary}
    $temp=$OutputPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes(($script:Result|ConvertTo-Json -Depth 6 -Compress))
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
        # PowerShell 5.1 casts $null to an empty string for a String argument.
        # NullString preserves .NET's no-backup contract without deleting the old result first.
        if(Test-Path -LiteralPath $OutputPath){[IO.File]::Replace($temp,$OutputPath,[NullString]::Value)}
        else{[IO.File]::Move($temp,$OutputPath)}
    } catch {} finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}}
}
function Get-TailscaleCli {
    foreach($candidate in @("$env:ProgramFiles\Tailscale\tailscale.exe","${env:ProgramFiles(x86)}\Tailscale\tailscale.exe","$env:LOCALAPPDATA\Tailscale\tailscale.exe")) {
        if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){return $candidate}
    }
    $command=Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue
    if($command){return $command.Source}
    return $null
}
function Read-Probe {
    param([string]$Cli,[string]$Type,[int]$LimitMs=3000)
    $remaining=20000-[int]$clock.Elapsed.TotalMilliseconds
    if($remaining -lt 100){$r=New-Object Tqr.DiagnosticCommand;$r.TimedOut=$true;return $r}
    return [Tqr.DiagnosticAnalysis]::Run($Cli,$Type,$Peer,[Math]::Min($LimitMs,$remaining))
}
function Match-VpnSoftware {
    param([string[]]$Names)
    # Fixed labels only. Raw process/service names never leave this function.
    # Detection is best-effort context for Diagnostics and is never a health or repair input.
    $rules=@(
        [pscustomobject]@{label='Proton VPN';patterns=@('^protonvpn(?:service|\.wireguardservice)?$','^proton vpn(?: service)?$')}
        [pscustomobject]@{label='NordVPN';patterns=@('^nordvpn(?:-service|service)?$','^nordvpn(?: service)?$')}
        [pscustomobject]@{label='Mullvad';patterns=@('^mullvad(?:-daemon|daemon)?$','^mullvad vpn(?: service)?$')}
        [pscustomobject]@{label='ExpressVPN';patterns=@('^expressvpn(?:service|systemservice)?$','^expressvpn(?: service)?$')}
        [pscustomobject]@{label='Surfshark';patterns=@('^surfshark(?:service| service)?$')}
        [pscustomobject]@{label='Private Internet Access';patterns=@('^(?:pia-client|pia-service|private internet access(?: service)?)$')}
        [pscustomobject]@{label='Windscribe';patterns=@('^windscribe(?:service| service)?$')}
        [pscustomobject]@{label='IVPN';patterns=@('^ivpn(?:service|-service| client| service)?$')}
        [pscustomobject]@{label='TunnelBear';patterns=@('^tunnelbear.*$')}
        [pscustomobject]@{label='CyberGhost';patterns=@('^cyberghost.*$')}
        [pscustomobject]@{label='OpenVPN';patterns=@('^openvpn(?:service.*|serv.*| connect)?$')}
        [pscustomobject]@{label='WireGuard';patterns=@('^wireguard(?:manager|service.*| manager)?$')}
        [pscustomobject]@{label='Cisco Secure Client';patterns=@('^(?:vpnagent|csc_vpnagent|cisco secure client(?: vpn)?)$')}
        [pscustomobject]@{label='GlobalProtect';patterns=@('^(?:pangps|pangpa|globalprotect|globalprotect service)$')}
        [pscustomobject]@{label='FortiClient VPN';patterns=@('^forti(?:client|vpn).*$')}
        [pscustomobject]@{label='Ivanti Secure Access';patterns=@('^(?:pulsesvc|pulseui|ivanti secure access.*)$')}
        [pscustomobject]@{label='Cloudflare WARP';patterns=@('^(?:cloudflare ?warp|warp-svc|cloudflare warp service)$')}
        [pscustomobject]@{label='Mozilla VPN';patterns=@('^(?:mozilla vpn|mozillavpn.*)$')}
        [pscustomobject]@{label='hide.me';patterns=@('^(?:hide\.me|hideme).*$')}
        [pscustomobject]@{label='PureVPN';patterns=@('^purevpn.*$')}
        [pscustomobject]@{label='Hotspot Shield';patterns=@('^(?:hotspotshield|hotspot shield).*$')}
    )
    $found=New-Object 'Collections.Generic.List[string]'
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($raw in @($Names)){
        if([string]::IsNullOrWhiteSpace([string]$raw)){continue}
        $name=([string]$raw).Trim()
        $matched=$false
        foreach($rule in $rules){
            foreach($pattern in @($rule.patterns)){
                if($name -match $pattern){
                    if($seen.Add([string]$rule.label)){$found.Add([string]$rule.label)}
                    $matched=$true
                    break
                }
            }
            if($matched){break}
        }
        if(-not $matched -and $name -match '(?i)vpn|wireguard|openvpn'){
            if($seen.Add('Other VPN software')){$found.Add('Other VPN software')}
        }
    }
    return @($found.ToArray())
}
function Detect-OtherVpns {
    # Presence only: installed/running software does not prove a VPN is connected or conflicting.
    # Inventory is read-only and raw process/service names are not persisted.
    $names=New-Object 'Collections.Generic.List[string]'
    foreach($process in @(Get-Process -ErrorAction SilentlyContinue)){
        try {$names.Add([string]$process.ProcessName)} catch {}
        finally {try{$process.Dispose()}catch{}}
    }
    foreach($service in @(Get-Service -ErrorAction SilentlyContinue)){
        try {
            $names.Add([string]$service.Name)
            $names.Add([string]$service.DisplayName)
        } catch {}
        finally {try{$service.Dispose()}catch{}}
    }
    return @(Match-VpnSoftware -Names @($names.ToArray()))
}
try {
    Publish 'Finding Tailscale' 5
    Add-Type -Path (Join-Path $PSScriptRoot 'TailscaleQuickRepair.Operations.dll') -ErrorAction Stop
    if(-not [Tqr.DiagnosticAnalysis]::ValidPeer($Peer)){throw 'Invalid peer input.'}
    $cli=Get-TailscaleCli
    if(-not $cli){
        $script:Result.error='cli_missing';$script:Result.detail='The diagnostic CLI was not found. No network settings were changed.'
        Publish 'Complete' 100 $true 'warn' 'Diagnostics could not find the Tailscale CLI.'
        exit 0
    }
    Publish 'Inspecting network conditions' 15
    try {
        $vpnSnapshot=[Tqr.VpnAwareness]::Inspect()
        if($vpnSnapshot){
            $script:Result.vpnState=[string]$vpnSnapshot.State
            if([string]$vpnSnapshot.State -eq 'Detected'){$script:Result.vpnLabel=[string]$vpnSnapshot.Label}
        }
    } catch {}
    $net=[Tqr.DiagnosticAnalysis]::ParseNetwork((Read-Probe $cli 'netcheck' 8000))
    foreach($name in @('udp','ipv4','ipv6','nearestDerp','mapping','portMapping')){$script:Result[$name]=[string]$net.$name}
    $script:Result.netcheckStatus=$net.status
    Publish 'Probing the peer path' 40
    $disco=[Tqr.DiagnosticAnalysis]::ParseProbe((Read-Probe $cli 'disco'),'disco')
    $script:Result.disco=$disco.Status;$script:Result.path=$disco.Path;$script:Result.latency=$disco.Latency
    Publish 'Probing the tunnel' 55
    $tunnel=[Tqr.DiagnosticAnalysis]::ParseProbe((Read-Probe $cli 'tsmp'),'tsmp');$script:Result.tsmp=$tunnel.Status
    Publish 'Probing ICMP' 70
    $icmp=[Tqr.DiagnosticAnalysis]::ParseProbe((Read-Probe $cli 'icmp'),'icmp');$script:Result.icmp=$icmp.Status
    Publish 'Probing Peer API' 85
    $api=[Tqr.DiagnosticAnalysis]::ParseProbe((Read-Probe $cli 'peerapi'),'peerapi');$script:Result.peerApi=$api.Status
    $script:Result.otherVpns=@(Detect-OtherVpns)
    $verdict=[Tqr.DiagnosticAnalysis]::Explain($net,$disco,$tunnel,$icmp,$api)
    $script:Result.detail=$verdict.Detail
    if($script:Result.vpnState -eq 'Detected'){
        $vpnContext=if([string]::IsNullOrWhiteSpace([string]$script:Result.vpnLabel)){'VPN tunnel'}else{[string]$script:Result.vpnLabel}
        $script:Result.detail+=' Active VPN context: '+$vpnContext+'. This does not prove a conflict; Quick Repair did not change VPN, route or DNS settings.'
    }
    elseif($script:Result.otherVpns.Count -gt 0){
        $script:Result.detail+=' Detected VPN software is not evidence of an active conflict.'
    }
    Publish 'Complete' 100 $true $verdict.Severity $verdict.Summary
} catch {
    $script:Result.error='inspection_incomplete'
    $script:Result.detail='One or more diagnostic steps could not complete. The main connection check and network settings were not changed.'
    Publish 'Complete' 100 $true 'warn' 'Diagnostics could not complete every step.'
}
