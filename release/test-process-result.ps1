# Run only the actual verifier statement and exit-code guard, not the native
# process driver. The synthetic interpreter below never executes a process.
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){
    throw 'Windows PowerShell 5.1 required for result-stream acceptance.'
}
$source=Join-Path $PSScriptRoot 'test-process-file-recovery.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Result driver syntax failed.'}
$functions=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-PinnedProcessFileRecovery'
},$true))
if($functions.Count -ne 1){throw 'Result driver function is ambiguous.'}
$statements=@($functions[0].Body.EndBlock.Statements)
$indexes=@(for($i=0;$i -lt $statements.Count;$i++){
    if($statements[$i].Extent.Text.Contains('prepare-clean-upgrade.py')){$i}
})
if($indexes.Count -ne 1){throw 'Verifier statement is ambiguous.'}
$index=[int]$indexes[0]
$statement=$statements[$index]
if($statement -isnot [Management.Automation.Language.AssignmentStatementAst] -or
   $statement.Left.Extent.Text -cne '$null' -or $index+1 -ge $statements.Count){
    throw 'Verifier output must not become a recovery result.'
}
$guard=$statements[$index+1]
if($guard -isnot [Management.Automation.Language.IfStatementAst] -or
   -not $guard.Extent.Text.Contains('$LASTEXITCODE -ne 0')){
    throw 'Verifier failure must retain its exit-code guard.'
}
# Parse only the two extracted statements with their original file identity.
# This keeps script-relative resolution without invoking the full driver.
$probeText=$statement.Extent.Text+"`n"+$guard.Extent.Text+"`nreturn 11"
$probeTokens=$null;$probeErrors=$null
$probeAst=[Management.Automation.Language.Parser]::ParseInput($probeText,$source,[ref]$probeTokens,[ref]$probeErrors)
if(@($probeErrors).Count){throw 'Isolated verifier syntax failed.'}
$probe=$probeAst.GetScriptBlock()
if($probe.File -cne $source){throw 'Isolated verifier lost its source context.'}
$InputDirectory='synthetic-inputs'
$script:fixtureExit=0
$script:fixtureCalls=0
$script:fixtureVerifier=Join-Path $PSScriptRoot 'prepare-clean-upgrade.py'
function python {
    if(@($args).Count -ne 4 -or $args[0] -cne '-B' -or
       $args[1] -cne $script:fixtureVerifier -or $args[2] -cne 'verify' -or
       $args[3] -cne 'synthetic-inputs'){throw 'Synthetic verifier arguments changed.'}
    $script:fixtureCalls++
    $global:LASTEXITCODE=$script:fixtureExit
    Write-Output 'Synthetic verification status.'
    Write-Output 'Second synthetic status line.'
}
if((Get-Command python).CommandType -ne [Management.Automation.CommandTypes]::Function){
    throw 'Only the synthetic interpreter may run.'
}
$savedExit=Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$hadExit=$null -ne $savedExit
$oldExit=if($hadExit){$savedExit.Value}else{$null}
try{
    $result=& $probe
    if($result -isnot [int] -or $result -ne 11 -or $script:fixtureCalls -ne 1){
        throw 'Verifier status contaminated the scalar result.'
    }
    foreach($code in @(1,90)){
        $script:fixtureExit=$code
        $refused=$false
        try{[void](& $probe)}catch{$refused=$true}
        if(-not $refused){throw 'Failed verification produced a success result.'}
    }
    if($script:fixtureCalls -ne 3){throw 'Result probes did not exercise each verification outcome.'}
}finally{
    if($hadExit){$global:LASTEXITCODE=$oldExit}else{Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue}
}
Write-Host 'Process recovery scalar output and failure propagation checks passed.'
