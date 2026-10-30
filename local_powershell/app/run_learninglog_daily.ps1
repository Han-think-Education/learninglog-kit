#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Daily Log — 하루 일과를 카테고리별 '포인트'로 정리하는 텍스트 브이로그 양식 채우기.

.DESCRIPTION
    - 카테고리(요소)를 골라서, 자유 메모를 로컬 기록 양식에 보관한다.
    - LM Studio가 이미 켜져 있으면 한 번의 짧은 보조 정리만 요청한다.
    - LM Studio가 없거나 응답에 실패하면 기다리지 않고 원문 보관 양식으로 저장한다.
    - 03_working_notes\personal_daily_logs\YYYY-MM-DD-daily.md 로 저장 (발행/업로드 없음 — 순수 정리).

.PARAMETER Date     날짜 (기본 오늘, yyyy-MM-dd)
.PARAMETER NoOpen   저장 후 자동 열기 안 함
.PARAMETER LMStudioBase  LM Studio OpenAI 호환 서버 주소
.PARAMETER LMStudioModel 사용할 모델 ID. 현재 로드되지 않았으면 원문만 저장
.PARAMETER NoLLM       보조 정리를 끄고 원문만 저장
#>
param(
    [string]$Date = (Get-Date).ToString("yyyy-MM-dd"),
    [switch]$NoOpen,
    [string]$LMStudioBase = "http://127.0.0.1:1234",
    [string]$LMStudioModel = "local-model",
    [switch]$NoLLM
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

# ── 카테고리(요소) 정의 ──
$CATS = @(
    @{ emoji = "📚"; name = "학습" },
    @{ emoji = "💻"; name = "개발" },
    @{ emoji = "🍳"; name = "요리" },
    @{ emoji = "🏃"; name = "운동" },
    @{ emoji = "📖"; name = "독서" },
    @{ emoji = "🎵"; name = "음악" },
    @{ emoji = "🎮"; name = "게임" },
    @{ emoji = "🌿"; name = "일상" },
    @{ emoji = "💡"; name = "생각" }
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  데일리 로그 ($Date)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ── 카테고리 선택 ──
Write-Host ""
Write-Host "  오늘 기록할 요소를 고르세요 (쉼표로 여러 개, 예: 1,3,8)" -ForegroundColor Yellow
for ($i = 0; $i -lt $CATS.Count; $i++) {
    Write-Host ("    [{0}] {1} {2}" -f ($i + 1), $CATS[$i].emoji, $CATS[$i].name)
}
$sel = (Read-Host "  번호").Trim()
if ($sel -eq "") { Write-Host "  취소됨." -ForegroundColor DarkGray; exit 0 }
$picked = @($sel -split "," | ForEach-Object { [int]$_.Trim() - 1 } | Where-Object { $_ -ge 0 -and $_ -lt $CATS.Count } | ForEach-Object { $CATS[$_] })
if ($picked.Count -eq 0) { Write-Host "  선택 없음." -ForegroundColor Yellow; exit 0 }

# ── 자유 메모 입력 (여러 줄, 빈 줄로 종료) ──
Write-Host ""
Write-Host "  오늘 있었던 일을 자유롭게 적으세요. (여러 줄 가능, 빈 줄 입력하면 끝 / 그냥 엔터=수동작성)" -ForegroundColor Yellow
$memoLines = [System.Collections.Generic.List[string]]::new()
while ($true) {
    $line = Read-Host "  >"
    if ($line -eq "") { break }
    $memoLines.Add($line)
}
$memo = ($memoLines -join "`n").Trim()

# ── LM Studio 보조 정리 ──
$lmOk = $false
$activeModel = ""
if (-not $NoLLM -and $memo -ne "") {
    try {
        $lmModels = Invoke-RestMethod "$($LMStudioBase.TrimEnd('/'))/v1/models" -TimeoutSec 2 -ErrorAction Stop
        $loadedIds = @($lmModels.data | Where-Object { $_.id -notmatch 'embed' } | Select-Object -ExpandProperty id)
        if ($loadedIds -contains $LMStudioModel) { $activeModel = $LMStudioModel }
        $lmOk = -not [string]::IsNullOrWhiteSpace($activeModel)
    } catch { $lmOk = $false }
    if (-not $lmOk) { Write-Host "  (지정 LM 모델 미로드/서버 없음 → 원문 보관 양식으로 생성)" -ForegroundColor DarkGray }
}

function Invoke-LMStudioAssist {
    param([string]$Prompt)
    $body = [ordered]@{
        model = $activeModel
        messages = @([ordered]@{ role = "user"; content = $Prompt })
        stream = $false
        temperature = 0.25
        max_tokens = 420
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6 -Compress))
    try {
        $resp = Invoke-RestMethod -Uri "$($LMStudioBase.TrimEnd('/'))/v1/chat/completions" -Method Post `
            -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 45 -ErrorAction Stop
        $text = [string]$resp.choices[0].message.content
        if ([string]::IsNullOrWhiteSpace($text)) { return "" }
        return $text.Trim()
    } catch {
        Write-Host "  (보조 정리 응답 없음 → 원문만 저장)" -ForegroundColor DarkGray
        return ""
    }
}

# ── 본문 조립 ──
$sb = [System.Collections.Generic.List[string]]::new()
$tagList = ($picked | ForEach-Object { '"' + $_.name + '"' }) -join ", "
$sb.Add("---")
$sb.Add('title: "' + $Date + ' 데일리 로그"')
$sb.Add("date: $Date")
$sb.Add('categories: ["daily"]')
$sb.Add("tags: [$tagList]")
$sb.Add("---")
$sb.Add("")
$sb.Add("## 오늘의 포인트")
$sb.Add("")
foreach ($c in $picked) { $sb.Add(("- {0} {1}: " -f $c.emoji, $c.name)) }
$sb.Add("")
$sb.Add("## 원문 메모")
$sb.Add("")
if ($memo) { $memo -split "`r?`n" | ForEach-Object { $sb.Add($_); $sb.Add("") } }
else { $sb.Add("(직접 채울 메모가 없습니다.)"); $sb.Add("") }

$assist = ""
if ($lmOk) {
    $categoryNames = ($picked | ForEach-Object { $_.name }) -join ", "
    $assistPrompt = @"
다음은 사용자가 직접 적은 하루 메모다. 보조 편집자처럼 정리하라.
선택 요소: $categoryNames
규칙:
- 메모에 있는 사실·감정·표현만 사용하고 새 경험을 만들지 마라.
- 선택 요소별로 짧은 bullet을 1~2개씩 제안하라.
- 마지막 줄은 반드시 '한 줄 회고: '로 시작하는 한 문장으로 끝내라.
- 조언, 과장, 칭찬, 서론은 쓰지 마라.

메모:
---
$memo
"@
    $assist = Invoke-LMStudioAssist $assistPrompt
}

$retro = ""
if ($assist) {
    $retroMatch = [regex]::Match($assist, '(?im)^\s*한 줄 회고\s*[:：]\s*(.+?)\s*$')
    if ($retroMatch.Success) {
        $retro = $retroMatch.Groups[1].Value.Trim()
        $assist = [regex]::Replace($assist, '(?im)^\s*한 줄 회고\s*[:：].*\r?\n?', '').Trim()
    }
}
if ($assist) {
    $sb.Add("## 보조 정리")
    $sb.Add("")
    $assist -split "`r?`n" | ForEach-Object { $sb.Add($_); $sb.Add("") }
}
$sb.Add("## 한 줄 회고")
$sb.Add("")
$sb.Add($retro)
$sb.Add("")

# ── 저장 ──
$outDir = Get-LLPath "03_working_notes\personal_daily_logs"   # 학습 미리보기/발행과 분리 (데일리는 별개 기능)
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outPath = Join-Path $outDir "$Date-daily.md"
$content = ($sb -join "`n")
[System.IO.File]::WriteAllText($outPath, $content, [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host ("  저장: 03_working_notes\personal_daily_logs\{0}-daily.md (블로그 발행용 아님)" -f $Date) -ForegroundColor Green
Write-Host ("  카테고리: {0}" -f (($picked | ForEach-Object { $_.emoji + $_.name }) -join " ")) -ForegroundColor DarkGray
Write-Host ("  보조 정리: {0}" -f $(if ($assist) { "LM Studio 사용" } else { "미사용(원문 보관)" })) -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan
if (-not $NoOpen) { Start-Process $outPath }
exit 0
