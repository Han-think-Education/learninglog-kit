#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog 런처 — 파이프라인 메뉴 (LM Studio 전용)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"
Import-Module (Join-Path $PSScriptRoot "..\app\core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$Root         = Get-LLRoot
$RegistryPath = Get-LLRegistryPath
$PrepDir      = Get-LLPath "09_reports\llm_prep"
$LMStudioBase = "http://127.0.0.1:1234"
$LMStudioModel = "local-model"

# ─────────────────────────────────────────────────────────
# 헬퍼
# ─────────────────────────────────────────────────────────
function Test-LMStudioRunning {
    try {
        $null = Invoke-RestMethod -Uri "$LMStudioBase/v1/models" -Method Get -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-PipelineStatus {
    $s = @{ total = 0; pending = 0; immediate = 0; drafted = 0; published = 0; internal = 0; prep = 0 }
    if (Test-Path $RegistryPath) {
        $null = Ensure-LLRegistrySchema
        $rows = Get-LLRegistryRows
        $s.total     = $rows.Count
        $s.pending   = @($rows | Where-Object { $_.status -in @("registered","new") }).Count
        $s.immediate = @($rows | Where-Object { $_.status -in @("registered","new") -and (Test-LLMProcessableSource $_) }).Count
        $s.drafted   = @($rows | Where-Object { $_.status -eq "drafted" }).Count
        $s.published = @($rows | Where-Object { $_.status -eq "published" }).Count
        $s.internal  = @($rows | Where-Object { $_.public_policy -eq "internal-only" }).Count
    }
    if (Test-Path $PrepDir) {
        $s.prep = @(Get-ChildItem $PrepDir -Filter "PREP_*.md" -File).Count
    }
    return $s
}

function Show-Menu {
    $s   = Get-PipelineStatus
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $lmOn      = Test-LMStudioRunning
    $lmLabel   = if ($lmOn) { "ON  (127.0.0.1:1234)" } else { "OFF" }
    $lmColor   = if ($lmOn) { "Green" } else { "Red" }
    $prepColor = if ($s.prep -gt 0) { "Yellow" } else { "DarkGray" }

    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |       LearningLog Launcher               |" -ForegroundColor Cyan
    Write-Host ("  |       {0}               |" -f $now) -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  |  전체:{0,3} 대기:{1,3} 즉시:{2,3} 초안:{3,3}    |" -f `
        $s.total, $s.pending, $s.immediate, $s.drafted) -ForegroundColor White
    Write-Host ("  |  발행:{0,3} internal-only:{1,3}                 |" -f `
        $s.published, $s.internal) -ForegroundColor DarkGray
    Write-Host ("  |  PREP 패킷 대기: {0,2} 개                    |" -f $s.prep) -ForegroundColor $prepColor
    Write-Host -NoNewline "  |  LM Studio: " -ForegroundColor White
    Write-Host -NoNewline $lmLabel -ForegroundColor $lmColor
    $pad = 29 - $lmLabel.Length
    Write-Host (" " * $pad + "|") -ForegroundColor White
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [1]  LearningLog    학습 기록/발행      |" -ForegroundColor Yellow
    Write-Host "  |  [2]  Projects       프로젝트 시리즈     |" -ForegroundColor Green
    Write-Host "  |  [3]  Daily          별도 회고 기록      |" -ForegroundColor Cyan
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [Q]  종료                               |" -ForegroundColor DarkGray
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  키를 누르세요 >" -ForegroundColor White -NoNewline
}

function Show-LearningLogMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |       LearningLog                        |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [1]  자동 생성+미리보기  발행 전 확인    |" -ForegroundColor Cyan
    Write-Host "  |  [2]  단계별 처리    등록/준비/LLM 노트   |" -ForegroundColor Magenta
    Write-Host "  |  [3]  블로그/발행    수리→승인→발행      |" -ForegroundColor Yellow
    Write-Host "  |  [4]  점검/관리      현황/리뷰/정리/내림  |" -ForegroundColor Green
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [Q]  뒤로                               |" -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  키를 누르세요 >" -ForegroundColor White -NoNewline
}

function Show-ProcessMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |       Step Processing                    |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [1]  새 파일 등록      inbox → registry |" -ForegroundColor Green
    Write-Host "  |  [2]  LLM 준비 패킷     registry → PREP  |" -ForegroundColor Yellow
    Write-Host "  |  [3]  LLM 학습노트      PREP → working   |" -ForegroundColor Magenta
    Write-Host "  |  [7]  자동 생성+미리보기  1→2→3→초안     |" -ForegroundColor Cyan
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [Q]  뒤로                               |" -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  키를 누르세요 >" -ForegroundColor White -NoNewline
}

function Show-BlogMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |       Blog / Publish                     |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [1]  자동 생성+미리보기  draft→preview  |" -ForegroundColor Cyan
    Write-Host "  |  [2]  미리보기 열기       통과/패치/차단 |" -ForegroundColor Yellow
    Write-Host "  |  [3]  자동 패치           QA reason fix  |" -ForegroundColor Magenta
    Write-Host "  |  [4]  승인본 이동         draft → ready  |" -ForegroundColor Yellow
    Write-Host "  |  [5]  발행하기            ready → blog   |" -ForegroundColor Green
    Write-Host "  |  [6]  패치 백업 복구      patch backup   |" -ForegroundColor DarkYellow
    Write-Host "  |  [7]  과거 초안 패치      backlog patch  |" -ForegroundColor DarkGray
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [Q]  뒤로                               |" -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  키를 누르세요 >" -ForegroundColor White -NoNewline
}

function Show-DailyMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |       Daily / Personal Log              |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [1]  로컬 데일리 로그   발행하지 않음    |" -ForegroundColor Cyan
    Write-Host "  |  [2]  개인 기록 글       사진/음악 블로그 |" -ForegroundColor Cyan
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [Q]  뒤로                               |" -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  키를 누르세요 >" -ForegroundColor White -NoNewline
}

function Show-ProjectsMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |       Projects / Series                  |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [1]  시리즈 초안 만들기 projects draft  |" -ForegroundColor Yellow
    Write-Host "  |  [2]  초안 등록          drafts→registry |" -ForegroundColor Green
    Write-Host "  |  [3]  미리보기 열기      preview page    |" -ForegroundColor Cyan
    Write-Host "  |  [4]  승인본 이동        draft → ready   |" -ForegroundColor Yellow
    Write-Host "  |  [5]  발행하기           ready → blog    |" -ForegroundColor Green
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [Q]  뒤로                               |" -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  키를 누르세요 >" -ForegroundColor White -NoNewline
}

function Show-ToolsMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |       Check / Maintenance                |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [1]  처리 현황 보기      queue          |" -ForegroundColor Green
    Write-Host "  |  [2]  품질 리뷰 검사      review         |" -ForegroundColor Yellow
    Write-Host "  |  [3]  차단 초안 정리      cleanup        |" -ForegroundColor Yellow
    Write-Host "  |  [4]  라이브 글 내림      unpublish      |" -ForegroundColor Red
    Write-Host "  |  [5]  구조 보정 점검      dry-run        |" -ForegroundColor Yellow
    Write-Host "  |                                          |" -ForegroundColor DarkGray
    Write-Host "  |  [Q]  뒤로                               |" -ForegroundColor DarkGray
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  키를 누르세요 >" -ForegroundColor White -NoNewline
}

function Run-ProcessMenu {
    while ($true) {
        Show-ProcessMenu
        $key = [Console]::ReadKey($true)
        switch ($key.KeyChar.ToString().ToUpper()) {
            "1" { Run-Script "run_learninglog_intake.ps1" }
            "2" { Run-Script "run_learninglog_prep.ps1" }
            "3" { Run-Extract }
            "7" { Run-AllAuto }
            "Q" { return }
        }
    }
}

function Run-LearningLogMenu {
    while ($true) {
        Show-LearningLogMenu
        $key = [Console]::ReadKey($true)
        switch ($key.KeyChar.ToString().ToUpper()) {
            "1" { Run-AllAuto }
            "2" { Run-ProcessMenu }
            "3" { Run-BlogMenu }
            "4" { Run-ToolsMenu }
            "Q" { return }
        }
    }
}

function Run-BlogMenu {
    while ($true) {
        Show-BlogMenu
        $key = [Console]::ReadKey($true)
        switch ($key.KeyChar.ToString().ToUpper()) {
            "1" { Run-AllAuto }
            "2" { Run-Script "run_learninglog_preview.ps1" @("-Section", "learning") }
            "3" { Run-Script "run_learninglog_repair_drafts.ps1" @("-Section", "learning", "-Mode", "auto") }
            "4" { Run-Script "run_learninglog_approve.ps1" @("-Section", "learning") }
            "5" { Run-Script "run_learninglog_publish.ps1" @("-Section", "learning") }
            "6" { Run-Script "run_learninglog_repair_drafts.ps1" @("-RestoreLatestBackup") }
            "7" { Run-Script "run_learninglog_repair_drafts.ps1" @("-Section", "learning", "-IncludeBacklog", "-Mode", "auto") }
            "Q" { return }
        }
    }
}

function Run-DailyMenu {
    while ($true) {
        Show-DailyMenu
        $key = [Console]::ReadKey($true)
        switch ($key.KeyChar.ToString().ToUpper()) {
            "1" { Run-Script "run_learninglog_daily.ps1" }
            "2" { Run-Script "run_learninglog_daily_post.ps1" }
            "Q" { return }
        }
    }
}

function Run-ProjectsMenu {
    while ($true) {
        Show-ProjectsMenu
        $key = [Console]::ReadKey($true)
        switch ($key.KeyChar.ToString().ToUpper()) {
            "1" { Run-Script "run_learninglog_project_series.ps1" }
            "2" { Run-Script "run_learninglog_register_drafts.ps1" @("-Section", "projects") }
            "3" { Run-Script "run_learninglog_preview.ps1" @("-Section", "projects") }
            "4" { Run-Script "run_learninglog_approve.ps1" @("-Section", "projects", "-IncludeBacklog") }
            "5" { Run-Script "run_learninglog_publish.ps1" @("-Section", "projects", "-IncludeBacklog") }
            "Q" { return }
        }
    }
}

function Run-ToolsMenu {
    while ($true) {
        Show-ToolsMenu
        $key = [Console]::ReadKey($true)
        switch ($key.KeyChar.ToString().ToUpper()) {
            "1" { Run-Script "run_learninglog_queue.ps1" }
            "2" { Run-Script "run_learninglog_review.ps1" }
            "3" { Run-Script "run_learninglog_cleanup.ps1" }
            "4" { Run-Script "run_learninglog_unpublish.ps1" }
            "5" { Run-Script "run_learninglog_restructure.ps1" }
            "Q" { return }
        }
    }
}

function Run-Script {
    param(
        [string]$ScriptName,
        [string[]]$ScriptArgs = @()
    )
    $path = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path $path)) {
        Write-Host ""
        Write-Host ("  [ERROR] 스크립트 없음: {0}" -f $ScriptName) -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }
    Write-Host ""
    Write-Host ("  >> {0} 실행 중..." -f $ScriptName) -ForegroundColor Cyan
    Write-Host ""
    & pwsh -ExecutionPolicy Bypass -File $path @ScriptArgs
    Write-Host ""
    Write-Host "  완료. 아무 키나 누르면 메뉴로 돌아갑니다..." -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

function Run-Extract {
    # LM Studio 전용 경로.
    if (Test-LMStudioRunning) {
        Run-Script "run_learninglog_extract.ps1" @("-Engine", "lm", "-LMStudioModel", $LMStudioModel)
        return
    }
    Write-Host ""
    Write-Host "  LM Studio(:1234) 서버가 꺼져 있습니다." -ForegroundColor Yellow
    Write-Host ("  LM Studio에서 {0} 모델을 Load/Start 한 뒤 다시 실행하세요." -f $LMStudioModel) -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  아무 키나 누르면 메뉴로 돌아갑니다..." -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

function Run-AllAuto {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "   오늘 새 로그 자동 생성+미리보기" -ForegroundColor Cyan
    Write-Host "   intake -> prep -> extract -> blogdraft -> register -> preview" -ForegroundColor Cyan
    Write-Host "   => 승인/발행은 하지 않습니다. preview 에서 통과/수리/차단을 고르세요." -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan

    # LM Studio 전용. 서버가 꺼져 있으면 중단한다.
    $autoEngineArgs = @("-Engine", "lm", "-LMStudioModel", $LMStudioModel)
    $autoDraftArgs = @("-Engine", "lm", "-LMStudioModel", $LMStudioModel, "-TodayOnly")
    if (-not (Test-LMStudioRunning)) {
        Write-Host ""
        Write-Host "  [중단] LM Studio 서버가 꺼져 있습니다." -ForegroundColor Red
        Write-Host "  LM Studio에서 모델을 Load하고 서버를 Start한 뒤 다시 실행하세요." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  아무 키나 누르면 메뉴로 돌아갑니다..." -ForegroundColor DarkGray
        $null = [Console]::ReadKey($true)
        return
    }

    Write-Host ""
    Write-Host "  새 파일 등록부터 초안 미리보기까지 자동 진행됩니다." -ForegroundColor Yellow
    Write-Host "  05_ready_to_publish, blog-source, git 작업은 건드리지 않습니다." -ForegroundColor Yellow
    Write-Host "  시작할까요? [Y] 시작 / 다른 키 취소" -ForegroundColor White -NoNewline
    $k = [Console]::ReadKey($true)
    if ($k.KeyChar.ToString().ToUpper() -ne "Y") {
        Write-Host ""
        Write-Host "  취소됨." -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return
    }

    $steps = @(
        @{ name = "[1] intake    새 파일 등록";              script = "run_learninglog_intake.ps1" },
        @{ name = "[2] prep      LLM 패킷 조립";            script = "run_learninglog_prep.ps1" },
        @{ name = "[3] extract   LLM 처리 (분류/추출/노트)"; script = "run_learninglog_extract.ps1"; args = $autoEngineArgs },
        @{ name = "[4] blogdraft 오늘 초안/합본 생성";       script = "run_learninglog_blogdraft.ps1"; args = $autoDraftArgs },
        @{ name = "[5] register  초안 레지스트리 등록";      script = "run_learninglog_register_drafts.ps1"; args = @("-Section", "learning") },
        @{ name = "[6] preview   미리보기/통과/수리/차단";   script = "run_learninglog_preview.ps1"; args = @("-Section", "learning") }
    )

    foreach ($step in $steps) {
        Write-Host ""
        Write-Host ("  ── {0} ──" -f $step.name) -ForegroundColor Cyan
        Write-Host ""
        $p = Join-Path $PSScriptRoot $step.script
        $stepArgs = @(); if ($step.ContainsKey('args')) { $stepArgs = $step.args }
        if (Test-Path $p) {
            & pwsh -ExecutionPolicy Bypass -File $p @stepArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Host ""
                Write-Host ("  [중단] {0} 실패 (exit {1})" -f $step.script, $LASTEXITCODE) -ForegroundColor Red
                Write-Host "  위 오류를 먼저 고친 뒤 다시 실행하세요." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  아무 키나 누르면 메뉴로 돌아갑니다..." -ForegroundColor DarkGray
                $null = [Console]::ReadKey($true)
                return
            }
        } else {
            Write-Host ("  [SKIP] 스크립트 없음: {0}" -f $step.script) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "   *** 오늘 처리 완료! ***" -ForegroundColor Green
    Write-Host "   미리보기까지 완료됨. 통과한 글만 승인본으로 이동됩니다." -ForegroundColor Green
    Write-Host "   발행은 Blog / Publish 메뉴의 [5]에서 따로 실행하세요." -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  아무 키나 누르면 메뉴로 돌아갑니다..." -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

# ─────────────────────────────────────────────────────────
# 메뉴 루프
# ─────────────────────────────────────────────────────────
while ($true) {
    Show-Menu
    $key = [Console]::ReadKey($true)
    $ch  = $key.KeyChar.ToString().ToUpper()

    switch ($ch) {
        "1" { Run-LearningLogMenu }
        "2" { Run-ProjectsMenu }
        "3" { Run-DailyMenu }
        # 숨은 호환 단축키: 예전 습관으로 눌러도 동작은 유지
        "7" { Run-AllAuto }
        "B" { Run-BlogMenu }
        "P" { Run-ProjectsMenu }
        "T" { Run-ToolsMenu }
        "D" { Run-DailyMenu }
        "Q" {
            Write-Host ""
            Write-Host "  종료합니다." -ForegroundColor DarkGray
            Write-Host ""
            exit 0
        }
    }
}
