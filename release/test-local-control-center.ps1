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

# Check visibility within the expandable Details container. A child's own
# Visibility can remain Visible while a containing panel is collapsed.
function Test-VisibleWithinDetails {
    param($Element,$Boundary)
    if ($null -eq $Element -or $null -eq $Boundary) { return $false }
    $node = $Element
    for ($depth = 0; $depth -lt 64; $depth++) {
        if ($null -eq $node) { return $false }
        if ([object]::ReferenceEquals($node,$Boundary)) { return $true }
        if ($node -is [System.Windows.UIElement] -and
            $node.Visibility -ne [System.Windows.Visibility]::Visible) { return $false }
        $node = [System.Windows.LogicalTreeHelper]::GetParent($node)
    }
    return $false
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
                $details = $window.FindName('DetailsPanel')
                Check ($details -and
                    (Test-VisibleWithinDetails $remoteName $details) -and
                    (Test-VisibleWithinDetails $remoteIp $details) -and
                    (Test-VisibleWithinDetails $remoteTrend $details)) 'Remote details keeps deeper context outside hidden ancestors'
                $duplicates = $window.FindName('DetailDuplicateRemoteSummary')
                Check ($remoteStatus -and $remoteRoute -and $remoteLatency -and $duplicates -and
                    $duplicates.Visibility -eq [System.Windows.Visibility]::Collapsed -and
                    [object]::ReferenceEquals([System.Windows.LogicalTreeHelper]::GetParent($remoteStatus),$duplicates) -and
                    [object]::ReferenceEquals([System.Windows.LogicalTreeHelper]::GetParent($remoteRoute),$duplicates) -and
                    [object]::ReferenceEquals([System.Windows.LogicalTreeHelper]::GetParent($remoteLatency),$duplicates) -and
                    -not (Test-VisibleWithinDetails $remoteStatus $details) -and
                    -not (Test-VisibleWithinDetails $remoteRoute $details) -and
                    -not (Test-VisibleWithinDetails $remoteLatency $details)) 'Remote dashboard duplicates stay hidden while copy bindings remain available'
                foreach ($name in @('DetailPeerName','DetailPeerIp','DetailConnectionTrend',
                    'DetailPeerStatus','DetailRoute','DetailLatency')) {
                    $namePattern = [regex]::Escape(('x:Name="' + $name + '"'))
                    Check ([regex]::Matches($xamlMatch.Groups['xaml'].Value,$namePattern).Count -eq 1) ('One remote detail binding: ' + $name)
                }
                $trendGrid = if ($remoteTrend) { [System.Windows.LogicalTreeHelper]::GetParent($remoteTrend) } else { $null }
                $recentLabel = @()
                if ($trendGrid -is [System.Windows.Controls.Grid]) {
                    $recentLabel = @($trendGrid.Children | Where-Object {
                        $_ -is [System.Windows.Controls.TextBlock] -and
                        [System.Windows.Controls.Grid]::GetRow($_) -eq [System.Windows.Controls.Grid]::GetRow($remoteTrend) -and
                        [System.Windows.Controls.Grid]::GetColumn($_) -eq 0 -and $_.Text -ceq 'Recent'
                    })
                    Check ($trendGrid.RowDefinitions.Count -eq 3) 'Remote details keeps three compact context rows'
                } else { Check $false 'Remote context grid is available' }
                Check ($recentLabel.Count -eq 1) 'Recent label belongs to the visible connection trend row'

                # Synthetic native controls prove the hierarchy check detects
                # hidden parents, rather than trusting a child's local value.
                $visibilityRoot = New-Object System.Windows.Controls.Grid
                $visibilityParent = New-Object System.Windows.Controls.StackPanel
                $visibilityProbe = New-Object System.Windows.Controls.TextBlock
                [void]$visibilityRoot.Children.Add($visibilityParent)
                [void]$visibilityParent.Children.Add($visibilityProbe)
                Check (Test-VisibleWithinDetails $visibilityProbe $visibilityRoot) 'Visibility check accepts an attached visible hierarchy'
                foreach ($state in @([System.Windows.Visibility]::Collapsed,[System.Windows.Visibility]::Hidden)) {
                    $visibilityParent.Visibility = $state
                    Check ($visibilityProbe.Visibility -eq [System.Windows.Visibility]::Visible -and
                        -not (Test-VisibleWithinDetails $visibilityProbe $visibilityRoot)) 'Visibility check rejects a hidden ancestor despite a visible child'
                }
                $visibilityParent.Visibility = [System.Windows.Visibility]::Visible
                $visibilityProbe.Visibility = [System.Windows.Visibility]::Collapsed
                Check (-not (Test-VisibleWithinDetails $visibilityProbe $visibilityRoot)) 'Visibility check rejects a directly collapsed control'
                [void]$visibilityParent.Children.Remove($visibilityProbe)
                $visibilityProbe.Visibility = [System.Windows.Visibility]::Visible
                Check (-not (Test-VisibleWithinDetails $visibilityProbe $visibilityRoot)) 'Visibility check rejects a detached control'
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
