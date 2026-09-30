param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$script:text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
function Replace-One([string]$Old,[string]$New) {
    if([regex]::Matches($script:text,[regex]::Escape($Old)).Count -ne 1){throw ('Progress reset anchor missing or duplicated: '+$Old.Substring(0,[Math]::Min(100,$Old.Length)))}
    $script:text=$script:text.Replace($Old,$New)
}
function Replace-Function([string]$Name,[string]$Replacement) {
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($script:text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Input package must parse.'}
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw "Expected exactly one $Name function."}
    $e=$nodes[0].Extent
    $script:text=$script:text.Remove($e.StartOffset,$e.EndOffset-$e.StartOffset).Insert($e.StartOffset,$Replacement)
}
Replace-One @'
    $script:launchUtc = [DateTime]::UtcNow
    $script:lastFreshStateUtc = $null
'@ @'
    $script:launchUtc = [DateTime]::UtcNow
    $script:repairResultNotBeforeUtc=$script:launchUtc
    $script:lastAcceptedRepairStampUtc=[DateTime]::MinValue
    $script:lastFreshStateUtc = $null
'@
Replace-One '    function Show-ImmediateRunState {' @'
    function Get-RepairAttachmentFloor {
        # Inspect verifies ownership; the process start bounds results from the
        # existing worker. Never use an arbitrary one-minute lookback.
        try {
            $owner=Get-ActiveOperationLock
            if($owner -and [string]$owner.kind -eq 'repair' -and [int]$owner.ownerPid -gt 0){
                $process=[Diagnostics.Process]::GetProcessById([int]$owner.ownerPid)
                try {
                    if(-not $process.HasExited){return $process.StartTime.ToUniversalTime()}
                } finally {$process.Dispose()}
            }
        } catch {}
        return [DateTime]::UtcNow
    }

    function Update-RepairObservation {
        # Main-check state has legacy timestamps, not a request ID. Require the
        # embedded UTC stamp as well as a stable file read. Do not delete evidence
        # or reset the accepted-result watermark between repeated clicks.
        try {
            if(-not (Test-Path -LiteralPath $StateFile -PathType Leaf)){return}
            $before=Get-Item -LiteralPath $StateFile -ErrorAction Stop
            if($before.Length -lt 2 -or $before.Length -gt 65536 -or
                ($before.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $before.LastWriteTimeUtc -le $script:lastAppliedStateWriteUtc){return}
            $raw=Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 -ErrorAction Stop
            if($raw.Length -gt 65536){return}
            $after=Get-Item -LiteralPath $StateFile -ErrorAction Stop
            if($before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc -or $before.Length -ne $after.Length){return}
            $data=$raw | ConvertFrom-Json -ErrorAction Stop
            $stamp=[DateTime]::MinValue
            if(-not [DateTime]::TryParseExact([string]$data.updatedUtc,'o',[Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,[ref]$stamp) -or $stamp.Kind -ne [DateTimeKind]::Utc){return}
            if($stamp -lt $script:repairResultNotBeforeUtc -or $stamp -le $script:lastAcceptedRepairStampUtc -or
                $stamp -gt [DateTime]::UtcNow.AddSeconds(5)){return}
            if($data.done -isnot [bool] -or $null -eq $data.progress -or
                [double]$data.progress -lt 0 -or [double]$data.progress -gt 100 -or
                [double]::IsNaN([double]$data.progress)){return}
            if($data.PSObject.Properties.Name -contains 'peer' -and [string]$data.peer -ine [string]$Peer){return}
            $script:lastAppliedStateWriteUtc=$after.LastWriteTimeUtc
            $script:lastAcceptedRepairStampUtc=$stamp
            $script:lastFreshStateUtc=[DateTime]::UtcNow
            Apply-State $data
        } catch {}
    }

    function Reset-AdvancedProgress {
        # Set the start value before the panel can render. This deliberately uses
        # no progress animation: the fill tracks measured worker state only.
        $AdvancedDiagnosticsProgress.IsIndeterminate=$false
        $AdvancedDiagnosticsProgress.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty,$null)
        $AdvancedDiagnosticsProgress.Value=0
        $script:advancedProgressStampUtc=[DateTime]::MinValue
        $AdvancedDiagnosticsProgress.ApplyTemplate() | Out-Null
        $AdvancedDiagnosticsProgress.UpdateLayout()
    }

    function Show-ImmediateRunState {
'@
Replace-One @'
        $script:launchUtc = [DateTime]::UtcNow
        $script:runStartedAt = Get-Date
'@ @'
        $script:launchUtc = [DateTime]::UtcNow
        $script:repairResultNotBeforeUtc=$script:launchUtc
        $script:runStartedAt = Get-Date
'@
Replace-One @'
        $script:notifiedForCurrentRun = $false
        $script:lastFreshStateUtc = $null
        $script:lastAppliedStateWriteUtc = [DateTime]::MinValue
'@ @'
        $script:notifiedForCurrentRun = $false
        $script:lastFreshStateUtc = $null
        # Keep the last accepted file/stamp across a new check.
'@
Replace-One @'
        $script:lastAppliedStateWriteUtc = [DateTime]::MinValue
        $script:launchUtc = [DateTime]::UtcNow

        $HeroDetail.Text = 'Starting the protected check.'
'@ @'
        # Show-ImmediateRunState established this request's boundary before
        # dispatching native work. Do not clear it or replay the previous result.
        $HeroDetail.Text = 'Starting the protected check.'
'@
Replace-Function 'Attach-To-RunningRepair' @'
function Attach-To-RunningRepair {
        if((Get-RepairTaskState) -notin @('Running','Queued')){return $false}
        $floor=Get-RepairAttachmentFloor
        # A worker can still be exiting after its terminal result was displayed.
        # Keep that result rather than flashing checking/completed for the same run.
        if($script:lastData -and [bool]$script:lastData.done -and
            $script:lastAcceptedRepairStampUtc -ge $floor){return $true}
        Show-ImmediateRunState
        $script:repairResultNotBeforeUtc=$floor
        $HeroDetail.Text='A check is already running. Waiting for its current result.'
        return $true
    }
'@
Replace-One @'
    function Start-Repair {
        if ($script:repairActive) {
            return
        }

        $activeOperation
'@ @'
    function Start-Repair {
        if ($script:repairActive) {
            return
        }
        if(Attach-To-RunningRepair){return}

        $activeOperation
'@
Replace-One @'
            if (Test-Path -LiteralPath $StateFile) {
                $stateItem = Get-Item -LiteralPath $StateFile -ErrorAction Stop

                if (
                    $stateItem.LastWriteTimeUtc -ge $script:launchUtc.AddSeconds(-1) -and
                    $stateItem.LastWriteTimeUtc -gt $script:lastAppliedStateWriteUtc
                ) {
                    $data = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop |
                        ConvertFrom-Json -ErrorAction Stop

                    $script:lastAppliedStateWriteUtc = $stateItem.LastWriteTimeUtc
                    $script:lastFreshStateUtc = [DateTime]::UtcNow
                    Apply-State $data
                }
            }
'@ @'
            Update-RepairObservation
'@
Replace-One @'
            $script:lastAppliedStateWriteUtc = [DateTime]::MinValue
            $script:lastData = $null
            Reset-Ui -SkipEngineCheck
'@ @'
            $script:repairResultNotBeforeUtc=[DateTime]::UtcNow
            $script:lastData = $null
            Reset-Ui -SkipEngineCheck
'@
# Ensure every dot has a pending state; it must not inherit a previous terminal color.
Replace-One @'
        } elseif ([int]$Data.progress -ge 88) {
            Set-Step $PeerDot $PeerStep 'active'
        }
'@ @'
        } elseif ([int]$Data.progress -ge 88) {
            Set-Step $PeerDot $PeerStep 'active'
        } else {
            Set-Step $PeerDot $PeerStep 'idle'
        }
'@
Replace-One @'
            Remove-Item `
                -LiteralPath $AdvancedDiagnosticsStateFile `
                -Force `
                -ErrorAction SilentlyContinue

            $AdvancedDiagnosticsPanel.Visibility
'@ @'
            # Preserve the previous result file. The new run ID excludes it.
            Reset-AdvancedProgress

            $AdvancedDiagnosticsPanel.Visibility
'@
Replace-One '            $AdvancedDiagnosticsProgress.Value = 2' '            # Progress stays at zero until this worker publishes its first step.'
Replace-One @'
                                    Background="{StaticResource Border}"/>

                                <Grid Margin="0,16,0,0">
'@ @'
                                    Background="{StaticResource Border}">
                                    <ProgressBar.Template>
                                        <ControlTemplate TargetType="{x:Type ProgressBar}">
                                            <Grid ClipToBounds="True" SnapsToDevicePixels="True">
                                                <Border x:Name="PART_Track" Background="{TemplateBinding Background}"/>
                                                <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}"/>
                                            </Grid>
                                        </ControlTemplate>
                                    </ProgressBar.Template>
                                </ProgressBar>

                                <Grid Margin="0,16,0,0">
'@
[void][scriptblock]::Create($script:text)
[IO.File]::WriteAllText($Path,$script:text,(New-Object Text.UTF8Encoding($true)))
Write-Host 'Repeated-check state isolation and measured-progress reset applied.'
