param(
    [string]$PackDirectory = ''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

if([string]::IsNullOrWhiteSpace($PackDirectory)){
    $PackDirectory=Split-Path -Parent $MyInvocation.MyCommand.Path
}
$PackDirectory=[IO.Path]::GetFullPath($PackDirectory)
$resultPath=Join-Path $PackDirectory 'FIELD-RESULT.json'
$cases=New-Object 'Collections.Generic.List[object]'
$passed=$false
$stage='preflight'

function Check([bool]$Value,[string]$Name){
    $script:stage=$Name
    $cases.Add([pscustomobject]@{name=$Name;passed=$Value})
    if(-not $Value){throw 'Field acceptance assertion failed.'}
    Write-Host ('PASS: '+$Name)
}

$probe=@'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TqrFieldProcessProbe
{
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint TOKEN_QUERY = 0x0008;

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_ELEVATION { public int TokenIsElevated; }

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint DesiredAccess, bool InheritHandle, int ProcessId);

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool GetTokenInformation(
        IntPtr TokenHandle,
        int TokenInformationClass,
        out TOKEN_ELEVATION TokenInformation,
        int TokenInformationLength,
        out int ReturnLength);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool QueryFullProcessImageName(IntPtr ProcessHandle, int Flags, StringBuilder ExeName, ref int Size);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool ProcessIdToSessionId(uint ProcessId, out uint SessionId);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr Handle);

    public static int ElevationState(int processId)
    {
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) return -1;
        try
        {
            IntPtr token;
            if (!OpenProcessToken(process, TOKEN_QUERY, out token)) return -1;
            try
            {
                TOKEN_ELEVATION elevation;
                int returned;
                int size = Marshal.SizeOf(typeof(TOKEN_ELEVATION));
                if (!GetTokenInformation(token, 20, out elevation, size, out returned) || returned < size)
                    return -1;
                return elevation.TokenIsElevated == 0 ? 0 : 1;
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }

    public static string ImagePath(int processId)
    {
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) return String.Empty;
        try
        {
            int length = 32768;
            StringBuilder value = new StringBuilder(length);
            return QueryFullProcessImageName(process, 0, value, ref length) ? value.ToString() : String.Empty;
        }
        finally { CloseHandle(process); }
    }

    public static int SessionId(int processId)
    {
        uint session;
        return ProcessIdToSessionId((uint)processId, out session) ? (int)session : -1;
    }
}
'@

try{
    Check ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'Windows desktop environment'
    $identityPath=Join-Path $PackDirectory 'FIELD-PACK-IDENTITY.json'
    Check (Test-Path -LiteralPath $identityPath -PathType Leaf) 'Field-pack identity is present'
    $identity=Get-Content -LiteralPath $identityPath -Raw|ConvertFrom-Json
    Check ($identity.schema -eq 2 -and [string]$identity.version -ceq '3.0.0-rc.12' -and
        [int64]$identity.versionCode -eq 30001012 -and $identity.publicRelease -is [bool] -and
        -not [bool]$identity.publicRelease) 'Field pack identifies private RC12'
    Check ([string]$identity.candidateSource -ceq '36bd301fdff27737c2a0e3ad2375ce277ffc955c' -and
        [int64]$identity.candidateArtifactId -eq 11107315062 -and
        [string]$identity.candidateSha256 -ceq 'ba6c7ee49c01668c79764ff4b986abcac38f21f1cd0699ee17c75df761d27a17' -and
        [string]$identity.setupSha256 -ceq 'f91f962387813765070af7892cf926dc3504778538a8535521a6cb03794cfac6') 'Field pack is bound to the migration-accepted RC12 bytes'

    $candidate=Join-Path $PackDirectory 'candidate'
    $setup=Join-Path $candidate 'TailscaleQuickRepair-SetupPackage-3.0.0-rc.12.zip'
    $installer=Join-Path $candidate 'TailscaleQuickRepair-Standalone-3.0.0-rc.12.exe'
    Check ((Test-Path -LiteralPath $setup -PathType Leaf) -and (Test-Path -LiteralPath $installer -PathType Leaf)) 'Accepted RC12 candidate files are present'
    Check ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$identity.setupSha256 -and
        (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$identity.candidateSha256) 'Accepted RC12 candidate hashes match'

    $appRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TailscaleQuickRepair'
    $installedExe=Join-Path $appRoot 'TailscaleQuickRepair.exe'
    $versionPath=Join-Path $appRoot 'version.user.json'
    $configPath=Join-Path $appRoot 'config.json'
    Check ((Test-Path -LiteralPath $installedExe -PathType Leaf) -and (Test-Path -LiteralPath $versionPath -PathType Leaf)) 'RC12 application files are installed'
    Check (Test-Path -LiteralPath $configPath -PathType Leaf) 'Existing Quick Repair configuration is still present'

    $version=Get-Content -LiteralPath $versionPath -Raw|ConvertFrom-Json
    Check ([string]$version.version -ceq '3.0.0-rc.12' -and [int64]$version.versionCode -eq 30001012) 'Installed version is RC12'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($setup)
    try{
        $manifestEntries=@($archive.Entries|Where-Object{$_.FullName -ceq 'package-manifest.json'})
        Check ($manifestEntries.Count -eq 1) 'RC12 package has one manifest'
        $reader=New-Object IO.StreamReader($manifestEntries[0].Open(),[Text.Encoding]::UTF8,$true)
        try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
        $exeEntries=@($manifest.files|Where-Object{[string]$_.path -ceq 'app/TailscaleQuickRepair.exe'})
        Check ($manifest.schema -eq 1 -and [string]$manifest.version -ceq '3.0.0-rc.12' -and $exeEntries.Count -eq 1) 'RC12 package manifest identifies the resident application'
        $installedHash=(Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()
        Check ($installedHash -ceq ([string]$exeEntries[0].sha256).ToLowerInvariant()) 'Installed resident application matches the accepted RC12 package'
    }finally{$archive.Dispose()}

    Add-Type -TypeDefinition $probe -Language CSharp
    Check ([TqrFieldProcessProbe]::ElevationState($PID) -eq 0) 'Verifier is running without elevation'
    $allProcesses=@([Diagnostics.Process]::GetProcessesByName('TailscaleQuickRepair'))
    $currentSession=[TqrFieldProcessProbe]::SessionId($PID)
    Check ($currentSession -ge 0) 'Current desktop session can be identified'
    $processes=@($allProcesses|Where-Object{[TqrFieldProcessProbe]::SessionId([int]$_.Id) -eq $currentSession})
    Check ($processes.Count -eq 1) 'Exactly one Quick Repair resident process is running in this desktop session'
    try{
        $pid=[int]$processes[0].Id
        $actualPath=[TqrFieldProcessProbe]::ImagePath($pid)
        Check (-not [string]::IsNullOrWhiteSpace($actualPath) -and
            [IO.Path]::GetFullPath($actualPath) -ieq [IO.Path]::GetFullPath($installedExe)) 'Resident process is running from the expected per-user install'
        $elevation=[TqrFieldProcessProbe]::ElevationState($pid)
        Check ($elevation -eq 0) 'Resident Quick Repair process is not elevated after Setup'
    }finally{
        foreach($process in $allProcesses){try{$process.Dispose()}catch{}}
    }

    $passed=$true
}
catch{
    Write-Host ('STOPPED: '+$stage) -ForegroundColor Yellow
}
finally{
    [pscustomobject]@{
        schema=1
        version='3.0.0-rc.12'
        passed=$passed
        checks=@($cases.ToArray())
        stoppedAt=if($passed){''}else{$stage}
        containsDeviceData=$false
        containsNetworkData=$false
    }|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $resultPath -Encoding UTF8
}

if($passed){
    Write-Host 'RC12 physical post-Setup verification passed.' -ForegroundColor Green
    exit 0
}
Write-Host 'RC12 physical post-Setup verification did not pass. FIELD-RESULT.json contains only check names and PASS/FAIL values.' -ForegroundColor Yellow
exit 1
