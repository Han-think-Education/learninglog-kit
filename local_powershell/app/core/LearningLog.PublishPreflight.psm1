Set-StrictMode -Version Latest

function Test-LLPreflightReparsePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        if ($item.FullName.TrimEnd('\', '/') -ieq $rootFull) { break }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
    return $false
}

function Invoke-LLPublishPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ReadyRoot,
        [string]$ExpectedSha256 = '',
        [string]$RegistryStatus = '',
        [string]$PublicPolicy = '',
        [string]$SourceCategory = '',
        [Parameter(Mandatory)][AllowEmptyString()][string]$OriginalContent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$DraftAssetRoot = '',
        [switch]$AllowPublished,
        [long]$MaxMarkdownBytes = 3145728,
        [long]$MaxImageBytes = 26214400
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $addFinding = {
        param([string]$Code, [ValidateSet('WARN', 'FAIL')][string]$Severity)
        $findings.Add([pscustomobject]@{ code = $Code; severity = $Severity })
    }

    $fullPath = ''
    $rootFull = ''
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $rootFull = [IO.Path]::GetFullPath($ReadyRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    } catch {
        & $addFinding 'invalid_path' 'FAIL'
    }

    if ($fullPath -and $rootFull) {
        if (-not $fullPath.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            & $addFinding 'outside_approved_root' 'FAIL'
        } elseif (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            & $addFinding 'source_missing' 'FAIL'
        } else {
            $relative = $fullPath.Substring($rootFull.Length).Replace('\', '/')
            if ($relative -notmatch '^[^/]+/[^/]+\.md$') { & $addFinding 'invalid_ready_layout' 'FAIL' }
            if ([IO.Path]::GetExtension($fullPath) -ine '.md') { & $addFinding 'unsupported_source_type' 'FAIL' }
            try {
                if (Test-LLPreflightReparsePath -Path $fullPath -Root $rootFull) { & $addFinding 'linked_source_path' 'FAIL' }
            } catch {
                & $addFinding 'source_path_unverifiable' 'FAIL'
            }
            if ($ExpectedSha256) {
                if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                    & $addFinding 'invalid_approval_hash' 'FAIL'
                } else {
                    try {
                        $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash
                        if ($actualHash -ine $ExpectedSha256) { & $addFinding 'approval_hash_changed' 'FAIL' }
                    } catch {
                        & $addFinding 'source_hash_unverifiable' 'FAIL'
                    }
                }
            }
            try {
                if ((Get-Item -LiteralPath $fullPath -ErrorAction Stop).Length -gt $MaxMarkdownBytes) {
                    & $addFinding 'markdown_size_limit' 'FAIL'
                }
            } catch {
                & $addFinding 'source_size_unverifiable' 'FAIL'
            }
        }
    }

    $status = $RegistryStatus.Trim().ToLowerInvariant()
    if ($status -ne 'approved' -and -not ($AllowPublished -and $status -eq 'published')) {
        & $addFinding 'registry_status_not_approved' 'FAIL'
    }

    $policy = $PublicPolicy.Trim().ToLowerInvariant()
    if ($policy -notin @('public', 'partial-public')) {
        & $addFinding 'public_policy_not_publishable' 'FAIL'
    }
    if ($SourceCategory.Trim().ToLowerInvariant() -in @('lecture_pdf', 'practice_notebook', 'zip_archive', 'image', 'checkpoint', 'index_note')) {
        & $addFinding 'source_category_not_publishable' 'FAIL'
    }

    $sourceFrontMatter = [regex]::Match($OriginalContent, '\A---\s*\r?\n(?<yaml>.*?)\r?\n---\s*(?:\r?\n|$)', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $sourceFrontMatter.Success) {
        & $addFinding 'frontmatter_missing_or_invalid' 'FAIL'
    } else {
        $declaredPolicy = [regex]::Match($sourceFrontMatter.Groups['yaml'].Value, '(?im)^\s*public_policy\s*:\s*(?<value>[^\r\n#]+)')
        if ($declaredPolicy.Success) {
            $declared = $declaredPolicy.Groups['value'].Value.Trim().Trim('"').Trim("'").ToLowerInvariant()
            if ($declared -notin @('public', 'partial-public')) {
                & $addFinding 'declared_policy_not_publishable' 'FAIL'
            } elseif ($declared -ne $policy) {
                & $addFinding 'declared_policy_conflict' 'FAIL'
            }
        }
    }

    $publishedFrontMatter = [regex]::Match($Content, '\A---\s*\r?\n(?<yaml>.*?)\r?\n---\s*(?:\r?\n|$)', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $publishedFrontMatter.Success) {
        & $addFinding 'published_frontmatter_invalid' 'FAIL'
    } elseif ($publishedFrontMatter.Groups['yaml'].Value -match '(?im)^\s*(?:source_id|note_date|mode|model|public_policy|registry_id|registry_ref|source_path|internal_id)\s*:') {
        & $addFinding 'internal_metadata_in_output' 'FAIL'
    }

    $publishedBody = $Content
    if ($publishedFrontMatter.Success) { $publishedBody = $Content.Substring($publishedFrontMatter.Length) }
    if ($publishedBody -match '(?im)^\s*(?:source_id|note_date|registry_id|registry_ref|source_path|internal_id)\s*:') {
        & $addFinding 'internal_metadata_in_body' 'WARN'
    }
    if ($Content -match '(?is)<\s*(?:img|iframe|object|embed)\b') {
        & $addFinding 'html_embedded_asset_not_scanned' 'WARN'
    }
    if ($Content -match '(?im)\]\(\s*/?downloads/[^)]*\)') {
        & $addFinding 'download_not_manifested' 'WARN'
    }

    if ([Text.Encoding]::UTF8.GetByteCount($Content) -gt $MaxMarkdownBytes) { & $addFinding 'markdown_size_limit' 'FAIL' }

    $credentialPatterns = @(
        '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b',
        '\bAKIA[0-9A-Z]{16}\b',
        '\bAIza[0-9A-Za-z_-]{35}\b',
        '\bsk-[A-Za-z0-9]{24,}\b'
    )
    foreach ($pattern in $credentialPatterns) {
        if ([regex]::IsMatch($Content, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            & $addFinding 'credential_like_value' 'FAIL'
            break
        }
    }
    $genericCredential = [regex]::Match($Content, '(?im)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\b\s*[:=]\s*[""]?([A-Za-z0-9_./+=-]{12,})')
    if ($genericCredential.Success -and $genericCredential.Groups[1].Value -notmatch '(?i)(example|dummy|fake|placeholder|redacted|replace|your|change[-_]?me|not[-_]?real|test[-_]?only)') {
        & $addFinding 'credential_assignment_suspected' 'FAIL'
    }

    if ([regex]::IsMatch($Content, '(?i)(?:\b[A-Z]:\\(?:Users)\\[^\s<>"]+|\\\\[A-Za-z0-9._-]+\\[A-Za-z0-9$._-]+(?:\\[^\s<>"]+)?)')) {
        & $addFinding 'personal_or_internal_path' 'WARN'
    }

    $imageRefs = [regex]::Matches($Content, '!\[[^\]]*\]\((?<target>[^)\s]+)[^)]*\)')
    foreach ($imageRef in $imageRefs) {
        $target = [string]$imageRef.Groups['target'].Value
        if ($target -match '^(?i)https?://') {
            & $addFinding 'external_image_not_scanned' 'WARN'
            continue
        }
        if ($target -match '^(?i)(?:file:|data:|javascript:|//)') {
            & $addFinding 'unsafe_image_scheme' 'FAIL'
            continue
        }
        if (-not $target.StartsWith('/images/', [StringComparison]::OrdinalIgnoreCase)) {
            & $addFinding 'unmanaged_image_reference' 'WARN'
            continue
        }
        if (-not $DraftAssetRoot -or -not (Test-Path -LiteralPath $DraftAssetRoot -PathType Container)) {
            & $addFinding 'image_asset_root_missing' 'FAIL'
            continue
        }
        try {
            $assetRoot = [IO.Path]::GetFullPath($DraftAssetRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $relativeAsset = [Uri]::UnescapeDataString($target.TrimStart('/')) -replace '/', '\'
            $assetSegments = $relativeAsset.Split([IO.Path]::DirectorySeparatorChar)
            if ($assetSegments -contains '..' -or [IO.Path]::IsPathRooted($relativeAsset)) {
                & $addFinding 'image_path_traversal' 'FAIL'
                continue
            }
            $assetPath = [IO.Path]::GetFullPath((Join-Path $assetRoot $relativeAsset))
            if (-not $assetPath.StartsWith($assetRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
                & $addFinding 'image_asset_missing_or_outside_root' 'FAIL'
                continue
            }
            if (Test-LLPreflightReparsePath -Path $assetPath -Root $assetRoot) {
                & $addFinding 'linked_image_path' 'FAIL'
                continue
            }
            if ([IO.Path]::GetExtension($assetPath).ToLowerInvariant() -notin @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg')) {
                & $addFinding 'unsupported_image_type' 'FAIL'
                continue
            }
            if ((Get-Item -LiteralPath $assetPath -ErrorAction Stop).Length -gt $MaxImageBytes) {
                & $addFinding 'image_size_limit' 'FAIL'
            }
        } catch {
            & $addFinding 'image_asset_unverifiable' 'FAIL'
        }
    }

    $distinctFindings = @($findings | Sort-Object code -Unique)
    $resultStatus = 'PASS'
    if (@($distinctFindings | Where-Object severity -eq 'FAIL').Count -gt 0) {
        $resultStatus = 'FAIL'
    } elseif (@($distinctFindings | Where-Object severity -eq 'WARN').Count -gt 0) {
        $resultStatus = 'WARN'
    }
    $sourceHash = ''
    if ($fullPath -and (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        try { $sourceHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    }
    return [pscustomobject]@{
        status = $resultStatus
        source_sha256 = $sourceHash
        findings = $distinctFindings
    }
}

Export-ModuleMember -Function Invoke-LLPublishPreflight
