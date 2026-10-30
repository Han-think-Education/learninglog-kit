#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Preview — 초안 미리보기 대시보드 (로컬 서버 모드: 화면에서 선택 삭제 가능)

.DESCRIPTION
    기본(서버 모드):
      - http://127.0.0.1:8765 로 대시보드 서빙
    - 각 초안에 통과/수리/차단 버튼 제공
      통과: QA 통과 글만 05_ready_to_publish 로 승인 이동
      수리: LLM 수리 스크립트 실행 후 다시 미리보기
      차단: .trash\preview_block_<시각>\ 로 이동(복구 가능)
      - 콘솔에서 Q 입력(또는 창 닫기/Ctrl+C)으로 종료
    -Static:
      - 예전처럼 정적 HTML 만 생성하고 종료 (삭제 버튼 없음)

.PARAMETER NoOpen           브라우저 자동 열기 안 함
.PARAMETER IncludePublished 발행된 글도 PUBLISHED 배지로 포함
.PARAMETER IncludeByproducts 합본 처리 후 생긴 partial-public 부산물 초안도 포함
.PARAMETER IncludeBacklog 과거 날짜의 초안도 포함 (기본값은 오늘 초안만)
.PARAMETER Static           정적 HTML 만 생성 (서버 안 띄움)
.PARAMETER Port             서버 포트 (기본 8765)
.PARAMETER Section          특정 섹션만 표시 (learning/projects/practice/goals)
#>

param(
    [switch]$NoOpen,
    [switch]$IncludePublished,
    [switch]$IncludeByproducts,
    [switch]$IncludeBacklog,
    [switch]$Static,
    [string]$Section = "",
    [int]$Port = 8765
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$CoreModulePath = Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1"
Import-Module $CoreModulePath -Force -DisableNameChecking

function Refresh-CoreModule {
    # 서버를 오래 켜둔 상태에서 모듈을 고쳐도 승인/수리 요청에는 최신 규칙을 사용한다.
    Import-Module $CoreModulePath -Force -DisableNameChecking
}

$RunTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Preview Dashboard" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$null = Ensure-LLRegistrySchema
$DraftsDir = Get-LLPath "04_blog_drafts"
$DraftAssetsRoot = Get-LLPath "04_blog_drafts\_assets"
$OutDir    = Get-LLPath "09_reports\preview"
$markedPath = Get-LLPath "app\core\vendor\marked.min.js"
if (-not (Test-Path -LiteralPath $markedPath)) {
    Write-Host "  [경고] marked.min.js 없음: $markedPath" -ForegroundColor Yellow
}

function New-Dashboard {
    return (New-LLPreviewDashboard -DraftsDir $DraftsDir -OutDir $OutDir -IncludePublished:$IncludePublished -IncludeByproducts:$IncludeByproducts -IncludeBacklog:$IncludeBacklog -Section $Section)
}

$result = New-Dashboard
Write-Host ""
Write-Host ("  초안 {0} 개 미리보기 생성" -f $result.count) -ForegroundColor Green
if (-not $IncludePublished -and $result.excludedPublished -gt 0) {
    Write-Host ("  발행 제외: {0} 개 (-IncludePublished 로 포함 가능)" -f $result.excludedPublished) -ForegroundColor DarkGray
}
if (-not $IncludeByproducts -and $result.excludedByproducts -gt 0) {
    Write-Host ("  부산물 제외: {0} 개 (-IncludeByproducts 로 포함 가능)" -f $result.excludedByproducts) -ForegroundColor DarkGray
}
if (-not $IncludeBacklog -and $result.excludedBacklog -gt 0) {
    Write-Host ("  과거 초안 제외: {0} 개 (-IncludeBacklog 로 포함 가능)" -f $result.excludedBacklog) -ForegroundColor DarkGray
}
$canApprove = @($result.items | Where-Object { $_.canApprove }).Count
Write-Host ("  ✅ 승인 가능 {0} 개  /  ⚠️ 검토 필요 {1} 개" -f $canApprove, ($result.count - $canApprove))

# ── 정적 모드 ──
if ($Static) {
    Write-Host ("  -> {0}" -f $result.html) -ForegroundColor DarkGray
    if ($result.count -gt 0 -and -not $NoOpen) { Start-Process $result.html }
    Write-Host "========================================" -ForegroundColor Cyan
    exit 0
}

# ── 서버 모드 ──
$prefix = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
    Write-Host ("  [ERROR] 포트 {0} 사용 불가 (이미 실행 중?): {1}" -f $Port, $_.Exception.Message) -ForegroundColor Red
    Write-Host "  기존 미리보기 창을 닫거나 -Port 로 다른 포트를 지정하세요." -ForegroundColor Yellow
    exit 1
}

$TrashRoot = Get-LLPath (".trash\preview_del_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$draftsFull = (Resolve-Path -LiteralPath $DraftsDir).Path
$draftAssetsFull = if (Test-Path -LiteralPath $DraftAssetsRoot) { (Resolve-Path -LiteralPath $DraftAssetsRoot).Path } else { "" }

Write-Host ""
Write-Host ("  서버 모드: {0}" -f $prefix) -ForegroundColor Cyan
Write-Host "  화면에서 통과/수리/차단·휴지통을 선택할 수 있습니다." -ForegroundColor Cyan
Write-Host ("  차단 위치: {0}" -f $TrashRoot) -ForegroundColor DarkGray
Write-Host "  종료: 이 창에서 Q 입력 (또는 창 닫기)" -ForegroundColor DarkGray
if (-not $NoOpen) { Start-Process $prefix }

function Send-Text {
    param($Resp, [string]$Text, [string]$CType = "text/plain; charset=utf-8", [int]$Code = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Resp.StatusCode = $Code
    $Resp.ContentType = $CType
    $Resp.ContentLength64 = $bytes.Length
    $Resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $Resp.OutputStream.Close()
}

function Send-DraftAsset {
    param($Resp, [string]$UrlPath)
    if (-not $draftAssetsFull -or -not $UrlPath.StartsWith("/images/")) {
        Send-Text $Resp "not found" -Code 404
        return
    }

    $relative = [Uri]::UnescapeDataString($UrlPath.TrimStart("/")) -replace "/", "\"
    if ($relative -match '(^|\\)\.\.(\\|$)') {
        Send-Text $Resp "invalid asset path" -Code 400
        return
    }
    $candidate = Join-Path $draftAssetsFull $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        Send-Text $Resp "not found" -Code 404
        return
    }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    if (-not $resolved.StartsWith($draftAssetsFull, [StringComparison]::OrdinalIgnoreCase)) {
        Send-Text $Resp "invalid asset path" -Code 400
        return
    }

    $contentTypes = @{
        ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"
        ".gif" = "image/gif"; ".webp" = "image/webp"; ".svg" = "image/svg+xml"
    }
    $ext = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if (-not $contentTypes.ContainsKey($ext)) {
        Send-Text $Resp "unsupported asset type" -Code 415
        return
    }
    $bytes = [IO.File]::ReadAllBytes($resolved)
    $Resp.StatusCode = 200
    $Resp.ContentType = $contentTypes[$ext]
    $Resp.ContentLength64 = $bytes.Length
    $Resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $Resp.OutputStream.Close()
}

# 비동기 수신 + 콘솔 Q 종료 병행
$deleted = 0
while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(200)) {
        if ((-not [Console]::IsInputRedirected) -and [Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar.ToString().ToUpper() -eq "Q") {
                Write-Host ("`n  종료. 이번 세션 삭제 {0}건 -> {1}" -f $deleted, $TrashRoot) -ForegroundColor Green
                $listener.Stop(); exit 0
            }
        }
    }
    $ctx = $task.Result
    $req = $ctx.Request; $resp = $ctx.Response
    $path = $req.Url.AbsolutePath

    try {
        if ($path -in @("/", "/approve", "/block", "/repair", "/edit")) { Refresh-CoreModule }
        if ($path -eq "/") {
            $r = New-Dashboard
            $html = Read-LLText $r.html
            $html = $html.Replace('../../app/core/vendor/marked.min.js', '/vendor/marked.min.js')
            Send-Text $resp $html "text/html; charset=utf-8"
        }
        elseif ($path -eq "/vendor/marked.min.js") {
            Send-Text $resp (Read-LLText $markedPath) "application/javascript; charset=utf-8"
        }
        elseif ($path.StartsWith("/images/")) {
            Send-DraftAsset $resp $path
        }
        elseif ($path -eq "/delete") {
            $rel = $req.QueryString["f"]   # 예: 04_blog_drafts/learning/x.md
            if (-not $rel) { Send-Text $resp "missing f" -Code 400; continue }
            $full = Join-Path (Get-LLRoot) ($rel -replace "/", "\")
            $fullResolved = ""
            if (Test-Path -LiteralPath $full) { $fullResolved = (Resolve-Path -LiteralPath $full).Path }
            # 안전 검증: 04_blog_drafts 안의 .md 만 허용
            if (-not $fullResolved -or -not $fullResolved.StartsWith($draftsFull) -or -not $fullResolved.EndsWith(".md")) {
                Send-Text $resp "invalid path" -Code 400; continue
            }
            $dest = Join-Path $TrashRoot ($rel -replace "/", "\")
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Move-Item -LiteralPath $fullResolved -Destination $dest -Force
            $deleted++
            Write-Host ("  [삭제] {0} -> .trash" -f $rel) -ForegroundColor Yellow
            Send-Text $resp "ok"
        }
        elseif ($path -eq '/edit') {
            if ($req.HttpMethod -ne 'POST') { Send-Text $resp 'method not allowed' -Code 405; continue }
            if ($req.ContentLength64 -gt 1000000) { Send-Text $resp '본문이 너무 큽니다.' -Code 413; continue }
            $reader = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8)
            try { $data=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            $action=Invoke-LLPreviewEditDraft -RelativePath $req.QueryString['f'] -ExpectedHash ([string]$data.hash) -Title ([string]$data.title) -Body ([string]$data.body)
            Send-Text $resp (ConvertTo-Json $action -Depth 5 -Compress) 'application/json; charset=utf-8'
        }
        elseif ($path -eq "/approve") {
            if ($req.HttpMethod -ne "POST") { Send-Text $resp "method not allowed" -Code 405; continue }
            $rel = $req.QueryString["f"]
            if (-not $rel) { Send-Text $resp "missing f" -Code 400; continue }
            $action = Invoke-LLPreviewApproveDraft -RelativePath $rel
            Write-Host ("  [통과] {0} -> {1}" -f $rel, $action.dest) -ForegroundColor Green
            Send-Text $resp (($action | ConvertTo-Json -Compress)) "application/json; charset=utf-8"
        }
        elseif ($path -eq "/block") {
            if ($req.HttpMethod -ne "POST") { Send-Text $resp "method not allowed" -Code 405; continue }
            $rel = $req.QueryString["f"]
            if (-not $rel) { Send-Text $resp "missing f" -Code 400; continue }
            $action = Invoke-LLPreviewBlockDraft -RelativePath $rel
            Write-Host ("  [차단] {0} -> {1}" -f $rel, $action.trash) -ForegroundColor Yellow
            Send-Text $resp (($action | ConvertTo-Json -Compress)) "application/json; charset=utf-8"
        }
        elseif ($path -eq "/repair") {
            if ($req.HttpMethod -ne "POST") { Send-Text $resp "method not allowed" -Code 405; continue }
            $rel = $req.QueryString["f"]
            if (-not $rel) { Send-Text $resp "missing f" -Code 400; continue }
            $mode = "auto"
            $full = Resolve-LLSafeDraftPath -RelativePath $rel
            $draft = Get-Item -LiteralPath $full
            $content = Read-LLText $full
            $row = Resolve-LLDraftRegistryRow -Draft $draft -Content $content
            $draftRel = Get-LLRelativePath $full
            $section = (($draftRel -split "/")[1]).ToLowerInvariant()
            $dailyMergedDates = Get-LLDailyMergedDateKeys
            $isByproduct = Test-LLDraftByproduct -Draft $draft -Row $row -DailyMergedDates $dailyMergedDates
            $eligibility = Get-LLDraftBadges -Content $content -Row $row -ByproductOverride $isByproduct -Section $section
            if (-not $eligibility.canRepair) {
                Send-Text $resp ("자동 패치 차단: " + $eligibility.repairBlockReason) -Code 409
                continue
            }
            $repairScript = Join-Path (Get-LLRoot) "run\run_learninglog_repair_drafts.ps1"
            if (-not (Test-Path -LiteralPath $repairScript)) { Send-Text $resp "repair script not found" -Code 500; continue }
            Write-Host ("  [패치:{0}] {1}" -f $mode, $rel) -ForegroundColor Yellow
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repairScript -DraftPath $full -Mode $mode -Quiet 2>&1
            if ($LASTEXITCODE -ne 0) {
                Send-Text $resp (($out | Out-String).Trim()) -Code 500
                continue
            }
            Send-Text $resp (($out | Out-String).Trim())
        }
        else {
            Send-Text $resp "not found" -Code 404
        }
    } catch {
        try { Send-Text $resp ("error: " + $_.Exception.Message) -Code 500 } catch {}
    }
}
