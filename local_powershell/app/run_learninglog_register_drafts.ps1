#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Register Drafts — 04_blog_drafts 의 미등록 초안을 레지스트리에 등록

.DESCRIPTION
    GPT/외부에서 만든 새 .md 초안을 04_blog_drafts\<section>\ 에 넣은 뒤 이 스크립트를 돌리면:
      - 레지스트리에 매칭 행이 없는 초안을 찾아
      - topic = 파일명(stem), public_policy = public, status = drafted 로 행 추가
      - 이렇게 등록돼야 승인/미리보기에서 "NO REGISTRY" 차단을 면하고 신규로 노출됨
      - 품질 게이트(QA)도 함께 확인해 결과 표로 보여줌

    하지 않는 것:
      - 본문 수정 없음 (등록만)
      - 발행/이동 없음
      - 이미 등록된 초안은 건너뜀 (과거 글 보존)

.PARAMETER Policy
    새로 등록할 초안의 public_policy (기본 public). partial-public 등으로 바꿀 수 있음.
.PARAMETER WhatIfList
    등록하지 않고 대상만 표시

.PARAMETER Section
    특정 섹션만 등록한다. 예: learning, projects
#>

param(
    [ValidateSet("public", "partial-public", "internal-only", "private")]
    [string]$Policy = "public",
    [string]$Section = "",
    [switch]$WhatIfList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$RunDT   = Get-Date
$RunTime = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$Today   = $RunDT.ToString("yyyy-MM-dd")
$null    = Ensure-LLRegistrySchema

$DraftsDir = Get-LLPath "04_blog_drafts"
$regPath   = Get-LLRegistryPath
$fields    = @(Get-LLRegistryFields)
$SectionFilter = $Section.Trim().ToLowerInvariant()

function Get-DraftSection {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $rel = $Draft.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
    $sectionName = ($rel -split "/")[0]
    if (-not $sectionName) { return "learning" }
    return $sectionName.ToLowerInvariant()
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Register Drafts" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $DraftsDir)) {
    Write-Host "  04_blog_drafts 없음." -ForegroundColor Yellow
    exit 0
}

$rows = @(Get-LLRegistryRows)
$topicSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$sidSet   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($r in $rows) {
    $t = Get-LLProp $r "topic";     if ($t) { $null = $topicSet.Add($t) }
    $s = Get-LLProp $r "source_id"; if ($s) { $null = $sidSet.Add($s) }
}

# frontmatter 값 추출
function Get-FM {
    param([string]$Content, [string]$Key)
    $pat = "(?m)^\s*$([regex]::Escape($Key)):\s*`"?(.+?)`"?\s*$"
    if ($Content -match $pat) { return $Matches[1].Trim() }
    return ""
}

# 다음 source_id 생성기 (SRC-YYYYMMDD-NNN, 충돌 회피)
function New-Sid {
    param([string]$DateStr)
    $d = ($DateStr -replace '-', '')
    if ($d.Length -ne 8) { $d = (Get-Date -Format "yyyyMMdd") }
    for ($i = 700; $i -lt 1000; $i++) {
        $cand = "SRC-{0}-{1:D3}" -f $d, $i
        if (-not $sidSet.Contains($cand)) { $null = $sidSet.Add($cand); return $cand }
    }
    return "SRC-$d-{0}" -f (Get-Random -Maximum 99999)
}

$drafts = @(Get-ChildItem -LiteralPath $DraftsDir -Recurse -Filter "*.md" -File | Sort-Object FullName)
if ($SectionFilter) {
    $drafts = @($drafts | Where-Object { (Get-DraftSection $_) -eq $SectionFilter })
}
$toRegister = [System.Collections.Generic.List[object]]::new()

foreach ($d in $drafts) {
    $content = Read-LLText $d.FullName
    $sid = Get-LLDraftSourceId $content
    $stem = $d.BaseName
    $already = ($sid -and $sidSet.Contains($sid)) -or $topicSet.Contains($stem)
    if ($already) { continue }

    $rel = $d.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
    $section = ($rel -split "/")[0]; if (-not $section) { $section = "learning" }
    $date = Get-FM $content "date"; if (-not $date) { $date = $Today }
    $toRegister.Add([pscustomobject]@{ Draft = $d; Stem = $stem; Section = $section; Date = $date; Content = $content })
}

if ($toRegister.Count -eq 0) {
    Write-Host ""
    if ($SectionFilter) {
        Write-Host ("  등록할 미등록 초안이 없습니다. (section={0})" -f $SectionFilter) -ForegroundColor Green
    } else {
        Write-Host "  등록할 미등록 초안이 없습니다. (모두 등록됨)" -ForegroundColor Green
    }
    Write-Host "========================================" -ForegroundColor Cyan
    exit 0
}

Write-Host ""
if ($SectionFilter) {
    Write-Host ("  미등록 초안 {0}개 (section={1})" -f $toRegister.Count, $SectionFilter) -ForegroundColor Yellow
} else {
    Write-Host ("  미등록 초안 {0}개" -f $toRegister.Count) -ForegroundColor Yellow
}
foreach ($x in $toRegister) {
    $iss = @(Get-LLDraftQualityIssues -Content $x.Content -Section $x.Section)
    $qa = if ($iss.Count -eq 0) { "QA PASS" } else { "QA 차단: " + ($iss -join ", ") }
    $col = if ($iss.Count -eq 0) { "Green" } else { "Red" }
    Write-Host ("  - {0}/{1}  [{2}]  ({3})" -f $x.Section, $x.Draft.Name, $qa, $x.Date) -ForegroundColor $col
}

if ($WhatIfList) {
    Write-Host ""
    Write-Host "  [WhatIfList] 등록하지 않고 목록만 표시했습니다." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    exit 0
}

# 레지스트리 행 추가
$newRows = [System.Collections.Generic.List[object]]::new()
foreach ($x in $toRegister) {
    $o = [ordered]@{}
    foreach ($f in $fields) { $o[$f] = "" }
    $o.source_id       = New-Sid $x.Date
    $o.source_path     = "04_blog_drafts/$($x.Section)/$($x.Draft.Name)"
    $o.file_name       = $x.Draft.Name
    $o.file_path       = $x.Draft.FullName
    $o.file_type       = "md"
    $o.source_type     = "blog_draft"
    $o.source_category = $x.Section
    $o.date_added      = $x.Date
    $o.created_at      = $x.Date
    $o.status          = "drafted"
    $o.topic           = $x.Stem
    $o.language        = "korean"
    $o.public_policy   = $Policy
    $o.hash            = ""
    $o.notes           = "register_drafts 자동 등록 ($RunTime)"
    $newRows.Add([pscustomobject]$o)
}

$all = @($rows) + @($newRows)
$all | Export-Csv -LiteralPath $regPath -Encoding utf8 -NoTypeInformation

Write-Host ""
Write-Host ("  등록 완료: {0}개 (public_policy={1}, status=drafted)" -f $newRows.Count, $Policy) -ForegroundColor Green
Write-Host "  다음: [V] preview 로 확인 → [A] approve → [5] publish" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
exit 0
