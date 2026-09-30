param(
    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$zips = @(Get-ChildItem -LiteralPath $output -Filter 'TailscaleQuickRepair-*.zip' -File)

if ($zips.Count -ne 1) {
    throw "Expected exactly one normal update ZIP in $output; found $($zips.Count)."
}

$requiredSources = @(
    'src\native\PublicSetupHost.cs',
    'src\native\PublicSetupEntry.cs',
    'src\native\PassiveStartupHealth.cs',
    'src\native\PassiveStartupWork.cs',
    'src\native\VpnAwareness.cs'
)

foreach ($relative in $requiredSources) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo $relative) -PathType Leaf)) {
        throw "Native setup routing source is missing: $relative"
    }
}

$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $compiler) {
    throw 'The .NET Framework C# compiler could not be located.'
}

$frameworkDir = Split-Path -Parent $compiler
$refs = @(
    (Join-Path $frameworkDir 'System.Web.Extensions.dll'),
    (Join-Path $frameworkDir 'System.IO.Compression.dll'),
    (Join-Path $frameworkDir 'System.IO.Compression.FileSystem.dll'),
    (Join-Path $frameworkDir 'System.Windows.Forms.dll'),
    (Join-Path $frameworkDir 'System.Drawing.dll')
)

foreach ($reference in $refs) {
    if (-not (Test-Path -LiteralPath $reference)) {
        throw "Required setup reference is missing: $reference"
    }
}

function Get-TrustedRelativePath {
    param([string]$Root,[string]$FullName)

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $fileFull = [IO.Path]::GetFullPath($FullName)

    if (-not $fileFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Package file escapes staging root: $fileFull"
    }

    return $fileFull.Substring($rootFull.Length).Replace('\','/')
}

function Replace-LiteralRegexOnce {
    param([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Description)

    $regex = New-Object System.Text.RegularExpressions.Regex(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $matches = $regex.Matches($Text)
    if ($matches.Count -ne 1) {
        throw "Expected one $Description match; found $($matches.Count)."
    }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $Replacement
    }

    return $regex.Replace($Text,$evaluator,1)
}

$zip = $zips[0]
$work = Join-Path $env:TEMP ('TQR-SetupRoute-' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $work 'package'
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $root -Force

    $appDir = Join-Path $root 'app'
    $uiPath = Join-Path $appDir 'Tailscale-Repair-UI.ps1'
    $setupExe = Join-Path $appDir 'TailscaleQuickRepairSetup.exe'
    $versionPath = Join-Path $root 'version.json'

    foreach ($required in @($uiPath,$versionPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Normal update package is incomplete: $required"
        }
    }

    $compileOut = Join-Path $work 'setup-compile.out'
    $compileErr = Join-Path $work 'setup-compile.err'
    $args = @(
        '/nologo',
        '/target:winexe',
        '/platform:anycpu',
        '/optimize+',
        '/main:PublicSetupEntry',
        ('/out:"{0}"' -f $setupExe)
    )
    foreach ($reference in $refs) { $args += ('/reference:"{0}"' -f $reference) }
    $args += ('"{0}"' -f (Join-Path $repo 'src\native\PublicSetupHost.cs'))
    $args += ('"{0}"' -f (Join-Path $repo 'src\native\PublicSetupEntry.cs'))
    $args += ('"{0}"' -f (Join-Path $repo 'src\native\OperationGate.cs'))

    $compile = Start-Process -FilePath $compiler -ArgumentList ($args -join ' ') `
        -RedirectStandardOutput $compileOut -RedirectStandardError $compileErr `
        -WindowStyle Hidden -Wait -PassThru

    if ($compile.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $setupExe)) {
        $details = @()
        if (Test-Path $compileOut) { $details += Get-Content $compileOut -Raw }
        if (Test-Path $compileErr) { $details += Get-Content $compileErr -Raw }
        throw "Native Setup host compilation failed.`r`n$($details -join [Environment]::NewLine)"
    }

    $setupTest = Start-Process -FilePath $setupExe -ArgumentList '--self-test-installer' `
        -WindowStyle Hidden -Wait -PassThru
    if ($setupTest.ExitCode -ne 0) {
        throw "Native Setup host self-test failed: $($setupTest.ExitCode)."
    }

    $operationsDll = Join-Path $appDir 'TailscaleQuickRepair.Operations.dll'
    $libraryArgs = @('/nologo','/target:library','/platform:anycpu','/optimize+',
        ('/out:"{0}"' -f $operationsDll),
        ('/reference:"{0}"' -f (Join-Path $frameworkDir 'System.Web.Extensions.dll')),
        ('/reference:"{0}"' -f (Join-Path $frameworkDir 'System.ServiceProcess.dll')),
        ('"{0}"' -f (Join-Path $repo 'src\native\AutoRepairPolicy.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\AutoRepairLocalStatus.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\AutoRepairWorker.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\AutoRepairBackground.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\WindowsAutoRepairMachine.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\OperationGate.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\LocalHistory.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\ConnectionQuality.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\VpnAwareness.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\SmartNotifications.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\PassiveStartupHealth.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\PassiveStartupWork.cs')),
        ('/reference:"{0}"' -f [System.Management.Automation.PowerShell].Assembly.Location),
        ('"{0}"' -f (Join-Path $repo 'src\native\DiagnosticAnalysis.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\SupportReport.cs')),
        ('"{0}"' -f (Join-Path $repo 'src\native\SupportReportWindow.cs')))
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
    foreach($assembly in @([Windows.Window].Assembly,[Windows.Media.Brush].Assembly,[Windows.DependencyObject].Assembly,[System.Xaml.XamlServices].Assembly)){
        $libraryArgs += ('/reference:"{0}"' -f $assembly.Location)
    }
    $libraryBuild = Start-Process -FilePath $compiler -ArgumentList ($libraryArgs -join ' ') `
        -RedirectStandardOutput $compileOut -RedirectStandardError $compileErr -WindowStyle Hidden -Wait -PassThru
    if ($libraryBuild.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $operationsDll)) {
        throw ('Operations library compilation failed. ' + [IO.File]::ReadAllText($compileOut))
    }

    # Normal and protected delivery must start from the SAME fully featured UI.
    $deliveryVersion = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'public-ui.ps1') -Path $uiPath -Version ([string]$deliveryVersion.version) -VersionCode ([int64]$deliveryVersion.versionCode)
    $ui = [IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8)

    if ($ui -notmatch '(?m)^\$SetupHostPath\s*=') {
        $statePattern = '(?m)^\$StateDir\s*=\s*Join-Path\s+\$env:LOCALAPPDATA\s+''TailscaleQuickRepair''\s*$'
        $stateMatch = [regex]::Match($ui,$statePattern)
        if (-not $stateMatch.Success) { throw 'Could not locate Quick Repair StateDir declaration.' }

        $replacement = $stateMatch.Value + [Environment]::NewLine +
            '$SetupHostPath = Join-Path $StateDir ''TailscaleQuickRepairSetup.exe'''
        $ui = $ui.Remove($stateMatch.Index,$stateMatch.Length).Insert($stateMatch.Index,$replacement)
    }

    $installHeader = @'
    function Start-UpdateInstall {
        if (
            $script:repairActive -or
            -not $script:updateManifest
        ) {
            return
        }
'@

    $protectedRoute = @'
    function Start-UpdateInstall {
        if (
            $script:repairActive -or
            -not $script:updateManifest
        ) {
            return
        }

        $requiresSetup = $false
        if ($script:updateManifest.PSObject.Properties.Name -contains 'requiresSetup') {
            if ($script:updateManifest.requiresSetup -isnot [bool]) {
                $UpdateStatusText.Text = 'Update metadata is invalid'
                $UpdateStatusText.Foreground = Get-Brush 'Amber'
                $UpdateDetailText.Text = 'The update type could not be verified. Nothing was changed.'
                $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
                return
            }
            $requiresSetup = $script:updateManifest.requiresSetup
        }

        if ($requiresSetup) {
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

            if (-not (Test-Path -LiteralPath $SetupHostPath)) {
                $UpdateStatusText.Text = 'Setup component is missing'
                $UpdateStatusText.Foreground = Get-Brush 'Amber'
                $UpdateDetailText.Text = 'Run Repair installation or the latest Setup before installing this system update.'
                $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
                return
            }

            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $SetupHostPath
                $psi.Arguments = '--upgrade --channel "' + $selectedChannel + '" --target-code ' + [string][int64]$script:updateManifest.versionCode
                $psi.UseShellExecute = $true
                $setupProcess = [System.Diagnostics.Process]::Start($psi)

                if (-not $setupProcess) {
                    throw 'The native Setup host could not start.'
                }

                $CheckForUpdatesButton.IsEnabled = $false
                $UpdateNowButton.IsEnabled = $false
                $UpdateNowButton.Content = 'Updating…'
                $UpdateStatusText.Text = 'Installing system update…'
                $UpdateStatusText.Foreground = Get-Brush 'Blue'
                $UpdateDetailText.Text = 'Approve the Windows prompt. The verified Setup host will update Quick Repair and restart it.'
                $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
                $script:allowFullExit = $true

                $window.Dispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Background,
                    [Action]{ $window.Close() }
                ) | Out-Null
                return
            }
            catch {
                $CheckForUpdatesButton.IsEnabled = $true
                $UpdateNowButton.IsEnabled = $true
                $UpdateNowButton.Content = 'Update now'
                $UpdateStatusText.Text = 'Could not start system update'
                $UpdateStatusText.Foreground = Get-Brush 'Amber'
                $UpdateDetailText.Text = 'Nothing was changed.'
                $UpdateDetailText.Visibility = [System.Windows.Visibility]::Visible
                return
            }
        }
'@

    $repairPattern = '(?s)    function Invoke-InstallationRepair \{.*?\r?\n    function Update-DetailsToggleText \{'
    $repairReplacement = @'
    function Invoke-InstallationRepair {
        if (-not (Test-Path -LiteralPath $SetupHostPath)) {
            Set-Badge $HeroBadge $HeroBadgeText 'SETUP ISSUE' 'failure'
            $HeroTitle.Text = 'Installation repair is unavailable'
            $HeroDetail.Text = 'Run the latest Tailscale Quick Repair Setup to restore the maintenance component.'
            return
        }

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $SetupHostPath
            $psi.Arguments = '--repair'
            $psi.UseShellExecute = $true
            $process = [System.Diagnostics.Process]::Start($psi)
            if (-not $process) { throw 'The maintenance helper could not start.' }

            Set-Badge $HeroBadge $HeroBadgeText 'MAINTENANCE' 'repairing'
            $HeroTitle.Text = 'Repairing Quick Repair'
            $HeroDetail.Text = 'Approve the Windows prompt. Quick Repair will rebuild its protected integration and reopen automatically.'
            $RepairInstallationButton.IsEnabled = $false
            $script:allowFullExit = $true
            $global:TqrUiShutdownRequested = $true

            $window.Dispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{
                    try { $window.Close() } catch {}
                }
            ) | Out-Null
        }
        catch {
            $RepairInstallationButton.IsEnabled = $true
            Set-Badge $HeroBadge $HeroBadgeText 'SETUP ISSUE' 'failure'
            $HeroTitle.Text = 'Could not start installation repair'
            $HeroDetail.Text = $_.Exception.Message
        }
    }

    function Update-DetailsToggleText {
'@

    if ($ui -notmatch [regex]::Escape("$psi.Arguments = '--repair'")) {
        $ui = Replace-LiteralRegexOnce `
            -Text $ui `
            -Pattern $repairPattern `
            -Replacement $repairReplacement `
            -Description 'native installation repair function'
    }
    if ($ui -notmatch [regex]::Escape('$requiresSetup = $false')) {
        if (-not $ui.Contains($installHeader)) {
            throw 'Could not locate native Start-UpdateInstall header.'
        }
        $ui = $ui.Replace($installHeader,$protectedRoute)
    }

    foreach ($required in @(
        '$SetupHostPath',
        '$requiresSetup = $false',
        '--channel "',
        '--target-code ',
        "$psi.Arguments = '--repair'"
    )) {
        if ($ui -notmatch [regex]::Escape($required)) {
            throw "Native setup routing verification failed: $required"
        }
    }

    $headerCount = [regex]::Matches($ui,'(?m)^param\(\r?\n\s*\[switch\]\$StartInTray\r?\n\)').Count
    $xamlCount = [regex]::Matches($ui,'(?m)^\s*\[xml\]\$xaml\s*=\s*@"').Count
    if ($headerCount -ne 1 -or $xamlCount -ne 1) {
        throw "Routed UI must remain one script. Headers=$headerCount Xaml=$xamlCount"
    }

    [void][scriptblock]::Create($ui)
    $xamlMatch = [regex]::Match($ui,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    if (-not $xamlMatch.Success) { throw 'Routed UI XAML was not found.' }
    [xml]$xamlDoc = $xamlMatch.Groups['xaml'].Value
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    $testWindow = $null
    try {
        $testWindow = [Windows.Markup.XamlReader]::Load($reader)
        if (-not $testWindow) { throw 'Routed UI WPF validation returned no window.' }
    }
    finally {
        try { $reader.Close() } catch {}
        try { if ($testWindow -is [System.Windows.Window]) { $testWindow.Close() } } catch {}
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($uiPath,$ui,$utf8Bom)
    & (Join-Path $PSScriptRoot 'add-local-history.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-connection-quality.ps1') -Path $uiPath
    $notificationTransform=[scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'add-smart-notifications.ps1'),[Text.Encoding]::UTF8))
    & $notificationTransform -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-diagnostics-polish.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-progress-reset.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-support-export.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-auto-repair-worker.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-passive-startup-health.ps1') -Path $uiPath

    $validation=Get-Content -LiteralPath (Join-Path $output 'build-validation.json') -Raw|ConvertFrom-Json
    if($validation.schema -ne 1 -or $validation.passed -isnot [bool] -or -not $validation.passed -or
        $validation.source -cne $env:GITHUB_SHA -or
        $validation.profile -cnotin @('PublicRelease','Development','PrivateDevelopment')){
        throw 'Status presentation requires matching build validation.'
    }
    if($validation.publicFeedVerified -isnot [bool] -or $validation.publishable -isnot [bool] -or
        $validation.publicFeedVerified -ne ($validation.profile -ceq 'PublicRelease') -or
        $validation.publishable -ne ($validation.profile -ceq 'PublicRelease')){
        throw 'Build profile evidence is inconsistent.'
    }
    & (Join-Path $PSScriptRoot 'add-status-clarity.ps1') -Path $uiPath -ValidationProfile $validation.profile
    & (Join-Path $PSScriptRoot 'add-update-guardian.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-protected-update-handoff.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-local-control-center.ps1') -Path $uiPath
    & (Join-Path $PSScriptRoot 'add-vpn-awareness.ps1') -Path $uiPath
    Copy-Item -LiteralPath (Join-Path $repo 'src\app\Advanced-Diagnostics.ps1') -Destination (Join-Path $appDir 'Advanced-Diagnostics.ps1') -Force

    $version = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    $publish = Get-Content -LiteralPath (Join-Path $repo 'release\publish.json') -Raw | ConvertFrom-Json
    if ([string]$publish.version -cne [string]$version.version -or [int64]$publish.versionCode -ne [int64]$version.versionCode) {
        throw 'Protected update metadata does not match version.json.'
    }

    $deliveryChannel = [string]$publish.channel
    if ($deliveryChannel -notin @('stable','preview')) {
        throw 'publish.channel must be stable or preview.'
    }

    $protectedHandoff = $false
    if ($publish.PSObject.Properties.Name -contains 'protectedHandoff') {
        if ($publish.protectedHandoff -isnot [bool]) {
            throw 'protectedHandoff must be a boolean.'
        }
        $protectedHandoff = [bool]$publish.protectedHandoff
    }
    $requiresSetup = [bool]$publish.requiresSetup
    if ($protectedHandoff -and $requiresSetup) {
        throw 'protectedHandoff and requiresSetup cannot both be enabled for the same release.'
    }

    $protectedMarkerPath = Join-Path $appDir 'protected-update.json'
    if (Test-Path -LiteralPath $protectedMarkerPath) {
        Remove-Item -LiteralPath $protectedMarkerPath -Force
    }

    # The handoff marker is transient. Generate the permanent app integrity
    # manifest first, then add the marker so the outer package manifest protects
    # its exact bytes without requiring it to remain after Setup completes.
    & (Join-Path $PSScriptRoot 'write-integrity-manifest.ps1') -AppDirectory $appDir -VersionPath $versionPath -Profile 'update'

    if ($requiresSetup -or $protectedHandoff) {
        [ordered]@{
            schema = 2
            versionCode = [int64]$version.versionCode
            channel = $deliveryChannel
        } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $protectedMarkerPath -Encoding UTF8
    }

    $entries = @(
        Get-ChildItem -LiteralPath $root -File -Recurse |
            Where-Object { $_.Name -ne 'package-manifest.json' } |
            ForEach-Object {
                [ordered]@{
                    path = Get-TrustedRelativePath -Root $root -FullName $_.FullName
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    size = [int64]$_.Length
                }
            } |
            Sort-Object { $_.path }
    )

    if ('app/TailscaleQuickRepairSetup.exe' -notin @($entries | ForEach-Object { $_.path })) {
        throw 'Native Setup host did not enter the update package.'
    }

    $manifest = [ordered]@{
        schema = 1
        product = 'Tailscale Quick Repair'
        version = [string]$version.version
        versionCode = [int64]$version.versionCode
        files = $entries
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'package-manifest.json') -Encoding UTF8

    & (Join-Path $PSScriptRoot 'privacy-scan.ps1') -Root $root -SkipRepositoryIdentity

    Remove-Item -LiteralPath $zip.FullName -Force
    Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip.FullName -CompressionLevel Optimal

    $sha = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $sha | Set-Content -LiteralPath ($zip.FullName + '.sha256') -Encoding ASCII

    Write-Host "Native setup routing passed: $($version.version) ($($version.versionCode))"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
