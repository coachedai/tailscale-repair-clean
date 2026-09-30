param(
    [Parameter(Mandatory=$true)][string]$AppDirectory,
    [Parameter(Mandatory=$true)][string]$VersionPath,
    [Parameter(Mandatory=$true)][ValidateSet('update','setup')][string]$Profile
)
$ErrorActionPreference = 'Stop'
$app = (Resolve-Path -LiteralPath $AppDirectory).Path
$version = Get-Content -LiteralPath $VersionPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace([string]$version.version) -or [int64]$version.versionCode -le 0) {
    throw 'Invalid release version for integrity manifest.'
}
$required = @(
    'Tailscale-Repair-UI.ps1',
    'TailscaleQuickRepairUpdater.exe',
    'TailscaleQuickRepairSetup.exe',
    'TailscaleQuickRepair.Operations.dll',
    'Advanced-Diagnostics.ps1'
)
if ($Profile -eq 'setup') {
    $required += 'TailscaleQuickRepair.exe'
}
$files = @(Get-ChildItem -LiteralPath $app -File | Where-Object { $_.Name -ne 'integrity-manifest.json' })
if ($files.Count -ne $required.Count -or @(Get-ChildItem -LiteralPath $app -Directory).Count -ne 0) {
    throw "Unexpected app payload for $Profile integrity profile."
}
$entries = @()
foreach ($name in ($required | Sort-Object)) {
    $path = Join-Path $app $name
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0) {
        throw "Invalid release file: $name"
    }
    $entries += [ordered]@{
        path = $name
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        size = [int64]$item.Length
    }
}
$manifest = [ordered]@{
    schema = 1
    product = 'Tailscale Quick Repair'
    version = [string]$version.version
    versionCode = [int64]$version.versionCode
    algorithm = 'SHA256'
    profile = $Profile
    files = $entries
}
$manifestPath = Join-Path $app 'integrity-manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
$roundTrip = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([int64]$roundTrip.versionCode -ne [int64]$version.versionCode -or
    [string]$roundTrip.version -cne [string]$version.version -or
    @($roundTrip.files).Count -ne $required.Count) {
    throw 'Integrity manifest round-trip failed.'
}
foreach ($entry in @($roundTrip.files)) {
    $path = Join-Path $app ([string]$entry.path)
    if ([int64](Get-Item -LiteralPath $path).Length -ne [int64]$entry.size -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.sha256) {
        throw 'Final packaged file changed after integrity generation.'
    }
}
Write-Host "Final $Profile integrity manifest verified: $($entries.Count) files, version $($version.version)."
