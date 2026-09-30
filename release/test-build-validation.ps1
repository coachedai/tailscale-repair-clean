param(
    [Parameter(Mandatory=$true)][string]$UpdaterPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateSet('PublicRelease','Development')][string]$ValidationProfile='PublicRelease'
)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$passed=$false
$publicFeedVerified=$false
$cases=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw ('Build validation failed: '+$Name)}
}
try {
    if($ValidationProfile -eq 'Development'){
        Check ($env:GITHUB_ACTIONS -ceq 'true' -and $env:GITHUB_REPOSITORY -ceq 'coachedai/tailscale-repair-clean' -and $env:GITHUB_REPOSITORY_ID -ceq '1398720044') 'Development profile requires the bound CI repository'
        $event=Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw|ConvertFrom-Json
        Check ($event.repository.private -eq $false -and [int64]$event.repository.id -eq 1398720044 -and [string]$event.repository.full_name -ceq 'coachedai/tailscale-repair-clean') 'Development profile requires the public bound repository event'
        foreach($name in @('publish.json','preview-publish.json')){
            $p=Get-Content -LiteralPath (Join-Path $PSScriptRoot $name) -Raw|ConvertFrom-Json
            Check ($p.publish -is [bool] -and -not $p.publish) 'Development profile cannot authorize publishing'
        }
    }
    # These tests use the exact compiled updater, without changing its trust rules.
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($UpdaterPath))
    $type=$assembly.GetType('Program',$true)
    $flags=[Reflection.BindingFlags]'Static,Public,NonPublic'
    $map=$type.GetMethod('GetManifestApiUrl',$flags)
    $trust=$type.GetMethod('IsTrustedReleaseUrl',$flags)
    foreach($channel in @('stable','preview')){
        $suffix=if($channel -eq 'stable'){'latest.json?ref=main'}else{'preview.json?ref=preview'}
        $expected='https://api.github.com/repos/coachedai/tailscale-repair-clean/contents/updates/'+$suffix
        Check ([string]$map.Invoke($null,[object[]]@($channel)) -ceq $expected) ('Compiled '+$channel+' endpoint is fixed')
    }
    Check ([bool]$trust.Invoke($null,[object[]]@('https://github.com/coachedai/tailscale-repair-clean/releases/download/fixture/package.zip'))) 'Compiled updater accepts only the intended release destination'
    foreach($url in @('http://github.com/coachedai/tailscale-repair-clean/releases/download/fixture/package.zip','https://example.invalid/package.zip','https://github.com/coachedai/unrelated-project/releases/download/fixture/package.zip')){
        Check (-not [bool]$trust.Invoke($null,[object[]]@($url))) 'Compiled updater rejects an untrusted release destination'
    }
    if($ValidationProfile -eq 'PublicRelease'){
        # Public release acceptance still requires both unauthenticated product endpoints.
        foreach($channel in @('stable','preview')){
            $p=Start-Process -FilePath $UpdaterPath -ArgumentList ('--network-self-test --channel '+$channel) -WindowStyle Hidden -Wait -PassThru
            Check ($p.ExitCode -eq 0) ('Public '+$channel+' HTTPS feed is available')
        }
        $publicFeedVerified=$true
    } else {
        Write-Host 'Development build: public feed readiness is NOT verified. Not release acceptance.'
    }
    $invalid=Start-Process -FilePath $UpdaterPath -ArgumentList '--network-self-test --channel arbitrary-url' -WindowStyle Hidden -Wait -PassThru
    Check ($invalid.ExitCode -eq 26) 'Unsupported update channel is refused'
    $passed=$true
} finally {
    New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
    [pscustomobject]@{
        schema=1;profile=$ValidationProfile;passed=$passed;publicFeedVerified=$publicFeedVerified
        publishable=($passed -and $publicFeedVerified);source=$env:GITHUB_SHA
        updaterSha256=(Get-FileHash -LiteralPath $UpdaterPath -Algorithm SHA256).Hash.ToLowerInvariant()
        cases=@($cases.ToArray())
    }|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-validation.json') -Encoding UTF8
}
