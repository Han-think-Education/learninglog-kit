#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Phase 3 Extract — Ollama 호출로 extract + working_note 자동 생성

.DESCRIPTION
    하는 것:
      - Ollama 헬스체크 (127.0.0.1:11434)
      - 09_reports\llm_prep\PREP_*.md 패킷 로드 및 파싱
      - MODE 1 classify  : exaone3.5:7.8b     → classify_SOURCEID.json
      - MODE 2 extract   : exaone3.5:7.8b     → 02_extracted\concept_extracts\
      - MODE 3 working_note: exaone3.5:7.8b   → 03_working_notes\daily_logs\
      - source_registry.csv status 업데이트 (registered → extracted → working)
      - 처리 완료 패킷 → 09_reports\llm_prep\processed\ 이동
      - 실행 리포트 → 09_reports\extract_report_YYYYMMDD_HHMMSS.md
      - 멱등성: 출력 파일 이미 존재 시 해당 모드 skip

    하지 않는 것 (절대 금지):
      - blog-source 접촉 없음
      - 04_blog_drafts 생성 없음 (draft는 별도 단계, 인간 검토 필요)
      - Hugo build / git commit / git push 없음
      - internal-only 소스 처리 없음
      - lecture 소스 본문 처리 없음 (저작권)
      - processed_ledger.csv 수정 없음

.PARAMETER SourceId
    특정 소스 하나만 처리. 생략 시 전체 PREP 패킷 처리.

.PARAMETER IncludeDraft
    예외적으로 extract 단계 안에서 MODE 4 blog draft까지 실행.
    기본값은 꺼짐. 일반 사용은 MODE 3 working_note에서 끝내고,
    초안 생성은 run_learninglog_blogdraft.ps1 또는 런처 [4]에서 별도 실행한다.

.NOTES
    읽는 파일 : 09_reports\llm_prep\PREP_*.md, 01_registry\source_registry.csv
    쓰는 파일 : 02_extracted\concept_extracts\, 03_working_notes\daily_logs\,
                09_reports\llm_prep\classify_*.json, 09_reports\extract_report_*.md
    이동      : PREP_*.md → 09_reports\llm_prep\processed\
    백업      : 07_archive\backups\source_registry_YYYYMMDD_HHMMSS.csv
#>

param(
    [string]$SourceId      = "",
    [int]$NumCtx           = 8192,  # 실행 컨텍스트. GPU VRAM 부족 시 4096/2048 로 낮춤
    [int]$MaxCharsPerChunk = 0,     # 0 = NumCtx 에서 자동 계산
    [ValidateSet("lm","ollama")]
    [string]$Engine         = "lm",
    [string]$LMStudioBase   = "http://127.0.0.1:1234",
    [string]$LMStudioModel  = "local-model",
    [switch]$IncludeDraft
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

# ─────────────────────────────────────────────────────────
# 경로 설정
# ─────────────────────────────────────────────────────────
$Root         = Get-LLRoot
$RegistryPath = Get-LLRegistryPath
$PrepDir      = Get-LLPath "09_reports\llm_prep"
$ProcessedDir = Join-Path $PrepDir "processed"
$ReportsDir   = Get-LLPath "09_reports"
$BackupDir    = Get-LLPath "07_archive\backups"
$ExtractedDir = Get-LLPath "02_extracted\concept_extracts"
$WorkingDir   = Get-LLPath "03_working_notes\daily_logs"
$OllamaBase   = "http://127.0.0.1:11434"
$UseLM        = $Engine -ieq "lm"

$RunDT     = Get-Date
$RunTime   = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$TodayStr  = $RunDT.ToString("yyyy-MM-dd")
$TimeStamp = $RunDT.ToString("yyyyMMdd_HHmmss")

# ─────────────────────────────────────────────────────────
# 모델 설정
# ─────────────────────────────────────────────────────────
$ModelClassify = if ($UseLM) { $LMStudioModel } else { "exaone3.5:7.8b" }
$ModelExtract  = if ($UseLM) { $LMStudioModel } else { "exaone3.5:7.8b" }
$ModelWorking  = if ($UseLM) { $LMStudioModel } else { "exaone3.5:7.8b" }

# ─────────────────────────────────────────────────────────
# 배너
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Phase 3 Extract" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────
# 1. LLM 엔드포인트 헬스체크
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("  {0} 헬스체크 ... " -f $(if ($UseLM) { "LM Studio" } else { "Ollama" })) -ForegroundColor White -NoNewline
try {
    if ($UseLM) {
        $null = Invoke-RestMethod -Uri "$LMStudioBase/v1/models" -Method Get -TimeoutSec 5 -ErrorAction Stop
        Write-Host "OK ($LMStudioBase)" -ForegroundColor Green
        # 생성 전에 모델 ID가 실제 로드 목록에 있는지 확인 — 잘못된 ID면 긴 재시도 대신 즉시 실패.
        $mc = Test-LLMModelAvailable -Model $LMStudioModel -LMStudioBase $LMStudioBase
        if (-not $mc.ok) {
            Write-Host ("  [ERROR] 모델 '{0}' 이(가) LM Studio에 로드돼 있지 않습니다. Load 후 다시 실행하세요." -f $LMStudioModel) -ForegroundColor Red
            if ($mc.available.Count -gt 0) { Write-Host ("  현재 로드됨: {0}" -f ($mc.available -join ", ")) -ForegroundColor DarkGray }
            exit 1
        }
        Write-Host ("  모델 확인: {0}" -f $LMStudioModel) -ForegroundColor Green
    } else {
        $null = Invoke-RestMethod -Uri "$OllamaBase/" -Method Get -TimeoutSec 5 -ErrorAction Stop
        Write-Host "OK ($OllamaBase)" -ForegroundColor Green
    }
} catch {
    Write-Host "FAIL" -ForegroundColor Red
    if ($UseLM) {
        Write-Host "  [ERROR] LM Studio 서버가 없습니다. 127.0.0.1:1234에서 서버를 켜고 모델을 로드하세요." -ForegroundColor Red
    } else {
        Write-Host "  [ERROR] Ollama 미실행. $OllamaBase 를 먼저 시작하세요." -ForegroundColor Red
        Write-Host "  힌트: ollama serve 또는 Ollama 앱 실행" -ForegroundColor Yellow
    }
    exit 1
}

# ─────────────────────────────────────────────────────────
# 2. PREP 패킷 로드
# ─────────────────────────────────────────────────────────
if (-not (Test-Path $PrepDir)) {
    Write-Host "  [ERROR] llm_prep 폴더 없음: $PrepDir" -ForegroundColor Red
    Write-Host "  run_learninglog_prep.ps1 을 먼저 실행하세요." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $RegistryPath)) {
    Write-Host "  [ERROR] source_registry.csv 없음: $RegistryPath" -ForegroundColor Red
    exit 1
}
$schema = Ensure-LLRegistrySchema
if ($schema.upgraded -and $schema.backup) {
    Write-Host ("  registry upgraded: {0}" -f $schema.backup) -ForegroundColor Yellow
}

if ($SourceId -ne "") {
    $packets = @(Get-ChildItem -Path $PrepDir -Filter "PREP_${SourceId}.md" -File)
} else {
    $packets = @(Get-ChildItem -Path $PrepDir -Filter "PREP_*.md" -File | Sort-Object Name)
}

if ($packets.Count -eq 0) {
    Write-Host "  처리할 PREP 패킷 없음." -ForegroundColor Yellow
    if ($SourceId -ne "") { Write-Host "  지정 ID: $SourceId" -ForegroundColor Yellow }
    else { Write-Host "  run_learninglog_prep.ps1 을 먼저 실행하세요." -ForegroundColor Yellow }
    exit 0
}

Write-Host ("  패킷 로드: {0} 개" -f $packets.Count) -ForegroundColor Yellow

# ─────────────────────────────────────────────────────────
# 3. 사전 준비 — 백업 + 폴더
# ─────────────────────────────────────────────────────────
$backupPath = Join-Path $BackupDir "source_registry_$TimeStamp.csv"
Copy-Item $RegistryPath $backupPath -ErrorAction Stop
Write-Host ("  registry 백업: source_registry_{0}.csv" -f $TimeStamp) -ForegroundColor DarkGray

foreach ($d in @($ProcessedDir, $ExtractedDir, $WorkingDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# ─────────────────────────────────────────────────────────
# 헬퍼: LM Studio/OpenAI 호환 생성 호출
# ─────────────────────────────────────────────────────────
function Invoke-LMStudioGenerate {
    param(
        [string]$Model,
        [string]$Prompt,
        [int]$NumPredict = 512,
        [int]$CtxSize    = 8192
    )
    $bodyObj = [ordered]@{
        model = $Model
        messages = @(
            [ordered]@{ role = "user"; content = $Prompt }
        )
        stream = $false
        temperature = 0.2
        max_tokens = $NumPredict
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($bodyJson)
    # 일시적 blip(순간 400/타임아웃/빈응답) 흡수용 재시도. 지속 실패는 그대로 throw.
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri "$LMStudioBase/v1/chat/completions" -Method Post `
                -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 600 -ErrorAction Stop
            $text = [string]$resp.choices[0].message.content
            if ([string]::IsNullOrWhiteSpace($text)) { throw "LM Studio returned an empty response." }
            return $text
        } catch {
            if ($attempt -ge $maxAttempts) { throw }
            Write-Host ("      [LM 재시도 {0}/{1}] {2}" -f $attempt, $maxAttempts, $_.Exception.Message) -ForegroundColor DarkYellow
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Invoke-OllamaGenerate {
    param(
        [string]$Model,
        [string]$Prompt,
        [int]$NumPredict = 512,   # 출력 토큰 제한 — 입력 여유 확보
        [int]$CtxSize    = 8192   # Ollama 실행 컨텍스트 명시 (스크립트 $NumCtx 와 일치)
    )
    if ($UseLM) {
        return Invoke-LMStudioGenerate -Model $Model -Prompt $Prompt -NumPredict $NumPredict -CtxSize $CtxSize
    }
    $bodyObj = [ordered]@{
        model   = $Model
        prompt  = $Prompt
        stream  = $false
        options = [ordered]@{ num_predict = $NumPredict; num_ctx = $CtxSize }
    }
    $bodyJson  = $bodyObj | ConvertTo-Json -Depth 4 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

    $resp = Invoke-RestMethod `
        -Uri "$OllamaBase/api/generate" `
        -Method Post `
        -Body $bodyBytes `
        -ContentType "application/json; charset=utf-8" `
        -TimeoutSec 600 `
        -ErrorAction Stop

    return $resp.response
}

# ─────────────────────────────────────────────────────────
# 헬퍼: NumCtx 기반 안전 청크 크기 계산 (감지 없이 직접 계산)
# ─────────────────────────────────────────────────────────
function Get-ChunkSize {
    param(
        [int]$CtxLen,
        [string]$SourceType = "personal_note",
        [string]$SourceCategory = "personal_note",
        [string]$FileType = "md"
    )
    return (Get-LLChunkSize -NumCtx $CtxLen -SourceType $SourceType -SourceCategory $SourceCategory -FileType $FileType -ManualChunkChars $MaxCharsPerChunk)
}

# ─────────────────────────────────────────────────────────
# 헬퍼: 텍스트 청킹 (단락 단위)
# ─────────────────────────────────────────────────────────
function Split-IntoChunks {
    param(
        [string]$Text,
        [int]$MaxChars,
        [int]$OverlapChars = 0
    )
    # 빈 줄 기준으로 단락 분리
    $paragraphs = $Text -split "(?m)^\s*$"
    $chunks = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()

    foreach ($para in $paragraphs) {
        $para = $para.Trim()
        if ($para -eq "") { continue }

        if ($current.Length + $para.Length + 2 -gt $MaxChars -and $current.Length -gt 0) {
            $chunks.Add($current.ToString().Trim())
            $null = $current.Clear()
        }
        $null = $current.AppendLine($para)
        $null = $current.AppendLine()
    }
    if ($current.Length -gt 0) { $chunks.Add($current.ToString().Trim()) }

    # 단락 자체가 MaxChars 초과하는 경우 강제 분할
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

# ─────────────────────────────────────────────────────────
# 헬퍼: 청킹 + 병합 LLM 호출
# ─────────────────────────────────────────────────────────
function Invoke-OllamaChunked {
    param(
        [string]$Model,
        [string]$Instruction,   # 고정 지시문 (프롬프트 템플릿)
        [string]$Body,          # 처리할 소스 본문
        [int]$MaxChars,         # 청크당 최대 문자 수
        [int]$DirectChars = 0,
        [int]$OverlapChars = 0
    )

    # 청킹 불필요한 경우 바로 처리
    if (($DirectChars -gt 0 -and $Body.Length -le $DirectChars) -or $Body.Length -le $MaxChars) {
        return Invoke-OllamaGenerate -Model $Model -Prompt ($Instruction + "`n---`n" + $Body) -CtxSize $NumCtx
    }

    $chunks = Split-IntoChunks -Text $Body -MaxChars $MaxChars -OverlapChars $OverlapChars
    Write-Host ("      청킹: {0} 파트 분할 (각 ~{1}자, overlap {2}자)" -f $chunks.Count, $MaxChars, $OverlapChars) -ForegroundColor DarkGray

    # 각 청크 처리
    $partials = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $chunkInstruction = $Instruction + "`n(파트 $($i+1)/$($chunks.Count) — 이 부분만 처리)"
        Set-LLJobItem -Detail ("{0} · 파트 {1}/{2}" -f $script:LHStepLabel, ($i + 1), $chunks.Count)
        Write-Host ("      파트 $($i+1)/$($chunks.Count) " ) -ForegroundColor DarkGray -NoNewline
        $partial = Invoke-OllamaGenerate -Model $Model -Prompt ($chunkInstruction + "`n---`n" + $chunks[$i]) -CtxSize $NumCtx
        $partials.Add($partial)
        Write-Host "OK" -ForegroundColor Green
    }

    # 단일 청크였으면 그대로 반환
    if ($partials.Count -eq 1) { return $partials[0] }

    # 병합 — LLM 재호출 없이 직접 연결 (merge pass도 토큰 한계에 걸리므로)
    Write-Host "      결과 연결 중 ... " -ForegroundColor DarkGray -NoNewline
    $merged = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $partials.Count; $i++) {
        if ($i -gt 0) { $null = $merged.AppendLine("`n---") }
        $null = $merged.AppendLine($partials[$i])
    }
    Write-Host "OK" -ForegroundColor Green

    return $merged.ToString().Trim()
}

function Remove-ExtraHugoFrontMatter {
    param([string]$Text)
    $lines = $Text -split "`r?`n"
    if ($lines.Count -eq 0) { return $Text }

    $start = 0
    if ($lines[0].Trim() -eq "---") {
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq "---") {
                $start = $i + 1
                break
            }
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

    return (($out -join "`n").TrimEnd() + "`n")
}

# ─────────────────────────────────────────────────────────
# 헬퍼: registry status 업데이트
# ─────────────────────────────────────────────────────────
function Update-RegistryStatus {
    param(
        [string]$Sid,
        [string]$NewStatus
    )
    return (Set-LLRegistryStatus -SourceId $Sid -Status $NewStatus)
}

# ─────────────────────────────────────────────────────────
# 4. 기본 청크 정책 표시
# ─────────────────────────────────────────────────────────
$DefaultPolicy = Get-LLProcessingPolicy -SourceType "personal_note" -SourceCategory "personal_note" -FileType "md" -ManualChunkChars $MaxCharsPerChunk

Write-Host ""
Write-Host ("  실행 컨텍스트: {0}토큰  →  personal_note direct≤{1}자 / chunk {2}자 / overlap {3}자" -f $NumCtx, $DefaultPolicy.MaxDirectChars, $DefaultPolicy.ChunkChars, $DefaultPolicy.OverlapChars) -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────
# 5. 패킷 순회 처리
# ─────────────────────────────────────────────────────────
$doneCount = 0
$skipCount = 0
$errCount  = 0
$reportRows = [System.Collections.Generic.List[string]]::new()
$pktTotal = @($packets).Count     # 컨트롤센터 진행바용(LH_JOB_PROGRESS 켜진 실행에서만 기록)
$pktIdx = 0
$script:LHStepLabel = ""

foreach ($pkt in $packets) {

    # ── 4-1. 패킷 파싱 ──────────────────────────────────────
    $fullText = [System.IO.File]::ReadAllText($pkt.FullName, [System.Text.Encoding]::UTF8)
    $pLines   = [System.IO.File]::ReadAllLines($pkt.FullName, [System.Text.Encoding]::UTF8)

    $sid    = ""
    $topic  = ""
    $policy = ""
    $stype  = ""
    $scat   = ""
    $ftype  = ""
    $sourcePath = ""

    foreach ($ln in $pLines) {
        if     ($ln -match '^\| source_id \| `(.+)` \|')     { $sid    = $Matches[1].Trim() }
        elseif ($ln -match '^\| topic \| (.+) \|')            { $topic  = $Matches[1].Trim() }
        elseif ($ln -match '^\| public_policy \| (.+) \|')   { $policy = $Matches[1].Trim() }
        elseif ($ln -match '^\| source_type \| (.+) \|')     { $stype  = $Matches[1].Trim() }
        elseif ($ln -match '^\| source_category \| (.+) \|') { $scat   = $Matches[1].Trim() }
        elseif ($ln -match '^\| file_type \| (.+) \|')       { $ftype  = $Matches[1].Trim() }
        elseif ($ln -match '^\| source_path \| `(.+)` \|')    { $sourcePath = $Matches[1].Trim() }
    }

    # 소스 본문 추출
    $beginMark = "<!-- BEGIN SOURCE -->"
    $endMark   = "<!-- END SOURCE -->"
    $bIdx = $fullText.IndexOf($beginMark)
    $eIdx = $fullText.IndexOf($endMark)
    $body = if ($bIdx -ge 0 -and $eIdx -gt $bIdx) {
        $fullText.Substring($bIdx + $beginMark.Length, $eIdx - $bIdx - $beginMark.Length).Trim()
    } else { "" }

    Write-Host ""
    Write-Host ("  [{0}] {1}" -f $sid, $topic) -ForegroundColor Magenta
    $pktIdx++
    Set-LLJobItem -Done ($pktIdx - 1) -Total $pktTotal -Item $topic -Detail "분석 준비" -SubDone 0 -SubTotal 3

    # ── 4-2. 안전 필터 ──────────────────────────────────────
    $packetMeta = [pscustomobject]@{
        public_policy = $policy
        source_type = $stype
        source_category = $scat
        file_type = $ftype
    }
    if (-not (Test-LLMProcessableSource $packetMeta)) {
        Write-Host "    [SKIP] LLM 처리 금지 — personal_note 텍스트만 허용" -ForegroundColor DarkGray
        $skipCount++
        $reportRows.Add(("| ``{0}`` | {1} | SKIP (policy/category/type gate) | - | - |" -f $sid, $topic))
        continue
    }
    if ($body -eq "") {
        Write-Host "    [SKIP] 소스 본문 파싱 실패 — BEGIN/END SOURCE 마커 없음" -ForegroundColor Red
        $errCount++
        $reportRows.Add(("| ``{0}`` | {1} | ERROR: 본문 파싱 실패 | - | - |" -f $sid, $topic))
        continue
    }

    # 늦게 처리한 personal note도 실행일이 아닌 원본 작성일로 묶는다.
    $noteDate = $TodayStr
    if ($sourcePath -match '(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)') {
        $noteDate = $Matches[1]
    } elseif ($body -match '(?m)^\s*(?:-\s*)?date:\s*(\d{4}-\d{2}-\d{2})\s*$') {
        $noteDate = $Matches[1]
    }

    $chunkPolicy = Get-LLProcessingPolicy -SourceType $stype -SourceCategory $scat -FileType $ftype -ManualChunkChars $MaxCharsPerChunk
    $ChunkClassify = $chunkPolicy.ChunkChars
    $ChunkExtract  = $chunkPolicy.ChunkChars
    $ChunkWorking  = $chunkPolicy.ChunkChars
    $DirectChars   = $chunkPolicy.MaxDirectChars
    $OverlapChars  = $chunkPolicy.OverlapChars
    Write-Host ("    LLM 입력 정책    ... direct≤{0}자 / chunk {1}자 / overlap {2}자" -f $DirectChars, $ChunkWorking, $OverlapChars) -ForegroundColor DarkGray

    # ── 4-3. 출력 경로 ──────────────────────────────────────
    $classifyPath = Join-Path $PrepDir ("classify_{0}.json" -f $sid)
    $extractPath  = Join-Path $ExtractedDir ("{0}_{1}_extract.md" -f $sid, $topic)
    $workingPath  = Join-Path $WorkingDir ("{0}_{1}.md" -f $noteDate, $topic)
    $processedPkt = Join-Path $ProcessedDir $pkt.Name

    $modeErrors = [System.Collections.Generic.List[string]]::new()

    # ── MODE 1: classify ────────────────────────────────────
    $script:LHStepLabel = "1/3 분류"; Set-LLJobItem -SubDone 0 -Detail $script:LHStepLabel
    if (Test-Path $classifyPath) {
        Write-Host "    MODE 1 classify  ... SKIP (이미 존재)" -ForegroundColor DarkGray
    } else {
        Write-Host ("    MODE 1 classify  ... {0} " -f $ModelClassify) -ForegroundColor White -NoNewline
        try {
            # classify 는 분류 목적 — 앞부분만으로 충분, 안전 길이로 자름
            $classifyBody = if ($body.Length -gt $ChunkClassify) {
                $body.Substring(0, $ChunkClassify) + "`n...(이하 생략)"
            } else { $body }
            $jsonTemplate   = '{"source_type":"","topic":"","language":"","public_policy":"","target_section":"learning|goals|practice|projects","tags":[]}'
            $classifyPrompt = "너는 LearningLog 파이프라인의 소스 분류 워커다.`n" +
                              "아래 노트를 읽고 다음 JSON 형식으로만 출력해라. JSON 외 다른 텍스트는 절대 쓰지 마라.`n" +
                              $jsonTemplate + "`n---`n" + $classifyBody
            $classifyResult = Invoke-OllamaGenerate -Model $ModelClassify -Prompt $classifyPrompt -NumPredict 200 -CtxSize $NumCtx
            [System.IO.File]::WriteAllText($classifyPath, $classifyResult, [System.Text.Encoding]::UTF8)
            Write-Host "OK" -ForegroundColor Green
        } catch {
            Write-Host "FAIL" -ForegroundColor Red
            Write-Host ("    [ERROR] classify: {0}" -f $_.Exception.Message) -ForegroundColor Red
            $modeErrors.Add("MODE1: " + $_.Exception.Message)
        }
    }

    # ── MODE 2: extract ─────────────────────────────────────
    $script:LHStepLabel = "2/3 개념 추출"; Set-LLJobItem -SubDone 1 -Detail $script:LHStepLabel
    if (Test-Path $extractPath) {
        Write-Host "    MODE 2 extract   ... SKIP (이미 존재)" -ForegroundColor DarkGray
    } else {
        Write-Host ("    MODE 2 extract   ... {0} " -f $ModelExtract) -ForegroundColor White -NoNewline
        try {
            $extractInstruction = "너는 LearningLog 파이프라인의 사실 추출 워커다.`n" +
                                  "아래 학습 노트에서 핵심 사실만 추출해라. 개인 해석은 포함하지 마라. 한국어로 작성해라.`n" +
                                  "출력 형식:`n# Extracted Summary`n## 핵심 개념`n## 명령어 / 코드`n## 기억할 사실"
            $extractResult = Invoke-OllamaChunked -Model $ModelExtract -Instruction $extractInstruction -Body $body -MaxChars $ChunkExtract -DirectChars $DirectChars -OverlapChars $OverlapChars

            $extractFM = "---`nsource_id: $sid`nextract_date: $TodayStr`nmodel: $ModelExtract`nmode: extract`n---`n`n"
            [System.IO.File]::WriteAllText($extractPath, ($extractFM + $extractResult), [System.Text.Encoding]::UTF8)

            $null = Update-RegistryStatus -Sid $sid -NewStatus "extracted"
            Write-Host "OK" -ForegroundColor Green
            Write-Host "    registry         ... registered → extracted" -ForegroundColor DarkGray
        } catch {
            Write-Host "FAIL" -ForegroundColor Red
            Write-Host ("    [ERROR] extract: {0}" -f $_.Exception.Message) -ForegroundColor Red
            $modeErrors.Add("MODE2: " + $_.Exception.Message)
        }
    }

    # ── MODE 3: working_note ────────────────────────────────
    $script:LHStepLabel = "3/3 워킹노트 작성"; Set-LLJobItem -SubDone 2 -Detail $script:LHStepLabel
    if (Test-Path $workingPath) {
        Write-Host "    MODE 3 working   ... SKIP (이미 존재)" -ForegroundColor DarkGray
    } else {
        Write-Host ("    MODE 3 working   ... {0} " -f $ModelWorking) -ForegroundColor White -NoNewline
        try {
            $workingInstruction = "너는 LearningLog 파이프라인의 워킹 노트 생성 워커다.`n" +
                                  "아래 학습 노트를 바탕으로 한국어 워킹 노트를 작성해라.`n" +
                                  "초보자 시점, 학습자의 혼란을 중심으로 써라.`n" +
                                  "포함 항목: 무엇이 헷갈렸나 / 정리된 이해 / 실습 예시 / 초보자 키워드(의미+검색어) / 내 프로젝트 연결 / 다음 복습 주제"
            $workingResult = Invoke-OllamaChunked -Model $ModelWorking -Instruction $workingInstruction -Body $body -MaxChars $ChunkWorking -DirectChars $DirectChars -OverlapChars $OverlapChars

            $workingFM = "---`nsource_id: $sid`nnote_date: $noteDate`nmodel: $ModelWorking`nmode: working_note`n---`n`n"
            [System.IO.File]::WriteAllText($workingPath, ($workingFM + $workingResult), [System.Text.Encoding]::UTF8)

            $null = Update-RegistryStatus -Sid $sid -NewStatus "working"
            Write-Host "OK" -ForegroundColor Green
            Write-Host "    registry         ... extracted → working" -ForegroundColor DarkGray
        } catch {
            Write-Host "FAIL" -ForegroundColor Red
            Write-Host ("    [ERROR] working_note: {0}" -f $_.Exception.Message) -ForegroundColor Red
            $modeErrors.Add("MODE3: " + $_.Exception.Message)
        }
    }

    if ($IncludeDraft) {
        # ── MODE 4: blog_draft ──────────────────────────────
        # 기본 파이프라인에서는 실행하지 않는다. 필요할 때만 -IncludeDraft로 사용.
        # internal-only 제외, partial-public / public 만
        if ($policy -in @("public", "partial-public")) {

        # classify 결과에서 section 파싱 (없으면 learning 기본값)
        $section = "learning"
        if (Test-Path $classifyPath) {
            try {
                $cJson = [System.IO.File]::ReadAllText($classifyPath, [System.Text.Encoding]::UTF8)
                # JSON에서 target_section 값 추출
                if ($cJson -match '"target_section"\s*:\s*"([^"]+)"') {
                    $section = $Matches[1]
                }
            } catch {}
        }
        # section 검증 — 정해진 4개만 허용
        $validSections = @("learning", "goals", "practice", "projects")
        if ($validSections -notcontains $section) { $section = "learning" }

        $draftDir  = Join-Path $Root ("04_blog_drafts\" + $section)
        $draftPath = Join-Path $draftDir ("${topic}.md")

        if (Test-Path $draftPath) {
            Write-Host "    MODE 4 draft     ... SKIP (이미 존재)" -ForegroundColor DarkGray
        } else {
            if (-not (Test-Path $draftDir)) {
                New-Item -ItemType Directory -Path $draftDir -Force | Out-Null
            }
            Write-Host ("    MODE 4 draft     ... {0} " -f $ModelWorking) -ForegroundColor White -NoNewline
            try {
                # 입력: 방금 만든 워킹 노트 (원본 소스 아님)
                $wContent = [System.IO.File]::ReadAllText($workingPath, [System.Text.Encoding]::UTF8)

                $fence = '```'
                $draftInstruction = "너는 LearningLog 파이프라인의 Hugo 블로그 초안 생성 워커다.`n" +
                    "아래 워킹 노트를 바탕으로 Hugo 블로그 초안을 한국어로 작성해라.`n`n" +
                    "규칙:`n" +
                    "- 강의 원문 복사 금지 — 내 학습 경험과 해석 위주로 작성`n" +
                    "- draft: true 로 작성 (발행은 인간이 결정)`n" +
                    "- source_id, note_date, model, mode 는 front matter 나 본문에 절대 쓰지 말 것`n" +
                    "- front matter 는 글 맨 위에 한 번만. 본문 중간에 --- 구분선이나 메타데이터를 다시 넣지 말 것`n" +
                    "- 최상위 ## 제목은 '개념명' 또는 '총평' 만. 같은 ## 제목을 두 번 쓰지 말 것`n" +
                    "- 개념이 여러 개면 '## 1. 개념명', '## 2. 개념명' 처럼 번호를 붙여 개념마다 별도 ## 블록으로 나눈다`n" +
                    "- 각 개념 ## 블록 안에는 아래 다섯 ### 소제목을 순서대로 넣는다 (이 다섯 ### 은 개념마다 반복해도 된다):`n" +
                    "  ### 왜 이걸 보게 됐나`n  ### 내가 헷갈린 지점`n  ### 시도한 코드 / 예시`n  ### 결과와 해석`n  ### 정리된 이해`n" +
                    "- 글의 맨 마지막에는 반드시 '## 총평' 을 넣고 그 안에 다음 세 ### 를 둔다:`n" +
                    "  ### 오늘 전체에서 배운 것`n  ### 다음에 조심할 것`n  ### 다음 복습 주제`n" +
                    "- '## 목차' 는 직접 쓰지 말 것 (목차는 자동 생성된다)`n" +
                    "- 코드 블록은 반드시 펜스를 열고 닫는다. 출력/결과 주석은 실제 값으로 채운다. 빈 '# 출력:' 금지`n" +
                    "- '왜 썼나 / 배운 것 / 헷갈린 것' 처럼 슬래시로 합친 제목을 만들지 말 것`n`n" +
                    "출력 형식 (front matter 로 시작):`n" +
                    "---`ntitle: `"제목`"`ndate: $noteDate`ndraft: true`n" +
                    "categories: [`"`"]`ntags: []`ndescription: `"설명`"`n---`n`n" +
                    "## 1. 첫 번째 개념명`n### 왜 이걸 보게 됐나`n...`n### 내가 헷갈린 지점`n...`n" +
                    "### 시도한 코드 / 예시`n...`n### 결과와 해석`n...`n### 정리된 이해`n...`n`n" +
                    "## 2. 두 번째 개념명`n(같은 ### 다섯 블록 반복)`n`n" +
                    "## 총평`n### 오늘 전체에서 배운 것`n...`n### 다음에 조심할 것`n...`n### 다음 복습 주제`n..."

                $draftResult = Invoke-OllamaChunked -Model $ModelWorking -Instruction $draftInstruction -Body $wContent -MaxChars $ChunkWorking -DirectChars $DirectChars -OverlapChars $OverlapChars
                $draftResult = Remove-ExtraHugoFrontMatter -Text $draftResult
                $draftResult = ConvertTo-LLOutlineArticleStructure -Content $draftResult
                [System.IO.File]::WriteAllText($draftPath, $draftResult, [System.Text.Encoding]::UTF8)

                $draftIssues = @(Get-LLDraftQualityIssues -Content $draftResult)
                if ($draftIssues.Count -gt 0) {
                    $null = Update-RegistryStatus -Sid $sid -NewStatus "needs_review"
                    Write-Host ("WARN ({0})" -f ($draftIssues -join ", ")) -ForegroundColor Yellow
                    Write-Host ("    draft 저장       ... 04_blog_drafts\{0}\{1}.md" -f $section, $topic) -ForegroundColor DarkGray
                    Write-Host "    registry         ... working → needs_review" -ForegroundColor Yellow
                } else {
                    $null = Update-RegistryStatus -Sid $sid -NewStatus "drafted"
                    Write-Host "OK" -ForegroundColor Green
                    Write-Host ("    draft 저장       ... 04_blog_drafts\{0}\{1}.md" -f $section, $topic) -ForegroundColor DarkGray
                    Write-Host "    registry         ... working → drafted" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "FAIL" -ForegroundColor Red
                Write-Host ("    [ERROR] blog_draft: {0}" -f $_.Exception.Message) -ForegroundColor Red
                $modeErrors.Add("MODE4: " + $_.Exception.Message)
            }
        }
        } else {
            Write-Host "    MODE 4 draft     ... SKIP (internal-only — 발행 불가)" -ForegroundColor DarkGray
        }
    }

    # ── 패킷 이동 (오류 없을 때만) ──────────────────────────
    if ($modeErrors.Count -eq 0) {
        try {
            Move-Item $pkt.FullName $processedPkt -Force -ErrorAction Stop
            Write-Host "    패킷             ... → processed/" -ForegroundColor DarkGray
        } catch {
            Write-Host ("    [WARN] 패킷 이동 실패: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
        $doneCount++
        $reportRows.Add(("| ``{0}`` | {1} | OK | ``{2}`` | ``{3}`` |" -f $sid, $topic,
            (Split-Path $extractPath -Leaf), (Split-Path $workingPath -Leaf)))
    } else {
        $errMsg = $modeErrors -join " / "
        $errCount++
        $reportRows.Add(("| ``{0}`` | {1} | ERROR: {2} | - | - |" -f $sid, $topic, $errMsg))
    }
}

Set-LLJobItem -Done $pktTotal -Total $pktTotal -Item "" -Detail "워킹노트 변환 완료" -SubDone 0 -SubTotal 0

# ─────────────────────────────────────────────────────────
# 5. 실행 리포트 생성
# ─────────────────────────────────────────────────────────
$r = [System.Collections.Generic.List[string]]::new()
$r.Add("# LearningLog Extract Report")
$r.Add("")
$r.Add("> 실행 시각: $RunTime")
$r.Add("")
$r.Add("---")
$r.Add("")
$r.Add("## 결과 요약")
$r.Add("")
$r.Add("| 항목 | 수 |")
$r.Add("|------|----|")
$r.Add("| 처리 완료 | $doneCount |")
$r.Add("| skip | $skipCount |")
$r.Add("| 오류 | $errCount |")
$r.Add("")
$r.Add("---")
$r.Add("")
$r.Add("## 처리 상세")
$r.Add("")
$r.Add("| source_id | topic | 결과 | extract 파일 | working_note 파일 |")
$r.Add("|-----------|-------|------|-------------|-----------------|")
$r.AddRange([string[]]$reportRows)
$r.Add("")
$r.Add("---")
$r.Add("")
$r.Add("## 생성된 파일 위치")
$r.Add("")
$r.Add("| 단계 | 경로 |")
$r.Add("|------|------|")
$r.Add("| 분류 JSON | ``09_reports\llm_prep\classify_*.json`` |")
$r.Add("| 사실 추출 | ``02_extracted\concept_extracts\`` |")
$r.Add("| 워킹 노트 | ``03_working_notes\daily_logs\`` |")
$r.Add("| 처리 완료 패킷 | ``09_reports\llm_prep\processed\`` |")
$r.Add("")
$r.Add("---")
$r.Add("")
$r.Add("## 다음 단계 (인간 검토 필요)")
$r.Add("")
$r.Add("1. ``03_working_notes\daily_logs\`` 파일 내용 검토")
$r.Add("2. 블로그 초안(draft) 생성 여부 결정 — 별도 단계, 인간 검토 후")
$r.Add("3. ``run_learninglog_queue.ps1`` 실행으로 최신 큐 상태 확인")
$r.Add("")
$r.Add("> 자동 생성 리포트. blog-source 미접촉. 04_blog_drafts 미생성.")
$r.Add("> source_registry.csv 변경: 처리된 소스 status 갱신.")

$reportContent = $r -join "`n"
$reportPath = Join-Path $ReportsDir "extract_report_$TimeStamp.md"
[System.IO.File]::WriteAllText($reportPath, $reportContent, [System.Text.Encoding]::UTF8)

# ─────────────────────────────────────────────────────────
# 6. 최종 요약
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  결과 요약" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host ("  처리 완료: {0,3}" -f $doneCount) -ForegroundColor Green
Write-Host ("  skip:     {0,3}" -f $skipCount)  -ForegroundColor DarkGray
if ($errCount -gt 0) {
    Write-Host ("  오류:     {0,3}" -f $errCount) -ForegroundColor Red
} else {
    Write-Host ("  오류:     {0,3}" -f $errCount) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host ("  리포트: {0}" -f $reportPath) -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
