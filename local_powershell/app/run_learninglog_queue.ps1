#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Queue Reporter — 처리 대기 소스 우선순위 리포트 생성

.DESCRIPTION
    하는 것:
      - source_registry.csv 읽기
      - status = registered / new 인 소스 선택
      - source_type / public_policy / topic 별 그룹화
      - 우선순위 정렬 및 권장 행동 추천
      - Markdown 리포트 생성 (09_reports\)

    하지 않는 것:
      - source_registry.csv 수정 없음
      - 원본 파일 수정 없음
      - blog-source 접촉 없음
      - extracted summary 생성 없음
      - LLM 호출 없음

.PARAMETER IncludeBacklog
    과거에 등록됐지만 아직 처리되지 않은 대기 항목까지 포함한다. 기본값은 오늘 등록분만 표시한다.

.NOTES
    읽는 파일: source_registry.csv
    쓰는 파일: 09_reports\queue_report_YYYYMMDD_HHMMSS.md
#>

param(
    [switch]$IncludeBacklog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

# ─────────────────────────────────────────────────────────
# 경로 설정
# ─────────────────────────────────────────────────────────
$Root         = Get-LLRoot
$RegistryPath = Get-LLRegistryPath
$ReportsDir   = Get-LLPath "09_reports"

# ─────────────────────────────────────────────────────────
# 우선순위 / 권장 행동 맵
# ─────────────────────────────────────────────────────────
$PriorityMap = @{
    "personal_note" = 1
    "chat_export"   = 2
    "web_note"      = 3
    "lecture"       = 4
    "practice"      = 5
    "internal_note" = 6
    "screenshot"    = 5
}

$ActionMap = @{
    "personal_note" = "extract + working_note + draft 생성 가능"
    "chat_export"   = "personal_notes 로 분리 후 처리 권장"
    "web_note"      = "개인 노트로 재작성 후 처리 권장"
    "lecture"       = "internal-only extract — 개인 해석 없이 blog draft 불가"
    "practice"      = "ipynb 메타 등록만 — LLM/blog 자동 처리 금지"
    "internal_note" = "내부 체크포인트/인덱스 — LLM/blog 자동 처리 금지"
    "screenshot"    = "hold / 수동 검토 필요"
}

# ─────────────────────────────────────────────────────────
# 타임스탬프
# ─────────────────────────────────────────────────────────
$RunDT     = Get-Date
$RunTime   = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$TimeStamp = $RunDT.ToString("yyyyMMdd_HHmmss")
$TodayStr  = $RunDT.ToString("yyyy-MM-dd")

# ─────────────────────────────────────────────────────────
# 배너
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Queue Reporter" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────
# 1. source_registry.csv 로드
# ─────────────────────────────────────────────────────────
if (-not (Test-Path $RegistryPath)) {
    Write-Host "  [ERROR] source_registry.csv 없음: $RegistryPath" -ForegroundColor Red
    Write-Host "  run_learninglog_intake.ps1 을 먼저 실행하세요." -ForegroundColor Yellow
    exit 1
}

$schema = Ensure-LLRegistrySchema
if ($schema.upgraded -and $schema.backup) {
    Write-Host ("  registry upgraded: {0}" -f $schema.backup) -ForegroundColor Yellow
}
$allSources = Get-LLRegistryRows
Write-Host ""
Write-Host ("  레지스트리 로드: {0} 개 전체" -f $allSources.Count) -ForegroundColor White

# ─────────────────────────────────────────────────────────
# 2. 처리 대기 소스 필터 (registered / new)
# ─────────────────────────────────────────────────────────
$pendingSources = @($allSources | Where-Object { $_.status -in @("registered", "new") })
if ($IncludeBacklog) {
    $queueSources = $pendingSources
    $excludedBacklog = 0
} else {
    $queueSources = @($pendingSources | Where-Object { (Get-LLProp $_ "date_added") -like "$TodayStr*" })
    $excludedBacklog = $pendingSources.Count - $queueSources.Count
}
Write-Host ("  처리 대기:       {0} 개 ({1})" -f $queueSources.Count, $(if($IncludeBacklog){"전체"}else{"오늘"})) -ForegroundColor Yellow
if ($excludedBacklog -gt 0) {
    Write-Host ("  과거 대기 숨김:   {0} 개 (-IncludeBacklog 로 포함)" -f $excludedBacklog) -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────
# 3. 우선순위 정렬
# ─────────────────────────────────────────────────────────
$sorted = $queueSources | Sort-Object {
    $p = $PriorityMap[$_.source_type]
    if ($null -eq $p) { $p = 99 }
    # 같은 type 내에서는 public_policy 우선 (partial-public > public > internal-only)
    $policyScore = switch ($_.public_policy) {
        "partial-public" { 1 }
        "public"         { 2 }
        "internal-only"  { 3 }
        default          { 4 }
    }
    # 정렬 키: type 우선순위 * 10 + policy 점수
    $p * 10 + $policyScore
}

# ─────────────────────────────────────────────────────────
# 4. 분석 데이터 준비
# ─────────────────────────────────────────────────────────

# type별 그룹
$byType = $queueSources | Group-Object source_type | Sort-Object {
    $p = $PriorityMap[$_.Name]
    if ($null -eq $p) { 99 } else { $p }
}

# public_policy별 그룹
$byPolicy = $queueSources | Group-Object public_policy | Sort-Object Count -Descending

# 전체 status 분포
$byStatus = $allSources | Group-Object status | Sort-Object Count -Descending

# Top 10
$top10 = $sorted | Select-Object -First 10

# lecture 대기 목록
$lectureQueue = @($queueSources | Where-Object { $_.source_type -eq "lecture" })

# internal-only 전체 (status 무관)
$internalAll = $allSources | Where-Object { $_.public_policy -eq "internal-only" }

# ─────────────────────────────────────────────────────────
# 5. 콘솔 출력 요약
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  --- source_type 분포 (대기) ---" -ForegroundColor Magenta
foreach ($g in $byType) {
    $action = $ActionMap[$g.Name]
    if ($null -eq $action) { $action = "수동 검토" }
    Write-Host ("    {0,-15} {1,3} 개   → {2}" -f $g.Name, $g.Count, $action) -ForegroundColor White
}

Write-Host ""
Write-Host "  --- 우선 처리 후보 Top 10 ---" -ForegroundColor Magenta
$rank = 1
foreach ($s in $top10) {
    $action = $ActionMap[$s.source_type]
    if ($null -eq $action) { $action = "수동 검토" }
    Write-Host ("    {0,2}. {1}  [{2}]  {3,-30}  {4}" -f `
        $rank, $s.source_id, $s.public_policy, $s.topic, $action) -ForegroundColor Green
    $rank++
}

# ─────────────────────────────────────────────────────────
# 6. 리포트 생성
# ─────────────────────────────────────────────────────────
if (-not (Test-Path $ReportsDir)) {
    New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null
}

$reportName = "queue_report_$TimeStamp.md"
$reportPath = Join-Path $ReportsDir $reportName

# ── 6-1. 요약 현황 테이블 ──────────────────────────────
$summaryLines = [System.Collections.Generic.List[string]]::new()
$summaryLines.Add("| 항목 | 수 |")
$summaryLines.Add("|------|----|")
$summaryLines.Add("| 전체 등록 소스 | $($allSources.Count) |")
$summaryLines.Add("| 처리 대기 (registered/new) | $($queueSources.Count) |")
$summaryLines.Add("| 과거 대기 숨김 | $excludedBacklog |")
$summaryLines.Add("| 즉시 처리 가능 (processable personal_note) | $(@($queueSources | Where-Object { Test-LLMProcessableSource $_ }).Count) |")
$summaryLines.Add("| 강의 대기 (lecture) | $(@($queueSources | Where-Object { $_.source_type -eq 'lecture' }).Count) |")
$summaryLines.Add("| internal-only 전체 | $($internalAll.Count) |")
foreach ($g in $byStatus) {
    $summaryLines.Add("| status = $($g.Name) | $($g.Count) |")
}
$summaryTable = $summaryLines -join "`n"

# ── 6-2. type별 분포 테이블 ───────────────────────────
$typeLines = [System.Collections.Generic.List[string]]::new()
$typeLines.Add("| source_type | 대기 수 | 우선순위 | 권장 행동 |")
$typeLines.Add("|------------|---------|---------|---------|")
foreach ($g in $byType) {
    $pri = $PriorityMap[$g.Name]
    if ($null -eq $pri) { $pri = 9 }
    $act = $ActionMap[$g.Name]
    if ($null -eq $act) { $act = "수동 검토" }
    $typeLines.Add("| $($g.Name) | $($g.Count) | $pri | $act |")
}
$typeTable = $typeLines -join "`n"

# ── 6-3. public_policy별 분포 테이블 ─────────────────
$policyLines = [System.Collections.Generic.List[string]]::new()
$policyLines.Add("| public_policy | 대기 수 |")
$policyLines.Add("|--------------|---------|")
foreach ($g in $byPolicy) {
    $policyLines.Add("| $($g.Name) | $($g.Count) |")
}
$policyTable = $policyLines -join "`n"

# ── 6-4. Top 10 테이블 ────────────────────────────────
$top10Lines = [System.Collections.Generic.List[string]]::new()
$top10Lines.Add("| 순위 | source_id | type | topic | public_policy | 권장 행동 |")
$top10Lines.Add("|------|-----------|------|-------|---------------|---------|")
$r = 1
foreach ($s in $top10) {
    $act = $ActionMap[$s.source_type]
    if ($null -eq $act) { $act = "수동 검토" }
    $top10Lines.Add("| $r | ``$($s.source_id)`` | $($s.source_type) | $($s.topic) | $($s.public_policy) | $act |")
    $r++
}
$top10Table = $top10Lines -join "`n"

# ── 6-5. 강의 대기 목록 ───────────────────────────────
$lectureLines = [System.Collections.Generic.List[string]]::new()
$lectureLines.Add("| source_id | topic | notes |")
$lectureLines.Add("|-----------|-------|-------|")
foreach ($l in $lectureQueue) {
    $lectureLines.Add("| ``$($l.source_id)`` | $($l.topic) | $($l.notes) |")
}
$lectureTable = if ($lectureQueue.Count -gt 0) {
    $lectureLines -join "`n"
} else { "_(없음)_" }

# ── 6-6. 다음 권장 행동 ───────────────────────────────
$immediateQueue = @($queueSources | Where-Object { Test-LLMProcessableSource $_ })
$nextLines = [System.Collections.Generic.List[string]]::new()

if ($immediateQueue.Count -gt 0) {
    $nextLines.Add("**즉시 처리 가능한 소스 ($($immediateQueue.Count)개):**")
    $nextLines.Add("")
    $i = 1
    foreach ($s in ($immediateQueue | Sort-Object { $PriorityMap[$_.source_type] })) {
        $act = $ActionMap[$s.source_type]
        $nextLines.Add("$i. ``$($s.source_id)`` — $($s.source_type) / $($s.topic) / $($s.public_policy)")
        $nextLines.Add("   → $act")
        $i++
    }
    $nextLines.Add("")
}

if ($lectureQueue.Count -gt 0) {
    $nextLines.Add("**강의 처리 ($($lectureQueue.Count)개):**")
    $nextLines.Add("")
    $nextLines.Add("강의 소스는 직접 발행 불가. 순서:")
    $nextLines.Add("")
    $nextLines.Add("1. 강의 내용을 바탕으로 내 이해를 ``00_inbox/personal_notes/`` 에 작성")
    $nextLines.Add("2. 그 personal_note 를 intake → extract → working_note → draft 순서로 처리")
    $nextLines.Add("3. 강의 소스 자체는 ``internal-only`` 유지")
}

$nextSection = $nextLines -join "`n"

# ── 6-7. 리포트 조립 ──────────────────────────────────
$reportLines = [System.Collections.Generic.List[string]]::new()
$reportLines.Add("# LearningLog Queue Report")
$reportLines.Add("")
$reportLines.Add("> 실행 시각: $RunTime")
$reportLines.Add("")
$reportLines.Add("---")
$reportLines.Add("")
$reportLines.Add("## 요약 현황")
$reportLines.Add("")
$reportLines.Add($summaryTable)
$reportLines.Add("")
$reportLines.Add("---")
$reportLines.Add("")
$reportLines.Add("## source_type 별 분포 (처리 대기)")
$reportLines.Add("")
$reportLines.Add($typeTable)
$reportLines.Add("")
$reportLines.Add("---")
$reportLines.Add("")
$reportLines.Add("## public_policy 별 분포 (처리 대기)")
$reportLines.Add("")
$reportLines.Add($policyTable)
$reportLines.Add("")
$reportLines.Add("---")
$reportLines.Add("")
$reportLines.Add("## 우선 처리 후보 Top 10")
$reportLines.Add("")
$reportLines.Add($top10Table)
$reportLines.Add("")
$reportLines.Add("---")
$reportLines.Add("")
$reportLines.Add("## 강의 대기 목록 (internal-only, $($lectureQueue.Count)개)")
$reportLines.Add("")
$reportLines.Add($lectureTable)
$reportLines.Add("")
$reportLines.Add("---")
$reportLines.Add("")
$reportLines.Add("## 다음 권장 행동")
$reportLines.Add("")
$reportLines.Add($nextSection)
$reportLines.Add("")
$reportLines.Add("---")
$reportLines.Add("")
$reportLines.Add("> 자동 생성 리포트. 수정하지 마시오.")
$reportLines.Add("> 이 리포트는 처리 현황 스냅샷이며 source_registry.csv 를 변경하지 않았습니다.")

$reportContent = $reportLines -join "`n"
[System.IO.File]::WriteAllText($reportPath, $reportContent, [System.Text.Encoding]::UTF8)

# ─────────────────────────────────────────────────────────
# 7. 최종 요약
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  결과 요약" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host ("  전체 등록 소스:          {0,4}" -f $allSources.Count)       -ForegroundColor White
Write-Host ("  처리 대기 (reg/new):     {0,4}" -f $queueSources.Count)     -ForegroundColor Yellow
Write-Host ("  즉시 처리 가능:          {0,4}" -f $immediateQueue.Count)   -ForegroundColor Green
Write-Host ("  강의 대기:               {0,4}" -f $lectureQueue.Count)     -ForegroundColor DarkGray
Write-Host ""
Write-Host "  리포트: $reportPath" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
