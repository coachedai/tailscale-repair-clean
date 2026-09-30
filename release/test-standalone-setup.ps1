param([Parameter(Mandatory=$true)][string]$OutputDirectory,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or $env:GITHUB_REPOSITORY_ID -cne '1398720044'){throw 'Standalone tests require the bound disposable CI runner.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$version=Get-Content (Join-Path $PSScriptRoot '../version.json') -Raw|ConvertFrom-Json
$files=@(Get-ChildItem $OutputDirectory -Filter ('TailscaleQuickRepair-Standalone-'+$version.version+'.exe') -File)
if($files.Count -ne 1){throw 'One standalone installer is required.'}
$exe=$files[0].FullName
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false
$root=Join-Path $env:TEMP ('TqrBundleTests-'+[Guid]::NewGuid().ToString('N'))
$fixture=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$ownsFixture=$false
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw ('Standalone check failed: '+$Name)}
    Write-Host ('PASS standalone: '+$Name)
}
function Must-Refuse([scriptblock]$Operation,[string]$Name){
    $rejected=$false;$kind='NoException'
    try{& $Operation|Out-Null}catch{$e=$_.Exception;while($e.InnerException){$e=$e.InnerException};$kind=$e.GetType().FullName;$rejected=($e -is [IO.InvalidDataException] -or $e -is [IO.IOException])}
    if(-not $rejected){Write-Host ('Unexpected rejection result type: '+$kind)}
    Check $rejected $Name
}
try {
    New-Item -ItemType Directory -Path $root|Out-Null
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
    $type=$assembly.GetType('Tqr.EmbeddedSetupPackage',$true)
    $flags=[Reflection.BindingFlags]'Static,Instance,Public,NonPublic'
    $read=$type.GetMethod('Read',$flags);$parse=$type.GetMethod('ParseMetadata',$flags)
    $copy=$type.GetMethod('CopyVerified',$flags)
    $meta=$read.Invoke($null,@())
    Check ($null -ne $meta) 'Embedded metadata and payload are present'
    $target=$type.GetMethod('RequireTarget',$flags)
    [void]$target.Invoke($meta,[object[]]@([int64]$version.versionCode))
    Must-Refuse {$target.Invoke($meta,[object[]]@([int64]1))} 'A different requested version is refused'
    $stream=$assembly.GetManifestResourceStream('Tqr.SetupMetadata')
    $reader=New-Object IO.StreamReader $stream
    try{$metadata=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    Check ($metadata.repository -ceq 'coachedai/tailscale-repair-clean' -and [int64]$metadata.repositoryId -eq 1398720044 -and $metadata.version -ceq $version.version) 'Bundle identifies the exact repository and version'
    $hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    Check ((Get-Content -LiteralPath ($exe+'.sha256') -Raw).Trim() -ceq $hash) 'Standalone file matches its external checksum'
    $validJson=[string]($metadata|ConvertTo-Json -Compress)
    $roundTrip=$parse.Invoke($null,[object[]]@([string]$validJson))
    Check ($null -ne $roundTrip) 'Valid metadata reaches the native parser through reflection'
    foreach($field in @('repository','repositoryId','sha256','size','versionCode','channel')){
        $bad=$metadata|ConvertTo-Json -Compress|ConvertFrom-Json
        switch($field){
            'repository' {$bad.repository='coachedai/unrelated-project'}
            'repositoryId' {$bad.repositoryId=1}
            'sha256' {$bad.sha256='not-a-hash'}
            'size' {$bad.size=-1}
            'versionCode' {$bad.versionCode='123'}
            'channel' {$bad.channel='unknown'}
        }
        $json=$bad|ConvertTo-Json -Compress
        Must-Refuse {$parse.Invoke($null,[object[]]@([string]$json))} ('Invalid '+$field+' is refused')
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes('Synthetic bundle fixture')
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $destination=Join-Path $root 'copied.dat'
    $memory=New-Object IO.MemoryStream(,$bytes)
    try{[void]$copy.Invoke($null,[object[]]@([IO.Stream]$memory,[string]$destination,[int64]$bytes.Length,[string]$digest))}finally{$memory.Dispose()}
    Check ([IO.File]::ReadAllText($destination) -ceq 'Synthetic bundle fixture') 'Bounded copy verifies exact length and SHA-256'
    $memory=New-Object IO.MemoryStream(,$bytes)
    try{Must-Refuse {$copy.Invoke($null,[object[]]@([IO.Stream]$memory,[string]$destination,[int64]$bytes.Length,[string]$digest))} 'Existing destination is not overwritten'}finally{$memory.Dispose()}
    foreach($size in @([int64]($bytes.Length-1),[int64]($bytes.Length+1))){
        $memory=New-Object IO.MemoryStream(,$bytes);$path=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.dat')
        try{Must-Refuse {$copy.Invoke($null,[object[]]@([IO.Stream]$memory,[string]$path,[int64]$size,[string]$digest))} 'Truncated or excessive payload is refused'}finally{$memory.Dispose()}
    }
    $memory=New-Object IO.MemoryStream(,$bytes);$path=Join-Path $root 'wrong-hash.dat'
    try{Must-Refuse {$copy.Invoke($null,[object[]]@([IO.Stream]$memory,[string]$path,[int64]$bytes.Length,[string]('0'*64)))} 'Incorrect SHA-256 is refused'}finally{$memory.Dispose()}
    $payload=Join-Path $root 'payload.zip'
    [void]$type.GetMethod('CopyTo',$flags).Invoke($meta,[object[]]@([string]$payload))
    $expanded=Join-Path $root 'expanded'
    [IO.Compression.ZipFile]::ExtractToDirectory($payload,$expanded)
    & (Join-Path $PSScriptRoot 'privacy-scan.ps1') -Root $expanded -SkipRepositoryIdentity
    Check $true 'Exact embedded package passes expanded privacy scan'
    $ui=[IO.File]::ReadAllText((Join-Path $expanded 'app/Tailscale-Repair-UI.ps1'))
    $versionMatches=[regex]::Matches($ui,'(?m)^\$ProductVersion\s*=\s*''([^'']+)''\s*$')
    $codeMatches=[regex]::Matches($ui,'(?m)^\$ProductVersionCode\s*=\s*\[int64\](\d+)\s*$')
    Check ($versionMatches.Count -eq 1 -and $versionMatches[0].Groups[1].Value -ceq $version.version) 'Embedded interface identifies the exact candidate version'
    Check ($codeMatches.Count -eq 1 -and [int64]$codeMatches[0].Groups[1].Value -eq $version.versionCode) 'Embedded interface retains the exact monotonic version code'
    $hostType=$assembly.GetType('PublicSetupHost',$true)
    Check ([int]$hostType.GetMethod('VerifyEmbeddedPackage',$flags).Invoke($null,@()) -eq 0) 'Native Setup verifies every embedded install file without installing'
    # This is synthetic current-layout acceptance, not a genuine released upgrade.
    Check (-not (Test-Path -LiteralPath $fixture)) 'No existing application state is used by the fixture'
    New-Item -ItemType Directory -Path $fixture|Out-Null;$ownsFixture=$true
    $config=Join-Path $fixture 'config.json'
    $content='{ "peer": "fixture-device.invalid", "retainedSetting": true }'
    [IO.File]::WriteAllText($config,$content)
    $preserve=$hostType.GetMethod('PreserveOrWriteConfig',$flags)
    [void]$preserve.Invoke($null,[object[]]@('fixture-device.invalid',$true))
    Check ([IO.File]::ReadAllText($config) -ceq $content) 'Upgrade preserves complete configuration bytes and additional fields'
    Must-Refuse {$preserve.Invoke($null,[object[]]@('another-fixture.invalid',$true))} 'Changed target is refused rather than overwriting settings'
    [IO.File]::WriteAllText((Join-Path $fixture 'version.user.json'),'{"versionCode":40000000}')
    Must-Refuse {$type.GetMethod('RefuseDowngrade',$flags).Invoke($meta,[object[]]@([string]$fixture))} 'A newer installed version is not downgraded'
    Check ([IO.File]::ReadAllText($config) -ceq $content) 'Refused operations preserve configuration'
    $passed=$true
} finally {
    if($ownsFixture){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop}
    if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
    [pscustomobject]@{passed=$passed;source=$env:GITHUB_SHA;cases=@($cases.ToArray());scope='Exact standalone package, native verification and synthetic configuration preservation. Not genuine released-version or real desktop acceptance.'}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $EvidenceDirectory 'standalone-setup-results.json') -Encoding UTF8
}
