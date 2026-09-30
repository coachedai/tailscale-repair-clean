param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$SkipRepositoryIdentity
)

$ErrorActionPreference = 'Stop'
$ExpectedRepository = 'coachedai/tailscale-repair-clean'
$rootPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)

function Add-Finding {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path,
        [string]$Reason
    )

    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path))
        $pathId = ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
        $List.Add("file-sha256=$pathId :: $Reason")
    } finally { $hasher.Dispose() }
}

$findings = New-Object 'System.Collections.Generic.List[string]'

if (-not $SkipRepositoryIdentity) {
    if (
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY) -and
        $env:GITHUB_REPOSITORY -ne $ExpectedRepository
    ) {
        throw 'Repository isolation check failed; unexpected repository.'
    }

    try {
        $origin = (& git -C $rootPath remote get-url origin 2>$null | Select-Object -First 1).Trim()

        if (
            $origin -and
            $origin -notmatch '(?i)(github\.com[:/])coachedai/tailscale-repair-clean(?:\.git)?$'
        ) {
            throw 'Repository isolation check failed; unexpected origin.'
        }
    }
    catch {
        if ($env:GITHUB_ACTIONS -eq 'true') {
            throw
        }
    }
}

$tracked = @()

if (
    -not $SkipRepositoryIdentity -and
    (Test-Path -LiteralPath (Join-Path $rootPath '.git'))
) {
    $tracked = @(& git -C $rootPath ls-files)
}
else {
    $tracked = @(
        Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force |
            Where-Object {
                $_.FullName -notmatch '[\\/]\.git[\\/]' -and
                $_.FullName -notmatch '[\\/]dist[\\/]'
            } |
            ForEach-Object {
                $_.FullName.Substring($rootPath.Length).TrimStart('\','/') -replace '\\','/'
            }
    )
}

# Construct the other-project token dynamically so the scanner does not match itself.
$otherProjectToken = ('coach' + 'intake')

$forbiddenFileNames = @(
    '.env',
    '.env.local',
    'config.json',
    'secrets.json',
    'credentials.json',
    'id_rsa',
    'id_ed25519'
)

$textExtensions = @(
    '.ps1', '.psm1', '.psd1',
    '.cs', '.vbs', '.py',
    '.json', '.yml', '.yaml',
    '.md', '.txt',
    '.xml', '.config', '.ini', '.cfg', '.conf', '.toml', '.properties', '.csv'
)

$textLeafNames = @(
    '.gitignore',
    '.gitattributes'
)

# Real-machine evidence and opaque containers are forbidden from public
# source and release payloads. Do not add user-specific deny-list values here:
# the policy must remain generic and must never contain private identifiers.
$forbiddenEvidenceExtensions = @(
    '.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif', '.tif', '.tiff',
    '.mp4', '.mov', '.webm', '.avi',
    '.log', '.dmp', '.mdmp', '.evtx', '.etl', '.reg',
    '.pcap', '.pcapng', '.har',
    '.zip', '.7z', '.rar', '.tar', '.gz', '.tgz',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.db', '.sqlite', '.sqlite3', '.bak'
)

# Expanded release payloads legitimately contain the compiled native hosts.
# Public repository source itself is text-only.
$allowedExpandedBinaryExtensions = @('.exe', '.dll')

$secretPatterns = @(
    @{ Name = 'GitHub token'; Pattern = '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b' },
    @{ Name = 'GitHub fine-grained token'; Pattern = '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b' },
    @{ Name = 'Tailscale auth key'; Pattern = '(?i)\btskey-[A-Za-z0-9-]{10,}\b' },
    @{ Name = 'AWS access key'; Pattern = '\bAKIA[0-9A-Z]{16}\b' },
    @{ Name = 'Private key'; Pattern = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' },
    @{ Name = 'Generic API secret'; Pattern = '(?i)\bsk-[A-Za-z0-9_-]{20,}\b' }
)

$windowsUserPathPattern = '(?i)\b[A-Z]:\\Users\\([^\\\r\n]+)'
$deviceNamePattern = '(?i)\bvmi\d{5,}\b'
$emailPattern = '(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b'
$ipv4Pattern = '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])'
$escapedIpv4Pattern = '(?<!\d)(?:\d{1,3}\\\.){3}\d{1,3}(?!\d)'
$bracketIpv4Pattern = '(?<!\d)(?:\d{1,3}\[\.\]){3}\d{1,3}(?!\d)'

$internalProvenanceHashes = @(
    '60965168ce762e949600281ba6d01fee136e5b6e8257b1f216f9025ed324474c',
    '7d3194f79e645c42e4396dda38be04766810ec6a00d00aced3ffc2a0a1f1a9ef',
    '57de4cf40144bdf7d00010f2f5557a7d642c2b9705309bfade167dd313e2ca93',
    '487b91042c7cf27a19e23ea8699f5f354b1a0c3af9e418138dc6150d830f970d',
    '053ea4804ef1bb33d4a3d6fb024a614b6d257cebc2bc7cd915da9c9522f37ffc'
)
$internalPathHashes = @(
    'cf07194ee232eb531e15f690000d19846dea69cf05504782658afcfacb9228a2',
    'eb7526362ee7678cb5650f67d90cfdb84485363ca148ff3993ded032560941fb',
    '8b34dbc2c05eb4d7e25d48efeace82456b16cee760bcae80c157f52a3c2e787b',
    '5c0dc939187d4ae4bdb6abd314825f9f524c45c140b6e929ab93708e94b4f25f',
    '54e6289e14c7b0e7ad9acc2dfc4c1e3d027d0eef7f5c4c3fe7c292761d0e06a6',
    'd27247eba6ef434b6145732315d2e88de96ac8c12ca95ca51277e96dfd69649c',
    '5417dcf3515cce99d317b6d1e22915f647f195e0f1cd9578534cf18a6d353895'
)

function Get-WordHash {
    param([string]$Value)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        return ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally {
        $hasher.Dispose()
    }
}

foreach ($relative in $tracked) {
    if ([string]::IsNullOrWhiteSpace($relative)) { continue }

    $relativeNormalized = $relative -replace '\\','/'
    $leaf = [IO.Path]::GetFileName($relativeNormalized)

    foreach($word in [regex]::Matches($relativeNormalized.ToLowerInvariant(),'[a-z][a-z0-9]{2,}')){
        if($internalPathHashes -contains (Get-WordHash $word.Value)){
            Add-Finding $findings $relativeNormalized 'Internal development artifact path is forbidden from public source.'
            break
        }
    }

    if ($relativeNormalized -match '(?i)(^|/)' + [regex]::Escape($otherProjectToken) + '(/|$)') {
        Add-Finding $findings $relativeNormalized 'Cross-project path detected. This repository must stay isolated.'
    }

    if (
        $forbiddenFileNames -contains $leaf -or
        $leaf -match '(?i)\.(pem|pfx|p12|key)$'
    ) {
        Add-Finding $findings $relativeNormalized 'Sensitive/local configuration file must not be tracked.'
    }

    $extension = [IO.Path]::GetExtension($leaf).ToLowerInvariant()

    if ($forbiddenEvidenceExtensions -contains $extension) {
        Add-Finding $findings $relativeNormalized 'Real-machine evidence, opaque archive, or document file type is forbidden.'
        continue
    }

    if (
        -not ($textExtensions -contains $extension) -and
        -not ($textLeafNames -contains $leaf)
    ) {
        if ($SkipRepositoryIdentity -and $allowedExpandedBinaryExtensions -contains $extension) {
            continue
        }

        Add-Finding $findings $relativeNormalized 'Unreviewed non-text/binary file type is forbidden by the public-repository privacy policy.'
        continue
    }

    $fullPath = [IO.Path]::GetFullPath((Join-Path $rootPath $relativeNormalized))

    if (-not $fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        Add-Finding $findings $relativeNormalized 'Path escapes repository root.'
        continue
    }

    if (-not (Test-Path -LiteralPath $fullPath)) { continue }

    $file = Get-Item -LiteralPath $fullPath

    if ($file.Length -gt 5MB) {
        Add-Finding $findings $relativeNormalized 'Unexpected text file larger than 5 MB.'
        continue
    }

    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop

    if ($content.IndexOf($otherProjectToken, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Add-Finding $findings $relativeNormalized 'Cross-project content detected.'
    }

    foreach($word in [regex]::Matches($content.ToLowerInvariant(),'[a-z][a-z0-9]{2,}')){
        if($internalProvenanceHashes -contains (Get-WordHash $word.Value)){
            Add-Finding $findings $relativeNormalized 'Internal development provenance marker detected.'
            break
        }
    }

    foreach ($pattern in $secretPatterns) {
        if ($content -match $pattern.Pattern) {
            Add-Finding $findings $relativeNormalized $pattern.Name
        }
    }

    foreach ($match in [regex]::Matches($content, $windowsUserPathPattern)) {
        $userSegment = $match.Groups[1].Value

        if ($userSegment -notin @('Public', '<user>', 'USERNAME', '$env:USERNAME')) {
            Add-Finding $findings $relativeNormalized 'Personal Windows user-profile path detected.'
        }
    }

    if ($content -match $deviceNamePattern) {
        Add-Finding $findings $relativeNormalized 'Machine-specific VPS/device name detected.'
    }

    foreach ($match in [regex]::Matches($content, $emailPattern)) {
        $email = $match.Value

        if (
            $email -notmatch '(?i)@users\.noreply\.github\.com$' -and
            $email -cne 'noreply@github.com'
        ) {
            Add-Finding $findings $relativeNormalized 'Email address detected; value withheld.'
        }
    }

    foreach ($match in [regex]::Matches($content, $ipv4Pattern)) {
        $value = $match.Value

        # Protocol/version literals only. Real network addresses are blocked.
        if ($value -in @('0.0.0.0', '127.0.0.1', '2.0.0.0', '3.0.0.0')) {
            continue
        }

        # AssemblyVersion / AssemblyFileVersion are four-part numeric version
        # literals, not network addresses. Ignore them only when the matched
        # value appears on that exact assembly attribute line.
        $lineStart = $content.LastIndexOf("`n", [Math]::Max(0, $match.Index - 1))
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }

        $lineEnd = $content.IndexOf("`n", $match.Index)
        if ($lineEnd -lt 0) { $lineEnd = $content.Length }

        $line = $content.Substring($lineStart, $lineEnd - $lineStart).Trim()

        if (
            $line -match '(?i)^\[assembly:\s*System\.Reflection\.Assembly(?:File)?Version\s*\(' -and
            $line -match [regex]::Escape($value)
        ) {
            continue
        }

        $octets = @($value.Split('.') | ForEach-Object { [int]$_ })

        if ($octets.Count -ne 4 -or ($octets | Where-Object { $_ -gt 255 }).Count -gt 0) {
            continue
        }

        Add-Finding $findings $relativeNormalized 'Literal IPv4 address detected; value withheld.'
    }

    foreach ($match in [regex]::Matches($content, $escapedIpv4Pattern)) {
        $value = $match.Value -replace '\\\.', '.'
        $octets = @($value.Split('.') | ForEach-Object { [int]$_ })
        if (
            $value -notin @('0.0.0.0', '127.0.0.1', '2.0.0.0', '3.0.0.0') -and
            $octets.Count -eq 4 -and
            ($octets | Where-Object { $_ -gt 255 }).Count -eq 0
        ) {
            Add-Finding $findings $relativeNormalized 'Escaped literal IPv4 address detected.'
        }
    }

    foreach ($match in [regex]::Matches($content, $bracketIpv4Pattern)) {
        $value = $match.Value.Replace('[.]','.')
        $octets = @($value.Split('.') | ForEach-Object { [int]$_ })
        if (
            $value -notin @('0.0.0.0', '127.0.0.1', '2.0.0.0', '3.0.0.0') -and
            $octets.Count -eq 4 -and
            ($octets | Where-Object { $_ -gt 255 }).Count -eq 0
        ) {
            Add-Finding $findings $relativeNormalized 'Bracket-encoded literal IPv4 address detected.'
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host ''
    Write-Host 'PRIVACY / PROJECT ISOLATION CHECK FAILED' -ForegroundColor Red

    foreach ($finding in $findings) {
        Write-Host " - $finding" -ForegroundColor Red
    }

    Write-Host ''
    throw "Blocked $($findings.Count) potentially sensitive or cross-project item(s)."
}

Write-Host "Privacy and project-isolation scan passed ($($tracked.Count) files checked)." -ForegroundColor Green
