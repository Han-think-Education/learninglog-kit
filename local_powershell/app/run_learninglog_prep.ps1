#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Phase 3 Prep — LLM task 패킷 조립 (LLM 호출 직전까지만)

.DESCRIPTION
    하는 것:
      - source_registry.csv 읽기
      - 즉시 처리 가능한 소스 선택 (personal_note + public/partial-public + registered/new)
        또는 -SourceId 로 단일 소스 지정
      - 각 소스의 본문을 읽어 LLM task 패킷(markdown) 조립
        (classify / extract / working_note 3개 모드 지시 + 출력형식 + 소스 본문 + 권장 출력경로)
      - 패킷을 09_reports\llm_prep\ 에 저장
      - 매니페스트 생성

    하지 않는 것 (LLM 직전에서 멈춤):
      - LLM 호출 없음
      - source_registry.csv 수정 없음
      - 원본 소스 파일 수정 없음
      - 02_extracted / 03_working_notes / 04_blog_drafts 에 결과물 생성 없음
      - blog-source 접촉 없음
      - 강의(lecture) / internal-only 본문 임베드 없음 (저작권 보호)

.PARAMETER SourceId
    특정 소스 하나만 준비. 생략 시 즉시 처리 가능한 모든 personal_note 준비.

.NOTES
    읽는 파일 : source_registry.csv, 00_inbox\**\*.md
    쓰는 파일 : 09_reports\llm_prep\PREP_<SourceId>.md, 09_reports\llm_prep\_MANIFEST.md
#>

param(
    [string]$SourceId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

# ─────────────────────────────────────────────────────────
# 경로
# ─────────────────────────────────────────────────────────
$Root         = Get-LLRoot
$RegistryPath = Get-LLRegistryPath
$PrepDir      = Get-LLPath "09_reports\llm_prep"

$RunDT     = Get-Date
$RunTime   = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$TodayStr  = $RunDT.ToString("yyyy-MM-dd")

$fence = '```'

# ─────────────────────────────────────────────────────────
# 배너
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Phase 3 Prep (LLM 직전까지)" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────
# 1. 레지스트리 로드
# ─────────────────────────────────────────────────────────
if (-not (Test-Path $RegistryPath)) {
    Write-Host "  [ERROR] source_registry.csv 없음: $RegistryPath" -ForegroundColor Red
    exit 1
}
$schema = Ensure-LLRegistrySchema
if ($schema.upgraded -and $schema.backup) {
    Write-Host ("  registry upgraded: {0}" -f $schema.backup) -ForegroundColor Yellow
}
$all = Get-LLRegistryRows
Write-Host ""
Write-Host ("  레지스트리 로드: {0} 개" -f $all.Count) -ForegroundColor White

# ─────────────────────────────────────────────────────────
# 2. 대상 선정
# ─────────────────────────────────────────────────────────
if ($SourceId -ne "") {
    $targets = @($all | Where-Object { $_.source_id -eq $SourceId })
    if ($targets.Count -eq 0) {
        Write-Host "  [ERROR] source_id 없음: $SourceId" -ForegroundColor Red
        exit 1
    }
} else {
    $targets = @($all | Where-Object {
        $_.status -in @("registered", "new") -and
        (Test-LLMProcessableSource $_)
    })
}

Write-Host ("  준비 대상: {0} 개" -f $targets.Count) -ForegroundColor Yellow
if ($targets.Count -eq 0) {
    Write-Host "  준비할 소스 없음. 종료." -ForegroundColor DarkGray
    exit 0
}

# 안전 필터: internal-only / lecture 는 본문 임베드 금지
$skipped = @($targets | Where-Object { -not (Test-LLMProcessableSource $_) })
$targets = @($targets | Where-Object {
    Test-LLMProcessableSource $_
})
foreach ($s in $skipped) {
    Write-Host ("  [SKIP] {0} — LLM 본문 임베드 금지 ({1}/{2}/{3})" -f $s.source_id, $s.source_type, $s.source_category, $s.public_policy) -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────
# 3. 출력 폴더
# ─────────────────────────────────────────────────────────
if (-not (Test-Path $PrepDir)) {
    New-Item -ItemType Directory -Path $PrepDir -Force | Out-Null
}

$manifestRows = [System.Collections.Generic.List[string]]::new()
$manifestRows.Add("| source_id | topic | policy | 패킷 파일 | 본문 길이 |")
$manifestRows.Add("|-----------|-------|--------|-----------|-----------|")

$madeCount = 0

# ─────────────────────────────────────────────────────────
# 4. 각 소스 패킷 조립
# ─────────────────────────────────────────────────────────
foreach ($s in $targets) {
    $sid    = $s.source_id
    $topic  = $s.topic
    $policy = $s.public_policy
    $srcRel = $s.source_path
    $srcAbs = Resolve-LLSourcePath $srcRel

    # 본문 읽기 (.md/.txt 만)
    $ext = [System.IO.Path]::GetExtension($srcAbs).ToLower()
    $bodyOk = (Test-LLMProcessableSource $s) -and ($ext -eq ".md" -or $ext -eq ".txt") -and (Test-Path $srcAbs)
    if ($bodyOk) {
        $body = [System.IO.File]::ReadAllText($srcAbs, [System.Text.Encoding]::UTF8)
    } else {
        $body = "(본문 임베드 불가: 파일 없음 또는 비텍스트 형식 — $srcRel)"
    }

    $indexGuidance = ""
    $srcName = [System.IO.Path]::GetFileName($srcAbs)
    if ($bodyOk -and $s.source_type -eq "personal_note" -and $s.source_category -eq "personal_note" -and $srcName -match '^PN_(\d{4}-\d{2}-\d{2})_' -and $srcName -notlike "*_INDEX.md") {
        $noteDate = $Matches[1]
        $indexPath = Join-Path (Split-Path -Parent $srcAbs) ("PN_{0}_INDEX.md" -f $noteDate)
        if (Test-Path -LiteralPath $indexPath) {
            $indexGuidance = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8).Trim()
        }
    }

    # 권장 출력 경로
    $extractPath = "02_extracted/concept_extracts/${sid}_${topic}_extract.md"
    $workingPath = "03_working_notes/daily_logs/${TodayStr}_${topic}.md"
    $draftPath   = "04_blog_drafts/learning/${topic}.md"

    $p = [System.Collections.Generic.List[string]]::new()
    $p.Add("# LLM TASK PACKET — $sid")
    $p.Add("")
    $p.Add("> ⚠️ READY FOR LLM — NOT YET EXECUTED")
    $p.Add("> 이 패킷은 LLM 입력 준비물입니다. 아직 모델을 호출하지 않았습니다.")
    $p.Add("> 생성 시각: $RunTime")
    $p.Add("")
    $p.Add("---")
    $p.Add("")
    $p.Add("## 소스 메타데이터")
    $p.Add("")
    $p.Add("| 항목 | 값 |")
    $p.Add("|------|----|")
    $p.Add("| source_id | ``$sid`` |")
    $p.Add("| source_path | ``$srcRel`` |")
    $p.Add("| source_type | $($s.source_type) |")
    $p.Add("| source_category | $($s.source_category) |")
    $p.Add("| file_type | $($s.file_type) |")
    $p.Add("| topic | $topic |")
    $p.Add("| language | $($s.language) |")
    $p.Add("| public_policy | $policy |")
    $p.Add("")
    $p.Add("---")
    $p.Add("")
    $p.Add("## 역할 (LLM 워커)")
    $p.Add("")
    $p.Add("LearningLog 파이프라인 내 로컬 LLM 워커. 입력은 아래 소스 본문 1개.")
    $p.Add("한국어 먼저. 영어 기술용어는 필요할 때만. 학습자의 혼란과 정리된 이해를 보존. 초보자 시점 유지.")
    $p.Add("")
    $p.Add("**금지:** 발행 금지 / blog-source 수정 금지 / 메타데이터 임의 생성 금지 / 강의 원문 장문 복사 금지 / internal-only 로 공개 초안 생성 금지")
    $p.Add("")
    $p.Add("---")
    $p.Add("")
    $p.Add("## 처리 모드 (순서대로)")
    $p.Add("")
    $p.Add("### MODE 1 — classify")
    $p.Add("권장 모델: ``exaone3.5:7.8b``")
    $p.Add("소스를 읽고 아래 메타데이터를 JSON 으로 제안:")
    $p.Add("")
    $p.Add($fence + "json")
    $p.Add("{")
    $p.Add('  "source_type": "",')
    $p.Add('  "topic": "",')
    $p.Add('  "language": "",')
    $p.Add('  "public_policy": "",')
    $p.Add('  "target_section": "learning|goals|practice|projects",')
    $p.Add('  "tags": []')
    $p.Add("}")
    $p.Add($fence)
    $p.Add("")
    $p.Add("### MODE 2 — extract")
    $p.Add("권장 모델: ``exaone3.5:7.8b``")
    $p.Add("소스에서 **사실만** 추출 (해석 금지). 결과 저장 권장 경로:")
    $p.Add("``$extractPath``")
    $p.Add("")
    $p.Add("### MODE 3 — working_note")
    $p.Add("권장 모델: ``exaone3.5:7.8b``")
    $p.Add("아래 항목으로 한국어 working note 초안 작성. 결과 저장 권장 경로:")
    $p.Add("``$workingPath``")
    $p.Add("")
    $p.Add("- 무엇이 헷갈렸나")
    $p.Add("- 정리된 이해")
    $p.Add("- 실습 예시")
    $p.Add("- 초보자 키워드 (의미 + 검색어)")
    $p.Add("- 내 프로젝트 연결")
    $p.Add("")
    $p.Add("(이후 blog_draft 단계 권장 경로: ``$draftPath`` — draft: true 로, 발행은 인간 승인 후)")
    $p.Add("")
    $p.Add("---")
    $p.Add("")
    $p.Add("## 출력 형식 (LLM 이 채울 것)")
    $p.Add("")
    $p.Add($fence + "markdown")
    $p.Add("# Result")
    $p.Add("## Mode")
    $p.Add("## Source Summary")
    $p.Add("## Suggested Metadata")
    $p.Add("## Beginner Keywords")
    $p.Add("## Extracted Summary")
    $p.Add("## Personal Understanding Points")
    $p.Add("## Suggested Next Action")
    $p.Add($fence)
    $p.Add("")
    $p.Add("---")
    $p.Add("")
    if ($indexGuidance -ne "") {
        $p.Add("## INDEX Guidance (참조 전용)")
        $p.Add("")
        $p.Add("> 이 섹션은 같은 날짜 INDEX 노트입니다. 분류/맥락 참고용이며, 발행 본문이나 소스 본문으로 취급하지 마세요.")
        $p.Add("> 여기에 있는 내용은 원문 복사 대상이 아니며, 아래 SOURCE만 실제 처리 대상입니다.")
        $p.Add("")
        $p.Add("<!-- BEGIN INDEX GUIDANCE -->")
        $p.Add("")
        $p.Add($indexGuidance)
        $p.Add("")
        $p.Add("<!-- END INDEX GUIDANCE -->")
        $p.Add("")
        $p.Add("---")
        $p.Add("")
    }
    $p.Add("## 소스 본문 (입력)")
    $p.Add("")
    $p.Add("<!-- BEGIN SOURCE -->")
    $p.Add("")
    $p.Add($body)
    $p.Add("")
    $p.Add("<!-- END SOURCE -->")

    $packetContent = $p -join "`n"
    $packetName = "PREP_$sid.md"
    $packetPath = Join-Path $PrepDir $packetName
    [System.IO.File]::WriteAllText($packetPath, $packetContent, [System.Text.Encoding]::UTF8)

    $bodyLen = if ($bodyOk) { $body.Length } else { 0 }
    Write-Host ("  [PREP] {0}  ->  llm_prep\{1}  (본문 {2}자)" -f $sid, $packetName, $bodyLen) -ForegroundColor Green
    $manifestRows.Add("| ``$sid`` | $topic | $policy | ``$packetName`` | $bodyLen |")
    $madeCount++
}

# ─────────────────────────────────────────────────────────
# 5. 매니페스트
# ─────────────────────────────────────────────────────────
$man = [System.Collections.Generic.List[string]]::new()
$man.Add("# LLM Prep Manifest")
$man.Add("")
$man.Add("> 생성 시각: $RunTime")
$man.Add("> 상태: READY FOR LLM — 아직 실행 안 됨")
$man.Add("")
$man.Add("준비된 패킷: $madeCount 개")
$man.Add("")
$man.AddRange([string[]]$manifestRows)
$man.Add("")
$man.Add("---")
$man.Add("")
$man.Add("## 다음 단계")
$man.Add("")
$man.Add("1. 위 패킷 파일을 LLM 에 입력 (MODE 1 -> 2 -> 3 순서)")
$man.Add("2. 결과를 권장 경로(02_extracted / 03_working_notes)에 저장")
$man.Add("3. source_registry.csv status 를 extracted / working 으로 수동 업데이트")
$man.Add("4. (선택) blog_draft 생성 -> 인간 검토 -> ready_to_publish")
$man.Add("")
$man.Add("> 이 매니페스트와 패킷들은 LLM 입력 준비물이며, 어떤 원본/레지스트리도 변경하지 않았습니다.")

$manContent = $man -join "`n"
$manPath = Join-Path $PrepDir "_MANIFEST.md"
[System.IO.File]::WriteAllText($manPath, $manContent, [System.Text.Encoding]::UTF8)

# ─────────────────────────────────────────────────────────
# 6. 요약
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  결과 요약" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host ("  준비된 패킷:   {0}" -f $madeCount) -ForegroundColor Green
Write-Host ("  제외:          {0}" -f $skipped.Count) -ForegroundColor DarkGray
Write-Host ("  출력 폴더:     {0}" -f $PrepDir) -ForegroundColor White
Write-Host ("  매니페스트:    {0}" -f $manPath) -ForegroundColor White
Write-Host ""
Write-Host "  *** LLM 호출 없음. 다음: [3] extract 로 패킷을 처리하세요. ***" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
