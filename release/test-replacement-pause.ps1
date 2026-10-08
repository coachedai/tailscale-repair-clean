# Synthetic prerequisite for deterministic standalone interruption testing.
# This probe never starts an installer or opens an installed product file.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'coachedai/tailscale-repair-clean' -or
   $env:GITHUB_REPOSITORY_ID -cne '1398720044' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
   $env:GITHUB_REF_NAME -notin @('main','work/public') -or
   [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -or
   $env:TQR_NATIVE_LAB_RUN -cne $env:GITHUB_RUN_ID -or
   $PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){
    throw 'Owned hosted file-pause probe required.'
}
$null=& python -B (Join-Path $PSScriptRoot 'check-repository.py') --ci
if($LASTEXITCODE -ne 0){throw 'File-pause source boundary refused.'}
$null=& python -B (Join-Path $PSScriptRoot 'test-replacement-pause.py')
if($LASTEXITCODE -ne 0){throw 'File-pause contracts failed.'}
function Require-ProbePath([string]$Path){
    $part=[IO.Path]::GetFullPath($Path)
    while($part){
        if(Test-Path -LiteralPath $part){
            if((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked probe path refused.'}
        }
        $parent=[IO.Path]::GetDirectoryName($part);if($parent -eq $part){break};$part=$parent
    }
}
if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){throw 'Runner temporary storage required.'}
$temporary=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
Require-ProbePath $temporary
$probeRoot=Join-Path $temporary ('TqrReplacementProbe-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $probeRoot){throw 'Existing file-pause fixture refused.'}
$source=Join-Path $PSScriptRoot 'ReplacementPause.cs'
Require-ProbePath $source
$probePassed=$false
[void][IO.Directory]::CreateDirectory($probeRoot)
try{
    Add-Type -Path $source -ErrorAction Stop
    $checks=[Tqr.Acceptance.ReplacementPauseProbe]::Run($probeRoot)
    if($checks -isnot [int] -or $checks -ne 10){throw 'Incomplete native file-pause evidence.'}
    $probePassed=$true
}finally{
    if($probePassed){
        Require-ProbePath $probeRoot
        $expected=@('target.dat','readback.dat')
        $items=@(Get-ChildItem -LiteralPath $probeRoot -Force)
        if($items.Count -ne 2){throw 'Unexpected file-pause fixture contents.'}
        foreach($item in $items){
            if($item.PSIsContainer -or $item.Name -cnotin $expected -or
               ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Probe cleanup boundary refused.'}
        }
        [IO.Directory]::Delete($probeRoot,$true)
    }
}
Write-Host 'Native synthetic replacement pause passed: 10 checks. Standalone termination remains separate.'
