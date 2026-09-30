param([string]$EvidenceDirectory='.\test-evidence')
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Native Windows PowerShell 5.1 is required.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$root=Join-Path $env:TEMP ('TQR-LocalStatus-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false
function Assert-Status([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw "FAILED: $Name"}
    Write-Host "PASS local status: $Name"
}
try {
    $fixtureIp=@('100','100','10','20') -join '.'
    $fixtureV6=@('fd7a','115c','a1e0','','1234') -join ':'
    $privateIp=@('192','168','1','8') -join '.'
    $publicIp=@('8','8','8','8') -join '.'
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $ref=Join-Path (Split-Path $compiler) 'System.Web.Extensions.dll'
    $dll=Join-Path $root 'AutoStatus.dll'
    & $compiler /nologo /target:library ('/out:'+$dll) ('/reference:'+$ref) (Join-Path $repo 'src\native\AutoRepairPolicy.cs') (Join-Path $repo 'src\native\AutoRepairLocalStatus.cs')
    Assert-Status ($LASTEXITCODE -eq 0 -and (Test-Path $dll)) 'Local-only collector compiles on the native .NET Framework compiler'
    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
    foreach($state in @('Running','Stopped','NeedsLogin','NeedsMachineAuth','InUseOtherUser','Starting','NoState')){
        $r=[Tqr.AutoRepairLocalStatus]::Parse(('{"BackendState":"'+$state+'"}'),0,$false,$false)
        Assert-Status ($r.Status -eq 'Complete' -and $r.Backend -ceq $state) "Explicit backend state is retained without inventing health: $state"
    }
    $invalid=@(
        '', '{}','[]','{"BackendState":null}','{"BackendState":true}','{"BackendState":1}',
        '{"BackendState":""}','{"BackendState":"FutureState"}','{"backendstate":"Running"}',
        '{"BackendState":"Stopped","BackendState":"Running"}',
        '{"BackendState":"Stopped","Back\u0065ndState":"Running"}',
        '{"Back\u0065ndState":"Running"}', '{"BackendState":"Running"',
        '{"Other":{"BackendState":"Running"}}',
        '{"BackendState":"Running","Version":"1","Version":"2"}',
        ('{"BackendState":"Running","TailscaleIPs":["'+(@('100','100','1','1') -join '.')+'"],"TailscaleIPs":["'+(@('100','100','1','2') -join '.')+'"]}')
    )
    $index=0
    foreach($json in $invalid){
        $index++
        $r=[Tqr.AutoRepairLocalStatus]::Parse($json,0,$false,$false)
        Assert-Status ($r.Backend -eq 'Unknown' -and $r.Status -ne 'Complete') "Malformed, missing or ambiguous evidence stays unconfirmed: case $index"
    }
    $r=[Tqr.AutoRepairLocalStatus]::Parse('{"BackendState":"Running","Self":{"HostName":"fixture-private","Note":"quoted \"BackendState\": \"Stopped\""}}',0,$false,$false)
    Assert-Status ($r.Backend -eq 'Running') 'Quoted content inside unrelated nested values cannot masquerade as a top-level state'
    $r=[Tqr.AutoRepairLocalStatus]::Parse(('{"BackendState":"Running","Version":"1.90.0-tabcdef","TailscaleIPs":["'+$fixtureV6+'","'+$fixtureIp+'"],"Self":{"HostName":"fixture-private"},"AuthURL":"fixture-private"}'),0,$false,$false)
    Assert-Status ($r.Backend -eq 'Running' -and $r.LocalIp -ceq $fixtureIp -and $r.Version -ceq '1.90.0-tabcdef') 'Validated self Tailscale IP and version are retained without peer or host metadata'
    $r=[Tqr.AutoRepairLocalStatus]::Parse(('{"BackendState":"Running","Version":"bad version <x>","TailscaleIPs":["'+$privateIp+'","'+$publicIp+'"]}'),0,$false,$false)
    Assert-Status ($r.Backend -eq 'Running' -and [string]::IsNullOrEmpty($r.LocalIp) -and [string]::IsNullOrEmpty($r.Version)) 'Non-Tailscale addresses and unsafe version text are discarded without changing backend health'
    $r=[Tqr.AutoRepairLocalStatus]::Parse(('{"BackendState":"Running","Version":"1.90.0","TailscaleIPs":["'+$fixtureV6+'"]}'),0,$false,$false)
    Assert-Status ($r.LocalIp.StartsWith('fd7a:115c:a1e0:') -and $r.Version -ceq '1.90.0') 'Tailscale IPv6 self address is accepted when IPv4 is unavailable'
    $r=[Tqr.AutoRepairLocalStatus]::Parse('{"BackendState":"Running"}',7,$false,$false)
    Assert-Status ($r.Status -eq 'CommandFailed' -and $r.Backend -eq 'Unknown') 'Nonzero exit cannot supply a usable health observation'
    $r=[Tqr.AutoRepairLocalStatus]::Parse('{"BackendState":"Running"}',0,$true,$false)
    Assert-Status ($r.Status -eq 'TimedOut' -and $r.Backend -eq 'Unknown') 'Even valid-looking output is rejected after timeout'
    $r=[Tqr.AutoRepairLocalStatus]::Parse('{"BackendState":"Running"}',0,$false,$true)
    Assert-Status ($r.Status -eq 'Incomplete' -and $r.Backend -eq 'Unknown') 'Truncated or incomplete reads cannot become healthy'
    Assert-Status (([Tqr.AutoRepairLocalStatus]::Parse((' '*65537),0,$false,$false)).Backend -eq 'Unknown') 'Parser rejects oversized input before deserialization'
    $fields=[Tqr.AutoBackendObservation].GetFields().Name
    Assert-Status (($fields -join ',') -eq 'Backend,Status,LocalIp,Version,ExitCode,DurationMs,RetainedBytes') 'Public observation exposes only typed backend plus validated self IP/version metadata'

    $source=Join-Path $root 'fixture.cs'
    @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
class StatusFixture
{
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    static int Main(string[] args)
    {
        string exe=Process.GetCurrentProcess().MainModule.FileName;
        string mode=Path.GetFileNameWithoutExtension(exe);
        File.WriteAllText(exe+".pid",Process.GetCurrentProcess().Id.ToString());
        File.WriteAllText(exe+".window",GetConsoleWindow()==IntPtr.Zero?"hidden":"visible");
        if(args.Length!=3 || args[0]!="status" || args[1]!="--json" || args[2]!="--peers=false") return 91;
        File.WriteAllText(exe+".arguments","fixed-local-status-only");
        if(mode=="sleep") { Thread.Sleep(10000); return 0; }
        if(mode=="overflow") { Console.Write(new string('x',400000)); return 0; }
        if(mode=="stderr") { Console.Error.Write(new string('e',400000)); Console.Write("{\"BackendState\":\"Running\"}"); return 0; }
        if(mode=="error") { Console.Write("{\"BackendState\":\"Running\"}"); return 7; }
        if(mode=="unsupported") { Console.Error.Write("flag provided but not defined"); return 2; }
        if(mode=="invalid-utf8") { Console.OpenStandardOutput().Write(new byte[]{255,254,255},0,3); return 0; }
        if(mode=="partial") { Console.Write("{\"BackendState\":\"Running\""); return 0; }
        if(mode=="empty") return 0;
        if(mode=="unknown") { Console.Write("{\"Version\":\"fixture\"}"); return 0; }
        string backend=mode=="disconnected"?"Stopped":mode=="login"?"NeedsLogin":"Running";
        string ip=String.Join(".",new[]{"100","100","10","20"});
        Console.Write("{\"BackendState\":\""+backend+"\",\"Version\":\"1.90.0\",\"TailscaleIPs\":[\""+ip+"\"],\"Self\":{\"HostName\":\"fixture-private\"},\"AuthURL\":\"fixture-private\"}");
        return 0;
    }
}
'@|Set-Content -LiteralPath $source -Encoding UTF8
    $seed=Join-Path $root 'seed.exe'
    & $compiler /nologo /target:exe ('/out:'+$seed) $source
    Assert-Status ($LASTEXITCODE -eq 0 -and (Test-Path $seed)) 'Synthetic native CLI compiles without a live Tailscale installation'
    foreach($name in @('good','disconnected','login','sleep','overflow','stderr','error','unsupported','invalid-utf8','partial','empty','unknown')){
        $exe=Join-Path $root ($name+'.exe');Copy-Item $seed $exe
        $budget=if($name -eq 'sleep'){1200}else{3000}
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $r=[Tqr.AutoRepairLocalStatus]::Read($exe,$budget)
        Assert-Status ((Get-Content ($exe+'.arguments') -Raw) -eq 'fixed-local-status-only') "$name child receives only status --json --peers=false"
        Assert-Status ((Get-Content ($exe+'.window') -Raw) -eq 'hidden') "$name native child has no console window"
        Assert-Status ($r.RetainedBytes -ge 0 -and $r.RetainedBytes -le 65536 -and $watch.ElapsedMilliseconds -lt 6000) "$name capture has bounded retention and elapsed time"
        $pidValue=[int](Get-Content ($exe+'.pid') -Raw)
        $alive=$false
        try{$owned=[Diagnostics.Process]::GetProcessById($pidValue);$alive=-not $owned.HasExited;$owned.Dispose()}catch{}
        Assert-Status (-not $alive) "$name owned child is not left running"
        switch($name){
            'good' { Assert-Status ($r.Backend -eq 'Running' -and $r.Status -eq 'Complete' -and $r.LocalIp -ceq $fixtureIp -and $r.Version -ceq '1.90.0') 'Valid JSON returns bounded backend plus self metadata without a trailing newline' }
            'disconnected' { Assert-Status ($r.Backend -eq 'Stopped' -and $r.Status -eq 'Complete') 'Native intentional disconnection is passed to policy without starting recovery' }
            'login' { Assert-Status ($r.Backend -eq 'NeedsLogin' -and $r.Status -eq 'Complete') 'Native sign-in requirement is passed to policy without starting recovery' }
            'sleep' { Assert-Status ($r.Status -eq 'TimedOut' -and $r.Backend -eq 'Unknown') 'Stalled owned child times out without a fabricated Running state' }
            'overflow' { Assert-Status ($r.Status -eq 'Incomplete' -and $r.Backend -eq 'Unknown') 'Large unterminated stdout is bounded before line parsing could accumulate it' }
            'stderr' { Assert-Status ($r.Status -eq 'Incomplete' -and $r.Backend -eq 'Unknown') 'Stderr flood cannot deadlock or substitute valid-looking stdout for complete evidence' }
            default { Assert-Status ($r.Backend -eq 'Unknown' -and $r.Status -ne 'Complete') "$name native failure stays unconfirmed" }
        }
        $serialized=$r|ConvertTo-Json -Compress
        Assert-Status (-not $serialized.Contains('fixture-private')) "$name observation excludes identifiers from raw fixture output"
    }
    Assert-Status (([Tqr.AutoRepairLocalStatus]::Read('relative.exe',1000)).Backend -eq 'Unknown') 'A relative executable is refused rather than resolved from the working directory'
    Assert-Status (([Tqr.AutoRepairLocalStatus]::Read((Join-Path $root 'missing.exe'),1000)).Backend -eq 'Unknown') 'Missing CLI yields no invented healthy backend'
    Assert-Status (([Tqr.AutoRepairLocalStatus]::Read((Join-Path $root 'good.exe'),99)).Backend -eq 'Unknown') 'Out-of-policy command budgets are refused'
    $passed=$true
}
finally {
    [pscustomobject]@{
        passed=$passed;scope='Native read-only CLI collector and parser, not installed monitor or repair acceptance';cases=@($cases.ToArray());
        limits=@('No live service, task, VPN or peer is changed','CLI discovery and protected repair integration remain separate','Only synthetic owned child processes are run')
    }|ConvertTo-Json -Depth 8|Set-Content (Join-Path $evidence 'auto-repair-local-status.json') -Encoding UTF8
    # All files and executable children belong to this disposable fixture only.
    foreach($pidFile in @(Get-ChildItem -LiteralPath $root -Filter '*.exe.pid' -ErrorAction SilentlyContinue)){
        try{
            $owned=[Diagnostics.Process]::GetProcessById([int](Get-Content $pidFile.FullName -Raw))
            if($owned.MainModule.FileName.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){$owned.Kill();[void]$owned.WaitForExit(1000)}
            $owned.Dispose()
        }catch{}
    }
    if($passed){Remove-Item -LiteralPath $root -Recurse -Force}
}