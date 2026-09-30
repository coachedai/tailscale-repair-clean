param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2

if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){
    throw 'VPN awareness acceptance requires Windows PowerShell 5.1.'
}

$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$version=Get-Content -LiteralPath (Join-Path $repo 'version.json') -Raw|ConvertFrom-Json
$zip=Join-Path $OutputDirectory ('TailscaleQuickRepair-'+[string]$version.version+'.zip')
if(-not(Test-Path -LiteralPath $zip -PathType Leaf)){throw 'Validated update ZIP is missing.'}

$cases=New-Object 'Collections.Generic.List[object]'
$passed=$true
function Check([bool]$Value,[string]$Name){
    $script:cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){$script:passed=$false}
}

$work=Join-Path $env:RUNNER_TEMP ('tqr-vpn-awareness-'+[Guid]::NewGuid().ToString('N'))
$root=Join-Path $work 'package'
New-Item -ItemType Directory -Path $root -Force|Out-Null
try{
    Expand-Archive -LiteralPath $zip -DestinationPath $root -Force
    $dll=Join-Path $root 'app\TailscaleQuickRepair.Operations.dll'
    $uiPath=Join-Path $root 'app\Tailscale-Repair-UI.ps1'
    Add-Type -Path $dll -ErrorAction Stop

    function Classify([string]$Name,[string]$Description,[Net.NetworkInformation.NetworkInterfaceType]$Type,[Net.NetworkInformation.OperationalStatus]$Status){
        return [Tqr.VpnAwareness]::Classify($Name,$Description,$Type,$Status)
    }

    Check ((Classify 'Tailscale' 'Tailscale Tunnel' ([Net.NetworkInformation.NetworkInterfaceType]::Tunnel) ([Net.NetworkInformation.OperationalStatus]::Up)) -ceq '') 'Tailscale itself is never classified as another VPN'
    Check ((Classify 'fixture' 'Proton VPN WireGuard' ([Net.NetworkInformation.NetworkInterfaceType]::Ethernet) ([Net.NetworkInformation.OperationalStatus]::Up)) -ceq 'Proton VPN') 'Proton VPN is recognised without special repair behaviour'
    Check ((Classify 'fixture' 'CloudflareWARP' ([Net.NetworkInformation.NetworkInterfaceType]::Ethernet) ([Net.NetworkInformation.OperationalStatus]::Up)) -ceq 'Cloudflare WARP') 'Cloudflare WARP is recognised'
    Check ((Classify 'fixture' 'Cisco AnyConnect Secure Mobility Client' ([Net.NetworkInformation.NetworkInterfaceType]::Ethernet) ([Net.NetworkInformation.OperationalStatus]::Up)) -ceq 'Cisco Secure Client') 'Enterprise VPN adapters are recognised'
    Check ((Classify 'fixture' 'Wintun Userspace Tunnel' ([Net.NetworkInformation.NetworkInterfaceType]::Ethernet) ([Net.NetworkInformation.OperationalStatus]::Up)) -ceq 'VPN tunnel') 'Unknown Wintun adapters use a generic fixed label'
    Check ((Classify 'fixture' 'Private Secret VPN 123' ([Net.NetworkInformation.NetworkInterfaceType]::Tunnel) ([Net.NetworkInformation.OperationalStatus]::Up)) -ceq 'VPN tunnel') 'Unknown tunnel names never escape the fixed-label boundary'
    Check ((Classify 'Wi-Fi' 'Intel Wireless Adapter' ([Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) ([Net.NetworkInformation.OperationalStatus]::Up)) -ceq '') 'Ordinary network adapters are not labelled as VPNs'
    Check ((Classify 'fixture' 'Mullvad VPN' ([Net.NetworkInformation.NetworkInterfaceType]::Ethernet) ([Net.NetworkInformation.OperationalStatus]::Down)) -ceq '') 'Inactive VPN adapters are not shown as active'

    $snapshot=[Tqr.VpnAwareness]::Inspect()
    Check ($snapshot -and [string]$snapshot.State -in @('Detected','NotDetected','Unknown')) 'Live inspection returns only a bounded state'
    Check ([string]$snapshot.Signature -notmatch '(?i)\\|[A-Z]:|@|\b(?:\d{1,3}\.){3}\d{1,3}\b') 'Live VPN signature contains no path, account or IPv4 material'

    $text=[IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) 'Packaged VPN-aware UI parses'
    Check ($text.Contains('x:Name="DetailVpn"') -and $text.Contains('"VPN: $($DetailVpn.Text)"')) 'VPN state appears in Local details and explicit copied status'
    Check ($text.Contains('$script:trayVpnItem') -and $text.Contains("ToolStripMenuItem('VPN - not checked')")) 'Tray exposes bounded VPN context without a control action'

    $update=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Update-VpnAwareness'},$true))
    Check ($update.Count -eq 1) 'Exactly one VPN presentation function is packaged'
    if($update.Count -eq 1){
        $body=$update[0].Extent.Text
        Check ($text.Contains('[Tqr.VpnAwareness]::Inspect()')) 'VPN presentation uses the native read-only classifier'
        Check ($body.Contains('Add-ReliabilityEvent') -and $body.Contains('$RecordTransition')) 'VPN transitions can add a privacy-safe Activity event without changing health'
        Check ($body.Contains('$script:lastVpnTransitionDetected=$true')) 'VPN transition detection exposes only a boolean coexistence signal'
        foreach($forbidden in @('Start-Repair','Invoke-AutoRepairMonitorNow','Restart-Service','Stop-Service','Set-Net','netsh','ipconfig /flushdns')){
            Check (-not $body.Contains($forbidden)) ('VPN presentation never invokes '+$forbidden)
        }
    }

    $transition=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-VpnTransitionMessage'},$true))
    Check ($transition.Count -eq 1) 'Exactly one pure VPN transition formatter is packaged'
    if($transition.Count -eq 1){
        . ([scriptblock]::Create($transition[0].Extent.Text))
        Check ((Get-VpnTransitionMessage 'NotDetected' 'Detected' 'Proton VPN') -ceq 'VPN active - Proton VPN') 'VPN activation uses only a fixed public label'
        Check ((Get-VpnTransitionMessage 'Detected' 'NotDetected' '') -ceq 'VPN inactive') 'VPN disconnect is reported without adapter data'
        Check ((Get-VpnTransitionMessage 'Detected' 'Detected' 'Mullvad') -ceq 'VPN changed - Mullvad') 'VPN-to-VPN changes stay privacy-safe'
    }
    $historyCode=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-VpnHistoryCode'},$true))
    Check ($historyCode.Count -eq 1) 'Exactly one typed VPN history classifier is packaged'
    if($historyCode.Count -eq 1){
        . ([scriptblock]::Create($historyCode[0].Extent.Text))
        Check ((Get-VpnHistoryCode 'NotDetected' 'Detected') -ceq 'vpn_active' -and
            (Get-VpnHistoryCode 'Detected' 'NotDetected') -ceq 'vpn_inactive' -and
            (Get-VpnHistoryCode 'Detected' 'Detected') -ceq 'vpn_changed') 'VPN history records only fixed transition codes'
    }
    Check ($text.Contains('[Tqr.LocalHistory]::Record($StateDir,$historyCode,-1,-1)')) 'VPN transition history persists no vendor, adapter or address fields'
    $poll=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Poll-ReliabilityEnvironment'},$true))
    Check ($poll.Count -eq 1 -and [regex]::Matches($poll[0].Extent.Text,[regex]::Escape('Update-VpnAwareness -RecordTransition')).Count -eq 2) 'Resume and network changes refresh VPN context without adding a new repair trigger'
    if($poll.Count -eq 1){
        $pollText=$poll[0].Extent.Text
        Check ($pollText.Contains('$autoRepairDelaySeconds=if($script:lastVpnTransitionDetected){20}else{10}') -and
            $pollText.Contains('$autoRepairDelaySeconds=if($script:lastVpnTransitionDetected){15}else{8}')) 'VPN coexistence adds settling time without changing repair authority'
    }

    $native=[IO.File]::ReadAllText((Join-Path $repo 'src\native\VpnAwareness.cs'),[Text.Encoding]::UTF8)
    foreach($forbidden in @('File.','Registry','Process.Start','ServiceController','WebRequest','HttpClient')){
        Check (-not $native.Contains($forbidden)) ('Native VPN awareness remains read-only: '+$forbidden)
    }
    Check ($native.Contains('raw adapter names/descriptions never leave') -and $native.Contains('"VPN tunnel"')) 'Native classifier enforces fixed-label privacy'

    $xamlMatch=[regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    Check $xamlMatch.Success 'VPN-aware XAML remains extractable'
    if($xamlMatch.Success){
        [xml]$xaml=$xamlMatch.Groups['xaml'].Value
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $reader=New-Object System.Xml.XmlNodeReader $xaml
        $window=$null
        try{
            $window=[Windows.Markup.XamlReader]::Load($reader)
            Check ($window -and $window.FindName('DetailVpn')) 'VPN status control loads in native WPF'
        }finally{
            try{$reader.Close()}catch{}
            try{if($window -is [Windows.Window]){$window.Close()}}catch{}
        }
    }
}finally{
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
    [pscustomobject]@{
        schema=1;passed=$passed;source=$env:GITHUB_SHA
        scope='Synthetic adapter classification plus final packaged WPF wiring. No VPN client, route, DNS setting, adapter or Tailscale state is changed.'
        cases=@($cases.ToArray())
    }|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'vpn-awareness-results.json') -Encoding UTF8
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if(-not $passed){throw 'VPN awareness acceptance failed.'}
Write-Host 'VPN awareness acceptance passed.'
