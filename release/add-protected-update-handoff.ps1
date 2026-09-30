param([Parameter(Mandatory=$true)][string]$Path)

$ErrorActionPreference = 'Stop'
$text = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)

function Replace-ExactOnce {
    param([string]$Find,[string]$Replace,[string]$Description)
    $first = $script:text.IndexOf($Find,[StringComparison]::Ordinal)
    if ($first -lt 0 -or $script:text.IndexOf($Find,$first+$Find.Length,[StringComparison]::Ordinal) -ge 0) {
        throw "Expected one $Description marker."
    }
    $script:text = $script:text.Remove($first,$Find.Length).Insert($first,$Replace)
}

function Replace-FunctionOnce {
    param([string]$Name,[string]$Replacement)

    $tokens=$null
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($script:text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {
        throw "Packaged UI does not parse before replacing $Name."
    }

    $functions=@($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    },$true))

    if ($functions.Count -ne 1) {
        throw "Expected one packaged $Name function; found $($functions.Count)."
    }

    $node=$functions[0]
    $length=$node.Extent.EndOffset-$node.Extent.StartOffset
    $script:text=$script:text.Remove($node.Extent.StartOffset,$length).Insert($node.Extent.StartOffset,$Replacement)
}

if ($text -notmatch '(?m)^\$ProtectedUpdateMarkerPath\s*=') {
    $setupLine = '$SetupHostPath = Join-Path $StateDir ''TailscaleQuickRepairSetup.exe'''
    Replace-ExactOnce $setupLine ($setupLine + [Environment]::NewLine +
        '$ProtectedUpdateMarkerPath = Join-Path $StateDir ''protected-update.json''' + [Environment]::NewLine +
        '$RestartRegistryPath = ''HKCU:\Software\TailscaleQuickRepair''' + [Environment]::NewLine +
        '$RestartRegistryName = ''PendingRestartVersionCode''') 'Setup path'
}

$functionBlock = @'
    function Invoke-PendingProtectedUpdate {
        param([scriptblock]$StartProcess)

        if ($script:pendingProtectedUpdateStarted -or -not (Test-Path -LiteralPath $ProtectedUpdateMarkerPath)) {
            return $false
        }

        try {
            $marker = Get-Content -LiteralPath $ProtectedUpdateMarkerPath -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
            $names = @($marker.PSObject.Properties.Name)
            $validCodeType = $marker.versionCode -is [int] -or $marker.versionCode -is [long]
            $markerChannel = 'stable'

            if ($marker.schema -isnot [int] -or -not $validCodeType -or [int64]$marker.versionCode -ne $ProductVersionCode) {
                throw 'The protected update marker is invalid.'
            }

            if ([int]$marker.schema -eq 1) {
                if ($names.Count -ne 2 -or 'schema' -notin $names -or 'versionCode' -notin $names) {
                    throw 'The protected update marker is invalid.'
                }
            }
            elseif ([int]$marker.schema -eq 2) {
                if ($names.Count -ne 3 -or 'schema' -notin $names -or 'versionCode' -notin $names -or 'channel' -notin $names) {
                    throw 'The protected update marker is invalid.'
                }
                $markerChannel = [string]$marker.channel
                if ($markerChannel -notin @('stable','preview')) {
                    throw 'The protected update marker is invalid.'
                }
            }
            else {
                throw 'The protected update marker is invalid.'
            }

            $installedVersionPath = Join-Path $StateDir 'version.user.json'
            if (-not (Test-Path -LiteralPath $installedVersionPath -PathType Leaf)) {
                throw 'The installed update identity is missing.'
            }
            $installedVersion = Get-Content -LiteralPath $installedVersionPath -Raw -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
            $installedChannel = [string]$installedVersion.channel
            if (
                [int64]$installedVersion.versionCode -ne $ProductVersionCode -or
                $installedChannel -notin @('stable','preview') -or
                $installedChannel -cne $markerChannel
            ) {
                throw 'The protected update marker does not match the installed release channel.'
            }

            if (-not (Test-Path -LiteralPath $SetupHostPath -PathType Leaf)) {
                throw 'The verified Setup component is missing.'
            }

            $requesterSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ([string]::IsNullOrWhiteSpace($requesterSid) -or $requesterSid -notmatch '^S-1-[0-9-]+$') {
                throw 'The Windows account could not be verified.'
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $SetupHostPath
            $psi.Arguments = '--upgrade --channel "' + $markerChannel + '" --target-code ' + [string][int64]$marker.versionCode + ' --requester-sid "' + $requesterSid + '"'
            $psi.Verb = 'runas'
            $psi.UseShellExecute = $true

            if ($StartProcess) {
                $process = & $StartProcess $psi
            }
            else {
                $process = [System.Diagnostics.Process]::Start($psi)
            }

            if (-not $process) {
                throw 'The protected update could not start.'
            }

            $script:pendingProtectedUpdateStarted = $true
            $script:allowFullExit = $true
            $global:TqrUiShutdownRequested = $true
            $UpdateStatusText.Text = 'Finishing protected update...'
            $UpdateStatusText.Foreground = Get-Brush 'Blue'
            $UpdateDetailText.Text = 'Approve the Windows prompt. Quick Repair will reopen when the update is complete.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible

            $window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{ try { $window.Close() } catch {} }
            ) | Out-Null

            return $true
        }
        catch {
            $UpdateStatusText.Text = 'Protected update needs attention'
            $UpdateStatusText.Foreground = Get-Brush 'Amber'
            $UpdateDetailText.Text = 'The protected part of the update was not started. Nothing protected was changed.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            return $false
        }
    }

    function Acknowledge-ProtectedRestart {
        try {
            if (-not (Test-Path -LiteralPath $RestartRegistryPath)) {
                return $false
            }

            $values = Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction SilentlyContinue
            if (-not $values -or $null -eq $values.$RestartRegistryName) {
                return $false
            }

            $pending = $values.$RestartRegistryName
            $validType = $pending -is [long] -or $pending -is [int]
            if (-not $validType -or [int64]$pending -ne $ProductVersionCode) {
                $UpdateStatusText.Text = 'Restart confirmation needs attention'
                $UpdateStatusText.Foreground = Get-Brush 'Amber'
                $UpdateDetailText.Text = 'Quick Repair is running, but the saved restart confirmation does not match this version.'
                $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
                return $false
            }

            Remove-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction Stop
            $remaining = Get-ItemProperty -LiteralPath $RestartRegistryPath -Name $RestartRegistryName -ErrorAction SilentlyContinue
            if ($remaining -and $null -ne $remaining.$RestartRegistryName) {
                throw 'Restart confirmation could not be cleared.'
            }

            if (Get-Command Write-LocalHistoryEvent -ErrorAction SilentlyContinue) {
                Write-LocalHistoryEvent 'update_installed'
            }
            if (Get-Command Request-SmartNotification -ErrorAction SilentlyContinue) {
                [void](Request-SmartNotification 'update_installed' ([DateTime]::UtcNow.ToString('o')))
            }

            $UpdateStatusText.Text = "Updated successfully - $ProductVersion"
            $UpdateStatusText.Foreground = Get-Brush 'Green'
            $UpdateDetailText.Text = 'The protected update finished and Quick Repair restarted normally.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            return $true
        }
        catch {
            $UpdateStatusText.Text = 'Restart confirmation needs attention'
            $UpdateStatusText.Foreground = Get-Brush 'Amber'
            $UpdateDetailText.Text = 'Quick Repair is running, but restart confirmation could not be completed.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            return $false
        }
    }

'@

if ($text -notmatch [regex]::Escape('function Invoke-PendingProtectedUpdate')) {
    Replace-ExactOnce '    function Start-UpdateInstall {' ($functionBlock + '    function Start-UpdateInstall {') 'update install function'
}

$showUpdateResult = @'
    function Show-UpdateResult {
        if (-not (Test-Path -LiteralPath $UpdateResultPath -PathType Leaf)) {
            return
        }

        try {
            $notificationResultStamp=(Get-Item -LiteralPath $UpdateResultPath -ErrorAction Stop).LastWriteTimeUtc.ToString('o')
            $raw = Get-Content -LiteralPath $UpdateResultPath -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt 16384) { return }
            $result = $raw | ConvertFrom-Json -ErrorAction Stop

            $schema = 1
            if ($result.PSObject.Properties.Name -contains 'schema') {
                $schema = [int]$result.schema
            }

            $success = $result.success -is [bool] -and [bool]$result.success
            $outcome = if ($schema -ge 2 -and $result.PSObject.Properties.Name -contains 'outcome') {
                [string]$result.outcome
            } elseif ($success) {
                'installed'
            } else {
                'failed'
            }
            $reason = if ($schema -ge 2 -and $result.PSObject.Properties.Name -contains 'reason') {
                [string]$result.reason
            } else {
                'legacy_failure'
            }
            $recoveredPrevious = (
                $schema -ge 2 -and
                $result.PSObject.Properties.Name -contains 'recoveredPrevious' -and
                $result.recoveredPrevious -is [bool] -and
                [bool]$result.recoveredPrevious
            )

            switch ($outcome) {
                'installed' {
                    if (-not $success) { throw 'Invalid update result state.' }
                    if (Test-Path -LiteralPath $ProtectedUpdateMarkerPath) {
                        $UpdateStatusText.Text = 'Update downloaded - finishing setup'
                        $UpdateStatusText.Foreground = Get-Brush 'Blue'
                        $UpdateDetailText.Text = 'Windows approval is needed to finish the protected part of this update.'
                    }
                    else {
                        Write-LocalHistoryEvent 'update_installed'
                        [void](Request-SmartNotification 'update_installed' $notificationResultStamp)
                        $UpdateStatusText.Text = "Updated successfully - $([string]$result.version)"
                        $UpdateStatusText.Foreground = Get-Brush 'Green'
                        $UpdateDetailText.Text = if ($recoveredPrevious) {
                            'A previous interrupted update was recovered first. The verified update was then installed and Quick Repair restarted normally.'
                        } else {
                            'The verified update was installed and Quick Repair restarted normally.'
                        }
                    }
                }
                'rolled_back' {
                    if ($success) { throw 'Invalid update result state.' }
                    Write-LocalHistoryEvent 'update_failed'
                    [void](Request-SmartNotification 'update_attention' $notificationResultStamp)
                    $UpdateStatusText.Text = 'Update rolled back safely'
                    $UpdateStatusText.Foreground = Get-Brush 'Amber'
                    $UpdateDetailText.Text = 'The update did not complete. The verified previous files were restored and your installed version was kept.'
                }
                'recovery_required' {
                    if ($success) { throw 'Invalid update result state.' }
                    Write-LocalHistoryEvent 'update_failed'
                    [void](Request-SmartNotification 'update_attention' $notificationResultStamp)
                    $UpdateStatusText.Text = 'Update needs recovery'
                    $UpdateStatusText.Foreground = Get-Brush 'Red'
                    $UpdateDetailText.Text = 'Automatic recovery could not be verified. Recovery data was kept. Run Repair installation or the latest Setup before retrying.'
                }
                'failed' {
                    if ($success) { throw 'Invalid update result state.' }
                    Write-LocalHistoryEvent 'update_failed'
                    [void](Request-SmartNotification 'update_attention' $notificationResultStamp)
                    $UpdateStatusText.Text = 'Update not installed'
                    $UpdateStatusText.Foreground = Get-Brush 'Amber'
                    $UpdateDetailText.Text = switch ($reason) {
                        'integrity_refused' { 'The update was refused because its integrity or metadata could not be verified. No unverified update was installed.' }
                        'transport_unavailable' { 'The update download could not be completed. Nothing was installed.' }
                        'transport_timeout' { 'The update download timed out. Nothing was installed.' }
                        'feed_or_package_unavailable' { 'The selected update is not currently available. Nothing was installed.' }
                        'busy' { 'Another Quick Repair operation was already running. Nothing was installed.' }
                        default { 'The update was not installed. Nothing unverified was accepted.' }
                    }
                    if ($recoveredPrevious) {
                        $UpdateDetailText.Text = 'A previous interrupted update was recovered safely. ' + $UpdateDetailText.Text
                    }
                }
                default {
                    throw 'Unsupported update result state.'
                }
            }

            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            Remove-Item -LiteralPath $UpdateResultPath -Force -ErrorAction Stop
        }
        catch {
            # Unknown or malformed recovery evidence stays on disk for diagnosis.
        }
    }
'@

Replace-FunctionOnce 'Show-UpdateResult' $showUpdateResult

$startup = @'
                Show-UpdateResult
                [void](Get-ActiveOperationLock -RecoverStale)
'@
$startupNew = @'
                Show-UpdateResult
                [void](Get-ActiveOperationLock -RecoverStale)
                if (Invoke-PendingProtectedUpdate) {
                    return
                }
                [void](Acknowledge-ProtectedRestart)
'@
Replace-ExactOnce $startup $startupNew 'startup protected update handoff'

foreach ($required in @(
    '$ProtectedUpdateMarkerPath',
    '$RestartRegistryPath',
    '$RestartRegistryName',
    'function Invoke-PendingProtectedUpdate',
    'function Acknowledge-ProtectedRestart',
    '--requester-sid',
    '--channel "',
    '--target-code ',
    '$psi.Verb = ''runas''',
    'Update downloaded - finishing setup',
    'Acknowledge-ProtectedRestart'
)) {
    if ($text -notmatch [regex]::Escape($required)) {
        throw "Protected update handoff verification failed: $required"
    }
}

[void][scriptblock]::Create($text)
[IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Protected update handoff routing applied.'
