param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$script:text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Old,[string]$New){
    if([regex]::Matches($script:text,[regex]::Escape($Old)).Count -ne 1){throw ('Support export anchor missing or duplicated: '+$Old.Substring(0,[Math]::Min(100,$Old.Length)))}
    $script:text=$script:text.Replace($Old,$New)
}
Replace-One @'
                                    AutomationProperties.Name="Copy advanced diagnostics report"
                                    Grid.Column="1"
                                    Visibility="Collapsed"
                                    Style="{StaticResource GhostButtonStyle}"
                                    Content="Copy report"/>
'@ @'
                                    AutomationProperties.Name="Preview privacy-safe support report"
                                    AutomationProperties.HelpText="Review a report with identifiers and raw logs excluded before copying or saving. Runs no checks."
                                    Grid.Column="1"
                                    Visibility="Visible"
                                    Style="{StaticResource GhostButtonStyle}"
                                    Content="Share report"/>
'@
Replace-One "    `$AdvancedCopyButton = `$window.FindName('AdvancedCopyButton')" @'
    $AdvancedCopyButton = $window.FindName('AdvancedCopyButton')
    $script:supportDiagnosticsData=$null
    $script:supportDiagnosticsState='not_run'
    $script:supportDiagnosticsPeer=''
    $script:supportDiagnosticsStale=$false
    $script:supportReportWindow=$null
'@
Replace-One '    function Get-AdvancedValue {' @'
    function Get-SupportFields {
        param($Source,[string[]]$Names)
        $projected=[ordered]@{}
        foreach($name in $Names){
            if($Source -and $Source.PSObject.Properties[$name]){$projected[$name]=$Source.$name}
        }
        return $projected
    }

    function Get-SupportSnapshot {
        # No service/CLI calls, probes, directory scans or raw report strings.
        $mainState=if($script:repairActive){'checking'}elseif(-not $script:lastData){'not_run'}elseif($script:environmentStale){'stale'}else{'completed'}
        $main=Get-SupportFields $script:lastData @('done','updatedUtc','mode','client','service','backend','peerReachable','route','latency','repairPerformed')
        $diag=Get-SupportFields $script:supportDiagnosticsData @('done','updatedUtc','netcheckStatus','udp','ipv4','ipv6','path','latency','disco','tsmp','icmp','peerApi','mapping','portMapping','durationSeconds')
        $diagState=$script:supportDiagnosticsState
        if($diagState -eq 'completed' -and ($script:supportDiagnosticsStale -or
            ($script:supportDiagnosticsPeer -and $script:supportDiagnosticsPeer -ine $Peer))){$diagState='stale'}
        $guardian=[ordered]@{state='Not checked';checkedUtc=$null;verifiedFiles=$null;issues=$null;baseline='Not confirmed'}
        $status=[string]$GuardianStatusText.Text
        if($status -eq 'Healthy'){$guardian.state='Healthy';$guardian.issues=0}
        elseif($status -match '^([0-9]{1,2}) issues? need(s)? attention$'){$guardian.state='Needs attention';$guardian.issues=[int]$Matches[1]}
        elseif($status -eq 'Check incomplete'){$guardian.state='Check incomplete'}
        elseif($status -eq 'Checking...'){$guardian.state='Checking'}
        elseif($status -eq 'Waiting for another operation'){$guardian.state='Waiting'}
        if($guardian.state -in @('Healthy','Needs attention')){
            if($script:lastGuardianCheckAt -is [DateTime] -and $script:lastGuardianCheckAt.Year -ge 2020){$guardian.checkedUtc=$script:lastGuardianCheckAt.ToUniversalTime().ToString('o')}
            if([string]$GuardianDetailText.Text -match '^([0-9]{1,2}) release files verified with SHA-256[.]'){$guardian.verifiedFiles=[int]$Matches[1]}
            if([string]$GuardianDetailText.Text -match 'Known-good baseline established[.]'){$guardian.baseline='Established'}
            elseif([string]$GuardianDetailText.Text -match 'Known-good baseline confirmed[.]'){$guardian.baseline='Confirmed'}
        }
        $history=@{}
        try{$history=[Tqr.SupportReport]::ReadHistory($StateDir)|ConvertFrom-Json -ErrorAction Stop}catch{}
        [ordered]@{
            appVersion=$ProductVersion;tailscaleVersion=[string]$DetailVersion.Text
            vpnState=[string]$script:lastVpnAwarenessState;vpnLabel=[string]$script:lastVpnAwarenessLabel
            mainState=$mainState;main=$main;guardian=$guardian
            diagnosticState=$diagState;diagnostics=$diag;history=$history
        }|ConvertTo-Json -Depth 8 -Compress
    }

    function Show-SupportReport {
        try {
            if($script:supportReportWindow){[void]$script:supportReportWindow.Activate();return}
            if(-not ('Tqr.SupportReport' -as [type])){Add-Type -Path $OperationsLibraryPath -ErrorAction Stop}
            $snapshot=Get-SupportSnapshot
            $captured=[DateTime]::UtcNow
            $withoutHistory=[Tqr.SupportReport]::Build($snapshot,$false,$captured)
            $withHistory=[Tqr.SupportReport]::Build($snapshot,$true,$captured)
            $script:supportReportWindow=[Tqr.SupportReportWindow]::Create($window,$withoutHistory,$withHistory)
            [void]$script:supportReportWindow.ShowDialog()
        } catch {
            # Never surface exception text or reuse a previous raw report.
            [void][Windows.MessageBox]::Show($window,'The support preview could not open. No report was copied or saved.','Share report',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)
        } finally {$script:supportReportWindow=$null}
    }

    function Get-AdvancedValue {
'@
Replace-One @'
    function Complete-AdvancedDiagnostics {
        param(
            $Result,
            [string]$FallbackSummary = ''
        )
'@ @'
    function Complete-AdvancedDiagnostics {
        param(
            $Result,
            [string]$FallbackSummary = ''
        )
        $script:supportDiagnosticsData=$Result
        $script:supportDiagnosticsState=if($Result -and $Result.done -is [bool] -and $Result.done){'completed'}else{'incomplete'}
'@
Replace-One @'
            $script:advancedDiagnosticsRunId = [Guid]::NewGuid().ToString('N')
'@ @'
            $script:advancedDiagnosticsRunId = [Guid]::NewGuid().ToString('N')
            $script:supportDiagnosticsState='checking'
            $script:supportDiagnosticsPeer=$Peer
            $script:supportDiagnosticsStale=$false
'@
Replace-One '            $AdvancedCopyButton.Visibility = [System.Windows.Visibility]::Collapsed' '            $AdvancedCopyButton.Visibility = [System.Windows.Visibility]::Visible'
Replace-One @'
    function Reset-ConnectionQuality {
        param([switch]$Stale)
'@ @'
    function Reset-ConnectionQuality {
        param([switch]$Stale)
        $script:supportDiagnosticsStale=$true
'@
# Replace only the final packaged Copy event, not any repair/clipboard peer action.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($script:text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Export input must parse.'}
$events=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$AdvancedCopyButton' -and $n.Member.Value -eq 'Add_Click'},$true))
if($events.Count -ne 1){throw 'Expected one diagnostic share action.'}
$extent=$events[0].Extent
$script:text=$script:text.Remove($extent.StartOffset,$extent.EndOffset-$extent.StartOffset).Insert($extent.StartOffset,'$AdvancedCopyButton.Add_Click({ Show-SupportReport })')
[void][scriptblock]::Create($script:text)
[IO.File]::WriteAllText($Path,$script:text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Privacy-safe snapshot preview integrated without altering repair decisions.'
