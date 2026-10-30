#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Approve — 검수 통과한 초안을 05_ready_to_publish 로 승인 이동

.DESCRIPTION
    하는 것:
      - 04_blog_drafts\ 초안 목록 + QA 배지 표시
      - 선택한 초안의 QA/policy 게이트 확인 (Get-LLDraftBadges)
      - 통과(canApprove)한 것만 05_ready_to_publish\{section}\ 로 복사 (원본 보존)
      - registry status -> approved
      - 09_reports\approval_log.csv 기록

    차단:
      - QA REVIEW NEEDED / private / internal-only / needs_review 등은 승인 불가

.PARAMETER All
    승인 가능한 모든 초안을 한번에 승인
.PARAMETER DraftPath
    특정 초안 경로 지정
.PARAMETER IncludeByproducts
    합본 처리 후 생긴 partial-public 부산물 초안도 승인 목록에 포함
.PARAMETER IncludeBacklog
    오늘 날짜가 아닌 과거 초안도 승인 후보에 포함

.PARAMETER Section
    특정 섹션만 승인 후보에 포함. 예: learning, projects
#>

param(
    [switch]$All,
    [string]$DraftPath = "",
    [switch]$IncludePublished,
    [switch]$IncludeByproducts,
    [switch]$IncludeBacklog,
    [string]$Section = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$RunTime   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$TodayStr  = (Get-Date).ToString("yyyy-MM-dd")
$null      = Ensure-LLRegistrySchema
$DraftsDir = Get-LLPath "04_blog_drafts"
$ReadyDir  = Get-LLPath "05_ready_to_publish"
$LogPath   = Get-LLPath "09_reports\approval_log.csv"
$SectionFilter = $Section.Trim().ToLowerInvariant()

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Approve" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# registry topic 인덱스 (slot draft 는 source_id 없음 → 파일명으로 역매칭)
$rows = @(Get-LLRegistryRows)
$publishedNames = Get-LLPublishedNames
$rowByTopic = @{}
$rowBySid = @{}
foreach ($r in $rows) {
    $t = Get-LLProp $r "topic";     if ($t) { $rowByTopic[$t] = $r }
    $s = Get-LLProp $r "source_id"; if ($s) { $rowBySid[$s] = $r }
}

function Resolve-DraftRow {
    param($Draft, $Content)
    $sid = Get-LLDraftSourceId $Content
    if ($sid -and $rowBySid.ContainsKey($sid)) { return $rowBySid[$sid] }
    if ($rowByTopic.ContainsKey($Draft.BaseName)) { return $rowByTopic[$Draft.BaseName] }
    return $null
}

function Test-TodayDraft {
    param($Draft, $Row)

    if ($IncludeBacklog) { return $true }
    if ($Draft.Name -like "$TodayStr*") { return $true }
    if ($Row) {
        $d = Get-LLProp $Row "date_added"
        if ($d -eq $TodayStr) { return $true }
    }
    if ($Draft.LastWriteTime.ToString("yyyy-MM-dd") -eq $TodayStr) { return $true }
    return $false
}

function Get-DraftSection {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $rel = $Draft.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
    $sectionName = ($rel -split "/")[0]
    if (-not $sectionName) { return "learning" }
    return $sectionName.ToLowerInvariant()
}

# ── 대상 수집 ──
if ($DraftPath -ne "") {
    $targets = @(Get-Item -LiteralPath $DraftPath -ErrorAction SilentlyContinue)
    if ($SectionFilter) {
        $targets = @($targets | Where-Object { (Get-DraftSection $_) -eq $SectionFilter })
    }
} else {
    $allDrafts = @(Get-ChildItem -LiteralPath $DraftsDir -Recurse -Filter "*.md" -File | Sort-Object FullName)
    if ($SectionFilter) {
        $allDrafts = @($allDrafts | Where-Object { (Get-DraftSection $_) -eq $SectionFilter })
    }
    if ($allDrafts.Count -eq 0) {
        if ($SectionFilter) {
            Write-Host ("  04_blog_drafts 에 초안이 없습니다. (section={0})" -f $SectionFilter) -ForegroundColor Yellow
        } else {
            Write-Host "  04_blog_drafts 에 초안이 없습니다." -ForegroundColor Yellow
        }
        exit 0
    }
    $excludedByproducts = 0
    $excludedBacklog = 0
    if (-not $IncludeByproducts) {
        $visibleDrafts = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $allDrafts) {
            $c0 = Read-LLText $d.FullName
            $row0 = Resolve-DraftRow $d $c0
            if (Test-LLDraftByproduct -Draft $d -Row $row0) {
                $excludedByproducts++
                continue
            }
            $visibleDrafts.Add($d)
        }
        $allDrafts = @($visibleDrafts)
    }
    if (-not $IncludeBacklog) {
        $visibleDrafts = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $allDrafts) {
            $c0 = Read-LLText $d.FullName
            $row0 = Resolve-DraftRow $d $c0
            if (-not (Test-TodayDraft -Draft $d -Row $row0)) {
                $excludedBacklog++
                continue
            }
            $visibleDrafts.Add($d)
        }
        $allDrafts = @($visibleDrafts)
    }

    if ($allDrafts.Count -eq 0) {
        Write-Host "  오늘 승인할 초안이 없습니다." -ForegroundColor Yellow
        if ($excludedBacklog -gt 0) {
            Write-Host ("  과거 초안 제외: {0} 개 (-IncludeBacklog 로 포함)" -f $excludedBacklog) -ForegroundColor DarkGray
        }
        if ($excludedByproducts -gt 0) {
            Write-Host ("  부산물 제외: {0} 개 (-IncludeByproducts 로 포함)" -f $excludedByproducts) -ForegroundColor DarkGray
        }
        exit 0
    }

    Write-Host ""
    if ($SectionFilter) {
        Write-Host ("  --- 오늘 초안 목록 (QA 배지 / section={0}) ---" -f $SectionFilter) -ForegroundColor Magenta
    } else {
        Write-Host "  --- 오늘 초안 목록 (QA 배지) ---" -ForegroundColor Magenta
    }
    for ($i = 0; $i -lt $allDrafts.Count; $i++) {
        $rel = $allDrafts[$i].FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
        $c = Read-LLText $allDrafts[$i].FullName
        $row = Resolve-DraftRow $allDrafts[$i] $c
        $section = ($rel -split "/")[0]
        $b = Get-LLDraftBadges -Content $c -Row $row -Section $section
        $readyPath = Join-Path (Join-Path $ReadyDir $section) $allDrafts[$i].Name
        $snapshot = Get-LLApprovalSnapshotStatus -ReadyRoot $ReadyDir -ApprovedPath $readyPath -SourceId (Get-LLProp $row 'source_id') -Section $section -FileName $allDrafts[$i].Name
        $reapproval = (
            $row -and (Get-LLProp $row 'status').ToLowerInvariant() -eq 'approved' -and
            $snapshot.status -ne 'match' -and $b.qaPass -and
            (Get-LLProp $row 'public_policy').ToLowerInvariant() -in @('public','partial-public') -and
            (Test-LLPublishableSource $row) -and -not $b.isByproduct
        )
        $isPub = Test-LLDraftAlreadyPublished -Draft $allDrafts[$i] -Row $row -PublishedNames $publishedNames
        $canApproveItem = $b.canApprove -or $reapproval
        $mark = if ($isPub) { "📦" } elseif ($reapproval) { "🔁" } elseif ($b.canApprove) { "✅" } else { "⛔" }
        $col  = if ($isPub) { "DarkGray" } elseif ($canApproveItem) { "Green" } else { "DarkGray" }
        $badgeStr = ($b.badges | ForEach-Object { $_.text }) -join " "
        if ($reapproval) { $badgeStr += " 재승인 필요" }
        if ($isPub) { $badgeStr = "이미 발행됨 " + $badgeStr }
        Write-Host ("  [{0,2}] {1} {2}" -f ($i + 1), $mark, $rel) -ForegroundColor $col
        Write-Host ("       {0}" -f $badgeStr) -ForegroundColor DarkGray
    }
    if ($excludedByproducts -gt 0) {
        Write-Host ("  부산물 제외: {0} 개 (-IncludeByproducts 로 포함 가능)" -f $excludedByproducts) -ForegroundColor DarkGray
    }
    if ($excludedBacklog -gt 0) {
        Write-Host ("  과거 초안 제외: {0} 개 (-IncludeBacklog 로 포함)" -f $excludedBacklog) -ForegroundColor DarkGray
    }
    Write-Host "  [ A] 승인 가능한 전체" -ForegroundColor Yellow
    Write-Host "  [ Q] 취소" -ForegroundColor DarkGray
    Write-Host ""

    if ($All) {
        $targets = $allDrafts
    } else {
        $sel = (Read-Host "  번호 입력 (쉼표로 여러 개, 예: 1,3,5)").Trim().ToUpper()
        if ($sel -eq "Q" -or $sel -eq "") { Write-Host "  취소됨." -ForegroundColor DarkGray; exit 0 }
        if ($sel -eq "A") {
            $targets = $allDrafts
        } else {
            $indices = $sel -split "," | ForEach-Object { [int]$_.Trim() - 1 }
            $targets = @($indices | ForEach-Object { $allDrafts[$_] } | Where-Object { $null -ne $_ })
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Host "  선택된 파일 없음." -ForegroundColor Yellow
    exit 0
}

# ── 승인 처리 ──
$approved = 0; $blocked = 0; $skippedPublished = 0
Write-Host ""
foreach ($d in $targets) {
    $rel = $d.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
    $content = Read-LLText $d.FullName
    $row = Resolve-DraftRow $d $content
    $isByproduct = Test-LLDraftByproduct -Draft $d -Row $row
    $section = ($rel -split "/")[0]
    $b = Get-LLDraftBadges -Content $content -Row $row -ByproductOverride $isByproduct -Section $section
    $destDir = Join-Path $ReadyDir $section
    $dest = Join-Path $destDir $d.Name
    $snapshot = Get-LLApprovalSnapshotStatus -ReadyRoot $ReadyDir -ApprovedPath $dest -SourceId (Get-LLProp $row 'source_id') -Section $section -FileName $d.Name
    $reapproval = (
        $row -and (Get-LLProp $row 'status').ToLowerInvariant() -eq 'approved' -and
        $snapshot.status -ne 'match' -and $b.qaPass -and
        (Get-LLProp $row 'public_policy').ToLowerInvariant() -in @('public','partial-public') -and
        (Test-LLPublishableSource $row) -and -not $b.isByproduct
    )

    if (-not $IncludePublished -and (Test-LLDraftAlreadyPublished -Draft $d -Row $row -PublishedNames $publishedNames)) {
        Write-Host ("  [건너뜀] {0}" -f $rel) -ForegroundColor DarkGray
        Write-Host "         사유: 이미 발행됨 (갱신하려면 -IncludePublished)" -ForegroundColor DarkGray
        $skippedPublished++
        continue
    }

    if (-not $b.canApprove -and -not $reapproval) {
        $why = ($b.badges | Where-Object { $_.cls -ne "ok" } | ForEach-Object { $_.text }) -join ", "
        Write-Host ("  [차단] {0}" -f $rel) -ForegroundColor Red
        Write-Host ("         사유: {0}" -f $why) -ForegroundColor DarkGray
        $blocked++
        continue
    }

    $section = ($rel -split "/")[0]
    if (-not $section) { $section = "learning" }
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if (Test-Path -LiteralPath $dest) {
        $null = Backup-LLFile -Path $dest -Prefix ('approved_before_reapproval_' + [guid]::NewGuid().ToString('N'))
    }
    Copy-Item -LiteralPath $d.FullName -Destination $dest -Force

    $sid = Get-LLDraftSourceId $content
    if (-not $sid -and $row) { $sid = Get-LLProp $row "source_id" }
    if ($sid) { $null = Set-LLRegistryStatus -SourceId $sid -Status "approved" }

    Add-LLApprovalLogEntry -LogPath $LogPath -FileName $d.Name -SourceId $sid -Section $section -QaStatus "PASS" -Notes $(if ($reapproval) { 'explicit reapproval' } else { '' }) -ApprovedPath $dest -ReadyRoot $ReadyDir

    Write-Host ("  [{0}] {1} -> 05_ready_to_publish/{2}/" -f $(if ($reapproval) {'재승인'} else {'승인'}), $rel, $section) -ForegroundColor Green
    $approved++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  승인: {0}  /  차단: {1}  /  이미 발행 건너뜀: {2}" -f $approved, $blocked, $skippedPublished) -ForegroundColor White
if ($approved -gt 0) {
    Write-Host "  다음: [5] publish 로 승인본을 발행하세요." -ForegroundColor Cyan
}
Write-Host "========================================" -ForegroundColor Cyan
exit 0
