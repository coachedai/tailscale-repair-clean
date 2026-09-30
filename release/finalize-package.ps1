param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-TrustedRelativePath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Root,

        [Parameter(Mandatory=$true)]
        [string]$FullName
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )

    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    $fileFull = [IO.Path]::GetFullPath($FullName)

    if (-not $fileFull.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Package file escapes the package root: $fileFull"
    }

    $relative = $fileFull.Substring($prefix.Length).Replace('\','/')

    if (
        [string]::IsNullOrWhiteSpace($relative) -or
        $relative.StartsWith('/') -or
        $relative.Contains(':') -or
        @($relative.Split('/')) -contains '..'
    ) {
        throw "Invalid package-relative path: $relative"
    }

    return $relative
}

function Assert-PackageManifest {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Root,

        [Parameter(Mandatory=$true)]
        $Manifest
    )

    if ([int]$Manifest.schema -ne 1) {
        throw 'Package manifest schema must be 1.'
    }

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar

    $expected = @(
        'app/Tailscale-Repair-UI.ps1',
        'app/TailscaleQuickRepairUpdater.exe',
        'version.json'
    )

    $manifestPaths = @(
        $Manifest.files |
            ForEach-Object { [string]$_.path }
    )

    $actualPaths = @(
        Get-ChildItem -LiteralPath $Root -File -Recurse |
            Where-Object { $_.Name -ne 'package-manifest.json' } |
            ForEach-Object {
                Get-TrustedRelativePath -Root $Root -FullName $_.FullName
            } |
            Sort-Object
    )

    $manifestKey = (@($manifestPaths | Sort-Object) -join "`n")
    $actualKey = (@($actualPaths | Sort-Object) -join "`n")
    $expectedKey = (@($expected | Sort-Object) -join "`n")

    if ($manifestKey -ne $actualKey) {
        throw (
            'Package manifest file list does not exactly match the packaged files. ' +
            "Manifest=[$($manifestPaths -join ', ')] Actual=[$($actualPaths -join ', ')]"
        )
    }

    if ($actualKey -ne $expectedKey) {
        throw "Unexpected native update package contents: $($actualPaths -join ', ')"
    }

    foreach ($entry in @($Manifest.files)) {
        $relative = [string]$entry.path

        if (
            [string]::IsNullOrWhiteSpace($relative) -or
            $relative.StartsWith('/') -or
            $relative.Contains(':') -or
            @($relative.Split('/')) -contains '..'
        ) {
            throw "Unsafe package-manifest path: $relative"
        }

        $candidate = [IO.Path]::GetFullPath(
            (Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        )

        if (-not $candidate.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Package-manifest path escapes package root: $relative"
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Package-manifest file does not exist: $relative"
        }

        $file = Get-Item -LiteralPath $candidate
        $hash = (
            Get-FileHash -LiteralPath $candidate -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        if ([int64]$entry.size -ne [int64]$file.Length) {
            throw "Package-manifest size mismatch: $relative"
        }

        if ([string]$entry.sha256 -ne $hash) {
            throw "Package-manifest SHA-256 mismatch: $relative"
        }
    }
}

$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$zips = @(Get-ChildItem -LiteralPath $output -Filter '*.zip' -File)

if ($zips.Count -ne 1) {
    throw "Expected exactly one update ZIP in $output; found $($zips.Count)."
}

$zip = $zips[0]
$work = Join-Path $env:TEMP ('TQR-PackageFinalize-' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $work 'package'
$verifyRoot = Join-Path $work 'verify'

New-Item -ItemType Directory -Path $root -Force | Out-Null
New-Item -ItemType Directory -Path $verifyRoot -Force | Out-Null

try {
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $root -Force

    $versionPath = Join-Path $root 'version.json'

    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw 'Package is missing version.json.'
    }

    $version = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json

    if (
        [string]::IsNullOrWhiteSpace([string]$version.version) -or
        [int64]$version.versionCode -le 0
    ) {
        throw 'Package version.json is invalid.'
    }

    $uiPath = Join-Path $root 'app\Tailscale-Repair-UI.ps1'

    if (-not (Test-Path -LiteralPath $uiPath -PathType Leaf)) {
        throw 'Package is missing the Quick Repair UI.'
    }

    & (Join-Path $PSScriptRoot 'polish-ui-v2.ps1') `
        -Path $uiPath `
        -Version ([string]$version.version) `
        -VersionCode ([int64]$version.versionCode)

    $entries = @(
        Get-ChildItem -LiteralPath $root -File -Recurse |
            Where-Object { $_.Name -ne 'package-manifest.json' } |
            ForEach-Object {
                [ordered]@{
                    path = Get-TrustedRelativePath -Root $root -FullName $_.FullName
                    sha256 = (
                        Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                    size = [int64]$_.Length
                }
            } |
            Sort-Object { $_.path }
    )

    $manifest = [ordered]@{
        schema = 1
        product = 'Tailscale Quick Repair'
        version = [string]$version.version
        versionCode = [int64]$version.versionCode
        files = $entries
    }

    Assert-PackageManifest -Root $root -Manifest ([pscustomobject]$manifest)

    $manifestPath = Join-Path $root 'package-manifest.json'
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    [IO.File]::WriteAllText(
        $manifestPath,
        ($manifest | ConvertTo-Json -Depth 8),
        $utf8
    )

    $serialized = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-PackageManifest -Root $root -Manifest $serialized

    Remove-Item -LiteralPath $zip.FullName -Force

    Compress-Archive `
        -Path (Join-Path $root '*') `
        -DestinationPath $zip.FullName `
        -CompressionLevel Optimal

    $shaPath = $zip.FullName + '.sha256'
    $sha = (
        Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    Set-Content -LiteralPath $shaPath -Value $sha -Encoding ASCII

    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $verifyRoot -Force

    $roundTripManifestPath = Join-Path $verifyRoot 'package-manifest.json'

    if (-not (Test-Path -LiteralPath $roundTripManifestPath -PathType Leaf)) {
        throw 'Final ZIP is missing package-manifest.json.'
    }

    $roundTripManifest = Get-Content `
        -LiteralPath $roundTripManifestPath `
        -Raw |
        ConvertFrom-Json

    Assert-PackageManifest -Root $verifyRoot -Manifest $roundTripManifest

    if (
        [string]$roundTripManifest.version -ne [string]$version.version -or
        [int64]$roundTripManifest.versionCode -ne [int64]$version.versionCode
    ) {
        throw 'Final ZIP package metadata does not match version.json.'
    }

    $roundTripUi = Join-Path $verifyRoot 'app\Tailscale-Repair-UI.ps1'
    $roundTripUiText = [IO.File]::ReadAllText($roundTripUi, [Text.Encoding]::UTF8)

    foreach ($required in @(
        'QuickRepairWindowTheme',
        'VerticalScrollBarVisibility="Hidden"',
        ('Current ' + [string]$version.version + ' - Check GitHub for updates.')
    )) {
        if ($roundTripUiText -notmatch [regex]::Escape($required)) {
            throw "Final ZIP is missing UI polish marker: $required"
        }
    }

    Write-Host "Package manifest round-trip passed: $($zip.Name)"
    Write-Host "Manifest paths: $(@($roundTripManifest.files | ForEach-Object { [string]$_.path }) -join ', ')"
    Write-Host "Final SHA256=$sha"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
