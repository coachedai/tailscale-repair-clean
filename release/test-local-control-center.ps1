param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Local control center acceptance requires Windows PowerShell 5.1.'
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$version = Get-Content -LiteralPath (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json
$zipPath = Join-Path $OutputDirectory ('TailscaleQuickRepair-' + [string]$version.version + '.zip')
if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw 'Validated update ZIP is missing for local control center acceptance.'
}

$cases = New-Object 'System.Collections.Generic.List[object]'
$passed = $true
function Check {
    param([bool]$Condition,[string]$Name)
    $script:cases.Add([pscustomobject]@{name=$Name;passed=$Condition})
    if (-not $Condition) { $script:passed = $false }
}

$work = Join-Path $env:RUNNER_TEMP ('tqr-local-control-' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $work 'package'
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $root -Force
    $uiPath = Join-Path $root 'app\Tailscale-Repair-UI.ps1'
    if (-not (Test-Path -LiteralPath $uiPath -PathType Leaf)) {
        throw 'Packaged UI is missing.'
    }

    $text = [IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) 'Packaged UI parses after local control center integration'

    $localIndex = $text.IndexOf('Text="Local details"',[StringComparison]::Ordinal)
    $refreshIndex = $text.IndexOf('x:Name="AutoRepairCheckNowButton"',[StringComparison]::Ordinal)
    $openIndex = $text.IndexOf('x:Name="OpenTailscaleButton"',[StringComparison]::Ordinal)
    $automationIndex = $text.IndexOf('Text="Automation"',[StringComparison]::Ordinal)
    Check ($localIndex -ge 0 -and $refreshIndex -gt $localIndex -and $openIndex -gt $localIndex -and
        $automationIndex -gt $refreshIndex -and $automationIndex -gt $openIndex) 'Local actions live with Local details instead of Automatic Repair'

    $refreshClicks = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -ceq '$AutoRepairCheckNowButton' -and
        $node.Member.Value -eq 'Add_Click'
    },$true))
    Check ($refreshClicks.Count -eq 1) 'Exactly one local refresh click handler exists'
    if ($refreshClicks.Count -eq 1) {
        $body = $refreshClicks[0].Arguments[0].ScriptBlock.Extent.Text
        Check ($body.Contains('Invoke-PassiveStartupHealth -Refresh') -and
            -not $body.Contains('Invoke-AutoRepairMonitorNow') -and
            -not $body.Contains('Start-Repair')) 'Local refresh remains read-only and remote-free'
    }

    $openClicks = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -ceq '$OpenTailscaleButton' -and
        $node.Member.Value -eq 'Add_Click'
    },$true))
    Check ($openClicks.Count -eq 1 -and
        $openClicks[0].Arguments[0].ScriptBlock.Extent.Text.Contains('Open-TailscaleContextually')) 'Open Tailscale reuses the bounded installed-app launcher'

    $queue = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Queue-PassiveLocalRefresh'
    },$true))
    Check ($queue.Count -eq 1) 'One debounced passive local refresh queue exists'
    if ($queue.Count -eq 1) {
        $queueText = $queue[0].Extent.Text
        Check ($queueText.Contains('Invoke-PassiveStartupHealth -Refresh') -and
            -not $queueText.Contains('Start-Repair') -and
            -not $queueText.Contains('Invoke-AutoRepairMonitorNow') -and
            -not $queueText.Contains('tailscale ping')) 'Network-change refresh cannot repair or probe a peer'
    }

    $poll = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Poll-ReliabilityEnvironment'
    },$true))
    Check ($poll.Count -eq 1 -and
        [regex]::Matches($poll[0].Extent.Text,[regex]::Escape('Queue-PassiveLocalRefresh')).Count -eq 2) 'Resume and network change each schedule one local refresh'

    Check ($text.Contains('$script:trayOpenTailscaleItem') -and
        $text.Contains("ToolStripMenuItem('Open Tailscale')")) 'Tray exposes the official Tailscale app shortcut'
    Check (-not $text.Contains('Quick Repair 2.0')) 'Maintenance copy no longer carries a stale major-version label'

    $xamlMatch = [regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    Check $xamlMatch.Success 'Packaged XAML remains extractable'
    if ($xamlMatch.Success) {
        [xml]$xaml = $xamlMatch.Groups['xaml'].Value
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $window = $null
        try {
            $window = [Windows.Markup.XamlReader]::Load($reader)
            Check ($null -ne $window) 'Packaged XAML loads on native WPF'
            if ($window) {
                Check ($null -ne $window.FindName('AutoRepairCheckNowButton') -and
                    $null -ne $window.FindName('OpenTailscaleButton')) 'Local quick actions are present in the native WPF tree'
                $remoteName = $window.FindName('DetailPeerName')
                $remoteIp = $window.FindName('DetailPeerIp')
                $remoteTrend = $window.FindName('DetailConnectionTrend')
                $remoteStatus = $window.FindName('DetailPeerStatus')
                $remoteRoute = $window.FindName('DetailRoute')
                $remoteLatency = $window.FindName('DetailLatency')
                Check ($remoteName -and $remoteIp -and $remoteTrend -and
                    $remoteName.Visibility -eq [System.Windows.Visibility]::Visible -and
                    $remoteIp.Visibility -eq [System.Windows.Visibility]::Visible -and
                    $remoteTrend.Visibility -eq [System.Windows.Visibility]::Visible) 'Remote details keeps only deeper visible context'
                Check ($remoteStatus -and $remoteRoute -and $remoteLatency -and
                    $remoteStatus.Visibility -eq [System.Windows.Visibility]::Collapsed -and
                    $remoteRoute.Visibility -eq [System.Windows.Visibility]::Collapsed -and
                    $remoteLatency.Visibility -eq [System.Windows.Visibility]::Collapsed) 'Remote dashboard duplicates stay hidden while copy bindings remain available'
                Check ($text.Contains('Text="Recent"')) 'Remote details labels the connection trend compactly'
            }
        }
        finally {
            try { $reader.Close() } catch {}
            try { if ($window -is [System.Windows.Window]) { $window.Close() } } catch {}
        }
    }
}
finally {
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    [pscustomobject]@{
        schema=1
        passed=$passed
        source=$env:GITHUB_SHA
        scope='Final packaged UI structure and read-only local refresh routing; no live Tailscale service, peer or VPN is changed.'
        cases=@($cases.ToArray())
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'local-control-center-results.json') -Encoding UTF8

    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $passed) {
    throw 'Local control center acceptance failed.'
}
Write-Host 'Local control center acceptance passed.'
