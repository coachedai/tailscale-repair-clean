param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Update Guardian tests require native Windows PowerShell 5.1.'}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false
function Check([bool]$Value,[string]$Name){
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw ('FAILED Update Guardian: '+$Name)}
    Write-Host ('PASS Update Guardian: '+$Name)
}
function Native([Type]$Type,[string]$Name,[object[]]$Arguments=@()){
    $method=$Type.GetMethod($Name,[Reflection.BindingFlags]'Static,Public,NonPublic')
    if(-not $method){throw ('Missing native Guardian method: '+$Name)}
    $values=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$values[$i]=$null}else{$values[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    try{return ,($method.Invoke($null,$values))}catch{
        $e=$_.Exception
        while($e.InnerException){$e=$e.InnerException}
        throw $e
    }
}
$work=Join-Path $env:RUNNER_TEMP ('TqrGuardian-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
try{
    $compiler=@(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )|Where-Object{Test-Path $_}|Select-Object -First 1
    if(-not $compiler){throw 'C# compiler unavailable.'}
    $framework=Split-Path $compiler -Parent
    $dll=Join-Path $work 'UpdaterGuardian.dll'
    $args=@('/nologo','/target:library','/optimize+',('/out:"'+$dll+'"'))
    foreach($reference in @('System.Web.Extensions.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll','System.Windows.Forms.dll','System.Drawing.dll')){
        $args+=('/reference:"'+(Join-Path $framework $reference)+'"')
    }
    foreach($source in @((Join-Path $repo 'src/native/UpdaterHost.cs'),(Join-Path $repo 'src/native/OperationGate.cs'))){
        $args+=('"'+$source+'"')
    }
    $p=Start-Process -FilePath $compiler -ArgumentList ($args -join ' ') -WindowStyle Hidden -Wait -PassThru
    Check ($p.ExitCode -eq 0 -and (Test-Path $dll)) 'Updater Guardian source compiles on native .NET Framework'
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
    $type=$assembly.GetType('Program',$true)

    foreach($code in @(408,429,500,503,599)){
        Check ([bool](Native $type 'IsTransientStatusCode' @([int]$code))) ('Transient HTTP '+$code+' is retryable')
    }
    foreach($code in @(400,401,403,404)){
        Check (-not [bool](Native $type 'IsTransientStatusCode' @([int]$code))) ('Integrity/access HTTP '+$code+' is not retried')
    }
    $timeout=New-Object Net.WebException('fixture',[Net.WebExceptionStatus]::Timeout)
    Check ([bool](Native $type 'IsTransientWebFailure' @($timeout))) 'Transport timeout is classified as retryable'
    $integrity=New-Object IO.InvalidDataException('fixture raw text must not escape')
    Check (([string](Native $type 'GetFailureReason' @($integrity))) -ceq 'integrity_refused') 'Integrity refusal is typed without raw exception text'
    $safe=[string](Native $type 'GetSafeResultMessage' @('failed','integrity_refused',$false))
    Check ($safe -match 'integrity' -and $safe -notmatch 'fixture raw') 'Persisted/displayed integrity message is fixed and privacy-safe'

    function New-RecoveryFixture([string]$Root,[string]$TargetText,[string]$BackupText,[string]$TargetOverride='',[switch]$MissingBackup,[switch]$BadHash){
        New-Item -ItemType Directory -Path $Root -Force|Out-Null
        $rollback=Join-Path $Root 'UpdateRollback';New-Item -ItemType Directory -Path $rollback -Force|Out-Null
        $target=if($TargetOverride){$TargetOverride}else{Join-Path $Root 'fixture.exe'}
        [IO.File]::WriteAllText($target,$TargetText,(New-Object Text.UTF8Encoding($false)))
        $backup=Join-Path $rollback 'file-1.bak'
        if(-not $MissingBackup){[IO.File]::WriteAllText($backup,$BackupText,(New-Object Text.UTF8Encoding($false)))}
        $hash=if(-not $MissingBackup){(Get-FileHash $backup -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
        if($BadHash){$hash='0'*64}
        $entry=[ordered]@{Target=$target;Backup=$backup;Existed=$true;RelativePath='app/fixture.exe';BackupSha256=$hash}
        [IO.File]::WriteAllText((Join-Path $rollback 'rollback-map.json'),([ordered]@{schema=2;version='fixture';versionCode=1;files=@($entry)}|ConvertTo-Json -Depth 6 -Compress),(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $Root 'Update.pending'),'fixture',(New-Object Text.UTF8Encoding($false)))
        return [pscustomobject]@{Target=$target;Backup=$backup;Pending=(Join-Path $Root 'Update.pending')}
    }

    $recoverRoot=Join-Path $work 'recover-good'
    $fixture=New-RecoveryFixture $recoverRoot 'new' 'old'
    Check ([bool](Native $type 'RecoverInterruptedTransactionAt' @($recoverRoot))) 'Interrupted transaction is detected and recovered before another update'
    Check (([IO.File]::ReadAllText($fixture.Target) -ceq 'old') -and -not(Test-Path $fixture.Pending)) 'Recovered predecessor bytes are verified before pending state is cleared'

    $outside=Join-Path $work 'outside.txt';[IO.File]::WriteAllText($outside,'outside',(New-Object Text.UTF8Encoding($false)))
    $escapeRoot=Join-Path $work 'recover-escape'
    $escape=New-RecoveryFixture $escapeRoot 'outside' 'replacement' -TargetOverride $outside
    $refused=$false
    try{[void](Native $type 'RecoverInterruptedTransactionAt' @($escapeRoot))}catch{
        $e=$_.Exception;while($e.InnerException){$e=$e.InnerException}
        $refused=$e.GetType().Name -match 'UpdateRecoveryRequiredException'
    }
    Check ($refused -and [IO.File]::ReadAllText($outside) -ceq 'outside' -and (Test-Path $escape.Pending)) 'Recovery map cannot write outside the Quick Repair root'

    $missingRoot=Join-Path $work 'recover-missing'
    $missing=New-RecoveryFixture $missingRoot 'new' 'old' -MissingBackup
    $missingRefused=$false
    try{[void](Native $type 'RecoverInterruptedTransactionAt' @($missingRoot))}catch{
        $e=$_.Exception;while($e.InnerException){$e=$e.InnerException}
        $missingRefused=$e.GetType().Name -match 'UpdateRecoveryRequiredException'
    }
    Check ($missingRefused -and [IO.File]::ReadAllText($missing.Target) -ceq 'new' -and (Test-Path $missing.Pending)) 'Missing rollback evidence is preserved and never reported as recovered'

    $hashRoot=Join-Path $work 'recover-hash'
    $bad=New-RecoveryFixture $hashRoot 'new' 'old' -BadHash
    $hashRefused=$false
    try{[void](Native $type 'RecoverInterruptedTransactionAt' @($hashRoot))}catch{
        $e=$_.Exception;while($e.InnerException){$e=$e.InnerException}
        $hashRefused=$e.GetType().Name -match 'UpdateRecoveryRequiredException'
    }
    Check ($hashRefused -and [IO.File]::ReadAllText($bad.Target) -ceq 'new' -and (Test-Path $bad.Pending)) 'Tampered rollback backup is not trusted and recovery evidence remains'

    $normal=@(Get-ChildItem -LiteralPath $OutputDirectory -File -Filter 'TailscaleQuickRepair-*.zip'|Where-Object{$_.Name -notmatch 'SetupPackage|migration'})
    if($normal.Count -ne 1){throw ('Expected one normal update package; found '+$normal.Count)}
    $expanded=Join-Path $work 'package';Expand-Archive -LiteralPath $normal[0].FullName -DestinationPath $expanded
    $uiPath=Join-Path $expanded 'app/Tailscale-Repair-UI.ps1'
    $text=[IO.File]::ReadAllText($uiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Guardian-enabled packaged UI parses on Windows PowerShell 5.1'
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Show-UpdateResult'},$true))
    Check ($nodes.Count -eq 1) 'Exactly one packaged Guardian result renderer exists'
    . ([scriptblock]::Create($nodes[0].Extent.Text))
    Add-Type -AssemblyName PresentationFramework
    function Get-Brush([string]$Name){
        switch($Name){
            'Green' { return [Windows.Media.Brushes]::Green }
            'Red' { return [Windows.Media.Brushes]::Red }
            'Blue' { return [Windows.Media.Brushes]::DodgerBlue }
            default { return [Windows.Media.Brushes]::Orange }
        }
    }
    $UpdateStatusText=New-Object Windows.Controls.TextBlock
    $UpdateDetailText=New-Object Windows.Controls.TextBlock
    $UpdateDetailText.Visibility=[Windows.Visibility]::Collapsed
    function Write-LocalHistoryEvent([string]$Kind){}
    function Request-SmartNotification([string]$Kind,[string]$Stamp){return $true}
    $ProtectedUpdateMarkerPath=Join-Path $work 'protected-update.json'
    $UpdateResultPath=Join-Path $work 'update-result.json'

    function Invoke-ResultFixture($Data){
        [IO.File]::WriteAllText($UpdateResultPath,($Data|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
        Show-UpdateResult
    }
    Invoke-ResultFixture ([ordered]@{schema=2;success=$false;version='';outcome='rolled_back';reason='transaction_rolled_back';recoveredPrevious=$false;message='SHOULD_NOT_RENDER_RAW_TEXT';completedUtc=[DateTime]::UtcNow.ToString('o')})
    Check ($UpdateStatusText.Text -ceq 'Update rolled back safely' -and $UpdateDetailText.Text -notmatch 'SHOULD_NOT_RENDER') 'Verified rollback is described truthfully without raw persisted text'
    Check (-not(Test-Path $UpdateResultPath)) 'Recognised typed result is consumed once'

    Invoke-ResultFixture ([ordered]@{schema=2;success=$false;version='';outcome='recovery_required';reason='recovery_required';recoveredPrevious=$false;message='SHOULD_NOT_RENDER_RAW_TEXT';completedUtc=[DateTime]::UtcNow.ToString('o')})
    Check ($UpdateStatusText.Text -ceq 'Update needs recovery' -and $UpdateDetailText.Text -match 'Recovery data was kept' -and $UpdateDetailText.Text -notmatch 'SHOULD_NOT_RENDER') 'Unverified rollback is never presented as successful recovery'

    Invoke-ResultFixture ([ordered]@{schema=2;success=$true;version='fixture';outcome='installed';reason='none';recoveredPrevious=$true;message='SHOULD_NOT_RENDER_RAW_TEXT';completedUtc=[DateTime]::UtcNow.ToString('o')})
    Check ($UpdateStatusText.Text -ceq 'Updated successfully - fixture' -and $UpdateDetailText.Text -match 'previous interrupted update was recovered') 'Successful update reports a verified prior recovery separately'

    $passed=$true
}finally{
    [pscustomobject]@{schema=1;passed=$passed;source=$env:GITHUB_SHA;scope='Typed updater recovery, bounded transport retry classification and final packaged result presentation on disposable fixtures.';cases=@($cases.ToArray())}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'update-guardian-results.json') -Encoding UTF8
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
