# Test-only. Loaded by the guarded empty-runner native suite; never packaged.
# Preserve UTC acceptance while independently measuring QPC and attributing runs.
function New-NativeRecurrenceTrace([string]$Marker,[string]$ScriptPath,[string]$TaskPath) {
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
       $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
       $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or
       $TaskPath -cnotmatch '^\\TqrNativeAcceptance-[a-f0-9]{32}\\FullFallback$') {
        throw 'Native recurrence trace refused this environment or task.'
    }
    $channel='Microsoft-Windows-TaskScheduler/Operational'
    $configuration=New-Object Diagnostics.Eventing.Reader.EventLogConfiguration($channel)
    $wasEnabled=$configuration.IsEnabled
    if(-not $wasEnabled){$configuration.IsEnabled=$true;$configuration.SaveChanges()}
    $context=[pscustomobject]@{
        Marker=$Marker;TaskPath=$TaskPath;Configuration=$configuration;WasEnabled=$wasEnabled
        Clock=[Diagnostics.Stopwatch]::StartNew();Samples=(New-Object 'Collections.Generic.List[object]')
        LastSample=$null;NextSample=0.0;Restored=$false
    }
    $script:timingContext=$context
    # This is still the same fixed Windows PowerShell action behind WScript.
    # Capture both clocks BEFORE COM/CIM calls, then write the old UTC marker
    # last so its presence also means that the bounded diagnostic line is complete.
    $worker=@'
$ErrorActionPreference='Stop'
$qpc=[Diagnostics.Stopwatch]::GetTimestamp();$utc=[DateTime]::UtcNow
$frequency=[Diagnostics.Stopwatch]::Frequency
$marker='__MARKER__';$taskPath='__TASK__'
$record=[ordered]@{schema=1;utc=$utc.ToString('o');qpc=$qpc;frequency=$frequency;writer=$PID;parent=0;instances=@();error=0}
$service=$null;$folder=$null;$task=$null;$instances=$null
try {
    $self=Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId='+$PID) -OperationTimeoutSec 5
    $record.parent=[int]$self.ParentProcessId
    $service=New-Object -ComObject 'Schedule.Service';$service.Connect()
    $folder=$service.GetFolder($taskPath.Substring(0,$taskPath.LastIndexOf('\')))
    $task=$folder.GetTask('FullFallback');$instances=$task.GetInstances(0)
    if($instances.Count -gt 4){throw 'Unexpected fixture task instance count.'}
    for($i=1;$i -le $instances.Count;$i++){
        $instance=$instances.Item($i)
        try {
            $record.instances+=@{id=([Guid]([string]$instance.InstanceGuid)).ToString('N');engine=[int]$instance.EnginePID;matches=([string]$instance.Path -ceq $taskPath)}
        } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($instance) }
    }
} catch { $record.error=[int]$_.Exception.HResult }
finally {
    foreach($item in @($instances,$task,$folder,$service)){
        if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}
    }
}
$trace=$marker+'.trace'
if((Test-Path -LiteralPath $trace) -and (Get-Item -LiteralPath $trace).Length -gt 16384){throw 'Fixture trace bound reached.'}
[IO.File]::AppendAllText($trace,($record|ConvertTo-Json -Depth 6 -Compress)+[Environment]::NewLine)
[IO.File]::AppendAllText($marker,$utc.ToString('o')+[Environment]::NewLine)
'@
    $worker=$worker.Replace('__MARKER__',$Marker.Replace("'","''")).Replace('__TASK__',$TaskPath)
    [IO.File]::WriteAllText($ScriptPath,$worker,(New-Object Text.UTF8Encoding($false)))
    return $context
}
function Add-NativeRecurrenceClockSample($Context,$Task) {
    $qpc=[Diagnostics.Stopwatch]::GetTimestamp();$utc=[DateTime]::UtcNow
    $frequency=[Diagnostics.Stopwatch]::Frequency;$elapsed=$Context.Clock.Elapsed.TotalSeconds
    $drift=0.0
    if($Context.LastSample){
        $drift=($utc-$Context.LastSample.Time).TotalSeconds-($qpc-$Context.LastSample.Qpc)/[double]$frequency
    }
    if($Context.Samples.Count -lt 96 -and ($elapsed -ge $Context.NextSample -or [Math]::Abs($drift) -gt 0.5)){
        $Context.Samples.Add([pscustomobject]@{utc=$utc.ToString('o');qpc=$qpc;frequency=$frequency;elapsed=$elapsed;clockDifferenceSeconds=$drift;nextRunUtc=$Task.NextRunTime.ToUniversalTime().ToString('o');state=[int]$Task.State})
        $Context.NextSample=$elapsed+10
    }
    $Context.LastSample=[pscustomobject]@{Time=$utc;Qpc=$qpc}
}
function Read-NativeRecurrenceTrace($Context,$Task) {
    $observed=@();$projected=New-Object 'Collections.Generic.List[object]'
    $instanceMap=@{};$events=New-Object 'Collections.Generic.List[object]';$eventError=0
    $file=$Context.Marker+'.trace'
    if(Test-Path -LiteralPath $file){
        if((Get-Item -LiteralPath $file).Length -gt 32768){throw 'Fixture trace exceeds read bound.'}
        $observed=@([IO.File]::ReadAllLines($file)|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json})
        if($observed.Count -gt 16){throw 'Fixture trace has too many observations.'}
    }
    foreach($record in $observed){
        if($record.schema -ne 1 -or $record.qpc -le 0 -or $record.frequency -le 0 -or @($record.instances).Count -gt 4){throw 'Invalid fixture observation.'}
        $ids=@()
        foreach($instance in $record.instances){
            $id=([Guid]$instance.id).ToString('N')
            if(-not $instanceMap.ContainsKey($id)){$instanceMap[$id]=$instanceMap.Count+1}
            $ids+=@([int]$instanceMap[$id])
        }
        $projected.Add([pscustomobject]@{utc=[string]$record.utc;qpc=[int64]$record.qpc;frequency=[int64]$record.frequency;instances=$ids;exactTask=(@($record.instances|Where-Object {-not $_.matches}).Count -eq 0);error=[int]$record.error})
    }
    # Server-side query is restricted to the uniquely named test task. Never
    # export raw XML, event messages, usernames, paths or unrelated task events.
    $reader=$null
    try {
        $query=New-Object Diagnostics.Eventing.Reader.EventLogQuery('Microsoft-Windows-TaskScheduler/Operational',[Diagnostics.Eventing.Reader.PathType]::LogName,('*[EventData[Data[@Name="TaskName"]="'+$Context.TaskPath+'"]]'))
        $reader=New-Object Diagnostics.Eventing.Reader.EventLogReader($query)
        for($i=0;$i -lt 128;$i++){
            $event=$reader.ReadEvent([TimeSpan]::FromSeconds(2));if(-not $event){break}
            try {
                [xml]$xml=$event.ToXml();$data=@{}
                foreach($field in $xml.Event.EventData.Data){$data[[string]$field.Name]=[string]$field.'#text'}
                $instance=0
                foreach($key in @('InstanceId','TaskInstanceId')){
                    $id=[Guid]::Empty
                    if($data.ContainsKey($key) -and [Guid]::TryParse($data[$key],[ref]$id)){
                        $text=$id.ToString('N');if(-not $instanceMap.ContainsKey($text)){$instanceMap[$text]=$instanceMap.Count+1}
                        $instance=[int]$instanceMap[$text]
                    }
                }
                $pidMatch=$false
                foreach($key in @('ProcessID','ProcessId','EnginePID')){
                    $value=0
                    if($data.ContainsKey($key) -and [int]::TryParse($data[$key],[ref]$value)){
                        $pidMatch=$pidMatch -or (@($observed|Where-Object {$_.writer -eq $value -or $_.parent -eq $value}).Count -gt 0)
                    }
                }
                $events.Add([pscustomobject]@{eventId=[int]$event.Id;utc=$event.TimeCreated.ToUniversalTime().ToString('o');instance=$instance;matchesMarkerProcess=$pidMatch})
            } finally {$event.Dispose()}
        }
    } catch {$eventError=[int]$_.Exception.HResult}
    finally {if($reader){$reader.Dispose()}}
    $triggers=New-Object 'Collections.Generic.List[object]'
    $definition=$Task.Definition
    for($i=1;$i -le $definition.Triggers.Count;$i++){
        $t=$definition.Triggers.Item($i)
        $triggers.Add([pscustomobject]@{type=[int]$t.Type;enabled=[bool]$t.Enabled;interval=[string]$t.Repetition.Interval;duration=[string]$t.Repetition.Duration})
    }
    $qpcSeconds=-1.0;$utcSeconds=-1.0
    if($observed.Count -ge 2 -and $observed[0].frequency -eq $observed[1].frequency){
        $qpcSeconds=([int64]$observed[1].qpc-[int64]$observed[0].qpc)/[double]$observed[0].frequency
        $utcSeconds=([DateTime]::Parse($observed[1].utc)-[DateTime]::Parse($observed[0].utc)).TotalSeconds
    }
    return [pscustomobject]@{schema=1;source=$env:GITHUB_SHA;observations=@($projected.ToArray());qpcSeconds=$qpcSeconds;utcSeconds=$utcSeconds;clockDifferenceSeconds=($utcSeconds-$qpcSeconds);samples=@($Context.Samples.ToArray());events=@($events.ToArray());eventReadError=$eventError;triggers=@($triggers.ToArray());channelWasEnabled=[bool]$Context.WasEnabled;channelRestored=[bool]$Context.Restored}
}
function Close-NativeRecurrenceTrace($Context) {
    if($Context.Configuration){
        try {
            $Context.Configuration.IsEnabled=$Context.WasEnabled;$Context.Configuration.SaveChanges()
            $Context.Restored=($Context.Configuration.IsEnabled -eq $Context.WasEnabled)
        } finally {$Context.Configuration.Dispose();$Context.Configuration=$null}
    }
}
# A few log entries alone are not attribution. Require two distinct running
# instances, each tied to the real time trigger, task start and marker process.
function Test-NativeRecurrenceAttribution($Report) {
    if($Report.eventReadError -ne 0 -or @($Report.observations).Count -ne 2 -or
       [Math]::Abs($Report.clockDifferenceSeconds) -gt 2 -or
       @($Report.samples|Where-Object {[Math]::Abs($_.clockDifferenceSeconds) -gt 0.5}).Count -gt 0){return $false}
    $enabled=@($Report.triggers|Where-Object enabled)
    if(@($Report.triggers).Count -ne 4 -or $enabled.Count -ne 1 -or
       $enabled[0].type -ne 1 -or $enabled[0].interval -cne 'PT5M' -or $enabled[0].duration -cne ''){return $false}
    $ids=New-Object 'Collections.Generic.HashSet[int]'
    foreach($entry in $Report.observations){
        if($entry.error -ne 0 -or -not $entry.exactTask -or @($entry.instances).Count -ne 1){return $false}
        $id=[int]$entry.instances[0]
        if($id -lt 1 -or -not $ids.Add($id)){return $false}
        foreach($eventId in @(107,100,200)){
            $matches=@($Report.events|Where-Object {$_.eventId -eq $eventId -and $_.instance -eq $id})
            if($matches.Count -ne 1 -or ($eventId -eq 200 -and -not $matches[0].matchesMarkerProcess)){return $false}
        }
    }
    if(@($Report.events|Where-Object {$_.eventId -eq 107}).Count -ne 2 -or
       @($Report.events|Where-Object {$_.eventId -in @(108,109,110,114,117,118,119,120,121,122,123,124,125,322)}).Count -gt 0){return $false}
    return $true
}
