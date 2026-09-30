param([string]$EvidenceDirectory='.\test-evidence')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflow=Get-Content -LiteralPath (Join-Path $repo '.github\workflows\auto-repair-development.yml') -Raw -Encoding UTF8
$config=Get-Content -LiteralPath (Join-Path $repo 'release\preview-publish.json') -Raw|ConvertFrom-Json
$cases=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Value,[string]$Name){
    if(-not $Value){throw "FAILED preview pipeline: $Name"}
    $cases.Add([pscustomobject]@{name=$Name;passed=$true})
    Write-Host "PASS preview pipeline: $Name"
}
function Count([string]$Needle){return ([regex]::Matches($workflow,[regex]::Escape($Needle))).Count}
try{
    Check ([int]$config.schema -eq 1 -and $config.publish -is [bool] -and $config.prerelease -is [bool] -and [bool]$config.prerelease) 'Preview publication intent has the fixed guarded schema'
    Check ((Count '  preview-publish:') -eq 1) 'Exactly one Preview publisher job exists'
    Check ($workflow.Contains('needs: [verify, released-upgrade, history-privacy]') -and
           $workflow.Contains("needs.verify.outputs.preview_publish == 'true'") -and
           $workflow.Contains("needs.released-upgrade.result == 'success'") -and
           $workflow.Contains("needs.history-privacy.result == 'success'")) 'Preview publication is blocked on exact Windows jobs and zero-finding history acceptance'
    Check ($workflow.Contains('test-git-history-audit.py') -and $workflow.Contains('Require zero history privacy findings')) 'Same-workflow history acceptance runs audited synthetic tests and the actual full-history scan'
    Check ((Count 'test-source-syntax.ps1') -eq 2) 'Native source parsing runs before build and before upgrade fixture mutation'
    Check ($workflow.Contains("if: always() && steps.source_privacy.outcome == 'success'")) 'A rejected source snapshot is not reuploaded as evidence'
    Check ($workflow.Contains('Validate published RC1 to current Early-access candidate') -and
           $workflow.Contains('test-preview-upgrade.ps1')) 'Preview publication is gated by the normal published-RC1 to current-candidate upgrade path'
    Check (-not $workflow.Contains('Assemble current candidate field pack') -and
           -not $workflow.Contains('name: development-field-preview')) 'Current RC candidates are not distributed through the retired developer field-pack path'
    Check ((Count 'contents: write') -eq 1) 'Only one development job receives contents write permission'
    Check ($workflow.Contains('name: auto-repair-regression-packages') -and
           $workflow.Contains('Preview publisher reuses the exact validated package artifact')) 'Preview publisher consumes the exact upstream-tested product artifact'
    $jobStartForAssets=$workflow.IndexOf('  preview-publish:',[StringComparison]::Ordinal)
    if($jobStartForAssets -lt 0){throw 'Preview publisher job boundary missing.'}
    $assetJob=$workflow.Substring($jobStartForAssets)
    Check ($assetJob.Contains('TailscaleQuickRepair-SetupPackage-$v.zip') -and
           $assetJob.Contains('TailscaleQuickRepair-$v.zip') -and
           -not $assetJob.Contains('TailscaleQuickRepair-Bootstrap-$v.exe') -and
           -not $assetJob.Contains('TailscaleQuickRepair-Setup-$v.exe')) 'Preview prerelease exposes only in-app package ZIPs and their sidecars'
    Check ($workflow.Contains('--prerelease') -and
           $workflow.Contains("'^3\.0\.0-rc\.[1-9][0-9]*$'")) 'Preview publisher only creates explicit 3.0 RC GitHub prereleases'
    Check ($workflow.Contains('refs/heads/preview') -and
           $workflow.Contains('updates/preview.json')) 'Preview publisher writes only the dedicated Preview update manifest'
    Check ($workflow.Contains('refs/heads/work/3.0') -and
           $workflow.Contains('Disarm Preview publication')) 'Successful publication disarms the developer intent with a non-force branch commit'
    $jobStart=$workflow.IndexOf('  preview-publish:',[StringComparison]::Ordinal)
    if($jobStart -lt 0){throw 'Preview publisher job boundary missing.'}
    $job=$workflow.Substring($jobStart)
    Check (-not $job.Contains('refs/heads/main') -and -not $job.Contains('updates/latest.json')) 'Preview publisher has no Stable branch or Stable-manifest write path'
    Check (-not $job.Contains('git push --force') -and -not $job.Contains('git push -f ')) 'Preview publication and disarm pushes are non-force only'
    Check ($job.Contains('Branch moved before Preview publication') -and
           $job.Contains('Branch moved before Preview disarm')) 'Preview publisher refuses a moving development branch before irreversible steps'
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
    [pscustomobject]@{passed=$true;scope='Guarded Early-access prerelease publication; Stable main/latest.json excluded';cases=@($cases.ToArray())}|ConvertTo-Json -Depth 7|Set-Content (Join-Path $EvidenceDirectory 'preview-pipeline-results.json') -Encoding UTF8
}catch{
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
    [pscustomobject]@{passed=$false;failureType=$_.Exception.GetType().FullName;cases=@($cases.ToArray())}|ConvertTo-Json -Depth 7|Set-Content (Join-Path $EvidenceDirectory 'preview-pipeline-results.json') -Encoding UTF8
    throw
}
