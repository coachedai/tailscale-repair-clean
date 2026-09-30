$ErrorActionPreference = 'SilentlyContinue'

$StateDir = Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$ConfigPath = Join-Path $StateDir 'config.json'
$StateFile = Join-Path $StateDir 'state.json'
$OperationLockPath = Join-Path $StateDir 'operation.lock'

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Get-ConfiguredPeer {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return ''
    }

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $candidate = [string]$config.peer

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            return ''
        }

        $candidate = $candidate.Trim()

        if (
            $candidate.Length -gt 255 -or
            $candidate -match '[\r\n\s]'
        ) {
            return ''
        }

        $parsed = $null

        if (-not [System.Net.IPAddress]::TryParse($candidate, [ref]$parsed)) {
            return ''
        }

        return $parsed.ToString()
    }
    catch {
        return ''
    }
}

$Peer = Get-ConfiguredPeer

$script:Diag = [ordered]@{
    client        = 'Unknown'
    service       = 'Unknown'
    startup       = 'Unknown'
    backend       = 'Unknown'
    localIp       = ''
    version       = ''
    peerName      = if ([string]::IsNullOrWhiteSpace($Peer)) { 'Target not configured' } else { 'Remote machine' }
    peerOnline    = 'Unknown'
    peerReachable = 'Unknown'
    route         = ''
    latency       = ''
}

$script:EventItems = @()
$script:RepairPerformed = $false

function Add-Event {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return }

    $line = "$(Get-Date -Format 'HH:mm:ss')  $Text"
    $script:EventItems = @($script:EventItems + $line)

    if ($script:EventItems.Count -gt 8) {
        $script:EventItems = @($script:EventItems | Select-Object -Last 8)
    }
}

function Publish-State {
    param(
        [string]$Status,
        [string]$Detail,
        [int]$Progress,
        [string]$Mode,
        [string]$Phase,
        [bool]$Done = $false
    )

    $obj = [ordered]@{
        status        = $Status
        detail        = $Detail
        progress      = $Progress
        mode          = $Mode
        phase         = $Phase
        done          = $Done
        repairPerformed = [bool]$script:RepairPerformed
        client        = $script:Diag.client
        service       = $script:Diag.service
        startup       = $script:Diag.startup
        backend       = $script:Diag.backend
        localIp       = $script:Diag.localIp
        version       = $script:Diag.version
        peerName      = $script:Diag.peerName
        peerOnline    = $script:Diag.peerOnline
        peerReachable = $script:Diag.peerReachable
        route         = $script:Diag.route
        latency       = $script:Diag.latency
        events        = @($script:EventItems)
        updatedUtc    = [DateTime]::UtcNow.ToString('o')
    }

    $tmp = $StateFile + '.tmp'
    $obj | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StateFile -Force
}

function Acquire-OperationLock {
    param([string]$Kind = 'repair')
    try {
        if (-not ('Tqr.OperationGate' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'TailscaleQuickRepair.Operations.dll') -ErrorAction Stop
        }
        $script:repairOperationLease = [Tqr.OperationGate]::TryAcquire($StateDir, $Kind)
        return ($null -ne $script:repairOperationLease)
    }
    catch { return $false }
}

function Release-OperationLock {
    if ($script:repairOperationLease) {
        $script:repairOperationLease.Dispose()
        $script:repairOperationLease = $null
    }
}

function Get-TailscaleCli {
    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe",
        "$env:LOCALAPPDATA\Tailscale\tailscale.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Get-TailscaleGuiPath {
    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale-ipn.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale-ipn.exe",
        "$env:LOCALAPPDATA\Tailscale\tailscale-ipn.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    try {
        $runValue = (Get-ItemProperty `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
            -Name 'Tailscale' `
            -ErrorAction SilentlyContinue).Tailscale

        if ($runValue) {
            $candidate = $runValue.Trim()

            if ($candidate.StartsWith('"')) {
                $candidate = ($candidate -split '"')[1]
            } else {
                $candidate = ($candidate -split '\s+')[0]
            }

            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    } catch {}

    return $null
}

function Test-TailscaleGuiRunning {
    return [bool](Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue)
}

function Start-TailscaleGui {
    if (Test-TailscaleGuiRunning) {
        return $true
    }

    $guiPath = Get-TailscaleGuiPath
    if (-not $guiPath) {
        return $false
    }

    try {
        Start-Process -FilePath $guiPath -ErrorAction Stop | Out-Null

        $deadline = (Get-Date).AddSeconds(8)
        do {
            if (Test-TailscaleGuiRunning) {
                return $true
            }

            Start-Sleep -Milliseconds 400
        } while ((Get-Date) -lt $deadline)
    } catch {}

    return (Test-TailscaleGuiRunning)
}

function Restart-TailscaleGui {
    try {
        Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}

    Start-Sleep -Seconds 1
    return (Start-TailscaleGui)
}

function Get-ServiceStartupMode {
    try {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tailscale'
        $startValue = (Get-ItemProperty -LiteralPath $path -Name Start -ErrorAction Stop).Start

        switch ([int]$startValue) {
            2 { return 'Automatic' }
            3 { return 'Manual' }
            4 { return 'Disabled' }
            default { return 'Unknown' }
        }
    }
    catch {}

    return 'Unknown'
}

function Get-ServiceState {
    $serviceObj = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if (-not $serviceObj) { return 'Missing' }

    return [string]$serviceObj.Status
}

function Get-TailscaleSnapshot {
    param([string]$Cli)

    if (-not $Cli) { return $null }

    try {
        $raw = & $Cli status --json 2>$null

        if ($LASTEXITCODE -ne 0 -or -not $raw) {
            return $null
        }

        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-BackendState {
    param([object]$Snapshot)

    if (-not $Snapshot) { return 'Unavailable' }

    if ($Snapshot.PSObject.Properties.Name -contains 'BackendState') {
        return [string]$Snapshot.BackendState
    }

    return 'Unknown'
}

function Get-BackendAttention {
    param([string]$BackendState)

    switch ($BackendState) {
        'NeedsLogin' {
            return [pscustomobject]@{
                ExitCode = 13
                Status = 'Tailscale needs sign-in'
                Detail = 'This device needs to be signed in before connectivity can be restored.'
            }
        }
        'Stopped' {
            return [pscustomobject]@{
                ExitCode = 14
                Status = 'Tailscale is disconnected'
                Detail = 'The app is open but Tailscale is intentionally disconnected. Connect it from the tray, then run the check again.'
            }
        }
        'NeedsMachineAuth' {
            return [pscustomobject]@{
                ExitCode = 15
                Status = 'Tailscale needs approval'
                Detail = 'This device needs approval before connectivity can be restored. Quick Repair will not change the service or network adapter while approval is pending.'
            }
        }
        'InUseOtherUser' {
            return [pscustomobject]@{
                ExitCode = 16
                Status = 'Tailscale is in use by another user'
                Detail = 'Another Windows user currently owns the Tailscale session. Quick Repair will not change the service or network adapter.'
            }
        }
    }

    if ($BackendState -notin @('Running','NoState','Starting','Unavailable')) {
        return [pscustomobject]@{
            ExitCode = 17
            Status = 'Tailscale needs attention'
            Detail = 'Tailscale reported a backend state that Quick Repair does not recognise. No service or network-adapter recovery was attempted.'
        }
    }

    return $null
}

function Complete-BackendAttention {
    param(
        [string]$BackendState,
        [string]$Cli
    )

    $attention = Get-BackendAttention $BackendState
    if (-not $attention) { return 0 }

    [void](Refresh-Diagnostics $Cli)
    Publish-State ([string]$attention.Status) ([string]$attention.Detail) 100 'warning' 'Complete' $true
    return [int]$attention.ExitCode
}
function Get-PeerInfo {
    param(
        [object]$Snapshot,
        [string]$Address
    )

    if (-not $Snapshot -or -not $Snapshot.Peer) {
        return $null
    }

    foreach ($property in $Snapshot.Peer.PSObject.Properties) {
        $peerObj = $property.Value

        if ($peerObj -and $peerObj.TailscaleIPs -and ($peerObj.TailscaleIPs -contains $Address)) {
            return $peerObj
        }
    }

    return $null
}

function Refresh-Diagnostics {
    param([string]$Cli)

    $script:Diag.client = if (Test-TailscaleGuiRunning) { 'Running' } else { 'Closed' }
    $script:Diag.service = Get-ServiceState
    $script:Diag.startup = Get-ServiceStartupMode

    if (-not $Cli) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($script:Diag.version)) {
        try {
            $firstLine = (& $Cli version 2>$null | Select-Object -First 1)

            if ($firstLine) {
                $script:Diag.version = ([string]$firstLine).Trim()
            }
        } catch {}
    }

    $snapshot = Get-TailscaleSnapshot $Cli
    $script:Diag.backend = Get-BackendState $snapshot

    if ($snapshot) {
        try {
            if ($snapshot.Self -and $snapshot.Self.TailscaleIPs) {
                $ipv4 = @($snapshot.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)

                if ($ipv4.Count -gt 0) {
                    $script:Diag.localIp = [string]$ipv4[0]
                } elseif ($snapshot.Self.TailscaleIPs.Count -gt 0) {
                    $script:Diag.localIp = [string]$snapshot.Self.TailscaleIPs[0]
                }
            }
        } catch {}

        $peerInfo = if ([string]::IsNullOrWhiteSpace($Peer)) {
            $null
        } else {
            Get-PeerInfo $snapshot $Peer
        }

        if ($peerInfo) {
            try {
                if ($peerInfo.HostName) {
                    $script:Diag.peerName = [string]$peerInfo.HostName
                } elseif ($peerInfo.DNSName) {
                    $script:Diag.peerName = ([string]$peerInfo.DNSName).TrimEnd('.')
                }
            } catch {}

            try {
                if ($peerInfo.PSObject.Properties.Name -contains 'Online') {
                    $script:Diag.peerOnline = if ([bool]$peerInfo.Online) { 'Online' } else { 'Offline' }
                }
            } catch {}
        } else {
            $script:Diag.peerOnline = 'Unknown'
        }
    }

    return $snapshot
}

function Wait-ServiceState {
    param(
        [string]$Wanted,
        [int]$Seconds = 20
    )

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        $serviceObj = Get-Service -Name Tailscale -ErrorAction SilentlyContinue

        if (-not $serviceObj) {
            return $false
        }

        if ([string]$serviceObj.Status -eq $Wanted) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-TailscaleBackend {
    param(
        [string]$Cli,
        [int]$Seconds = 15
    )

    $lastState = 'Unavailable'
    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        $snapshot = Refresh-Diagnostics $Cli
        $lastState = $script:Diag.backend

        if ($lastState -eq 'Running') {
            return 'Running'
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $lastState
}

function Restart-TailscaleService {
    param([string]$Cli)

    Publish-State `
        'Restarting Tailscale service' `
        'Restarting only the Tailscale Windows service.' `
        54 'repairing' 'Service recovery'

    $serviceObj = Get-Service -Name Tailscale -ErrorAction SilentlyContinue

    if (-not $serviceObj) {
        return $false
    }

    if ((Get-ServiceStartupMode) -eq 'Disabled') {
        try {
            Set-Service -Name Tailscale -StartupType Automatic -ErrorAction Stop
        }
        catch {
            & sc.exe config Tailscale start= auto *> $null
        }

        if ((Get-ServiceStartupMode) -ne 'Disabled') {
            $script:Diag.startup = Get-ServiceStartupMode
            $script:RepairPerformed = $true
            Add-Event 'Tailscale service re-enabled'
        }
    }

    if ($serviceObj.Status -ne 'Stopped') {
        Stop-Service -Name Tailscale -Force -ErrorAction SilentlyContinue
        [void](Wait-ServiceState 'Stopped' 20)
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Start-Service -Name Tailscale -ErrorAction SilentlyContinue

        if (Wait-ServiceState 'Running' 20) {
            $script:Diag.service = 'Running'

            if (-not (Test-TailscaleGuiRunning)) {
                [void](Start-TailscaleGui)
            }

            $script:RepairPerformed = $true
            Add-Event 'Tailscale service restarted'
            Start-Sleep -Seconds 2
            [void](Refresh-Diagnostics $Cli)
            return $true
        }

        if ($attempt -lt 3) {
            Start-Sleep -Seconds 2
        }
    }

    return $false
}

function Get-TailscaleNetworkAdapters {
    # Fail closed to the vendor-controlled interface description. Friendly
    # adapter names are user-editable and must never widen repair scope.
    return @(
        Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object {
                ([string]$_.InterfaceDescription) -ieq 'Tailscale Tunnel'
            }
    )
}

function Repair-TailscaleAdapter {
    param([string]$Cli)

    Publish-State `
        'Refreshing Tailscale' `
        'Refreshing only the Tailscale network adapter. Other Windows networking is left alone.' `
        70 'repairing' 'Adapter recovery'

    $adapters = @(Get-TailscaleNetworkAdapters)

    if ($adapters.Count -gt 0) {
        foreach ($adapter in $adapters) {
            Disable-NetAdapter `
                -InputObject $adapter `
                -Confirm:$false `
                -ErrorAction SilentlyContinue
        }

        Start-Sleep -Seconds 2

        foreach ($adapter in $adapters) {
            Enable-NetAdapter `
                -InputObject $adapter `
                -Confirm:$false `
                -ErrorAction SilentlyContinue
        }

        Start-Sleep -Seconds 2
        $script:RepairPerformed = $true
        Add-Event 'Tailscale adapter refreshed'
    }

    return (Restart-TailscaleService $Cli)
}

function Get-PeerConnectivity {
    param(
        [string]$Cli,
        [string]$Address
    )

    $result = [ordered]@{
        reachable = $false
        route     = ''
        latency   = ''
    }

    if (-not $Cli) {
        return [pscustomobject]$result
    }

    try {
        $outputText = (& $Cli ping '--until-direct=false' '--c=1' '--timeout=5s' $Address 2>&1 | Out-String).Trim()
        $result.reachable = ($LASTEXITCODE -eq 0)

        if ($outputText -match 'in\s+([0-9.]+)\s*ms') {
            $result.latency = "$($Matches[1]) ms"
        }

        if ($outputText -match 'via\s+DERP\(([^)]+)\)') {
            $result.route = "Relay · $($Matches[1].ToUpper())"
        } elseif ($outputText -match '\svia\s+\S+') {
            $result.route = 'Direct'
        }

        if ($result.reachable -and [string]::IsNullOrWhiteSpace($result.route)) {
            $result.route = 'Connected'
        }
    } catch {}

    return [pscustomobject]$result
}

$operationAcquired = Acquire-OperationLock -Kind 'repair'
if (-not $operationAcquired) {
    # A rejected contender must not overwrite the current owner's result.
    exit 75
}

try {
    Publish-State `
        'Checking Tailscale' `
        'Checking the desktop client, Windows service and Tailscale backend.' `
        8 'checking' 'App'

    $serviceObj = Get-Service -Name Tailscale -ErrorAction SilentlyContinue

    if (-not $serviceObj) {
        $script:Diag.service = 'Missing'
        Publish-State `
            'Tailscale service not found' `
            'The Windows Tailscale service is missing. Repair or reinstall Tailscale first.' `
            100 'failure' 'Complete' $true
        exit 20
    }

    $cli = Get-TailscaleCli

    if (-not $cli) {
        Publish-State `
            'Tailscale installation not found' `
            'tailscale.exe could not be located. Repair or reinstall Tailscale first.' `
            100 'failure' 'Complete' $true
        exit 21
    }

    $snapshot = Refresh-Diagnostics $cli
    Publish-State `
        'Checking Tailscale' `
        'Checking the desktop client, Windows service and Tailscale backend.' `
        12 'checking' 'App'

    $clientWasClosed = -not (Test-TailscaleGuiRunning)

    if ($clientWasClosed) {
        Publish-State `
            'Opening Tailscale' `
            'The desktop client was closed, so it is being reopened automatically.' `
            18 'repairing' 'App'

        if (-not (Start-TailscaleGui)) {
            $script:Diag.client = 'Closed'
            Publish-State `
                'Could not open Tailscale' `
                'The Tailscale desktop client could not be started automatically.' `
                100 'failure' 'Complete' $true
            exit 22
        }

        $script:Diag.client = 'Running'
        $script:RepairPerformed = $true
        Add-Event 'Desktop client reopened'
    }

    $serviceState = Get-ServiceState
    $script:Diag.service = $serviceState
    $script:Diag.startup = Get-ServiceStartupMode

    if ($serviceState -ne 'Running' -and $script:Diag.startup -eq 'Disabled') {
        Publish-State `
            'Enabling Tailscale service' `
            'The Tailscale Windows service was disabled. Restoring its normal startup configuration.' `
            24 'repairing' 'Service'

        try {
            Set-Service -Name Tailscale -StartupType Automatic -ErrorAction Stop
        }
        catch {
            & sc.exe config Tailscale start= auto *> $null
        }

        $script:Diag.startup = Get-ServiceStartupMode

        if ($script:Diag.startup -eq 'Disabled') {
            Publish-State `
                'Tailscale service is disabled' `
                'The service is disabled and Windows would not allow the repair tool to re-enable it.' `
                100 'failure' 'Complete' $true
            exit 23
        }

        $script:RepairPerformed = $true
        Add-Event 'Tailscale service re-enabled'
    }

    if ($serviceState -ne 'Running') {
        Publish-State `
            'Starting Tailscale service' `
            "The Windows service is $serviceState. Starting it now." `
            28 'repairing' 'Service'

        Start-Service -Name Tailscale -ErrorAction SilentlyContinue

        if (Wait-ServiceState 'Running' 20) {
            $script:Diag.service = 'Running'
            $script:RepairPerformed = $true
            Add-Event 'Tailscale service started'
        } elseif (-not (Restart-TailscaleService $cli)) {
            Publish-State `
                'Tailscale service would not start' `
                'The Windows service did not reach Running state after retrying.' `
                100 'failure' 'Complete' $true
            exit 30
        }
    }

    [void](Refresh-Diagnostics $cli)

    Publish-State `
        'Connecting Tailscale' `
        'Waiting for the Tailscale backend to become ready.' `
        40 'checking' 'Tailscale'

    $backendState = Wait-TailscaleBackend $cli 12

    if ($backendState -eq 'NoState' -or
        $backendState -eq 'Starting' -or
        $backendState -eq 'Unavailable') {

        Publish-State `
            'Restarting Tailscale app' `
            "The desktop client is running but the backend is '$backendState'. Restarting only the client first." `
            48 'repairing' 'Tailscale'

        if (Restart-TailscaleGui) {
            $script:Diag.client = 'Running'
            $script:RepairPerformed = $true
            Add-Event 'Desktop client restarted'
        }

        $backendState = Wait-TailscaleBackend $cli 12
    }

    $attentionExit = Complete-BackendAttention $backendState $cli
    if ($attentionExit -gt 0) { exit $attentionExit }

    if ($backendState -ne 'Running') {
        if (-not (Restart-TailscaleService $cli)) {
            [void](Refresh-Diagnostics $cli)

            Publish-State `
                'Tailscale could not recover' `
                'The Tailscale service could not be restarted successfully.' `
                100 'failure' 'Complete' $true
            exit 30
        }

        Publish-State `
            'Reconnecting Tailscale' `
            'The service restarted successfully. Waiting for the backend to reconnect.' `
            62 'checking' 'Tailscale'

        $backendState = Wait-TailscaleBackend $cli 15
        $attentionExit = Complete-BackendAttention $backendState $cli
        if ($attentionExit -gt 0) { exit $attentionExit }
    }

    if ($backendState -ne 'Running') {
        [void](Repair-TailscaleAdapter $cli)

        if (-not (Test-TailscaleGuiRunning)) {
            [void](Start-TailscaleGui)
        }

        Publish-State `
            'Finalising recovery' `
            'The Tailscale adapter was refreshed. Waiting for the backend one final time.' `
            76 'checking' 'Tailscale'

        $backendState = Wait-TailscaleBackend $cli 15
        $attentionExit = Complete-BackendAttention $backendState $cli
        if ($attentionExit -gt 0) { exit $attentionExit }
    }

    [void](Refresh-Diagnostics $cli)

    if ($backendState -ne 'Running') {
        Publish-State `
            'Tailscale is still unavailable' `
            "The service and client are running, but the backend still reports '$backendState'. No Windows-wide network reset was performed." `
            100 'failure' 'Complete' $true
        exit 31
    }

    if ([string]::IsNullOrWhiteSpace($Peer)) {
        $script:Diag.peerName = 'Target not configured'
        $script:Diag.peerOnline = 'Not configured'
        $script:Diag.peerReachable = 'Not configured'
        $script:Diag.route = ''
        $script:Diag.latency = ''

        Publish-State `
            'Tailscale is healthy' `
            'Local Tailscale is working normally. Choose a target Tailscale IP in Quick Repair to verify a remote device.' `
            100 'success' 'Complete' $true
        exit 0
    }

    Publish-State `
        'Checking the other machine' `
        "Tailscale is healthy. Testing $Peer now." `
        88 'checking' 'Peer'

    $connection = Get-PeerConnectivity $cli $Peer

    if ($connection.reachable) {
        $script:Diag.peerReachable = 'Reachable'
        $script:Diag.route = [string]$connection.route
        $script:Diag.latency = [string]$connection.latency
        $script:Diag.peerOnline = 'Online'

        if ($script:Diag.route) {
            Add-Event "Peer reachable via $($script:Diag.route)"
        } else {
            Add-Event 'Peer reachable'
        }

        $routeIsRelay = ([string]$script:Diag.route -like 'Relay*')

        if ($clientWasClosed) {
            Publish-State `
                'Tailscale restored' `
                'The desktop client was closed. It was reopened automatically and the other machine is reachable again.' `
                100 'success' 'Complete' $true
        } elseif ($script:RepairPerformed) {
            Publish-State `
                'Tailscale repaired' `
                'A Tailscale issue was corrected and the other machine is reachable again.' `
                100 'success' 'Complete' $true
        } elseif ($routeIsRelay) {
            Publish-State `
                'Everything is healthy' `
                'No repair was needed. The other machine is reachable through a Tailscale relay rather than a direct path.' `
                100 'success' 'Complete' $true
        } else {
            Publish-State `
                'Everything is healthy' `
                'No repair was needed. Tailscale and the other machine are working normally.' `
                100 'success' 'Complete' $true
        }

        exit 0
    }

    $script:Diag.peerReachable = 'Unreachable'
    $snapshot = Refresh-Diagnostics $cli
    $peerInfo = Get-PeerInfo $snapshot $Peer

    if (-not $peerInfo) {
        Publish-State `
            'This PC is healthy' `
            'The other machine is not present in current tailnet status. It may be signed out, removed or connected elsewhere.' `
            100 'warning' 'Complete' $true
        exit 11
    }

    if (($peerInfo.PSObject.Properties.Name -contains 'Online') -and
        $peerInfo.Online -eq $false) {

        $script:Diag.peerOnline = 'Offline'

        Publish-State `
            'The other machine is offline' `
            'Tailscale on this PC is healthy. The remote machine is currently reported offline.' `
            100 'warning' 'Complete' $true
        exit 12
    }

    if (
        ($peerInfo.PSObject.Properties.Name -contains 'Online') -and
        $peerInfo.Online -eq $true
    ) {
        Publish-State `
            'Recovering the Tailscale path' `
            'The other machine is online but did not respond. Restarting only the Tailscale service once to clear a stale VPN/network path.' `
            92 'repairing' 'Peer recovery'

        Add-Event 'Peer online but unreachable; Tailscale service recycle started'

        if (Restart-TailscaleService $cli) {
            $backendState = Wait-TailscaleBackend $cli 15
            $attentionExit = Complete-BackendAttention $backendState $cli
            if ($attentionExit -gt 0) { exit $attentionExit }

            if ($backendState -eq 'Running') {
                Publish-State `
                    'Rechecking the other machine' `
                    'Tailscale restarted successfully. Verifying the remote machine again.' `
                    96 'checking' 'Peer'

                $retryConnection = Get-PeerConnectivity $cli $Peer

                if ($retryConnection.reachable) {
                    $script:Diag.peerReachable = 'Reachable'
                    $script:Diag.peerOnline = 'Online'
                    $script:Diag.route = [string]$retryConnection.route
                    $script:Diag.latency = [string]$retryConnection.latency

                    Add-Event 'Stale peer path cleared by restarting the Tailscale service'

                    Publish-State `
                        'Tailscale repaired' `
                        'The other machine was online but the route was stale. Restarting the Tailscale service restored connectivity.' `
                        100 'success' 'Complete' $true
                    exit 0
                }
            }
        }

        Add-Event 'Tailscale service recycle did not restore peer connectivity'
    }

    Publish-State `
        'The other machine did not respond' `
        'Tailscale on this PC is running, but the remote machine is still unreachable after targeted recovery.' `
        100 'failure' 'Complete' $true
    exit 40
}
catch {
    Publish-State `
        'Unexpected repair error' `
        $_.Exception.Message `
        100 'failure' 'Complete' $true
    exit 99
}
finally {
    if ($operationAcquired) { Release-OperationLock }
}
