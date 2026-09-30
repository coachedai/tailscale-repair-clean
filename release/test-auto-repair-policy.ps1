param([string]$EvidenceDirectory = '.\test-evidence')
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Native Windows PowerShell 5.1 is required; substitute runtimes are not acceptance.'
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$evidence = (Resolve-Path $EvidenceDirectory).Path
$root = Join-Path $env:TEMP ('TQR-AutoPolicy-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$results = New-Object 'Collections.Generic.List[object]'
$children = New-Object 'Collections.Generic.List[object]'
$passed = $false
function Assert-Case([bool]$Value,[string]$Name) {
    $results.Add([pscustomobject]@{name=$Name;passed=$Value})
    if (-not $Value) { throw "FAILED: $Name" }
    Write-Host "PASS: $Name"
}
function Write-Json([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8 -Compress),(New-Object Text.UTF8Encoding($false)))
}
function Healthy {
    $h = New-Object Tqr.AutoHealth
    $h.Service='Running'; $h.Startup='Automatic'; $h.Client='Running'; $h.Backend='Running'
    return $h
}
function Fault {
    $h = Healthy
    $h.Service='Stopped'; $h.Backend='Unknown'
    return $h
}
function New-State { return (New-Object Tqr.AutoPolicyState) }
function Evaluate($State,$Health,[DateTime]$When,[bool]$Enabled=$true,[bool]$Busy=$false) {
    return [Tqr.AutoRepairPolicy]::Evaluate($State,$Health,$When,$Enabled,$Busy)
}
function New-Fixture([string]$Name) {
    $path=Join-Path $root $Name
    New-Item -ItemType Directory -Path $path | Out-Null
    Write-Json (Join-Path $path 'auto-repair.json') @{enabled=$true}
    return $path
}
function Observe([string]$Path,$Health,[DateTime]$When,[bool]$Busy=$false) {
    return [Tqr.AutoRepairPolicyStore]::Observe($Path,$Health,$When,$Busy)
}
try {
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $reference=Join-Path (Split-Path $compiler) 'System.Web.Extensions.dll'
    $dll=Join-Path $root 'AutoRepairPolicy.dll'
    & $compiler /nologo /target:library /optimize+ ('/out:'+$dll) ('/reference:'+$reference) (Join-Path $repo 'src\native\AutoRepairPolicy.cs')
    Assert-Case ($LASTEXITCODE -eq 0 -and (Test-Path $dll)) 'Policy compiles on the native .NET Framework compiler'
    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
    $time=[DateTime]::Parse('2030-01-01T00:00:00.0000000Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $s=New-State; $h=Healthy
    Assert-Case ((Evaluate $s $h $time).Action -eq 'Healthy') 'Healthy requires explicit service client and backend evidence'
    foreach($value in @('Unknown','','future-state','Running with injected text')) {
        $s=New-State; $h=Healthy; $h.Backend=$value
        Assert-Case ((Evaluate $s $h $time).Reason -eq 'unconfirmed') "Missing or unknown backend is not healthy: '$value'"
    }
    $s=New-State; $h=Healthy; $h.Client='Closed'; $h.Backend='Unknown'
    Assert-Case ((Evaluate $s $h $time).Reason -eq 'unconfirmed') 'Closed client with unknown backend does not manufacture a repair reason'
    foreach($value in @('Stopped','NeedsLogin','NeedsMachineAuth','InUseOtherUser')) {
        $s=New-State; $h=Healthy; $h.Client='Closed'; $h.Backend=$value
        Assert-Case ((Evaluate $s $h $time).Action -eq 'Attention') "Intent or authentication takes priority over reopening the client: $value"
        $h=Fault
        Assert-Case ((Evaluate $s $h $time.AddMinutes(5)).Action -eq 'Attention') "Observed hold survives later service loss: $value"
        Assert-Case ((Evaluate $s (Healthy) $time.AddMinutes(6)).Action -eq 'Healthy' -and $s.IntentHold -eq '') "Explicit later Running evidence releases the hold: $value"
    }
    foreach($value in @('Running','Stopped')) {
        $s=New-State; $h=Healthy; $h.Service=$value; $h.Startup='Disabled'
        Assert-Case ((Evaluate $s $h $time).Reason -eq 'service_disabled') "Disabled service is not silently re-enabled: $value"
    }
    $s=New-State; $h=Fault; $h.Service='Missing'
    Assert-Case ((Evaluate $s $h $time).Reason -eq 'installation_missing') 'Missing installation requires attention, not blind task dispatch'
    $s=New-State; $h=Fault; $h.Startup='Unknown'
    Assert-Case ((Evaluate $s $h $time).Reason -eq 'unconfirmed') 'Unconfirmed startup state cannot authorize starting a service'
    $s=New-State; $h=Fault
    Assert-Case ((Evaluate $s $h $time $false).Action -eq 'Disabled' -and $s.Observed -eq '') 'Default-off does not collect or mutate policy state'
    Assert-Case ((Evaluate $s $h $time $true $true).Reason -eq 'operation_busy' -and $s.Observed -eq '') 'Busy coordinator does not consume or mutate observations'
    Assert-Case ((Evaluate $s $h $time).Reason -eq 'confirming_fault') 'First confirmed local fault waits for a second observation'
    Assert-Case ((Evaluate $s $h $time.AddSeconds(29)).Action -eq 'Wait') 'Transient local fault cannot consume a repair slot inside grace'
    Assert-Case ((Evaluate $s $h $time.AddSeconds(30)).Action -eq 'RequestRepair' -and $s.Attempts -eq 1) 'Confirmed local fault reserves one repair attempt'
    $d=Evaluate $s $h $time.AddSeconds(31)
    Assert-Case ($d.Action -eq 'Cooldown' -and $d.CooldownMinutes -eq 15 -and $s.Attempts -eq 1) 'Rapid repeated events share the first fifteen-minute cooldown'
    foreach($attempt in @(2,3)) {
        $at=[DateTime]::Parse($s.NextAllowed,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        Assert-Case ((Evaluate $s $h $at).Action -eq 'Wait') "Long gap requires a fresh fault confirmation before attempt $attempt"
        $d=Evaluate $s $h $at.AddSeconds(30)
        $next=[DateTime]::Parse($s.NextAllowed,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        Assert-Case ($d.Action -eq 'RequestRepair' -and $s.Attempts -eq $attempt -and ($next-$at.AddSeconds(30)).TotalMinutes -eq @(0,15,30,60)[$attempt]) "Persistent backoff escalates for attempt $attempt"
    }
    $at=([DateTime]::Parse($s.NextAllowed,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).AddSeconds(1)
    Assert-Case ((Evaluate $s $h $at).Reason -eq 'retry_limit') 'Third unresolved attempt stops automatic retries rather than looping'
    [void](Evaluate $s $h $at.AddSeconds(1) $false)
    Assert-Case ((Evaluate $s $h $at.AddSeconds(2)).Reason -eq 'retry_limit') 'Preference toggling does not reset the exhausted retry budget'
    $healthy=Healthy
    [void](Evaluate $s $healthy $at.AddMinutes(1))
    for($i=1;$i -le 20;$i++){ [void](Evaluate $s $healthy $at.AddMinutes(1).AddSeconds($i)) }
    Assert-Case ($s.Attempts -eq 3 -and $s.HealthySamples -eq 1) 'Rapid healthy events cannot pretend to be sustained recovery'
    [void](Evaluate $s $healthy $at.AddMinutes(6))
    Assert-Case ($s.Attempts -eq 3 -and $s.HealthySamples -eq 2) 'Two healthy samples retain the unresolved-incident budget'
    [void](Evaluate $s $healthy $at.AddMinutes(11))
    Assert-Case ($s.Attempts -eq 0 -and $s.LastAttempt -eq '' -and $s.NextAllowed -eq '') 'Three spaced healthy samples over ten minutes reset the incident budget'
    $before=$s.Observed
    Assert-Case ((Evaluate $s $h $at).Reason -eq 'clock_changed' -and $s.Observed -eq $before) 'Clock rollback preserves prior evidence and fails closed'
    Assert-Case ((Evaluate $s $h ([DateTime]::SpecifyKind($at.AddDays(1),[DateTimeKind]::Unspecified))).Reason -eq 'clock_changed') 'Unspecified local time cannot bypass UTC policy ordering'
    foreach($backend in @('Starting','NoState')) {
        $s=New-State; $h=Healthy; $h.Backend=$backend
        [void](Evaluate $s $h $time)
        Assert-Case ((Evaluate $s $h $time.AddSeconds(30)).Action -eq 'Wait') "$backend gets the longer backend-settling grace"
        Assert-Case ((Evaluate $s $h $time.AddSeconds(60)).Action -eq 'RequestRepair') "$backend is eligible only after a sustained comparable observation"
    }
    $s=New-State; $h=Fault; [void](Evaluate $s $h $time)
    $h.Backend='Unknown'; $h.Service='Unknown'; [void](Evaluate $s $h $time.AddSeconds(20))
    Assert-Case ((Evaluate $s (Fault) $time.AddSeconds(40)).Action -eq 'Wait') 'Missing evidence breaks fault continuity'
    $s=New-State; [void](Evaluate $s (Fault) $time)
    Assert-Case ((Evaluate $s (Fault) $time.AddMinutes(11)).Action -eq 'Wait') 'Long observation gap cannot reuse a stale pre-suspend fault'
    $s=New-State; $s.Attempts=-1
    Assert-Case ((Evaluate $s (Fault) $time).Reason -eq 'state_unavailable') 'Damaged numeric state fails closed'
    Assert-Case (([Tqr.AutoHealth].GetFields().Name -join ',') -eq 'Service,Startup,Client,Backend') 'Decision input has no peer address path latency or raw-message channel'

    $path=New-Fixture 'store'
    $policy=Join-Path $path 'auto-repair-policy.json'
    Assert-Case ((Observe $path (Fault) $time).Action -eq 'Wait' -and (Test-Path $policy)) 'First native policy write creates a bounded record'
    Assert-Case ((Observe $path (Fault) $time.AddSeconds(30)).Action -eq 'RequestRepair') 'Native store durably reserves before returning a repair decision'
    $stored=[IO.File]::ReadAllText($policy)
    Assert-Case ($stored.Length -lt 16384 -and (Test-Path ($policy+'.previous'))) 'Atomic replacement retains one bounded predecessor'
    Assert-Case ((Observe $path (Fault) $time.AddSeconds(31)).Action -eq 'Cooldown') 'New store call reads the committed cooldown'
    $settings=Join-Path $path 'auto-repair.json'
    Write-Json $settings @{enabled=$false}
    $before=[IO.File]::ReadAllText($policy)
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(1)).Action -eq 'Disabled' -and [IO.File]::ReadAllText($policy) -ceq $before) 'Disabling leaves existing retry evidence untouched'
    Write-Json $settings @{enabled=$true}
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(2)).Action -eq 'Cooldown') 'Re-enabling retains the persisted budget'
    $saved=[IO.File]::ReadAllBytes($policy)
    [IO.File]::WriteAllText($policy,'{damaged')
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable' -and [IO.File]::ReadAllText($policy) -ceq '{damaged') 'Damaged primary is preserved, never replaced by a clean budget'
    [IO.File]::WriteAllBytes($policy,$saved)
    $held=[IO.File]::Open($policy,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try { Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable') 'Locked primary fails closed without blocking recovery flow' }
    finally { $held.Dispose() }
    $held=[IO.File]::Open((Join-Path $path 'auto-repair-policy.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable') 'Competing policy owner is not evicted or retried indefinitely' }
    finally { $held.Dispose() }
    $prev=$policy+'.previous'; $savedPrev=[IO.File]::ReadAllBytes($prev)
    [IO.File]::WriteAllText($prev,'{bad-predecessor')
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable' -and [IO.File]::ReadAllText($prev) -ceq '{bad-predecessor') 'Damaged predecessor is not silently overwritten'
    [IO.File]::WriteAllBytes($prev,$savedPrev)
    [IO.File]::Move($policy,($policy+'.fixture-removed'))
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable' -and -not (Test-Path $policy)) 'Missing primary with surviving predecessor cannot reset retry budget'
    [IO.File]::Move(($policy+'.fixture-removed'),$policy)
    [IO.File]::WriteAllText($policy,('x'*16385))
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable' -and (Get-Item $policy).Length -eq 16385) 'Oversized policy is rejected and preserved'
    [IO.File]::WriteAllBytes($policy,$saved)
    $bad=([Text.Encoding]::UTF8.GetString($saved)).Replace('"Attempts":1','"Attempts":"1"')
    [IO.File]::WriteAllText($policy,$bad)
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable') 'String-coerced retry counters are rejected'
    [IO.File]::WriteAllBytes($policy,$saved)
    $original=[Text.Encoding]::UTF8.GetString($saved)
    $bad=$original.Replace('"Attempts":1','"Attempts":0,"Attempts":1')
    [IO.File]::WriteAllText($policy,$bad)
    Assert-Case ((Observe $path (Fault) $time.AddMinutes(3)).Reason -eq 'state_unavailable') 'Duplicate policy fields are rejected'
    [IO.File]::WriteAllBytes($policy,$saved)
    $settingsCases=@(
        '{"enabled":"false"}', '{"enabled":1}', '{"enabled":null}', '{"enabled":true,"enabled":false}',
        '{"enabled":true,"unexpected":"private text"}', '{"enabled":true,"updatedUtc":false}',
        '{"\u0065nabled":false,"enabled":true}', '{"enabled":true,"updatedUtc":"not-a-time"}'
    )
    foreach($bad in $settingsCases) {
        [IO.File]::WriteAllText($settings,$bad)
        Assert-Case ($null -eq [Tqr.AutoRepairPolicyStore]::ReadEnabled($path)) "Invalid settings fail closed: $bad"
    }
    Write-Json $settings @{enabled=$true;updatedUtc=$time.ToString('o')}
    Assert-Case ([Tqr.AutoRepairPolicyStore]::ReadEnabled($path) -eq $true) 'Existing typed settings and UTC timestamp remain compatible'
    Assert-Case (@(Get-ChildItem $path -Filter '*.tmp').Count -eq 0) 'Failed and successful native writes clean up only their own scratch files'

    $directoryState=New-Fixture 'directory-predecessor'
    $directoryPrimary=Join-Path $directoryState 'auto-repair-policy.json'
    New-Item -ItemType Directory -Path ($directoryPrimary+'.previous') | Out-Null
    Assert-Case ((Observe $directoryState (Fault) $time).Reason -eq 'state_unavailable' -and -not (Test-Path $directoryPrimary)) 'An unexpected predecessor directory cannot create a clean retry budget'
    Assert-Case (Test-Path -LiteralPath ($directoryPrimary+'.previous') -PathType Container) 'Unexpected predecessor evidence is preserved'

    $worker=Join-Path $root 'policy-worker.ps1'
    @'
param([string]$Dll,[string]$Root,[string]$When,[string]$Result,[switch]$Pause)
$ErrorActionPreference='Stop'
[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($Dll))
$h=New-Object Tqr.AutoHealth
$h.Service='Stopped';$h.Startup='Automatic';$h.Client='Running';$h.Backend='Unknown'
$at=[DateTime]::Parse($When,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
$d=[Tqr.AutoRepairPolicyStore]::Observe($Root,$h,$at,$false)
[IO.File]::WriteAllText($Result,($d|ConvertTo-Json -Compress))
if($Pause){Start-Sleep -Seconds 60}
'@ | Set-Content $worker -Encoding UTF8
    function Launch-Worker([string]$Name,[string]$PolicyRoot,[DateTime]$When,[switch]$Pause) {
        $result=Join-Path $root ($Name+'.json')
        $arguments='-NoProfile -NonInteractive -File "'+$worker+'" -Dll "'+$dll+'" -Root "'+$PolicyRoot+'" -When "'+$When.ToString('o')+'" -Result "'+$result+'"'
        if($Pause){$arguments+=' -Pause'}
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=Join-Path $PSHOME 'powershell.exe';$psi.Arguments=$arguments;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $p=[Diagnostics.Process]::Start($psi);$children.Add($p)
        return [pscustomobject]@{Process=$p;Result=$result}
    }
    function Await-Result($Worker) {
        $until=[DateTime]::UtcNow.AddSeconds(12)
        while([DateTime]::UtcNow -lt $until) {
            try { if(Test-Path $Worker.Result){return ([IO.File]::ReadAllText($Worker.Result)|ConvertFrom-Json)} }catch{}
            Start-Sleep -Milliseconds 20
        }
        throw 'Synthetic child did not publish its result.'
    }
    $parallel=New-Fixture 'parallel'
    [void](Observe $parallel (Fault) $time)
    $a=Launch-Worker 'parallel-a' $parallel $time.AddSeconds(30)
    $b=Launch-Worker 'parallel-b' $parallel $time.AddSeconds(30)
    $answers=@((Await-Result $a),(Await-Result $b))
    Assert-Case (@($answers|Where-Object Action -eq 'RequestRepair').Count -eq 1) 'Two real concurrent Windows processes cannot reserve the same repair slot'
    Assert-Case ((Get-Content (Join-Path $parallel 'auto-repair-policy.json') -Raw|ConvertFrom-Json).Attempts -eq 1) 'Concurrent contention leaves exactly one persisted attempt'
    $crash=New-Fixture 'crash'
    [void](Observe $crash (Fault) $time)
    $child=Launch-Worker 'crash-after-reservation' $crash $time.AddSeconds(30) -Pause
    $answer=Await-Result $child
    Assert-Case ($answer.Action -eq 'RequestRepair') 'Disposable worker reserves before the simulated crash'
    $child.Process.Kill();[void]$child.Process.WaitForExit(5000)
    Assert-Case ((Observe $crash (Fault) $time.AddSeconds(31)).Action -eq 'Cooldown') 'Killed reservation owner cannot cause immediate duplicate dispatch on restart'
    Assert-Case ((Get-Item (Join-Path $crash 'auto-repair-policy.lock')).Length -eq 0) 'Policy lock handle is recoverable without deleting its marker file'
    $passed=$true
}
finally {
    foreach($p in $children){try{if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(1000)}}catch{};try{$p.Dispose()}catch{}}
    [pscustomobject]@{
        passed=$passed;scope='Native policy/state component; not integrated monitor or installer acceptance';
        platform=$PSVersionTable.PSVersion.ToString();cases=@($results.ToArray());
        limits=@('No product service or task is modified','No peer networking occurs','Whole-PC power loss and protected Setup are not covered')
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'auto-repair-policy.json') -Encoding UTF8
    # Dedicated synthetic fixture only. Failed fixture state stays on the runner;
    # retained JSON reports carry each assertion result without private identifiers.
    if($passed){Remove-Item -LiteralPath $root -Recurse -Force}
}
