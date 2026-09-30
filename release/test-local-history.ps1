param([Parameter(Mandatory=$true)][string]$Dll,[Parameter(Mandatory=$true)][string]$UiPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Native Windows PowerShell 5.1 required.' }
if (-not ('Tqr.LocalHistory' -as [type])) { Add-Type -Path $Dll }
$root=Join-Path $env:TEMP ('TQR-HistoryTest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAILED history: $Name" }
    $cases.Add([pscustomobject]@{name=$Name;passed=$true}); Write-Host "PASS history: $Name"
}
try {
    Check ([Tqr.LocalHistory]::Read($root).Entries.Count -eq 0) 'Empty history is readable without a dummy entry'
    Check ([Tqr.LocalHistory]::Record($root,'check_healthy',-1,-1)) 'First typed event saves'
    Check ([Tqr.LocalHistory]::Record($root,'check_healthy',-1,-1) -and [Tqr.LocalHistory]::Read($root).Entries.Count -eq 1) 'Repeated identical event is coalesced'
    for ($i=0;$i -lt 55;$i++) { [void][Tqr.LocalHistory]::Record($root, $(if($i%2){'route_direct'}else{'route_relay'}),-1,-1) }
    $path=Join-Path $root 'health-history.json'
    Check ([Tqr.LocalHistory]::Read($root).Entries.Count -eq 40 -and (Get-Item $path).Length -le 32768) 'Retention is bounded to 40 events and 32 KiB'
    Check (Test-Path (Join-Path $root 'health-history.previous.json')) 'Atomic replacement retains one predecessor'
    $doc=Get-Content $path -Raw | ConvertFrom-Json
    $doc.entries[0].utc=[DateTime]::UtcNow.AddDays(-31).ToString('o')
    [IO.File]::WriteAllText($path,($doc|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    Check ([Tqr.LocalHistory]::Read($root).Entries.Count -eq 39) 'Entries over 30 days are not shown'
    Check ([Tqr.LocalHistory]::Record($root,'update_installed',-1,-1) -and @((Get-Content $path -Raw|ConvertFrom-Json).entries).Count -eq 40) 'Next append prunes expired records'
    Check ([Tqr.LocalHistory]::Record($root,'vpn_active',-1,-1) -and
        [Tqr.LocalHistory]::Describe([Tqr.HistoryEntry]@{code='vpn_active';before=-1;after=-1}) -eq 'VPN became active') 'VPN activation is a fixed typed history event'
    Check ([Tqr.LocalHistory]::Record($root,'vpn_inactive',-1,-1) -and
        [Tqr.LocalHistory]::Describe([Tqr.HistoryEntry]@{code='vpn_inactive';before=-1;after=-1}) -eq 'VPN became inactive') 'VPN deactivation is a fixed typed history event'
    Check ([Tqr.LocalHistory]::Record($root,'vpn_changed',-1,-1) -and
        [Tqr.LocalHistory]::Describe([Tqr.HistoryEntry]@{code='vpn_changed';before=-1;after=-1}) -eq 'Active VPN changed') 'VPN switch history stores no vendor, adapter or address'
    $hash=(Get-FileHash $path).Hash
    Check (-not [Tqr.LocalHistory]::Record($root,'unapproved arbitrary text',-1,-1) -and (Get-FileHash $path).Hash -eq $hash) 'Arbitrary free text is not persisted'
    Check (-not [Tqr.LocalHistory]::Record($root,'latency_up',-99,999999) -and (Get-FileHash $path).Hash -eq $hash) 'Out-of-range values are rejected without writing'
    $doc=Get-Content $path -Raw|ConvertFrom-Json
    Check (@($doc.PSObject.Properties.Name|Where-Object {$_ -notin @('schema','entries')}).Count -eq 0) 'Only typed envelope fields are persisted'
    Check (@($doc.entries|ForEach-Object {$_.PSObject.Properties.Name}|Where-Object {$_ -notin @('id','utc','code','before','after')}).Count -eq 0) 'No peer, address, name, path or raw-message fields in records'
    $saved=[IO.File]::ReadAllBytes($path)
    [IO.File]::WriteAllText($path,'{broken')
    Check ([Tqr.LocalHistory]::Read($root).Status -eq 'unavailable' -and -not [Tqr.LocalHistory]::Record($root,'check_healthy',-1,-1) -and [IO.File]::ReadAllText($path) -eq '{broken') 'Unreadable history is preserved, not overwritten'
    [IO.File]::WriteAllBytes($path,$saved)
    $beforeLockHash=(Get-FileHash $path).Hash
    $held=[IO.File]::Open((Join-Path $root 'health-history.gate'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $result=[Tqr.LocalHistory]::Record($root,'check_healthy',-1,-1)
        Check (-not $result -and $watch.Elapsed.TotalSeconds -lt 2 -and (Get-FileHash $path).Hash -eq $beforeLockHash) 'Busy history does not wait indefinitely or alter the store'
    } finally { $held.Dispose() }
    Check ([Tqr.LocalHistory]::Read($root).Status -eq 'ready') 'History reads recover after a lock is released'

    # Real packaged PowerShell definitions and WPF History button event.
    $text=[IO.File]::ReadAllText($UiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Packaged history code parses on Windows PowerShell 5.1'
    foreach ($name in @('Initialize-LocalHistory','Write-LocalHistoryEvent','Update-LocalHistoryView','Record-CompletedHistory')) {
        $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Check ($functions.Count -eq 1) "Exactly one packaged $name function remains after all transforms"
        . ([scriptblock]::Create($functions[0].Extent.Text))
    }
    $match=[regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    [xml]$xaml=$match.Groups['xaml'].Value
    $reader=New-Object Xml.XmlNodeReader $xaml
    $window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
    $HistoryButton=$window.FindName('HistoryButton'); $HistoryPanel=$window.FindName('HistoryPanel'); $HistoryText=$window.FindName('HistoryText')
    $SessionText=$window.FindName('SessionText');$CopyButton=$window.FindName('CopyButton');$ActivityDescriptionText=$window.FindName('ActivityDescriptionText')
    $StateDir=$root;$OperationsLibraryPath=$Dll
    $script:historyVisible=$false;$script:historyWriteUnavailable=$false
    $handlers=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -ceq '$HistoryButton' -and $n.Member.Value -eq 'Add_Click'},$true))
    Check ($handlers.Count -eq 1) 'Exactly one packaged History click event'
    $HistoryButton.Add_Click($handlers[0].Arguments[0].ScriptBlock.GetScriptBlock())
    $HistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ($HistoryPanel.Visibility -eq 'Visible' -and $SessionText.Visibility -eq 'Collapsed' -and $HistoryText.Text -match 'App update installed') 'History button displays persisted events inside Activity'
    $HistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Check ($HistoryPanel.Visibility -eq 'Collapsed' -and $SessionText.Visibility -eq 'Visible') 'History toggles back to session activity'
    $other=Join-Path $root 'new-session';$StateDir=$other
    $script:historyLastStamp='';$script:historyLastOutcome='';$script:historyLastRoute='';$script:historyLastLatency=-1
    $data=[pscustomobject]@{done=$true;mode='success';updatedUtc='fixture-1';peerReachable='Reachable';route='Direct';latency='12 ms';repairPerformed=$false}
    Record-CompletedHistory $data;Record-CompletedHistory $data
    Check ([Tqr.LocalHistory]::Read($other).Entries.Count -eq 1) 'Repeated rendering of one check does not duplicate history'
    $data.updatedUtc='fixture-2';$data.route='Relay';Record-CompletedHistory $data
    Check ([Tqr.LocalHistory]::Read($other).Entries[0].code -eq 'route_relay') 'A completed route transition is recorded without a peer identifier'
    $window.Close()
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'history-results.json'),(@{passed=$true;scope='Native store and final packaged WPF History button; no production networking';cases=$cases.ToArray()}|ConvertTo-Json -Depth 8))
} catch {
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'history-results.json'),(@{passed=$false;failure=$_.Exception.Message;cases=$cases.ToArray()}|ConvertTo-Json -Depth 8))
    throw
}
