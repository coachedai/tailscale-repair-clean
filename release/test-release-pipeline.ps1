param([string]$EvidenceDirectory='.\test-evidence')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflow=Get-Content -LiteralPath (Join-Path $repo '.github\workflows\release.yml') -Raw -Encoding UTF8
$cases=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Value,[string]$Name){
    if(-not $Value){throw "FAILED release pipeline: $Name"}
    $cases.Add([pscustomobject]@{name=$Name;passed=$true})
    Write-Host "PASS release pipeline: $Name"
}
function Count([string]$Needle){return ([regex]::Matches($workflow,[regex]::Escape($Needle))).Count}
try{
    Check ((Count '  release_compatibility:') -eq 1) 'One clean-runner release compatibility job'
    Check ([regex]::IsMatch($workflow,"(?m)^  release_compatibility:\r?\n    name: Release compatibility\r?\n    if: github\.ref == 'refs/heads/main'$")) 'Compatibility job is main-only'
    foreach($name in @(
        'Update channel trust and preference gates',
        'Real installed Windows service and recurrence gates',
        'Require independent clock and exact trigger attribution',
        'Ordinary-user protected file and task gates',
        'Protected migration and evidence-preserving refusal gates',
        'Upgrade genuine released 5.2.1 files and tasks',
        'Recover files after killed Setup and killed recovery',
        'Verify the published 5.2.1 protected-update handoff'
    )){
        Check ((Count $name) -eq 1) ("Required release gate remains: "+$name)
    }
    Check ((Count 'TQR_RELEASE_VALIDATION: ${{ github.run_id }}') -eq 6) 'Every destructive release-only test receives the stamped run ID'
    Check ($workflow.Contains('name: quick-repair-${{ needs.validate.outputs.safe_version }}') -and
           $workflow.Contains('name: runtime-evidence-${{ needs.validate.outputs.safe_version }}')) 'Compatibility consumes exact native-tested package and evidence artifacts'
    Check ($workflow.Contains('needs: [validate, release_compatibility]') -and
           $workflow.Contains("needs.release_compatibility.result == 'success'")) 'Publication is blocked on clean-runner compatibility'
    Check ($workflow.Contains('Main changed after validation; do not publish an outdated build.') -and
           $workflow.Contains('Main changed during publication; keep the previous update channel.')) 'Publication refuses a moving main branch'
    Check ($workflow.Contains('git push origin HEAD:refs/heads/main') -and -not $workflow.Contains('git push --force')) 'Manifest publication remains non-force only'
    $privacyScan=Join-Path $repo 'release\privacy-scan.ps1'
    $privacyLab=Join-Path $env:TEMP ('TqrPrivacyPipeline-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $privacyLab|Out-Null
    try{
        [IO.File]::WriteAllBytes((Join-Path $privacyLab 'synthetic-screen.png'),[byte[]](1,2,3,4))
        [IO.File]::WriteAllBytes((Join-Path $privacyLab 'opaque-evidence.bin'),[byte[]](5,6,7,8))
        [IO.File]::WriteAllBytes((Join-Path $privacyLab 'evidence.zip'),[byte[]](9,10,11,12))
        $blocked=$false
        try{& $privacyScan -Root $privacyLab -SkipRepositoryIdentity}catch{$blocked=$true}
        Check $blocked 'Privacy scanner rejects synthetic screenshot, archive and opaque binary evidence'
        Remove-Item -LiteralPath $privacyLab -Recurse -Force
        New-Item -ItemType Directory -Path $privacyLab|Out-Null
        $slash=[char]92
        $encodedAddress='192'+$slash+'.0'+$slash+'.2'+$slash+'.45'
        Set-Content -LiteralPath (Join-Path $privacyLab 'encoded-address-fixture.ps1') -Value $encodedAddress -Encoding ASCII
        $encodedBlocked=$false
        try{& $privacyScan -Root $privacyLab -SkipRepositoryIdentity}catch{$encodedBlocked=$true}
        Check $encodedBlocked 'Privacy scanner rejects escaped literal network addresses'
        Remove-Item -LiteralPath $privacyLab -Recurse -Force
        New-Item -ItemType Directory -Path $privacyLab|Out-Null
        [IO.File]::WriteAllBytes((Join-Path $privacyLab 'fixture.exe'),[byte[]](1,2,3,4))
        [IO.File]::WriteAllBytes((Join-Path $privacyLab 'fixture.dll'),[byte[]](5,6,7,8))
        Set-Content -LiteralPath (Join-Path $privacyLab 'fixture.txt') -Value 'synthetic package fixture' -Encoding ASCII
        & $privacyScan -Root $privacyLab -SkipRepositoryIdentity
        Check $true 'Privacy scanner still permits expected expanded native package binaries and safe text'
    }finally{
        Remove-Item -LiteralPath $privacyLab -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach($path in @(
        'release\test-native-windows.ps1',
        'release\test-native-permissions.ps1',
        'release\test-protected-migration.ps1',
        'release\test-released-upgrade.ps1',
        'release\test-protected-update-handoff.ps1',
        'release\protected-handoff-child.ps1',
        'release\test-interrupted-setup-recovery.ps1',
        'release\interrupted-setup-child.ps1'
    )){
        $scriptText=Get-Content -LiteralPath (Join-Path $repo $path) -Raw -Encoding UTF8
        Check ($scriptText.Contains('$releaseValidation=') -and $scriptText.Contains('$env:TQR_RELEASE_VALIDATION -ceq $env:GITHUB_RUN_ID')) ((Split-Path $path -Leaf)+' retains the stamped release guard')
    }
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
    [pscustomobject]@{passed=$true;scope='Release workflow exact-artifact and guarded-main contract';cases=@($cases.ToArray())}|ConvertTo-Json -Depth 7|Set-Content (Join-Path $EvidenceDirectory 'release-pipeline-results.json') -Encoding UTF8
}catch{
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null
    [pscustomobject]@{passed=$false;failureType=$_.Exception.GetType().FullName;cases=@($cases.ToArray())}|ConvertTo-Json -Depth 7|Set-Content (Join-Path $EvidenceDirectory 'release-pipeline-results.json') -Encoding UTF8
    throw
}
