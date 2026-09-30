param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$version=Get-Content (Join-Path $repo 'version.json') -Raw|ConvertFrom-Json
$safeVersion=[string]$version.version -replace '[^A-Za-z0-9._-]','-'
$packages=@(Get-ChildItem -LiteralPath $OutputDirectory -Filter ('TailscaleQuickRepair-SetupPackage-'+$safeVersion+'.zip') -File)
if($packages.Count -ne 1){throw 'One exact Setup package is required.'}
$package=$packages[0]
$receipt=Get-Content -LiteralPath (Join-Path $OutputDirectory 'build-validation.json') -Raw|ConvertFrom-Json
if(-not $receipt.passed -or $receipt.source -cne $env:GITHUB_SHA){throw 'Matching build validation is required.'}
$work=Join-Path $env:TEMP ('TqrEmbeddedSetup-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
function Replace-Exactly([string]$Text,[string]$Before,[string]$After){
    if([regex]::Matches($Text,[regex]::Escape($Before)).Count -ne 1){throw 'Standalone Setup integration anchor is missing or ambiguous.'}
    return $Text.Replace($Before,$After)
}
try {
    $metadata=[ordered]@{schema=1;repository='coachedai/tailscale-repair-clean';repositoryId=1398720044;version=[string]$version.version;versionCode=[int64]$version.versionCode;sha256=(Get-FileHash $package.FullName -Algorithm SHA256).Hash.ToLowerInvariant();size=[int64]$package.Length;channel=[string]$version.channel}
    $metadataPath=Join-Path $work 'payload-metadata.json'
    [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
    $hostSource=[IO.File]::ReadAllText((Join-Path $repo 'src/native/PublicSetupHost.cs'))
    $hostSource=Replace-Exactly $hostSource '            bool upgradeOnly = HasSwitch(args, "--upgrade");' @'
            Tqr.EmbeddedSetupPackage embedded = Tqr.EmbeddedSetupPackage.Read();
            bool upgradeOnly = HasSwitch(args, "--upgrade") || (!repairOnly && embedded != null && Tqr.EmbeddedSetupPackage.HasExistingInstallation(GetAppDir()));
'@
    $hostSource=Replace-Exactly $hostSource '            long targetCode = ReadLongArg(args, "--target-code", 0);' @'
            long targetCode = ReadLongArg(args, "--target-code", 0);
            if (!repairOnly && embedded != null)
            {
                embedded.RequireTarget(targetCode);
                embedded.RefuseDowngrade(GetAppDir());
                channel = embedded.Channel;
                targetCode = embedded.VersionCode;
            }
'@
    $hostSource=Replace-Exactly $hostSource @'
            SetupManifest manifest = FetchSetupManifest(channel, targetCode);
            string zip = Path.Combine(work, "setup.zip");
            DownloadFile(manifest.Url, zip);
'@ @'
            Tqr.EmbeddedSetupPackage embedded = Tqr.EmbeddedSetupPackage.Read();
            string zip = Path.Combine(work, "setup.zip");
            SetupManifest manifest;
            if (embedded != null)
            {
                embedded.RequireTarget(targetCode);
                embedded.RefuseDowngrade(GetAppDir());
                manifest = new SetupManifest { Version = embedded.Version, VersionCode = embedded.VersionCode, Size = embedded.Size, Sha256 = embedded.Sha256 };
                embedded.CopyTo(zip);
            }
            else
            {
                manifest = FetchSetupManifest(channel, targetCode);
                DownloadFile(manifest.Url, zip);
            }
'@
    $hostSource=Replace-Exactly $hostSource @'
        int step = 0;

        WriteLocalConfig(peer);
'@ @'
        int step = 0;

        PreserveOrWriteConfig(peer, upgradeOnly);
'@
    $testMethod=@'
    private static void PreserveOrWriteConfig(string peer, bool upgradeOnly)
    {
        if (!upgradeOnly) { WriteLocalConfig(peer); return; }
        if (!String.Equals(ReadConfiguredPeer(), peer, StringComparison.Ordinal))
            throw new InvalidDataException("The existing target changed. Setup will not overwrite its configuration.");
    }

    internal static int VerifyEmbeddedPackage()
    {
        string root = Path.Combine(Path.GetTempPath(), "TqrBundleCheck-" + Guid.NewGuid().ToString("N"));
        try
        {
            Tqr.EmbeddedSetupPackage embedded = Tqr.EmbeddedSetupPackage.Read();
            if (embedded == null) return 31;
            Directory.CreateDirectory(root);
            string zip = Path.Combine(root, "package.zip");
            embedded.CopyTo(zip);
            string extracted = Path.Combine(root, "expanded");
            ZipFile.ExtractToDirectory(zip, extracted);
            PackageManifest package = ReadPackageManifest(extracted);
            if (package.VersionCode != embedded.VersionCode || package.Version != embedded.Version) return 32;
            VerifyPackage(extracted, package);
            return 0;
        }
        catch { return 33; }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

'@
    $hostSource=Replace-Exactly $hostSource '    private static int RunInstallerSelfTest()' ($testMethod+'    private static int RunInstallerSelfTest()')
    $entrySource=[IO.File]::ReadAllText((Join-Path $repo 'src/native/PublicSetupEntry.cs'))
    $entrySource=Replace-Exactly $entrySource '            if (HasSwitch(args, "--self-test-relocation-child"))' @'
            if (HasSwitch(args, "--verify-bundle"))
                return PublicSetupHost.VerifyEmbeddedPackage();
            if (HasSwitch(args, "--self-test-relocation-child"))
'@
    $hostPath=Join-Path $work 'PublicSetupHost.cs';$entryPath=Join-Path $work 'PublicSetupEntry.cs'
    [IO.File]::WriteAllText($hostPath,$hostSource,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($entryPath,$entrySource,(New-Object Text.UTF8Encoding($false)))
    & (Join-Path $PSScriptRoot 'privacy-scan.ps1') -Root $work -SkipRepositoryIdentity
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $framework=Split-Path $compiler -Parent
    $output=Join-Path $OutputDirectory ('TailscaleQuickRepair-Standalone-'+$safeVersion+'.exe')
    $arguments=@('/nologo','/target:winexe','/optimize+','/main:PublicSetupEntry',('/out:"'+$output+'"'),('/resource:"'+$package.FullName+'",Tqr.SetupPayload'),('/resource:"'+$metadataPath+'",Tqr.SetupMetadata'))
    foreach($reference in @('System.Web.Extensions.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll','System.Windows.Forms.dll','System.Drawing.dll')){$arguments+=('/reference:"'+(Join-Path $framework $reference)+'"')}
    foreach($source in @($hostPath,$entryPath,(Join-Path $repo 'src/native/OperationGate.cs'),(Join-Path $repo 'src/native/EmbeddedSetupPackage.cs'))){$arguments+=('"'+$source+'"')}
    $stdout=Join-Path $work 'compile.out';$stderr=Join-Path $work 'compile.err'
    $p=Start-Process -FilePath $compiler -ArgumentList ($arguments -join ' ') -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -Wait -PassThru
    if($p.ExitCode -ne 0){Get-Content $stdout,$stderr;throw 'Standalone Setup compilation failed.'}
    foreach($switch in @('--verify-bundle','--self-test-installer')){
        $test=Start-Process -FilePath $output -ArgumentList $switch -WindowStyle Hidden -PassThru
        if(-not $test.WaitForExit(45000)){try{$test.Kill()}catch{};throw 'Standalone Setup self-test timed out.'}
        if($test.ExitCode -ne 0){throw ('Standalone Setup self-test failed: '+$test.ExitCode)}
    }
    (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()|Set-Content -LiteralPath ($output+'.sha256') -Encoding ASCII
    Write-Host 'Standalone Setup payload, inner file integrity and native relocation checks passed. Migration acceptance is separate.'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
}
