#Requires -Version 7.0
Set-StrictMode -Version Latest

$script:LLRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:LLRegistryFields = @(
    "source_id",
    "source_path",
    "file_name",
    "file_path",
    "file_type",
    "source_type",
    "source_category",
    "date_added",
    "created_at",
    "status",
    "topic",
    "language",
    "public_policy",
    "hash",
    "notes"
)

function Get-LLRoot { return $script:LLRoot }

function Get-LLPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    return (Join-Path $script:LLRoot $RelativePath)
}

# Hugo 사이트 루트. 환경변수 LEARNINGLOG_BLOG_ROOT 가 있으면 그 경로, 없으면 LearningLog 옆 'Blog' 폴더.
function Get-LLBlogRoot {
    if ($env:LEARNINGLOG_BLOG_ROOT) { return $env:LEARNINGLOG_BLOG_ROOT }
    return (Join-Path (Split-Path -Parent $script:LLRoot) 'Blog')
}

function Read-LLText {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-LLText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

function Get-LLRegistryPath {
    return (Get-LLPath "01_registry\source_registry.csv")
}

function Get-LLRegistryFields {
    return @($script:LLRegistryFields)
}

function Get-LLProp {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ""
    )
    if ($null -eq $Row) { return $Default }
    $prop = $Row.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return [string]$prop.Value
}

function Backup-LLFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Prefix = "backup"
    )
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $backupDir = Get-LLPath "07_archive\backups"
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $name = "{0}_{1}{2}" -f $Prefix, $stamp, [System.IO.Path]::GetExtension($Path)
    $dest = Join-Path $backupDir $name
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

function Get-LLRelativePath {
    param([Parameter(Mandatory)][string]$FullPath)
    $rel = $FullPath.Replace($script:LLRoot + "\", "").Replace($script:LLRoot + "/", "")
    return $rel.Replace("\", "/").Normalize([System.Text.NormalizationForm]::FormC)
}

function Resolve-LLSourcePath {
    param([Parameter(Mandatory)][string]$SourcePath)
    if ([System.IO.Path]::IsPathRooted($SourcePath)) { return $SourcePath }
    return (Join-Path $script:LLRoot ($SourcePath -replace "/", "\"))
}

function Get-LLHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { return "" }
}

function Get-LLMarkdownBodyHash {
    param([AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return "" }
    $normalized = $Content.TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n").Normalize([Text.NormalizationForm]::FormC)
    $frontMatter = [regex]::Match($normalized, '\A---\n[\s\S]*?\n---(?:\n|\z)')
    if ($frontMatter.Success) { $normalized = $normalized.Substring($frontMatter.Length) }
    $body = $normalized.Trim()
    if (-not $body) { return "" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($body))).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-LLTopicFromFilename {
    param([Parameter(Mandatory)][string]$FileName)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $name = $name -replace '_\d{4}-\d{2}-\d{2}', ''
    $name = $name -replace '^COLLECT_\d{8}_[^_]+_?', ''
    $name = $name -replace '\d{8}', ''
    $name = $name -replace '^PN_\d{4}-\d{2}-\d{2}_?', ''
    $name = $name -replace '^PN_\d*_?', ''
    $name = $name -replace '^SRC-\d{8}-\d{3}_?', ''
    $name = $name -replace '^SRC-\d+-\d+-?', ''
    $name = $name -replace '^\[.*?\]_?\s*', ''
    $name = $name.ToLowerInvariant().Trim()
    $name = $name -replace '[\s_]+', '-'
    $name = $name -replace '-+', '-'
    $name = $name.Trim('-')
    if ($name.Length -lt 3) { return "unclassified" }
    return $name
}

function Get-LLSourceMetadata {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$InboxSubfolder
    )
    $ext = $File.Extension.ToLowerInvariant()
    $name = $File.Name
    $sourceType = "misc"
    $category = "misc"
    $policy = "internal-only"

    if ($name -like "*_INDEX.md") {
        $sourceType = "internal_note"; $category = "index_note"; $policy = "internal-only"
    } elseif ($name -like "CHECKPOINT_*.md") {
        $sourceType = "internal_note"; $category = "checkpoint"; $policy = "internal-only"
    } elseif ($ext -eq ".pdf") {
        $sourceType = "lecture"; $category = "lecture_pdf"; $policy = "internal-only"
    } elseif ($ext -eq ".ipynb") {
        $sourceType = "practice"; $category = "practice_notebook"; $policy = "private"
    } elseif ($ext -eq ".zip") {
        $sourceType = "archive"; $category = "zip_archive"; $policy = "internal-only"
    } elseif ($ext -in @(".png", ".jpg", ".jpeg", ".webp")) {
        $sourceType = "screenshot"; $category = "image"; $policy = "internal-only"
    } elseif ($InboxSubfolder -eq "dev_notes") {
        $sourceType = "development_note"; $category = "dev"; $policy = "private"
    } elseif ($name -like "PN_*.md" -or $InboxSubfolder -eq "personal_notes") {
        $sourceType = "personal_note"; $category = "personal_note"; $policy = "partial-public"
    } elseif ($name -like "SRC-*.md") {
        $sourceType = "intake_note"; $category = "intake_note"; $policy = "partial-public"
    } elseif ($InboxSubfolder -eq "chat_exports") {
        $sourceType = "chat_export"; $category = "chat_export"; $policy = "partial-public"
    } elseif ($InboxSubfolder -eq "web_notes" -and $name -like "COLLECT_*.md") {
        # 공식 RSS/Atom 수집물은 일반 웹 메모와 분리해 AI 자료·논문 흐름으로 보낸다.
        $sourceType = "web_note"; $category = "ai-research"; $policy = "partial-public"
    } elseif ($InboxSubfolder -eq "web_notes") {
        $sourceType = "web_note"; $category = "web_note"; $policy = "partial-public"
    } elseif ($ext -in @(".md", ".txt")) {
        $sourceType = "personal_note"; $category = "personal_note"; $policy = "partial-public"
    }

    # 공개 정책은 파일명 추정값보다 원문 front matter가 우선이다.
    # INDEX/checkpoint는 선언과 무관하게 내부 참조 자료로 유지한다.
    if ($ext -in @('.md', '.txt') -and $category -notin @('index_note', 'checkpoint')) {
        $declared = Get-LLNoteField -Content (Read-LLText $File.FullName) -Name 'public_policy'
        if ($declared) {
            $policy = if ($declared -in @('public', 'partial-public', 'private', 'internal-only')) { $declared } else { 'private' }
        }
    }

    [pscustomobject]@{
        file_name       = $name
        file_path       = $File.FullName
        file_type       = $ext.TrimStart(".")
        source_type     = $sourceType
        source_category = $category
        public_policy   = $policy
        topic           = Get-LLTopicFromFilename $name
        hash            = Get-LLHash $File.FullName
    }
}

function Get-LLExistingIds {
    param([array]$Rows)
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Rows) {
        $id = Get-LLProp $row "source_id"
        if ($id) { $null = $ids.Add($id) }
    }
    return $ids
}

function Get-LLNextSourceId {
    param(
        [array]$Rows,
        [string]$DateString = (Get-Date -Format "yyyyMMdd")
    )
    $prefix = "SRC-$DateString-"
    $max = 0
    foreach ($row in $Rows) {
        $id = Get-LLProp $row "source_id"
        if ($id.StartsWith($prefix)) {
            $n = 0
            if ([int]::TryParse($id.Substring($prefix.Length), [ref]$n) -and $n -gt $max) { $max = $n }
        }
    }
    return "{0}{1}" -f $prefix, ($max + 1).ToString("D3")
}

function ConvertTo-LLRegistryRow {
    param([Parameter(Mandatory)]$Row)
    $sourcePath = Get-LLProp $Row "source_path"
    $absPath = Get-LLProp $Row "file_path"
    if (-not $absPath -and $sourcePath) { $absPath = Resolve-LLSourcePath $sourcePath }
    $fileName = Get-LLProp $Row "file_name"
    if (-not $fileName -and $sourcePath) { $fileName = [System.IO.Path]::GetFileName($sourcePath) }
    $fileType = Get-LLProp $Row "file_type"
    if (-not $fileType -and $fileName) { $fileType = [System.IO.Path]::GetExtension($fileName).TrimStart(".").ToLowerInvariant() }

    $sourceType = Get-LLProp $Row "source_type" "misc"
    $category = Get-LLProp $Row "source_category"
    if (-not $category) {
        $category = switch ($sourceType) {
            "lecture" { if ($fileType -eq "pdf") { "lecture_pdf" } else { "lecture" } }
            "personal_note" { "personal_note" }
            "chat_export" { "chat_export" }
            "web_note" { "web_note" }
            "screenshot" { "image" }
            default { $sourceType }
        }
    }
    $dateAdded = Get-LLProp $Row "date_added" (Get-Date -Format "yyyy-MM-dd")
    $hash = Get-LLProp $Row "hash"
    if (-not $hash -and $absPath -and (Test-Path -LiteralPath $absPath)) { $hash = Get-LLHash $absPath }
    $topicDefault = "unclassified"
    if ($fileName) { $topicDefault = Get-LLTopicFromFilename $fileName }

    $out = [ordered]@{}
    $out["source_id"] = Get-LLProp $Row "source_id"
    $out["source_path"] = $sourcePath
    $out["file_name"] = $fileName
    $out["file_path"] = $absPath
    $out["file_type"] = $fileType
    $out["source_type"] = $sourceType
    $out["source_category"] = $category
    $out["date_added"] = $dateAdded
    $out["created_at"] = Get-LLProp $Row "created_at" $dateAdded
    $out["status"] = Get-LLProp $Row "status" "registered"
    $out["topic"] = Get-LLProp $Row "topic" $topicDefault
    $out["language"] = Get-LLProp $Row "language" "ko"
    $out["public_policy"] = Get-LLProp $Row "public_policy" "internal-only"
    $out["hash"] = $hash
    $out["notes"] = Get-LLProp $Row "notes"
    return [pscustomobject]$out
}

function Save-LLRegistryRows {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Rows)
    $path = Get-LLRegistryPath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ($Rows.Count -eq 0) {
        # 첫 실행(빈 레지스트리)에서도 헤더는 남긴다.
        $header = ($script:LLRegistryFields | ForEach-Object { '"' + $_ + '"' }) -join ','
        Set-Content -LiteralPath $path -Value $header -Encoding utf8
        return
    }
    $Rows | Select-Object $script:LLRegistryFields |
        Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8
}

function Ensure-LLRegistrySchema {
    $path = Get-LLRegistryPath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $path)) {
        @() | Select-Object $script:LLRegistryFields | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8
        return [pscustomobject]@{ upgraded = $true; backup = ""; rows = @() }
    }

    $rows = @(Import-Csv -LiteralPath $path -Encoding utf8)
    $headers = @()
    if ($rows.Count -gt 0) { $headers = @($rows[0].PSObject.Properties.Name) }
    else {
        $first = [System.IO.File]::ReadLines($path) | Select-Object -First 1
        if ($first) { $headers = @($first -split ",") }
    }
    $needsUpgrade = $false
    foreach ($field in $script:LLRegistryFields) {
        if ($headers -notcontains $field) { $needsUpgrade = $true; break }
    }

    if (-not $needsUpgrade) {
        return [pscustomobject]@{ upgraded = $false; backup = ""; rows = $rows }
    }

    $backup = Backup-LLFile -Path $path -Prefix "source_registry_pre_local_v05"
    $newRows = @($rows | ForEach-Object { ConvertTo-LLRegistryRow $_ })
    Save-LLRegistryRows $newRows
    return [pscustomobject]@{ upgraded = $true; backup = $backup; rows = $newRows }
}

function Get-LLRegistryRows {
    $null = Ensure-LLRegistrySchema
    $path = Get-LLRegistryPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Import-Csv -LiteralPath $path -Encoding utf8)
}

function Set-LLRegistryStatus {
    param(
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$Status
    )
    $rows = @(Get-LLRegistryRows)
    $hit = $false
    foreach ($row in $rows) {
        if ((Get-LLProp $row "source_id") -eq $SourceId) {
            $row.status = $Status
            $hit = $true
        }
    }
    if ($hit) { Save-LLRegistryRows $rows }
    return $hit
}

function Test-LLMProcessableSource {
    param([Parameter(Mandatory)]$Row)
    $policy = Get-LLProp $Row "public_policy"
    $sourceType = Get-LLProp $Row "source_type"
    $category = Get-LLProp $Row "source_category"
    $fileType = Get-LLProp $Row "file_type"
    if ($policy -notin @("public", "partial-public")) { return $false }
    if ($sourceType -ne "personal_note") { return $false }
    if ($category -in @("lecture_pdf", "practice_notebook", "zip_archive", "image", "checkpoint", "index_note")) { return $false }
    if ($fileType -notin @("md", "txt")) { return $false }
    return $true
}

function Test-LLPublishableSource {
    param([Parameter(Mandatory)]$Row)
    $policy = Get-LLProp $Row "public_policy"
    $category = Get-LLProp $Row "source_category"
    if ($policy -notin @("public", "partial-public")) { return $false }
    if ($category -in @("lecture_pdf", "practice_notebook", "zip_archive", "image", "checkpoint", "index_note")) { return $false }
    return $true
}

function Get-LLProcessingPolicy {
    param(
        [string]$SourceType = "personal_note",
        [string]$SourceCategory = "personal_note",
        [string]$FileType = "md",
        [int]$ManualChunkChars = 0
    )

    $policy = [ordered]@{
        MaxDirectChars = 0
        ChunkChars     = 4000
        OverlapChars   = 300
        ReferenceOnly  = $false
    }

    if ($SourceCategory -in @("lecture_pdf", "index_note", "checkpoint", "practice_notebook", "zip_archive", "image")) {
        $policy.ReferenceOnly = $true
        $policy.ChunkChars = 3000
        $policy.OverlapChars = 0
    } elseif ($SourceType -eq "chat_export") {
        $policy.ChunkChars = 5000
        $policy.OverlapChars = 500
    } elseif ($SourceType -eq "personal_note" -and $FileType -in @("md", "txt")) {
        $policy.MaxDirectChars = 6000
        $policy.ChunkChars = 4000
        $policy.OverlapChars = 300
    }

    if ($ManualChunkChars -gt 0) { $policy.ChunkChars = $ManualChunkChars }
    return [pscustomobject]$policy
}

function Get-LLChunkSize {
    param(
        [int]$NumCtx = 8192,
        [string]$SourceType = "personal_note",
        [string]$SourceCategory = "personal_note",
        [string]$FileType = "md",
        [int]$ManualChunkChars = 0
    )
    return (Get-LLProcessingPolicy -SourceType $SourceType -SourceCategory $SourceCategory -FileType $FileType -ManualChunkChars $ManualChunkChars).ChunkChars
}

function Get-LLDirectCharLimit {
    param(
        [string]$SourceType = "personal_note",
        [string]$SourceCategory = "personal_note",
        [string]$FileType = "md"
    )
    return (Get-LLProcessingPolicy -SourceType $SourceType -SourceCategory $SourceCategory -FileType $FileType).MaxDirectChars
}

function Get-LLOverlapChars {
    param(
        [string]$SourceType = "personal_note",
        [string]$SourceCategory = "personal_note",
        [string]$FileType = "md"
    )
    return (Get-LLProcessingPolicy -SourceType $SourceType -SourceCategory $SourceCategory -FileType $FileType).OverlapChars
}

function Split-LLTextChunks {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$MaxChars = 4000,
        [int]$OverlapChars = 0
    )
    $paragraphs = $Text -split "(?m)^\s*$"
    $chunks = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    foreach ($para in $paragraphs) {
        $p = $para.Trim()
        if (-not $p) { continue }
        if ($current.Length + $p.Length + 2 -gt $MaxChars -and $current.Length -gt 0) {
            $chunks.Add($current.ToString().Trim())
            $null = $current.Clear()
        }
        $null = $current.AppendLine($p)
        $null = $current.AppendLine()
    }
    if ($current.Length -gt 0) { $chunks.Add($current.ToString().Trim()) }
    if ($chunks.Count -eq 0) { $chunks.Add($Text) }

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($chunk in $chunks) {
        if ($chunk.Length -le $MaxChars) {
            $result.Add($chunk)
        } else {
            $pos = 0
            while ($pos -lt $chunk.Length) {
                $len = [Math]::Min($MaxChars, $chunk.Length - $pos)
                $result.Add($chunk.Substring($pos, $len))
                $pos += $len
            }
        }
    }

    if ($OverlapChars -le 0 -or $result.Count -le 1) { return $result }

    $withOverlap = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $result.Count; $i++) {
        if ($i -eq 0) {
            $withOverlap.Add($result[$i])
            continue
        }
        $prev = $result[$i - 1]
        $tailLen = [Math]::Min($OverlapChars, $prev.Length)
        $tail = $prev.Substring($prev.Length - $tailLen)
        $withOverlap.Add("[이전 문맥 일부]`n$tail`n`n[현재 파트]`n$($result[$i])")
    }
    return $withOverlap
}

function Remove-ExtraHugoFrontMatter {
    # -KeepTrailingWhitespace: 줄 끝 공백을 건드리지 않는다(LLM 초안 정리용. 마크다운 강제 줄바꿈 보존).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$KeepTrailingWhitespace)
    $lines = $Text -split "`r?`n"
    if ($lines.Count -eq 0) { return $Text }
    $start = 0
    if ($lines[0].Trim() -eq "---") {
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq "---") { $start = $i + 1; break }
        }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $start; $i++) { $out.Add($lines[$i]) }
    $metaLinePattern = '^\s*(source_id|note_date|mode|model):\s*'
    $boldMetaPattern = '^\s*\*\*(title|제목|date|날짜|draft|categories|category|카테고리|범주|tags|태그|description|설명)\*\*\s*:'

    $i = $start
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line.Trim() -eq "---" -or $line -match $metaLinePattern -or $line -match $boldMetaPattern) {
            $i++
            continue
        }
        $out.Add($line)
        $i++
    }
    $final = ($out -join "`n")
    if (-not $KeepTrailingWhitespace) { $final = $final -replace '(?m)[ \t]+$', '' }
    return ($final.TrimEnd() + "`n")
}

# YAML 큰따옴표 문자열. 기본은 줄바꿈을 공백으로 접는다(-KeepNewlines 로 원문 유지).
function ConvertTo-LLYamlString {
    param([AllowEmptyString()][string]$Value, [switch]$KeepNewlines)
    $s = if ($null -eq $Value) { "" } else { [string]$Value }
    # 치환 문자열에서 백슬래시는 특수문자가 아니다: '\\' = 역슬래시 2개, '\"' = 역슬래시 + 따옴표.
    # (옛 구현은 '\\\\' / '\\"' 로 이중 이스케이프해 따옴표·역슬래시가 든 제목이 잘못된 YAML 이 됐다.)
    $s = $s -replace '\\', '\\'
    $s = $s -replace '"', '\"'
    if (-not $KeepNewlines) { $s = $s -replace "\r?\n", ' ' }
    return '"' + $s + '"'
}

# HTML 태그 제거 + 엔티티 해제 + 공백 정리.
function ConvertTo-LLPlainText {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $s = [System.Net.WebUtility]::HtmlDecode($Value)
    $s = [regex]::Replace($s, '<[^>]+>', ' ')
    return [regex]::Replace($s, '\s+', ' ').Trim()
}

# 초안 파일이 속한 섹션(04_blog_drafts 아래 첫 폴더). 없으면 learning.
function Get-LLDraftSection {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft, [Parameter(Mandatory)][string]$DraftsDir)
    $rel = $Draft.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
    $sectionName = ($rel -split "/")[0]
    if (-not $sectionName) { return "learning" }
    return $sectionName.ToLowerInvariant()
}

# 오늘 처리 대상인가: 백로그 포함 / 파일명이 오늘 날짜 / registry 등록일이 오늘 / 파일 수정일이 오늘.
function Test-LLTodayDraft {
    param(
        [Parameter(Mandatory)]$Draft,
        $Row,
        [Parameter(Mandatory)][string]$TodayStr,
        [switch]$IncludeBacklog
    )
    if ($IncludeBacklog) { return $true }
    if ($Draft.Name -like "$TodayStr*") { return $true }
    if ($Row) {
        $d = Get-LLProp $Row "date_added"
        if ($d -eq $TodayStr) { return $true }
    }
    if ($Draft.LastWriteTime.ToString("yyyy-MM-dd") -eq $TodayStr) { return $true }
    return $false
}

# 초안 → registry 행. 본문의 source_id 가 우선, 없으면 파일명(topic)으로 찾는다.
function Resolve-LLDraftRow {
    param($Draft, $Content, [Parameter(Mandatory)]$RowBySid, [Parameter(Mandatory)]$RowByTopic)
    $sid = Get-LLDraftSourceId $Content
    if ($sid -and $RowBySid.ContainsKey($sid)) { return $RowBySid[$sid] }
    if ($RowByTopic.ContainsKey($Draft.BaseName)) { return $RowByTopic[$Draft.BaseName] }
    return $null
}

function Get-LLArticleStructureStats {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $stats = [ordered]@{
        purpose  = 0
        learned  = 0
        confused = 0
        practice = 0
        summary  = 0
        combined = 0
    }

    $inFence = $false
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            continue
        }
        if ($inFence) { continue }
        if ($line -notmatch '^\s*#{2,4}\s+(.+?)\s*$') { continue }

        $heading = $Matches[1].Trim()
        $heading = $heading -replace '^\*\*(.+?)\*\*$', '$1'
        $heading = $heading.Trim().TrimEnd(":").TrimEnd("?").Trim()
        $heading = $heading -replace '^\*\*(.+?)\*\*$', '$1'
        $heading = $heading -replace '\s+', ' '

        if ($heading -match '왜\s*썼나\s*/\s*배운\s*것|왜\s*썼나.+정리된\s*이해|왜\s*썼나.+다음\s*복습') {
            $stats["combined"]++
            continue
        }
        if ($heading -in @("왜 썼나", "왜 이 글을 썼나")) { $stats["purpose"]++; continue }
        if ($heading -in @("배운 것", "오늘 배운 핵심") -or $heading -match '^배운 것\s*\(.+\)$') { $stats["learned"]++; continue }
        if ($heading -in @("헷갈린 것", "헷갈렸던 점", "헷갈렸던 지점", "헷갈리던 점", "헷갈릴 수 있는 점")) { $stats["confused"]++; continue }
        if ($heading -in @("실습 예시", "실습하면서 알게 된 것")) { $stats["practice"]++; continue }
        if ($heading -in @("정리된 이해", "이해 정리")) { $stats["summary"]++; continue }
    }

    return [pscustomobject]$stats
}

function Repair-LLMarkdownCodeFences {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $lines = $Content -split "`r?`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $inFence = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            $out.Add($line)
            continue
        }

        if ($inFence -and $line -match '^\s*#{2,4}\s+') {
            $out.Add('```')
            $inFence = $false
        }

        $out.Add($line)
    }

    if ($inFence) { $out.Add('```') }
    $final = ($out -join "`n") -replace '(?m)[ \t]+$', ''
    # 빈 코드블록(여는 펜스 + 공백뿐 + 닫는 펜스) 제거 — 모델이 남기는 잉여 펜스 정리
    $final = $final -replace '(?m)^```[^\n]*\n(?:[ \t]*\n)*```[ \t]*(?:\n|$)', ''
    return ($final.TrimEnd() + "`n")
}

function Repair-LLMTextArtifacts {
    # 로컬 LLM 출력의 흔한 잡음을 결정적으로 교정하는 검수 단계(LLM 재호출 없음).
    #  - 반복 라벨 "**무엇 / 왜 중요한가**" 의 깨진 변형(중요한a, 중요한か, 중요한이 등)을 정규화
    #  - 한글에 달라붙은 일본어 가나(히라가나/가타카나)는 잡음으로 보고 제거
    #  - 한글 사이에 잘못 끼어든 라틴 단어(공백 없이 붙은) 등 명백한 깨짐만 손댐
    #  - 코드블록(```) 안은 건드리지 않는다(코드 보존).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    $lines = $Text -split "`r?`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; $out.Add($line); continue }
        if ($inFence) { $out.Add($line); continue }
        $l = $line
        # 1) 반복 라벨 정규화: "**무엇 / 왜 중요한X**" → "**무엇 / 왜 중요한가**"
        $l = [regex]::Replace($l, '\*\*\s*무엇\s*/\s*왜\s*중요한[^\*\r\n]*\*\*', '**무엇 / 왜 중요한가**')
        # 2) 한글에 달라붙은 일본어 가나 제거(앞/뒤 모두)
        $l = [regex]::Replace($l, '(?<=[가-힣])[ぁ-ゖァ-ヺ]+', '')
        $l = [regex]::Replace($l, '[ぁ-ゖァ-ヺ]+(?=[가-힣])', '')
        # 3) 이중 공백 정리(코드 밖 본문)
        $l = [regex]::Replace($l, '(\S)  +(\S)', '$1 $2')
        $out.Add($l)
    }
    return ($out -join "`n")
}

function Normalize-LLBodyMarkdown {
    # 본문(front matter 제외)의 구조 잡음을 결정적으로 정리하는 검수 단계.
    #  - h1(# ) → h2(## ): h1은 글 제목 전용이라 본문에 있으면 목차·QA 게이트가 깨진다.
    #  - 본문에 흩어진 수평선(---, ***, ___) 제거: front matter/목차 구분선은 생성기가 따로 관리.
    #  - 코드블록(```) 안은 보존.
    #  주의: front matter 를 포함한 전체 문서가 아니라 '본문 텍스트'에만 적용해야 한다.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    $lines = $Text -split "`r?`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; $out.Add($line); continue }
        if ($inFence) { $out.Add($line); continue }
        if ($line -match '^\s*(---+|\*\*\*+|___+)\s*$') { continue }          # 수평선 제거
        if ($line -match '^#\s+(.+?)\s*$') { $out.Add('## ' + $Matches[1]); continue }   # h1 → h2
        $out.Add($line)
    }
    return ($out -join "`n")
}

function Get-LLArticleHeadingKind {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Heading)

    $h = $Heading.Trim()
    $h = $h -replace '^\*\*(.+?)\*\*$', '$1'
    $h = $h.Trim().TrimEnd(":").TrimEnd("?").Trim()
    $h = $h -replace '^\*\*(.+?)\*\*$', '$1'
    $h = $h -replace '^\d+[\.\)]\s*', ''
    $h = $h -replace '\s+', ' '

    if ($h -match '왜\s*썼나\s*/\s*배운\s*것|왜\s*썼나.+정리된\s*이해|왜\s*썼나.+다음\s*복습') { return "combined" }
    if ($h -in @("왜 썼나", "왜 이 글을 썼나")) { return "purpose" }
    if ($h -in @("배운 것", "오늘 배운 핵심") -or $h -match '^배운 것\s*\(.+\)$') { return "learned" }
    if ($h -in @("헷갈린 것", "헷갈렸던 점", "헷갈렸던 지점", "헷갈리던 점", "헷갈릴 수 있는 점")) { return "confused" }
    if ($h -in @("실습 예시", "실습하면서 알게 된 것")) { return "practice" }
    if ($h -in @("정리된 이해", "이해 정리")) { return "summary" }

    if ($h -match '실습|예시|코드|출력') { return "practice" }
    if ($h -match '헷갈|혼란|오해|주의') { return "confused" }
    if ($h -match '정리|이해|결론') { return "summary" }
    if ($h -match '목표|이유|왜') { return "purpose" }
    return "learned"
}

function ConvertTo-LLSingleArticleStructure {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $content = Remove-ExtraHugoFrontMatter -Text $Content
    $content = $content -replace "헷갈릴린", "헷갈린"
    $content = $content -replace '(?m)(print\(count\)\s*#\s*출력:)\s*$', '$1 1'
    $content = $content -replace '(?m)(#\s*(출력|결과):)\s*$', '$1 확인 필요'
    $content = Repair-LLMarkdownCodeFences -Content $content

    $lines = $content -split "`r?`n"
    $frontMatter = [System.Collections.Generic.List[string]]::new()
    $bodyStart = 0
    if ($lines.Count -gt 1 -and $lines[0].Trim() -eq "---") {
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq "---") {
                for ($j = 0; $j -le $i; $j++) { $frontMatter.Add($lines[$j]) }
                $bodyStart = $i + 1
                break
            }
        }
    }

    $segments = [System.Collections.Generic.List[object]]::new()
    $currentHeading = ""
    $currentLines = [System.Collections.Generic.List[string]]::new()
    $inFence = $false

    for ($i = $bodyStart; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            $currentLines.Add($line)
            continue
        }

        if (-not $inFence -and $line -match '^\s*#{2,4}\s+(.+?)\s*$') {
            if ($currentHeading -ne "" -or $currentLines.Count -gt 0) {
                $segments.Add([pscustomobject]@{
                    Heading = $currentHeading
                    Text = (($currentLines -join "`n").Trim())
                })
            }
            $currentHeading = $Matches[1].Trim()
            $currentLines = [System.Collections.Generic.List[string]]::new()
            continue
        }

        $currentLines.Add($line)
    }

    if ($currentHeading -ne "" -or $currentLines.Count -gt 0) {
        $segments.Add([pscustomobject]@{
            Heading = $currentHeading
            Text = (($currentLines -join "`n").Trim())
        })
    }

    $buckets = [ordered]@{
        purpose = [System.Collections.Generic.List[object]]::new()
        learned = [System.Collections.Generic.List[object]]::new()
        confused = [System.Collections.Generic.List[object]]::new()
        practice = [System.Collections.Generic.List[object]]::new()
        summary = [System.Collections.Generic.List[object]]::new()
    }

    foreach ($segment in $segments) {
        $heading = [string]$segment.Heading
        $text = ([string]$segment.Text).Trim()
        if (-not $heading -and -not $text) { continue }
        $kind = Get-LLArticleHeadingKind -Heading $heading
        if ($kind -eq "combined") {
            if ($text) {
                $buckets["learned"].Add([pscustomobject]@{ Heading = "학습 내용"; Text = $text })
            }
            continue
        }
        if (-not $buckets.Contains($kind)) { $kind = "learned" }

        $cleanHeading = $heading
        if (-not $cleanHeading) { $cleanHeading = "메모" }
        $cleanHeading = $cleanHeading -replace '^\*\*(.+?)\*\*$', '$1'
        $cleanHeading = $cleanHeading.Trim().TrimEnd(":").TrimEnd("?").Trim()
        if ($cleanHeading -match '왜\s*썼나|배운\s*것|오늘\s*배운\s*핵심|헷갈|정리된\s*이해|실습\s*예시') {
            $cleanHeading = switch ($kind) {
                "purpose" { "글을 남긴 이유" }
                "learned" { "학습 포인트" }
                "confused" { "혼동 포인트" }
                "practice" { "실습 기록" }
                "summary" { "이해 정리" }
                default { "학습 포인트" }
            }
        }
        if ($text) {
            $buckets[$kind].Add([pscustomobject]@{ Heading = $cleanHeading; Text = $text })
        }
    }

    function Add-LLArticleSection {
        param(
            [System.Collections.Generic.List[string]]$Out,
            [string]$Heading,
            [System.Collections.Generic.List[object]]$Items,
            [switch]$NumberedSubsections
        )
        $Out.Add("## $Heading")
        $Out.Add("")
        if ($Items.Count -eq 0) {
            $Out.Add("정리할 내용 없음.")
            $Out.Add("")
            return
        }
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            if ($NumberedSubsections -and $Items.Count -gt 1) {
                $sub = ([string]$item.Heading).Trim()
                if (-not $sub) { $sub = "내용" }
                $Out.Add(("### {0}. {1}" -f ($i + 1), $sub))
                $Out.Add("")
            }
            $Out.Add(([string]$item.Text).Trim())
            $Out.Add("")
        }
    }

    $out = [System.Collections.Generic.List[string]]::new()
    if ($frontMatter.Count -gt 0) {
        foreach ($line in $frontMatter) { $out.Add($line) }
        $out.Add("")
    }

    Add-LLArticleSection -Out $out -Heading "왜 이 글을 썼나" -Items $buckets["purpose"]
    Add-LLArticleSection -Out $out -Heading "오늘 배운 핵심" -Items $buckets["learned"] -NumberedSubsections
    Add-LLArticleSection -Out $out -Heading "헷갈렸던 지점" -Items $buckets["confused"] -NumberedSubsections
    Add-LLArticleSection -Out $out -Heading "실습하면서 알게 된 것" -Items $buckets["practice"] -NumberedSubsections
    Add-LLArticleSection -Out $out -Heading "정리된 이해" -Items $buckets["summary"]

    # AI와 블로그 주인의 협업 고지 (한국어/영어)
    $out.Add("")
    $out.Add("> 🤖 이 글은 AI와 블로그 주인의 합작으로 작성되었습니다!")
    $out.Add("> This post was created collaboratively by AI and the blog owner.")
    $out.Add("")

    $final = ($out -join "`n") -replace '(?m)[ \t]+$', ''
    return ($final.TrimEnd() + "`n")
}

function Test-LLHasSummarySection {
    param([Parameter(Mandatory)][AllowEmptyString()][object]$Lines)
    if ($Lines -is [string]) { $Lines = $Lines -split "`r?`n" }
    $inFence = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^\s*##\s+총평\s*$') { return $true }
    }
    return $false
}

function Get-LLHugoAnchor {
    param([Parameter(Mandatory)][string]$HeadingText)
    $s = $HeadingText.Trim()
    $s = $s.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^0-9a-z가-힣ㄱ-ㅎㅏ-ㅣ \-]', '')
    $s = $s -replace '\s+', '-'
    $s = $s -replace '-+', '-'
    $s = $s.Trim('-')
    return $s
}

function Remove-LLExistingTableOfContents {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)

    $lines = $Body -split "`r?`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    $skippingToc = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            if (-not $skippingToc) { $out.Add($line) }
            continue
        }
        if (-not $inFence -and $line -match '^##\s+목차\s*$') {
            $skippingToc = $true
            continue
        }
        if ($skippingToc) {
            # 기존 목차 뒤의 구분선과 링크 목록을 버리고 다음 최상위 섹션부터 보존한다.
            if (-not $inFence -and ($line -match '^##\s+' -or $line -match '^---\s*$')) {
                $skippingToc = $false
                if ($line -match '^##\s+') { $out.Add($line) }
            }
            continue
        }
        $out.Add($line)
    }
    return ($out -join "`n")
}

function Add-LLTableOfContents {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)

    # 모델이 목차를 미리 출력해도 시스템 목차와 중복되지 않도록 항상 재생성한다.
    $cleanBody = Remove-LLExistingTableOfContents -Body $Body
    $lines = $cleanBody -split "`r?`n"
    $headings = [System.Collections.Generic.List[object]]::new()
    $firstHeadingIdx = -1
    $inFence = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^##\s+(.+?)\s*$' -and $line -notmatch '^###') {
            $full = $Matches[1].Trim()
            if ($full -eq '목차') { continue }
            if ($firstHeadingIdx -lt 0) { $firstHeadingIdx = $i }
            # 번호 분리: '1. 개념 A' → num='1', label='개념 A'
            $num = ''
            $label = $full
            if ($full -match '^(\d+)[\.\)]\s*(.+)$') { $num = $Matches[1]; $label = $Matches[2].Trim() }
            $headings.Add([pscustomobject]@{ Num = $num; Label = $label; Anchor = (Get-LLHugoAnchor -HeadingText $full) })
        }
    }
    if ($headings.Count -eq 0 -or $firstHeadingIdx -lt 0) { return $Body }

    $toc = [System.Collections.Generic.List[string]]::new()
    $toc.Add("## 목차")
    foreach ($h in $headings) {
        if ($h.Num) {
            $toc.Add(("- {0}. [{1}](#{2})" -f $h.Num, $h.Label, $h.Anchor))
        } else {
            $toc.Add(("- [{0}](#{1})" -f $h.Label, $h.Anchor))
        }
    }
    $toc.Add("")
    $toc.Add("---")
    $toc.Add("")

    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $firstHeadingIdx) { foreach ($t in $toc) { $out.Add($t) } }
        $out.Add($lines[$i])
    }
    return ($out -join "`n")
}

function ConvertTo-LLOutlineArticleStructure {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$FallbackTitle = "",
        [string]$FallbackDate = "",
        [string]$FallbackSection = "learning"
    )

    # 0) BOM 제거
    $Content = $Content -replace "^﻿", ""

    # 1) 기존 후처리 재사용 (메타/오타/빈출력주석/펜스)
    $content = Remove-ExtraHugoFrontMatter -Text $Content
    $content = $content -replace "헷갈릴린", "헷갈린"
    $content = $content -replace '(?m)(#\s*(출력|결과):)\s*$', '$1 확인 필요'
    $content = Repair-LLMarkdownCodeFences -Content $content

    # 2) front matter / body 분리
    $lines = $content -split "`r?`n"
    $fmEnd = -1
    if ($lines.Count -gt 1 -and $lines[0].Trim() -eq "---") {
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq "---") { $fmEnd = $i; break }
        }
    }
    $frontMatter = [System.Collections.Generic.List[string]]::new()
    $bodyStart = 0
    if ($fmEnd -gt 0) {
        for ($j = 0; $j -le $fmEnd; $j++) { $frontMatter.Add($lines[$j]) }
        $bodyStart = $fmEnd + 1
    }

    # 2b) front matter 정상성 검사. title:/draft: 없으면 깨진 것 → 정상 YAML 재구성
    $fmText = ($frontMatter -join "`n")
    $hasValidTitle = $fmText -match '(?m)^\s*title:\s*\S'
    if (-not $hasValidTitle) {
        # 깨진 fm 안에서 제목 후보 추출: '**제목: X**' 또는 '**title:** X' 또는 첫 의미줄
        $titleGuess = $FallbackTitle
        if ($fmText -match '제목[:：]\s*(.+)') { $titleGuess = ($Matches[1] -replace '[*`]', '').Trim() }
        elseif ($fmText -match '(?im)title[:：]\s*(.+)') { $titleGuess = ($Matches[1] -replace '[*`"]', '').Trim() }
        if (-not $titleGuess) { $titleGuess = "학습 노트" }
        $dateGuess = if ($FallbackDate) { $FallbackDate } else { (Get-Date -Format 'yyyy-MM-dd') }
        if ($fmText -match '(?m)date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})') { $dateGuess = $Matches[1] }
        $frontMatter = [System.Collections.Generic.List[string]]::new()
        $frontMatter.Add("---")
        $frontMatter.Add(("title: `"{0}`"" -f ($titleGuess -replace '"', "'")))
        $frontMatter.Add(("date: {0}" -f $dateGuess))
        $frontMatter.Add("draft: true")
        $frontMatter.Add(("categories: [`"{0}`"]" -f $FallbackSection))
        $frontMatter.Add("tags: []")
        $frontMatter.Add("description: `"`"")
        $frontMatter.Add("---")
    }

    # 3) body 수집 + 기존 '## 목차' 블록 제거 (재생성용)
    $body = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    $skippingToc = $false
    for ($i = $bodyStart; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*```') { $inFence = -not $inFence; $body.Add($line); continue }
        if (-not $inFence -and $line -match '^##\s+목차\s*$') { $skippingToc = $true; continue }
        if ($skippingToc) {
            if (-not $inFence -and ($line -match '^##\s+' -or $line.Trim() -eq '---')) {
                $skippingToc = $false
            } else { continue }
        }
        $body.Add($line)
    }

    # 4) 총평 누락시 스텁 추가
    if (-not (Test-LLHasSummarySection -Lines $body)) {
        $body.Add("")
        $body.Add("## 총평")
        $body.Add("")
        $body.Add("### 오늘 전체에서 배운 것")
        $body.Add("정리 필요.")
        $body.Add("")
        $body.Add("### 다음에 조심할 것")
        $body.Add("정리 필요.")
        $body.Add("")
        $body.Add("### 다음 복습 주제")
        $body.Add("정리 필요.")
        $body.Add("")
    }

    # 5) 목차 자동 주입
    $bodyText = Add-LLTableOfContents -Body ($body -join "`n")

    # 6) 재조립
    $out = [System.Collections.Generic.List[string]]::new()
    if ($frontMatter.Count -gt 0) { foreach ($l in $frontMatter) { $out.Add($l) }; $out.Add("") }
    $out.Add($bodyText.TrimStart())
    $final = ($out -join "`n") -replace '(?m)[ \t]+$', ''
    return ($final.TrimEnd() + "`n")
}

# ─────────────────────────────────────────────────────────
# 슬롯 채우기(fill-in-the-blank) 방식 — 구조는 PS 조립, LLM은 텍스트만
# ─────────────────────────────────────────────────────────

function ConvertFrom-LLJsonResponse {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $t = $Raw.Trim()
    $t = $t -replace "^﻿", ""
    $t = $t -replace '(?s)^\s*```(?:json)?\s*', '' -replace '(?s)\s*```\s*$', ''
    $open  = $t.IndexOf('{')
    $close = $t.LastIndexOf('}')
    if ($open -lt 0 -or $close -le $open) { return $null }
    $json = $t.Substring($open, $close - $open + 1)
    try { return ($json | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Get-LLJsonField {
    param($Obj, [string]$Key, [string]$Default = "")
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Key]
    if ($p -and $p.Value) { return [string]$p.Value }
    return $Default
}

function Get-LLConceptList {
    param(
        [Parameter(Mandatory)][string]$NoteContent,
        [Parameter(Mandatory)][scriptblock]$LLMInvoker,
        [int]$MaxConcepts = 4
    )
    $prompt = @"
너는 학습 노트에서 다룬 핵심 개념을 추출하는 분류기다.
아래 노트는 같은 주제를 여러 번 반복하거나 잘린 부분이 있을 수 있다.
중복을 제거하고, 실제로 다룬 서로 다른 핵심 개념을 최대 $MaxConcepts 개까지 골라라.
개념명은 짧은 한국어 명사구로. (예: f-string 포매팅, 클래스와 인스턴스)
출력 규칙: 한 줄에 개념 하나씩, 개념명만. 번호/기호/설명/머리말 금지.

노트:
---
$NoteContent
"@
    # plain-text 로 받아 줄 단위 파싱 (JSON 의존 제거 → 작은 모델 안정성↑).
    # 빈 결과면 런너 죽음 의심 → 회복 대기 후 재시도.
    $names = @()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $raw = [string](& $LLMInvoker $prompt) } catch { $raw = "" }
        foreach ($line in ($raw -split "`r?`n")) {
            $n = $line.Trim()
            $n = $n -replace '^\s*[\-\*\d\.\)\#]+\s*', ''   # 선두 번호/기호 제거
            $n = $n.Trim().Trim('"').Trim("'").Trim()
            if ($n -and $n.Length -le 40 -and $n -notmatch '[{}\[\]]') { $names += $n }
        }
        if ($names.Count -gt 0) { break }
        # 빈 결과 = 런너 죽음 의심 → 선택된 엔진(LM) 회복만 확인 후 재시도, 꺼져 있으면 즉시 중단
        if ($attempt -lt 3) { if (-not (Wait-LLMReady)) { break } }
    }
    $names = @($names | Select-Object -Unique)
    if ($names.Count -gt $MaxConcepts) { $names = $names[0..($MaxConcepts-1)] }
    if ($names.Count -eq 0) { $names = @("학습 내용") }
    return $names
}

function Get-LLBlogSection {
    # 기본은 learning/projects지만 명시된 editorial section은 보존한다.
    # 섹션을 보존해야 분야별 작성 기준과 QA 프로필이 같은 글에 적용된다.
    param([string]$Topic, [string]$RawSection = "")
    $n = (([string]$Topic) + " " + [string]$RawSection).ToLowerInvariant()
    $explicit = ([string]$RawSection).Trim().ToLowerInvariant()
    if ($explicit -in @('research', 'practice', 'goals', 'dev')) { return $explicit }
    $proj = @(
        'ai-tools','generative','stable-diffusion','audiocraft','magenta','videocrafter','diffusion',
        'environment','-env','conda','colab-local','pip-requirements','ollama-local','venv',
        'package-release','package-environment','classmap','learninglog-kit','local-tool-distribution',
        'pyrecipe','streamlit','dataset','crawl','bookcrawler','llm-design','hallucination'
    )
    foreach ($k in $proj) { if ($n -like "*$k*") { return 'projects' } }
    if ($RawSection -eq 'projects') { return 'projects' }
    return 'learning'
}

function Repair-LLIndentedCodeFences {
    # 들여쓴/중첩 코드펜스(``` )를 컬럼0으로 평탄화 → 'mismatched indented code fence' 차단 방지.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $lines = $Content -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s+)(```.*)$') { $lines[$i] = $Matches[2] }
    }
    return ($lines -join "`n")
}

function Set-LLMRecoveryEndpoint {
    # 공통 슬롯 생성기의 재시도 대상(LM Studio). -Engine 은 호환용으로만 받는다.
    param(
        [ValidateSet("lm")][string]$Engine = "lm",
        [string]$LMStudioBase = "http://127.0.0.1:1234"
    )
    $script:LLMRecoveryEngine = $Engine
    $script:LLMRecoveryLMStudioBase = $LMStudioBase.TrimEnd('/')
}

function Wait-LLMReady {
    # LM Studio API 를 한 번 점검한다. 서버가 꺼져 있으면 회복을 오래 기다리지 않는다.
    param(
        [int]$MaxWaitSec = 90,
        [ValidateSet("lm")][string]$Engine = $script:LLMRecoveryEngine,
        [string]$LMStudioBase = $script:LLMRecoveryLMStudioBase
    )
    if ([string]::IsNullOrWhiteSpace($LMStudioBase)) { $LMStudioBase = "http://127.0.0.1:1234" }

    try {
        $null = Invoke-RestMethod "$($LMStudioBase.TrimEnd('/'))/v1/models" -TimeoutSec 4 -ErrorAction Stop
        Start-Sleep -Seconds 2   # 호출 간 간격
        return $true
    } catch {
        Write-Host "    (LM Studio 서버가 꺼져 있거나 응답하지 않습니다. 현재 작업을 중단합니다.)" -ForegroundColor Red
        return $false
    }
}

function Test-LLMModelAvailable {
    # LM Studio /v1/models 목록에 지정한 모델 ID가 실제로 있는지 확인한다.
    # 생성 요청 전에 호출해, 잘못된 모델 ID로 인한 긴 재시도 대신 즉시 실패시킨다.
    # 반환: @{ ok; reason(server|model|""); message; available(id 배열) }
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$LMStudioBase = "http://127.0.0.1:1234"
    )
    try {
        $resp = Invoke-RestMethod -Uri "$($LMStudioBase.TrimEnd('/'))/v1/models" -Method Get -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ ok = $false; reason = "server"; message = $_.Exception.Message; available = @() }
    }
    $ids = @()
    if ($resp -and $resp.PSObject.Properties['data'] -and $resp.data) {
        $ids = @($resp.data | ForEach-Object { [string]$_.id })
    }
    if ($ids -contains $Model) {
        return [pscustomobject]@{ ok = $true; reason = ""; message = ""; available = $ids }
    }
    return [pscustomobject]@{ ok = $false; reason = "model"; message = "model not loaded: $Model"; available = $ids }
}

function Get-LLFieldText {
    # 한 칸(필드)을 plain-text 로 채운다. JSON 파싱 없음 → 작은 모델에서도 잘 안 깨짐.
    # 빈 응답/예외 시 즉시 재시도하지 않고 선택된 엔진 상태를 확인한 뒤 재시도.
    param(
        [Parameter(Mandatory)][scriptblock]$LLMInvoker,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$Retries = 3,
        [switch]$AllowEmpty
    )
    for ($i = 0; $i -le $Retries; $i++) {
        $failed = $false
        try { $r = ([string](& $LLMInvoker $Prompt)) } catch { $r = ""; $failed = $true }
        $r = $r.Trim()
        # 모델이 통째로 따옴표로 감싼 경우만 한 겹 제거 (코드블록은 보존)
        if ($r -match '^"(.*)"$' -and $r -notmatch '```') { $r = $Matches[1].Trim() }
        if ($r) { return $r }   # 성공 즉시 반환 (고정 2초 sleep 제거 — LM 단일 로컬 서버, 호출 간 rate-limit 불필요)
        # code 칸 등: 예외가 아니라 '내용 없음'으로 비운 거면 정상 — 그대로 반환
        if ($AllowEmpty -and -not $failed) { return "" }
        # 빈 응답/예외 = 런너 죽음 의심 → 선택된 엔진 회복 대기 후 재시도
        if ($i -lt $Retries) {
            if (-not (Wait-LLMReady)) { break }
        }
    }
    return ""
}

function Get-LLConceptSlots {
    param(
        [Parameter(Mandatory)][string]$ConceptName,
        [Parameter(Mandatory)][string]$NoteContext,
        [Parameter(Mandatory)][scriptblock]$LLMInvoker
    )
    # 한 번에 5칸 JSON 대신, 칸 하나씩 plain-text 로 채운다(작은 모델 안정성↑).
    $ctx  = "학습 노트:`n---`n$NoteContext`n---`n"
    $rule = " 마크다운 헤딩(#) 금지. 학습자 1인칭 한국어. 강의 원문 복붙 금지. 사족/머리말 없이 본문만 출력."

    $why      = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt ($ctx + "개념 '$ConceptName' 을(를) 왜 배우게 됐는지 배경을 2~3문장으로 써라." + $rule)
    $confused = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt ($ctx + "개념 '$ConceptName' 에서 처음에 헷갈렸거나 오해했던 점을 2~3문장으로 써라." + $rule)
    $code     = Get-LLFieldText -LLMInvoker $LLMInvoker -AllowEmpty -Prompt ($ctx + "개념 '$ConceptName' 의 핵심을 보여주는 코드 예시'만' 출력하라. 반드시 백틱3개로 감싼 코드 블록 형태로. 출력 주석은 실제 값으로. 노트에 코드 근거가 없으면 아무것도 쓰지 마라.")
    $result   = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt ($ctx + "개념 '$ConceptName' 의 코드/실습 결과와 그 해석을 2~3문장으로 써라." + $rule)
    $summary  = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt ($ctx + "개념 '$ConceptName' 에서 최종적으로 정리된 이해를 2~3문장으로 써라." + $rule)

    if (-not $summary.Trim()) {
        $alt = @($result, $why, $confused | Where-Object { $_.Trim() } | Select-Object -First 1)
        $summary = if ($alt) { [string]$alt } else { '정리 필요.' }
    }
    return [pscustomobject]@{ why = $why; confused = $confused; code = $code; result = $result; summary = $summary }
}

function Get-LLOverallReview {
    param(
        [Parameter(Mandatory)][string]$NoteContent,
        [Parameter(Mandatory)][string[]]$ConceptNames,
        [Parameter(Mandatory)][scriptblock]$LLMInvoker
    )
    $list = ($ConceptNames -join ", ")
    # 총평도 칸 하나씩 plain-text 로 채운다.
    $ctx  = "학습 노트:`n---`n$NoteContent`n---`n오늘 다룬 개념들: $list`n"
    $rule = " 마크다운 헤딩 금지. 학습자 1인칭 한국어. 짧고 구체적으로. 사족 없이 본문만 출력."

    $learned = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt ($ctx + "'오늘 전체에서 배운 것'을 2~3문장으로 써라." + $rule)
    $caution = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt ($ctx + "'다음에 조심할 것'을 2~3문장으로 써라." + $rule)
    $review  = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt ($ctx + "'다음에 복습하거나 더 알아볼 주제'를 2~3문장으로 써라." + $rule)

    $fill = @($learned, $review, $caution | Where-Object { $_.Trim() } | Select-Object -First 1)
    $fillStr = if ($fill) { [string]$fill } else { '정리 필요.' }
    if (-not $learned.Trim()) { $learned = $fillStr }
    if (-not $caution.Trim()) { $caution = $fillStr }
    if (-not $review.Trim())  { $review  = $fillStr }
    return [pscustomobject]@{ learned = $learned; caution = $caution; review = $review }
}

function New-LLOutlineFromSlots {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][object[]]$Concepts,
        [Parameter(Mandatory)][object]$Review,
        [string[]]$Tags = @()
    )
    function _slot([string]$v, [string]$default = '정리 필요.') {
        $t = ([string]$v).Trim()
        if (-not $t) { return $default }
        return $t
    }

    $tagsYaml = if ($Tags.Count) { '["' + ($Tags -join '","') + '"]' } else { '[]' }
    $safeTitle = $Title -replace '"', "'"

    $sb = [System.Collections.Generic.List[string]]::new()
    $sb.Add('---')
    $sb.Add("title: `"$safeTitle`"")
    $sb.Add("date: $Date")
    $sb.Add('draft: true')
    $sb.Add("categories: [`"$Section`"]")
    $sb.Add("tags: $tagsYaml")
    $sb.Add("description: `"$safeTitle 학습 정리`"")
    $sb.Add('---')
    $sb.Add('')

    for ($i = 0; $i -lt $Concepts.Count; $i++) {
        $c = $Concepts[$i]; $s = $c.Slots
        $sb.Add(("## {0}. {1}" -f ($i + 1), $c.Name))
        $sb.Add('')
        $sb.Add('### 왜 이걸 보게 됐나');   $sb.Add((_slot $s.why));               $sb.Add('')
        $sb.Add('### 내가 헷갈린 지점');    $sb.Add((_slot $s.confused));          $sb.Add('')
        $sb.Add('### 시도한 코드 / 예시');  $sb.Add((_slot $s.code '예시 없음.'));  $sb.Add('')
        $sb.Add('### 결과와 해석');        $sb.Add((_slot $s.result));            $sb.Add('')
        $sb.Add('### 정리된 이해');        $sb.Add((_slot $s.summary));           $sb.Add('')
    }

    $sb.Add('## 총평'); $sb.Add('')
    $sb.Add('### 오늘 전체에서 배운 것'); $sb.Add((_slot $Review.learned)); $sb.Add('')
    $sb.Add('### 다음에 조심할 것');     $sb.Add((_slot $Review.caution)); $sb.Add('')
    $sb.Add('### 다음 복습 주제');       $sb.Add((_slot $Review.review));  $sb.Add('')
    $sb.Add('> 🤖 이 글은 AI와 블로그 주인의 합작으로 작성되었습니다!')
    $sb.Add('> This post was created collaboratively by AI and the blog owner.')

    $body = ($sb -join "`n")
    $body = Add-LLTableOfContents -Body $body
    $body = Repair-LLMarkdownCodeFences -Content $body
    $body = $body -replace "^﻿", ""
    return ($body.TrimEnd() + "`n")
}

function Get-LLDailyTitle {
    param(
        [AllowEmptyString()][string]$Candidate = "",
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][ValidateSet("am", "pm")][string]$Half,
        [string[]]$TopicLabels = @()
    )

    $halfKo = if ($Half -eq "am") { "오전" } else { "오후" }
    $raw = if ($null -eq $Candidate) { "" } else { [string]$Candidate }
    $hadLineBreak = $raw -match '[\r\n]'
    $text = $raw -replace '[\r\n\t]+', ' '
    $text = $text -replace '\s{2,}', ' '
    $text = $text -replace '^[\s"''`#*\-]+', ''
    $text = $text -replace '^(?i)(?:제목\s*[:：]\s*)', ''
    $text = $text -replace '^(?i)(?:오늘\s*)?(?:오전|오후)(?:\s*학습)?\s*[,|:：\-]+\s*', ''
    $text = $text -replace '^(?i)\d{4}-\d{2}-\d{2}\s*(?:오전|오후)?\s*[,|:：\-]*\s*', ''
    $text = $text -replace '(?i)(정리했습니다|정리하였다|정리함|배웠습니다|살펴봤습니다)[.!。]*\s*$', ''
    $text = $text.Trim().Trim('"').Trim("'").Trim()

    $labels = @($TopicLabels | ForEach-Object {
        ([string]$_ -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim().Trim('#').Trim()
    } | Where-Object { $_ -and $_ -notmatch '^(총평|목차)$' } | Select-Object -First 3)
    $fallback = if ($labels.Count -gt 0) { $labels[0] } else { "오늘 배운 핵심" }
    if ($labels.Count -gt 1 -and (($labels[0].Length + $labels[1].Length + 3) -le 40)) {
        $fallback = "$($labels[0]) · $($labels[1])"
    }
    $fallback = $fallback.Trim()

    # 모델이 문단을 반환했거나 너무 길면 첫 번째 섹션 제목으로 되돌린다.
    # 제목은 검색 결과와 카드 목록에서 한 줄로 읽히는 것이 우선이다.
    $useFallback = $hadLineBreak -or $text.Length -gt 64 -or $text.Length -lt 4 -or $text -match '(?i)학습 노트|정리 필요'
    if ($useFallback) { $text = $fallback }
    if ($text.Length -gt 52) {
        $short = (($text -split '\s*(?:[:：,，;；]|그리고|및)\s*')[0]).Trim()
        if ($short.Length -ge 8) { $text = $short }
    }
    if ($text.Length -gt 52) { $text = $text.Substring(0, 52).TrimEnd() }
    if (-not $text) { $text = $fallback }

    return ("{0} 학습 | {1}" -f $halfKo, $text)
}

function Repair-LLDailyFrontMatterTitle {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$Date = "",
        [ValidateSet("", "am", "pm")][string]$Half = ""
    )
    if (-not $Half) { return $Content }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Content -split "`r?`n")) { $lines.Add($line) }
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne "---") { return $Content }

    $fmEnd = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") { $fmEnd = $i; break }
    }
    if ($fmEnd -lt 1) { return $Content }
    $titleIdx = -1
    for ($i = 1; $i -lt $fmEnd; $i++) {
        if ($lines[$i] -match '^\s*title:\s*') { $titleIdx = $i; break }
    }
    if ($titleIdx -lt 0) { return $Content }

    $titleParts = [System.Collections.Generic.List[string]]::new()
    $titleParts.Add(($lines[$titleIdx] -replace '^\s*title:\s*', ''))
    $nextKey = $fmEnd
    for ($i = $titleIdx + 1; $i -lt $fmEnd; $i++) {
        if ($lines[$i] -match '^\s*(date|draft|categories|tags|description|public_policy|ai_assisted|ai_model|source_):') {
            $nextKey = $i
            break
        }
        $titleParts.Add($lines[$i])
    }
    $candidate = (($titleParts -join ' ') -replace '^\s*"', '' -replace '"\s*$', '').Trim()
    $dateValue = $Date
    foreach ($line in $lines[1..($fmEnd - 1)]) {
        if ($line -match '^\s*date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})') { $dateValue = $Matches[1]; break }
    }
    $labels = [System.Collections.Generic.List[string]]::new()
    for ($i = $fmEnd + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s+(.+?)\s*$' -and $lines[$i] -notmatch '^###') {
            $h = $Matches[1].Trim()
            if ($h -notmatch '^(목차|총평)$') {
                $h = $h -replace '^\d+[.)]\s*', ''
                $labels.Add($h)
            }
        }
    }
    $newTitle = Get-LLDailyTitle -Candidate $candidate -Date $dateValue -Half $Half -TopicLabels @($labels)
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $titleIdx) {
            $out.Add(('title: "' + ($newTitle -replace '"', "'") + '"'))
            continue
        }
        if ($i -gt $titleIdx -and $i -lt $nextKey) { continue }
        $out.Add($lines[$i])
    }
    return ($out -join "`n")
}

function New-LLDailyPost {
    # 하루 오전/오후 합본 글 빌더. 노트 1개 = 섹션 1개 (### 무엇을 배웠나/헷갈렸던 점/정리된 이해).
    # 2026-06-08 수동 합본(시범 2편)과 동일 양식.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][ValidateSet("am","pm")][string]$Half,
        [Parameter(Mandatory)][object[]]$Sections,   # @{Heading;Learned;Confused;Code;Understood}
        [Parameter(Mandatory)][object]$Review,        # @{learned;caution;review}
        [string[]]$Tags = @(),
        [string]$Description = ""
    )
    function _s([string]$v, [string]$default = '정리 필요.') {
        $t = ([string]$v).Trim(); if (-not $t) { return $default }; return $t
    }
    $halfKo = if ($Half -eq "am") { "오전" } else { "오후" }
    $topicLabels = @($Sections | ForEach-Object { $_.Heading })
    $cleanTitle = Get-LLDailyTitle -Candidate $Title -Date $Date -Half $Half -TopicLabels $topicLabels
    $safeTitle = $cleanTitle -replace '"', "'"
    if (-not $Description) { $Description = "$Date $halfKo 학습 정리" }
    $safeDesc = $Description -replace '"', "'"
    $tagsYaml = if ($Tags.Count) { '["' + (($Tags | Select-Object -Unique) -join '","') + '"]' } else { '[]' }

    $sb = [System.Collections.Generic.List[string]]::new()
    $sb.Add('---')
    $sb.Add("title: `"$safeTitle`"")
    $sb.Add("date: $Date")
    $sb.Add('draft: false')
    $sb.Add('categories: ["learning"]')
    $sb.Add("tags: $tagsYaml")
    $sb.Add("description: `"$safeDesc`"")
    $sb.Add('ai_assisted: true')
    $sb.Add('ai_model: "local-llm"')
    $sb.Add('---')
    $sb.Add('')

    for ($i = 0; $i -lt $Sections.Count; $i++) {
        $sec = $Sections[$i]
        $sb.Add(("## {0}. {1}" -f ($i + 1), ($sec.Heading -replace '"', "'")))
        $sb.Add('')
        $sb.Add('### 무엇을 배웠나');   $sb.Add((_s $sec.Learned));    $sb.Add('')
        $sb.Add('### 헷갈렸던 점');     $sb.Add((_s $sec.Confused));   $sb.Add('')
        $sb.Add('### 정리된 이해');     $sb.Add((_s $sec.Understood)); $sb.Add('')
        $code = ([string]$sec.Code).Trim()
        if ($code) { $sb.Add($code); $sb.Add('') }
    }

    $sb.Add('## 총평'); $sb.Add('')
    $sb.Add("### 오늘 $halfKo 전체에서 배운 것"); $sb.Add((_s $Review.learned)); $sb.Add('')
    $sb.Add('### 다음에 조심할 것');             $sb.Add((_s $Review.caution)); $sb.Add('')
    $sb.Add('### 다음 복습 주제');               $sb.Add((_s $Review.review));  $sb.Add('')
    $sb.Add('> 🤖 이 글은 AI와 블로그 주인의 합작으로 작성되었습니다!')
    $sb.Add('> This post was created collaboratively by AI and the blog owner.')

    $body = ($sb -join "`n")
    $body = Add-LLTableOfContents -Body $body
    $body = Repair-LLMarkdownCodeFences -Content $body
    $body = Repair-LLIndentedCodeFences -Content $body
    $body = $body -replace "^﻿", ""
    return ($body.TrimEnd() + "`n")
}

function Get-LLDraftEditorialProfile {
    param(
        $Row,
        [string]$Section = ""
    )

    $category = (Get-LLRowProp $Row "source_category").ToLowerInvariant()
    $sourceType = (Get-LLRowProp $Row "source_type").ToLowerInvariant()
    $sectionKey = $Section.Trim().ToLowerInvariant()
    if (-not $sectionKey) {
        $sourcePath = (Get-LLRowProp $Row "source_path") -replace "\\", "/"
        if ($sourcePath -match '(?i)(?:^|/)04_blog_drafts/([^/]+)/') { $sectionKey = $Matches[1].ToLowerInvariant() }
    }

    # 사용자가 직접 작성한 글(컨트롤센터 '직접 작성')은 학습 데일리용 구조 게이트
    # (총평/필수섹션)를 강제하지 않는다. 사진·음악 등 자유 형식이므로 목차 + QA 기본만.
    # section(learning/projects) 분기보다 먼저 본다 → 폴더 위치와 무관하게 관대한 기준 적용.
    if ($category -in @("personal_post", "personal-thinking", "personal_thinking", "personal")) {
        return [pscustomobject]@{
            key = "personal_post"; label = "POST"; summaryRequired = $false; minGroups = 0; requiredGroups = @()
        }
    }

    # category를 section보다 먼저 본다. ai-research가 learning 폴더에 놓여도
    # 리서치 기준을 적용하고, 오래된 registry 행에도 동일한 판정을 유지한다.
    if ($category -in @("research", "ai-research") -or $sectionKey -eq "research") {
        return [pscustomobject]@{
            key = "research"; label = "RESEARCH"; summaryRequired = $false; minGroups = 4
            requiredGroups = @(
                [pscustomobject]@{ label = "요약/핵심"; pattern = "한눈에|요약|핵심" }
                [pscustomobject]@{ label = "자료/근거"; pattern = "자료|근거|출처|참고" }
                [pscustomobject]@{ label = "실행/적용"; pattern = "실험|실행|적용|재현|운영" }
                [pscustomobject]@{ label = "한계/주의"; pattern = "한계|주의|불확실|검증" }
                [pscustomobject]@{ label = "구조/구성"; pattern = "구조|구성|아키텍처|파이프라인" }
            )
        }
    }
    if ($category -in @("projects", "team_project", "dev") -or $sectionKey -in @("projects", "dev")) {
        return [pscustomobject]@{
            key = "project"; label = "PROJECT"; summaryRequired = $false; minGroups = 3
            requiredGroups = @(
                [pscustomobject]@{ label = "문제/목표"; pattern = "문제|목표|요구사항|배경" }
                [pscustomobject]@{ label = "구조/결정"; pattern = "구조|아키텍처|설계|결정|구성" }
                [pscustomobject]@{ label = "구현/변경"; pattern = "구현|개발|변경|코드|기능" }
                [pscustomobject]@{ label = "검증/결과"; pattern = "검증|테스트|결과|확인|QA" }
                [pscustomobject]@{ label = "한계/다음 단계"; pattern = "한계|다음|후속|개선|남은" }
            )
        }
    }
    if ($category -in @("practice_notebook", "practice") -or $sectionKey -eq "practice") {
        return [pscustomobject]@{
            key = "practice"; label = "PRACTICE"; summaryRequired = $false; minGroups = 4
            requiredGroups = @(
                [pscustomobject]@{ label = "목표/준비"; pattern = "목표|준비|환경|준비물" }
                [pscustomobject]@{ label = "단계/실행"; pattern = "단계|실행|실습|절차|과정" }
                [pscustomobject]@{ label = "결과/검증"; pattern = "결과|검증|확인|출력|관찰" }
                [pscustomobject]@{ label = "실패/배운 점"; pattern = "실패|오류|배운|교훈|원인" }
                [pscustomobject]@{ label = "다음 연습"; pattern = "다음|복습|연습|개선" }
            )
        }
    }
    if ($category -in @("goals", "goal") -or $sectionKey -eq "goals") {
        return [pscustomobject]@{
            key = "goal"; label = "GOAL"; summaryRequired = $false; minGroups = 4
            requiredGroups = @(
                [pscustomobject]@{ label = "목표"; pattern = "목표|목적|달성할 것" }
                [pscustomobject]@{ label = "현재 상태"; pattern = "현재|현황|상태|진척" }
                [pscustomobject]@{ label = "실행 계획"; pattern = "계획|실행|일정|단계|우선순위" }
                [pscustomobject]@{ label = "성공 기준"; pattern = "성공 기준|완료 조건|측정|판정" }
                [pscustomobject]@{ label = "다음 행동"; pattern = "다음 행동|다음 단계|후속|리뷰" }
            )
        }
    }
    if ($category -in @("daily_merged", "personal_note", "chat_export", "intake_note", "web_note", "learning") -or $sectionKey -eq "learning" -or $sourceType -in @("personal_note", "chat_export")) {
        return [pscustomobject]@{
            key = "learning"; label = "LEARNING"; summaryRequired = $true; minGroups = 0; requiredGroups = @()
        }
    }
    return [pscustomobject]@{
        key = "generic"; label = "GENERAL"; summaryRequired = $false; minGroups = 0; requiredGroups = @()
    }
}

function Get-LLDraftQualityIssues {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        $Row,
        [string]$Section = ""
    )
    $profile = Get-LLDraftEditorialProfile -Row $Row -Section $Section
    $issues = [System.Collections.Generic.List[string]]::new()
    $fenceCount = ([regex]::Matches($Content, '(?m)^\s*```')).Count
    if (($fenceCount % 2) -ne 0) { $issues.Add("odd code fence count") }
    $fenceOpen = $false
    $fenceIndent = 0
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -notmatch '^(\s*)```') { continue }
        $indent = $Matches[1].Length
        if (-not $fenceOpen) {
            $fenceOpen = $true
            $fenceIndent = $indent
        } else {
            if ($fenceIndent -gt 0 -and $indent -lt $fenceIndent) {
                $issues.Add("mismatched indented code fence")
                break
            }
            $fenceOpen = $false
            $fenceIndent = 0
        }
    }
    if ($Content -match '(?m)#\s*(출력|결과):\s*$') { $issues.Add("empty output/result comment") }
    # front matter 영역(맨 위 ---~---) 이후, 목차 구분선 1개는 허용.
    # 본문에 추가 '---'가 또 나오면(목차 구분선 외) front matter 누출로 간주.
    # 코드펜스 안의 '---'(SQL 주석 구분선 등)는 세지 않음 (오탐 방지)
    $inFenceD = $false; $allDelims = 0
    foreach ($dl in ($Content -split "`r?`n")) {
        if ($dl -match '^\s*```') { $inFenceD = -not $inFenceD; continue }
        if (-not $inFenceD -and $dl -match '^---\s*$') { $allDelims++ }
    }
    $allowedDelims = 2   # front matter open/close
    if ($Content -match '(?ms)^##\s+목차\s*$.*?^---\s*$') { $allowedDelims = 3 }  # + 목차 구분선
    if ($allDelims -gt $allowedDelims) { $issues.Add("extra front matter delimiter") }
    # source_id/note_date/mode/model은 등록 초안의 front matter에 남을 수 있다.
    # front matter를 제외한 본문에서만 내부 메타데이터 누출로 판정한다.
    $bodyForLeakCheck = $Content
    if ($Content -match '(?s)^---\s*\r?\n.*?\r?\n---\s*\r?\n(.*)$') { $bodyForLeakCheck = $Matches[1] }
    if ($bodyForLeakCheck -match '(?m)^\s*(source_id|note_date|mode|model):\s*') { $issues.Add("internal metadata") }
    if ($Content -match '(?m)^\s*\*\*(title|제목|date|날짜|draft|categories|category|카테고리|범주|tags|태그|description|설명)\*\*\s*:') { $issues.Add("bold metadata block") }
    if ($Content -match '(?ms)^---\s*\r?\n.*?^title:\s*"[^"\r\n]*\r?\n') { $issues.Add("multiline front matter title") }
    $structure = Get-LLArticleStructureStats -Content $Content

    # 목차형 구조 게이트
    $bodyLines = $Content -split "`r?`n"

    # (a) ## 총평은 LearningLog 학습 글에만 필수
    if ($profile.summaryRequired -and -not (Test-LLHasSummarySection -Lines $bodyLines)) {
        $issues.Add("missing 총평 section")
    }

    # (b) 최상위 ## 중복만 차단 (### 면제). 코드펜스 밖, 정규화 후 텍스트 기준.
    $inFence = $false
    $topCounts = @{}
    foreach ($line in $bodyLines) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^##\s+(.+?)\s*$' -and $line -notmatch '^###') {
            $h = $Matches[1].Trim()
            $h = $h -replace '^\*\*(.+?)\*\*$', '$1'
            $h = $h.Trim().TrimEnd(":").TrimEnd("?").Trim()
            $h = $h -replace '\s+', ' '
            if ($topCounts.ContainsKey($h)) { $topCounts[$h]++ } else { $topCounts[$h] = 1 }
        }
    }
    $dupTop = @()
    foreach ($k in $topCounts.Keys) { if ($topCounts[$k] -gt 1) { $dupTop += ("{0}={1}" -f $k, $topCounts[$k]) } }
    if ($dupTop.Count -gt 0) { $issues.Add("repeated top-level ## headings: " + ($dupTop -join ", ")) }

    # (c) ## 목차 권장 (자동주입이 항상 넣으므로 정상 경로선 통과)
    if ($Content -notmatch '(?m)^##\s+목차\s*$') { $issues.Add("missing 목차 section") }

    # (c-2) 분야별 핵심 섹션. 제목 표현은 어느 정도 허용하되, 한 분야의
    # 기본 흐름이 통째로 빠진 글은 승인 전에 다시 보게 한다.
    if ($profile.requiredGroups.Count -gt 0) {
        $topHeadingText = (($bodyLines | Where-Object { $_ -match '^##\s+(.+?)\s*$' -and $_ -notmatch '^###' }) -join "`n")
        $matched = 0
        $missingLabels = [System.Collections.Generic.List[string]]::new()
        foreach ($group in @($profile.requiredGroups)) {
            if ($topHeadingText -match ("(?i)" + $group.pattern)) { $matched++ } else { $missingLabels.Add($group.label) }
        }
        if ($matched -lt [int]$profile.minGroups) {
            $issues.Add(("missing {0} sections: {1}" -f $profile.key, ($missingLabels -join ", ")))
        }
    }

    # (d) 합쳐진 제목 검사 유지
    if ([int]$structure.combined -gt 0) { $issues.Add("combined outline heading") }

    # (e) 미완성 플레이스홀더 차단 — LLM 이 비운 섹션 (New-LLOutlineFromSlots 기본값 '정리 필요.')
    if ($Content -match '정리 필요\.') { $issues.Add("placeholder content (정리 필요)") }

    # (f) 제너릭 제목 차단 — front matter title 이 "학습 노트" 면 미작성으로 간주
    if ($Content -match '(?m)^\s*title:\s*"?학습 노트"?\s*$') { $issues.Add("generic title (학습 노트)") }
    $frontTitle = ""
    if ($Content -match '(?m)^\s*title:\s*"?(.+?)"?\s*$') { $frontTitle = $Matches[1].Trim() }
    if ($frontTitle -match '^[a-z0-9]+(?:[-_][a-z0-9]+){1,}$') { $issues.Add("generic title (slug)") }

    # (g) 잘린 문장 차단 — 코드펜스 밖 본문 문단이 한국어 연결어미/관형형으로 끝난 뒤
    #     빈 줄+heading 또는 문서 끝이 오면 중간에 잘린 것으로 간주.
    #     ('완료','필요' 같은 명사 종결 요약문 오탐 방지를 위해 연결형 어미로 한정)
    $inFenceT = $false
    for ($li = 0; $li -lt $bodyLines.Count; $li++) {
        $ln = $bodyLines[$li]
        if ($ln -match '^\s*```') { $inFenceT = -not $inFenceT; continue }
        if ($inFenceT) { continue }
        $t = $ln.Trim()
        if ($t.Length -lt 15) { continue }
        if ($t -match '^[#>\-\*\|]' ) { continue }   # heading/list/quote/table 제외
        # 연결어미/관형형으로 끝나면 잇따라 내용이 와야 함 (예: ~연결할, ~위한, ~하여, ~하고, ~되어, ~하는, ~에서)
        if ($t -notmatch '(할|하는|되는|위한|대한|하여|하고|되어|이며|에서|으로|면서|또는|그리고)$') { continue }
        $next = ""
        for ($nj = $li + 1; $nj -lt $bodyLines.Count; $nj++) {
            if ($bodyLines[$nj].Trim() -ne "") { $next = $bodyLines[$nj].Trim(); break }
        }
        if ($next -eq "" -or $next -match '^#') { $issues.Add("truncated sentence"); break }
    }

    return @($issues)
}

function ConvertTo-LLPublishMarkdown {
    param(
        [Parameter(Mandatory)][string]$Content,
        [string]$ModelName = "local-llm"
    )
    $content = Remove-ExtraHugoFrontMatter -Text $Content
    if ($content -notmatch "^---") { return $content }
    $lines = $content -split "`n"
    $fmEnd = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") { $fmEnd = $i; break }
    }
    if ($fmEnd -eq -1) { return $content }

    $fm = [System.Collections.Generic.List[string]]::new()
    $hasAi = $false
    foreach ($ln in $lines[1..($fmEnd - 1)]) {
        $s = $ln.Trim()
        if ($s.StartsWith("draft:")) { $fm.Add("draft: false"); continue }
        if ($s -match '^date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})') {
            $fm.Add("date: $($Matches[1])")
            continue
        }
        if ($s.StartsWith("date:")) {
            $fm.Add("date: $(Get-Date -Format 'yyyy-MM-dd')")
            continue
        }
        if ($s.StartsWith("source_id:")) { continue }
        if ($s.StartsWith("note_date:")) { continue }
        if ($s.StartsWith("model:")) { continue }
        if ($s.StartsWith("mode:")) { continue }
        if ($s.StartsWith("public_policy:")) { continue }
        if ($s.StartsWith("ai_assisted:")) { $hasAi = $true }
        $fm.Add($ln)
    }
    if (-not $hasAi) {
        $fm.Add("ai_assisted: true")
        $fm.Add("ai_model: `"$ModelName`"")
    }

    $body = [System.Collections.Generic.List[string]]::new()
    for ($i = $fmEnd + 1; $i -lt $lines.Count; $i++) {
        $s = $lines[$i].Trim()
        if ($s.StartsWith("source_id:") -or $s.StartsWith("note_date:") -or $s.StartsWith("model:") -or $s.StartsWith("mode:")) { continue }
        $body.Add($lines[$i])
    }
    return "---`n" + ($fm -join "`n") + "`n---`n" + (($body -join "`n").TrimStart()) + "`n"
}

# ─────────────────────────────────────────────────────────
# Preview / Approve 안전장치 (Preview First, Publish Later)
# ─────────────────────────────────────────────────────────

function Get-LLRowProp {
    # Get-LLProp 의 null-safe 래퍼 (Row 가 null 이어도 OK)
    param($Row, [Parameter(Mandatory)][string]$Name, [string]$Default = "")
    if ($null -eq $Row) { return $Default }
    return (Get-LLProp -Row $Row -Name $Name -Default $Default)
}

function ConvertTo-LLHtmlEncoded {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
    return $t
}

function Get-LLDraftSourceId {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    # 초안 식별자는 YAML front matter에서만 읽는다. 본문/코드 예시의 source_id는
    # 원본 자료 인용일 수 있으므로 레지스트리 연결 키로 사용하면 안 된다.
    $frontMatterMatch = [regex]::Match(
        $Content,
        '\A(?:\uFEFF)?---[ \t]*\r?\n(?<yaml>.*?)\r?\n---[ \t]*(?:\r?\n|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $frontMatterMatch.Success) { return "" }

    if ($frontMatterMatch.Groups["yaml"].Value -match '(?m)^[ \t]*source_id[ \t]*:[ \t]*(\S+)') {
        return $Matches[1].Trim().Trim('"').Trim("'")
    }
    return ""
}

function Get-LLDraftTitle {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    if ($Content -match '(?m)^\s*title:\s*"?(.+?)"?\s*$') { return $Matches[1].Trim() }
    return ""
}

function Resolve-LLOriginalNotePath {
    param($Row)
    $p = Get-LLRowProp $Row "source_path"
    if (-not $p) { return "" }
    return (Resolve-LLSourcePath $p)
}

function Get-LLSourceContentDate {
    param($Row, [string]$Fallback = "")

    foreach ($field in @("source_path", "file_name", "topic")) {
        $value = Get-LLRowProp $Row $field
        if ($value -match '(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)') {
            return $Matches[1]
        }
    }

    $path = Resolve-LLOriginalNotePath $Row
    if ($path -and (Test-Path -LiteralPath $path)) {
        $head = ((Read-LLText $path) -split "`r?`n" | Select-Object -First 40) -join "`n"
        if ($head -match '(?m)^\s*(?:-\s*)?date:\s*"?(\d{4}-\d{2}-\d{2})"?\s*$') {
            return $Matches[1]
        }
    }

    if ($Fallback) { return $Fallback }
    return (Get-LLRowProp $Row "date_added")
}

function Get-LLDailyMemberIndex {
    # daily 합본의 "원본 노트 묶음" 미리보기용 인덱스.
    # key = "yyyy-MM-dd|am" / "...|pm"  ->  topic 순 정렬된 멤버 행 리스트.
    # 렌더당 daily 초안마다 전체 레지스트리(수백 행)를 파일 I/O로 재스캔하던 O(N×M)을,
    # 렌더당 1회 사전계산으로 대체한다.
    param([array]$Rows = @())
    if ($Rows.Count -eq 0) { $Rows = @(Get-LLRegistryRows) }
    $memberTypes = @("personal_note","chat_export","intake_note","web_note")
    $idx = @{}
    foreach ($r in $Rows) {
        $st = (Get-LLProp $r "source_type").ToLowerInvariant()
        if ($st -notin $memberTypes) { continue }
        $cdate = Get-LLSourceContentDate -Row $r
        if (-not $cdate) { continue }
        $slot = ""
        $memberTopic = (Get-LLProp $r "topic").ToLowerInvariant()
        if ($memberTopic -match '^(am|pm)-') {
            $slot = $Matches[1]
        } else {
            $sp = Get-LLProp $r "source_path"
            if ($sp -match '(?i)PN_\d{4}-\d{2}-\d{2}_(AM|PM)_') { $slot = $Matches[1].ToLowerInvariant() }
        }
        if (-not $slot) { continue }
        $key = "$cdate|$slot"
        if (-not $idx.ContainsKey($key)) { $idx[$key] = [System.Collections.Generic.List[object]]::new() }
        $idx[$key].Add($r)
    }
    $sorted = @{}
    foreach ($k in @($idx.Keys)) { $sorted[$k] = @($idx[$k] | Sort-Object { Get-LLProp $_ "topic" }) }
    return $sorted
}

function Resolve-LLPreviewOriginalNote {
    param($Row, $MemberIndex = $null)

    $path = Resolve-LLOriginalNotePath $Row
    $category = (Get-LLRowProp $Row "source_category").ToLowerInvariant()
    $topic = Get-LLRowProp $Row "topic"

    if ($category -eq "daily_merged" -and $topic -match '^(\d{4}-\d{2}-\d{2})-(am|pm)-daily$') {
        $date = $Matches[1]
        $slot = $Matches[2].ToLowerInvariant()
        if ($null -ne $MemberIndex) {
            # 사전 구축된 인덱스로 O(1) 조회 — 렌더당 전체 레지스트리 재스캔+파일 head 읽기 제거.
            $key = "$date|$slot"
            $members = if ($MemberIndex.ContainsKey($key)) { @($MemberIndex[$key]) } else { @() }
        } else {
            # 폴백(인덱스 미제공): 기존 방식. 정확하지만 daily 초안이 많으면 매우 느리다.
            $slotLabel = $slot.ToUpperInvariant()
            $slotPattern = "(?i)PN_" + [regex]::Escape($date) + "_" + $slotLabel + "_"
            $rows = @(Get-LLRegistryRows)
            $memberCandidates = @($rows | Where-Object {
                $sourceType = (Get-LLProp $_ "source_type").ToLowerInvariant()
                $sourcePath = Get-LLProp $_ "source_path"
                $memberTopic = (Get-LLProp $_ "topic").ToLowerInvariant()
                $contentDate = Get-LLSourceContentDate -Row $_
                $sourceType -in @("personal_note","chat_export","intake_note","web_note") -and
                $contentDate -eq $date -and
                (
                    $memberTopic.StartsWith("$slot-") -or
                    $sourcePath -match $slotPattern
                )
            })
            $members = @($memberCandidates | Sort-Object { Get-LLProp $_ "topic" })
        }

        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($m in $members) {
            $memberPath = Resolve-LLSourcePath (Get-LLProp $m "source_path")
            if (-not $memberPath -or -not (Test-Path -LiteralPath $memberPath)) { continue }
            $title = Get-LLProp $m "topic"
            if (-not $title) { $title = Split-Path -LeafBase $memberPath }
            $memberRel = Get-LLRelativePath $memberPath
            $memberHeading = "## " + $title
            $memberSourceLine = "출처: " + $memberRel
            $parts.Add($memberHeading)
            $parts.Add("")
            $parts.Add($memberSourceLine)
            $parts.Add("")
            $parts.Add((Read-LLText $memberPath).Trim())
            $parts.Add("")
        }

        if ($parts.Count -gt 0) {
            $header = [System.Collections.Generic.List[string]]::new()
            $header.Add("# 원본 노트 묶음")
            $header.Add("")
            $header.Add("daily 합본 글의 멤버 원본을 모아 보여줍니다.")
            $header.Add("")
            return [pscustomobject]@{
                Path = "daily source bundle"
                Text = (($header + $parts) -join "`n").TrimEnd() + "`n"
            }
        }
    }

    $text = ""
    if ($path -and (Test-Path -LiteralPath $path)) {
        $text = Read-LLText $path
    }
    return [pscustomobject]@{ Path = $path; Text = $text }
}

function Get-LLDraftBadges {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        $Row,
        [Nullable[bool]]$ByproductOverride = $null,
        [string]$Section = ""
    )
    # Preview must also render drafts created before registry registration.
    # Use an explicit empty row so every downstream profile/status lookup stays null-safe.
    $hasRegistryRow = ($null -ne $Row)
    $declaredPolicy = ""
    if ($null -eq $Row) {
        # A draft's own metadata may add a restrictive warning, but it can never
        # grant publication eligibility without a matching registry row.
        $declaredPolicy = (Get-LLNoteField -Content $Content -Name "public_policy").ToLowerInvariant()
        $Row = [pscustomobject]@{
            source_category = ""
            source_type = ""
            public_policy = if ($declaredPolicy -in @("private", "internal-only")) { $declaredPolicy } else { "" }
            status = ""
            source_path = ""
        }
    }
    $profile = Get-LLDraftEditorialProfile -Row $Row -Section $Section
    $issues = @(Get-LLDraftQualityIssues -Content $Content -Row $Row -Section $Section)
    $qaPass = ($issues.Count -eq 0)
    $policy = (Get-LLRowProp $Row "public_policy").ToLowerInvariant()
    $status = (Get-LLRowProp $Row "status").ToLowerInvariant()
    $isApproved = ($status -eq "approved")

    if ($null -ne $ByproductOverride) {
        $isByproduct = [bool]$ByproductOverride
    } else {
        $isByproduct = $false
        if ($Row) {
            $category = (Get-LLProp $Row "source_category").ToLowerInvariant()
            $sourceType = (Get-LLProp $Row "source_type").ToLowerInvariant()
            $isByproduct = (
                $category -ne "daily_merged" -and
                $policy -eq "partial-public" -and
                $sourceType -in @("personal_note", "chat_export", "intake_note", "web_note")
            )
        }
    }

    $policyOk = ($hasRegistryRow -and $policy -in @("public", "partial-public"))
    # A registry intake row is not itself a blog draft. Only generated, pending
    # drafts may receive an approval decision; needs_review is eligible for a
    # human pass when its QA and publication policy are otherwise clean.
    $statusOk = ($hasRegistryRow -and $status -in @("drafted", "needs_review"))
    $canApprove = ($hasRegistryRow -and $qaPass -and $policyOk -and $statusOk -and -not $isByproduct)
    $canRepair = ($hasRegistryRow -and $policyOk -and $statusOk -and -not $isByproduct)

    $approvalReasons = [System.Collections.Generic.List[string]]::new()
    $repairReasons = [System.Collections.Generic.List[string]]::new()
    if (-not $hasRegistryRow) {
        $approvalReasons.Add("registry에 연결된 원본 없음")
        $repairReasons.Add("registry에 연결된 원본 없음")
    }
    if (-not $policyOk) {
        $policyReason = switch ($policy) {
            "private"       { "공개 정책 private"; break }
            "internal-only" { "공개 정책 internal-only"; break }
            default         { "공개 정책 미확인"; break }
        }
        $approvalReasons.Add($policyReason)
        $repairReasons.Add($policyReason)
    }
    if ($hasRegistryRow -and -not $statusOk) {
        $statusReason = if ($status) { "승인 가능한 초안 상태가 아님 ($status)" } else { "registry 초안 상태 미확인" }
        $approvalReasons.Add($statusReason)
        $repairReasons.Add($statusReason)
    }
    if ($isByproduct) {
        $approvalReasons.Add("합본 부산물")
        $repairReasons.Add("합본 부산물")
    }
    if (-not $qaPass) { $approvalReasons.Add("본문 QA 미통과 ($($issues.Count)개)") }

    $badges = [System.Collections.Generic.List[object]]::new()
    if ($canApprove) {
        $badges.Add([pscustomobject]@{ text = "QA PASS"; cls = "ok" })
    } elseif ($qaPass) {
        # Structural checks alone are not an overall QA pass. In particular,
        # private/internal or intake-only records must never look publishable.
        $badges.Add([pscustomobject]@{ text = "본문 구조 확인"; cls = "warn" })
        $badges.Add([pscustomobject]@{ text = "승인 차단"; cls = "danger" })
    } else {
        $badges.Add([pscustomobject]@{ text = "REVIEW NEEDED"; cls = "warn" })
        $joined = ($issues -join " ")
        if ($joined -match 'code fence|mismatched|empty output') { $badges.Add([pscustomobject]@{ text = "CODE FENCE"; cls = "warn" }) }
        if ($joined -match 'front matter delimiter')             { $badges.Add([pscustomobject]@{ text = "FRONTMATTER"; cls = "warn" }) }
        if ($joined -match 'internal metadata|bold metadata')    { $badges.Add([pscustomobject]@{ text = "SOURCE LEAK"; cls = "danger" }) }
        if ($joined -match 'missing 총평|missing 목차|missing (research|project|practice|goal) sections|repeated|combined') { $badges.Add([pscustomobject]@{ text = "STRUCTURE"; cls = "warn" }) }
    }

    switch ($policy) {
        "internal-only"  { $badges.Add([pscustomobject]@{ text = "INTERNAL-ONLY"; cls = "danger" }) }
        "private"        { $badges.Add([pscustomobject]@{ text = "PRIVATE"; cls = "danger" }) }
        "partial-public" { if ($hasRegistryRow) { $badges.Add([pscustomobject]@{ text = "PARTIAL"; cls = "warn" }) } else { $badges.Add([pscustomobject]@{ text = "POLICY UNVERIFIED"; cls = "danger" }) } }
        "public"         { if ($hasRegistryRow) { $badges.Add([pscustomobject]@{ text = "PUBLIC"; cls = "ok" }) } else { $badges.Add([pscustomobject]@{ text = "POLICY UNVERIFIED"; cls = "danger" }) } }
        default          { }
    }
    if (-not $hasRegistryRow) { $badges.Add([pscustomobject]@{ text = "NO REGISTRY"; cls = "danger" }) }

    if ($status -in @("needs_review", "archived", "rejected")) {
        $badges.Add([pscustomobject]@{ text = ("STATUS:" + $status); cls = "warn" })
    }
    if ($isApproved) {
        $badges.Add([pscustomobject]@{ text = "APPROVED"; cls = "approved" })
    }

    if ($isByproduct) {
        $badges.Add([pscustomobject]@{ text = "BYPRODUCT"; cls = "warn" })
    }

    $approvalBlockReason = if ($approvalReasons.Count) { $approvalReasons -join " · " } else { "승인 조건 확인 필요" }
    $repairBlockReason = if ($repairReasons.Count) { $repairReasons -join " · " } else { "자동 패치 조건 확인 필요" }
    return [pscustomobject]@{
        qaPass = $qaPass; canApprove = $canApprove; canRepair = $canRepair
        approvalBlockReason = $approvalBlockReason; repairBlockReason = $repairBlockReason
        isByproduct = $isByproduct; approved = $isApproved; profile = $profile.key; badges = @($badges)
    }
}

function Get-LLPublishedNames {
    # 06_published 의 모든 .md 파일명(소문자)을 HashSet 으로 반환.
    # "이미 발행됨" 판정의 단일 소스 (registry status 는 신뢰 불가).
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pubDir = Get-LLPath "06_published"
    if (Test-Path -LiteralPath $pubDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $pubDir -Recurse -Filter "*.md" -File)) {
            $null = $set.Add($f.Name)
        }
    }
    return $set
}

function Test-LLPathHasReparseAncestor {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or $parent.FullName -eq $cursor) { break }
        $cursor = $parent.FullName
    }
    return $false
}

function Get-LLPublishedBodyIndex {
    param([Parameter(Mandatory)][string]$PublishedDir)
    $index = @{}
    if (-not (Test-Path -LiteralPath $PublishedDir)) { return ,$index }
    if (Test-LLPathHasReparseAncestor -Path $PublishedDir) { throw "발행 보관소 경로에 재분석 지점이 있어 중복 검사를 중단했습니다: $PublishedDir" }
    $root = [IO.Path]::GetFullPath($PublishedDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($file in @(Get-ChildItem -LiteralPath $PublishedDir -Recurse -Filter '*.md' -File | Sort-Object FullName)) {
        if (Test-LLPathHasReparseAncestor -Path $file.FullName) { continue }
        $content = Read-LLText $file.FullName
        $bodyHash = Get-LLMarkdownBodyHash -Content $content
        if (-not $bodyHash -or $index.ContainsKey($bodyHash)) { continue }
        $full = [IO.Path]::GetFullPath($file.FullName)
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $index[$bodyHash] = $full.Substring($root.Length).Replace('\', '/')
    }
    return ,$index
}

function Get-LLPublishLedgerRows {
    param([string]$LogPath = (Get-LLPath '01_registry/publish_ledger.csv'))
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    $reader = [IO.StreamReader]::new($LogPath, [Text.Encoding]::UTF8, $true)
    try { $header = [string]$reader.ReadLine() } finally { $reader.Dispose() }
    $expected = @('draft_path','hugo_target_path','published_date','public_url','status','notes')
    $actual = @($header.TrimStart([char]0xFEFF).Split(',') | ForEach-Object { $_.Trim().Trim('"') })
    if (($actual -join ',') -cne ($expected -join ',')) { throw "publish_ledger.csv 헤더가 기존 계약과 다릅니다: $LogPath" }
    try { return @(Import-Csv -LiteralPath $LogPath -Encoding utf8) }
    catch { throw "발행 결과 원장을 읽지 못했습니다: $($_.Exception.Message)" }
}

function Add-LLPublishLedgerEntry {
    param(
        [Parameter(Mandatory)][string]$DraftPath,
        [Parameter(Mandatory)][string]$HugoTargetPath,
        [Parameter(Mandatory)][string]$Status,
        [string]$PublishedDate = '',
        [string]$PublicUrl = '',
        [string]$SourceId = '',
        [string]$ContentSha256 = '',
        [string]$FailureCode = '',
        [string]$Message = '',
        [string]$DuplicateOf = '',
        [string[]]$CleanupPaths = @(),
        [string]$AttemptId = ([guid]::NewGuid().ToString('N')),
        [string]$LogPath = (Get-LLPath '01_registry/publish_ledger.csv')
    )
    $parent = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $LogPath)) {
        [IO.File]::WriteAllText($LogPath, "draft_path,hugo_target_path,published_date,public_url,status,notes`r`n", [Text.UTF8Encoding]::new($false))
    }
    $null = Get-LLPublishLedgerRows -LogPath $LogPath
    $details = [ordered]@{
        attempt_id = $AttemptId
        attempted_at = [DateTimeOffset]::Now.ToString('o')
        source_id = $SourceId
        content_sha256 = $ContentSha256.ToLowerInvariant()
        failure_code = $FailureCode
        message = if ($Message.Length -gt 1200) { $Message.Substring(0, 1200) } else { $Message }
        duplicate_of = $DuplicateOf
        cleanup_paths = @($CleanupPaths)
    }
    $entry = [pscustomobject]@{
        draft_path = $DraftPath.Replace('\','/')
        hugo_target_path = $HugoTargetPath.Replace('\','/')
        published_date = $PublishedDate
        public_url = $PublicUrl
        status = $Status.Trim().ToLowerInvariant()
        notes = (ConvertTo-Json $details -Depth 4 -Compress)
    }
    $entry | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding utf8 -Append
    return $entry
}

function Get-LLPublishAttemptForDraft {
    param(
        [Parameter(Mandatory)][string]$DraftPath,
        [Parameter(Mandatory)][string]$ContentSha256,
        [AllowNull()][object[]]$Rows = $null
    )
    if ($null -eq $Rows) { $Rows = @(Get-LLPublishLedgerRows) }
    $normalizedPath = $DraftPath.Replace('\','/')
    $matching = @($Rows | Where-Object { [string]::Equals((Get-LLRowProp $_ 'draft_path').Replace('\','/'), $normalizedPath, [StringComparison]::OrdinalIgnoreCase) })
    for ($i = $matching.Count - 1; $i -ge 0; $i--) {
        $row = $matching[$i]
        $details = $null
        try { $details = Get-LLRowProp $row 'notes' | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $rowHash = (Get-LLRowProp $details 'content_sha256').ToLowerInvariant()
        if (-not $rowHash -or $rowHash -ine $ContentSha256.ToLowerInvariant()) { continue }
        return [pscustomobject]@{
            status = (Get-LLRowProp $row 'status').Trim().ToLowerInvariant()
            message = Get-LLRowProp $details 'message'
            failure_code = Get-LLRowProp $details 'failure_code'
            duplicate_of = Get-LLRowProp $details 'duplicate_of'
            attempt_id = Get-LLRowProp $details 'attempt_id'
            hugo_target_path = Get-LLRowProp $row 'hugo_target_path'
            content_sha256 = $rowHash
        }
    }
    return [pscustomobject]@{ status=''; message=''; failure_code=''; duplicate_of=''; attempt_id=''; hugo_target_path=''; content_sha256='' }
}

function Test-LLDraftAlreadyPublished {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Draft,
        $Row,
        $PublishedNames
    )
    if ($PublishedNames -and $PublishedNames.Contains($Draft.Name)) { return $true }
    if ($Row) {
        $status = (Get-LLProp $Row "status").ToLowerInvariant()
        if ($status -eq "published") { return $true }
    }
    return $false
}

function Get-LLDailyMergedDateKeys {
    param([array]$Rows = @())
    if ($Rows.Count -eq 0) { $Rows = @(Get-LLRegistryRows) }
    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Rows) {
        if ((Get-LLProp $r "source_category").ToLowerInvariant() -ne "daily_merged") { continue }
        $rawDate = Get-LLProp $r "date_added"
        $parsed = [datetime]::MinValue
        if ($rawDate -and [datetime]::TryParse($rawDate, [ref]$parsed)) {
            $null = $keys.Add($parsed.ToString("yyyy-MM-dd"))
        }
    }
    return $keys
}

function Test-LLDraftByproduct {
    # 합본 daily 글이 발행 후보가 된 이후, partial-public 개별 노트 초안은
    # preview/approve 후보가 아니라 보관/정리 대상 부산물로 취급한다.
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Draft,
        $Row,
        [System.Collections.Generic.HashSet[string]]$DailyMergedDates = $null
    )
    if (-not $Row) { return $false }
    $category = (Get-LLProp $Row "source_category").ToLowerInvariant()
    if ($category -eq "daily_merged") { return $false }
    # 명시적으로 등록된 개인 글은 chat_export 형식이어도 독립 발행 후보다.
    if ($category -in @("personal_post", "personal-thinking", "personal_thinking", "personal")) { return $false }

    $policy = (Get-LLProp $Row "public_policy").ToLowerInvariant()
    if ($policy -ne "partial-public") { return $false }

    $sourceType = (Get-LLProp $Row "source_type").ToLowerInvariant()
    if ($sourceType -notin @("personal_note", "chat_export", "intake_note", "web_note")) { return $false }

    # 합본이 없는 날짜의 단독 학습 노트는 부산물이 아니라 정상 초안이다.
    if ($null -eq $DailyMergedDates) { $DailyMergedDates = Get-LLDailyMergedDateKeys }
    $rawDate = Get-LLProp $Row "date_added"
    $parsed = [datetime]::MinValue
    if (-not $rawDate -or -not [datetime]::TryParse($rawDate, [ref]$parsed)) { return $false }
    return $DailyMergedDates.Contains($parsed.ToString("yyyy-MM-dd"))
}

function Get-LLDraftDate {
    # 정렬 키. registry date_added(yyyy-MM-dd) 우선, 없으면 파일 LastWriteTime.
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Draft,
        $Row
    )
    if ($Row) {
        $d = Get-LLProp $Row "date_added"
        if ($d) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($d, [ref]$parsed)) { return $parsed }
        }
    }
    return $Draft.LastWriteTime
}

function Resolve-LLDraftRegistryRow {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Draft,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [array]$Rows = @()
    )
    if ($Rows.Count -eq 0) { $Rows = @(Get-LLRegistryRows) }
    $sid = Get-LLDraftSourceId $Content
    if ($sid) {
        $hit = $Rows | Where-Object { (Get-LLProp $_ "source_id") -eq $sid } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return ($Rows | Where-Object { (Get-LLProp $_ "topic") -eq $Draft.BaseName } | Select-Object -First 1)
}

function Resolve-LLSafeDraftPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $root = Get-LLRoot
    $draftsDir = Get-LLPath "04_blog_drafts"
    $candidate = Join-Path $root ($RelativePath -replace "/", "\")
    if (-not (Test-Path -LiteralPath $candidate)) { throw "draft not found: $RelativePath" }
    $full = (Resolve-Path -LiteralPath $candidate).Path
    $draftsFull = (Resolve-Path -LiteralPath $draftsDir).Path
    if (-not $full.StartsWith($draftsFull.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "invalid draft path: $RelativePath"
    }
    if (-not $full.EndsWith(".md", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "invalid draft extension: $RelativePath"
    }
    return $full
}

function Get-LLApprovalLogRows {
    param([string]$LogPath = (Get-LLPath '09_reports\approval_log.csv'))
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    try { return @(Import-Csv -LiteralPath $LogPath -Encoding utf8) }
    catch { throw "승인 기록을 읽지 못했습니다: $($_.Exception.Message)" }
}

function Get-LLApprovalSnapshotStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReadyRoot,
        [Parameter(Mandatory)][string]$ApprovedPath,
        [string]$SourceId = '',
        [string]$Section = '',
        [string]$FileName = '',
        [AllowNull()][object[]]$Rows = $null
    )
    if ($null -eq $Rows) { $Rows = @(Get-LLApprovalLogRows) }
    $readyFull = [IO.Path]::GetFullPath($ReadyRoot).TrimEnd('\', '/')
    $approvedFull = [IO.Path]::GetFullPath($ApprovedPath)
    $prefix = $readyFull + [IO.Path]::DirectorySeparatorChar
    if (-not $approvedFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "승인 해시 대상이 승인 폴더 밖입니다: $ApprovedPath"
    }
    $relative = $approvedFull.Substring($prefix.Length).Replace('\', '/').Normalize([Text.NormalizationForm]::FormC)
    if (-not $FileName) { $FileName = [IO.Path]::GetFileName($approvedFull) }
    if (-not $Section) { $Section = (($relative -split '/')[0]) }

    $matching = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        $recordPath = (Get-LLRowProp $row 'approved_path').Replace('\', '/').Normalize([Text.NormalizationForm]::FormC)
        if ($recordPath) {
            if ([string]::Equals($recordPath, $relative, [StringComparison]::OrdinalIgnoreCase)) { $matching.Add($row) }
            continue
        }
        # Legacy approvals have no path/hash. Keep their identity so we can report
        # that explicit reapproval is needed instead of silently trusting them.
        $sameIdentity = [string]::Equals((Get-LLRowProp $row 'file_name'), $FileName, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals((Get-LLRowProp $row 'section'), $Section, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals((Get-LLRowProp $row 'source_id'), $SourceId, [StringComparison]::OrdinalIgnoreCase)
        if ($sameIdentity) { $matching.Add($row) }
    }
    if ($matching.Count -eq 0) {
        return [pscustomobject]@{ status='missing'; path=$relative; expected_hash=''; actual_hash=(Get-LLHash $approvedFull); record=$null }
    }
    $record = $matching[$matching.Count - 1]
    $recordPath = (Get-LLRowProp $record 'approved_path').Replace('\', '/').Normalize([Text.NormalizationForm]::FormC)
    $expectedHash = (Get-LLRowProp $record 'approved_sha256').ToLowerInvariant()
    $actualHash = Get-LLHash $approvedFull
    if ((Get-LLRowProp $record 'qa_status').Trim().ToUpperInvariant() -ne 'PASS') {
        return [pscustomobject]@{ status='revoked'; path=$relative; expected_hash=$expectedHash; actual_hash=$actualHash; record=$record }
    }
    if (-not $recordPath -or -not $expectedHash) {
        return [pscustomobject]@{ status='unbound'; path=$relative; expected_hash=$expectedHash; actual_hash=$actualHash; record=$record }
    }
    if ($recordPath -ine $relative -or
        (Get-LLRowProp $record 'file_name') -ine $FileName -or
        (Get-LLRowProp $record 'section') -ine $Section -or
        (Get-LLRowProp $record 'source_id') -ine $SourceId -or
        $expectedHash -notmatch '^[a-f0-9]{64}$' -or
        -not $actualHash) {
        return [pscustomobject]@{ status='mismatch'; path=$relative; expected_hash=$expectedHash; actual_hash=$actualHash; record=$record }
    }
    if ($actualHash -ine $expectedHash) {
        return [pscustomobject]@{ status='mismatch'; path=$relative; expected_hash=$expectedHash; actual_hash=$actualHash; record=$record }
    }
    return [pscustomobject]@{ status='match'; path=$relative; expected_hash=$expectedHash; actual_hash=$actualHash; record=$record }
}

function Get-LLReadyPublishCandidates {
    param(
        [string]$ReadyDir = (Get-LLPath '05_ready_to_publish'),
        [string]$PublishedDir = (Get-LLPath '06_published'),
        [string]$BlogRoot = (Join-Path (Split-Path (Get-LLRoot) -Parent) 'Blog'),
        [array]$Rows = @(Get-LLRegistryRows),
        [AllowNull()][array]$ApprovalRows = $null,
        [AllowNull()][array]$LedgerRows = $null,
        [switch]$IncludeBlocked
    )
    if (-not (Test-Path -LiteralPath $ReadyDir)) { return }
    if ($null -eq $ApprovalRows) { $ApprovalRows = @(Get-LLApprovalLogRows) }
    if ($null -eq $LedgerRows) { $LedgerRows = @(Get-LLPublishLedgerRows) }
    $publishedBodyIndex = Get-LLPublishedBodyIndex -PublishedDir $PublishedDir
    $readyFull=[IO.Path]::GetFullPath($ReadyDir).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    foreach ($draft in @(Get-ChildItem -LiteralPath $ReadyDir -Filter '*.md' -Recurse -File | Sort-Object FullName)) {
        # 링크/정션을 통해 승인 폴더 밖으로 빠지는 파일은 후보가 아니다.
        $ancestor=$draft; $linked=$false
        while ($ancestor -and $ancestor.FullName.TrimEnd('\','/') -ne $readyFull.TrimEnd('\','/')) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked=$true; break }
            $ancestor=if ($ancestor -is [IO.FileInfo]) { $ancestor.Directory } else { $ancestor.Parent }
        }
        if ($linked) { continue }
        $content=Read-LLText $draft.FullName
        $sid=Get-LLDraftSourceId $content
        if ($sid) {
            $matches=@($Rows | Where-Object { (Get-LLRowProp $_ 'source_id') -eq $sid })
        } else {
            $matches=@($Rows | Where-Object { (Get-LLRowProp $_ 'topic') -eq $draft.BaseName })
            if ($matches.Count -ne 1) {
                $matches=@($Rows | Where-Object { (Get-LLRowProp $_ 'file_name') -eq $draft.Name })
            }
        }
        if ($matches.Count -ne 1) { continue }
        $row=$matches[0]
        if ((Get-LLRowProp $row 'status').Trim().ToLowerInvariant() -ne 'approved' -or -not (Test-LLPublishableSource $row)) { continue }
        $relative=$draft.FullName.Substring($readyFull.Length) -replace '\\','/'
        if ($relative -notmatch '^[^/]+/[^/]+\.md$') { continue }
        $section=($relative -split '/')[0]
        $sourceId = Get-LLRowProp $row 'source_id'
        $fileHash = Get-LLHash $draft.FullName
        $bodyHash = Get-LLMarkdownBodyHash -Content $content
        $ledgerAttempt = Get-LLPublishAttemptForDraft -DraftPath ('05_ready_to_publish/' + $relative) -ContentSha256 $fileHash -Rows $LedgerRows
        $duplicateOf = ''
        if ($bodyHash -and $publishedBodyIndex.ContainsKey($bodyHash)) { $duplicateOf = '06_published/' + [string]$publishedBodyIndex[$bodyHash] }
        if ($ledgerAttempt.status -in @('duplicate_published','published') -and -not $duplicateOf) {
            $duplicateOf = [string]$ledgerAttempt.duplicate_of
            if (-not $duplicateOf) { $duplicateOf = [string]$ledgerAttempt.hugo_target_path }
            if (-not $duplicateOf) { $duplicateOf = '발행 원장에 성공 기록 있음' }
            if ($duplicateOf -notmatch '^(06_published/|content/)') { $duplicateOf = '06_published/' + $duplicateOf }
        }
        if ($duplicateOf) {
            if (-not $IncludeBlocked) { continue }
            $titleMatch=[regex]::Match($content,'(?m)^title:\s*(.*?)\s*$')
            $title=if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim('"',"'") } else { $draft.BaseName }
            [pscustomobject]@{
                path=$relative; full_path=$draft.FullName; title=$title; section=$section; hash=$fileHash
                source_id=$sourceId; registry_status=(Get-LLRowProp $row 'status')
                can_publish=$false; approval_status='duplicate'
                approval_reason="이미 발행된 본문과 같아 발행을 막았습니다: $duplicateOf"
                cleanup_eligible=$true; duplicate_of=$duplicateOf; body_sha256=$bodyHash
                last_attempt_status=$ledgerAttempt.status; last_attempt_message=$ledgerAttempt.message
            }
            continue
        }
        if ($ledgerAttempt.status -in @('reconcile_required','needs_review')) {
            if (-not $IncludeBlocked) { continue }
            $titleMatch=[regex]::Match($content,'(?m)^title:\s*(.*?)\s*$')
            $title=if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim('"',"'") } else { $draft.BaseName }
            $reason = if ($ledgerAttempt.status -eq 'reconcile_required') {
                '이전 시도에서 라이브 공개 여부가 확정되지 않았습니다. 사이트와 원장을 대조한 뒤 수동으로 정리해야 합니다.'
            } else { '이전 사전 검사에서 검토가 필요했습니다. 내용을 수정하고 다시 승인하세요.' }
            [pscustomobject]@{
                path=$relative; full_path=$draft.FullName; title=$title; section=$section; hash=$fileHash
                source_id=$sourceId; registry_status=(Get-LLRowProp $row 'status')
                can_publish=$false; approval_status=$ledgerAttempt.status; approval_reason=$reason
                cleanup_eligible=$false; duplicate_of=''; body_sha256=$bodyHash
                last_attempt_status=$ledgerAttempt.status; last_attempt_message=$ledgerAttempt.message
            }
            continue
        }
        $approval = Get-LLApprovalSnapshotStatus -ReadyRoot $ReadyDir -ApprovedPath $draft.FullName -SourceId $sourceId -Section $section -FileName $draft.Name -Rows $ApprovalRows
        if ($approval.status -ne 'match' -and -not $IncludeBlocked) { continue }
        $destination=Join-Path $BlogRoot "content/$relative"
        if ((Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath (Join-Path $PublishedDir $draft.Name))) { continue }
        if (@(Get-LLDraftQualityIssues -Content $content -Row $row -Section $section).Count) { continue }
        $titleMatch=[regex]::Match($content,'(?m)^title:\s*(.*?)\s*$')
        $title=if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim('"',"'") } else { $draft.BaseName }
        $reason = switch ($approval.status) {
            'match'   { '' }
            'missing' { '승인 당시 해시 기록이 없습니다. 미리보기에서 다시 승인하세요.' }
            'unbound' { '기존 승인에 파일 해시가 묶여 있지 않습니다. 미리보기에서 다시 승인하세요.' }
            'revoked' { '최신 승인 기록이 PASS가 아닙니다. 미리보기에서 다시 승인하세요.' }
            default   { '승인 이후 파일 또는 연결 정보가 바뀌었습니다. 미리보기에서 다시 승인하세요.' }
        }
        [pscustomobject]@{
            path=$relative; full_path=$draft.FullName; title=$title; section=$section; hash=$fileHash
            source_id=$sourceId; registry_status=(Get-LLRowProp $row 'status')
            can_publish=($approval.status -eq 'match'); approval_status=$approval.status; approval_reason=$reason
            cleanup_eligible=$false; duplicate_of=''; body_sha256=$bodyHash
            last_attempt_status=$ledgerAttempt.status; last_attempt_message=$ledgerAttempt.message
        }
    }
}

function Invoke-LLQuarantinePublishedDuplicate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [string]$ReadyDir = (Get-LLPath '05_ready_to_publish'),
        [string]$PublishedDir = (Get-LLPath '06_published'),
        [string]$BlogRoot = (Join-Path (Split-Path (Get-LLRoot) -Parent) 'Blog'),
        [string]$RegistryPath = (Get-LLRegistryPath),
        [string]$LedgerPath = (Get-LLPath '01_registry/publish_ledger.csv'),
        [string]$TrashRoot = (Get-LLPath '.trash'),
        [string]$RegistryBackupRoot = (Get-LLPath '07_archive/backups'),
        [AllowNull()][array]$ApprovalRows = $null
    )
    $relative = $RelativePath.Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or [IO.Path]::IsPathRooted($relative) -or $relative.Split('/') -contains '..') {
        throw '중복 정리 경로가 승인 폴더 밖입니다.'
    }
    if ($ExpectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw '중복 정리 요청의 파일 해시 형식이 올바르지 않습니다.' }
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { throw "source_registry.csv를 찾을 수 없습니다: $RegistryPath" }
    if ($null -eq $ApprovalRows) { $ApprovalRows = @(Get-LLApprovalLogRows) }
    $rows = @(Import-Csv -LiteralPath $RegistryPath -Encoding utf8)
    $ledgerRows = @(Get-LLPublishLedgerRows -LogPath $LedgerPath)
    $candidates = @(Get-LLReadyPublishCandidates -ReadyDir $ReadyDir -PublishedDir $PublishedDir -BlogRoot $BlogRoot -Rows $rows -ApprovalRows $ApprovalRows -LedgerRows $ledgerRows -IncludeBlocked)
    $matches = @($candidates | Where-Object { [string]::Equals([string]$_.path, $relative, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1 -or -not $matches[0].cleanup_eligible -or $matches[0].approval_status -ne 'duplicate') {
        throw '이 글은 발행 완료된 동일 본문으로 확인되지 않았습니다. 아무 파일도 이동하지 않았습니다.'
    }
    $candidate = $matches[0]
    if ($candidate.hash -ine $ExpectedHash) { throw '정리 요청 후 승인본이 변경됐습니다. 목록을 새로고침하세요.' }
    $publishedBodyIndex = Get-LLPublishedBodyIndex -PublishedDir $PublishedDir
    $bodyIsStillPublished = $candidate.body_sha256 -and $publishedBodyIndex.ContainsKey([string]$candidate.body_sha256)
    $ledgerConfirmsPublished = $candidate.last_attempt_status -in @('published','duplicate_published')
    if (-not $bodyIsStillPublished -and -not $ledgerConfirmsPublished) {
        throw '정리 직전 발행 완료 근거가 사라졌습니다. 목록을 새로고침한 뒤 다시 확인하세요.'
    }
    $sourceFull = [IO.Path]::GetFullPath($candidate.full_path)
    $readyPrefix = [IO.Path]::GetFullPath($ReadyDir).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $sourceFull.StartsWith($readyPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '정리 대상이 승인 대기 폴더 밖입니다.' }
    if (Test-LLPathHasReparseAncestor -Path $ReadyDir) { throw '승인 대기 폴더 경로에 재분석 지점이 있어 정리를 중단했습니다.' }
    if ((Get-LLHash $sourceFull) -ine $ExpectedHash) { throw '정리 직전에 승인본이 변경됐습니다. 아무 파일도 이동하지 않았습니다.' }
    $trashFull = [IO.Path]::GetFullPath($TrashRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (Test-LLPathHasReparseAncestor -Path $TrashRoot) { throw '휴지통 경로에 재분석 지점이 있어 정리를 중단했습니다.' }
    foreach ($protectedRoot in @($ReadyDir,$PublishedDir)) {
        $protectedFull = [IO.Path]::GetFullPath($protectedRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if ($trashFull.StartsWith($protectedFull, [StringComparison]::OrdinalIgnoreCase)) { throw '휴지통 경로가 승인본 또는 발행 보관소 안에 있어 정리를 중단했습니다.' }
    }

    $sourceId = [string]$candidate.source_id
    $registryMatches = @($rows | Where-Object { (Get-LLProp $_ 'source_id') -eq $sourceId })
    if ($registryMatches.Count -ne 1) { throw '원장 연결이 유일하지 않아 중복본을 정리하지 않았습니다.' }
    $registryRow = $registryMatches[0]
    $registryStatusBefore = (Get-LLProp $registryRow 'status').Trim().ToLowerInvariant()
    $shouldRejectRegistry = $registryStatusBefore -ne 'published'
    $runId = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $registryBackup = ''
    $ledgerBackup = ''
    $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
    if (-not (Test-Path -LiteralPath $RegistryBackupRoot)) { New-Item -ItemType Directory -Path $RegistryBackupRoot -Force | Out-Null }
    if ($shouldRejectRegistry) {
        $registryBackup = Join-Path $RegistryBackupRoot ('source_registry_before_duplicate_' + [guid]::NewGuid().ToString('N') + '.csv')
        Copy-Item -LiteralPath $RegistryPath -Destination $registryBackup
    }
    $ledgerBackup = Join-Path $RegistryBackupRoot ('publish_ledger_before_duplicate_' + $runId + '.csv')
    if ($ledgerExisted) { Copy-Item -LiteralPath $LedgerPath -Destination $ledgerBackup }
    else { [IO.File]::WriteAllText($ledgerBackup, "draft_path,hugo_target_path,published_date,public_url,status,notes`r`n", [Text.UTF8Encoding]::new($false)) }
    $trashRunRoot = Join-Path $TrashRoot ('publish_duplicate_' + $runId)
    $destination = Join-Path $trashRunRoot ($relative -replace '/', [string][IO.Path]::DirectorySeparatorChar)
    $destinationParent = Split-Path -Parent $destination
    if (Test-Path -LiteralPath $destination) { throw '휴지통 목적지 충돌입니다. 아무 파일도 이동하지 않았습니다.' }
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    $destinationFull = [IO.Path]::GetFullPath($destination)
    if (-not $destinationFull.StartsWith($trashFull, [StringComparison]::OrdinalIgnoreCase)) { throw '휴지통 목적지가 지정된 휴지통 폴더 밖입니다.' }
    $moved = $false
    $registryChanged = $false
    $manifestPath = Join-Path $trashRunRoot '_quarantine.json'
    $ledgerCommitted = $false
    try {
        if (Test-LLPathHasReparseAncestor -Path $trashRunRoot) { throw '정리 직전 휴지통 경로에 재분석 지점이 생겨 작업을 중단했습니다.' }
        $ancestor = Get-Item -LiteralPath $sourceFull -Force
        while ($ancestor -and $ancestor.FullName.TrimEnd('\','/') -ne [IO.Path]::GetFullPath($ReadyDir).TrimEnd('\','/')) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '정리 직전 승인 폴더 경로에 재분석 지점이 생겨 작업을 중단했습니다.' }
            $ancestor = if ($ancestor -is [IO.FileInfo]) { $ancestor.Directory } else { $ancestor.Parent }
        }
        if ((Get-LLHash $sourceFull) -ine $ExpectedHash) { throw '정리 직전 승인본이 변경됐습니다. 아무 파일도 이동하지 않았습니다.' }
        $latestPublishedIndex = Get-LLPublishedBodyIndex -PublishedDir $PublishedDir
        $stillPublished = $candidate.body_sha256 -and $latestPublishedIndex.ContainsKey([string]$candidate.body_sha256)
        if (-not $stillPublished -and $candidate.last_attempt_status -notin @('published','duplicate_published')) { throw '정리 직전 발행 완료 근거를 다시 확인하지 못했습니다.' }
        [IO.File]::Move($sourceFull, $destination)
        $moved = $true
        if ($shouldRejectRegistry) {
            $registryRow.status = 'rejected'
            $reason = "duplicate_published=$($candidate.duplicate_of); body_sha256=$($candidate.body_sha256)"
            $priorNotes = [string](Get-LLRowProp $registryRow 'notes')
            $registryRow.notes = if ($priorNotes) { $priorNotes.TrimEnd(';',' ') + '; ' + $reason } else { $reason }
            $columns = @($registryRow.PSObject.Properties.Name)
            $registryChanged = $true
            $rows | Select-Object $columns | Export-Csv -LiteralPath $RegistryPath -NoTypeInformation -Encoding utf8
        }
        $trashRelative = (Get-LLRelativePath $destination)
        $manifest = [ordered]@{
            version=1; transaction_state='prepared'; disposition='duplicate_published'; created_at=[DateTimeOffset]::Now.ToString('o')
            original_path=('05_ready_to_publish/' + $relative); trash_path=$trashRelative
            duplicate_of=[string]$candidate.duplicate_of; source_id=$sourceId
            file_sha256=$ExpectedHash.ToLowerInvariant(); body_sha256=[string]$candidate.body_sha256
            registry_status_before=$registryStatusBefore; registry_status_after=$(if($shouldRejectRegistry){'rejected'}else{'published'})
        }
        Write-LLText -Path $manifestPath -Content (ConvertTo-Json $manifest -Depth 4)
        $null = Add-LLPublishLedgerEntry -DraftPath ('05_ready_to_publish/' + $relative) -HugoTargetPath ('content/' + $relative) -Status 'duplicate_published' -SourceId $sourceId -ContentSha256 $ExpectedHash -FailureCode 'duplicate_body' -Message '정확히 일치하는 발행 본문을 찾아 승인본 사본만 휴지통으로 이동했습니다.' -DuplicateOf ([string]$candidate.duplicate_of) -CleanupPaths @($trashRelative) -AttemptId $runId -LogPath $LedgerPath
        $ledgerCommitted = $true
    } catch {
        $failure = $_.Exception.Message
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        if (-not $ledgerCommitted -and (Test-Path -LiteralPath $ledgerBackup)) {
            try { [IO.File]::Copy($ledgerBackup, $LedgerPath, $true) } catch { $rollbackErrors.Add('발행 원장 복구 실패: ' + $_.Exception.Message) }
        }
        if ($registryChanged -and (Test-Path -LiteralPath $registryBackup)) {
            try { [IO.File]::Copy($registryBackup, $RegistryPath, $true) } catch { $rollbackErrors.Add('registry 복구 실패: ' + $_.Exception.Message) }
        }
        if ($moved -and (Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $sourceFull)) {
            try { [IO.File]::Move($destination, $sourceFull) } catch { $rollbackErrors.Add('승인본 복구 실패: ' + $_.Exception.Message) }
        }
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $rollbackManifest = [ordered]@{version=1;transaction_state='rolled_back';disposition='duplicate_published';attempt_id=$runId;failure=$failure;rollback_errors=@($rollbackErrors)}
                Write-LLText -Path $manifestPath -Content (ConvertTo-Json $rollbackManifest -Depth 4)
            } catch { $rollbackErrors.Add('휴지통 상태 기록 실패: ' + $_.Exception.Message) }
        }
        if ($rollbackErrors.Count) { throw "$failure; 되돌리기 확인 필요: $($rollbackErrors -join ' | '); 휴지통=$trashRunRoot" }
        throw $failure
    }
    $manifest.transaction_state = 'committed'
    $manifestWarning = ''
    try { Write-LLText -Path $manifestPath -Content (ConvertTo-Json $manifest -Depth 4) } catch { $manifestWarning = $_.Exception.Message }
    return [pscustomobject]@{
        ok=$true; action='quarantine_duplicate'; original_path=('05_ready_to_publish/' + $relative)
        trash_path=$trashRelative; duplicate_of=[string]$candidate.duplicate_of
        source_id=$sourceId; registry_status=$(if($shouldRejectRegistry){'rejected'}else{'published'}); manifest_warning=$manifestWarning
    }
}

function Resolve-LLReadyPublishSelection {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Files, [AllowEmptyCollection()][array]$Candidates = @(Get-LLReadyPublishCandidates))
    if ($Files.Count -lt 1 -or $Files.Count -gt 50) { throw '발행할 글을 1~50개 선택하세요.' }
    $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Files) {
        $path=[string](Get-LLRowProp $file 'path')
        $hash=[string](Get-LLRowProp $file 'hash')
        if (-not $path -or -not $seen.Add($path)) { throw '비어 있거나 중복된 발행 선택입니다.' }
        $match=@($Candidates | Where-Object { $_.path -ceq $path })
        $notPublishable = ($match.Count -eq 1 -and $match[0].PSObject.Properties['can_publish'] -and -not [bool]$match[0].can_publish)
        if ($match.Count -ne 1 -or $notPublishable -or $hash -notmatch '^[A-Fa-f0-9]{64}$' -or $match[0].hash -ine $hash) {
            throw '선택한 승인본이 변경되었거나 발행 자격이 없습니다. 목록을 새로고침하고 다시 선택하세요.'
        }
        $match[0]
    }
}

function Assert-LLPublishContentSelection {
    param([AllowEmptyCollection()][array]$StatusLines, [Parameter(Mandatory)][array]$SelectedPaths)
    $allowed=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $SelectedPaths) { $null=$allowed.Add('content/'+([string]$path -replace '\\','/')) }
    foreach ($line in $StatusLines) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $text=[string]$line
        if ($text.Length -lt 4 -or -not $allowed.Contains($text.Substring(3).Trim('"'))) {
            throw '선택하지 않은 블로그 content 변경이 있습니다. 이전 발행 실패의 잔여 글이나 다른 편집 내용을 먼저 확인하세요. 배포하지 않았습니다.'
        }
    }
}

function Invoke-LLPreviewApproveDraft {
    param([Parameter(Mandatory)][string]$RelativePath)
    $full = Resolve-LLSafeDraftPath -RelativePath $RelativePath
    $draft = Get-Item -LiteralPath $full
    $content = Read-LLText $full
    $row = Resolve-LLDraftRegistryRow -Draft $draft -Content $content
    $dailyMergedDates = Get-LLDailyMergedDateKeys
    $isByproduct = Test-LLDraftByproduct -Draft $draft -Row $row -DailyMergedDates $dailyMergedDates
    $draftsDir = Get-LLPath "04_blog_drafts"
    $relFromDrafts = $draft.FullName.Replace($draftsDir + "\", "").Replace("\", "/")
    $section = ($relFromDrafts -split "/")[0]
    if (-not $section) { $section = "learning" }
    $badges = Get-LLDraftBadges -Content $content -Row $row -ByproductOverride $isByproduct -Section $section
    $issues = @(Get-LLDraftQualityIssues -Content $content -Row $row -Section $section)
    $policy = (Get-LLRowProp $row "public_policy").ToLowerInvariant()
    $status = (Get-LLRowProp $row "status").ToLowerInvariant()
    $destDir = Join-Path (Get-LLPath "05_ready_to_publish") $section
    $dest = Join-Path $destDir $draft.Name
    $sourceId = Get-LLDraftSourceId $content
    if (-not $sourceId -and $row) { $sourceId = Get-LLRowProp $row "source_id" }
    $approvalSnapshot = Get-LLApprovalSnapshotStatus -ReadyRoot (Get-LLPath '05_ready_to_publish') -ApprovedPath $dest -SourceId $sourceId -Section $section -FileName $draft.Name
    $manualReviewPass = (
        $issues.Count -eq 0 -and
        $policy -in @("public", "partial-public") -and
        $status -eq "needs_review" -and
        -not $badges.isByproduct
    )
    $reapprovalPass = (
        $badges.approved -and
        $approvalSnapshot.status -ne 'match' -and
        $issues.Count -eq 0 -and
        $policy -in @('public', 'partial-public') -and
        $status -eq 'approved' -and
        $row -and (Test-LLPublishableSource $row) -and
        -not $badges.isByproduct
    )
    if (-not $badges.canApprove -and -not $manualReviewPass -and -not $reapprovalPass) {
        $why = ($badges.badges | Where-Object { $_.cls -ne "ok" } | ForEach-Object { $_.text }) -join ", "
        throw "not approvable: $why"
    }

    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $backup = ''
    if ($reapprovalPass -and (Test-Path -LiteralPath $dest)) {
        $backup = Backup-LLFile -Path $dest -Prefix ('approved_before_reapproval_' + [guid]::NewGuid().ToString('N'))
    }
    Copy-Item -LiteralPath $draft.FullName -Destination $dest -Force

    if ($sourceId) { $null = Set-LLRegistryStatus -SourceId $sourceId -Status "approved" }
    Add-LLApprovalLogEntry -LogPath (Get-LLPath "09_reports\approval_log.csv") -FileName $draft.Name -SourceId $sourceId -Section $section -QaStatus "PASS" -Notes $(if ($reapprovalPass) { 'preview reapproval' } else { 'preview pass' }) -ApprovedPath $dest -ReadyRoot (Get-LLPath '05_ready_to_publish')

    return [pscustomobject]@{ ok = $true; action = $(if ($reapprovalPass) { 'reapprove' } else { 'approve' }); rel = $RelativePath; dest = (Get-LLRelativePath $dest); source_id = $sourceId; backup = $backup }
}

function Invoke-LLPreviewBlockDraft {
    param([Parameter(Mandatory)][string]$RelativePath)
    $full = Resolve-LLSafeDraftPath -RelativePath $RelativePath
    $draft = Get-Item -LiteralPath $full
    $content = Read-LLText $full
    $row = Resolve-LLDraftRegistryRow -Draft $draft -Content $content

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $trashRoot = Get-LLPath (".trash\preview_block_" + $stamp)
    $dest = Join-Path $trashRoot ($RelativePath -replace "/", "\")
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Move-Item -LiteralPath $draft.FullName -Destination $dest -Force

    $sid = Get-LLDraftSourceId $content
    if (-not $sid -and $row) { $sid = Get-LLProp $row "source_id" }
    if ($sid) { $null = Set-LLRegistryStatus -SourceId $sid -Status "rejected" }

    return [pscustomobject]@{ ok = $true; action = "block"; rel = $RelativePath; trash = (Get-LLRelativePath $dest); source_id = $sid }
}

function New-LLPreviewDashboard {
    param(
        [Parameter(Mandatory)][string]$DraftsDir,
        [Parameter(Mandatory)][string]$OutDir,
        [switch]$IncludePublished,
        [switch]$IncludeByproducts,
        [switch]$IncludeBacklog,
        [string]$Section = ""
    )
    $sectionFilter = $Section.Trim().ToLowerInvariant()
    $rows = @(Get-LLRegistryRows)
    $dailyMergedDates = Get-LLDailyMergedDateKeys -Rows $rows
    # 원본 노트 묶음 인덱스는 렌더당 1회만 계산(각 daily 초안이 재스캔하지 않게). 성능 핵심.
    $dailyMemberIndex = Get-LLDailyMemberIndex -Rows $rows
    $rowBySid = @{}
    $rowByTopic = @{}
    foreach ($r in $rows) {
        $sid = Get-LLProp $r "source_id"
        if ($sid) { $rowBySid[$sid] = $r }
        $topic = Get-LLProp $r "topic"
        if ($topic) { $rowByTopic[$topic] = $r }
    }

    $publishedNames = Get-LLPublishedNames
    $approvalRows = @(Get-LLApprovalLogRows)

    $items = [System.Collections.Generic.List[object]]::new()
    $excludedPublished = 0
    $excludedByproducts = 0
    $excludedBacklog = 0
    if (Test-Path -LiteralPath $DraftsDir) {
        # 1-pass: row 매칭 + 정렬 키(date) 계산 후, 날짜 내림차순(최신순) 정렬
        $entries = foreach ($d in (Get-ChildItem -LiteralPath $DraftsDir -Recurse -Filter "*.md" -File)) {
            if ($sectionFilter) {
                $relFromDrafts = $d.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
                $draftSection = (($relFromDrafts -split "/")[0]).ToLowerInvariant()
                if ($draftSection -ne $sectionFilter) { continue }
            }
            $content = Read-LLText $d.FullName
            $sid = Get-LLDraftSourceId $content
            $row = $null
            if ($sid -and $rowBySid.ContainsKey($sid)) {
                $row = $rowBySid[$sid]
            } elseif ($rowByTopic.ContainsKey($d.BaseName)) {
                # slot 방식 draft 는 source_id 가 없으므로 파일명=topic 으로 역매칭
                $row = $rowByTopic[$d.BaseName]
                if (-not $sid) { $sid = Get-LLProp $row "source_id" }
            }
            [pscustomobject]@{
                File = $d; Content = $content; Sid = $sid; Row = $row
                Date = (Get-LLDraftDate -Draft $d -Row $row)
                IsPublished = (Test-LLDraftAlreadyPublished -Draft $d -Row $row -PublishedNames $publishedNames)
                IsByproduct = (Test-LLDraftByproduct -Draft $d -Row $row -DailyMergedDates $dailyMergedDates)
            }
        }
        $entries = @($entries | Sort-Object -Property Date -Descending)

        if (-not $IncludeBacklog) {
            $todayStr = (Get-Date).ToString("yyyy-MM-dd")
            $visibleEntries = [System.Collections.Generic.List[object]]::new()
            foreach ($e in $entries) {
                $dateAdded = Get-LLRowProp $e.Row "date_added"
                $isToday = (
                    $e.File.Name -like "$todayStr*" -or
                    $dateAdded -eq $todayStr -or
                    $e.File.LastWriteTime.ToString("yyyy-MM-dd") -eq $todayStr
                )
                # 승인 '대기'(drafted / needs_review)인 초안만 날짜와 무관하게 계속 노출한다.
                # 이미 처리된 것(approved/published/rejected/archived)과 레지스트리 없는 잔여는
                # backlog로 숨긴다 — 어제 미완성은 살리되, 처리 끝난 건 화면·용량 낭비 안 하게.
                $st = (Get-LLRowProp $e.Row "status").ToLowerInvariant()
                $isPendingApproval = ($st -in @("drafted", "needs_review"))
                if ($isToday -or $isPendingApproval) { $visibleEntries.Add($e) } else { $excludedBacklog++ }
            }
            $entries = @($visibleEntries)
        }

        # 개별 personal_note를 부산물로 숨기는 것은 같은 날짜의 am/pm 합본이
        # 실제로 만들어진 경우에만 적용한다. 합본이 없는 단독 시험 노트까지
        # 숨기면 초안이 생성됐는데 preview에는 0개로 보이게 된다.
        $dailyDates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($e in $entries) {
            $category = (Get-LLRowProp $e.Row "source_category").ToLowerInvariant()
            if ($category -eq "daily_merged") {
                $null = $dailyDates.Add(([datetime]$e.Date).ToString("yyyy-MM-dd"))
            }
        }

        foreach ($e in $entries) {
            if ($e.IsPublished -and -not $IncludePublished) { $excludedPublished++; continue }
            if ($e.IsByproduct -and -not $dailyDates.Contains(([datetime]$e.Date).ToString("yyyy-MM-dd"))) {
                $e.IsByproduct = $false
            }
            if ($e.IsByproduct -and -not $IncludeByproducts) { $excludedByproducts++; continue }
            $d = $e.File; $content = $e.Content; $sid = $e.Sid; $row = $e.Row
            $rel = Get-LLRelativePath $d.FullName
            $section = ($rel -split "/")[1]
            if (-not $section) { $section = "?" }
            $b = Get-LLDraftBadges -Content $content -Row $row -ByproductOverride $e.IsByproduct -Section $section
            $readyPath = Join-Path (Get-LLPath '05_ready_to_publish') (Join-Path $section $d.Name)
            $approvalSnapshot = Get-LLApprovalSnapshotStatus -ReadyRoot (Get-LLPath '05_ready_to_publish') -ApprovedPath $readyPath -SourceId $sid -Section $section -FileName $d.Name -Rows $approvalRows
            $needsReapproval = (
                $b.approved -and
                $approvalSnapshot.status -ne 'match' -and
                $b.qaPass -and
                (Get-LLRowProp $row 'public_policy').ToLowerInvariant() -in @('public', 'partial-public') -and
                (Get-LLRowProp $row 'status').ToLowerInvariant() -eq 'approved' -and
                $row -and (Test-LLPublishableSource $row) -and
                -not $e.IsByproduct
            )
            $badgeList = [System.Collections.Generic.List[object]]::new()
            foreach ($bd in $b.badges) { $badgeList.Add($bd) }
            if ($e.IsPublished) { $badgeList.Add([pscustomobject]@{ text = "PUBLISHED"; cls = "warn" }) }
            if ($needsReapproval) { $badgeList.Add([pscustomobject]@{ text = "REAPPROVAL REQUIRED"; cls = "warn" }) }

            $title = Get-LLDraftTitle $content
            if (-not $title) { $title = $d.BaseName }
            $orig = Resolve-LLPreviewOriginalNote -Row $row -MemberIndex $dailyMemberIndex
            $origPath = $orig.Path
            $origB64 = ""
            if ($orig.Text) {
                $origB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$orig.Text))
            }
            $draftB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))

            $items.Add([pscustomobject]@{
                name       = $d.Name
                rel        = $rel
                section    = $section
                sid        = $sid
                title      = $title
                policy     = (Get-LLRowProp $row "public_policy")
                status     = (Get-LLRowProp $row "status")
                canApprove = ($b.canApprove -or $needsReapproval)
                canRepair  = $b.canRepair
                approvalBlockReason = $(if ($needsReapproval) { '승인 당시 파일 해시가 없거나 승인본이 바뀌었습니다. 내용을 확인한 뒤 다시 승인하세요.' } else { $b.approvalBlockReason })
                repairBlockReason = $b.repairBlockReason
                approved   = $b.approved
                reapprovalRequired = $needsReapproval
                isByproduct = $e.IsByproduct
                badges     = @($badgeList)
                origPath   = $origPath
                origB64    = $origB64
                draftB64   = $draftB64
                hash       = (Get-LLHash $d.FullName)
                canEdit    = ((Get-LLRowProp $row 'status') -in @('drafted','needs_review'))
            })
        }
    }

    $itemArray = $items.ToArray()
    $dataJson = ($itemArray | ConvertTo-Json -Depth 6 -Compress)
    if (-not $dataJson) {
        $dataJson = "[]"
    } elseif ($itemArray.Count -eq 1 -and -not $dataJson.TrimStart().StartsWith("[")) {
        $dataJson = "[" + $dataJson + "]"
    }
    # </script> 차단: 평문 필드의 </ 를 <\/ 로 (본문은 Base64라 안전)
    $dataJson = $dataJson -replace '</', '<\/'
    $metaJson = ([pscustomobject]@{
        count = $items.Count
        excludedPublished = $excludedPublished
        excludedByproducts = $excludedByproducts
        excludedBacklog = $excludedBacklog
    } | ConvertTo-Json -Compress)

    $template = @'
<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<title>LearningLog Preview Dashboard</title>
<script src="__MARKED__"></script>
<style>
  body{margin:0;font-family:'Malgun Gothic',sans-serif;background:#1a1713;color:#eee;display:flex;height:100vh}
  #list{width:300px;overflow:auto;border-right:1px solid #333;padding:8px;flex-shrink:0}
  #summary{font-size:.75rem;line-height:1.5;color:#bbb;background:#211d17;border:1px solid #332d22;border-radius:6px;padding:7px;margin-bottom:8px}
  #summary b{color:#f0d58d}
  #list .item{padding:8px;border-radius:6px;cursor:pointer;margin-bottom:6px;background:#23201a;border:1px solid #2c2820}
  #list .item:hover{background:#2d2718}
  #list .item.on{border-color:#c49a4a}
  #list .t{font-size:.9rem;font-weight:600;margin-bottom:4px}
  #list .f{font-size:.7rem;color:#888;word-break:break-all}
  .itemrow{display:flex;align-items:flex-start;gap:6px}
  .itemrow .item{flex:1}
  .actions{display:flex;gap:4px;margin-top:6px;flex-wrap:wrap}
  .actions button{border:1px solid #443b2d;border-radius:5px;background:#29241c;color:#ddd;padding:3px 7px;cursor:pointer;font-size:.68rem}
  .actions button:hover{background:#3a3020}
  .actions .pass{color:#bdf7bd;border-color:#2d5b31}
  .actions .repair{color:#ffe08a;border-color:#735c22}
  .actions .block{color:#ffb0b0;border-color:#6b2b2b}
  .actions .blocked{display:inline-block;max-width:100%;box-sizing:border-box;padding:4px 7px;border:1px solid #713c37;border-radius:5px;background:#321f1d;color:#ffb5a8;font-size:.72rem;line-height:1.45;overflow-wrap:anywhere}
  .badge{display:inline-block;padding:1px 6px;border-radius:10px;font-size:.65rem;margin:2px 2px 0 0}
  .ok{background:#1e4620;color:#9f9} .warn{background:#5a4a1a;color:#fd6} .danger{background:#5a1e1e;color:#f99}
  .approved{background:#164d2a;color:#a7f3b8}
  #list .itemrow.approved .item{border-color:#37b866;box-shadow:0 0 0 1px rgba(55,184,102,.25)}
  #list .itemrow.approved .item.on{border-color:#55d47d}
  #view{flex:1;display:flex;overflow:hidden}
  .pane{flex:1;overflow:auto;padding:16px;border-left:1px solid #333}
  .pane h4{position:sticky;top:0;background:#1a1713;margin:0 0 12px;padding:6px 0;color:#c49a4a;border-bottom:1px solid #333}
  .render{background:#fff;color:#222;padding:20px;border-radius:8px;line-height:1.7}
  .render pre{background:#f4f4f4;padding:12px;border-radius:6px;overflow:auto}
  .render code{background:#eee;padding:1px 4px;border-radius:3px}
  .render pre code{background:none;padding:0}
  .render h1,.render h2,.render h3{border-bottom:1px solid #eee;padding-bottom:4px}
  .empty{color:#888;font-style:italic}
  #editor{margin-bottom:16px} #editor input,#editor textarea{box-sizing:border-box;width:100%;background:#fff;color:#222;border:1px solid #666;border-radius:5px;padding:9px;font:inherit}
  #editor textarea{min-height:350px;resize:vertical;font-family:monospace;line-height:1.6;margin-top:8px} #editor button{padding:7px 12px;margin:8px 6px 0 0;cursor:pointer}
  #edit-hint{font-size:.85rem;color:#e8d7ac}
</style></head>
<body>
<div id="list"></div>
<div id="view">
  <div class="pane"><h4>원본 입력 자료</h4><div id="orig" class="render"></div></div>
  <div class="pane"><h4>블로그 초안 (발행될 모습)</h4>
    <div id="editor" hidden><input id="edit-title" aria-label="초안 제목"><textarea id="edit-body" aria-label="초안 본문 Markdown"></textarea>
      <button id="edit-preview" type="button">변경 내용 미리보기</button><button id="edit-save" type="button">편집 저장</button><button id="edit-cancel" type="button">편집 취소</button>
      <p id="edit-hint" role="status">제목·본문만 편집합니다. 원본 자료와 공개 정책은 그대로이며, 저장은 승인이 아닙니다.</p>
    </div><div id="draft" class="render"></div></div>
</div>
<script id="meta" type="application/json">__META__</script>
<script id="data" type="application/json">__DATA__</script>
<script>
  const META = JSON.parse(document.getElementById('meta').textContent);
  const RAW_DATA = JSON.parse(document.getElementById('data').textContent);
  const DATA = Array.isArray(RAW_DATA) ? RAW_DATA : (RAW_DATA ? [RAW_DATA] : []);
  function b64(b){ return new TextDecoder().decode(Uint8Array.from(atob(b), c=>c.charCodeAt(0))); }
  function escapeHtml(t){return String(t).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
  function renderMarkdown(text){
    // 입력/생성/편집 본문의 HTML은 실행하지 않는다. HTML 데모 공개와 별개다.
    const renderer=new marked.Renderer();
    renderer.html=html=>escapeHtml(html);
    const link=renderer.link.bind(renderer), image=renderer.image.bind(renderer);
    renderer.link=(href,title,label)=>{
      const safe=href && !/[\x00-\x20\\]/.test(href) && (/^https?:\/\//i.test(href) || !/^[^/#?]*:/.test(href));
      return safe ? link(href,title,label) : label;
    };
    renderer.image=(href,title,label)=>href && /^\/images\//.test(href) ? image(href,title,label) : escapeHtml('[이미지: '+label+']');
    return marked.parse(text,{renderer});
  }
  let editingIndex = null;
  function show(i){
    if (editingIndex !== null && !confirm('저장하지 않은 편집을 닫을까요?')) return;
    editingIndex = null; document.getElementById('editor').hidden = true;
    document.querySelectorAll('#list .item').forEach((e,j)=>e.classList.toggle('on', j===i));
    const d = DATA[i];
    document.getElementById('orig').innerHTML  = d.origB64 ? renderMarkdown(b64(d.origB64)) : '<p class="empty">원본 note 없음</p>';
    document.getElementById('draft').innerHTML = renderMarkdown(b64(d.draftB64));
  }
  const list = document.getElementById('list');
  const summary = document.createElement('div');
  summary.id = 'summary';
  summary.innerHTML = '<b>표시 '+META.count+'개</b>'
    + (META.excludedPublished ? '<br>발행 제외 '+META.excludedPublished+'개' : '')
    + (META.excludedByproducts ? '<br>부산물 제외 '+META.excludedByproducts+'개' : '')
    + (META.excludedBacklog ? '<br>과거 초안 제외 '+META.excludedBacklog+'개' : '');
  list.appendChild(summary);
  const canAct = location.protocol === 'http:';   // 서버 모드에서만 처리 가능
  function editIdx(i, ev){
    ev.stopPropagation(); const d=DATA[i];
    if(!canAct || !d.canEdit || d.approved) return;
    if(editingIndex !== null && !confirm('기존 편집을 닫을까요?')) return;
    editingIndex=null; show(i); editingIndex=i;
    document.getElementById('edit-title').value=d.title;
    document.getElementById('edit-body').value=b64(d.draftB64).replace(/^(?:\uFEFF)?---[^\S\r\n]*\r?\n[\s\S]*?\r?\n---[^\S\r\n]*(?:\r?\n|$)/,'').trim();
    document.getElementById('editor').hidden=false;
  }
  document.getElementById('edit-preview').onclick=()=>{ document.getElementById('draft').innerHTML=renderMarkdown(document.getElementById('edit-body').value); };
  document.getElementById('edit-cancel').onclick=()=>{const i=editingIndex; editingIndex=null; if(i!==null) show(i);};
  document.getElementById('edit-save').onclick=async()=>{
    if(editingIndex===null) return; const d=DATA[editingIndex]; const save=document.getElementById('edit-save'); save.disabled=true;
    try {
      const r=await fetch('/edit?f='+encodeURIComponent(d.rel), {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({title:document.getElementById('edit-title').value,body:document.getElementById('edit-body').value,hash:d.hash})});
      const text=await r.text(); if(!r.ok) throw new Error(text);
      const result=JSON.parse(text); alert('저장했습니다. 원문·결과를 검토한 뒤 별도로 승인하세요.'+(result.issues.length?'\nQA: '+result.issues.join(', '):''));
      editingIndex=null; location.reload();
    } catch(e){document.getElementById('edit-hint').textContent='저장 실패: '+e.message;} finally {save.disabled=false;}
  };
  async function postAction(path, rel, extra){
    const qs = new URLSearchParams(extra || {});
    qs.set('f', rel);
    const r = await fetch(path+'?'+qs.toString(), { method:'POST' });
    const t = await r.text();
    if(!r.ok){ throw new Error(t || ('HTTP '+r.status)); }
    return t;
  }
  async function passIdx(i, ev){
    ev.stopPropagation();
    if(editingIndex!==null){alert('편집을 저장하거나 취소한 뒤 승인하세요.');return;}
    const d=DATA[i];
    if(!d.canApprove){alert('공개 승인 차단: '+(d.approvalBlockReason||'승인 조건을 충족하지 못했습니다.'));return;}
    const verb=d.reapprovalRequired?'재승인':'승인';
    if(!confirm('"'+d.title+'" 을(를) '+verb+'할까요?\n'+(d.reapprovalRequired?'승인 당시 해시가 없거나 내용이 달라졌습니다. 현재 미리 본 내용을 새 승인본으로 기록합니다.':'승인본으로 이동합니다.'))) return;
    try{ await postAction('/approve', d.rel); alert(d.reapprovalRequired?'재승인했습니다. 승인본 해시를 기록했습니다.':'승인본으로 이동했습니다.'); location.reload(); }
    catch(e){ alert('통과 실패: '+e.message); }
  }
  async function repairIdx(i, ev, mode){
    ev.stopPropagation();
    if(editingIndex!==null){alert('편집을 저장하거나 취소한 뒤 패치하세요.');return;}
    const d=DATA[i];
    if(!d.canRepair){alert('자동 패치 차단: '+(d.repairBlockReason||'자동 패치 조건을 충족하지 못했습니다.'));return;}
    const label = 'QA 사유별 자동 패치';
    if(!confirm('"'+d.title+'" 을(를) '+label+'할까요?\\n패치 전 백업이 생성됩니다.')) return;
    try{ await postAction('/repair', d.rel, {mode:'auto'}); alert('자동 패치 완료. 다시 확인하세요.'); location.reload(); }
    catch(e){ alert('자동 패치 실패: '+e.message); }
  }
  async function blockIdx(i, ev){
    ev.stopPropagation();
    if(editingIndex!==null){alert('편집을 저장하거나 취소한 뒤 차단하세요.');return;}
    const d=DATA[i];
    if(!confirm('"'+d.title+'" 을(를) 차단하고 .trash 로 이동할까요?\\n복구 가능합니다.')) return;
    try{
      const raw = await postAction('/block', d.rel);
      let result = {}; try { result = JSON.parse(raw); } catch(e) {}
      alert('차단했습니다.\\n휴지통 위치: '+(result.trash || '.trash'));
      location.reload();
    }
    catch(e){ alert('차단 실패: '+e.message); }
  }
  window.__passIdx=passIdx; window.__repairIdx=repairIdx; window.__blockIdx=blockIdx; window.__editIdx=editIdx;
  if(DATA.length===0){ list.innerHTML+='<p class="empty">04_blog_drafts 에 초안이 없습니다.</p>'; }
  DATA.forEach((d,i)=>{
    const row=document.createElement('div'); row.className='itemrow'+(d.approved?' approved':'');
    const div=document.createElement('div'); div.className='item'; div.onclick=()=>show(i);
    const badges = Array.isArray(d.badges) ? d.badges : (d.badges ? [d.badges] : []);
    let bg=badges.map(b=>'<span class="badge '+escapeHtml(b.cls)+'">'+escapeHtml(b.text)+'</span>').join('');
    let act='';
    if(canAct && (!d.approved || d.reapprovalRequired)){
      act='<div class="actions">'
        + (d.canEdit ? '<button onclick="window.__editIdx('+i+',event)">편집·저장</button>' : '')
        + (d.canApprove ? '<button class="pass" onclick="window.__passIdx('+i+',event)">'+(d.reapprovalRequired?'재승인':'통과')+'</button>' : '<span class="blocked" role="status">공개 승인 차단 · '+escapeHtml(d.approvalBlockReason||'조건 미충족')+'</span>')
        + (d.canRepair && !d.approved ? '<button class="repair" onclick="window.__repairIdx('+i+',event,\'auto\')">자동 패치</button>' : '')
        + (!d.approved ? '<button class="block" onclick="window.__blockIdx('+i+',event)">차단·휴지통</button>' : '')
        + '</div>';
    }
    div.innerHTML='<div class="t">'+escapeHtml(d.title)+'</div><div class="f">'+escapeHtml(d.section)+' / '+escapeHtml(d.name)+'</div>'+bg+act;
    row.appendChild(div);
    list.appendChild(row);
  });
  if(DATA.length>0) show(0);
</script>
</body></html>
'@

    $html = $template.Replace('__MARKED__', '../../app/core/vendor/marked.min.js').Replace('__META__', $metaJson).Replace('__DATA__', $dataJson)

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $htmlPath = Join-Path $OutDir "index.html"
    Write-LLText -Path $htmlPath -Content $html

    return @{ html = $htmlPath; count = $items.Count; items = @($items); excludedPublished = $excludedPublished; excludedByproducts = $excludedByproducts; excludedBacklog = $excludedBacklog }
}

function Add-LLApprovalLogEntry {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$FileName,
        [string]$SourceId = "",
        [string]$Section = "",
        [string]$QaStatus = "PASS",
        [string]$ApprovedBy = $env:USERNAME,
        [string]$Notes = "",
        [string]$ApprovedPath = "",
        [string]$ReadyRoot = (Get-LLPath '05_ready_to_publish')
    )
    $approvedRelative = ''
    $approvedSha256 = ''
    if ($QaStatus.Trim().ToUpperInvariant() -eq 'PASS') {
        if (-not $ApprovedPath) { throw '승인 PASS 기록에는 승인본 경로와 해시가 필요합니다.' }
        $readyFull = [IO.Path]::GetFullPath($ReadyRoot).TrimEnd('\', '/')
        $approvedFull = [IO.Path]::GetFullPath($ApprovedPath)
        $prefix = $readyFull + [IO.Path]::DirectorySeparatorChar
        if (-not $approvedFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "승인본 경로가 승인 폴더 밖입니다: $ApprovedPath"
        }
        $approvedRelative = $approvedFull.Substring($prefix.Length).Replace('\', '/').Normalize([Text.NormalizationForm]::FormC)
        if (($approvedRelative -split '/').Count -ne 2 -or
            [IO.Path]::GetFileName($approvedFull) -ine $FileName -or
            ($approvedRelative -split '/')[0] -ine $Section) {
            throw "승인본 경로가 파일명/섹션과 일치하지 않습니다: $approvedRelative"
        }
        $approvedSha256 = Get-LLHash $approvedFull
        if ($approvedSha256 -notmatch '^[a-f0-9]{64}$') { throw "승인본 파일을 해시하지 못했습니다: $ApprovedPath" }
    }
    $entry = [pscustomobject]@{
        approved_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        file_name   = $FileName
        source_id   = $SourceId
        section     = $Section
        qa_status   = $QaStatus
        approved_by = $ApprovedBy
        notes       = $Notes
        approved_path = $approvedRelative
        approved_sha256 = $approvedSha256
    }
    $existing = @()
    if (Test-Path -LiteralPath $LogPath) {
        $existing = @(Import-Csv -LiteralPath $LogPath -Encoding utf8)
    }
    $all = @($existing) + @($entry)
    $parent = Split-Path -Parent $LogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $columns = @('approved_at','file_name','source_id','section','qa_status','approved_by','notes','approved_path','approved_sha256')
    $all | Select-Object $columns | Export-Csv -LiteralPath $LogPath -Encoding utf8 -NoTypeInformation
}

# ─────────────────────────────────────────────────────────
# 컨트롤센터 진행상태 (09_reports\control_center\job_progress.json)
#   파이프라인 스크립트가 "단계 n/N · 항목 k/m · 세부 진행"을 구조화해서 남기면
#   컨트롤센터가 이를 읽어 진행바·단계표시·남은시간(ETA)을 실제 값으로 보여준다.
#   - run_blog_daily 가 env LH_JOB_PROGRESS=1 을 켠 실행에서만 기록(단독 실행은 건드리지 않음)
#   - 모든 쓰기는 best-effort: 실패해도 파이프라인 동작에는 영향이 없다.
# ─────────────────────────────────────────────────────────
function Get-LLJobProgressPath {
    return (Join-Path (Get-LLPath "09_reports\control_center") "job_progress.json")
}

function Test-LLJobProgressEnabled {
    return ($env:LH_JOB_PROGRESS -eq "1")
}

function ConvertTo-LLDateTime {
    # ConvertFrom-Json(PS7)은 ISO 문자열을 DateTime 으로 바꾸기도 하므로 둘 다 처리한다.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    try { return [datetime]::Parse([string]$Value) } catch { return $null }
}

function Read-LLJobProgress {
    $path = Get-LLJobProgressPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-LLJobProgressFile {
    # 임시파일에 쓴 뒤 교체(원자적) → 서버가 쓰다 만 JSON 을 읽는 일이 없게 한다.
    param([Parameter(Mandatory)]$Data)
    $path = Get-LLJobProgressPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $path + ".tmp"
    [System.IO.File]::WriteAllText($tmp, ($Data | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Move($tmp, $path, $true)
}

function Clear-LLJobProgress {
    $path = Get-LLJobProgressPath
    try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } catch {}
}

function Set-LLJobStage {
    # 새 단계 시작. Index=1 이면 새 실행으로 보고 started 를 갱신한다.
    param(
        [Parameter(Mandatory)][string]$Job,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [string]$Detail = ""
    )
    if (-not (Test-LLJobProgressEnabled)) { return }
    try {
        $prev = Read-LLJobProgress
        $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        $runId = [string]$env:LH_JOB_RUN_ID
        $started = $now
        if ($prev -and [string]$prev.job -eq $Job -and [string]$prev.state -eq "running" -and [string]$prev.run_id -eq $runId -and $runId) {
            $ps = ConvertTo-LLDateTime $prev.started
            if ($ps) { $started = $ps.ToString("yyyy-MM-ddTHH:mm:ss") }
        }
        Write-LLJobProgressFile ([ordered]@{
            job = $Job; state = "running"; run_id = $runId
            started = $started; stage_started = $now; updated = $now
            stage_index = $Index; stage_total = $Total; stage_key = $Key; stage_label = $Label
            done = 0; total = 0; sub_done = 0; sub_total = 0; item = ""; detail = $Detail
        })
    } catch {}
}

function Set-LLJobItem {
    # 현재 단계 안의 항목 진행(done/total), 세부 진행(sub_done/sub_total), 항목명, 설명을 갱신한다.
    param(
        [int]$Done = -1, [int]$Total = -1,
        [int]$SubDone = -1, [int]$SubTotal = -1,
        [string]$Item, [string]$Detail
    )
    if (-not (Test-LLJobProgressEnabled)) { return }
    try {
        $p = Read-LLJobProgress
        if ($null -eq $p -or [string]$p.state -ne "running") { return }
        $o = [ordered]@{}
        foreach ($pr in $p.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
        if ($Done -ge 0)     { $o["done"] = $Done }
        if ($Total -ge 0)    { $o["total"] = $Total }
        if ($SubDone -ge 0)  { $o["sub_done"] = $SubDone }
        if ($SubTotal -ge 0) { $o["sub_total"] = $SubTotal }
        if ($PSBoundParameters.ContainsKey("Item"))   { $o["item"] = $Item }
        if ($PSBoundParameters.ContainsKey("Detail")) { $o["detail"] = $Detail }
        $o["updated"] = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Write-LLJobProgressFile $o
    } catch {}
}

function Complete-LLJobProgress {
    param([ValidateSet("done", "failed")][string]$State = "done", [string]$Detail = "")
    if (-not (Test-LLJobProgressEnabled)) { return }
    try {
        $p = Read-LLJobProgress
        if ($null -eq $p) { return }
        $o = [ordered]@{}
        foreach ($pr in $p.PSObject.Properties) { $o[$pr.Name] = $pr.Value }
        $o["state"] = $State
        $o["detail"] = $Detail
        $o["updated"] = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Write-LLJobProgressFile $o
    } catch {}
}

function Get-LLJobProgressInfo {
    # progress.json → UI 표시용 값(전체 %·단계 안 %·남은시간·경과)을 계산한다.
    # 단계마다 걸리는 시간이 크게 달라(LLM 단계가 대부분) 가중치로 전체 %를 낸다.
    param([Parameter(Mandatory)]$Progress, [datetime]$Now = (Get-Date))
    $idx = [int]$Progress.stage_index
    $total = [Math]::Max(1, [int]$Progress.stage_total)
    $weights = switch ([string]$Progress.job) {
        "blogdaily" { @(1, 1, 1, 12, 12, 1) }
        default     { @() }
    }
    if ($weights.Count -ne $total) { $weights = @(1..$total | ForEach-Object { 1 }) }

    $done = [int]$Progress.done; $items = [int]$Progress.total
    $subDone = [int]$Progress.sub_done; $subTotal = [int]$Progress.sub_total
    $subFrac = if ($subTotal -gt 0) { [Math]::Min(1.0, $subDone / $subTotal) } else { 0.0 }
    $frac = if ($items -gt 0) { [Math]::Min(1.0, ($done + $subFrac) / $items) } else { 0.0 }

    $state = [string]$Progress.state
    $before = 0.0
    for ($i = 1; $i -lt $idx -and $i -le $weights.Count; $i++) { $before += $weights[$i - 1] }
    $cur = if ($idx -ge 1 -and $idx -le $weights.Count) { $weights[$idx - 1] } else { 0 }
    $sum = ($weights | Measure-Object -Sum).Sum
    $pct = if ($state -eq "done") { 100.0 } else { [Math]::Round(100.0 * ($before + $cur * $frac) / $sum, 1) }

    $started = ConvertTo-LLDateTime $Progress.started
    $stageStarted = ConvertTo-LLDateTime $Progress.stage_started
    $updated = ConvertTo-LLDateTime $Progress.updated
    $elapsed = if ($started) { [int][Math]::Max(0, ($Now - $started).TotalSeconds) } else { 0 }
    $stageElapsed = if ($stageStarted) { [int][Math]::Max(0, ($Now - $stageStarted).TotalSeconds) } else { 0 }

    # 현재 단계 남은 시간 추정: 진행분이 어느 정도 쌓였을 때만(너무 이르면 오차가 큼)
    $eta = $null
    if ($state -eq "running" -and $frac -ge 0.08 -and $frac -lt 1.0 -and $stageElapsed -gt 20) {
        $eta = [int](($stageElapsed * (1.0 - $frac)) / $frac)
    }
    return [ordered]@{
        job = [string]$Progress.job; state = $state
        stage_index = $idx; stage_total = $total
        stage_key = [string]$Progress.stage_key; stage_label = [string]$Progress.stage_label
        done = $done; total = $items; sub_done = $subDone; sub_total = $subTotal
        item = [string]$Progress.item; detail = [string]$Progress.detail
        pct = $pct; elapsed = $elapsed; stage_elapsed = $stageElapsed; eta_stage = $eta
        started_epoch = $(if ($started) { [int64]([DateTimeOffset]$started).ToUnixTimeSeconds() } else { 0 })
        idle_sec = $(if ($updated) { [int][Math]::Max(0, ($Now - $updated).TotalSeconds) } else { 0 })
    }
}

# 기존 registry/모델/미리보기 계약을 사용하는 개인 개발 입력 기능.
. (Join-Path $PSScriptRoot 'LearningLog.Development.ps1')
Export-ModuleMember -Function *-LL*, Remove-ExtraHugoFrontMatter, ConvertTo-LLPublishMarkdown
