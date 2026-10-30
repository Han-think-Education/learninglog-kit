#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Repair Drafts - QA 실패/needs_review 초안을 사유별 자동 패치한다.

.DESCRIPTION
    - 기존 초안을 .repair_backup\<timestamp>\04_blog_drafts\... 에 백업한다.
    - auto 모드는 QA 사유별 코드 패치를 먼저 적용하고 LLM 재작성은 하지 않는다.
    - patch 모드는 기존 블로그 초안/합본 구조를 유지하고 문제 지점만 원본으로 채운다.
    - tidy 모드는 기존 블로그 초안/합본을 기준으로 QA 사유만 고쳐 같은 초안 파일을 갱신한다.
    - regenerate 모드는 원본 personal note/daily source bundle만 기준으로 초안을 다시 만든다.
    - 수리 후 QA를 다시 검사해 통과하면 registry status=drafted, 실패하면 needs_review 로 둔다.
    - 발행/승인/publish/blog-source 작업은 하지 않는다.

.PARAMETER DraftPath
    특정 초안 하나만 수리한다. preview 대시보드의 수리 버튼에서 이 모드로 호출된다.

.PARAMETER RestoreLatestBackup
    지정한 DraftPath의 최신 .repair_backup 파일을 복구하고 status를 needs_review 로 둔다.

.PARAMETER Quiet
    preview 서버 호출용. 프롬프트를 줄이고 결과만 간단히 출력한다.

.PARAMETER IncludeBacklog
    오늘 날짜가 아닌 과거 초안도 수리 후보에 포함한다.

.PARAMETER Mode
    auto: QA 사유별 자동 패치. 기본값.
    patch: 기존 초안 구조 유지 + 원본 참고 표적 수리.
    tidy: 기존 초안 기준 정리 수리.
    regenerate: 원본 기준 재생성.
#>

param(
    [string]$DraftPath = "",
    [switch]$All,
    [switch]$RestoreLatestBackup,
    [switch]$Quiet,
    [switch]$IncludeBacklog,
    [string]$Section = "",
    [ValidateSet("auto", "patch", "tidy", "regenerate")]
    [string]$Mode = "auto",
    [int]$NumCtx = 16384,
    [string]$Model = "gemma3:12b",
    [ValidateSet("lm")][string]$Engine = "lm",   # 호환용(LM Studio 단일 엔진)
    [string]$LMStudioBase  = "http://127.0.0.1:1234",
    [string]$LMStudioModel = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.Llm.psm1") -Force -DisableNameChecking

$Root = Get-LLRoot
$DraftsDir = Get-LLPath "04_blog_drafts"
$BackupRoot = Get-LLPath ".repair_backup"
$RunTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$TodayStr = Get-Date -Format "yyyy-MM-dd"
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
# LM Studio 단일 엔진. auto 모드는 LLM 자체를 안 씀.
$SectionFilter = $Section.Trim().ToLowerInvariant()

function Write-Info {
    param([string]$Text, [string]$Color = "White")
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Get-DraftRelPath {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    return (Get-LLRelativePath $Draft.FullName)
}

function Get-DraftDate {
    param([string]$Content)
    if ($Content -match '(?m)^\s*date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})') { return $Matches[1] }
    return (Get-Date -Format "yyyy-MM-dd")
}

function Invoke-LLMRepair {
    param([string]$Prompt)
    return Invoke-LLMGenerate -Base $LMStudioBase -Model $Model -Prompt $Prompt -NumPredict 4096 -Temperature 0.25 -EmptyMessage "LM Studio 빈 응답 (모델 thinking 모드가 켜져 있으면 끄세요)"
}

function Backup-Draft {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $rel = Get-DraftRelPath $Draft
    $dest = Join-Path (Join-Path $BackupRoot $Stamp) ($rel -replace "/", "\")
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $Draft.FullName -Destination $dest -Force
    return $dest
}

function Restore-LatestBackup {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $rel = Get-DraftRelPath $Draft
    $relWin = $rel -replace "/", "\"
    $backups = @(Get-ChildItem -LiteralPath $BackupRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.EndsWith($relWin, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) { throw "backup not found: $rel" }
    Copy-Item -LiteralPath $backups[0].FullName -Destination $Draft.FullName -Force

    $content = Read-LLText $Draft.FullName
    $row = Resolve-LLDraftRegistryRow -Draft $Draft -Content $content
    $sid = Get-LLDraftSourceId $content
    if (-not $sid -and $row) { $sid = Get-LLProp $row "source_id" }
    if ($sid) { $null = Set-LLRegistryStatus -SourceId $sid -Status "needs_review" }
    return $backups[0].FullName
}

function Get-BackupOriginalPath {
    param([Parameter(Mandatory)][System.IO.FileInfo]$BackupFile)
    $rel = $BackupFile.FullName.Substring($BackupRoot.Length).TrimStart("\", "/")
    $parts = $rel -split '[\\/]'
    if ($parts.Count -lt 3) { return "" }
    $relAfterStamp = ($parts[1..($parts.Count - 1)] -join "\")
    return (Join-Path $Root $relAfterStamp)
}

function Restore-BackupFile {
    param([Parameter(Mandatory)][System.IO.FileInfo]$BackupFile)
    $dest = Get-BackupOriginalPath -BackupFile $BackupFile
    if (-not $dest) { throw "cannot resolve backup target: $($BackupFile.FullName)" }
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $BackupFile.FullName -Destination $dest -Force

    $draft = Get-Item -LiteralPath $dest
    $content = Read-LLText $draft.FullName
    $row = Resolve-LLDraftRegistryRow -Draft $draft -Content $content
    $sid = Get-LLDraftSourceId $content
    if (-not $sid -and $row) { $sid = Get-LLProp $row "source_id" }
    if ($sid) { $null = Set-LLRegistryStatus -SourceId $sid -Status "needs_review" }

    return [pscustomobject]@{ backup = $BackupFile.FullName; restored = $dest; source_id = $sid }
}

function Get-LLDraftRepairMetrics {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $placeholders = ([regex]::Matches($Content, '정리 필요|placeholder content')).Count
    $headings = ([regex]::Matches($Content, '(?m)^##\s+')).Count
    return [pscustomobject]@{
        chars = $Content.Length
        headings = $headings
        placeholders = $placeholders
        score = ($headings * 10000) + $Content.Length - ($placeholders * 100000)
    }
}

function Find-LLBetterRepairBackup {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Draft,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentContent
    )
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return $null }

    $rel = Get-DraftRelPath $Draft
    $relWin = $rel -replace "/", "\"
    $currentMetrics = Get-LLDraftRepairMetrics -Content $CurrentContent
    $candidates = @(Get-ChildItem -LiteralPath $BackupRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.EndsWith($relWin, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($candidates.Count -eq 0) { return $null }

    $ranked = foreach ($b in $candidates) {
        $text = Read-LLText $b.FullName
        $metrics = Get-LLDraftRepairMetrics -Content $text
        [pscustomobject]@{
            File = $b
            Content = $text
            Metrics = $metrics
        }
    }
    $best = @($ranked | Sort-Object @{ Expression = { $_.Metrics.score }; Descending = $true }, @{ Expression = { $_.File.LastWriteTime }; Descending = $true } | Select-Object -First 1)
    if ($best.Count -eq 0) { return $null }
    $best = $best[0]

    $currentLooksDamaged = (
        ($currentMetrics.placeholders -gt 0 -and $best.Metrics.placeholders -lt $currentMetrics.placeholders) -or
        ($best.Metrics.headings -ge ($currentMetrics.headings + 3)) -or
        ($best.Metrics.chars -gt 0 -and $currentMetrics.chars -lt [int]($best.Metrics.chars * 0.7) -and $best.Metrics.placeholders -le $currentMetrics.placeholders)
    )
    if (-not $currentLooksDamaged) { return $null }
    return $best
}

function Get-RepairTargets {
    if ($DraftPath) {
        $full = Resolve-LLSafeDraftPath -RelativePath (Get-LLRelativePath $DraftPath)
        return @(Get-Item -LiteralPath $full)
    }

    $all = @(Get-ChildItem -LiteralPath $DraftsDir -Recurse -Filter "*.md" -File | Sort-Object FullName)
    if ($SectionFilter) {
        $all = @($all | Where-Object { (Get-LLDraftSection -Draft $_ -DraftsDir $DraftsDir) -eq $SectionFilter })
    }
    $targets = [System.Collections.Generic.List[object]]::new()
    $script:RepairExcludedBacklog = 0
    foreach ($d in $all) {
        $content = Read-LLText $d.FullName
        $row = Resolve-LLDraftRegistryRow -Draft $d -Content $content
        if (-not (Test-LLTodayDraft -Draft $d -Row $row -TodayStr $TodayStr -IncludeBacklog:$IncludeBacklog)) {
            $script:RepairExcludedBacklog++
            continue
        }
        $badges = Get-LLDraftBadges -Content $content -Row $row -Section (Get-LLDraftSection -Draft $d -DraftsDir $DraftsDir)
        $status = (Get-LLRowProp $row "status").ToLowerInvariant()
        if ((-not $badges.canApprove) -or $status -eq "needs_review") {
            $targets.Add($d)
        }
    }
    return @($targets)
}

function Repair-LLAutoPatchContent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$Title = "",
        [string]$Date = "",
        [string]$Section = "learning",
        [string]$ProfileKey = "learning",
        [ValidateSet("", "am", "pm")][string]$Half = ""
    )
    $text = Remove-ExtraHugoFrontMatter -Text $Content
    $text = Repair-LLIndentedCodeFences -Content $text
    $text = Repair-LLMarkdownCodeFences -Content $text
    $text = Repair-LLSubheadingLevels -Content $text
    if ($ProfileKey -eq "learning") {
        # LearningLog 일일 글만 기존 outline/총평 보정 규칙을 사용한다.
        $text = ConvertTo-LLOutlineArticleStructure -Content $text -FallbackTitle $Title -FallbackDate $Date -FallbackSection $Section
        if ($Half) { $text = Repair-LLDailyFrontMatterTitle -Content $text -Date $Date -Half $Half }
    } else {
        # 프로젝트·리서치·실습·목표 글에는 학습일지 전용 '총평'을 주입하지 않는다.
        $text = Add-LLTableOfContents -Body $text
    }

    # ConvertTo-LLOutlineArticleStructure는 목차 아래 구분선 1개를 허용한다.
    # 그 외 본문 중간의 단독 --- 는 front matter 누출로 보고 제거한다.
    $lines = $text -split "`r?`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    $fmDelims = 0
    $tocDelimiterKept = $false
    $seenToc = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            $out.Add($line)
            continue
        }
        if (-not $inFence -and $line -match '^##\s+목차\s*$') {
            $seenToc = $true
            $out.Add($line)
            continue
        }
        if (-not $inFence -and $line.Trim() -eq "---") {
            $fmDelims++
            if ($fmDelims -le 2) {
                $out.Add($line)
                continue
            }
            if ($seenToc -and -not $tocDelimiterKept) {
                $tocDelimiterKept = $true
                $out.Add($line)
                continue
            }
            continue
        }
        $out.Add($line)
    }
    return (($out -join "`n").TrimEnd() + "`n")
}

function Repair-LLSubheadingLevels {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    # 합본 초안에서 LLM이 소제목을 ##로 올려 쓰는 경우를 보정한다.
    # 정상적인 개념 제목(## 1. ...)과 총평은 유지하고, 소제목/중복 제목만 ###로 내린다.
    $lines = $Content -split "`r?`n"
    $inFence = $false
    $seen = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            continue
        }
        if ($inFence -or $line -notmatch '^(\s*)##(?!#)\s+(.+?)\s*$') { continue }

        $indent = $Matches[1]
        $heading = $Matches[2].Trim()
        $normalized = $heading -replace '^\*\*(.+?)\*\*$', '$1'
        $normalized = ($normalized.Trim().TrimEnd(':').TrimEnd('?') -replace '\s+', ' ')
        $isNumbered = $heading -match '^\d+\.\s+'
        $isReserved = $heading -match '^(목차|총평)$'
        $looksLikeSubheading = $heading -match '(헷갈|정리된 이해|무엇을 배웠|배운 것|실습|초보자|결과와 해석|분석 및 적용 가이드|파일 구조|실행 상태|동작 조건)'
        $isDuplicate = $seen.ContainsKey($normalized)

        if (-not $isNumbered -and -not $isReserved -and ($looksLikeSubheading -or $isDuplicate)) {
            $lines[$i] = $indent + '### ' + $heading
            continue
        }
        if (-not $isReserved) { $seen[$normalized] = $true }
    }
    return ($lines -join "`n")
}

function Repair-OneDraft {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $rel = Get-DraftRelPath $Draft
    $content = Read-LLText $Draft.FullName
    $row = Resolve-LLDraftRegistryRow -Draft $Draft -Content $content
    $section = Get-LLDraftSection -Draft $Draft -DraftsDir $DraftsDir
    $profile = Get-LLDraftEditorialProfile -Row $row -Section $section
    $issues = @(Get-LLDraftQualityIssues -Content $content -Row $row -Section $section)
    $half = ""
    if ($Draft.BaseName -match '(?i)-(am|pm)-daily$') { $half = $Matches[1].ToLowerInvariant() }
    $profileRule = if ($profile.key -eq "learning") {
        "- LearningLog 학습 글이므로 ## 총평을 포함하고, 무엇을 배웠는지·헷갈린 점·다음 복습을 정리한다."
    } else {
        "- $($profile.label) 글이므로 해당 분야의 목표/근거/실행/검증/다음 단계 흐름을 따른다. LearningLog 전용 ## 총평은 강제하지 않는다."
    }
    $title = Get-LLDraftTitle $content
    if (-not $title) { $title = $Draft.BaseName }
    $date = Get-DraftDate $content

    $issueText = if ($issues.Count -gt 0) { $issues -join "; " } else { "registry/status review needed" }

    if ($Mode -eq "auto") {
        $backup = Backup-Draft -Draft $Draft
        $base = Find-LLBetterRepairBackup -Draft $Draft -CurrentContent $content
        $patchSource = "current"
        $patchContent = $content
        if ($base) {
            $patchSource = "backup:" + (Get-LLRelativePath $base.File.FullName)
            $patchContent = [string]$base.Content
            Write-Info ("  기준본: {0}" -f $patchSource) "DarkGray"
        }
        $fixed = Repair-LLAutoPatchContent -Content $patchContent -Title $title -Date $date -Section $section -ProfileKey $profile.key -Half $half
        Write-LLText -Path $Draft.FullName -Content $fixed

        $newIssues = @(Get-LLDraftQualityIssues -Content $fixed -Row $row -Section $section)
        $sid = Get-LLDraftSourceId $fixed
        if (-not $sid -and $row) { $sid = Get-LLProp $row "source_id" }
        $newStatus = if ($newIssues.Count -eq 0) { "drafted" } else { "needs_review" }
        if ($sid) { $null = Set-LLRegistryStatus -SourceId $sid -Status $newStatus }

        return [pscustomobject]@{
            rel = $rel
            mode = $Mode
            source = $patchSource
            backup = Get-LLRelativePath $backup
            status = $newStatus
            issues = ($newIssues -join "; ")
        }
    }

    if ($Mode -eq "regenerate") {
        $orig = Resolve-LLPreviewOriginalNote $row
        $sourceText = [string]$orig.Text
        if ([string]::IsNullOrWhiteSpace($sourceText)) {
            throw "original note not found for regenerate"
        }
        if ($sourceText.Length -gt 18000) { $sourceText = $sourceText.Substring(0, 18000) + "`n...(원본 일부 생략)" }
        $topic = if ($row) { Get-LLProp $row "topic" } else { $Draft.BaseName }
        $category = if ($row) { Get-LLProp $row "source_category" } else { "" }
        $prompt = @"
너는 LearningLog의 Hugo 블로그 초안 재생성 워커다.
아래 원본 노트만 기준으로 블로그 초안을 처음부터 다시 만든다.

반드시 지킬 규칙:
- 기존 초안의 본문은 참고하지 않는다.
- 결과는 완성된 Markdown 전체 글 하나만 출력한다.
- 맨 위에는 Hugo front matter를 한 번만 둔다.
- draft: true 를 유지한다.
- source_id, note_date, model, mode 같은 내부 메타데이터는 쓰지 않는다.
- 원본 강의/자료를 길게 복사하지 말고 학습자의 이해와 정리 중심으로 쓴다.
- 원본에 없는 내용을 상상해서 추가하지 않는다.
- QA 사유를 해결한다: $issueText
- '정리 필요.' 같은 placeholder를 남기지 않는다.
- ## 목차는 직접 만들지 않아도 된다. 시스템이 다시 생성한다.
$profileRule
- 코드 블록은 열고 닫는 펜스를 맞춘다.
- slug 같은 영어 파일명을 제목으로 쓰지 말고 사람이 읽는 한국어 제목을 쓴다.
- daily 합본이면 원본 묶음의 멤버 순서를 유지하고, 멤버마다 자연스러운 한국어 ## 섹션 제목을 만든다.

section: $section
topic: $topic
source_category: $category
날짜: $date

[원본 노트 또는 daily source bundle]
---
$sourceText
---
"@
    } elseif ($Mode -eq "patch") {
        $orig = Resolve-LLPreviewOriginalNote $row
        $sourceText = [string]$orig.Text
        if ([string]::IsNullOrWhiteSpace($sourceText)) {
            throw "original note not found for patch repair"
        }
        $draftText = $content
        if ($sourceText.Length -gt 14000) { $sourceText = $sourceText.Substring(0, 14000) + "`n...(원본 일부 생략)" }
        if ($draftText.Length -gt 14000) { $draftText = $draftText.Substring(0, 14000) + "`n...(초안 일부 생략)" }
        $prompt = @"
너는 LearningLog의 Hugo 블로그 초안 표적 수리 워커다.
기준은 기존 블로그 초안/합본이고, 원본 노트는 빈칸과 문제 지점을 채우는 데만 사용한다.

반드시 지킬 규칙:
- 결과는 완성된 Markdown 전체 글 하나만 출력한다.
- 맨 위에는 Hugo front matter를 한 번만 둔다.
- draft: true 를 유지한다.
- source_id, note_date, model, mode 같은 내부 메타데이터는 쓰지 않는다.
- 기존 초안의 ## 섹션 순서와 범위를 최대한 유지한다.
- 기존 초안에 있는 정상 문단은 삭제하거나 요약하지 않는다.
- '정리 필요.', 빈 총평, 끊긴 문장, slug 제목, 깨진 코드펜스처럼 QA 사유가 있는 부분만 고친다.
- 빈 부분을 채울 때는 원본 노트에서 해당 섹션과 가장 가까운 내용을 찾아 2~4문장으로 채운다.
- 원본에도 근거가 없으면 새 내용을 상상하지 말고, 기존 섹션의 주변 문맥을 자연스럽게 정리해 빈칸이 남지 않게 한다.
- ## 목차는 직접 만들지 않아도 된다. 시스템이 다시 생성한다.
$profileRule
- daily 합본이면 각 멤버 섹션의 제목과 순서를 유지한다. 섹션을 하나로 합치지 않는다.

QA 사유: $issueText
section: $section
기존 제목: $title
날짜: $date

[기존 블로그 초안/합본 - 구조 유지 대상]
---
$draftText
---

[원본 노트 또는 daily source bundle - 빈칸 보충용]
---
$sourceText
---
"@
    } else {
        $draftText = $content
        if ($draftText.Length -gt 18000) { $draftText = $draftText.Substring(0, 18000) + "`n...(초안 일부 생략)" }
        $prompt = @"
너는 LearningLog의 Hugo 블로그 초안 수리 워커다.
아래 기존 블로그 초안/합본만 기준으로 발행 전 미리보기용 글을 고쳐라.

반드시 지킬 규칙:
- 결과는 완성된 Markdown 전체 글 하나만 출력한다.
- 맨 위에는 Hugo front matter를 한 번만 둔다.
- draft: true 를 유지한다.
- source_id, note_date, model, mode 같은 내부 메타데이터는 쓰지 않는다.
- 새 내용을 상상해서 추가하지 말고, 기존 초안에 이미 있는 내용만 정리한다.
- 개인 원본 노트나 source bundle을 추측하지 않는다.
- QA 사유를 해결한다: $issueText
- '정리 필요.' 같은 placeholder를 남기지 않는다.
- ## 목차는 직접 만들지 않아도 된다. 시스템이 다시 생성한다.
$profileRule
- 코드 블록은 열고 닫는 펜스를 맞춘다.
- slug 같은 영어 파일명을 제목으로 쓰지 말고 사람이 읽는 한국어 제목을 쓴다.
- daily 합본 글이면 각 섹션의 순서와 핵심 주제를 유지한다.
- 문체만 다듬고 구조를 복구한다. 글의 주제, 날짜, 범위를 바꾸지 않는다.

section: $section
기존 제목: $title
날짜: $date

[기존 블로그 초안/합본]
---
$draftText
---
"@
    }

    $backup = Backup-Draft -Draft $Draft
    $raw = Invoke-LLMRepair -Prompt $prompt
    $fixed = Remove-ExtraHugoFrontMatter -Text $raw
    $fixed = ConvertTo-LLOutlineArticleStructure -Content $fixed -FallbackTitle $title -FallbackDate $date -FallbackSection $section
    $fixed = Repair-LLIndentedCodeFences -Content $fixed
    Write-LLText -Path $Draft.FullName -Content $fixed

    $newIssues = @(Get-LLDraftQualityIssues -Content $fixed -Row $row -Section $section)
    $sid = Get-LLDraftSourceId $fixed
    if (-not $sid -and $row) { $sid = Get-LLProp $row "source_id" }
    $newStatus = if ($newIssues.Count -eq 0) { "drafted" } else { "needs_review" }
    if ($sid) { $null = Set-LLRegistryStatus -SourceId $sid -Status $newStatus }

    return [pscustomobject]@{
        rel = $rel
        mode = $Mode
        backup = Get-LLRelativePath $backup
        status = $newStatus
        issues = ($newIssues -join "; ")
    }
}

Write-Info ""
Write-Info "========================================" "Cyan"
Write-Info "  LearningLog Draft Repair" "Cyan"
Write-Info "  $RunTime" "Cyan"
Write-Info ("  context: {0} tokens" -f $NumCtx) "DarkGray"
Write-Info ("  mode: {0}" -f $Mode) "DarkGray"
Write-Info "========================================" "Cyan"

if ($RestoreLatestBackup -and -not $DraftPath) {
    $backupFiles = @(Get-ChildItem -LiteralPath $BackupRoot -Recurse -Filter "*.md" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($backupFiles.Count -eq 0) {
        Write-Host "복구할 수리 백업이 없습니다."
        exit 0
    }
    if (-not $All) {
        Write-Info ""
        Write-Info ("  --- 수리 백업 {0} 개 ---" -f $backupFiles.Count) "Magenta"
        $max = [Math]::Min($backupFiles.Count, 30)
        for ($i = 0; $i -lt $max; $i++) {
            $dest = Get-BackupOriginalPath -BackupFile $backupFiles[$i]
            $destRel = if ($dest) { Get-LLRelativePath $dest } else { "?" }
            Write-Info ("  [{0,2}] {1} -> {2}" -f ($i + 1), (Get-LLRelativePath $backupFiles[$i].FullName), $destRel) "DarkGray"
        }
        Write-Info "  [ Q] 취소" "DarkGray"
        $sel = (Read-Host "  복구할 번호 입력").Trim().ToUpper()
        if ($sel -eq "" -or $sel -eq "Q") { Write-Info "  취소됨." "DarkGray"; exit 0 }
        $idx = [int]$sel - 1
        $backupFiles = @($backupFiles[$idx])
    }
    foreach ($bf in $backupFiles) {
        $r = Restore-BackupFile -BackupFile $bf
        Write-Host ("복구 완료: {0}" -f (Get-LLRelativePath $r.restored))
    }
    exit 0
}

$targets = @(Get-RepairTargets)
if ($targets.Count -eq 0) {
    Write-Host "수리 대상 초안이 없습니다."
    if ((Get-Variable -Name RepairExcludedBacklog -Scope Script -ErrorAction SilentlyContinue) -and $script:RepairExcludedBacklog -gt 0) {
        Write-Host ("과거 초안 제외: {0} 개 (-IncludeBacklog 로 포함)" -f $script:RepairExcludedBacklog)
    }
    exit 0
}

if ($RestoreLatestBackup) {
    if (-not $DraftPath) { throw "-RestoreLatestBackup requires -DraftPath" }
    $restored = Restore-LatestBackup -Draft $targets[0]
    Write-Host ("복구 완료: {0}" -f $restored)
    exit 0
}

if (-not $DraftPath -and -not $All) {
    Write-Info ""
    $actionName = if ($Mode -eq "auto") { "패치" } else { "수리" }
    Write-Info ("  --- {0} 대상 {1} 개 ---" -f $actionName, $targets.Count) "Magenta"
    if ((Get-Variable -Name RepairExcludedBacklog -Scope Script -ErrorAction SilentlyContinue) -and $script:RepairExcludedBacklog -gt 0) {
        Write-Info ("  과거 초안 제외: {0} 개 (-IncludeBacklog 로 포함)" -f $script:RepairExcludedBacklog) "DarkGray"
    }
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $c = Read-LLText $targets[$i].FullName
        $row = Resolve-LLDraftRegistryRow -Draft $targets[$i] -Content $c
        $badges = Get-LLDraftBadges -Content $c -Row $row -Section (Get-LLDraftSection -Draft $d -DraftsDir $DraftsDir)
        $why = ($badges.badges | Where-Object { $_.cls -ne "ok" } | ForEach-Object { $_.text }) -join ", "
        Write-Info ("  [{0,2}] {1}" -f ($i + 1), (Get-DraftRelPath $targets[$i])) "DarkGray"
        Write-Info ("       {0}" -f $why) "DarkGray"
    }
    Write-Info ("  [ A] 전체 {0}" -f $actionName) "Yellow"
    Write-Info "  [ Q] 취소" "DarkGray"
    $sel = (Read-Host ("  {0}할 번호 입력 (쉼표로 여러 개)" -f $actionName)).Trim().ToUpper()
    if ($sel -eq "" -or $sel -eq "Q") { Write-Info "  취소됨." "DarkGray"; exit 0 }
    if ($sel -ne "A") {
        $indices = $sel -split "," | ForEach-Object { [int]$_.Trim() - 1 }
        $targets = @($indices | ForEach-Object { $targets[$_] } | Where-Object { $null -ne $_ })
    }
}

if ($Mode -ne "auto") {
    Write-Info ""
    Write-Info "  LM Studio 헬스체크 ... " "White"
    try {
        $lmModels = Invoke-RestMethod -Uri "$LMStudioBase/v1/models" -Method Get -TimeoutSec 5 -ErrorAction Stop
    } catch {
        Write-Host "LM Studio 미실행: $LMStudioBase  (lms server start)"
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($LMStudioModel)) {
        $LMStudioModel = @($lmModels.data | Where-Object { $_.id -notmatch 'embed' } | Select-Object -ExpandProperty id)[0]
    }
    if ([string]::IsNullOrWhiteSpace($LMStudioModel)) { Write-Host "LM Studio에 로드된 모델이 없습니다."; exit 1 }
    $Model = $LMStudioModel
}

$done = 0
$failed = 0
$results = [System.Collections.Generic.List[object]]::new()
foreach ($d in $targets) {
    try {
        $actionName = if ($Mode -eq "auto") { "패치" } else { "수리" }
        Write-Info ("  [{0}] {1}" -f $actionName, (Get-DraftRelPath $d)) "Yellow"
        $result = Repair-OneDraft -Draft $d
        $results.Add($result)
        $done++
        if ($result.status -eq "drafted") {
            Write-Info ("       OK -> {0}" -f $result.status) "Green"
        } else {
            Write-Info ("       REVIEW -> {0}" -f $result.issues) "Yellow"
        }
    } catch {
        $failed++
        Write-Host ("수리 실패: {0} - {1}" -f (Get-DraftRelPath $d), $_.Exception.Message)
    }
}

if ($Quiet) {
    $results | ConvertTo-Json -Depth 4 -Compress
} else {
    Write-Info ""
    Write-Info "========================================" "Cyan"
    Write-Info ("  수리 완료: {0} / 실패: {1}" -f $done, $failed) "White"
    Write-Info "  다음: 미리보기에서 다시 확인하세요." "Cyan"
    Write-Info "========================================" "Cyan"
}

if ($failed -gt 0) { exit 1 }
exit 0
