#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Cleanup — 차단된(검수 미통과) 초안을 .trash 로 이동 (복구 가능)

.DESCRIPTION
    하는 것:
      - 04_blog_drafts\ 및 05_ready_to_publish\ 초안 스캔 → Get-LLDraftBadges 로 canApprove 판정
      - 차단된(canApprove=false) 초안만 목록화 + QA 사유 배지 표시
      - 선택한 초안을 .trash\<timestamp>\<원래 폴더>\<section>\ 로 이동 (하드 삭제 아님)
      - 09_reports\cleanup_log.csv 에 이동 기록

    하지 않는 것:
      - 발행본/원본 노트 삭제 없음
      - 영구 삭제 없음 (.trash 로 이동만 — 복구 가능)

.PARAMETER All
    차단된 모든 초안을 한번에 이동
.PARAMETER DryRun
    이동하지 않고 차단 목록만 표시
#>

param(
    [switch]$All,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$RunDT     = Get-Date
$RunTime   = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$Stamp     = $RunDT.ToString("yyyyMMdd_HHmmss")
$null      = Ensure-LLRegistrySchema
$DraftRoots = [ordered]@{
    "04_blog_drafts"      = Get-LLPath "04_blog_drafts"
    "05_ready_to_publish" = Get-LLPath "05_ready_to_publish"
}
$TrashRoot  = Get-LLPath ".trash\$Stamp"
$LogPath   = Get-LLPath "09_reports\cleanup_log.csv"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Cleanup (차단 초안 정리)" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# registry topic/sid 인덱스 (approve 와 동일 패턴)
$rows = @(Get-LLRegistryRows)
$publishedNames = Get-LLPublishedNames
$rowByTopic = @{}
$rowBySid = @{}
foreach ($r in $rows) {
    $t = Get-LLProp $r "topic";     if ($t) { $rowByTopic[$t] = $r }
    $s = Get-LLProp $r "source_id"; if ($s) { $rowBySid[$s] = $r }
}

function Get-CleanupRelativePath {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $rootName = [string]$Draft.PSObject.Properties["CleanupRoot"].Value
    $rootPath = [string]$Draft.PSObject.Properties["CleanupRootPath"].Value
    $rel = $Draft.FullName.Substring($rootPath.Length) -replace '^[\\/]+', ''
    return [pscustomobject]@{
        RootName  = $rootName
        Relative  = ($rel -replace '\\', '/')
    }
}

# ── 차단 초안 수집 ──
$allDrafts = @(
    foreach ($entry in $DraftRoots.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value)) { continue }
        $rootPath = (Resolve-Path -LiteralPath $entry.Value).Path
        foreach ($draft in (Get-ChildItem -LiteralPath $entry.Value -Recurse -Filter "*.md" -File | Sort-Object FullName)) {
            $draft | Add-Member -NotePropertyName CleanupRoot -NotePropertyValue $entry.Key -Force
            $draft | Add-Member -NotePropertyName CleanupRootPath -NotePropertyValue $rootPath -Force
            $draft
        }
    }
)
if ($allDrafts.Count -eq 0) {
    Write-Host "  정리할 초안 폴더가 비어 있습니다." -ForegroundColor Yellow
    exit 0
}

$blockedList = [System.Collections.Generic.List[object]]::new()
foreach ($d in $allDrafts) {
    $c = Read-LLText $d.FullName
    $row = Resolve-LLDraftRow $d $c -RowBySid $rowBySid -RowByTopic $rowByTopic
    # 승인/발행된 글은 차단 대상이 아니다. 04_blog_drafts에 원본 초안이
    # 남아 있어도 이력 보존용 사본이므로 절대 .trash로 이동하지 않는다.
    $rowStatus = (Get-LLProp $row "status").ToLowerInvariant()
    if ($rowStatus -in @("approved", "published") -or
        (Test-LLDraftAlreadyPublished -Draft $d -Row $row -PublishedNames $publishedNames)) { continue }
    $rel = (Get-CleanupRelativePath -Draft $d).Relative
    $section = ($rel -split "/")[0]
    $b = Get-LLDraftBadges -Content $c -Row $row -Section $section
    if (-not $b.canApprove) {
        $why = ($b.badges | Where-Object { $_.cls -ne "ok" } | ForEach-Object { $_.text }) -join ", "
        $blockedList.Add([pscustomobject]@{ File = $d; Why = $why })
    }
}

if ($blockedList.Count -eq 0) {
    Write-Host ""
    Write-Host "  차단된 초안이 없습니다. (모두 승인 가능 상태)" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    exit 0
}

Write-Host ""
Write-Host ("  차단 초안은 다음 위치로 이동됩니다: {0}" -f $TrashRoot) -ForegroundColor DarkGray
Write-Host ("  --- 차단된 초안 {0} 개 ---" -f $blockedList.Count) -ForegroundColor Magenta
for ($i = 0; $i -lt $blockedList.Count; $i++) {
    $pathInfo = Get-CleanupRelativePath -Draft $blockedList[$i].File
    $rel = "$($pathInfo.RootName)/$($pathInfo.Relative)"
    Write-Host ("  [{0,2}] ⛔ {1}" -f ($i + 1), $rel) -ForegroundColor DarkGray
    Write-Host ("       사유: {0}" -f $blockedList[$i].Why) -ForegroundColor DarkGray
}
Write-Host ""

if ($DryRun) {
    Write-Host "  [DryRun] 이동하지 않고 목록만 표시했습니다." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    exit 0
}

# ── 대상 선택 ──
if ($All) {
    $targets = @($blockedList)
} else {
    Write-Host "  [ A] 차단된 전체 이동" -ForegroundColor Yellow
    Write-Host "  [ Q] 취소" -ForegroundColor DarkGray
    Write-Host ""
    $sel = (Read-Host "  이동할 번호 입력 (쉼표로 여러 개, 예: 1,3,5)").Trim().ToUpper()
    if ($sel -eq "Q" -or $sel -eq "") { Write-Host "  취소됨." -ForegroundColor DarkGray; exit 0 }
    if ($sel -eq "A") {
        $targets = @($blockedList)
    } else {
        $indices = $sel -split "," | ForEach-Object { [int]$_.Trim() - 1 }
        $targets = @($indices | ForEach-Object { $blockedList[$_] } | Where-Object { $null -ne $_ })
    }
}

if ($targets.Count -eq 0) {
    Write-Host "  선택된 파일 없음." -ForegroundColor Yellow
    exit 0
}

# ── 이동 처리 ──
$moved = 0
$logEntries = [System.Collections.Generic.List[object]]::new()
Write-Host ""
foreach ($t in $targets) {
    $d = $t.File
    $pathInfo = Get-CleanupRelativePath -Draft $d
    $rel = "$($pathInfo.RootName)/$($pathInfo.Relative)"
    $destPath = Join-Path $TrashRoot ($rel -replace '/', '\')
    $destDir = Split-Path -Parent $destPath
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Move-Item -LiteralPath $d.FullName -Destination $destPath -Force
    Write-Host ("  [이동] {0} -> .trash/{1}/{2}" -f $rel, $Stamp, $rel) -ForegroundColor Yellow
    $logEntries.Add([pscustomobject]@{
        moved_at   = $RunTime
        file_name  = $d.Name
        rel_path   = ($rel -replace '\\','/')
        reason     = $t.Why
        trash_path = $destPath
        moved_by   = $env:USERNAME
    })
    $moved++
}

# ── 로그 기록 (실패해도 이동 결과는 유지) ──
if ($logEntries.Count -gt 0) {
    try {
        $parent = Split-Path -Parent $LogPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $existing = @()
        if (Test-Path -LiteralPath $LogPath) { $existing = @(Import-Csv -LiteralPath $LogPath -Encoding utf8) }
        $all = @($existing) + @($logEntries.ToArray())
        $all | Export-Csv -LiteralPath $LogPath -Encoding utf8 -NoTypeInformation
    } catch {
        Write-Host ("  [경고] 로그 기록 실패(이동은 정상): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  이동 완료: {0} 개 -> .trash\{1}\" -f $moved, $Stamp) -ForegroundColor Green
Write-Host "  복구하려면 .trash 에서 원래 폴더(04_blog_drafts 또는 05_ready_to_publish)로 되돌리세요." -ForegroundColor DarkGray
Write-Host ("  로그: {0}" -f $LogPath) -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan
exit 0
