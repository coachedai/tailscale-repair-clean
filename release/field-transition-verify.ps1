param(
    [ValidateSet('Vpn','SleepResume','RebootBefore','RebootAfter')]
    [string]$Mode = 'Vpn',
    [string]$PackDirectory = '',
    [ValidateRange(60,900)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2

if([string]::IsNullOrWhiteSpace($PackDirectory)){
    $PackDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path
}
$PackDirectory=[IO.Path]::GetFullPath($PackDirectory)
$resultPath=Join-Path $PackDirectory ('FIELD-TRANSITION-RESULT-'+$Mode+'.json')
$rebootState=Join-Path $PackDirectory 'REBOOT-STATE.json'
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false
$stage='preflight'

function Check([bool]$Value,[string]$Name){
    $script:stage=$Name
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Physical transition assertion failed.'}
    Write-Host ('PASS: '+$Name)
}
function Digest([string]$Path){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Require-OrdinaryUser {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    Check (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Verifier is running without elevation'
}
function Read-LocalHealth {
    $machine=New-Object Tqr.WindowsAutoRepairMachine
    return $machine.Observe()
}
function Require-HealthyLocalTailscale {
    $health=Read-LocalHealth
    Check ($health -and $health.Service -eq 'Running' -and $health.Backend -eq 'Running') 'Local authenticated Tailscale service and backend are running'
}
function Load-Baseline {
    $appRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TailscaleQuickRepair'
    $versionPath=Join-Path $appRoot 'version.user.json'
    $configPath=Join-Path $appRoot 'config.json'
    $exePath=Join-Path $appRoot 'TailscaleQuickRepair.exe'
    $libraryPath=Join-Path $appRoot 'TailscaleQuickRepair.Operations.dll'

    Check (Test-Path -LiteralPath (Join-Path $PackDirectory 'FIELD-RESULT.json') -PathType Leaf) 'Post-Setup field result is present'
    $field=Get-Content -LiteralPath (Join-Path $PackDirectory 'FIELD-RESULT.json') -Raw|ConvertFrom-Json
    Check ($field.schema -eq 1 -and [bool]$field.passed -and [string]$field.version -ceq '3.0.0-rc.12' -and
        $field.containsDeviceData -eq $false -and $field.containsNetworkData -eq $false) 'RC12 post-Setup verification already passed'

    Check ((Test-Path -LiteralPath $versionPath -PathType Leaf) -and
        (Test-Path -LiteralPath $configPath -PathType Leaf) -and
        (Test-Path -LiteralPath $exePath -PathType Leaf) -and
        (Test-Path -LiteralPath $libraryPath -PathType Leaf)) 'Installed RC12 files required by this verifier are present'

    $version=Get-Content -LiteralPath $versionPath -Raw|ConvertFrom-Json
    Check ([string]$version.version -ceq '3.0.0-rc.12' -and [int64]$version.versionCode -eq 30001012) 'Installed version is RC12'

    if(-not ('Tqr.AutoRepairPolicyStore' -as [type])){Add-Type -Path $libraryPath -ErrorAction Stop}
    Check (-not [Tqr.AutoRepairPolicyStore]::ReadEnabled($appRoot)) 'Automatic Repair is off for physical transition verification'
    Require-HealthyLocalTailscale

    return [pscustomobject]@{
        AppRoot=$appRoot
        ConfigPath=$configPath
        ExePath=$exePath
        LibraryPath=$libraryPath
        ConfigSha256=Digest $configPath
        ExeSha256=Digest $exePath
        LibrarySha256=Digest $libraryPath
    }
}
function Verify-Unchanged($Baseline){
    Check ((Digest $Baseline.ConfigPath) -ceq [string]$Baseline.ConfigSha256) 'Quick Repair configuration bytes are unchanged'
    Check ((Digest $Baseline.ExePath) -ceq [string]$Baseline.ExeSha256) 'Quick Repair resident executable is unchanged'
    Check ((Digest $Baseline.LibraryPath) -ceq [string]$Baseline.LibrarySha256) 'Quick Repair operations library is unchanged'
    Check (-not [Tqr.AutoRepairPolicyStore]::ReadEnabled($Baseline.AppRoot)) 'Automatic Repair remains off'
    Require-HealthyLocalTailscale
}

try{
    Check ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'Windows desktop environment'
    Require-OrdinaryUser
    Check (-not(Test-Path -LiteralPath $resultPath)) 'Existing transition result will not be overwritten'

    if($Mode -eq 'RebootAfter'){
        Check (Test-Path -LiteralPath $rebootState -PathType Leaf) 'Privacy-safe pre-reboot state is present'
        $saved=Get-Content -LiteralPath $rebootState -Raw|ConvertFrom-Json
        Check ($saved.schema -eq 1 -and [string]$saved.version -ceq '3.0.0-rc.12' -and
            $saved.containsDeviceData -eq $false -and $saved.containsNetworkData -eq $false) 'Pre-reboot state contains only approved acceptance fields'
        $created=[DateTime]::Parse([string]$saved.createdUtc).ToUniversalTime()
        Check ($created -le [DateTime]::UtcNow -and ([DateTime]::UtcNow-$created).TotalHours -le 24) 'Pre-reboot state is recent'

        $baseline=Load-Baseline
        Check ([string]$saved.configSha256 -ceq [string]$baseline.ConfigSha256) 'Configuration matches the pre-reboot hash'
        Check ([string]$saved.exeSha256 -ceq [string]$baseline.ExeSha256) 'Resident executable matches the pre-reboot hash'
        Check ([string]$saved.librarySha256 -ceq [string]$baseline.LibrarySha256) 'Operations library matches the pre-reboot hash'
        Verify-Unchanged $baseline
        $passed=$true
    }
    else{
        $baseline=Load-Baseline

        if($Mode -eq 'Vpn'){
            $initial=[Tqr.VpnAwareness]::Inspect()
            Check ($initial -and [string]$initial.State -in @('Detected','NotDetected') -and
                -not [string]::IsNullOrWhiteSpace([string]$initial.Signature)) 'Initial VPN context is available through the read-only fixed-label boundary'
            $initialSignature=[string]$initial.Signature
            Write-Host 'Connect or disconnect your normal VPN once. This verifier only observes the transition.'
            $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            $changed=$null
            while([DateTime]::UtcNow -lt $deadline){
                Start-Sleep -Seconds 1
                $sample=[Tqr.VpnAwareness]::Inspect()
                if($sample -and [string]$sample.State -in @('Detected','NotDetected') -and
                    -not [string]::IsNullOrWhiteSpace([string]$sample.Signature) -and
                    [string]$sample.Signature -cne $initialSignature){
                    $changed=$sample
                    break
                }
            }
            Check ($null -ne $changed) 'A real VPN or tunnel transition was observed without changing it'

            $stableSignature=[string]$changed.Signature
            $stableSince=[DateTime]::UtcNow
            $stable=$false
            $settleDeadline=[DateTime]::UtcNow.AddSeconds(45)
            while([DateTime]::UtcNow -lt $settleDeadline){
                Start-Sleep -Seconds 1
                $sample=[Tqr.VpnAwareness]::Inspect()
                if(-not $sample -or [string]::IsNullOrWhiteSpace([string]$sample.Signature) -or
                    [string]$sample.Signature -cne $stableSignature){
                    if($sample -and -not [string]::IsNullOrWhiteSpace([string]$sample.Signature)){
                        $stableSignature=[string]$sample.Signature
                    }
                    $stableSince=[DateTime]::UtcNow
                    continue
                }
                if(([DateTime]::UtcNow-$stableSince).TotalSeconds -ge 10){$stable=$true;break}
            }
            Check $stable 'VPN or tunnel context remained stable for ten seconds after the transition'
            Verify-Unchanged $baseline
            $passed=$true
        }
        elseif($Mode -eq 'SleepResume'){
            Write-Host 'Put this PC to sleep once, then resume and sign back in. Do not change Tailscale or VPN settings.'
            $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            $last=[DateTime]::UtcNow
            $observed=$false
            while([DateTime]::UtcNow -lt $deadline){
                Start-Sleep -Seconds 1
                $now=[DateTime]::UtcNow
                if(($now-$last).TotalSeconds -ge 8){$observed=$true;break}
                $last=$now
            }
            Check $observed 'A real suspend and resume polling gap was observed'
            Start-Sleep -Seconds 10
            Verify-Unchanged $baseline
            $passed=$true
        }
        elseif($Mode -eq 'RebootBefore'){
            Check (-not(Test-Path -LiteralPath $rebootState)) 'Existing pre-reboot state will not be overwritten'
            [ordered]@{
                schema=1
                version='3.0.0-rc.12'
                createdUtc=[DateTime]::UtcNow.ToString('o')
                configSha256=[string]$baseline.ConfigSha256
                exeSha256=[string]$baseline.ExeSha256
                librarySha256=[string]$baseline.LibrarySha256
                containsDeviceData=$false
                containsNetworkData=$false
            }|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $rebootState -Encoding UTF8
            Check (Test-Path -LiteralPath $rebootState -PathType Leaf) 'Privacy-safe pre-reboot hashes were saved'
            Write-Host 'Reboot Windows normally. After signing back in, start Quick Repair if needed and run this verifier with -Mode RebootAfter.'
            $passed=$true
        }
    }
}
catch{
    Write-Host ('STOPPED: '+$stage) -ForegroundColor Yellow
}
finally{
    [pscustomobject]@{
        schema=1
        version='3.0.0-rc.12'
        mode=$Mode
        passed=$passed
        checks=@($cases.ToArray())
        stoppedAt=if($passed){''}else{$stage}
        containsDeviceData=$false
        containsNetworkData=$false
        changesNetworkSettings=$false
    }|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $resultPath -Encoding UTF8
}

if($passed){
    Write-Host ('RC12 '+$Mode+' physical transition verification passed.') -ForegroundColor Green
    exit 0
}
Write-Host ('RC12 '+$Mode+' physical transition verification did not pass. The result contains only named PASS/FAIL checks.') -ForegroundColor Yellow
exit 1
