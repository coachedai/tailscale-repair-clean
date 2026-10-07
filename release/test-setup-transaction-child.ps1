param(
    [Parameter(Mandatory=$true)][ValidateSet('apply','recover')][string]$Mode,
    [Parameter(Mandatory=$true)][ValidateRange(1,11)][int]$Checkpoint,
    [Parameter(Mandatory=$true)][string]$InputDirectory,
    [Parameter(Mandatory=$true)][string]$WorkDirectory
)
# Internal to the owned disposable transaction test; never an installer entry.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$ready=$null;$proceed=$null;$type=$null;$lease=$false;$exitCode=90
try{
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
       $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
       $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
       $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
       $env:GITHUB_REF_NAME -notin @('main','work/public') -or
       [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
       $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or
       $PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Hosted child boundary refused.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'Elevated disposable child required.'
    }
    if($env:TQR_SETUP_RELOCATION_TEST_APPDIR){throw 'Relocation override refused.'}
    if($env:TQR_CRASH_NONCE -cnotmatch '^[a-f0-9]{32}$' -or
       $env:TQR_CRASH_OWNER -cnotmatch '^[1-9][0-9]*$' -or
       $env:TQR_CRASH_OWNER_STARTED -cnotmatch '^[1-9][0-9]*$'){throw 'Owned handshake absent.'}
    $hostPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $owner=[Diagnostics.Process]::GetProcessById([int]$env:TQR_CRASH_OWNER)
    if($owner.HasExited -or $owner.Id -eq $PID -or
       $owner.StartTime.ToUniversalTime().Ticks -ne [int64]$env:TQR_CRASH_OWNER_STARTED -or
       $owner.MainModule.FileName -ine $hostPath){throw 'Owning process identity mismatch.'}
    function Require-ChildPath([string]$Path){
        $full=[IO.Path]::GetFullPath($Path)
        $temporary=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
        if(-not $full.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase)){throw 'Temporary child path required.'}
        $part=$full
        while($part){
            if(Test-Path -LiteralPath $part){
                if((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked child path refused.'}
            }
            $parent=[IO.Path]::GetDirectoryName($part);if($parent -eq $part){break};$part=$parent
        }
        return $full
    }
    $InputDirectory=Require-ChildPath $InputDirectory
    $WorkDirectory=Require-ChildPath $WorkDirectory
    if($WorkDirectory -cne $env:TQR_CRASH_WORK -or
       -not(Test-Path -LiteralPath $WorkDirectory -PathType Container)){throw 'Owned work boundary mismatch.'}
    # This verifies checkout, both immutable distributions and the current receipt.
    & python -B (Join-Path $PSScriptRoot 'prepare-clean-upgrade.py') verify $InputDirectory
    if($LASTEXITCODE -ne 0){throw 'Child input verification refused.'}
    $pins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'clean-upgrade.json') -Raw|ConvertFrom-Json
    $exeName='TailscaleQuickRepair-Standalone-'+[string]$pins.version+'.exe'
    $candidate=Join-Path $InputDirectory $exeName
    $expected=[string]$pins.files.$exeName.sha256
    $candidateBytes=[IO.File]::ReadAllBytes($candidate)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{$actual=[BitConverter]::ToString($hasher.ComputeHash($candidateBytes)).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
    if($candidateBytes.LongLength -ne [int64]$pins.files.$exeName.size -or $actual -cne $expected){throw 'Child installer integrity refused.'}
    $ready=[Threading.EventWaitHandle]::OpenExisting('Local\TqrTxnReady-'+$env:TQR_CRASH_NONCE)
    $proceed=[Threading.EventWaitHandle]::OpenExisting('Local\TqrTxnProceed-'+$env:TQR_CRASH_NONCE)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $assembly=[Reflection.Assembly]::Load($candidateBytes)
    $type=$assembly.GetType('PublicSetupHost',$true)
    $flags=[Reflection.BindingFlags]'Public,NonPublic,Static'
    function Invoke-ChildNative([string]$Name,[object[]]$Arguments=@()){
        $method=$type.GetMethod($Name,$flags);if(-not $method){throw 'Required native method absent.'}
        $values=New-Object object[] $Arguments.Count
        for($i=0;$i -lt $Arguments.Count;$i++){
            if($null -eq $Arguments[$i]){$values[$i]=$null}else{$values[$i]=$Arguments[$i].PSObject.BaseObject}
        }
        $result=$method.Invoke($null,$values)
        if($null -eq $result){return $null};return ,$result.PSObject.BaseObject
    }
    $package=Require-ChildPath (Join-Path $WorkDirectory 'candidate')
    $manifest=Invoke-ChildNative 'ReadPackageManifest' @($package)
    $plan=Invoke-ChildNative 'VerifyPackage' @($package,$manifest)
    if($plan.Count -ne 11 -or $manifest.VersionCode -ne 30001013){throw 'Fixed candidate plan required.'}
    $recovery=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TailscaleQuickRepair.SetupRecovery'
    $lease=[bool](Invoke-ChildNative 'TryAcquireOperationLock' @('setup'))
    if(-not $lease){throw 'Child could not own the native transaction.'}
    if($Mode -ceq 'apply'){
        if(Test-Path -LiteralPath $recovery){throw 'Earlier recovery evidence must remain untouched.'}
        $callback=[Action[int]]{
            param($step)
            if($step -eq $Checkpoint){
                [void]$ready.Set()
                # Parent must forcibly terminate this process. If its handshake
                # fails, exit without unwinding the transaction or erasing evidence.
                [void]$proceed.WaitOne(60000)
                [Environment]::Exit(91)
            }
        }
        [void](Invoke-ChildNative 'ApplyFilesCore' @($plan,$WorkDirectory,$callback))
        throw 'Requested checkpoint was not reached.'
    }else{
        if(-not(Test-Path -LiteralPath (Join-Path $recovery 'transaction.json') -PathType Leaf)){throw 'Prepared recovery journal required.'}
        [void]$ready.Set()
        if(-not $proceed.WaitOne(60000)){throw 'Recovery handshake timed out.'}
        if(-not [bool](Invoke-ChildNative 'RecoverInterruptedFileTransaction')){throw 'Native recovery did not execute.'}
        $exitCode=0
    }
}catch{
    # Never echo exception strings, installation paths or journal contents.
    Write-Host 'Owned transaction child refused or failed; values withheld.'
}finally{
    if($lease){try{[void](Invoke-ChildNative 'ReleaseOperationLock')}catch{$exitCode=90}}
    if($ready){$ready.Dispose()};if($proceed){$proceed.Dispose()}
}
exit $exitCode
