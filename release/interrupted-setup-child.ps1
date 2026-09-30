param(
    [ValidateSet('InstallLegacy','LegacyIntegration','ApplyPause','RecoveryPause','Recover','RecoverRefuse','IntegrationPause','IntegrationComplete')][string]$Phase,
    [string]$Package,
    [string]$Work,
    [int]$PauseAfter=0,
    [string]$Ready='',
    [string]$Peer='integration-replay.invalid',
    [string]$Startup='true',
    [long]$VersionCode=0,
    [ValidateSet('stable','preview')][string]$Channel='stable',
    [string]$Report=''
)
$ErrorActionPreference='Stop'
$releaseValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$developmentValidation=($env:GITHUB_REF_NAME -ceq 'work/3.0')
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or -not ($developmentValidation -or $releaseValidation) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or -not $env:GITHUB_RUN_ID -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Interrupted Setup child refused this environment.'}

$passed=$false;$lease=$false;$failure=$null;$stage='start'
function Invoke-Private($Type,[string]$Name,[object[]]$Arguments=@()){
    $script:stage='invoke_'+$Name
    $method=$Type.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $method){throw 'Expected packaged Setup boundary missing.'}
    $native=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$native[$i]=$null}else{$native[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    return ,($method.Invoke($null,$native))
}
try{
    $setupPath=Join-Path $Package 'app\TailscaleQuickRepairSetup.exe'
    $type=[Reflection.Assembly]::LoadFile($setupPath).GetType('PublicSetupHost')
    if(-not $type){throw 'Packaged Setup type is unavailable.'}

    $lease=[bool](Invoke-Private $type 'TryAcquireOperationLock' @('setup'))
    if(-not $lease){throw 'Setup operation lease is unavailable.'}

    if($Phase -eq 'InstallLegacy'){
        $manifest=Invoke-Private $type 'ReadPackageManifest' @($Package)
        $files=Invoke-Private $type 'VerifyPackage' @($Package,$manifest)
        [void](Invoke-Private $type 'ApplyFiles' @($files,$Work))
    }
    elseif($Phase -eq 'LegacyIntegration'){
        [void](Invoke-Private $type 'WriteLocalConfig' @('integration-legacy.invalid'))
        [void](Invoke-Private $type 'RegisterRepairTask')
        [void](Invoke-Private $type 'RegisterAutoRepairTask')
        [void](Invoke-Private $type 'ConfigureStartup' @($false))
        [void](Invoke-Private $type 'CreateStartMenuShortcut')
    }
    elseif($Phase -eq 'IntegrationPause'){
        if($VersionCode -le 0){throw 'Candidate version code is required.'}
        [void](Invoke-Private $type 'ValidateProtectedUpdateMarker' @($VersionCode,$Channel))
        $startupValue=[bool]::Parse($Startup)
        $callback=[Action[int]]{
            param([int]$index)
            if($index -eq $PauseAfter){
                [IO.File]::WriteAllText($Ready,('integration-'+$index))
                Start-Sleep -Seconds 90
            }
        }
        [void](Invoke-Private $type 'CompleteInstalledIntegrationCore' @($Peer,$startupValue,$true,$VersionCode,$callback))
    }
    elseif($Phase -eq 'IntegrationComplete'){
        if($VersionCode -le 0){throw 'Candidate version code is required.'}
        [void](Invoke-Private $type 'ValidateProtectedUpdateMarker' @($VersionCode,$Channel))
        [void](Invoke-Private $type 'CompleteInstalledIntegration' @($Peer,[bool]::Parse($Startup),$true,$VersionCode))
    }
    elseif($Phase -eq 'ApplyPause'){
        $manifest=Invoke-Private $type 'ReadPackageManifest' @($Package)
        $files=Invoke-Private $type 'VerifyPackage' @($Package,$manifest)
        $callback=[Action[int]]{
            param([int]$index)
            if($index -eq $PauseAfter){
                [IO.File]::WriteAllText($Ready,'replaced')
                Start-Sleep -Seconds 90
            }
        }
        [void](Invoke-Private $type 'ApplyFilesCore' @($files,$Work,$callback))
    }
    elseif($Phase -eq 'RecoveryPause'){
        $callback=[Action[int]]{
            param([int]$index)
            if($index -eq $PauseAfter){
                [IO.File]::WriteAllText($Ready,'restored')
                Start-Sleep -Seconds 90
            }
        }
        [void](Invoke-Private $type 'RecoverInterruptedFileTransactionCore' @($callback))
    }
    elseif($Phase -eq 'RecoverRefuse'){
        $ownerRefused=$false
        try{
            [void](Invoke-Private $type 'RecoverInterruptedFileTransaction')
        }catch{
            for($ex=$_.Exception;$ex;$ex=$ex.InnerException){
                if($ex -is [UnauthorizedAccessException]){$ownerRefused=$true;break}
            }
        }
        if(-not $ownerRefused){throw 'Recovery owner mismatch was not refused by the packaged Setup core.'}
    }
    else{
        $recovered=[bool](Invoke-Private $type 'RecoverInterruptedFileTransaction')
        if(-not $recovered){throw 'Expected interrupted Setup transaction was not recovered.'}
    }

    if($lease){[void](Invoke-Private $type 'ReleaseOperationLock');$lease=$false}
    $passed=$true
}catch{
    $chain=New-Object 'Collections.Generic.List[object]'
    for($ex=$_.Exception;$ex;$ex=$ex.InnerException){$chain.Add([pscustomobject]@{type=$ex.GetType().FullName;code=$ex.HResult})}
    $failure=[pscustomobject]@{stage=$stage;line=$_.InvocationInfo.ScriptLineNumber;exceptions=@($chain.ToArray())}
}finally{
    if($lease){try{[void](Invoke-Private $type 'ReleaseOperationLock')}catch{$passed=$false}}
    if($Report){
        [pscustomobject]@{passed=$passed;source=$env:GITHUB_SHA;phase=$Phase;failure=$failure}|
            ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Report -Encoding UTF8
    }
}
if(-not $passed){exit 21}
