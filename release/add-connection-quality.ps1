param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Old,[string]$New) {
    if ([regex]::Matches($script:text,[regex]::Escape($Old)).Count -ne 1) {
        throw ('Quality transform anchor missing or duplicated: ' + $Old.Substring(0,[Math]::Min(90,$Old.Length)))
    }
    $script:text=$script:text.Replace($Old,$New)
}
function Replace-Function([string]$Name,[string]$Replacement) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($script:text,[ref]$tokens,[ref]$errors)
    if ($errors.Count -ne 0) { throw 'Input package does not parse.' }
    $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if ($nodes.Count -ne 1) { throw "Expected exactly one packaged $Name definition." }
    $extent=$nodes[0].Extent
    $script:text=$script:text.Remove($extent.StartOffset,$extent.EndOffset-$extent.StartOffset).Insert($extent.StartOffset,$Replacement)
}
Replace-Function 'Update-ConnectionIntelligence' @'
function Update-ConnectionIntelligence {
        param($Data)
        if (-not $Data -or -not [bool]$Data.done) { return }
        try {
            if (-not ('Tqr.ConnectionQuality' -as [type])) {
                Add-Type -Path $OperationsLibraryPath -ErrorAction Stop
            }
            if (-not $script:connectionQuality) {
                $script:connectionQuality=New-Object Tqr.ConnectionQuality
            }
            # Never compare a delayed result for the old target with the new one.
            if ($Data.PSObject.Properties.Name -contains 'peer' -and
                -not [string]::IsNullOrWhiteSpace([string]$Data.peer) -and
                [string]$Data.peer -ine [string]$Peer) { return }
            $view=$script:connectionQuality.Observe([string]$Peer,$true,[string]$Data.updatedUtc,
                [string]$Data.peerReachable,[string]$Data.route,[string]$Data.latency,[DateTime]::UtcNow)
            if (-not $view) { return }
            Set-ConnectionInsight $view.Summary $view.Tone
            $ConnectionInsightText.ToolTip=$view.Explanation
            $DetailConnectionTrend.Text=$view.Baseline
            $DetailConnectionTrend.ToolTip=$view.Explanation
            $DetailConnectionTrend.Foreground=Get-Brush 'Value'
            if ($view.EventText) { Add-ConnectionEvent $view.EventText }
        }
        catch {
            # Quality analysis cannot change the check result, schedule a repair,
            # hide a failed measurement, or escape into the global UI handler.
            try {
                Set-ConnectionInsight 'Connection analysis unavailable' 'muted'
                $DetailConnectionTrend.Text='Not measured'
                $DetailConnectionTrend.ToolTip='The connection check result above is unchanged.'
            } catch {}
        }
    }

    function Reset-ConnectionQuality {
        param([switch]$Stale)
        try {
            if ($script:connectionQuality) { $script:connectionQuality.Reset([DateTime]::UtcNow) }
            $script:historyLastRoute=''
            $script:historyLastLatency=-1
            $script:connectionEvents.Clear()
            if ($Stale) {
                Set-ConnectionInsight 'Network changed; run a fresh check' 'muted'
                $DetailConnectionTrend.Text='Waiting for a fresh check'
            } else {
                Set-ConnectionInsight '' 'muted'
            }
        } catch {}
    }
'@
Replace-One "    `$script:connectionSamples = New-Object 'System.Collections.Generic.List[object]'" @'
    $script:connectionQuality=$null
    $script:connectionSamples = New-Object 'System.Collections.Generic.List[object]'
'@
Replace-One "        `$script:Peer = `$candidate" @'
        Reset-ConnectionQuality
        $script:Peer = $candidate
'@
Replace-One "    function Mark-CurrentResultStale {`n        param([string]`$Reason)" @'
    function Mark-CurrentResultStale {
        param([string]$Reason)
        Reset-ConnectionQuality -Stale
'@
# Keep the visible summary distinct from the baseline in Details, not repeated.
Replace-One '<TextBlock Grid.Row="5" Text="Session"' '<TextBlock Grid.Row="5" Text="Baseline"'
Replace-One '"Session trend: $($DetailConnectionTrend.Text)"' '"Recent latency baseline: $($DetailConnectionTrend.Text)"'
# Reserve existing layout space; never animate the same label on every repaint.
Replace-One '        Fade-In $ConnectionInsightText 0.55 170' '        # Keep the reserved insight row steady; no repeated fade on quick checks.'
[void][scriptblock]::Create($text)
[IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Passive connection quality added after final UI transforms.'
