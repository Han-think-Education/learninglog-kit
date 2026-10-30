#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Blog Draft — 워킹 노트 → Hugo 블로그 초안 생성

.DESCRIPTION
    하는 것:
      - 03_working_notes\daily_logs\ 의 노트 스캔
      - 대응하는 04_blog_drafts\ 파일이 없는 것만 처리
      - LM Studio 로 Hugo 초안 생성 (draft: true)
      - source_registry.csv status → drafted

    하지 않는 것:
      - blog-source 접촉 없음 (publish 는 run_learninglog_publish.ps1)
      - internal-only 소스 처리 없음
      - 원본 파일 수정 없음

.PARAMETER SourceId
    특정 source_id 만 처리

.PARAMETER TodayOnly
    오늘 등록된 소스의 워킹노트만 처리 (학습일은 어제 등 과거일 수 있음)

.PARAMETER IncludeBacklog
    과거 날짜의 워킹노트까지 처리 (명시적으로 지정한 경우에만)
#>

param(
    [string]$SourceId  = "",
    [switch]$Force,
    [int]$NumCtx       = 8192,
    [int]$MaxCharsPerChunk = 0,
    [ValidateRange(1,4)][int]$MaxConcepts = 2,
    [ValidateSet("lm")][string]$Engine = "lm",   # 호환용(LM Studio 단일 엔진)
    [string]$LMStudioBase  = "http://127.0.0.1:1234",
    [string]$LMStudioModel = "",
    [switch]$TodayOnly,
    [switch]$IncludeBacklog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.Llm.psm1") -Force -DisableNameChecking

$Root         = Get-LLRoot
$RegistryPath = Get-LLRegistryPath
$WorkingDir   = Get-LLPath "03_working_notes\daily_logs"
$DraftsRoot   = Get-LLPath "04_blog_drafts"
$ModelDraft   = ""   # 아래 헬스체크에서 LM Studio 에 로드된 모델로 채운다

$RunDT    = Get-Date
$RunTime  = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$TodayStr = $RunDT.ToString("yyyy-MM-dd")
$TimeStamp = $RunDT.ToString("yyyyMMdd_HHmmss")
$TodayScope = -not $IncludeBacklog

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Blog Draft Generator" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─── LLM 엔진 헬스체크 (LM Studio) ───────────
Write-Host ""
Write-Host "  LM Studio 헬스체크 ... " -ForegroundColor White -NoNewline
try {
    $lmModels = Invoke-RestMethod -Uri "$LMStudioBase/v1/models" -Method Get -TimeoutSec 5 -ErrorAction Stop
    Write-Host "OK" -ForegroundColor Green
} catch {
    Write-Host "FAIL" -ForegroundColor Red
    Write-Host "  LM Studio 서버(:1234)를 먼저 켜세요:  lms server start" -ForegroundColor Yellow
    exit 1
}
if ([string]::IsNullOrWhiteSpace($LMStudioModel)) {
    # 자동감지: 로드된 첫 비임베딩 모델
    $LMStudioModel = @($lmModels.data | Where-Object { $_.id -notmatch 'embed' } | Select-Object -ExpandProperty id)[0]
}
if ([string]::IsNullOrWhiteSpace($LMStudioModel)) {
    Write-Host "  [ERROR] LM Studio에 로드된 모델이 없습니다. 모델을 Load 하세요." -ForegroundColor Red
    exit 1
}
# 지정 모델이 실제 로드 목록에 있는지 확인 — 잘못된 ID면 긴 재시도 대신 즉시 실패.
$mc = Test-LLMModelAvailable -Model $LMStudioModel -LMStudioBase $LMStudioBase
if (-not $mc.ok) {
    Write-Host ("  [ERROR] 모델 '{0}' 이(가) LM Studio에 로드돼 있지 않습니다. Load 후 다시 실행하세요." -f $LMStudioModel) -ForegroundColor Red
    if ($mc.available.Count -gt 0) { Write-Host ("  현재 로드됨: {0}" -f ($mc.available -join ", ")) -ForegroundColor DarkGray }
    exit 1
}
$ModelDraft = $LMStudioModel
Write-Host ("  엔진: LM Studio  모델: {0}" -f $ModelDraft) -ForegroundColor DarkGray

# 공통 슬롯 생성기의 재시도 대상도 이번 실행 엔진으로 고정한다.
Set-LLMRecoveryEndpoint -Engine lm -LMStudioBase $LMStudioBase

# ─── 청크 크기 계산 ──────────────────────────────────────
$DefaultPolicy = Get-LLProcessingPolicy -SourceType "personal_note" -SourceCategory "personal_note" -FileType "md" -ManualChunkChars $MaxCharsPerChunk
Write-Host ("  컨텍스트: {0}토큰 → personal_note direct≤{1}자 / chunk {2}자 / overlap {3}자" -f $NumCtx, $DefaultPolicy.MaxDirectChars, $DefaultPolicy.ChunkChars, $DefaultPolicy.OverlapChars) -ForegroundColor DarkGray

# ─── registry 로드 ────────────────────────────────────────
$schema = Ensure-LLRegistrySchema
if ($schema.upgraded -and $schema.backup) {
    Write-Host ("  registry upgraded: {0}" -f $schema.backup) -ForegroundColor Yellow
}
$registry = Get-LLRegistryRows
$publishedNames = Get-LLPublishedNames   # 06_published 에 있는 글은 draft 지워졌어도 재생성 안 함
$PublishedDirCheck = Get-LLPath "06_published"

# ─── LM Studio (OpenAI 호환) 호출 헬퍼 ────────────────────
function Invoke-LLMText {
    param([string]$Model, [string]$Prompt)
    return Invoke-LLMGenerate -Base $LMStudioBase -Model $Model -Prompt $Prompt -NumPredict 1024 -Temperature 0.3 -EmptyMessage "LM Studio 빈 응답 (모델 thinking 모드가 켜져 있으면 끄세요)"
}

function Test-BlogDraftBadTitle {
    param(
        [string]$Title,
        [string]$Topic
    )
    $t = $Title.Trim()
    if ($t -eq "") { return $true }
    if ($t -match '^(학습 노트|제목|블로그 제목)$') { return $true }
    if ($Topic -and $t.ToLowerInvariant() -eq $Topic.ToLowerInvariant()) { return $true }
    if ($t -match '^[a-z0-9]+(?:[-_][a-z0-9]+){1,}$') { return $true }
    return $false
}

function Get-BlogDraftFallbackTitle {
    param(
        [string]$Topic,
        [string[]]$ConceptNames = @()
    )
    $conceptTitle = @($ConceptNames | Where-Object { $_ -and $_ -ne "학습 내용" } | Select-Object -First 2)
    if ($conceptTitle.Count -gt 0) {
        return (($conceptTitle -join "와 ") + " 이해하기")
    }
    $words = @($Topic -split '[-_]' | Where-Object { $_ })
    if ($words.Count -eq 0) { return "학습 내용 정리" }
    $textInfo = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    return ($textInfo.ToTitleCase(($words -join " ")) + " 정리")
}

function Get-BlogDraftTitle {
    param(
        [string]$Topic,
        [string]$NoteContext,
        [string[]]$ConceptNames,
        [scriptblock]$LLMInvoker
    )
    $conceptText = if ($ConceptNames.Count -gt 0) { ($ConceptNames -join ", ") } else { "학습 내용" }
    $ctx = $NoteContext
    if ($ctx.Length -gt 2500) { $ctx = $ctx.Substring(0, 2500) }
    $prompt = @"
아래 워킹노트로 Hugo 블로그 글 제목을 한 줄로 지어라.
- 한국어 제목
- 12~45자
- 따옴표, 마크다운, 설명 금지
- '$Topic' 같은 파일명/slug 그대로 금지
- '학습 노트'라는 표현 금지

topic: $Topic
핵심 개념: $conceptText

워킹노트:
---
$ctx
---
"@
    $title = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt $prompt
    $title = (($title -split '\r?\n') | Select-Object -First 1).Trim()
    $title = $title.Trim("#").Trim().Trim('"').Trim("'").Trim()
    if (Test-BlogDraftBadTitle -Title $title -Topic $Topic) {
        $title = Get-BlogDraftFallbackTitle -Topic $Topic -ConceptNames $ConceptNames
    }
    return $title
}

function Test-BlogDraftSlugTitle {
    param([string]$Title)
    $t = $Title.Trim()
    if ($t -eq "") { return $true }
    if ($t -match '^(am|pm)-\d{2}-') { return $true }
    if ($t -match '^[a-z0-9]+(?:[-_][a-z0-9]+){1,}$') { return $true }
    return $false
}

function Get-BlogDraftSectionFallbackTitle {
    param([string]$Topic)
    $stem = $Topic -replace '^(am|pm)-\d{2}-', ''
    $words = @($stem -split '[-_]' | Where-Object { $_ })
    if ($words.Count -eq 0) { return "학습 내용 정리" }

    $known = @{
        "sql" = "SQL"; "sqlite" = "SQLite"; "erd" = "ERD"; "join" = "JOIN";
        "groupby" = "GROUP BY"; "having" = "HAVING"; "rank" = "RANK";
        "ntile" = "NTILE"; "lag" = "LAG"; "lead" = "LEAD"; "mom" = "MoM";
        "rollup" = "ROLLUP"; "cube" = "CUBE"; "union" = "UNION";
        "all" = "ALL"; "view" = "VIEW"; "dual" = "DUAL"; "plsql" = "PL/SQL";
        "classicmodels" = "ClassicModels"; "strftime" = "strftime";
        "over" = "OVER"; "partition" = "PARTITION"; "current" = "CURRENT";
        "row" = "ROW"
    }

    $parts = @($words | ForEach-Object {
        $w = $_.ToLowerInvariant()
        if ($known.ContainsKey($w)) { $known[$w] } else { $w }
    })
    return (($parts -join " ") + " 이해하기")
}

function Get-BlogDraftSectionTitle {
    param(
        [string]$Title,
        [string]$Topic,
        [string]$NoteContext,
        [scriptblock]$LLMInvoker
    )
    $candidate = $Title.Trim()
    if (-not (Test-BlogDraftSlugTitle -Title $candidate)) { return $candidate }

    $ctx = $NoteContext
    if ($ctx.Length -gt 2200) { $ctx = $ctx.Substring(0, 2200) }
    $prompt = @"
아래 워킹노트로 daily 합본 글의 섹션 제목을 한 줄로 지어라.
- 한국어 제목
- 12~45자
- 따옴표, 마크다운, 설명 금지
- '$Topic' 같은 파일명/slug 그대로 금지
- 목차에 들어가도 자연스러운 제목

topic: $Topic
현재 제목: $Title

워킹노트:
---
$ctx
---
"@
    $sectionTitle = Get-LLFieldText -LLMInvoker $LLMInvoker -Prompt $prompt
    $sectionTitle = (($sectionTitle -split '\r?\n') | Select-Object -First 1).Trim()
    $sectionTitle = $sectionTitle.Trim("#").Trim().Trim('"').Trim("'").Trim()
    if (Test-BlogDraftSlugTitle -Title $sectionTitle) {
        $sectionTitle = Get-BlogDraftSectionFallbackTitle -Topic $Topic
    }
    return $sectionTitle
}

function Invoke-LLMTextChunked { param([string]$Model, [string]$Instruction, [string]$Body, [int]$MaxChars, [int]$DirectChars = 0, [int]$OverlapChars = 0)
    if (($DirectChars -gt 0 -and $Body.Length -le $DirectChars) -or $Body.Length -le $MaxChars) {
        return Invoke-LLMText -Model $Model -Prompt ($Instruction + "`n---`n" + $Body)
    }
    $chunks = Split-LLTextChunks -Text $Body -MaxChars $MaxChars -OverlapChars $OverlapChars
    Write-Host ("      청킹: {0} 파트 (각 ~{1}자, overlap {2}자)" -f $chunks.Count, $MaxChars, $OverlapChars) -ForegroundColor DarkGray
    $parts = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        Write-Host ("      파트 {0}/{1} " -f ($i+1), $chunks.Count) -ForegroundColor DarkGray -NoNewline
        $parts.Add((Invoke-LLMText -Model $Model -Prompt ($Instruction + "`n(파트 $($i+1)/$($chunks.Count))`n---`n" + $chunks[$i])))
        Write-Host "OK" -ForegroundColor Green
    }
    if ($parts.Count -eq 1) { return $parts[0] }
    return $parts -join "`n`n---`n`n"
}

function Get-LLWorkingNoteDate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FallbackDate
    )

    # 업로드/등록일(date_added)과 실제 학습일(note_date)은 다를 수 있다.
    # 늦게 업로드한 노트도 원래 학습일을 글 날짜로 유지한다.
    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
        $inFrontMatter = ($lines.Count -gt 0 -and $lines[0].Trim() -eq '---')
        for ($i = 1; $i -lt $lines.Count -and $inFrontMatter; $i++) {
            if ($lines[$i].Trim() -eq '---') { break }
            if ($lines[$i] -match '^\s*note_date:\s*(\d{4}-\d{2}-\d{2})\s*$') {
                return $Matches[1]
            }
        }
    } catch {}

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($baseName -match '^(\d{4}-\d{2}-\d{2})_(?:am|pm)-') {
        return $Matches[1]
    }
    return $FallbackDate
}

function Get-LLWorkingNoteSourceId {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
        $inFrontMatter = ($lines.Count -gt 0 -and $lines[0].Trim() -eq '---')
        for ($i = 1; $i -lt $lines.Count -and $inFrontMatter; $i++) {
            if ($lines[$i].Trim() -eq '---') { break }
            $line = $lines[$i]
            if ($line -match '^\s*source_id:\s*(.+?)\s*$') { return $Matches[1].Trim() }
        }
    } catch {}
    return ""
}

# ─── 워킹 노트 스캔 ──────────────────────────────────────
$workingFiles = @(Get-ChildItem -Path $WorkingDir -Filter "*.md" -File | Sort-Object Name)
if ($TodayScope) {
    # 기본 범위는 '파일 날짜가 오늘'이 아니라 '오늘 등록된 소스'다.
    # 어제 학습하고 오늘 업로드한 노트도 포함하되, 과거 backlog는 열지 않는다.
    $workingFiles = @($workingFiles | Where-Object {
        $sid = Get-LLWorkingNoteSourceId -Path $_.FullName
        if (-not $sid) { return $false }
        $row = @($registry | Where-Object { $_.source_id -eq $sid } | Select-Object -First 1)
        if ($row.Count -eq 0) { return $false }
        $uploadDate = ([string]$row.date_added).Trim()
        if ($uploadDate.Length -gt 10) { $uploadDate = $uploadDate.Substring(0, 10) }
        $st = ([string]$row.status).Trim().ToLowerInvariant()
        # 오늘 등록분 + 아직 초안 안 된 미완성(working) 잔여를 함께 처리한다(날짜가 넘어가도 안 끊김).
        ($uploadDate -eq $TodayStr) -or ($st -eq "working")
    })
    Write-Host ("  워킹 노트: {0} 개 (오늘 등록분: {1}, 학습일 무관)" -f $workingFiles.Count, $TodayStr) -ForegroundColor Yellow
} else {
    Write-Host ("  워킹 노트: {0} 개" -f $workingFiles.Count) -ForegroundColor Yellow
}

$doneCount = 0; $skipCount = 0; $errCount = 0

# ─── [합본] am/pm 노트 → 하루 = 오전 1편 + 오후 1편 ─────────
#   워킹노트 이름이 'YYYY-MM-DD_am-…' / 'YYYY-MM-DD_pm-…' 이면 날짜·반일별로 묶어
#   합본 글 1편(YYYY-MM-DD-{am|pm}-daily.md)을 생성한다. 묶인 노트는 개별 생성에서 제외.
$consumed = [System.Collections.Generic.HashSet[string]]::new()
$llmTextG = { param($p) Invoke-LLMText -Model $ModelDraft -Prompt $p }

$groups = @{}
foreach ($wf in $workingFiles) {
    if ($wf.BaseName -match '^(\d{4}-\d{2}-\d{2})_(am|pm)-') {
        $gk = "{0}|{1}" -f $Matches[1], $Matches[2]
        if (-not $groups.ContainsKey($gk)) { $groups[$gk] = [System.Collections.Generic.List[object]]::new() }
        $groups[$gk].Add($wf)
    }
}

# 컨트롤센터 진행바용: 이번 단계에서 만들 글 수 = am/pm 합본 + 개별 노트
$progTotal = $groups.Count + @($workingFiles | Where-Object { $_.BaseName -notmatch '^(\d{4}-\d{2}-\d{2})_(am|pm)-' }).Count
$progIdx = 0

foreach ($gk in ($groups.Keys | Sort-Object)) {
    $gDate, $gHalf = $gk -split '\|'
    $gFiles = $groups[$gk]
    foreach ($f in $gFiles) { $null = $consumed.Add($f.FullName) }   # 합본 대상은 개별 생성 금지

    $halfKo = if ($gHalf -eq "am") { "오전" } else { "오후" }
    $dailyName = "$gDate-$gHalf-daily.md"
    $dailyPath = Join-Path (Join-Path $DraftsRoot "learning") $dailyName

    Write-Host ""
    Write-Host ("  [합본] {0} {1} — 노트 {2}개" -f $gDate, $halfKo, $gFiles.Count) -ForegroundColor Magenta
    $progIdx++
    Set-LLJobItem -Done ($progIdx - 1) -Total $progTotal -Item ("{0} {1} 합본 (노트 {2}개)" -f $gDate, $halfKo, $gFiles.Count) -Detail "노트 제목 정리" -SubDone 0 -SubTotal ($gFiles.Count + 1)

    # 같은 날짜·반일의 합본이 이미 있으면 skip (수동/GPT 합본 'YYYY-MM-DD-am-*.md' 포함)
    $already = @(Get-ChildItem -Path $PublishedDirCheck -Filter "$gDate-$gHalf-*.md" -ErrorAction SilentlyContinue) +
               @(Get-ChildItem -Path (Join-Path $DraftsRoot "learning") -Filter "$gDate-$gHalf-*.md" -ErrorAction SilentlyContinue)
    if ($already.Count -gt 0 -and -not $Force) {
        Write-Host ("    daily_draft ... SKIP (이미 존재: {0})" -f $already[0].Name) -ForegroundColor DarkGray
        $skipCount++; continue
    }

    try {
        # 멤버 노트 수집 (policy 통과분만)
        $members = @()
        foreach ($f in $gFiles) {
            $sidM = ""
            foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
                if ($ln -match "^source_id:\s*(.+)") { $sidM = $Matches[1].Trim(); break }
            }
            $rowM = $registry | Where-Object { $_.source_id -eq $sidM } | Select-Object -First 1
            if ($null -eq $rowM) { continue }
            if (-not (Test-LLPublishableSource $rowM)) { continue }
            $statusM = ""
            if ($rowM.PSObject.Properties['status']) { $statusM = ([string]$rowM.status).Trim().ToLowerInvariant() }
            if ($statusM -in @('rejected','needs_review','archived')) { continue }
            $rawM = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            $ctxM = Remove-ExtraHugoFrontMatter -Text $rawM -KeepTrailingWhitespace
            if ($ctxM.Length -gt 3500) { $ctxM = $ctxM.Substring(0, 3500) }
            $titleM = ""
            if ($rawM -match '(?m)^\s*title:\s*"?(.+?)"?\s*$') { $titleM = $Matches[1].Trim() }
            if (-not $titleM) { $titleM = $rowM.topic }
            $titleM = Get-BlogDraftSectionTitle -Title $titleM -Topic $rowM.topic -NoteContext $ctxM -LLMInvoker $llmTextG
            $tagsM = @()
            if ($rawM -match '(?m)^\s*(recommended_)?tags:\s*\[(.+?)\]') {
                $tagsM = @($Matches[2] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })
            }
            $members += [pscustomobject]@{ Sid = $sidM; Title = $titleM; Ctx = $ctxM; Tags = $tagsM }
        }
        if ($members.Count -eq 0) {
            Write-Host "    daily_draft ... SKIP (사용 가능한 멤버 노트 없음)" -ForegroundColor DarkGray
            $skipCount++; continue
        }

        Write-Host ("    daily_draft ... {0} " -f $ModelDraft) -ForegroundColor White -NoNewline
        Set-LLJobItem -SubDone 0 -SubTotal ($members.Count + 1) -Detail "섹션 작성 준비"

        # 노트당 섹션 1개 채우기 (칸별 plain-text, 회복 대기 내장)
        $rule = " 마크다운 헤딩(#) 금지. 학습자 1인칭 한국어. 강의 원문 복붙 금지. 사족 없이 본문만 출력."
        $sections = @()
        $mi = 0
        foreach ($m in $members) {
            Set-LLJobItem -SubDone $mi -Detail ("섹션 {0}/{1} 작성 · {2}" -f ($mi + 1), $members.Count, $m.Title)
            $ctx = "학습 노트:`n---`n$($m.Ctx)`n---`n"
            $sections += [pscustomobject]@{
                Heading    = $m.Title
                Learned    = (Get-LLFieldText -LLMInvoker $llmTextG -Prompt ($ctx + "이 노트에서 무엇을 배웠는지 2~4문장으로 써라." + $rule))
                Confused   = (Get-LLFieldText -LLMInvoker $llmTextG -Prompt ($ctx + "처음에 헷갈렸거나 오해했던 점을 2~3문장으로 써라." + $rule))
                Understood = (Get-LLFieldText -LLMInvoker $llmTextG -Prompt ($ctx + "최종적으로 정리된 이해를 2~3문장으로 써라." + $rule))
                Code       = (Get-LLFieldText -LLMInvoker $llmTextG -AllowEmpty -Prompt ($ctx + "핵심을 보여주는 코드 예시'만' 백틱3개 코드블록으로 출력하라. 노트에 코드 근거가 없으면 아무것도 쓰지 마라."))
            }
            $mi++
        }
        Set-LLJobItem -SubDone $members.Count -Detail "총평·제목 생성"

        # 총평 + 제목
        $digest = ($sections | ForEach-Object { "- " + $_.Heading + ": " + $_.Learned }) -join "`n"
        $rctx = "오늘 $halfKo 학습 요약:`n$digest`n"
        $review = [pscustomobject]@{
            learned = (Get-LLFieldText -LLMInvoker $llmTextG -Prompt ($rctx + "'오늘 $halfKo 전체에서 배운 것'을 2~3문장으로 써라." + $rule))
            caution = (Get-LLFieldText -LLMInvoker $llmTextG -Prompt ($rctx + "'다음에 조심할 것'을 2~3문장으로 써라." + $rule))
            review  = (Get-LLFieldText -LLMInvoker $llmTextG -Prompt ($rctx + "'다음에 복습할 주제'를 2~3문장으로 써라." + $rule))
        }
        $gTitle = (Get-LLFieldText -LLMInvoker $llmTextG -Prompt ($rctx + "이 $halfKo 학습글의 블로그 제목을 지어라. 반드시 한 줄, 20~42자, 핵심 주제 1개만 사용하라. '오늘', '$halfKo', '정리했습니다', '학습 노트'는 쓰지 말고, 문장이나 설명·목록·줄바꿈 없이 제목만 출력하라." + $rule))
        if (-not $gTitle -or $gTitle -match '학습 노트') { $gTitle = $members[0].Title }
        $gTags = @($members | ForEach-Object { $_.Tags } | Select-Object -Unique | Select-Object -First 8)

        $resultG = New-LLDailyPost -Title $gTitle -Date $gDate -Half $gHalf -Sections $sections -Review $review -Tags $gTags
        if (-not (Test-Path (Join-Path $DraftsRoot "learning"))) { New-Item -ItemType Directory -Path (Join-Path $DraftsRoot "learning") -Force | Out-Null }
        [System.IO.File]::WriteAllText($dailyPath, $resultG, [System.Text.Encoding]::UTF8)

        # 합본 글 레지스트리 등록 (topic=파일명stem) — approve 의 NO REGISTRY 차단 방지
        $stemG = [System.IO.Path]::GetFileNameWithoutExtension($dailyName)
        $regAll = @(Import-Csv -LiteralPath $RegistryPath -Encoding utf8)
        if (-not ($regAll | Where-Object { $_.topic -eq $stemG })) {
            $fieldsG = @(Get-LLRegistryFields)
            $o = [ordered]@{}; foreach ($fd in $fieldsG) { $o[$fd] = "" }
            $o.source_id = "SRC-" + ($gDate -replace '-','') + "-9" + $(if ($gHalf -eq "am") { "01" } else { "02" })
            $o.source_path = "04_blog_drafts/learning/$dailyName"
            $o.file_name = $dailyName; $o.file_type = "md"
            $o.source_type = "blog_draft"; $o.source_category = "daily_merged"
            $o.date_added = $gDate; $o.created_at = $gDate; $o.status = "drafted"
            $o.topic = $stemG; $o.language = "korean"; $o.public_policy = "public"
            $o.notes = "am/pm 합본 자동 생성"
            (@($regAll) + @([pscustomobject]$o)) | Export-Csv -LiteralPath $RegistryPath -Encoding utf8 -NoTypeInformation
            $registry = Get-LLRegistryRows
        }

        # 멤버 노트 상태 → drafted (합본으로 소비됨)
        foreach ($m in $members) { $null = Set-LLRegistryStatus -SourceId $m.Sid -Status "drafted" }

        $issG = @(Get-LLDraftQualityIssues -Content $resultG -Section "learning")
        if ($issG.Count -gt 0) {
            Write-Host ("WARN ({0})" -f ($issG -join ", ")) -ForegroundColor Yellow
        } else {
            Write-Host "OK" -ForegroundColor Green
        }
        Write-Host ("    저장: 04_blog_drafts\learning\{0}" -f $dailyName) -ForegroundColor DarkGray
        $doneCount++
    } catch {
        Write-Host "FAIL" -ForegroundColor Red
        Write-Host ("    [ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        $errCount++
    }
}

foreach ($wf in $workingFiles) {
    if ($consumed.Contains($wf.FullName)) { continue }   # am/pm 합본으로 소비됨 — 개별 생성 안 함
    $progIdx++
    Set-LLJobItem -Done ($progIdx - 1) -Total $progTotal -Item $wf.BaseName -Detail "개별 초안 작성" -SubDone 0 -SubTotal 0

    # front matter 에서 source_id 파싱
    $lines = [System.IO.File]::ReadAllLines($wf.FullName, [System.Text.Encoding]::UTF8)
    $sid   = ""
    foreach ($ln in $lines) {
        if ($ln -match "^source_id:\s*(.+)") { $sid = $Matches[1].Trim(); break }
    }

    if ($sid -eq "") { Write-Host ("  [SKIP] {0} — source_id 없음" -f $wf.Name) -ForegroundColor DarkGray; $skipCount++; continue }
    if ($SourceId -ne "" -and $sid -ne $SourceId) { continue }

    # registry 에서 소스 정보 조회
    $row = $registry | Where-Object { $_.source_id -eq $sid } | Select-Object -First 1
    if ($null -eq $row) { Write-Host ("  [SKIP] {0} — registry 없음" -f $sid) -ForegroundColor DarkGray; $skipCount++; continue }
    if (-not (Test-LLPublishableSource $row)) {
        Write-Host ("  [SKIP] {0} — publish policy/category gate" -f $sid) -ForegroundColor DarkGray; $skipCount++; continue
    }

    # 수동 관리 상태는 자동 재생성 금지. 다시 처리하려면 레지스트리 상태를 먼저 되돌린다.
    $rowStatus = ""
    if ($row.PSObject.Properties['status']) { $rowStatus = ([string]$row.status).Trim().ToLowerInvariant() }
    if ($rowStatus -in @('rejected','needs_review','archived')) {
        Write-Host ("  [SKIP] {0} — {1} (수동 관리 상태)" -f $sid, $rowStatus) -ForegroundColor DarkGray
        $skipCount++; continue
    }

    $topic   = $row.topic
    $section = "learning"  # 기본값

    # classify JSON 에서 section 파싱 시도
    $classifyPath = Join-Path $Root "09_reports\llm_prep\processed\classify_$sid.json"
    if (-not (Test-Path $classifyPath)) {
        $classifyPath = Join-Path $Root "09_reports\llm_prep\classify_$sid.json"
    }
    if (Test-Path $classifyPath) {
        try {
            $cj = [System.IO.File]::ReadAllText($classifyPath, [System.Text.Encoding]::UTF8)
            if ($cj -match '"target_section"\s*:\s*"([^"]+)"') { $section = $Matches[1] }
        } catch {}
    }
    # section 정규화 — learning/projects 2개로만 (생성AI/환경/데이터셋/도구/배포 → projects)
    $section = Get-LLBlogSection -Topic $topic -RawSection $section

    $chunkPolicy = Get-LLProcessingPolicy -SourceType $row.source_type -SourceCategory $row.source_category -FileType $row.file_type -ManualChunkChars $MaxCharsPerChunk
    $ChunkSize = $chunkPolicy.ChunkChars
    $DirectChars = $chunkPolicy.MaxDirectChars
    $OverlapChars = $chunkPolicy.OverlapChars

    $draftDir  = Join-Path $DraftsRoot $section
    $draftPath = Join-Path $draftDir "${topic}.md"

    Write-Host ""
    Write-Host ("  [{0}] {1}" -f $sid, $topic) -ForegroundColor Magenta
    Write-Host ("    LLM 입력 정책 ... direct≤{0}자 / chunk {1}자 / overlap {2}자" -f $DirectChars, $ChunkSize, $OverlapChars) -ForegroundColor DarkGray

    # 이미 발행된 글(06_published)은 draft 가 지워졌어도 재생성하지 않음 (과거 글 재처리 방지)
    if (-not $Force -and $publishedNames.Contains("${topic}.md")) {
        Write-Host "    blog_draft  ... SKIP (이미 발행됨 — 과거 글)" -ForegroundColor DarkGray
        $skipCount++; continue
    }
    if ((Test-Path $draftPath) -and (-not $Force)) {
        Write-Host "    blog_draft  ... SKIP (이미 존재, -Force 로 재생성)" -ForegroundColor DarkGray
        $skipCount++; continue
    }

    Write-Host ("    blog_draft  ... {0} " -f $ModelDraft) -ForegroundColor White -NoNewline

    try {
        if (-not (Test-Path $draftDir)) { New-Item -ItemType Directory -Path $draftDir -Force | Out-Null }

        $wContent = [System.IO.File]::ReadAllText($wf.FullName, [System.Text.Encoding]::UTF8)

        # ── 슬롯 채우기: 구조는 PS 조립, LLM 은 전부 plain-text 한 칸씩 ──
        #   (JSON 호출은 작은 모델에서 잘 깨지고 model runner crash 유발 → 제거)
        $llmText = { param($p) Invoke-LLMText -Model $ModelDraft -Prompt $p }

        # 워킹노트 컨텍스트 (frontmatter 제거 + direct 한도 컷)
        $noteCtx = Remove-ExtraHugoFrontMatter -Text $wContent -KeepTrailingWhitespace
        if ($DirectChars -gt 0 -and $noteCtx.Length -gt $DirectChars) {
            $noteCtx = $noteCtx.Substring(0, $DirectChars)
        }

        # 생성 (placeholder 검출 시 런너 회복 대기 후 1회 전체 재생성 — 글당 최대 2회)
        $result = ""; $draftIssues = @()
        for ($genTry = 1; $genTry -le 2; $genTry++) {
            $conceptNames = @(Get-LLConceptList -NoteContent $noteCtx -LLMInvoker $llmText -MaxConcepts $MaxConcepts)
            if ($conceptNames.Count -eq 0) { $conceptNames = @("학습 내용") }

            $concepts = @()
            foreach ($cn in $conceptNames) {
                $concepts += [pscustomobject]@{
                    Name  = $cn
                    Slots = Get-LLConceptSlots -ConceptName $cn -NoteContext $noteCtx -LLMInvoker $llmText
                }
            }
            $review = Get-LLOverallReview -NoteContent $noteCtx -ConceptNames $conceptNames -LLMInvoker $llmText
            $postTitle = Get-BlogDraftTitle -Topic $topic -NoteContext $noteCtx -ConceptNames $conceptNames -LLMInvoker $llmText

            $postDate = Get-LLWorkingNoteDate -Path $wf.FullName -FallbackDate $TodayStr
            $result = New-LLOutlineFromSlots -Title $postTitle -Date $postDate -Section $section `
                        -Concepts $concepts -Review $review
            $result = Repair-LLIndentedCodeFences -Content $result   # 중첩/들여쓴 코드펜스 평탄화

            $draftIssues = @(Get-LLDraftQualityIssues -Content $result -Row $row -Section $section)
            if (($draftIssues -join " ") -notmatch 'placeholder') { break }   # placeholder 없으면 확정
            if ($genTry -lt 2) {
                Write-Host "    (placeholder 검출 — 현재 엔진 상태 확인 후 전체 재생성)" -ForegroundColor DarkYellow
                $null = Wait-LLMReady
            }
        }
        [System.IO.File]::WriteAllText($draftPath, $result, [System.Text.Encoding]::UTF8)
        if ($draftIssues.Count -gt 0) {
            $null = Set-LLRegistryStatus -SourceId $sid -Status "needs_review"
            Write-Host ("WARN ({0})" -f ($draftIssues -join ", ")) -ForegroundColor Yellow
            Write-Host ("    저장: 04_blog_drafts\{0}\{1}.md" -f $section, $topic) -ForegroundColor DarkGray
            Write-Host "    registry: working → needs_review" -ForegroundColor Yellow
        } else {
            $null = Set-LLRegistryStatus -SourceId $sid -Status "drafted"
            Write-Host "OK" -ForegroundColor Green
            Write-Host ("    저장: 04_blog_drafts\{0}\{1}.md" -f $section, $topic) -ForegroundColor DarkGray
            Write-Host "    registry: working → drafted" -ForegroundColor DarkGray
        }
        $doneCount++
    } catch {
        Write-Host "FAIL" -ForegroundColor Red
        Write-Host ("    [ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        $errCount++
    }
}

Set-LLJobItem -Done $progTotal -Total $progTotal -Item "" -Detail "초안 생성 완료" -SubDone 0 -SubTotal 0

# ─── 요약 ────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  결과 요약" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host ("  생성 완료: {0}" -f $doneCount) -ForegroundColor Green
Write-Host ("  skip:     {0}" -f $skipCount)  -ForegroundColor DarkGray
if ($errCount -gt 0) { Write-Host ("  오류:     {0}" -f $errCount) -ForegroundColor Red }
Write-Host ""
Write-Host "  다음: 컨트롤센터에서 '미리보기·승인 열기' → 승인 후 '발행'" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
