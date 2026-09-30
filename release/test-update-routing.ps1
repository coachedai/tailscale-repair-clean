param([Parameter(Mandatory=$true)][string]$UiPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Native Windows PowerShell 5.1 required.' }
$root=Join-Path $env:TEMP ('TQR-RouteTest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
$cases=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAILED update route: $Name" }
    $cases.Add([pscustomobject]@{name=$Name;passed=$true});Write-Host "PASS update route: $Name"
}
$oldProbe=$env:TQR_ROUTING_PROBE
try {
    # Harmless native child substituted only as the fixture EXE path. Production
    # route code and the actual packaged WPF button are executed unchanged.
    $stub=Join-Path $root 'probe.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public class TqrRouteProbe {
    public static void Main(string[] args) {
        File.WriteAllLines(Environment.GetEnvironmentVariable("TQR_ROUTING_PROBE"),args);
    }
}
'@ -OutputAssembly $stub -OutputType WindowsApplication
    $text=[IO.File]::ReadAllText($UiPath,[Text.Encoding]::UTF8)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-UpdateInstall'},$true))
    $handoffFunctions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PendingProtectedUpdate'},$true))
    $ackFunctions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Acknowledge-ProtectedRestart'},$true))
    $channelFunctions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-UpdateChannel'},$true))
    Check ($functions.Count -eq 1 -and $handoffFunctions.Count -eq 1 -and $ackFunctions.Count -eq 1 -and $channelFunctions.Count -eq 1 -and $errors.Count -eq 0) 'Final package has one parsed update, protected handoff, restart acknowledgement and channel-selection action'
    $passiveStop=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-PassiveStartupHealth'},$true))
    Check ($passiveStop.Count -eq 1) 'Packaged passive cancellation is available to update routing'
    . ([scriptblock]::Create($passiveStop[0].Extent.Text))
    . ([scriptblock]::Create($functions[0].Extent.Text))
    . ([scriptblock]::Create($handoffFunctions[0].Extent.Text))
    . ([scriptblock]::Create($channelFunctions[0].Extent.Text))
    function Get-Brush([string]$Name) { return [Windows.Media.Brushes]::Gray }
    $handlers=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -ceq '$UpdateNowButton' -and $n.Member.Value -eq 'Add_Click'},$true))
    Check ($handlers.Count -eq 1) 'Final package has one Update now event'
    Check ([regex]::IsMatch($text,'if\s*\(Invoke-PendingProtectedUpdate\)\s*\{\s*return\s*\}',[Text.RegularExpressions.RegexOptions]::Singleline)) 'Successful protected handoff stops normal startup work before repair or health checks begin'
    $xamlMatch=[regex]::Match($text,'(?s)\[xml\]\$xaml\s*=\s*@"\r?\n(?<xaml>.*?)\r?\n"@')
    $UpdateChannelRegistryPath='HKCU:\Software\TailscaleQuickRepair-RouteTest-'+[Guid]::NewGuid().ToString('N')
    $UpdateChannelRegistryName='UpdateChannel'
    New-Item -Path $UpdateChannelRegistryPath -Force|Out-Null
    New-ItemProperty -LiteralPath $UpdateChannelRegistryPath -Name $UpdateChannelRegistryName -Value 'preview' -PropertyType String -Force|Out-Null
    foreach($kind in @('protected','ordinary','handoff','invalid')) {
        [xml]$xaml=$xamlMatch.Groups['xaml'].Value
        $reader=New-Object Xml.XmlNodeReader $xaml;$window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
        $script:routeFixtureClosed=$false
        $window.Add_Closed({$script:routeFixtureClosed=$true})
        $UpdateNowButton=$window.FindName('UpdateNowButton');$CheckForUpdatesButton=$window.FindName('CheckForUpdatesButton')
        $UpdateStatusText=$window.FindName('UpdateStatusText');$UpdateDetailText=$window.FindName('UpdateDetailText')
        $SetupHostPath=$stub;$UpdaterHostPath=$stub;$ProductVersionCode=[int64]1
        $script:repairActive=$false;$script:updateDownloadActive=$false
        $flag=switch($kind){'protected'{$true};'ordinary'{$false};'handoff'{$false};default{'not-a-boolean'}}
        $script:updateManifest=[pscustomobject]@{versionCode=2;version='fixture';requiresSetup=$flag}
        $script:updateManifestChannel='preview'
        if($kind -eq 'handoff'){$script:updateManifest|Add-Member -NotePropertyName protectedHandoff -NotePropertyValue $true}
        $probe=Join-Path $root ($kind+'.args');$env:TQR_ROUTING_PROBE=$probe
        $UpdateNowButton.IsEnabled=$true
        $UpdateNowButton.Add_Click($handlers[0].Arguments[0].ScriptBlock.GetScriptBlock())
        $UpdateNowButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if($kind -eq 'invalid') {
            Start-Sleep -Milliseconds 150
            Check (-not(Test-Path $probe) -and $UpdateStatusText.Text -eq 'Update metadata is invalid') 'Invalid protection flag starts no installer or ordinary updater'
        } else {
            $expectedStatus=if($kind -eq 'protected'){'Installing system update...'}else{'Installing update...'}
            Check ($UpdateNowButton.Content -ceq 'Updating...' -and $UpdateStatusText.Text -ceq $expectedStatus) "$kind route displays clean progress labels"
            $end=[DateTime]::UtcNow.AddSeconds(8)
            while(-not(Test-Path $probe) -and [DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 30}
            Check (Test-Path $probe) "$kind click starts the native fixture child"
            $probeArgs=@(Get-Content $probe)
            if($kind -eq 'protected') {
                Check ($probeArgs.Count -eq 5 -and $probeArgs[0] -eq '--upgrade' -and
                    $probeArgs[1] -eq '--channel' -and $probeArgs[2] -eq 'preview' -and
                    $probeArgs[3] -eq '--target-code' -and $probeArgs[4] -eq '2') 'Direct protected release invokes Setup for the exact Preview channel and target code'
            }
            else {
                Check ($probeArgs[0] -eq '--silent' -and
                    $probeArgs -contains '--current-pid' -and
                    $probeArgs -contains '--current-code' -and
                    $probeArgs -contains '--target-code' -and
                    $probeArgs -contains '--channel' -and
                    $probeArgs -contains 'preview' -and
                    $probeArgs -notcontains '--upgrade') ($kind+' release invokes the normal native updater with exact channel binding')
                if($kind -eq 'handoff'){Check ($script:updateManifest.protectedHandoff -eq $true) 'Protected handoff deliberately travels through the ordinary updater first'}
            }
        }
        # The real updater callback posts Close at Background priority. Drain it
        # while its fixture variables still exist; otherwise a later suite's WPF
        # window could be closed by this dynamically scoped PowerShell delegate.
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        if($kind -ne 'invalid') { Check $script:routeFixtureClosed "$kind updater deferred close completed in its own fixture" }
        else { Check (-not $script:routeFixtureClosed) 'Invalid metadata leaves the app window open' }
        $window.Close()
    }

    # The handoff starts only after the ordinary bridge package has restarted
    # the app. Exercise the actual final function with a harmless Setup fixture.
    $StateDir=$root
    [IO.File]::WriteAllText(
        (Join-Path $StateDir 'version.user.json'),
        ([ordered]@{product='Tailscale Quick Repair';version='fixture';versionCode=2;channel='preview';updateSchema=1;configSchema=2}|ConvertTo-Json -Compress)
    )
    # Simulate a real Windows UAC cancellation at the one process-start
    # boundary. No protected process may start, the marker must remain and the
    # existing window must stay usable so reopening/retrying is safe.
    [xml]$cancelXaml=$xamlMatch.Groups['xaml'].Value
    $cancelReader=New-Object Xml.XmlNodeReader $cancelXaml
    $cancelWindow=[Windows.Markup.XamlReader]::Load($cancelReader);$cancelReader.Close()
    $window=$cancelWindow
    $UpdateStatusText=$window.FindName('UpdateStatusText');$UpdateDetailText=$window.FindName('UpdateDetailText')
    $SetupHostPath=$stub;$ProductVersionCode=[int64]2
    $ProtectedUpdateMarkerPath=Join-Path $root 'cancel-protected-update.json'
    [IO.File]::WriteAllText($ProtectedUpdateMarkerPath,([ordered]@{schema=2;versionCode=2;channel='preview'}|ConvertTo-Json -Compress))
    $script:pendingProtectedUpdateStarted=$false;$script:allowFullExit=$false;$global:TqrUiShutdownRequested=$false
    $script:cancelRoute=$null
    $cancelled=Invoke-PendingProtectedUpdate -StartProcess {
        param($info)
        $script:cancelRoute=[pscustomobject]@{file=[string]$info.FileName;arguments=[string]$info.Arguments;verb=[string]$info.Verb;useShell=[bool]$info.UseShellExecute}
        throw (New-Object ComponentModel.Win32Exception 1223)
    }
    Check (-not $cancelled) 'Cancelling Windows approval starts no protected handoff'
    $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Check ($script:cancelRoute -and $script:cancelRoute.file -ceq $SetupHostPath -and
        $script:cancelRoute.verb -ceq 'runas' -and $script:cancelRoute.useShell -and
        $script:cancelRoute.arguments -ceq ('--upgrade --channel "preview" --target-code 2 --requester-sid "'+$currentSid+'"')) 'Cancelled Windows approval was prepared only for the installed Setup, exact Preview release and initiating SID'
    Check (Test-Path $ProtectedUpdateMarkerPath) 'Cancelling Windows approval preserves the pending protected update'
    Check (-not $script:pendingProtectedUpdateStarted -and -not $script:allowFullExit -and -not $global:TqrUiShutdownRequested) 'Cancelling Windows approval does not arm shutdown or mark the handoff started'
    Check ($cancelWindow.IsVisible -or -not $cancelWindow.IsLoaded) 'Cancellation does not request the application window to close'
    Check ($UpdateStatusText.Text -ceq 'Protected update needs attention') 'Cancellation leaves a clear retryable update state'
    $cancelWindow.Close()

    foreach($markerKind in @('valid','wrong-version','wrong-channel')) {
        [xml]$xaml=$xamlMatch.Groups['xaml'].Value
        $reader=New-Object Xml.XmlNodeReader $xaml;$window=[Windows.Markup.XamlReader]::Load($reader);$reader.Close()
        $UpdateStatusText=$window.FindName('UpdateStatusText');$UpdateDetailText=$window.FindName('UpdateDetailText')
        $SetupHostPath=$stub;$ProductVersionCode=[int64]2
        $ProtectedUpdateMarkerPath=Join-Path $root ($markerKind+'-protected-update.json')
        $versionCode=if($markerKind -eq 'wrong-version'){3}else{2}
        $channel=if($markerKind -eq 'wrong-channel'){'stable'}else{'preview'}
        [IO.File]::WriteAllText($ProtectedUpdateMarkerPath,([ordered]@{schema=2;versionCode=$versionCode;channel=$channel}|ConvertTo-Json -Compress))
        $script:pendingProtectedUpdateStarted=$false;$script:allowFullExit=$false;$global:TqrUiShutdownRequested=$false
        $probe=Join-Path $root ($markerKind+'-handoff.args');$env:TQR_ROUTING_PROBE=$probe
        $started=Invoke-PendingProtectedUpdate
        if($markerKind -eq 'valid'){
            Check $started 'Exact handoff marker starts the refreshed Setup route'
            $end=[DateTime]::UtcNow.AddSeconds(8)
            while(-not(Test-Path $probe) -and [DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 30}
            Check (Test-Path $probe) 'Exact handoff marker starts the native Setup fixture'
            $probeArgs=@(Get-Content $probe)
            $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Check ($probeArgs.Count -eq 7 -and $probeArgs[0] -eq '--upgrade' -and
                $probeArgs[1] -eq '--channel' -and $probeArgs[2] -eq 'preview' -and
                $probeArgs[3] -eq '--target-code' -and $probeArgs[4] -eq '2' -and
                $probeArgs[5] -eq '--requester-sid' -and $probeArgs[6] -ceq $currentSid) 'Pending handoff passes only the exact Preview release and initiating Windows SID'
            Check ($handoffFunctions[0].Extent.Text.Contains("$psi.Verb = 'runas'")) 'Pending handoff requests Windows administrator approval directly'
            Check (Test-Path $ProtectedUpdateMarkerPath) 'UI handoff never deletes the marker before Setup completion'
            $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        }else{
            Start-Sleep -Milliseconds 150
            Check (-not $started -and -not(Test-Path $probe)) 'Wrong-version or wrong-channel handoff marker starts no process'
            Check (Test-Path $ProtectedUpdateMarkerPath) 'Rejected marker is preserved for diagnosis'
        }
        $window.Close()
    }

    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'update-routing-results.json'),(@{passed=$true;scope='Actual packaged WPF Update now event and deferred close with harmless native executable fixture';cases=$cases.ToArray()}|ConvertTo-Json -Depth 8))
} catch {
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'update-routing-results.json'),(@{passed=$false;failure=$_.Exception.Message;cases=$cases.ToArray()}|ConvertTo-Json -Depth 8));throw
} finally {
    try{Remove-Item -LiteralPath $UpdateChannelRegistryPath -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    $env:TQR_ROUTING_PROBE=$oldProbe
}
