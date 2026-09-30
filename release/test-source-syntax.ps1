param(
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [string]$EvidenceDirectory = '.\test-evidence'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Source syntax acceptance requires native Windows PowerShell 5.1.'
}
$rootPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
$prefix = $rootPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$utf8 = New-Object Text.UTF8Encoding($false,$true)
$results = New-Object 'Collections.Generic.List[object]'
$files = New-Object 'Collections.Generic.List[object]'
$passed = $false
try {
    foreach ($part in @('src','release')) {
        $directory = Join-Path $rootPath $part
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw 'Required source directory is missing.'
        }
        if (((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Redirected source directory is refused.'
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force)) {
            if ($file.Extension -in @('.ps1','.psm1','.psd1')) { $files.Add($file) }
        }
    }
    if ($files.Count -eq 0) { throw 'No PowerShell source files were found.' }
    foreach ($file in $files) {
        if (-not $file.FullName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Source file is outside the validation root.'
        }
        $relative = $file.FullName.Substring($prefix.Length).Replace('\','/')
        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $fileId = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($relative))).Replace('-','').ToLowerInvariant()
        } finally { $hasher.Dispose() }
        $reason = ''
        $errorCount = 0
        try {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -gt 5MB) {
                throw 'Unsafe source type or size.'
            }
            $source = [IO.File]::ReadAllText($file.FullName,$utf8)
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
            $errorCount = @($errors).Count
            if ($errorCount -gt 0) { $reason = 'parse_error' }
        } catch { $reason = 'source_read_failed'; $errorCount = 1 }
        $results.Add([pscustomobject]@{fileSha256=$fileId;passed=($reason -eq '');reason=$reason;errorCount=$errorCount})
    }
    $passed = @($results | Where-Object { -not $_.passed }).Count -eq 0
} finally {
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    [pscustomobject]@{
        schema=1
        passed=$passed
        source=$env:GITHUB_SHA
        checked=$results.Count
        cases=@($results.ToArray())
        scope='Native PowerShell parser only. No source script is executed; no matched text or local paths are reported.'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'source-syntax-results.json') -Encoding UTF8
}
if (-not $passed) { throw 'Source syntax acceptance failed; inspect hashed result codes.' }
Write-Host ('Native PowerShell source syntax passed: '+$results.Count+' files.')
