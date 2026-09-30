param([Parameter(Mandatory=$true)][string]$OutputDirectory,[string]$EvidenceDirectory='.\test-evidence')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
# This suite installs an unauthenticated vendor MSI and product files/tasks ONLY
# on an empty GitHub-hosted Windows runner. It is not a user troubleshooting tool.
$releaseValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$preflightValidation=($env:GITHUB_REF_NAME -ceq 'main' -and $env:TQR_PREFLIGHT_VALIDATION -ceq $env:GITHUB_RUN_ID -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID))
$developmentValidation=($env:GITHUB_REF_NAME -ceq 'work/public')
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   -not ($developmentValidation -or $preflightValidation -or $releaseValidation) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or [string]::IsNullOrEmpty($env:GITHUB_RUN_ID) -or
   $PSVersionTable.PSVersion.Major -ne 5){throw 'Disposable native Windows lab guard refused this environment.'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if((git -C $repo remote get-url origin).Trim() -notmatch '^https://github.com/coachedai/tailscale-repair-clean(?:\.git)?$' -or
   (git -C $repo rev-parse HEAD).Trim() -cne $env:GITHUB_SHA -or
   ((Get-Content (Join-Path $repo 'release\publish.json') -Raw|ConvertFrom-Json).publish -and -not $releaseValidation)){throw 'Isolated exact-source validation required.'}
New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path
$lab=Join-Path $env:RUNNER_TEMP ('TqrNativeLab-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $lab|Out-Null
. (Join-Path $PSScriptRoot 'trace-native-recurrence.ps1')
$timingContext=$null;$timingReport=$null;$timingError=0
$cases=New-Object 'Collections.Generic.List[object]'
$observations=New-Object 'Collections.Generic.List[object]'
$passed=$false;$cleanupOK=$true;$stage='preflight';$failureType='';$failureCode=0;$reflectionBoundary='';$blockedStage='';$blockedBoundary=''
$cleanupStage='';$cleanupFailureType='';$cleanupFailureCode=0
$vendorInstalled=$false;$productOwned=$false;$vendorOwned=$false;$setupLease=$false
$startupOwned=$false;$startupApp=$null
$createdTasks=New-Object 'Collections.Generic.List[string]'
$folderName='';$folder=$null;$scheduler=$null;$setupType=$null;$msi='';$vendorHash='';$repeatDelta=-1;$fallbackScheduledUtc='';$fallbackFirings=@();$firstDelaySeconds=-1
$app=Join-Path $env:LOCALAPPDATA 'TailscaleQuickRepair'
$program=Join-Path $env:ProgramData 'TailscaleQuickRepair'
$vendorData=Join-Path $env:ProgramData 'Tailscale'
$vendorDir=Join-Path $env:ProgramFiles 'Tailscale'
function Check([bool]$Value,[string]$Name){
    $script:stage=$Name;$cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Native acceptance assertion failed.'}
    Write-Host "PASS real Windows: $Name"
}
function Stage([string]$Name){$script:stage=$Name;Write-Host "Native lab stage: $Name"}
function Setup([string]$Name,[object[]]$Arguments){
    $m=$setupType.GetMethod($Name,[Reflection.BindingFlags]'NonPublic,Static')
    if(-not $m){throw 'Expected native Setup method missing.'}
    $script:stage='native Setup '+$Name
    # PowerShell wraps private CLR return values in PSObject when they cross a
    # function boundary. Reflection needs the original CLR objects, not wrappers.
    $nativeArguments=New-Object object[] $Arguments.Count
    for($i=0;$i -lt $Arguments.Count;$i++){
        if($null -eq $Arguments[$i]){$nativeArguments[$i]=$null}
        else{$nativeArguments[$i]=$Arguments[$i].PSObject.BaseObject}
    }
    $script:reflectionBoundary=$Name+':'+(($nativeArguments|ForEach-Object {if($null -eq $_){'null'}else{$_.GetType().FullName}})-join ',')
    return ,($m.Invoke($null,$nativeArguments))
}
function JsonWrite([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8 -Compress),(New-Object Text.UTF8Encoding($false)))}
function NewState([string]$Name){
    $p=Join-Path $lab $Name;New-Item -ItemType Directory -Path $p|Out-Null
    if(-not [Tqr.AutoRepairPolicyStore]::SetEnabled($p,$true,[DateTime]::UtcNow)){throw 'Lab preference creation failed.'}
    return $p
}
function Download([string]$Url,[string]$Destination,[long]$Limit){
    $u=[Uri]$Url
    if($u.Scheme -ne 'https' -or $u.Host -cne 'pkgs.tailscale.com'){throw 'Untrusted vendor URL.'}
    $request=[Net.HttpWebRequest]::Create($u);$request.AllowAutoRedirect=$false
    $request.Timeout=20000;$request.ReadWriteTimeout=20000;$request.UserAgent='TqrDisposableAcceptance'
    $response=$null;$stream=$null;$file=$null
    try{
        $response=$request.GetResponse()
        if([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt $Limit){throw 'Vendor response refused.'}
        $stream=$response.GetResponseStream();$file=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 65536;$total=0L;$clock=[Diagnostics.Stopwatch]::StartNew()
        while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
            $total+=$n;if($total -gt $Limit -or $clock.Elapsed.TotalSeconds -gt 120){throw 'Vendor download exceeded bounds.'}
            $file.Write($buffer,0,$n)
        }
        if($total -eq 0){throw 'Empty vendor download.'}
    }finally{if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()}}
}
function Msi([bool]$Install){
    $args=if($Install){'/i "'+$msi+'" /qn /norestart TS_NOLAUNCH=1 TS_INSTALLUPDATES=never TS_CHECKUPDATES=never TS_ONBOARDING_FLOW=hide'}else{'/x "'+$msi+'" /qn /norestart'}
    $p=Start-Process (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList $args -WindowStyle Hidden -PassThru
    try{
        if(-not $p.WaitForExit(120000)){throw 'Vendor MSI exceeded the lab time budget.'}
        if($p.ExitCode -ne 0){throw ('Vendor MSI exit code '+$p.ExitCode)}
    }finally{$p.Dispose()}
}
function Observe($Machine,[string]$Label){
    $h=$Machine.Observe()
    $observations.Add([pscustomobject]@{step=$Label;service=$h.Service;startup=$h.Startup;client=$h.Client;backend=$h.Backend})
    return $h
}
function WaitTask($Task){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while([int]$Task.State -in @(2,4)){if($clock.Elapsed.TotalSeconds -gt 120){throw 'Lab task did not finish; no active job is rerun.'};Start-Sleep -Milliseconds 200}
}
function Mark-CleanupFailure([string]$Stage,$Exception=$null){
    $script:cleanupOK=$false
    if([string]::IsNullOrEmpty($script:cleanupStage)){
        $script:cleanupStage=$Stage
        if($Exception){$script:cleanupFailureType=$Exception.GetType().FullName;$script:cleanupFailureCode=$Exception.HResult}
    }
}
function Test-TailscaleServicePresent {
    $service=$null
    try{$service=Get-Service 'Tailscale' -ErrorAction SilentlyContinue;return $null -ne $service}
    finally{if($service){$service.Dispose()}}
}
function Stop-OwnedVendorClient {
    $expected=[IO.Path]::GetFullPath((Join-Path $vendorDir 'tailscale-ipn.exe'))
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    $stopped=0
    foreach($process in @(Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue)){
        try{
            if($process.SessionId -ne $session){continue}
            $actual=[IO.Path]::GetFullPath($process.MainModule.FileName)
            if($actual -ine $expected){throw 'Refusing to stop a non-fixture Tailscale client process.'}
            try{[void]$process.CloseMainWindow()}catch{}
            if(-not $process.WaitForExit(2500)){$process.Kill();if(-not $process.WaitForExit(5000)){throw 'Fixture Tailscale client did not exit.'}}
            $stopped++
        }
        finally{$process.Dispose()}
    }
    return $stopped
}
function MarkerTimes([string]$Path){
    if(-not(Test-Path -LiteralPath $Path)){return @()}
    if((Get-Item -LiteralPath $Path).Length -gt 4096){throw 'Unexpected task marker size.'}
    return @([IO.File]::ReadAllLines($Path)|Where-Object {$_}|ForEach-Object {
        [DateTime]::ParseExact($_,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    })
}
if(-not ('TqrStartupWindowProbe' -as [type])){
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TqrStartupWindowProbe
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);

    public static int CountVisibleTopLevelWindows(int processId)
    {
        int count = 0;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if(pid == (uint)processId && IsWindowVisible(hWnd)) count++;
            return true;
        }, IntPtr.Zero);
        return count;
    }
}
"@
}
function HarmlessTask([string]$Name,[string]$TriggerId){
    $definition=$scheduler.NewTask(0);$definition.Principal.UserId=$sid;$definition.Principal.LogonType=3;$definition.Principal.RunLevel=0
    $definition.Settings.Enabled=$true;$definition.Settings.MultipleInstances=2;$definition.Settings.ExecutionTimeLimit='PT1M'
    [void](Setup 'ConfigureAutoMonitorSchedule' @($definition,[DateTime]::Now,$sid))
    for($i=1;$i -le $definition.Triggers.Count;$i++){$t=$definition.Triggers.Item($i);$t.Enabled=([string]$t.Id -ceq $TriggerId)}
    $marker=Join-Path $lab ($Name+'.timestamps')
    $scriptPath=Join-Path $lab ($Name+'.ps1');$launcher=Join-Path $lab ($Name+'.vbs')
    [IO.File]::WriteAllText($scriptPath,('[IO.File]::AppendAllText('''+$marker.Replace("'","''")+''',[DateTime]::UtcNow.ToString(''o'')+[Environment]::NewLine)'))
    $trace=$null
    if($Name -ceq 'FullFallback'){
        $trace=New-NativeRecurrenceTrace -Marker $marker -ScriptPath $scriptPath -TaskPath ('\'+$folderName+'\'+$Name)
        $script:timingContext=$trace
    }
    $ps=Join-Path $PSHOME 'powershell.exe'
    $command='"'+$ps+'" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$scriptPath+'"'
    [IO.File]::WriteAllText($launcher,[string](Setup 'BuildHiddenLauncherBody' @($command)))
    $action=$definition.Actions.Create(0);$action.Path=Join-Path $env:WINDIR 'System32\wscript.exe';$action.Arguments='"'+$launcher+'"';$action.WorkingDirectory=$lab
    $task=$folder.RegisterTaskDefinition($Name,$definition,2,$null,$null,3,$null)
    return [pscustomobject]@{Task=$task;Marker=$marker;Name=$Name;Trace=$trace}
}
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem,System.ServiceProcess
    $machineSource=[IO.File]::ReadAllText((Join-Path $repo 'src\native\WindowsAutoRepairMachine.cs'))
    Check ($machineSource -notmatch '(?i)proton|nordvpn|mullvad|expressvpn|surfshark|openvpn|wireguard|globalprotect|forticlient|tunnelbear|cyberghost') 'Production Auto Repair contains no VPN-vendor-specific branch'
    Check ($machineSource -notmatch '(?i)\bnetsh\b|\bwinsock\b|\bipconfig\b|set-netadapter|disable-netadapter|enable-netadapter|set-dnsclientserveraddress|clear-dnsclientcache|reset.*adapter') 'Production Auto Repair contains no generic adapter, DNS or Windows-network reset command path'
    Check ($machineSource -match 'Comparison only in memory\.' -and $machineSource -match 'if\(nic\.Description\.IndexOf\("Tailscale"') 'Non-Tailscale interfaces are observed only as an in-memory continuity guard'
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    Check ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Disposable runner has native installation permission'
    Check ([Diagnostics.Process]::GetCurrentProcess().SessionId -gt 0) 'Acceptance runs in a real interactive user session'
    foreach($p in @($app,$program,$vendorDir,$vendorData)){
        Check (-not(Test-Path -LiteralPath $p)) 'Pre-existing product or vendor directory is never reused by this lab'
    }
    Check ($null -eq (Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue)) 'No pre-existing Tailscale service is touched'
    Check (-not(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tailscale') -and -not(Test-Path 'HKLM:\SOFTWARE\Policies\Tailscale')) 'No pre-existing Tailscale registration or policy is overwritten'
    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$rootFolder=$scheduler.GetFolder('\')
    foreach($name in @('Tailscale Quick Repair','Tailscale Quick Repair Auto Monitor')){
        $found=$false;try{[void]$rootFolder.GetTask($name);$found=$true}catch{}
        Check (-not $found) 'No pre-existing Quick Repair task is replaced'
    }
    $startupRegistryPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $startupRegistryName='Tailscale Quick Repair'
    $startupExisting=$null
    try{$startupExisting=(Get-ItemProperty -LiteralPath $startupRegistryPath -Name $startupRegistryName -ErrorAction Stop).$startupRegistryName}catch{}
    Check ($null -eq $startupExisting) 'Disposable runner has no pre-existing Quick Repair startup registration'
    $zip=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter '*SetupPackage-*.zip')
    Check ($zip.Count -eq 1) 'One exact full Setup development package is available'
    Stage 'verify exact package before native installation'
    $archive=[IO.Compression.ZipFile]::OpenRead($zip[0].FullName)
    try{
        $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $archive.Entries){
            $name=$entry.FullName.Replace('\','/')
            if($name.EndsWith('/')){continue}
            if($name -match '(^/|:|(^|/)\.\.(/|$))' -or -not $names.Add($name)){throw 'Unsafe or duplicate package path.'}
        }
    }finally{$archive.Dispose()}
    $package=Join-Path $lab 'package';Expand-Archive -LiteralPath $zip[0].FullName -DestinationPath $package
    $manifest=Get-Content (Join-Path $package 'package-manifest.json') -Raw|ConvertFrom-Json
    foreach($f in $manifest.files){
        $p=Join-Path $package ([string]$f.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if(-not(Test-Path -LiteralPath $p) -or (Get-Item $p).Length -ne $f.size -or (Get-FileHash $p).Hash -ine $f.sha256){throw 'Exact package digest verification failed.'}
    }
    Check ($names.Count -eq @($manifest.files).Count+1) 'Expanded native test payload matches the exact manifest file set'
    $setupAssembly=[Reflection.Assembly]::LoadFile((Join-Path $package 'app\TailscaleQuickRepairSetup.exe'))
    $setupType=$setupAssembly.GetType('PublicSetupHost')
    # Invoke unchanged real Setup cores, not a copied installer algorithm. The
    # interactive entry, UAC and release download are explicitly separate gates.
    $productOwned=$true
    $setupLease=[bool](Setup 'TryAcquireOperationLock' @('setup'))
    Check $setupLease 'Native Setup acquires its actual installation operation lease'
    $nativeManifest=Setup 'ReadPackageManifest' @($package)
    $files=Setup 'VerifyPackage' @($package,$nativeManifest)
    [void](Setup 'ApplyFiles' @($files,$lab))
    foreach($f in $manifest.files){
        $target=[string](Setup 'ResolveInstallTarget' @([string]$f.path))
        if((Get-FileHash -LiteralPath $target).Hash -ine $f.sha256){throw 'Installed payload differs from verified Setup package.'}
    }
    Check $true 'Actual Setup file application installs and verifies every app and protected file'

    Stage 'simulate Windows startup launch without rebooting the disposable runner'
    [void](Setup 'ConfigureStartup' @($true));$startupOwned=$true
    $startupExe=Join-Path $app 'TailscaleQuickRepair.exe'
    $expectedStartup='"'+$startupExe+'" --start-in-tray'
    $startupValue=(Get-ItemProperty -LiteralPath $startupRegistryPath -Name $startupRegistryName -ErrorAction Stop).$startupRegistryName
    Check ([string]$startupValue -ceq $expectedStartup -and [bool](Setup 'IsStartupEnabled' @())) 'Actual Setup writes the exact per-user --start-in-tray startup command'

    $beforeShellChildren=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.Name -in @('powershell.exe','pwsh.exe','cmd.exe','conhost.exe','wscript.exe','cscript.exe')}|Select-Object -ExpandProperty ProcessId)
    $startupApp=Start-Process -FilePath $startupExe -ArgumentList '--start-in-tray' -PassThru
    $sampleClock=[Diagnostics.Stopwatch]::StartNew();$samples=0;$maxVisible=0
    while($sampleClock.Elapsed.TotalSeconds -lt 6){
        $startupApp.Refresh()
        if($startupApp.HasExited){break}
        $visible=[TqrStartupWindowProbe]::CountVisibleTopLevelWindows($startupApp.Id)
        if($visible -gt $maxVisible){$maxVisible=$visible}
        $samples++
        Start-Sleep -Milliseconds 100
    }
    $startupApp.Refresh()
    Check (-not $startupApp.HasExited -and $samples -ge 20) 'Exact packaged --start-in-tray launch remains resident during startup simulation'
    Check ($maxVisible -eq 0) 'Start-in-tray simulation exposes no visible top-level Quick Repair window during sampled startup'

    $descendants=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.ParentProcessId -eq $startupApp.Id})
    $consoleChildren=@($descendants|Where-Object {$_.Name -in @('powershell.exe','pwsh.exe','cmd.exe','conhost.exe','wscript.exe','cscript.exe')})
    Check ($consoleChildren.Count -eq 0) 'Native startup path spawns no console or script-host child process'

    try{
        [void]$startupApp.CloseMainWindow()
        if(-not $startupApp.WaitForExit(2500)){$startupApp.Kill();[void]$startupApp.WaitForExit(5000)}
    }finally{$startupApp.Dispose();$startupApp=$null}

    [void](Setup 'ConfigureStartup' @($false));$startupOwned=$false
    $startupAfter=$null
    try{$startupAfter=(Get-ItemProperty -LiteralPath $startupRegistryPath -Name $startupRegistryName -ErrorAction Stop).$startupRegistryName}catch{}
    Check ($null -eq $startupAfter -and -not [bool](Setup 'IsStartupEnabled' @())) 'Actual Setup can remove only its own startup registration after the simulation'

    [void](Setup 'RegisterRepairTask' @());$createdTasks.Add('Tailscale Quick Repair')
    [void](Setup 'RegisterAutoRepairTask' @());$createdTasks.Add('Tailscale Quick Repair Auto Monitor')
    [void](Setup 'ReleaseOperationLock' @());$setupLease=$false
    $dll=Join-Path $program 'TailscaleQuickRepair.Operations.dll';Add-Type -Path $dll
    Check ([IO.Path]::GetFullPath([Tqr.AutoRepairWorker].Assembly.Location) -ieq [IO.Path]::GetFullPath($dll)) 'Worker executes the genuinely installed protected library'
    Check ((Get-FileHash $dll).Hash -eq (Get-FileHash (Join-Path $app 'TailscaleQuickRepair.Operations.dll')).Hash) 'Installed user and protected libraries match byte for byte'
    $machine=New-Object Tqr.WindowsAutoRepairMachine;$h=Observe $machine 'before-vendor-install'
    Check ($h.Service -eq 'Missing' -and -not $machine.CanMutate) 'Production OS boundary detects missing real installation without a PATH fallback'
    $auto=$rootFolder.GetTask('Tailscale Quick Repair Auto Monitor');$d=$auto.Definition
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $user=[string]$d.Principal.UserId
    $actualSid=if($user -match '^S-1-'){$user}else{([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value}
    Check ($actualSid -ceq $sid -and $d.Principal.LogonType -eq 3 -and $d.Principal.RunLevel -eq 1) 'Actual Setup registers the protected task for the same interactive user at highest run level'
    $logonTriggers=@()
    for($i=1;$i -le $d.Triggers.Count;$i++){
        $trigger=$d.Triggers.Item($i)
        if([string]$trigger.Id -ceq 'LocalLogon'){$logonTriggers+=,$trigger}
    }
    $logonTriggerSid=''
    if($logonTriggers.Count -eq 1){
        $triggerUser=[string]$logonTriggers[0].UserId
        try{
            $logonTriggerSid=if($triggerUser -match '^S-1-'){
                $triggerUser
            }else{
                ([Security.Principal.NTAccount]::new($triggerUser)).Translate([Security.Principal.SecurityIdentifier]).Value
            }
        }catch{$logonTriggerSid=''}
    }
    Check ($logonTriggers.Count -eq 1 -and $logonTriggerSid -ceq $sid -and [string]$logonTriggers[0].Delay -ceq 'PT30S') 'Actual protected monitor retains one delayed same-user logon trigger'
    Check (-not [bool]$d.Settings.WakeToRun -and -not [bool]$d.Settings.StartWhenAvailable) 'Logon/background simulation does not wake the PC or replay missed fallback runs'
    Check ($d.Actions.Count -eq 1 -and $d.Actions.Item(1).Arguments -ceq ('"'+(Join-Path $program 'Launch-Auto-Repair-Monitor.vbs')+'"')) 'Actual protected task targets the reviewed fixed hidden launcher'
    $folderName='TqrNativeAcceptance-'+[Guid]::NewGuid().ToString('N');$folder=$rootFolder.CreateFolder($folderName,$null)
    Stage 'download and validate fixed official vendor MSI'
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $vendorUrl='https://pkgs.tailscale.com/stable/tailscale-setup-1.102.3-amd64.msi'
    $msi=Join-Path $lab 'vendor.msi';$checksum=Join-Path $lab 'vendor.sha256'
    Download ($vendorUrl+'.sha256') $checksum 1024
    $checksumText=[IO.File]::ReadAllText($checksum).Trim()
    if($checksumText -notmatch '^([a-fA-F0-9]{64})(?:\s+\*?[^\r\n]+)?$'){throw 'Official vendor checksum format invalid.'}
    $vendorHash=$Matches[1].ToLowerInvariant();Download $vendorUrl $msi 160MB
    Check ((Get-FileHash $msi).Hash -ieq $vendorHash) 'Fixed official MSI matches its bounded HTTPS checksum response'
    $signature=Get-AuthenticodeSignature -FilePath $msi
    $publisher=if($signature.SignerCertificate){$signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)}else{''}
    Check ($signature.Status -eq 'Valid' -and $publisher -match '^Tailscale Inc\.?$') 'Windows validates the vendor MSI Authenticode signature and publisher'
    # Disable vendor telemetry BEFORE its first service start; no key, login,
    # tailnet join or peer configuration is ever supplied to this disposable lab.
    $vendorOwned=$true;New-Item -ItemType Directory -Path $vendorData|Out-Null
    [IO.File]::WriteAllText((Join-Path $vendorData 'tailscaled-env.txt'),"TS_NO_LOGS_NO_SUPPORT=true`n")
    $env:TS_NO_LOGS_NO_SUPPORT='true'
    Stage 'install unauthenticated official Tailscale in disposable machine'
    Msi $true;$vendorInstalled=$true
    $service=Get-Service 'Tailscale';$service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30));$service.Dispose()
    Check (Test-Path (Join-Path $vendorDir 'tailscale.exe')) 'Official vendor MSI installs the real CLI in the fixed installation directory'
    $machine=New-Object Tqr.WindowsAutoRepairMachine
    $wait=[Diagnostics.Stopwatch]::StartNew()
    do{$h=$machine.Observe();if($h.Backend -in @('NeedsLogin','Stopped')){break};Start-Sleep -Milliseconds 250}while($wait.Elapsed.TotalSeconds -lt 20)
    $h=Observe $machine 'unauthenticated-vendor'
    Check ($h.Service -eq 'Running' -and $h.Backend -in @('NeedsLogin','Stopped')) 'Production local collector reads the real unauthenticated backend state'
    Check $machine.CanContinue 'Installed production boundary retains a stable interactive environment'
    $intentRoot=NewState 'real-observed-intent';$result=[Tqr.AutoRepairWorker]::Execute($intentRoot,$machine)
    Check ($result.status -eq 'manual' -and $result.actionsAttempted -eq 0 -and -not $result.recoveryConfirmed) 'Real unauthenticated vendor state requires attention without automatic mutation'

    # Exercise the actual production client-launch boundary without pretending
    # that an unauthenticated backend authorises automatic repair. No login key,
    # peer or sign-in command is supplied to the disposable runner.
    $script:clientAuthorizations=0
    $opened=$machine.OpenClient([Action]{ $script:clientAuthorizations++ })
    $clientHealth=Observe (New-Object Tqr.WindowsAutoRepairMachine) 'after-real-client-open'
    Check ($opened -and $script:clientAuthorizations -eq 1 -and $clientHealth.Client -eq 'Running' -and
        $clientHealth.Backend -in @('NeedsLogin','Stopped')) 'Production client boundary opens the exact installed Tailscale client in the current session'
    $stillHeld=[Tqr.AutoRepairWorker]::Execute($intentRoot,(New-Object Tqr.WindowsAutoRepairMachine))
    Check ($stillHeld.status -eq 'manual' -and $stillHeld.actionsAttempted -eq 0 -and -not $stillHeld.recoveryConfirmed) 'Opening the real client cannot bypass the preserved sign-in or disconnect hold'
    $stoppedClients=Stop-OwnedVendorClient
    $clientWait=[Diagnostics.Stopwatch]::StartNew();$closedHealth=$null
    do{$closedHealth=(New-Object Tqr.WindowsAutoRepairMachine).Observe();if($closedHealth.Client -eq 'Closed'){break};Start-Sleep -Milliseconds 250}while($clientWait.Elapsed.TotalSeconds -lt 10)
    Check ($stoppedClients -ge 1 -and $closedHealth.Client -eq 'Closed') 'Native lab closes only the exact fixture-owned client after the reopen acceptance'

    $event=HarmlessTask 'RealServiceEvent' 'LocalSystemEvents'
    Check (@(MarkerTimes $event.Marker).Count -eq 0) 'Service-event acceptance starts without a pre-existing success marker'
    Stage 'stop only the vendor service installed by this lab'
    Check (@((Get-Service 'Tailscale').DependentServices|Where-Object Status -eq 'Running').Count -eq 0) 'Disposable vendor service has no running dependents before the controlled test stop'
    Stop-Service 'Tailscale';(Get-Service 'Tailscale').WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(15))
    $machine=New-Object Tqr.WindowsAutoRepairMachine;$result=[Tqr.AutoRepairWorker]::Execute($intentRoot,$machine)
    Check ($result.actionsAttempted -eq 0 -and (Get-Service 'Tailscale').Status -eq 'Stopped') 'Previously observed sign-in or disconnect intent survives actual service loss'
    Set-Service 'Tailscale' -StartupType Disabled
    $h=Observe (New-Object Tqr.WindowsAutoRepairMachine) 'disabled-service'
    $disabledRoot=NewState 'real-disabled-service';$result=[Tqr.AutoRepairWorker]::Execute($disabledRoot,(New-Object Tqr.WindowsAutoRepairMachine))
    Check ($h.Startup -eq 'Disabled' -and $result.actionsAttempted -eq 0 -and (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tailscale').Start -eq 4) 'Actual disabled service remains disabled and no repair action is authorised'
    Set-Service 'Tailscale' -StartupType Automatic
    # A distinct empty policy fixture models no previously observed intent. The
    # previous intentRoot is retained unmodified; no budget/marker is deleted.
    $startRoot=NewState 'real-first-observed-stopped-service'
    $machine=New-Object Tqr.WindowsAutoRepairMachine;$r1=[Tqr.AutoRepairWorker]::Execute($startRoot,$machine)
    Check ($r1.reason -eq 'confirming_fault' -and $r1.actionsAttempted -eq 0) 'Actual stopped-service recovery waits for a second real-time observation'
    Stage 'wait real settling interval without advancing the worker clock'
    Start-Sleep -Seconds 32
    $machine=New-Object Tqr.WindowsAutoRepairMachine;$r2=[Tqr.AutoRepairWorker]::Execute($startRoot,$machine)
    $h=Observe (New-Object Tqr.WindowsAutoRepairMachine) 'after-real-service-start'
    Check ($r2.actionsCompleted -eq 1 -and $r2.action1 -eq 'service_started' -and $h.Service -eq 'Running') 'Actual production worker starts the eligible real service under its genuine lease'
    Check (-not $r2.recoveryConfirmed -and $r2.lastRepairUtc -eq '' -and $h.Backend -in @('NeedsLogin','Stopped')) 'A real successful service start is not misreported as authenticated connection recovery'
    $history=[Tqr.LocalHistory]::Read($startRoot)
    Check ($history.Entries.code -contains 'auto_service_started' -and $history.Entries.code -contains 'auto_unconfirmed' -and $history.Entries.code -notcontains 'auto_recovered') 'Real service action leaves truthful bounded background History'
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    while(@(MarkerTimes $event.Marker).Count -eq 0 -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 250}
    Check (@(MarkerTimes $event.Marker).Count -ge 1) 'Actual Windows service-control event fires the exact delayed Setup subscription with a harmless action'
    $event.Task.Enabled=$false;WaitTask $event.Task
    # Directly exercise the installed production task, not a scheduler substitute.
    Stage 'execute actual protected scheduled monitor entry'
    Check ([Tqr.AutoRepairPolicyStore]::SetEnabled($app,$true,[DateTime]::UtcNow)) 'Explicit lab opt-in is saved before the actual protected task runs'
    WaitTask $auto;$before=[Tqr.AutoRepairRecords]::Current($app)
    if($before){
        $remaining=31-([DateTime]::UtcNow-[DateTime]::Parse($before.lastCheckedUtc)).TotalSeconds
        if($remaining -gt 0){Start-Sleep -Milliseconds ([int][Math]::Ceiling($remaining*1000))}
    }
    $start=[DateTime]::UtcNow;$running=$auto.Run($null)
    $deadline=[DateTime]::UtcNow.AddSeconds(35);$observed=$null
    do{
        $observed=[Tqr.AutoRepairRecords]::Current($app)
        if($observed -and [DateTime]::Parse($observed.lastCheckedUtc).ToUniversalTime() -ge $start){break}
        Start-Sleep -Milliseconds 250
    }while([DateTime]::UtcNow -lt $deadline)
    WaitTask $auto
    Check ($observed -and [DateTime]::Parse($observed.lastCheckedUtc).ToUniversalTime() -ge $start -and $observed.phase -eq 'Complete' -and $observed.status -eq 'manual' -and $observed.actionsAttempted -eq 0) 'Actual highest-interactive task executes the unmodified installed monitor and publishes a fresh attention result'
    Check ([int64]$auto.LastTaskResult -eq 20) 'Task Scheduler receives the real monitor attention exit code without a repair success claim'
    Check ([Tqr.AutoRepairPolicyStore]::SetEnabled($app,$false,[DateTime]::UtcNow)) 'Lab opt-out is persisted before testing the actual disabled task'
    $recordHash=(Get-FileHash (Join-Path $app 'auto-repair-state.json')).Hash
    WaitTask $auto;[void]$auto.Run($null);Start-Sleep -Seconds 2;WaitTask $auto
    Check ([int64]$auto.LastTaskResult -eq 0 -and (Get-FileHash (Join-Path $app 'auto-repair-state.json')).Hash -eq $recordHash) 'Actual disabled protected task exits quietly without overwriting prior evidence'
    # Measure recurrence after installation activity, not while MSI/first-run
    # process setup can delay the first marker. Keep the full interval assertion.
    $repeat=HarmlessTask 'FullFallback' 'LocalFallback'
    Check ($repeat.Task.Definition.Triggers.Item(1).Repetition.Interval -eq 'PT5M') 'Real fallback task retains the full five-minute repetition interval'
    Check (-not [bool]$repeat.Task.Definition.Settings.StartWhenAvailable) 'Real fallback does not queue a separate catch-up run after a missed time occurrence'
    $fallbackScheduledUtc=[DateTime]::Parse([string]$repeat.Task.Definition.Triggers.Item(1).StartBoundary).ToUniversalTime().ToString('o')
    Stage 'observe second real fallback firing after a full five minutes'
    $recurrenceWait=[Diagnostics.Stopwatch]::StartNew()
    do{
        Add-NativeRecurrenceClockSample $repeat.Trace $repeat.Task
        $times=@(MarkerTimes $repeat.Marker);if($times.Count -ge 2){break}
        Start-Sleep -Milliseconds 500
    }while($recurrenceWait.Elapsed.TotalSeconds -lt 420)
    $timingReport=Read-NativeRecurrenceTrace $repeat.Trace $repeat.Task
    $fallbackFirings=@($times|ForEach-Object {$_.ToString('o')})
    if($times.Count){$firstDelaySeconds=($times[0]-[DateTime]::Parse($fallbackScheduledUtc)).TotalSeconds}
    Check ($times.Count -ge 2) 'Real native fallback fires twice without a resident UI or any manual task Run request'
    $repeatDelta=($times[1]-$times[0]).TotalSeconds
    Check ($repeatDelta -ge 290 -and $repeatDelta -le 345) 'Measured recurrence spans the full five-minute interval without an accelerated clock'
    Check ($timingReport.qpcSeconds -ge 290 -and $timingReport.qpcSeconds -le 345) 'Independent monotonic clock confirms the same full five-minute interval'
    Check ($timingReport.observations.Count -ge 2 -and $timingReport.eventReadError -eq 0 -and @($timingReport.events).Count -gt 0) 'Recurrence retains actual task-instance and trigger evidence'
    $repeat.Task.Enabled=$false;WaitTask $repeat.Task
    Check (@(Get-Process -Name 'TailscaleQuickRepair' -ErrorAction SilentlyContinue).Count -eq 0) 'Native acceptance did not require a resident Quick Repair GUI'
    $passed=$true
}catch{
    $blockedStage=$stage;$blockedBoundary=$reflectionBoundary
    $failureType=$_.Exception.GetType().FullName;$failureCode=$_.Exception.HResult
    if($_.Exception.InnerException){$failureType=$_.Exception.InnerException.GetType().FullName;$failureCode=$_.Exception.InnerException.HResult}
    Write-Host ('Native Windows gate blocked at: '+$stage+'; type='+$failureType+'; code='+$failureCode)
}finally{
    # Only this empty-runner suite's own installation and tasks are cleaned up.
    if($startupApp){
        try{$startupApp.Refresh();if(-not $startupApp.HasExited){$startupApp.Kill();[void]$startupApp.WaitForExit(5000)}}catch{Mark-CleanupFailure 'stop_startup_fixture_app' $_.Exception}
        try{$startupApp.Dispose()}catch{}
        $startupApp=$null
    }
    if($startupOwned){
        try{
            Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Tailscale Quick Repair' -ErrorAction SilentlyContinue
            $startupOwned=$false
        }catch{Mark-CleanupFailure 'remove_startup_fixture_registration' $_.Exception}
    }
    # Never reset a policy/ownership marker to make an assertion pass.
    if($timingContext){
        try{$timingReport=Read-NativeRecurrenceTrace $timingContext $repeat.Task}catch{$timingError=$_.Exception.HResult;Mark-CleanupFailure 'read_recurrence_trace' $_.Exception}
        try{Close-NativeRecurrenceTrace $timingContext}catch{$timingError=$_.Exception.HResult;Mark-CleanupFailure 'restore_scheduler_channel' $_.Exception}
        if($timingReport){$timingReport.channelRestored=$timingContext.Restored;JsonWrite (Join-Path $evidence 'native-recurrence-trace.json') $timingReport}
    }
    if($setupLease){try{[void](Setup 'ReleaseOperationLock' @())}catch{Mark-CleanupFailure 'release_setup_lease' $_.Exception}}
    if($scheduler){
        foreach($name in $createdTasks){
            try{$task=$scheduler.GetFolder('\').GetTask($name);$task.Enabled=$false;WaitTask $task;$scheduler.GetFolder('\').DeleteTask($name,0)}
            catch{if($_.Exception.HResult -ne -2147024894){Mark-CleanupFailure ('delete_product_task:'+ $name) $_.Exception}}
        }
        if($folderName){
            foreach($name in @('FullFallback','RealServiceEvent')){
                try{$task=$folder.GetTask($name);$task.Enabled=$false;WaitTask $task;$folder.DeleteTask($name,0)}
                catch{if($_.Exception.HResult -ne -2147024894){Mark-CleanupFailure ('delete_fixture_task:'+ $name) $_.Exception}}
            }
            try{$scheduler.GetFolder('\').DeleteFolder($folderName,0)}catch{if($_.Exception.HResult -ne -2147024894){Mark-CleanupFailure 'delete_fixture_folder' $_.Exception}}
        }
        foreach($name in $createdTasks){
            try{[void]$scheduler.GetFolder('\').GetTask($name);Mark-CleanupFailure ('product_task_still_present:'+ $name)}
            catch{if($_.Exception.HResult -ne -2147024894){Mark-CleanupFailure ('verify_product_task_absent:'+ $name) $_.Exception}}
        }
    }
    if($vendorOwned){
        try{[void](Stop-OwnedVendorClient)}catch{Mark-CleanupFailure 'stop_fixture_client' $_.Exception}
    }
    if($vendorOwned -and $vendorInstalled){
        try{
            Msi $false
            $removeWait=[Diagnostics.Stopwatch]::StartNew()
            while((Test-TailscaleServicePresent) -and $removeWait.Elapsed.TotalSeconds -lt 20){Start-Sleep -Milliseconds 250}
            if(Test-TailscaleServicePresent){Mark-CleanupFailure 'vendor_service_still_registered'}
        }catch{Mark-CleanupFailure 'uninstall_vendor_msi' $_.Exception}
    }
    if($vendorOwned -and (Test-TailscaleServicePresent)){Mark-CleanupFailure 'vendor_service_present_after_cleanup'}
    $cases.Add([pscustomobject]@{name='Only owned native lab tasks and vendor installation are cleaned up';passed=$cleanupOK})
    [pscustomobject]@{
        passed=($passed -and $cleanupOK);source=$env:GITHUB_SHA;scope='Real empty GitHub-hosted Windows machine: unmodified Setup cores, exact packaged startup-in-tray simulation, installed worker and official unauthenticated vendor service; real scheduled dispatch and full recurrence';
        vendorVersion='1.102.3';vendorSha256=$vendorHash;recurrenceSeconds=$repeatDelta;fallbackScheduledUtc=$fallbackScheduledUtc;fallbackFirings=$fallbackFirings;firstDelaySeconds=$firstDelaySeconds;cases=@($cases.ToArray());observations=@($observations.ToArray());
        failureStage=$(if($passed){''}else{$blockedStage});failureType=$failureType;failureCode=$failureCode;reflectionBoundary=$blockedBoundary;timingTraceError=$timingError;
        cleanupStage=$cleanupStage;cleanupFailureType=$cleanupFailureType;cleanupFailureCode=$cleanupFailureCode;
        limits=@('No tailnet login, authentication key or remote peer','Fresh stopped-service policy is an explicitly separate state fixture; observed-intent state is preserved','Real service event uses the exact Setup subscription with a harmless action; actual monitor task dispatch is a separate test','Setup verification/application/registration cores execute natively; interactive UAC, alternate-admin, restart/rollback and full entry are not certified','Real client reopen is exercised without authentication; authenticated recovery remains separate','No actual reboot, sleep/resume, logoff/logon or VPN transition is induced; startup command, tray launch and logon-trigger behavior are simulated in-session on the disposable runner','No raw vendor logs, host paths, usernames, addresses, private state or MSI is uploaded; transient files remain only on the disposable runner')
    }|ConvertTo-Json -Depth 10|Set-Content (Join-Path $evidence 'native-windows-results.json') -Encoding UTF8
}
if(-not $passed -or -not $cleanupOK){$why=if(-not $passed){$blockedStage}else{$cleanupStage};throw ('Native Windows acceptance remains blocked: '+$why)}
