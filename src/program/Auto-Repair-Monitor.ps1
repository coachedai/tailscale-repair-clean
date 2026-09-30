$ErrorActionPreference = 'Stop'

# Fixed protected entry. No fixture switch, caller-supplied path, normal repair
# task invocation, peer argument or self-elevation route exists here.
function Invoke-AutoRepairWorker {
    $root = Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
    $library = Join-Path $PSScriptRoot 'TailscaleQuickRepair.Operations.dll'
    Add-Type -Path $library -ErrorAction Stop
    if ([Tqr.AutoRepairPolicyStore]::ReadEnabled($root) -ne $true) { return }
    $machine = New-Object Tqr.WindowsAutoRepairMachine
    $result = [Tqr.AutoRepairWorker]::ExecuteScheduled($root,$machine)
    if ($result.status -in @('manual','error')) { throw 'Automatic recovery needs attention.' }
}

try { Invoke-AutoRepairWorker; exit 0 }
catch { exit 20 } # Never print private exception details or overwrite evidence.
