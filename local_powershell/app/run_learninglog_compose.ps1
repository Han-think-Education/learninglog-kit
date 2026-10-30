#Requires -Version 7.0
<#
.SYNOPSIS
    직접 작성 → LLM 정리 → 블로그 초안 (컨트롤센터 '직접 작성' 백엔드)
.DESCRIPTION
    사용자가 직접 쓴 글을 로컬 LLM으로 '문단·맞춤법만' 다듬어 04_blog_drafts 에 초안을 만든다.
    - 내용 추가/삭제 없이 정리만 (사실 왜곡 방지)
    - 항상 최소 1개 `## 소제목` 보장 + 목차 자동 주입 → 기존 미리보기/승인/발행 게이트 통과
    - registry 에 source_category=personal_post(관대한 편집 프로파일) / public_policy=public / status=drafted 로 등록
    - 원본 글은 00_inbox/personal_notes 에 보존(미리보기 '원본 노트'용)
    - 발행(git push)은 하지 않는다 — 미리보기·승인·발행 단계에서 별도로.
.PARAMETER BodyFile   사용자가 쓴 원문(UTF-8) 파일 경로. (필수)
.PARAMETER Title      제목. 비우면 LLM이 제안(실패 시 날짜 기반).
.PARAMETER Date       yyyy-MM-dd. 기본 오늘.
.PARAMETER Section    learning | projects | personal. 기본 learning (폴더 위치용, 게이트는 personal_post 프로파일).
.PARAMETER Tags       쉼표구분 태그. 비우면 빈 배열.
.PARAMETER NoLLM      LLM 없이 원문 그대로 정리(테스트/오프라인).
.PARAMETER OutJson    결과(JSON)를 쓸 경로(서버가 초안 위치를 읽음).
#>
param(
    [Parameter(Mandatory)][string]$BodyFile,
    [string]$Title = "",
    [string]$Date = "",
    [ValidateSet("learning", "projects", "personal")][string]$Section = "learning",
    [string]$Tags = "",
    [switch]$NoLLM,
    [switch]$Rewrite,
    [string]$Slug = "",
    [string]$UploadDir = "",
    [string]$SpecJson = "",
    [string]$OutJson = "",
    [string]$LMStudioBase = "http://127.0.0.1:1234",
    [string]$LMStudioModel = "local-model"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

function Write-Step($msg) { Write-Host ("  " + $msg) -ForegroundColor Cyan }

$Root = Get-LLRoot

# 스펙 JSON(제목/날짜/섹션/태그) — 한글 인자를 커맨드라인 대신 UTF-8 파일로 받아 인코딩 손상 방지.
if ($SpecJson -and (Test-Path -LiteralPath $SpecJson)) {
    try {
        $spec = [System.IO.File]::ReadAllText($SpecJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($spec.PSObject.Properties['title'] -and $spec.title) { $Title = [string]$spec.title }
        if ($spec.PSObject.Properties['date'] -and $spec.date) { $Date = [string]$spec.date }
        if ($spec.PSObject.Properties['section'] -and $spec.section) { $Section = [string]$spec.section }
        if ($spec.PSObject.Properties['tags'] -and $spec.tags) { $Tags = [string]$spec.tags }
    } catch { Write-Host ("  [경고] 스펙 파싱 실패: " + $_.Exception.Message) -ForegroundColor Yellow }
}

if ($Section -notin @("learning", "projects", "personal")) { $Section = "learning" }
if (-not $Date) { $Date = Get-Date -Format "yyyy-MM-dd" }
if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw "Date 형식 오류: $Date (yyyy-MM-dd)" }
if (-not (Test-Path -LiteralPath $BodyFile)) { throw "본문 파일 없음: $BodyFile" }

$raw = [System.IO.File]::ReadAllText($BodyFile, [System.Text.Encoding]::UTF8).Trim()
if (-not $raw) { throw "본문이 비어 있습니다." }

$tagList = @($Tags -split '[,，]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Slug) {
    if ($Slug -notmatch '^[A-Za-z0-9._-]+$') { throw "Slug 형식 오류: $Slug" }
    $slug = $Slug
    if ($slug -match '^(\d{4}-\d{2}-\d{2})') { $Date = $Matches[1] }
} else {
    $stamp = Get-Date -Format "HHmmss"
    $slug = "$Date-post-$stamp"
}

# ── 1) LLM 정리 (문단·맞춤법만) ──────────────────────────────────────────
$aiAssisted = $false
$body = $raw
$llmNote = ""

if (-not $NoLLM) {
    Set-LLMRecoveryEndpoint -Engine "lm" -LMStudioBase $LMStudioBase
    if (Wait-LLMReady) {
        $mc = Test-LLMModelAvailable -Model $LMStudioModel -LMStudioBase $LMStudioBase
        if (-not $mc.ok) {
            $llmNote = "모델 미로드('$LMStudioModel') — 원문 그대로 사용"
            Write-Host ("  [경고] " + $llmNote) -ForegroundColor Yellow
        } else {
            Write-Step "LLM으로 글 정리 중..."
            $invoke = {
                param($p)
                return (Invoke-LLChatCompletion -Prompt $p -Model $LMStudioModel -Base $LMStudioBase -MaxTokens 3072)
            }
            $depth = if ($Rewrite) {
                "- 문단 구성과 흐름을 더 적극적으로 다듬어 읽기 쉽게 재구성해도 된다(사실·정보는 그대로)."
            } else {
                "- 맞춤법·띄어쓰기·문단 정리만. 문장 구조는 최대한 원문을 살려라."
            }
            $rule = @"
다음은 블로그 주인이 직접 쓴 글이다. 아래 원칙으로 '정리'하라.
- 내용을 추가하거나 삭제하지 말고, 사실을 바꾸지 마라.
$depth
- 자연스러운 한국어로. 말투(1인칭/반말/존댓말)는 원문 유지.
- 최소 1개 이상의 `## 소제목` 으로 구획하라(내용에 맞게).
- 머리말·해설·사족 없이 '정리된 본문'만 출력. 코드가 있으면 백틱3개 코드블록 유지.
- 제목 줄(#)이나 front matter(---)는 출력하지 마라.

원문:
---
$raw
---
"@
            $cleaned = (Get-LLFieldText -LLMInvoker $invoke -Prompt $rule).Trim()
            if ($cleaned) { $cleaned = Normalize-LLBodyMarkdown -Text (Repair-LLMTextArtifacts -Text $cleaned) }   # 검수: LLM 잡음·구조 교정
            if ($cleaned) { $body = $cleaned; $aiAssisted = $true; Write-Step "정리 완료." }
            else { $llmNote = "LLM 빈 응답 — 원문 그대로 사용"; Write-Host ("  [경고] " + $llmNote) -ForegroundColor Yellow }

            if (-not $Title) {
                $t = (Get-LLFieldText -LLMInvoker $invoke -Prompt ("다음 글에 어울리는 한국어 제목을 한 줄로만 제안하라(따옴표·기호·머리말 없이).`n---`n$body`n---")).Trim()
                $t = ($t -split "`r?`n")[0].Trim().Trim('"').Trim()
                if ($t -and $t.Length -le 80) { $Title = $t }
            }
        }
    } else {
        $llmNote = "LM Studio 미응답 — 원문 그대로 사용"
        Write-Host ("  [경고] " + $llmNote) -ForegroundColor Yellow
    }
}

if (-not $Title) { $Title = "$Date 기록" }

# ── 2) 구조 보정 (## 최소 1개 보장) ─────────────────────────────────────
if ($body -notmatch '(?m)^##\s+\S') {
    $body = "## " + $Title + "`n`n" + $body
}

# ── 2b) 첨부(사진/오디오/MIDI) → Blog/static 복사 + 본문 삽입 ────────────
#   신규 업로드는 UploadDir 에서 복사, 재정리(-Slug, UploadDir 없음)는 기존 static 폴더에서 재삽입.
$hasMidi = $false
$attachCount = 0
$Hub = Split-Path -Parent $Root
$imgExt = @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")
$audExt = @(".mp3", ".wav", ".ogg", ".m4a", ".flac")
$midExt = @(".mid", ".midi")
$imgLines = @(); $audLines = @(); $midLines = @()
function Add-AttachRef([string]$type, [string]$name) {
    $url = "/$type/$slug/$name"
    switch ($type) {
        "images" { $script:imgLines += ("![{0}]({1})" -f ([System.IO.Path]::GetFileNameWithoutExtension($name)), $url) }
        "audio"  { $script:audLines += ('{{< audio "' + $url + '" >}}') }
        "midi"   { $script:midLines += ('{{< midi "' + $url + '" >}}'); $script:hasMidi = $true }
    }
    $script:attachCount++
}
if ($UploadDir -and (Test-Path -LiteralPath $UploadDir)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $UploadDir -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $ext = $f.Extension.ToLowerInvariant()
        $safe = ($f.Name -replace '[^A-Za-z0-9._-]', '_')
        $type = if ($imgExt -contains $ext) { "images" } elseif ($audExt -contains $ext) { "audio" } elseif ($midExt -contains $ext) { "midi" } else { "" }
        if (-not $type) { Write-Host ("  [건너뜀] 지원하지 않는 형식: " + $f.Name) -ForegroundColor DarkYellow; continue }
        $destDir = Join-Path $Hub ("Blog\static\" + $type + "\" + $slug)
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $destDir $safe) -Force
        Add-AttachRef $type $safe
    }
} elseif ($Slug) {
    # 재정리: 이미 복사된 static 첨부를 그대로 다시 삽입(사진/오디오/MIDI 유지).
    foreach ($type in @("images", "audio", "midi")) {
        $d = Join-Path $Hub ("Blog\static\" + $type + "\" + $slug)
        if (Test-Path -LiteralPath $d) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Sort-Object Name)) { Add-AttachRef $type $f.Name }
        }
    }
}
if ($attachCount -gt 0) {
    $att = [System.Collections.Generic.List[string]]::new()
    $att.Add(""); $att.Add("## 첨부"); $att.Add("")
    foreach ($l in ($imgLines + $audLines + $midLines)) { $att.Add($l); $att.Add("") }
    $body = $body.TrimEnd() + "`n" + ($att -join "`n")
    Write-Step ("첨부 {0}개 삽입 (사진 {1}, 오디오 {2}, MIDI {3})" -f $attachCount, $imgLines.Count, $audLines.Count, $midLines.Count)
}

# ── 2c) 목차 주입 + 코드펜스 복구 ────────────────────────────────────────
$body = Add-LLTableOfContents -Body $body
$body = Repair-LLMarkdownCodeFences -Content $body
$body = ($body -replace "^﻿", "").TrimEnd()

# ── 3) front matter 조립 ─────────────────────────────────────────────────
$safeTitle = ($Title -replace '"', "'").Trim()
$tagsYaml = if ($tagList.Count) { '["' + ($tagList -join '","') + '"]' } else { '[]' }
$fm = [System.Collections.Generic.List[string]]::new()
$fm.Add('---')
$fm.Add("title: `"$safeTitle`"")
$fm.Add("date: $Date")
$fm.Add('draft: true')
$fm.Add("categories: [`"$Section`"]")
$fm.Add("tags: $tagsYaml")
$fm.Add("description: `"$safeTitle`"")
$fm.Add("ai_assisted: " + ($aiAssisted.ToString().ToLower()))
if ($aiAssisted) { $fm.Add('ai_model: "local-llm"') }
if ($hasMidi) { $fm.Add('midi: true') }
$fm.Add('---')
$fm.Add('')
$content = ($fm -join "`n") + "`n" + $body + "`n"

# ── 3b) 자동패치 ①: 형식·구조 검증 후 결정적 보정 ───────────────────────
# personal_post 프로파일 기준으로 QA 게이트를 미리 돌려, 통과 못 하면 결정적 보정을 시도한다.
$probe = [pscustomobject]@{ source_category = "personal_post"; public_policy = "public"; status = "drafted" }
$issues = @(Get-LLDraftQualityIssues -Content $content -Row $probe -Section $Section)
if ($issues.Count -gt 0) {
    $content = Repair-LLMarkdownCodeFences -Content $content
    $issues = @(Get-LLDraftQualityIssues -Content $content -Row $probe -Section $Section)
}
$autopatch = if ($issues.Count -eq 0) { "형식 검증 통과" } else { ("형식 경고 {0}건: {1}" -f $issues.Count, ($issues -join ", ")) }
Write-Step ("자동패치 ①: " + $autopatch)

# ── 4) 초안 + 원본 노트 저장 ─────────────────────────────────────────────
$draftDir = Get-LLPath ("04_blog_drafts\" + $Section)
if (-not (Test-Path -LiteralPath $draftDir)) { New-Item -ItemType Directory -Path $draftDir -Force | Out-Null }
$draftPath = Join-Path $draftDir ($slug + ".md")
Write-LLText -Path $draftPath -Content $content

$noteDir = Get-LLPath "00_inbox\personal_notes"
if (-not (Test-Path -LiteralPath $noteDir)) { New-Item -ItemType Directory -Path $noteDir -Force | Out-Null }
$notePath = Join-Path $noteDir ("PN_" + $Date + "_" + $slug + ".md")
Write-LLText -Path $notePath -Content ($raw + "`n")

# ── 5) registry 등록 (관대한 personal_post 프로파일) ─────────────────────
#   재정리(-Slug)면 같은 topic 기존 행을 지우고 새로 넣어 중복을 막는다.
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($r in @(Get-LLRegistryRows)) { if ((Get-LLProp $r "topic") -ne $slug) { $rows.Add($r) } }
$sid = "SRC-COMPOSE-" + (Get-Date -Format "yyyyMMdd-HHmmssfff")
$noteRel = (Get-LLRelativePath $notePath)
$row = [pscustomobject]@{
    source_id       = $sid
    source_path     = $noteRel
    file_name       = (Split-Path $notePath -Leaf)
    file_path       = $notePath
    file_type       = "md"
    source_type     = "personal_note"
    source_category = "personal_post"
    date_added      = $Date
    created_at      = (Get-Date -Format "yyyy-MM-dd")
    status          = "drafted"
    topic           = $slug
    language        = "korean"
    public_policy   = "public"
    hash            = (Get-LLHash $notePath)
    notes           = "직접 작성"
}
$rows.Add($row)
Save-LLRegistryRows @($rows)

# ── 6) 결과 ──────────────────────────────────────────────────────────────
$draftRel = (Get-LLRelativePath $draftPath)
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host ("  초안 생성 완료: {0}" -f $draftRel) -ForegroundColor Green
Write-Host ("  제목: {0}" -f $Title) -ForegroundColor Green
Write-Host ("  LLM 정리: {0}" -f $(if ($aiAssisted) { "예" } else { "아니오 (" + $llmNote + ")" })) -ForegroundColor Green
Write-Host "  다음: 미리보기 -> 승인 -> 발행" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Green

if ($OutJson) {
    $res = [ordered]@{ ok = $true; draft = $draftRel; slug = $slug; title = $Title; section = $Section; ai_assisted = $aiAssisted; attachments = $attachCount; midi = $hasMidi; autopatch = $autopatch; issues = $issues.Count; note = $llmNote }
    Write-LLText -Path $OutJson -Content ($res | ConvertTo-Json -Compress)
}
