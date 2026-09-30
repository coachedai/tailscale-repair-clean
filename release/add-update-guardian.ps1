param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
$pattern='(?s)    function Show-UpdateResult \{.*?\r?\n    function Update-HeroAndAction \{'
$matches=[regex]::Matches($text,$pattern)
if($matches.Count -ne 1){throw 'Update Guardian result renderer anchor is missing or ambiguous.'}
$replacement=@'
    function Show-UpdateResult {
        if (-not (Test-Path -LiteralPath $UpdateResultPath -PathType Leaf)) {
            return
        }

        try {
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
                    $UpdateStatusText.Text = "Updated successfully - $([string]$result.version)"
                    $UpdateStatusText.Foreground = Get-Brush 'Green'
                    $UpdateDetailText.Text = if ($recoveredPrevious) {
                        'A previous interrupted update was recovered first. The verified update was then installed and Quick Repair restarted normally.'
                    } else {
                        'The verified update was installed and Quick Repair restarted normally.'
                    }
                }
                'rolled_back' {
                    if ($success) { throw 'Invalid update result state.' }
                    $UpdateStatusText.Text = 'Update rolled back safely'
                    $UpdateStatusText.Foreground = Get-Brush 'Amber'
                    $UpdateDetailText.Text = 'The update did not complete. The verified previous files were restored and your installed version was kept.'
                }
                'recovery_required' {
                    if ($success) { throw 'Invalid update result state.' }
                    $UpdateStatusText.Text = 'Update needs recovery'
                    $UpdateStatusText.Foreground = Get-Brush 'Red'
                    $UpdateDetailText.Text = 'Automatic recovery could not be verified. Recovery data was kept. Run Repair installation or the latest Setup before retrying.'
                }
                'failed' {
                    if ($success) { throw 'Invalid update result state.' }
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
            # Malformed or unknown recovery evidence is retained rather than
            # discarded or rendered as a misleading success/rollback claim.
        }
    }

    function Update-HeroAndAction {
'@
$text=[regex]::Replace($text,$pattern,$replacement,1)
[void][scriptblock]::Create($text)
[IO.File]::WriteAllText($Path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Update Guardian 2.0 recovery result presentation applied.'
