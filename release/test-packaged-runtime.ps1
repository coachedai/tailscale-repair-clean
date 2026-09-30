param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$EvidenceDirectory = '.\test-evidence',
    [string]$LegacyDirectory = ''
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'These gates require native Windows PowerShell 5.1, not a substitute runtime.'
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Web.Extensions
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$script:results = New-Object 'Collections.Generic.List[object]'
$root = Join-Path $env:TEMP ('TQR-NativeGate-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Assert-That([bool]$Value,[string]$Name) {
    if (-not $Value) { throw "FAILED: $Name; Guardian detail: $($global:GuardianDetailText.Text)" }
    $script:results.Add([pscustomobject]@{name=$Name;passed=$true})
    Write-Host "PASS: $Name"
}
function Json-Write([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
}
try {
    $normalZip = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-*.zip' -File | Where-Object Name -notlike '*SetupPackage*')
    $setupZip = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'TailscaleQuickRepair-SetupPackage-*.zip' -File)
    Assert-That ($normalZip.Count -eq 1 -and $setupZip.Count -eq 1) 'Both exact delivery packages exist'
    $normal = Join-Path $root 'normal'
    $setup = Join-Path $root 'setup'
    Expand-Archive -LiteralPath $normalZip[0].FullName -DestinationPath $normal
    Expand-Archive -LiteralPath $setupZip[0].FullName -DestinationPath $setup
    $normalUi = [IO.File]::ReadAllText((Join-Path $normal 'app\Tailscale-Repair-UI.ps1'))
    $setupUi = [IO.File]::ReadAllText((Join-Path $setup 'app\Tailscale-Repair-UI.ps1'))
    $mojibakeLead = [string][char]0x00C2
    Assert-That (-not $normalUi.Contains($mojibakeLead) -and -not $setupUi.Contains($mojibakeLead)) 'Delivered UI contains no UTF-8 mojibake lead character'
    Assert-That ($normalUi -ceq $setupUi) 'Update and protected Setup deliver the same final UI'
    Assert-That ($normalUi.Contains('x:Name="ChangeTargetButton"') -and
        $normalUi.Contains('--upgrade --channel "') -and
        $normalUi.Contains('--target-code ') -and
        $normalUi.Contains('$script:updateManifestChannel')) 'Both delivery paths retain Change Target and channel-bound protected-update routing'
    $dll = Join-Path $normal 'app\TailscaleQuickRepair.Operations.dll'
    Add-Type -Path $dll
    $expectedVersion = Get-Content (Join-Path $normal 'version.json') -Raw | ConvertFrom-Json

    if ($LegacyDirectory) {
        $oldSetupZip = @(Get-ChildItem $LegacyDirectory -Filter '*SetupPackage-*.zip')
        $oldNormalZip = @(Get-ChildItem $LegacyDirectory -Filter 'TailscaleQuickRepair-*.zip' | Where-Object Name -notlike '*SetupPackage*')
        Assert-That ($oldSetupZip.Count -eq 1 -and $oldNormalZip.Count -eq 1) 'Previous released packages retained for regression evidence'
        $old = Join-Path $root 'old-setup'
        $oldNormal = Join-Path $root 'old-normal'
        Expand-Archive $oldSetupZip[0].FullName $old
        Expand-Archive $oldNormalZip[0].FullName $oldNormal
        Assert-That ((-not (Test-Path (Join-Path $old 'app\integrity-manifest.json'))) -and (Test-Path (Join-Path $oldNormal 'app\integrity-manifest.json'))) 'Reproduced 3.4.1: Setup omits metadata present in the ordinary update'
    }

    # Execute the exact final packaged event, through a native WPF Button event.
    # Network/service/task/startup probes are fixture stubs, never production operations.
    function global:Get-Brush([string]$Name) {
        switch ($Name) {
            'Blue' { [Windows.Media.Brushes]::Blue }
            'Green' { [Windows.Media.Brushes]::Green }
            'Amber' { [Windows.Media.Brushes]::Orange }
            default { [Windows.Media.Brushes]::Gray }
        }
    }
    function global:Test-StartWithWindows { return $false }
    function global:Test-RepairEngine { [pscustomobject]@{Healthy=$true;Message='Fixture integration'} }
    function global:Test-AutoRepairAvailable { return $true }
    function global:Initialize-OperationGate { if (-not ('Tqr.OperationGate' -as [type])) { throw 'Operations library missing' } }
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($normalUi,[ref]$tokens,[ref]$parseErrors)
    Assert-That ($parseErrors.Count -eq 0) 'Final packaged PowerShell parses on 5.1'
    $handlerNodes=@($ast.FindAll({param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Expression.Extent.Text -ceq '$GuardianCheckButton' -and $n.Member.Value -eq 'Add_Click'
    },$true))
    Assert-That ($handlerNodes.Count -eq 1) 'Exactly one delivered Guardian click handler'
    # History is a real packaged dependency of Guardian; do not stub it away.
    foreach ($name in @('Initialize-LocalHistory','Write-LocalHistoryEvent','Request-SmartNotification')) {
        $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Assert-That ($functions.Count -eq 1) "Packaged history dependency exists: $name"
        . ([scriptblock]::Create($functions[0].Extent.Text))
    }
    $handler=$handlerNodes[0].Arguments[0].ScriptBlock.GetScriptBlock()
    $xamlMatch=[regex]::Match($normalUi,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    Assert-That $xamlMatch.Success 'Final packaged main XAML is present'

    foreach ($profile in @('setup','update-overlay')) {
        $fixture=Join-Path $root ('fixture-' + $profile)
        New-Item -ItemType Directory -Path $fixture | Out-Null
        Copy-Item (Join-Path $setup 'app') (Join-Path $fixture 'app') -Recurse
        Copy-Item (Join-Path $setup 'program') (Join-Path $fixture 'program') -Recurse
        $global:StateDir=Join-Path $fixture 'app'
        if ($profile -eq 'update-overlay') { Copy-Item (Join-Path $normal 'app\*') $global:StateDir -Force }
        # A stale manifest is deliberately seeded, then replaced through the delivery file list.
        $manifestPath=Join-Path $global:StateDir 'integrity-manifest.json'
        $manifestBytes=[IO.File]::ReadAllBytes($manifestPath)
        Json-Write $manifestPath @{schema=1;versionCode=1;algorithm='SHA256';files=@()}
        $delivery=if($profile -eq 'setup'){$setup}else{$normal}
        $packageManifest=Get-Content (Join-Path $delivery 'package-manifest.json') -Raw | ConvertFrom-Json
        foreach($entry in $packageManifest.files) {
            if ([string]$entry.path -eq 'app/integrity-manifest.json') {
                Copy-Item (Join-Path $delivery $entry.path) $manifestPath -Force
            }
        }
        Assert-That ((Get-Content $manifestPath -Raw | ConvertFrom-Json).versionCode -eq $expectedVersion.versionCode) "$profile replaces stale metadata through its actual package file list"
        Copy-Item (Join-Path $delivery 'version.json') (Join-Path $global:StateDir 'version.user.json') -Force
        $global:ConfigPath=Join-Path $global:StateDir 'config.json'
        Json-Write $global:ConfigPath @{peer='fixture-peer'}
        $global:Peer='fixture-peer'
        $global:ProductVersion=[string]$expectedVersion.version
        $global:ProductVersionCode=[int64]$expectedVersion.versionCode
        $global:NativeHostPath=Join-Path $global:StateDir 'TailscaleQuickRepair.exe'
        $global:UpdaterHostPath=Join-Path $global:StateDir 'TailscaleQuickRepairUpdater.exe'
        $global:SetupHostPath=Join-Path $global:StateDir 'TailscaleQuickRepairSetup.exe'
        $global:OperationsLibraryPath=Join-Path $global:StateDir 'TailscaleQuickRepair.Operations.dll'
        $global:AdvancedDiagnosticsPath=Join-Path $global:StateDir 'Advanced-Diagnostics.ps1'
        $global:BackendPath=Join-Path $fixture 'program\Repair-Backend.ps1'
        $global:AutoRepairMonitorPath=Join-Path $fixture 'program\Auto-Repair-Monitor.ps1'
        $global:StartMenuShortcutPath=Join-Path $fixture 'fixture.lnk'
        [IO.File]::WriteAllText($global:StartMenuShortcutPath,'fixture')
        [xml]$xaml=$xamlMatch.Groups['xaml'].Value
        $reader=New-Object Xml.XmlNodeReader $xaml
        $global:window=[Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()
        $global:GuardianStatusText=$global:window.FindName('GuardianStatusText')
        $global:GuardianDetailText=$global:window.FindName('GuardianDetailText')
        $global:GuardianCheckButton=$global:window.FindName('GuardianCheckButton')
        $global:GuardianCheckButton.Add_Click($handler)
        function Invoke-GuardianClick {
            $global:GuardianCheckButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        }
        Invoke-GuardianClick
        Assert-That ($global:GuardianStatusText.Text -eq 'Healthy') "$profile native WPF Check establishes a healthy baseline"
        $snapshotPath=Join-Path $global:StateDir 'guardian-known-good.json'
        $savedSnapshot=[IO.File]::ReadAllBytes($snapshotPath)
        Invoke-GuardianClick
        Assert-That ($global:GuardianStatusText.Text -eq 'Healthy' -and $global:GuardianDetailText.Text -match 'confirmed') "$profile native WPF Check confirms the baseline on the second click"
        $snapshotHash=(Get-FileHash $snapshotPath).Hash
        $uiPath=Join-Path $global:StateDir 'Tailscale-Repair-UI.ps1'
        $savedUi=[IO.File]::ReadAllBytes($uiPath)
        $tampered=[byte[]]$savedUi.Clone(); $tampered[$tampered.Length-1]=$tampered[$tampered.Length-1] -bxor 1
        [IO.File]::WriteAllBytes($uiPath,$tampered)
        Invoke-GuardianClick
        Assert-That ($global:GuardianStatusText.Text -ne 'Healthy' -and (Get-FileHash $snapshotPath).Hash -eq $snapshotHash) "$profile same-size corruption is detected without replacing the baseline"
        [IO.File]::WriteAllBytes($uiPath,$savedUi)
        foreach($fault in @('empty','duplicate','path','version')) {
            $bad=[Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
            switch($fault) {
                'empty' {$bad.files=@()}
                'duplicate' {$bad.files=@($bad.files)+@($bad.files[0])}
                'path' {$bad.files[0].path='../outside.txt'}
                'version' {$bad.versionCode=1}
            }
            Json-Write $manifestPath $bad
            Invoke-GuardianClick
            Assert-That ($global:GuardianStatusText.Text -ne 'Healthy' -and (Get-FileHash $snapshotPath).Hash -eq $snapshotHash) "$profile rejects $fault manifest and preserves the baseline"
        }
        [IO.File]::WriteAllBytes($manifestPath,$manifestBytes)
        [IO.File]::WriteAllText($snapshotPath,'{broken')
        Invoke-GuardianClick
        Assert-That ($global:GuardianStatusText.Text -ne 'Healthy' -and [IO.File]::ReadAllText($snapshotPath) -eq '{broken') "$profile preserves a damaged baseline instead of blessing a replacement"
        [IO.File]::WriteAllBytes($snapshotPath,$savedSnapshot)
        $held=[IO.File]::Open($snapshotPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        try { Invoke-GuardianClick; Assert-That ($global:GuardianStatusText.Text -ne 'Healthy') "$profile blocked baseline access is not reported as success" }
        finally { $held.Dispose() }
        Invoke-GuardianClick
        Assert-That ($global:GuardianStatusText.Text -eq 'Healthy') "$profile recovers after the read-only fault tests"
        Assert-That (Test-Path (Join-Path $global:StateDir 'guardian-known-good.previous.json')) "$profile atomic baseline update retains one predecessor"
        $global:window.Close()
    }

    # Native cross-process tests use only a dedicated temp directory and child
    # PowerShell processes created here. No production services/tasks are stopped.
    $leaseRoot=Join-Path $root 'leases'
    New-Item -ItemType Directory -Path $leaseRoot | Out-Null
    $marker=Join-Path $leaseRoot 'operation.lock'
    $legacy=@{schema=1;kind='repair';ownerPid=$PID;startedUtc=[DateTime]::UtcNow.AddDays(-2).ToString('o')}
    Json-Write $marker $legacy
    [IO.File]::SetLastWriteTimeUtc($marker,[DateTime]::UtcNow.AddDays(-2))
    $hash=(Get-FileHash $marker).Hash
    $lease=[Tqr.OperationGate]::TryAcquire($leaseRoot,'update')
    Assert-That ($null -eq $lease -and (Get-FileHash $marker).Hash -eq $hash) 'A live legacy owner is never evicted because its marker is old'
    Remove-Item $marker # Test-owned fixture only.
    [IO.File]::WriteAllText($marker,'{bad')
    $rejected=$false
    try {$lease=[Tqr.OperationGate]::TryAcquire($leaseRoot,'repair')} catch {$rejected=$true}
    Assert-That ($rejected -and [IO.File]::ReadAllText($marker) -eq '{bad') 'Unreadable ownership fails closed and retains evidence'
    Remove-Item $marker
    $worker=Join-Path $root 'lease-worker.ps1'
    @'
param([string]$Dll,[string]$Root,[string]$Result,[string]$Release)
$ErrorActionPreference='Stop'
Add-Type -Path $Dll
$lease=[Tqr.OperationGate]::TryAcquire($Root,'repair')
if(-not $lease){[IO.File]::WriteAllText($Result,'busy');exit 0}
try {
    [IO.File]::WriteAllText($Result,'acquired')
    $end=[DateTime]::UtcNow.AddSeconds(15)
    while(-not (Test-Path -LiteralPath $Release) -and [DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 20}
} finally {$lease.Dispose()}
'@ | Set-Content -LiteralPath $worker -Encoding UTF8
    $powershell=Join-Path $PSHOME 'powershell.exe'
    function Start-LeaseWorker([string]$Name) {
        $result=Join-Path $root ($Name+'.result')
        $release=Join-Path $root ($Name+'.release')
        $args='-NoProfile -NonInteractive -File "'+$worker+'" -Dll "'+$dll+'" -Root "'+$leaseRoot+'" -Result "'+$result+'" -Release "'+$release+'"'
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$powershell; $psi.Arguments=$args; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
        [pscustomobject]@{Process=[Diagnostics.Process]::Start($psi);Result=$result;Release=$release}
    }
    function Await-Worker($Worker) {
        $end=[DateTime]::UtcNow.AddSeconds(10)
        while([DateTime]::UtcNow -lt $end) {
            try {
                if(Test-Path $Worker.Result) {
                    $answer=[IO.File]::ReadAllText($Worker.Result)
                    if($answer -in @('acquired','busy')) { return $answer }
                }
            } catch {}
            Start-Sleep -Milliseconds 20
        }
        throw 'Native child did not report a complete result' 
    }
    $one=Start-LeaseWorker 'one'; $two=Start-LeaseWorker 'two'
    try {
        $answers=@((Await-Worker $one),(Await-Worker $two))
        Assert-That (@($answers | Where-Object {$_ -eq 'acquired'}).Count -eq 1 -and @($answers | Where-Object {$_ -eq 'busy'}).Count -eq 1) 'Two native processes cannot both acquire the operation'
        $winner=if($answers[0] -eq 'acquired'){$one}else{$two}
        $winner.Process.Kill(); [void]$winner.Process.WaitForExit(5000)
        $lease=[Tqr.OperationGate]::TryAcquire($leaseRoot,'diagnostics')
        Assert-That ($null -ne $lease -and (Test-Path (Join-Path $leaseRoot 'operation-recovery.json'))) 'A killed test worker is recovered by a new owner with local evidence'
        $lease.Dispose()
        Assert-That (-not(Test-Path $marker)) 'Only the completed lease removes its own marker'
    } finally {
        foreach($w in @($one,$two)) {
            if(-not $w.Process.HasExited){[IO.File]::WriteAllText($w.Release,'release');if(-not $w.Process.WaitForExit(5000)){$w.Process.Kill()}}
            $w.Process.Dispose()
        }
    }
    $lease=[Tqr.OperationGate]::TryAcquire($leaseRoot,'integrity')
    $foreign=Get-Content $marker -Raw | ConvertFrom-Json
    $foreign.leaseId=[Guid]::NewGuid().ToString('N'); Json-Write $marker $foreign
    $rejected=$false
    try {$lease.Dispose()} catch {$rejected=$true}
    Assert-That ($rejected -and (Test-Path $marker)) 'An old lease cannot delete a replacement owner marker'
    & (Join-Path $PSScriptRoot 'test-backend-report.ps1') -BackendPath (Join-Path $setup 'program\Repair-Backend.ps1') -EvidenceDirectory $EvidenceDirectory
    & (Join-Path $PSScriptRoot 'test-local-history.ps1') -Dll $dll -UiPath (Join-Path $normal 'app\Tailscale-Repair-UI.ps1') -EvidenceDirectory $EvidenceDirectory
    & (Join-Path $PSScriptRoot 'test-update-routing.ps1') -UiPath (Join-Path $normal 'app\Tailscale-Repair-UI.ps1') -EvidenceDirectory $EvidenceDirectory
    # Windows PowerShell's default source encoding is not UTF-8; retain exact Unicode route fixtures.
    $qualityTest=[scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'test-connection-quality.ps1'),[Text.Encoding]::UTF8))
    & $qualityTest -UiPath (Join-Path $normal 'app\Tailscale-Repair-UI.ps1') -LibraryPath $dll -EvidenceDirectory $EvidenceDirectory
    & (Join-Path $PSScriptRoot 'test-smart-notifications.ps1') -UiPath (Join-Path $normal 'app\Tailscale-Repair-UI.ps1') -LibraryPath $dll -EvidenceDirectory $EvidenceDirectory
    & (Join-Path $PSScriptRoot 'test-diagnostics-polish.ps1') -UiPath (Join-Path $normal 'app\Tailscale-Repair-UI.ps1') -LibraryPath $dll -WorkerPath (Join-Path $normal 'app\Advanced-Diagnostics.ps1') -EvidenceDirectory $EvidenceDirectory
    & (Join-Path $PSScriptRoot 'test-progress-reset.ps1') -UiPath (Join-Path $normal 'app\Tailscale-Repair-UI.ps1') -EvidenceDirectory $EvidenceDirectory
    & (Join-Path $PSScriptRoot 'test-support-export.ps1') -UiPath (Join-Path $normal 'app\Tailscale-Repair-UI.ps1') -LibraryPath $dll -EvidenceDirectory $EvidenceDirectory
    # Isolate assembly identity: the protected package is a separate native build.
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -STA -File (Join-Path $PSScriptRoot 'test-auto-repair-worker.ps1') -OutputDirectory ([IO.Path]::GetFullPath($OutputDirectory)) -EvidenceDirectory ([IO.Path]::GetFullPath($EvidenceDirectory))
    if ($LASTEXITCODE -ne 0) { throw 'Integrated automatic worker gates failed.' }
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -STA -File (Join-Path $PSScriptRoot 'test-auto-background.ps1') -OutputDirectory ([IO.Path]::GetFullPath($OutputDirectory)) -EvidenceDirectory ([IO.Path]::GetFullPath($EvidenceDirectory))
    if ($LASTEXITCODE -ne 0) { throw 'Automatic background lifecycle gates failed.' }
    Json-Write (Join-Path $EvidenceDirectory 'native-results.json') @{passed=$true;runtime='Windows PowerShell 5.1 / WPF / .NET Framework';scope='Packaged Guardian event and real process ownership; OS integration probes are fixture stubs';cases=$script:results.ToArray()}
    Write-Host "Native package gates passed: $($script:results.Count) assertions."
} catch {
    Json-Write (Join-Path $EvidenceDirectory 'native-results.json') @{passed=$false;failure=[string]$_.Exception.Message;cases=$script:results.ToArray()}
    throw
}
# Leave the isolated fixture until the disposable CI runner is discarded. No
# broad cleanup, marker removal, or secret-bearing host diagnostics are used.
