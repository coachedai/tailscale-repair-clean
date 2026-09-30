param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist'),
    [ValidateSet('PublicRelease','Development')][string]$ValidationProfile='PublicRelease'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$diagnosticsSource = Join-Path $PSScriptRoot '..\src\app\Advanced-Diagnostics.ps1'
if (Test-Path -LiteralPath $diagnosticsSource -PathType Leaf) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($diagnosticsSource,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'Advanced diagnostics source does not parse on Windows PowerShell 5.1.' }
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$versionPath = Join-Path $repo 'version.json'
$packageSpecPath = Join-Path $repo 'release\package.json'

& (Join-Path $PSScriptRoot 'privacy-scan.ps1') `
    -Root $repo `
    -SkipRepositoryIdentity

$versionInfo = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
$packageSpec = Get-Content -LiteralPath $packageSpecPath -Raw | ConvertFrom-Json

$version = [string]$versionInfo.version
$versionCode = [int64]$versionInfo.versionCode
$safeVersion = $version -replace '[^A-Za-z0-9._-]', '-'

if ([string]::IsNullOrWhiteSpace($version) -or $versionCode -le 0) {
    throw 'version.json does not contain a valid version/versionCode.'
}

if ([int]$packageSpec.schema -ne 1) {
    throw 'release/package.json has an unsupported schema.'
}

$required = @(
    'src\app\Tailscale-Repair-UI.ps1',
    'src\native\UpdaterHost.cs',
    'src\native\UpdaterEntry.cs'
)

foreach ($relative in $required) {
    $path = Join-Path $repo $relative

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release source is missing: $relative"
    }
}

function Normalize-UiForWindowsPowerShell {
    param([string]$Text)

    $oldResetApp = "        Set-Step `$AppDot `$AppStep (if ([string]`$preflight.Client -eq 'Running') { 'good' } elseif ([string]`$preflight.Client -eq 'Closed') { 'warn' } else { 'bad' })"
    $newResetApp = @"
        `$appStepState = if ([string]`$preflight.Client -eq 'Running') {
            'good'
        } elseif ([string]`$preflight.Client -eq 'Closed') {
            'warn'
        } else {
            'bad'
        }
        Set-Step `$AppDot `$AppStep `$appStepState
"@

    $oldResetService = "        Set-Step `$ServiceDot `$ServiceStep (if ([string]`$preflight.Service -eq 'Running') { 'good' } elseif ([string]`$preflight.Service -eq 'Stopped') { 'warn' } elseif ([string]`$preflight.Service -eq 'Missing') { 'bad' } else { 'idle' })"
    $newResetService = @"
        `$serviceStepState = if ([string]`$preflight.Service -eq 'Running') {
            'good'
        } elseif ([string]`$preflight.Service -eq 'Stopped') {
            'warn'
        } elseif ([string]`$preflight.Service -eq 'Missing') {
            'bad'
        } else {
            'idle'
        }
        Set-Step `$ServiceDot `$ServiceStep `$serviceStepState
"@

    $oldCardApp = @"
        Set-Step `$AppDot `$AppStep (
            if ([string]`$Data.client -eq 'Running') { 'good' }
            elseif ([string]`$Data.client -eq 'Closed') { 'warn' }
            elseif ([int]`$Data.progress -ge 22) { 'bad' }
            else { 'active' }
        )
"@
    $newCardApp = @"
        `$appStepState = if ([string]`$Data.client -eq 'Running') {
            'good'
        } elseif ([string]`$Data.client -eq 'Closed') {
            'warn'
        } elseif ([int]`$Data.progress -ge 22) {
            'bad'
        } else {
            'active'
        }
        Set-Step `$AppDot `$AppStep `$appStepState
"@

    $oldCardService = @"
        Set-Step `$ServiceDot `$ServiceStep (
            if ([string]`$Data.service -eq 'Running') { 'good' }
            elseif ([string]`$Data.service -eq 'Stopped') { 'warn' }
            elseif ([int]`$Data.progress -ge 48) { 'bad' }
            else { 'active' }
        )
"@
    $newCardService = @"
        `$serviceStepState = if ([string]`$Data.service -eq 'Running') {
            'good'
        } elseif ([string]`$Data.service -eq 'Stopped') {
            'warn'
        } elseif ([int]`$Data.progress -ge 48) {
            'bad'
        } else {
            'active'
        }
        Set-Step `$ServiceDot `$ServiceStep `$serviceStepState
"@

    $Text = $Text.Replace($oldResetApp, $newResetApp.TrimEnd("`r", "`n"))
    $Text = $Text.Replace($oldResetService, $newResetService.TrimEnd("`r", "`n"))
    $Text = $Text.Replace($oldCardApp.TrimEnd("`r", "`n"), $newCardApp.TrimEnd("`r", "`n"))
    $Text = $Text.Replace($oldCardService.TrimEnd("`r", "`n"), $newCardService.TrimEnd("`r", "`n"))

    if (
        $Text -match 'Set-Step\s+\$AppDot\s+\$AppStep\s+\(' -or
        $Text -match 'Set-Step\s+\$ServiceDot\s+\$ServiceStep\s+\('
    ) {
        throw 'Legacy Set-Step expression syntax remains after normalization.'
    }

    return $Text
}

function Convert-UiToNativeUpdater {
    param(
        [string]$Text,
        [string]$ReleaseVersion,
        [int64]$ReleaseVersionCode
    )

    $Text = [regex]::Replace(
        $Text,
        "(?m)^\$ProductVersion\s*=\s*'[^']+'\s*$",
        ('$ProductVersion = ''' + $ReleaseVersion + ''''),
        1
    )

    $Text = [regex]::Replace(
        $Text,
        '(?m)^\$ProductVersionCode\s*=\s*\[int64\]\d+\s*$',
        ('$ProductVersionCode = [int64]' + $ReleaseVersionCode),
        1
    )

    $Text = [regex]::Replace(
        $Text,
        'Text="Current [^"]+ · Check GitHub for updates\."',
        ('Text="Current ' + $ReleaseVersion + ' · Check GitHub for updates."'),
        1
    )

    $Text = [regex]::Replace(
        $Text,
        '(?m)^\$UpdateInstallerPath\s*=.*\r?\n',
        '',
        1
    )

    $nativeInstall = @'
    function Start-UpdateInstall {
        if (
            $script:repairActive -or
            -not $script:updateManifest
        ) {
            return
        }

        if (-not (Test-Path -LiteralPath $UpdaterHostPath)) {
            $UpdateStatusText.Text = 'Updater component is missing'
            $UpdateStatusText.Foreground = Get-Brush 'Amber'
            $UpdateDetailText.Text = 'Install the native updater bridge once, then check for updates again.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
            return
        }

        try {
            $targetCode = [int64]$script:updateManifest.versionCode
            $selectedChannel = Get-UpdateChannel
            if (
                [string]::IsNullOrWhiteSpace([string]$script:updateManifestChannel) -or
                $script:updateManifestChannel -notin @('stable','preview') -or
                $script:updateManifestChannel -cne $selectedChannel
            ) {
                $script:updateManifest = $null
                $script:updateManifestChannel = ''
                $UpdateNowButton.Visibility = [System.Windows.Visibility]::Collapsed
                Start-UpdateCheck
                return
            }

            if ($targetCode -le $ProductVersionCode) {
                Start-UpdateCheck
                return
            }

            # Run the updater from TEMP so Windows never locks the installed
            # updater while the package replaces it.
            $tempUpdater = Join-Path $env:TEMP 'TailscaleQuickRepairUpdater-Native.exe'
            Remove-Item -LiteralPath $tempUpdater -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $UpdaterHostPath -Destination $tempUpdater -Force

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $tempUpdater
            $psi.Arguments = @(
                '--silent'
                '--current-pid'
                ([string]$PID)
                '--current-code'
                ([string]$ProductVersionCode)
                '--target-code'
                ([string]$targetCode)
                '--channel'
                ('"' + [string]$script:updateManifestChannel + '"')
            ) -join ' '
            $psi.UseShellExecute = $true

            $updaterProcess = [System.Diagnostics.Process]::Start($psi)

            if (-not $updaterProcess) {
                throw 'The native updater could not start.'
            }

            $CheckForUpdatesButton.IsEnabled = $false
            $UpdateNowButton.IsEnabled = $false
            $UpdateNowButton.Content = 'Updating…'
            $UpdateStatusText.Text = 'Installing update…'
            $UpdateStatusText.Foreground = Get-Brush 'Blue'
            $UpdateDetailText.Text = 'The native updater is verifying and installing the trusted release. Quick Repair will restart automatically.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible

            $script:allowFullExit = $true

            $window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{
                    $window.Close()
                }
            ) | Out-Null
        }
        catch {
            $CheckForUpdatesButton.IsEnabled = $true
            $UpdateNowButton.IsEnabled = $true
            $UpdateNowButton.Content = 'Update now'
            $UpdateStatusText.Text = 'Could not start update'
            $UpdateStatusText.Foreground = Get-Brush 'Amber'
            $UpdateDetailText.Text = 'Nothing was changed.'
            $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
        }
    }

    function Show-UpdateResult {
'@

    $pattern = '(?s)    function Start-UpdateInstall \{.*?\r?\n    function Show-UpdateResult \{'
    $updated = [regex]::Replace($Text, $pattern, $nativeInstall, 1)

    if ($updated -eq $Text) {
        throw 'Could not replace the legacy self-update function.'
    }

    $Text = $updated.Replace(
        'if ($script:updateCheckActive -or $script:updateDownloadActive) {',
        'if ($script:updateCheckActive) {'
    )

    foreach ($forbidden in @(
        'Update-Installer.ps1',
        'DownloadFileTaskAsync',
        "'--script'",
        'Administrator approval may be requested'
    )) {
        if ($Text -match [regex]::Escape($forbidden)) {
            throw "Packaged UI still contains legacy updater behaviour: $forbidden"
        }
    }

    if ($Text -notmatch [regex]::Escape('$UpdaterHostPath')) {
        throw 'Packaged UI no longer references the native updater host.'
    }

    if ($Text -notmatch 'TailscaleQuickRepairUpdater-Native\.exe') {
        throw 'Packaged UI does not launch the updater from a disposable TEMP copy.'
    }

    return $Text
}

$uiPath = Join-Path $repo 'src\app\Tailscale-Repair-UI.ps1'
$uiText = [IO.File]::ReadAllText($uiPath, [Text.Encoding]::UTF8)
$uiText = Normalize-UiForWindowsPowerShell $uiText
$uiText = Convert-UiToNativeUpdater `
    -Text $uiText `
    -ReleaseVersion $version `
    -ReleaseVersionCode $versionCode

[void][scriptblock]::Create($uiText)

$xamlMatch = [regex]::Match(
    $uiText,
    '(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@'
)

if (-not $xamlMatch.Success) {
    throw 'Could not locate the Quick Repair XAML block.'
}

[xml]$xamlDocument = $xamlMatch.Groups['xaml'].Value

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

$reader = New-Object System.Xml.XmlNodeReader $xamlDocument
$window = $null

try {
    $window = [Windows.Markup.XamlReader]::Load($reader)

    if (-not $window) {
        throw 'WPF XAML validation returned no Window.'
    }
}
finally {
    try { $reader.Close() } catch {}
    try {
        if ($window -is [System.Windows.Window]) {
            $window.Close()
        }
    } catch {}
}

$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object {
    Test-Path -LiteralPath $_
} | Select-Object -First 1

if (-not $compiler) {
    throw 'The .NET Framework C# compiler could not be located.'
}

$frameworkDir = Split-Path -Parent $compiler
$webExtensions = Join-Path $frameworkDir 'System.Web.Extensions.dll'
$compression = Join-Path $frameworkDir 'System.IO.Compression.dll'
$compressionFs = Join-Path $frameworkDir 'System.IO.Compression.FileSystem.dll'
$windowsForms = Join-Path $frameworkDir 'System.Windows.Forms.dll'

foreach ($assembly in @($webExtensions, $compression, $compressionFs, $windowsForms)) {
    if (-not (Test-Path -LiteralPath $assembly)) {
        throw "Required .NET Framework reference is missing: $assembly"
    }
}

$work = Join-Path $env:TEMP ('TQR-Release-' + [Guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $work 'package'
$packageApp = Join-Path $packageRoot 'app'

New-Item -ItemType Directory -Path $packageApp -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

try {
    $updaterSource = Join-Path $repo 'src\native\UpdaterHost.cs'
    $updaterEntry = Join-Path $repo 'src\native\UpdaterEntry.cs'
    $updaterExe = Join-Path $packageApp 'TailscaleQuickRepairUpdater.exe'
    $compileOut = Join-Path $work 'compile.out'
    $compileErr = Join-Path $work 'compile.err'

    $args = @(
        '/nologo'
        '/target:winexe'
        '/platform:anycpu'
        '/optimize+'
        '/main:UpdaterEntry'
        ('/reference:"{0}"' -f $webExtensions)
        ('/reference:"{0}"' -f $compression)
        ('/reference:"{0}"' -f $compressionFs)
        ('/reference:"{0}"' -f $windowsForms)
        ('/out:"{0}"' -f $updaterExe)
        ('"{0}"' -f $updaterSource)
        ('"{0}"' -f $updaterEntry)
        ('"{0}"' -f (Join-Path $repo 'src\native\OperationGate.cs'))
    )

    $compile = Start-Process `
        -FilePath $compiler `
        -ArgumentList ($args -join ' ') `
        -RedirectStandardOutput $compileOut `
        -RedirectStandardError $compileErr `
        -WindowStyle Hidden `
        -Wait `
        -PassThru

    if (
        $compile.ExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $updaterExe)
    ) {
        $details = @()

        if (Test-Path -LiteralPath $compileOut) {
            $details += Get-Content -LiteralPath $compileOut -Raw
        }

        if (Test-Path -LiteralPath $compileErr) {
            $details += Get-Content -LiteralPath $compileErr -Raw
        }

        throw "Native updater compilation failed.`r`n$($details -join [Environment]::NewLine)"
    }

    $updaterSourceText = (
        [IO.File]::ReadAllText($updaterSource, [Text.Encoding]::UTF8) +
        [Environment]::NewLine +
        [IO.File]::ReadAllText($updaterEntry, [Text.Encoding]::UTF8)
    )

    foreach ($forbidden in @(
        '-EncodedCommand',
        'Update-Installer.ps1',
        'powershell.exe',
        'runas'
    )) {
        if ($updaterSourceText -match [regex]::Escape($forbidden)) {
            throw "Native updater still contains forbidden legacy execution pattern: $forbidden"
        }
    }

    if ($updaterSourceText -notmatch 'SecurityProtocolType\)3072') {
        throw 'Native updater does not explicitly force TLS 1.2.'
    }

    & (Join-Path $PSScriptRoot 'test-build-validation.ps1') -UpdaterPath $updaterExe -OutputDirectory $OutputDirectory -ValidationProfile $ValidationProfile

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)

    [IO.File]::WriteAllText(
        (Join-Path $packageApp 'Tailscale-Repair-UI.ps1'),
        $uiText,
        $utf8Bom
    )

    Copy-Item $versionPath (Join-Path $packageRoot 'version.json') -Force

    $entries = @()

    Get-ChildItem -LiteralPath $packageRoot -File -Recurse |
        Where-Object { $_.Name -ne 'package-manifest.json' } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($packageRoot.Length).TrimStart('\') -replace '\\','/'

            $entries += [ordered]@{
                path = $relative
                sha256 = (
                    Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
                ).Hash.ToLowerInvariant()
                size = $_.Length
            }
        }

    $manifest = [ordered]@{
        schema = 1
        product = 'Tailscale Quick Repair'
        version = $version
        versionCode = $versionCode
        files = $entries
    }

    $manifest |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath (Join-Path $packageRoot 'package-manifest.json') `
            -Encoding UTF8

    & (Join-Path $PSScriptRoot 'privacy-scan.ps1') `
        -Root $packageRoot `
        -SkipRepositoryIdentity

    $zipPath = Join-Path $OutputDirectory "TailscaleQuickRepair-$safeVersion.zip"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    Compress-Archive `
        -Path (Join-Path $packageRoot '*') `
        -DestinationPath $zipPath `
        -CompressionLevel Optimal

    $sha = (
        Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $sha |
        Set-Content `
            -LiteralPath "$zipPath.sha256" `
            -Encoding ASCII

    $bootstrapPath = Join-Path $OutputDirectory "TailscaleQuickRepair-Bootstrap-$safeVersion.exe"
    Copy-Item -LiteralPath $updaterExe -Destination $bootstrapPath -Force

    $bootstrapSha = (
        Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $bootstrapSha |
        Set-Content `
            -LiteralPath "$bootstrapPath.sha256" `
            -Encoding ASCII

    Write-Host "PACKAGE=$zipPath"
    Write-Host "SHA256=$sha"
    Write-Host "BOOTSTRAP=$bootstrapPath"
    Write-Host "BOOTSTRAP_SHA256=$bootstrapSha"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
