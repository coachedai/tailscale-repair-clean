param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist-public'),
    [ValidateSet('PublicRelease','Development')][string]$ValidationProfile='PublicRelease'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$versionInfo = Get-Content -LiteralPath (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json
$version = [string]$versionInfo.version
$versionCode = [int64]$versionInfo.versionCode
$safeVersion = $version -replace '[^A-Za-z0-9._-]', '-'

& (Join-Path $PSScriptRoot 'privacy-scan.ps1') -Root $repo -SkipRepositoryIdentity

$required = @(
    'src\app\Tailscale-Repair-UI.ps1',
    'src\app\Advanced-Diagnostics.ps1',
    'src\program\Repair-Backend.ps1',
    'src\program\Auto-Repair-Monitor.ps1',
    'src\native\NativeHost.cs',
    'src\native\PublicSetupHost.cs',
    'src\native\PublicSetupEntry.cs',
    'src\native\UpdaterHost.cs',
    'src\native\UpdaterEntry.cs',
    'release\public-ui.ps1'
)

foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo $relative) -PathType Leaf)) {
        throw "Public installer source is missing: $relative"
    }
}

foreach ($scriptPath in @(
    (Join-Path $repo 'src\app\Advanced-Diagnostics.ps1'),
    (Join-Path $repo 'src\program\Repair-Backend.ps1'),
    (Join-Path $repo 'src\program\Auto-Repair-Monitor.ps1'),
    (Join-Path $repo 'release\public-ui.ps1')
)) {
    [void][scriptblock]::Create([IO.File]::ReadAllText($scriptPath, [Text.Encoding]::UTF8))
}

$backendSource = [IO.File]::ReadAllText(
    (Join-Path $repo 'src\program\Repair-Backend.ps1'),
    [Text.Encoding]::UTF8
)

if (
    $backendSource -match '(?m)^\s*\$Peer\s*=\s*[''\"]\d{1,3}(?:\.\d{1,3}){3}[''\"]'
) {
    throw 'Public repair backend still contains a baked-in peer address.'
}

if ($backendSource -notmatch [regex]::Escape("Join-Path `$env:LOCALAPPDATA 'TailscaleQuickRepair'")) {
    throw 'Public repair backend does not load local Quick Repair configuration.'
}

$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $compiler) { throw 'The .NET Framework C# compiler could not be located.' }

$frameworkDir = Split-Path -Parent $compiler
$webExtensions = Join-Path $frameworkDir 'System.Web.Extensions.dll'
$compression = Join-Path $frameworkDir 'System.IO.Compression.dll'
$compressionFs = Join-Path $frameworkDir 'System.IO.Compression.FileSystem.dll'
$windowsForms = Join-Path $frameworkDir 'System.Windows.Forms.dll'
$drawing = Join-Path $frameworkDir 'System.Drawing.dll'

foreach ($assembly in @($webExtensions,$compression,$compressionFs,$windowsForms,$drawing)) {
    if (-not (Test-Path -LiteralPath $assembly)) {
        throw "Required .NET Framework reference is missing: $assembly"
    }
}

$automation = $null
try { $automation = [System.Management.Automation.PowerShell].Assembly.Location } catch {}
if ([string]::IsNullOrWhiteSpace($automation)) { $automation = Join-Path $PSHOME 'System.Management.Automation.dll' }
if (-not (Test-Path -LiteralPath $automation -PathType Leaf)) {
    throw 'System.Management.Automation.dll could not be resolved for the native desktop host.'
}

function Invoke-CSharpBuild {
    param(
        [string]$Output,
        [string[]]$Sources,
        [string[]]$References,
        [string]$MainType,
        [string]$Icon
    )

    $stdout = "$Output.stdout.txt"
    $stderr = "$Output.stderr.txt"
    Remove-Item $Output,$stdout,$stderr -Force -ErrorAction SilentlyContinue

    $args = @('/nologo','/target:winexe','/platform:anycpu','/optimize+',('/main:{0}' -f $MainType),('/out:"{0}"' -f $Output))
    if (-not [string]::IsNullOrWhiteSpace($Icon)) {
        if (-not (Test-Path -LiteralPath $Icon -PathType Leaf)) {
            throw "Native icon file is missing: $Icon"
        }
        $args += ('/win32icon:"{0}"' -f $Icon)
    }
    foreach ($reference in $References) { $args += ('/reference:"{0}"' -f $reference) }
    foreach ($source in $Sources) { $args += ('"{0}"' -f $source) }

    $process = Start-Process -FilePath $compiler -ArgumentList ($args -join ' ') `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
        -WindowStyle Hidden -Wait -PassThru

    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Output)) {
        $details = @()
        if (Test-Path $stdout) { $details += Get-Content $stdout -Raw }
        if (Test-Path $stderr) { $details += Get-Content $stderr -Raw }
        throw "Native compilation failed for $Output.`r`n$($details -join [Environment]::NewLine)"
    }

    Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
}

function New-QuickRepairIcon {
    param([Parameter(Mandatory=$true)][string]$Path)

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $bitmap = New-Object System.Drawing.Bitmap 64,64
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $darkBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(18,25,37))
    $blueBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(8,102,255))
    $rounded = New-Object System.Drawing.Drawing2D.GraphicsPath

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $rounded.AddArc(4,4,16,16,180,90)
        $rounded.AddArc(44,4,16,16,270,90)
        $rounded.AddArc(44,44,16,16,0,90)
        $rounded.AddArc(4,44,16,16,90,90)
        $rounded.CloseFigure()
        $graphics.FillPath($darkBrush,$rounded)

        foreach ($point in @(
            @(32,15),
            @(20,24),
            @(44,24),
            @(32,32),
            @(20,40),
            @(44,40),
            @(32,49)
        )) {
            $graphics.FillEllipse(
                $blueBrush,
                [int]$point[0]-3,
                [int]$point[1]-3,
                6,
                6
            )
        }

        $hIcon = $bitmap.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hIcon)
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)

        try {
            $icon.Save($stream)
        }
        finally {
            $stream.Dispose()
            $icon.Dispose()
        }
    }
    finally {
        $rounded.Dispose()
        $blueBrush.Dispose()
        $darkBrush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Quick Repair icon generation failed.'
    }
}

function Get-RelativePackagePath {
    param([string]$Root,[string]$FullName)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $fileFull = [IO.Path]::GetFullPath($FullName)
    if (-not $fileFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Package file escapes root: $fileFull"
    }
    return $fileFull.Substring($rootFull.Length).Replace('\','/')
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$work = Join-Path $env:TEMP ('TQR-Public-' + [Guid]::NewGuid().ToString('N'))
$baseOut = Join-Path $work 'base-update'
$packageRoot = Join-Path $work 'setup-package'
$packageApp = Join-Path $packageRoot 'app'
$packageProgram = Join-Path $packageRoot 'program'
New-Item -ItemType Directory -Path $baseOut,$packageApp,$packageProgram -Force | Out-Null

try {
    $brandIcon = Join-Path $work 'QuickRepair.ico'
    New-QuickRepairIcon -Path $brandIcon

    # Reuse the already-hardened normal release build for the UI + updater,
    # then expand it into the complete fresh-install bundle.
    & (Join-Path $PSScriptRoot 'build.ps1') -OutputDirectory $baseOut -ValidationProfile $ValidationProfile
    & (Join-Path $PSScriptRoot 'finalize-package.ps1') -OutputDirectory $baseOut
    & (Join-Path $PSScriptRoot 'add-native-setup-routing.ps1') -OutputDirectory $baseOut

    $baseZip = @(Get-ChildItem -LiteralPath $baseOut -Filter 'TailscaleQuickRepair-*.zip' -File)
    if ($baseZip.Count -ne 1) { throw "Expected one validated base update ZIP; found $($baseZip.Count)." }
    Expand-Archive -LiteralPath $baseZip[0].FullName -DestinationPath $packageRoot -Force
    Remove-Item -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Force -ErrorAction SilentlyContinue
    # The handoff marker belongs only to the ordinary user-level bridge. A full
    # Setup package is already the protected installer and must not carry it.
    Remove-Item -LiteralPath (Join-Path $packageApp 'protected-update.json') -Force -ErrorAction SilentlyContinue

    $nativeHost = Join-Path $packageApp 'TailscaleQuickRepair.exe'
    $setupHostInstalled = Join-Path $packageApp 'TailscaleQuickRepairSetup.exe'
    $setupAsset = Join-Path $OutputDirectory "TailscaleQuickRepair-Setup-$safeVersion.exe"

    Invoke-CSharpBuild -Output $nativeHost `
        -Sources @((Join-Path $repo 'src\native\NativeHost.cs')) `
        -References @($automation,$windowsForms) -MainType 'NativeHost' -Icon $brandIcon

    Invoke-CSharpBuild -Output $setupHostInstalled `
        -Sources @(
            (Join-Path $repo 'src\native\PublicSetupHost.cs'),
            (Join-Path $repo 'src\native\PublicSetupEntry.cs'),
            (Join-Path $repo 'src\native\OperationGate.cs')
        ) `
        -References @($webExtensions,$compression,$compressionFs,$windowsForms,$drawing) `
        -MainType 'PublicSetupEntry' -Icon $brandIcon

    Copy-Item -LiteralPath $setupHostInstalled -Destination $setupAsset -Force

    $hostTest = Start-Process -FilePath $nativeHost -ArgumentList '--self-test-host' -WindowStyle Hidden -Wait -PassThru
    if ($hostTest.ExitCode -ne 0) { throw "Native desktop host self-test failed: $($hostTest.ExitCode)." }

    $setupTest = Start-Process -FilePath $setupAsset -ArgumentList '--self-test-installer' -WindowStyle Hidden -Wait -PassThru
    if ($setupTest.ExitCode -ne 0) { throw "Native public setup self-test failed: $($setupTest.ExitCode)." }

    Copy-Item (Join-Path $repo 'src\app\Advanced-Diagnostics.ps1') (Join-Path $packageApp 'Advanced-Diagnostics.ps1') -Force
    Copy-Item (Join-Path $repo 'src\program\Auto-Repair-Monitor.ps1') (Join-Path $packageProgram 'Auto-Repair-Monitor.ps1') -Force

    # The source backend intentionally starts conservative. The shipped public
    # package accepts either a Tailscale IP or a valid MagicDNS hostname.
    $backend = $backendSource
    $oldPeerParser = @'
        $parsed = $null

        if (-not [System.Net.IPAddress]::TryParse($candidate, [ref]$parsed)) {
            return ''
        }

        return $parsed.ToString()
'@
    $newPeerParser = @'
        $parsed = $null

        if ([System.Net.IPAddress]::TryParse($candidate, [ref]$parsed)) {
            return $parsed.ToString()
        }

        if ($candidate -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$') {
            return $candidate
        }

        return ''
'@
    if (-not $backend.Contains($oldPeerParser)) { throw 'Could not locate public backend target parser.' }
    $backend = $backend.Replace($oldPeerParser,$newPeerParser)
    [void][scriptblock]::Create($backend)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $packageProgram 'Repair-Backend.ps1'),$backend,$utf8Bom)

    $uiPath = Join-Path $packageApp 'Tailscale-Repair-UI.ps1'
    # Already transformed and routed in the shared base package; never apply twice.
    Copy-Item (Join-Path $packageApp 'TailscaleQuickRepair.Operations.dll') (Join-Path $packageProgram 'TailscaleQuickRepair.Operations.dll') -Force

    [void][scriptblock]::Create([IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8))
    foreach ($scriptPath in @(
        (Join-Path $packageApp 'Advanced-Diagnostics.ps1'),
        (Join-Path $packageProgram 'Auto-Repair-Monitor.ps1'),
        (Join-Path $packageProgram 'Repair-Backend.ps1')
    )) {
        [void][scriptblock]::Create([IO.File]::ReadAllText($scriptPath,[Text.Encoding]::UTF8))
    }

    $uiText = [IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8)
    $xamlMatch = [regex]::Match($uiText,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    if (-not $xamlMatch.Success) { throw 'Public setup UI XAML was not found.' }
    [xml]$xamlDoc = $xamlMatch.Groups['xaml'].Value
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    $testWindow = $null
    try {
        $testWindow = [Windows.Markup.XamlReader]::Load($reader)
        if (-not $testWindow) { throw 'Public setup UI WPF validation returned no window.' }
    }
    finally {
        try { $reader.Close() } catch {}
        try { if ($testWindow -is [System.Windows.Window]) { $testWindow.Close() } } catch {}
    }

    Copy-Item (Join-Path $repo 'version.json') (Join-Path $packageRoot 'version.json') -Force

    & (Join-Path $PSScriptRoot 'write-integrity-manifest.ps1') -AppDirectory $packageApp -VersionPath (Join-Path $packageRoot 'version.json') -Profile 'setup'

    $entries = @(
        Get-ChildItem -LiteralPath $packageRoot -File -Recurse |
            Where-Object { $_.Name -ne 'package-manifest.json' } |
            ForEach-Object {
                [ordered]@{
                    path = Get-RelativePackagePath -Root $packageRoot -FullName $_.FullName
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    size = [int64]$_.Length
                }
            } |
            Sort-Object { $_.path }
    )

    foreach ($needed in @(
        'app/TailscaleQuickRepair.exe',
        'app/TailscaleQuickRepairSetup.exe',
        'app/TailscaleQuickRepairUpdater.exe',
        'app/Tailscale-Repair-UI.ps1',
        'app/Advanced-Diagnostics.ps1',
        'program/Repair-Backend.ps1',
        'program/Auto-Repair-Monitor.ps1',
        'version.json'
    )) {
        if ($needed -notin @($entries | ForEach-Object { $_.path })) {
            throw "Public setup package is missing required component: $needed"
        }
    }

    $manifest = [ordered]@{
        schema = 1
        product = 'Tailscale Quick Repair'
        version = $version
        versionCode = $versionCode
        files = $entries
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Encoding UTF8

    & (Join-Path $PSScriptRoot 'privacy-scan.ps1') -Root $packageRoot -SkipRepositoryIdentity

    $setupZip = Join-Path $OutputDirectory "TailscaleQuickRepair-SetupPackage-$safeVersion.zip"
    Remove-Item $setupZip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $setupZip -CompressionLevel Optimal

    $setupSha = (Get-FileHash -LiteralPath $setupZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $setupSha | Set-Content -LiteralPath "$setupZip.sha256" -Encoding ASCII

    $setupExeSha = (Get-FileHash -LiteralPath $setupAsset -Algorithm SHA256).Hash.ToLowerInvariant()
    $setupExeSha | Set-Content -LiteralPath "$setupAsset.sha256" -Encoding ASCII

    $metadata = [ordered]@{
        schema = 1
        version = $version
        versionCode = $versionCode
        setupPackage = [ordered]@{ file = (Split-Path $setupZip -Leaf); sha256 = $setupSha; size = (Get-Item $setupZip).Length }
        setupExe = [ordered]@{ file = (Split-Path $setupAsset -Leaf); sha256 = $setupExeSha; size = (Get-Item $setupAsset).Length }
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'public-setup-metadata.json') -Encoding UTF8

    Copy-Item -LiteralPath (Join-Path $baseOut 'build-validation.json') -Destination (Join-Path $OutputDirectory 'build-validation.json') -Force
    Write-Host ('Full Setup package validation passed ('+$ValidationProfile+').')
    Write-Host "SETUP_EXE=$setupAsset"
    Write-Host "SETUP_PACKAGE=$setupZip"
    Write-Host "SETUP_SHA256=$setupSha"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
