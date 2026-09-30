param(
    [string]$EvidenceDirectory = '.\upgrade-evidence'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Published RC1 bridge acceptance requires Windows PowerShell 5.1.'
}
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean') {
    throw 'Published RC1 bridge acceptance is restricted to the disposable GitHub runner.'
}

$Repository = 'coachedai/tailscale-repair-clean'
$Tag = 'v3.0.0-rc.1'
$ExpectedTarget = '2555bf4af30845d2c722964e289cfdfe15a412bf'
$ExpectedAssets = [ordered]@{
    'TailscaleQuickRepair-3.0.0-rc.1.zip' = [pscustomobject]@{
        size = [int64]134104
        sha256 = 'dcf715e2289dff3c0077f6de43c7195750ec81066c82fcf9e5d6a8eff7d8423d'
    }
    'TailscaleQuickRepair-3.0.0-rc.1.zip.sha256' = [pscustomobject]@{
        size = [int64]66
        sha256 = 'cdbcf48eeddc01a591f4ac9ebb911220e351a68c7e233cafe3cd8040408b25aa'
    }
    'TailscaleQuickRepair-SetupPackage-3.0.0-rc.1.zip' = [pscustomobject]@{
        size = [int64]184330
        sha256 = 'e6097330a68153c3db65a3f33dad23508e2c6cb18da85ddc88c773594ecfa05c'
    }
    'TailscaleQuickRepair-SetupPackage-3.0.0-rc.1.zip.sha256' = [pscustomobject]@{
        size = [int64]66
        sha256 = '8162b50689de28c40de1975eb077be49c22734d8911e5acb5f2e428c1dd992b1'
    }
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$root = Join-Path $env:RUNNER_TEMP ('tqr-published-rc1-' + [Guid]::NewGuid().ToString('N'))
$download = Join-Path $root 'assets'
New-Item -ItemType Directory -Path $download -Force | Out-Null
$passed = $false
$failureType = ''
$assetEvidence = New-Object 'Collections.Generic.List[object]'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $apiHeaders = @{ 'User-Agent' = 'TailscaleQuickRepair-CI'; 'Accept' = 'application/vnd.github+json' }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:GITHUB_TOKEN)) {
        $apiHeaders['Authorization'] = 'Bearer ' + $env:GITHUB_TOKEN
    }
    $release = Invoke-RestMethod -UseBasicParsing -Headers $apiHeaders -Uri ('https://api.github.com/repos/' + $Repository + '/releases/tags/' + $Tag)

    if ([string]$release.tag_name -cne $Tag -or [bool]$release.draft -or -not [bool]$release.prerelease -or
        [string]$release.target_commitish -cne $ExpectedTarget) {
        throw 'Published RC1 release identity does not match the frozen acceptance target.'
    }

    $remoteAssets = @($release.assets)
    if ($remoteAssets.Count -ne $ExpectedAssets.Count) {
        throw 'Published RC1 contains an unexpected asset set.'
    }

    foreach ($name in $ExpectedAssets.Keys) {
        $expected = $ExpectedAssets[$name]
        $matches = @($remoteAssets | Where-Object { [string]$_.name -ceq $name })
        if ($matches.Count -ne 1) { throw ('Published RC1 asset is missing or duplicated: ' + $name) }
        $asset = $matches[0]
        if ([int64]$asset.size -ne [int64]$expected.size -or
            [string]$asset.digest -cne ('sha256:' + [string]$expected.sha256)) {
            throw ('Published RC1 asset metadata drifted: ' + $name)
        }

        $url = [string]$asset.browser_download_url
        $prefix = 'https://github.com/' + $Repository + '/releases/download/' + $Tag + '/'
        if (-not $url.StartsWith($prefix,[StringComparison]::Ordinal)) {
            throw ('Published RC1 asset URL left the expected repository/tag: ' + $name)
        }

        $destination = Join-Path $download $name
        Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent'='TailscaleQuickRepair-CI' } -Uri $url -OutFile $destination
        $file = Get-Item -LiteralPath $destination
        $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([int64]$file.Length -ne [int64]$expected.size -or $actual -cne [string]$expected.sha256) {
            throw ('Downloaded RC1 asset differs from its frozen release identity: ' + $name)
        }

        $assetEvidence.Add([pscustomobject]@{ name=$name; size=[int64]$file.Length; sha256=$actual })
    }

    foreach ($packageName in @(
        'TailscaleQuickRepair-3.0.0-rc.1.zip',
        'TailscaleQuickRepair-SetupPackage-3.0.0-rc.1.zip'
    )) {
        $package = Join-Path $download $packageName
        $sidecar = $package + '.sha256'
        $declared = ([IO.File]::ReadAllText($sidecar,[Text.Encoding]::ASCII)).Trim().ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($declared -notmatch '^[a-f0-9]{64}$' -or $declared -cne $actual) {
            throw ('Published RC1 SHA-256 sidecar does not match its package: ' + $packageName)
        }

        $scanRoot = Join-Path $root ('scan-' + [Guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $package -DestinationPath $scanRoot
        & (Join-Path $PSScriptRoot 'privacy-scan.ps1') -Root $scanRoot -SkipRepositoryIdentity
        Remove-Item -LiteralPath $scanRoot -Recurse -Force
    }

    & (Join-Path $PSScriptRoot 'test-field-preview.ps1') -OutputDirectory $download -EvidenceDirectory $EvidenceDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Exact published RC1 field acceptance failed.' }

    $passed = $true
}
catch {
    $failureType = $_.Exception.GetType().FullName
    throw
}
finally {
    [pscustomobject]@{
        passed = $passed
        tag = $Tag
        releaseTarget = $ExpectedTarget
        assets = @($assetEvidence.ToArray())
        failureType = $failureType
        scope = 'Exact already-published RC1 assets; privacy scan plus developer-only 5.2.1/6.4.0/6.4.3 field bridge acceptance'
    } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $EvidenceDirectory 'published-rc1-field-bridge.json') -Encoding UTF8

    try {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    } catch {}
}

if (-not $passed) { throw 'Published RC1 bridge acceptance failed; inspect privacy-safe evidence.' }
