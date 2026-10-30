#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Publish — 승인된 draft 를 blog-source 에 복사 + git push

.DESCRIPTION
    하는 것:
      - 04_blog_drafts\ 의 .md 파일 목록 표시
      - 선택한 파일(들)을 blog-source\content\{section}\ 에 복사
      - front matter 에서 draft:true → false, source_id 제거, ai_assisted 마킹 추가
      - git add + git commit + git push
      - source_registry.csv status → published

    하지 않는 것:
      - 원본 파일 수정/삭제 없음
      - 명시 선택 없이 자동 발행 없음

.PARAMETER All
    모든 draft 를 한번에 발행 (기본: 선택 메뉴)

.PARAMETER DraftPath
    특정 draft 파일 경로를 하나 이상 지정

.PARAMETER IncludePublished
    이미 blog-source/content 에 있는 글도 갱신 대상으로 포함한다. 기본값은 신규 글만 발행한다.

.PARAMETER IncludeBacklog
    오늘 날짜가 아닌 과거 승인본도 신규 발행 후보에 포함한다. 기본값은 오늘 승인본만 발행한다.

.PARAMETER Section
    특정 섹션만 발행 후보에 포함한다. 예: learning, projects

.PARAMETER ConfirmUpdates
    기존 발행 글을 갱신할 때의 확인을 비대화형으로 승인한다.

.PARAMETER SelectionFile
    컨트롤센터가 명시적으로 선택한 승인본의 상대 경로·SHA-256 목록(JSON).
    승인·본문 변경·선택 외 content 변경은 복사/빌드/푸시 전에 다시 검사한다.

.PARAMETER NonInteractive
    SelectionFile이 있을 때만 사용한다. 번호 입력이나 기존 글 갱신 확인창을 열지 않는다.

.NOTES
    blog-source 경로: $BlogSourceRoot 변수에서 설정
#>

param(
    [switch]$All,
    [string[]]$DraftPath = @(),
    [switch]$IncludePublished,
    [switch]$IncludeBacklog,
    [string]$Section = "",
    [switch]$ConfirmUpdates,
    [string]$SelectionFile = '',
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.PublishPreflight.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.PublishGitGuard.psm1") -Force -DisableNameChecking

# ─────────────────────────────────────────────────────────
# 경로 설정
# ─────────────────────────────────────────────────────────
$Root           = Get-LLRoot
$DraftsDir      = Get-LLPath "05_ready_to_publish"   # 승인된 글만 발행 (04 직접 발행 차단)
$PublishedDir   = Get-LLPath "06_published"
$DraftAssetRoot = Get-LLPath "04_blog_drafts\_assets"
$RegistryPath   = Get-LLRegistryPath
$BlogSourceRoot = Get-LLBlogRoot   # Hugo 사이트 루트

# UI는 명시적으로 선택한 승인본의 경로·해시만 전달한다. 자동 전체 발행은 금지한다.
if ($NonInteractive -and -not $SelectionFile) { throw '비대화형 발행에는 명시적 SelectionFile이 필요합니다.' }
if ($SelectionFile -and ($All -or $DraftPath.Count -gt 0 -or $IncludePublished -or $ConfirmUpdates)) { throw 'UI 선택 발행과 전체/경로/기존 글 갱신 옵션은 함께 쓸 수 없습니다.' }
$uiSelection=@()
if ($SelectionFile) {
    if ((Get-Item -LiteralPath $SelectionFile).Length -gt 262144) { throw '발행 선택 파일이 너무 큽니다.' }
    $selection=Get-Content -LiteralPath $SelectionFile -Raw -Encoding utf8 | ConvertFrom-Json
    if ($selection.version -ne 1 -or $selection.files -isnot [array]) { throw '발행 선택 파일의 형식이 올바르지 않습니다.' }
    $uiSelection=@(Resolve-LLReadyPublishSelection -Files $selection.files)
    $DraftPath=@($uiSelection.full_path)
}

$RunDT    = Get-Date
$RunTime  = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$TodayStr = $RunDT.ToString("yyyy-MM-dd")
$SectionFilter = $Section.Trim().ToLowerInvariant()

$fence = '```'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan

$schema = Ensure-LLRegistrySchema
if ($schema.upgraded -and $schema.backup) {
    Write-Host ("  registry upgraded: {0}" -f $schema.backup) -ForegroundColor Yellow
}
Write-Host "  LearningLog Publish" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 05_ready_to_publish 에 잔여 파일이 있어도 registry 상태가 승인되지 않은
# 파일은 발행 선택 목록에 노출하지 않는다.
$selectionRows = @(Get-LLRegistryRows)
$approvalRows = @(Get-LLApprovalLogRows)
function Resolve-PublishRegistryRow {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $content = Read-LLText $Draft.FullName
    $sid = Get-LLDraftSourceId $content
    if ($sid) {
        $matches = @($selectionRows | Where-Object { (Get-LLProp $_ 'source_id') -eq $sid })
        if ($matches.Count -eq 1) { return $matches[0] }
        return $null
    }
    $matches = @($selectionRows | Where-Object { (Get-LLProp $_ 'topic') -eq $Draft.BaseName })
    if ($matches.Count -ne 1) { $matches = @($selectionRows | Where-Object { (Get-LLProp $_ 'file_name') -eq $Draft.Name }) }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}
function Test-PublishStatusAllowed {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft)
    $row = Resolve-PublishRegistryRow -Draft $Draft
    if ($null -eq $row) { return $false }
    $status = (Get-LLProp $row "status").Trim().ToLowerInvariant()
    if ($status -ne 'approved' -and -not ($IncludePublished -and $status -eq 'published')) { return $false }
    if (-not (Test-LLPublishableSource $row)) { return $false }
    $relative = $Draft.FullName.Substring(($DraftsDir.TrimEnd('\') + '\').Length).Replace('\', '/')
    $section = ($relative -split '/')[0]
    $snapshot = Get-LLApprovalSnapshotStatus -ReadyRoot $DraftsDir -ApprovedPath $Draft.FullName -SourceId (Get-LLProp $row 'source_id') -Section $section -FileName $Draft.Name -Rows $approvalRows
    return ($snapshot.status -eq 'match')
}

# ─────────────────────────────────────────────────────────
# blog-source 존재 확인
# ─────────────────────────────────────────────────────────
if (-not (Test-Path $BlogSourceRoot)) {
    Write-Host "  [ERROR] blog-source 폴더 없음: $BlogSourceRoot" -ForegroundColor Red
    Write-Host "  blog-source 경로를 스크립트 상단 \$BlogSourceRoot 에서 수정하세요." -ForegroundColor Yellow
    exit 1
}

# git 설치 확인
try { $null = git --version 2>&1 } catch {
    Write-Host "  [ERROR] git 명령어를 찾을 수 없습니다. Git 이 설치되어 있는지 확인하세요." -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────
# draft 파일 목록 수집
# ─────────────────────────────────────────────────────────
function New-PublishPlan {
    param([Parameter(Mandatory)]$Draft)

    $rel = $Draft.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
    $section = ($rel -split "/")[0]
    $fname = $Draft.Name
    $destDir = Join-Path $BlogSourceRoot "content\$section"
    $destPath = Join-Path $destDir $fname
    $pubMarker = Join-Path $PublishedDir $fname
    # "발행됨" = content 복사본 + 06_published 표식이 둘 다 있을 때만.
    # 06_published 는 배포(빌드+푸시) 성공 후에만 기록되므로,
    # 빌드/푸시 실패로 복사만 된 글은 다음 실행에서 다시 신규로 잡힌다.
    $isUpdate = (Test-Path -LiteralPath $destPath) -and (Test-Path -LiteralPath $pubMarker)

    return [pscustomobject]@{
        Draft = $Draft
        Rel = $rel
        Section = $section
        FileName = $fname
        DestDir = $destDir
        DestPath = $destPath
        IsUpdate = $isUpdate
    }
}

function Test-PublishSection {
    param([Parameter(Mandatory)]$Draft)
    if (-not $SectionFilter) { return $true }
    $rel = $Draft.FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
    $sectionName = (($rel -split "/")[0]).ToLowerInvariant()
    return ($sectionName -eq $SectionFilter)
}

$excludedPublished = 0
$excludedBacklog = 0
$excludedUnapproved = 0

function Test-TodayDraft {
    param([Parameter(Mandatory)]$Draft)

    if ($IncludeBacklog) { return $true }
    if ($Draft.Name -like "$TodayStr*") { return $true }
    if ($Draft.LastWriteTime.ToString("yyyy-MM-dd") -eq $TodayStr) { return $true }
    return $false
}

if ($DraftPath.Count -gt 0) {
    $targets = @($DraftPath | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue })
    if ($SectionFilter) { $targets = @($targets | Where-Object { Test-PublishSection $_ }) }
} elseif ($All) {
    $allDrafts = @(Get-ChildItem -Path $DraftsDir -Recurse -Filter "*.md" -File | Sort-Object FullName)
    if ($SectionFilter) { $allDrafts = @($allDrafts | Where-Object { Test-PublishSection $_ }) }
    $beforeStatusFilter = $allDrafts.Count
    $allDrafts = @($allDrafts | Where-Object { Test-PublishStatusAllowed $_ })
    $excludedUnapproved = $beforeStatusFilter - $allDrafts.Count
    if (-not $IncludePublished) {
        $visibleDrafts = @($allDrafts | Where-Object { -not (New-PublishPlan -Draft $_).IsUpdate })
        $excludedPublished = $allDrafts.Count - $visibleDrafts.Count
        $allDrafts = $visibleDrafts
    }
    if (-not $IncludeBacklog) {
        $visibleDrafts = @($allDrafts | Where-Object { Test-TodayDraft -Draft $_ })
        $excludedBacklog = $allDrafts.Count - $visibleDrafts.Count
        $allDrafts = $visibleDrafts
    }
    $targets = $allDrafts
} else {
    # 대화형 선택
    $allDrafts = @(Get-ChildItem -Path $DraftsDir -Recurse -Filter "*.md" -File | Sort-Object FullName)
    if ($SectionFilter) { $allDrafts = @($allDrafts | Where-Object { Test-PublishSection $_ }) }
    $beforeStatusFilter = $allDrafts.Count
    $allDrafts = @($allDrafts | Where-Object { Test-PublishStatusAllowed $_ })
    $excludedUnapproved = $beforeStatusFilter - $allDrafts.Count
    if ($allDrafts.Count -eq 0) {
        if ($SectionFilter) {
            Write-Host ("  발행할 승인본이 없습니다. (section={0})" -f $SectionFilter) -ForegroundColor Yellow
        } else {
            Write-Host "  발행할 승인본이 없습니다 (05_ready_to_publish 비어 있음)." -ForegroundColor Yellow
        }
        Write-Host "  먼저 [V] preview 로 확인하고 [A] approve 로 승인하세요." -ForegroundColor DarkGray
        exit 0
    }

    if (-not $IncludePublished) {
        $visibleDrafts = @($allDrafts | Where-Object { -not (New-PublishPlan -Draft $_).IsUpdate })
        $excludedPublished = $allDrafts.Count - $visibleDrafts.Count
        $allDrafts = $visibleDrafts
    }
    if (-not $IncludeBacklog) {
        $visibleDrafts = @($allDrafts | Where-Object { Test-TodayDraft -Draft $_ })
        $excludedBacklog = $allDrafts.Count - $visibleDrafts.Count
        $allDrafts = $visibleDrafts
    }

    if ($allDrafts.Count -eq 0) {
        Write-Host "  발행할 오늘 신규 승인본이 없습니다." -ForegroundColor Yellow
        if ($excludedPublished -gt 0) {
            Write-Host ("  이미 발행된 승인본 {0} 개는 기본 발행에서 제외했습니다." -f $excludedPublished) -ForegroundColor DarkGray
            Write-Host "  기존 글을 갱신해야 할 때만 -IncludePublished 옵션을 사용하세요." -ForegroundColor DarkGray
        }
        if ($excludedBacklog -gt 0) {
            Write-Host ("  과거 미발행 승인본 {0} 개는 기본 발행에서 제외했습니다." -f $excludedBacklog) -ForegroundColor DarkGray
            Write-Host "  과거 승인본을 발행해야 할 때만 -IncludeBacklog 옵션을 사용하세요." -ForegroundColor DarkGray
        }
        exit 0
    }

    Write-Host ""
    if ($SectionFilter) {
        Write-Host ("  --- 발행 가능한 오늘 신규 승인본 목록 (section={0}) ---" -f $SectionFilter) -ForegroundColor Magenta
    } else {
        Write-Host "  --- 발행 가능한 오늘 신규 승인본 목록 ---" -ForegroundColor Magenta
    }
    for ($i = 0; $i -lt $allDrafts.Count; $i++) {
        $rel = $allDrafts[$i].FullName.Replace($DraftsDir + "\", "").Replace("\", "/")
        Write-Host ("  [{0,2}] {1}" -f ($i + 1), $rel) -ForegroundColor White
    }
    if ($excludedPublished -gt 0) {
        Write-Host ("  이미 발행된 승인본 제외: {0} 개 (-IncludePublished 로 갱신 모드)" -f $excludedPublished) -ForegroundColor DarkGray
    }
    if ($excludedBacklog -gt 0) {
        Write-Host ("  과거 미발행 승인본 제외: {0} 개 (-IncludeBacklog 로 포함)" -f $excludedBacklog) -ForegroundColor DarkGray
    }
    if ($excludedUnapproved -gt 0) {
        Write-Host ("  승인되지 않은 파일 제외: {0} 개 (rejected/drafted/needs_review 등)" -f $excludedUnapproved) -ForegroundColor DarkGray
    }
    Write-Host "  [ A] 전체 발행" -ForegroundColor Yellow
    Write-Host "  [ Q] 취소" -ForegroundColor DarkGray
    Write-Host ""

    $input = Read-Host "  번호 입력 (쉼표로 여러 개 가능, 예: 1,3,5)"
    $input = $input.Trim().ToUpper()

    if ($input -eq "Q" -or $input -eq "") { Write-Host "  취소됨." -ForegroundColor DarkGray; exit 0 }

    if ($input -eq "A") {
        $targets = $allDrafts
    } else {
        $indices = $input -split "," | ForEach-Object { [int]$_.Trim() - 1 }
        $targets = @($indices | ForEach-Object { $allDrafts[$_] } | Where-Object { $null -ne $_ })
    }
}

if (-not $SelectionFile) {
    $invalidTargets = @($targets | Where-Object { -not (Test-PublishStatusAllowed $_) })
    if ($invalidTargets.Count -gt 0) {
        $invalidNames = @($invalidTargets | ForEach-Object { $_.Name }) -join ', '
        throw "승인 당시 파일 해시와 일치하지 않거나 발행 자격이 없는 승인본입니다. 미리보기에서 다시 승인하세요: $invalidNames"
    }
}

if ($targets.Count -eq 0) {
    Write-Host "  선택된 파일 없음." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host ("  발행 대상: {0} 개" -f $targets.Count) -ForegroundColor Yellow

$targetPlans = [System.Collections.Generic.List[object]]::new()
$newTargets = [System.Collections.Generic.List[object]]::new()
$updateTargets = [System.Collections.Generic.List[object]]::new()

foreach ($draft in $targets) {
    $plan = New-PublishPlan -Draft $draft
    $targetPlans.Add($plan)
    if ($plan.IsUpdate) { $updateTargets.Add($plan) } else { $newTargets.Add($plan) }
}

Write-Host ("  신규 추가: {0} 개" -f $newTargets.Count) -ForegroundColor Green
Write-Host ("  기존 글 갱신: {0} 개" -f $updateTargets.Count) -ForegroundColor $(if ($updateTargets.Count -gt 0) { "Yellow" } else { "DarkGray" })

if ($updateTargets.Count -gt 0) {
    if ($NonInteractive -or $SelectionFile) { throw 'UI에서는 기존 발행 글을 갱신하지 않습니다.' }
    Write-Host ""
    Write-Host "  --- 기존 글 갱신 대상 ---" -ForegroundColor Yellow
    foreach ($plan in $updateTargets) {
        Write-Host ("  - {0}/{1}" -f $plan.Section, $plan.FileName) -ForegroundColor Yellow
    }
    Write-Host ""
    $confirmUpdate = if ($ConfirmUpdates) { "Y" } else { (Read-Host "  기존 글을 갱신합니다. 계속할까요? (Y/N)").Trim().ToUpperInvariant() }
    if ($confirmUpdate -ne "Y") {
        Write-Host "  취소됨. 복사/빌드/푸시를 시작하지 않았습니다." -ForegroundColor DarkGray
        exit 0
    }
}

# ─────────────────────────────────────────────────────────
# 헬퍼: front matter 처리
# ─────────────────────────────────────────────────────────
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

    $i = $start
    while ($i -lt $lines.Count) {
        $isBlock = $false
        $end = -1
        if ($lines[$i].Trim() -eq "---") {
            for ($j = $i + 1; $j -lt [Math]::Min($lines.Count, $i + 20); $j++) {
                if ($lines[$j].Trim() -eq "---") { $end = $j; break }
            }
            if ($end -gt $i) {
                $body = @($lines[($i + 1)..($end - 1)] | ForEach-Object { $_.Trim().ToLowerInvariant() })
                $keyCount = @($body | Where-Object {
                    $_.StartsWith("title:") -or $_.StartsWith("date:") -or $_.StartsWith("draft:") -or
                    $_.StartsWith("categories:") -or $_.StartsWith("tags:") -or $_.StartsWith("description:")
                }).Count
                $hasTitle = @($body | Where-Object { $_.StartsWith("title:") }).Count -gt 0
                $hasDateOrDraft = @($body | Where-Object { $_.StartsWith("date:") -or $_.StartsWith("draft:") }).Count -gt 0
                $isBlock = $hasTitle -and $hasDateOrDraft -and ($keyCount -ge 3)
            }
        }

        if ($isBlock) {
            while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq "") { $out.RemoveAt($out.Count - 1) }
            if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq "---") { $out.RemoveAt($out.Count - 1) }
            $i = $end + 1
            while ($i -lt $lines.Count -and $lines[$i].Trim() -eq "") { $i++ }
            continue
        }

        $out.Add($lines[$i])
        $i++
    }

    return (($out -join "`n").TrimEnd() + "`n")
}

function Process-FrontMatter {
    param(
        [string]$Content,
        [string]$ModelName = "local-llm"
    )

    $out = ConvertTo-LLPublishMarkdown -Content $Content -ModelName $ModelName
    # Hugo v0.144+ 에서 제거된 front matter 키를 발행 시점에 자동 제거
    # (남아 있으면 hugo 빌드가 ERROR 로 중단됨 — 2026-07-12 lang 사건)
    $out = $out -replace '(?m)^\s*lang\s*:\s*.*\r?\n', ''
    return $out
}

# ─────────────────────────────────────────────────────────
# 헬퍼: registry status → published
# ─────────────────────────────────────────────────────────
function _UpdateRegistry {
    param([string]$Sid)
    $null = Set-LLRegistryStatus -SourceId $Sid -Status "published"
}

function Get-HugoCommandPath {
    # 1) 허브 공용 portable_kit\tools\hugo.exe
    $localHugo = Join-Path (Split-Path $BlogSourceRoot -Parent) "portable_kit\tools\hugo.exe"
    if (Test-Path -LiteralPath $localHugo) { return $localHugo }

    # 2) PATH
    $cmd = Get-Command hugo -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 3) winget 설치본 (Hugo.Hugo.Extended) — 현재 사용자 기준
    $knownRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $knownRoot) {
        $found = Get-ChildItem -LiteralPath $knownRoot -Recurse -Filter "hugo.exe" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*Hugo.Hugo.Extended*" } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return ""
}

function Get-DraftRegistryRow {
    param(
        [string]$DraftName,
        [string]$RawContent
    )
    $sid = Get-LLDraftSourceId -Content $RawContent
    $rows = $selectionRows
    if ($sid) {
        $matches = @($rows | Where-Object { $_.source_id -eq $sid })
        if ($matches.Count -eq 1) { return $matches[0] }
        return $null
    }
    $topic = [System.IO.Path]::GetFileNameWithoutExtension($DraftName)
    $matches = @($rows | Where-Object { $_.topic -eq $topic })
    if ($matches.Count -ne 1) { $matches = @($rows | Where-Object { $_.file_name -eq $DraftName }) }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-FrontMatterValue {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Key
    )
    $pattern = "(?m)^$([regex]::Escape($Key)):\s*`"?(.+?)`"?\s*$"
    if ($Content -match $pattern) { return $Matches[1].Trim() }
    return ""
}

function Test-DraftQualityGate {
    param(
        [Parameter(Mandatory)][string]$DraftName,
        [Parameter(Mandatory)][string]$RawContent,
        $SourceRow
    )

    $section = ""
    if ($SourceRow) {
        $sourcePath = (Get-LLProp $SourceRow "source_path") -replace "\\", "/"
        if ($sourcePath -match '(?i)(?:^|/)04_blog_drafts/([^/]+)/') { $section = $Matches[1] }
    }
    $issues = @(Get-LLDraftQualityIssues -Content $RawContent -Row $SourceRow -Section $section)
    if ($issues.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Reason = "draft quality: " + ($issues -join ", ") }
    }

    if ($null -ne $SourceRow) {
        $status = (Get-LLProp $SourceRow "status").ToLowerInvariant()
        if ($status -in @("needs_review", "archived", "rejected")) {
            return [pscustomobject]@{ Ok = $false; Reason = "status gate: $status" }
        }

        $topic = (Get-LLProp $SourceRow "topic").ToLowerInvariant()
        $category = (Get-LLProp $SourceRow "source_category").ToLowerInvariant()
        $draftTitle = (Get-FrontMatterValue -Content $RawContent -Key "title").ToLowerInvariant()

        # High-signal mismatch guard for single-source drafts only.
        # Daily merged posts can legitimately mention several topics in the title.
        $isDailyMerged = ($category -eq "daily_merged" -or $topic -match '^\d{4}-\d{2}-\d{2}-(am|pm)-daily$')
        $looksLikePandas = ($draftTitle -match "pandas|read[_\. -]?csv|\bcsv\b")
        $sourceIsPandas = ($topic -match "pandas|read[_\. -]?csv|\bcsv\b")
        if (-not $isDailyMerged -and $looksLikePandas -and -not $sourceIsPandas) {
            return [pscustomobject]@{
                Ok = $false
                Reason = "title/topic mismatch: title looks like pandas/read_csv but topic is '$topic'"
            }
        }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "" }
}

function Get-DraftReferencedAssetPaths {
    param([Parameter(Mandatory)][string]$Content)

    $refs = @([regex]::Matches($Content, '!\[[^\]]*\]\((/images/[^)\s]+)\)') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($ref in $refs) {
        $relative = [Uri]::UnescapeDataString($ref.TrimStart("/")) -replace '\\', '/'
        if ($relative -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($relative)) {
            throw "허용되지 않은 이미지 경로: $ref"
        }
        $paths.Add($relative)
    }
    return $paths.ToArray()
}

function Copy-DraftReferencedAssets {
    param(
        [Parameter(Mandatory)][string]$Content,
        [AllowNull()][System.Collections.Generic.List[object]]$CreatedArtifacts = $null
    )

    $refs = @(Get-DraftReferencedAssetPaths -Content $Content)
    if ($refs.Count -eq 0) { return 0 }
    if (-not (Test-Path -LiteralPath $DraftAssetRoot)) {
        throw "초안 이미지 저장소가 없습니다: $DraftAssetRoot"
    }

    $assetRootFull = (Resolve-Path -LiteralPath $DraftAssetRoot).Path
    $copied = 0
    foreach ($assetPath in $refs) {
        $relative = $assetPath -replace '/', '\'
        $source = Join-Path $assetRootFull $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "초안 이미지 없음: /images/$assetPath" }
        $sourceFull = (Resolve-Path -LiteralPath $source).Path
        if (-not $sourceFull.StartsWith($assetRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "초안 이미지 저장소 밖의 경로: $assetPath"
        }

        $ext = [IO.Path]::GetExtension($sourceFull).ToLowerInvariant()
        if ($ext -notin @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")) {
            throw "지원하지 않는 이미지 형식: $assetPath"
        }
        $dest = Join-Path (Join-Path $BlogSourceRoot "static") $relative
        $destParent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        $disposition = Get-LLPublishDestinationDisposition `
            -DestinationPath $dest `
            -ExpectedFilePath $sourceFull `
            -Label '블로그 이미지'
        if ($disposition -eq 'Create') {
            # CreateNew prevents a file appearing between the check and copy from being overwritten.
            [System.IO.File]::Copy($sourceFull, $dest, $false)
            if ($null -ne $CreatedArtifacts) {
                $CreatedArtifacts.Add([pscustomobject]@{
                    full_path=$dest; repo_path=$dest.Substring($BlogSourceRoot.Length + 1).Replace('\','/'); sha256=(Get-LLHash $dest)
                })
            }
            $copied++
        }
    }
    return $copied
}

# ─────────────────────────────────────────────────────────
# 발행 처리
# ─────────────────────────────────────────────────────────
$publishedCount = 0
$publishedNewCount = 0
$publishedUpdateCount = 0
$errors         = [System.Collections.Generic.List[string]]::new()
$skippedPublishTargets = [System.Collections.Generic.List[string]]::new()
# 배포 성공 후에만 06_published 표식 + registry published 를 기록하기 위한 대기열
$pendingRecords = [System.Collections.Generic.List[object]]::new()
$sourcePathsToStage = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$createdPublishArtifacts = [System.Collections.Generic.List[object]]::new()
$publishAttemptId = [guid]::NewGuid().ToString('N')
$script:PublishAttemptHashes = @{}
$script:PublishOutcomeRecorded = $false
$script:PublicStageAttempted = $false
$script:PublicCommitAttempted = $false
$script:PublicCommitCompleted = $false
$script:PublicPushAttempted = $false
$script:LivePushCompleted = $false

function Move-CreatedPublishArtifactsToTrash {
    param([Parameter(Mandatory)][string]$AttemptId)
    $moved = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    if ($script:PublicStageAttempted -or $script:PublicCommitAttempted -or $script:PublicCommitCompleted -or $script:PublicPushAttempted -or $script:LivePushCompleted) {
        return [pscustomobject]@{ moved=@(); skipped=@('공개 저장소 Git 상태가 바뀌었을 수 있어 자동 정리를 보류했습니다.') }
    }
    $trashRunRoot = Get-LLPath ('.trash\publish_attempt_' + $AttemptId + '\blog-source')
    $trashPrefix = [IO.Path]::GetFullPath($trashRunRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($artifact in $createdPublishArtifacts) {
        if (-not (Test-Path -LiteralPath $artifact.full_path -PathType Leaf)) { continue }
        if ((Get-LLHash $artifact.full_path) -ine $artifact.sha256) {
            $skipped.Add("$($artifact.repo_path): 복사 후 파일이 바뀌어 보존")
            continue
        }
        $relative = ([string]$artifact.repo_path).Replace('\','/')
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Split('/') -contains '..') {
            $skipped.Add("$($artifact.repo_path): 저장소 밖 경로라 보존")
            continue
        }
        $destination = Join-Path $trashRunRoot ($relative -replace '/', [string][IO.Path]::DirectorySeparatorChar)
        if (-not [IO.Path]::GetFullPath($destination).StartsWith($trashPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $skipped.Add("$($artifact.repo_path): 휴지통 경계를 벗어나 보존")
            continue
        }
        if (Test-Path -LiteralPath $destination) {
            $skipped.Add("$($artifact.repo_path): 휴지통 목적지 충돌로 보존")
            continue
        }
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        try {
            [IO.File]::Move($artifact.full_path, $destination)
            $moved.Add("$($artifact.repo_path) -> $(Get-LLRelativePath $destination)")
        } catch { $skipped.Add("$($artifact.repo_path): $($_.Exception.Message)") }
    }
    if ($moved.Count -gt 0 -or $skipped.Count -gt 0) {
        $manifest = [ordered]@{
            version=1; disposition='retryable_publish_failure_cleanup'; attempt_id=$AttemptId
            created_at=[DateTimeOffset]::Now.ToString('o'); moved=@($moved); skipped=@($skipped)
            ready_approvals_preserved=$true; published_content_touched=$false
        }
        Write-LLText -Path (Join-Path $trashRunRoot '_cleanup.json') -Content (ConvertTo-Json $manifest -Depth 4)
    }
    return [pscustomobject]@{ moved=@($moved); skipped=@($skipped) }
}

function Write-PublishAttemptOutcome {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$FailureCode = '',
        [string]$Message = '',
        [string]$PublishedDate = '',
        [string[]]$CleanupPaths = @()
    )
    if ($script:PublishOutcomeRecorded) { return }
    foreach ($targetPlan in $targetPlans) {
        $relative = [string]$targetPlan.Rel
        $sourceId = ''
        if ($preflightCache.ContainsKey($targetPlan.Draft.FullName)) {
            $sourceId = Get-LLProp $preflightCache[$targetPlan.Draft.FullName].SourceRow 'source_id'
        } else {
            $row = Resolve-PublishRegistryRow -Draft $targetPlan.Draft
            if ($null -ne $row) { $sourceId = Get-LLProp $row 'source_id' }
        }
        $contentHash = ''
        if ($preflightCache.ContainsKey($targetPlan.Draft.FullName)) {
            $contentHash = [string]$preflightCache[$targetPlan.Draft.FullName].DraftSha256
        } elseif ($script:PublishAttemptHashes.ContainsKey($targetPlan.Draft.FullName)) {
            $contentHash = [string]$script:PublishAttemptHashes[$targetPlan.Draft.FullName]
        } else {
            $contentHash = Get-LLHash $targetPlan.Draft.FullName
        }
        $null = Add-LLPublishLedgerEntry `
            -DraftPath ('05_ready_to_publish/' + $relative) `
            -HugoTargetPath ('content/' + $targetPlan.Section + '/' + $targetPlan.FileName) `
            -PublishedDate $PublishedDate -PublicUrl '' -Status $Status -SourceId $sourceId `
            -ContentSha256 $contentHash -FailureCode $FailureCode -Message $Message `
            -CleanupPaths $CleanupPaths -AttemptId $publishAttemptId
    }
    $script:PublishOutcomeRecorded = $true
}

function Write-PublishAbortHint {
    param([string]$FailureCode = 'publish_aborted', [string]$Message = '')
    $cleanupPaths = @()
    if (-not $script:PublishOutcomeRecorded) {
        $status = if ($script:PublicStageAttempted -or $script:PublicCommitAttempted -or $script:PublicCommitCompleted -or $script:PublicPushAttempted -or $script:LivePushCompleted) { 'reconcile_required' } else { 'retryable_failed' }
        if ($status -eq 'retryable_failed') {
            $cleanup = Move-CreatedPublishArtifactsToTrash -AttemptId $publishAttemptId
            $cleanupPaths = @($cleanup.moved)
            if (@($cleanup.skipped).Count) { $Message = (($Message + ' · 정리 보류: ' + (@($cleanup.skipped) -join '; ')).Trim(' ', '·')) }
        }
        Write-PublishAttemptOutcome -Status $status -FailureCode $FailureCode -Message $Message -CleanupPaths $cleanupPaths
    }
    Write-Host ""
    if ($script:PublicStageAttempted -or $script:PublicCommitAttempted -or $script:PublicCommitCompleted -or $script:PublicPushAttempted -or $script:LivePushCompleted) {
        Write-Host "  공개 저장소 Git 상태와 라이브 반영 여부를 대조해야 합니다. 자동 정리·재발행을 멈추고 publish_ledger.csv에 reconcile_required로 기록했습니다." -ForegroundColor Yellow
    } else {
        Write-Host "  실패 원인을 publish_ledger.csv에 기록했습니다. 승인본은 보존되어 다시 시도할 수 있습니다." -ForegroundColor Yellow
        if ($cleanupPaths.Count) { Write-Host ("  이번 시도에서 새로 만든 미발행 사본은 .trash 로 이동했습니다: {0}" -f ($cleanupPaths -join ', ')) -ForegroundColor DarkGray }
    }
}

if ($SelectionFile) {
    # 목록을 연 뒤 승인이 취소되거나 본문이 바뀌었으면 복사·빌드·푸시 전에 중단한다.
    $null=@(Resolve-LLReadyPublishSelection -Files $selection.files)
    # 이전 실패에서 content에 복사만 된 다른 글을 Hugo가 함께 배포하지 않도록 막는다.
    $contentStatusText = Invoke-LLPublishGitCapture -RepoRoot $BlogSourceRoot -Arguments @('-c', 'core.quotepath=false', 'status', '--porcelain', '--untracked-files=all', '--', 'content')
    $contentStatus = @($contentStatusText -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-LLPublishContentSelection -StatusLines $contentStatus -SelectedPaths @($selection.files.path)
}
# 발행 전 모든 선택 파일을 먼저 검사한다. 한 건이라도 WARN/FAIL이면
# content·이미지 복사, Hugo, Git 동작 전에 전체 선택을 중단한다.
$preflightCache = @{}
$preflightFailures = [System.Collections.Generic.List[string]]::new()
foreach ($targetPlan in $targetPlans) {
    $draft = $targetPlan.Draft
    $relative = $draft.FullName.Substring(($DraftsDir.TrimEnd('\') + '\').Length).Replace('\', '/')
    try {
        $expectedHash = ''
        if ($SelectionFile) {
            $selectedFile = @($selection.files | Where-Object { ([string]$_.path) -ceq $relative })
            if ($selectedFile.Count -ne 1) { throw 'selection_entry_missing' }
            $expectedHash = [string]$selectedFile[0].hash
            $script:PublishAttemptHashes[$draft.FullName] = $expectedHash.ToLowerInvariant()
        }
        $rawHashBefore = Get-LLHash $draft.FullName
        if (-not $script:PublishAttemptHashes.ContainsKey($draft.FullName) -and $rawHashBefore) {
            $script:PublishAttemptHashes[$draft.FullName] = $rawHashBefore.ToLowerInvariant()
        }
        $raw = [System.IO.File]::ReadAllText($draft.FullName, [System.Text.Encoding]::UTF8)
        $rawHashAfter = Get-LLHash $draft.FullName
        if (-not $rawHashBefore -or $rawHashBefore -ine $rawHashAfter) { throw 'draft_changed_during_preflight_read' }
        $script:PublishAttemptHashes[$draft.FullName] = $rawHashAfter.ToLowerInvariant()
        $sourceRow = Get-DraftRegistryRow -DraftName $draft.Name -RawContent $raw
        $processed = Process-FrontMatter -Content $raw
        $registryStatus = ''
        $publicPolicy = ''
        $sourceCategory = ''
        if ($null -ne $sourceRow) {
            $registryStatus = Get-LLProp $sourceRow 'status'
            $publicPolicy = Get-LLProp $sourceRow 'public_policy'
            $sourceCategory = Get-LLProp $sourceRow 'source_category'
        }
        $preflight = Invoke-LLPublishPreflight `
            -Path $draft.FullName `
            -ReadyRoot $DraftsDir `
            -ExpectedSha256 $expectedHash `
            -RegistryStatus $registryStatus `
            -PublicPolicy $publicPolicy `
            -SourceCategory $sourceCategory `
            -OriginalContent $raw `
            -Content $processed `
            -DraftAssetRoot $DraftAssetRoot `
            -AllowPublished:$IncludePublished
        if ($preflight.status -ne 'PASS') {
            $codes = @($preflight.findings | ForEach-Object code) -join ', '
            $preflightFailures.Add("$relative [$($preflight.status)]: $codes")
            continue
        }
        $quality = Test-DraftQualityGate -DraftName $draft.Name -RawContent $processed -SourceRow $sourceRow
        if (-not $quality.Ok) {
            $preflightFailures.Add("$relative [FAIL]: draft_quality_gate")
            continue
        }
        $preflightCache[$draft.FullName] = [pscustomobject]@{
            Raw = $raw
            DraftSha256 = $rawHashAfter.ToLowerInvariant()
            SourceRow = $sourceRow
            Processed = $processed
            Result = $preflight
        }
    } catch {
        $preflightFailures.Add("$relative [FAIL]: preflight_execution_error")
    }
}
if ($preflightFailures.Count -gt 0) {
    $message = "발행 보안 사전검사 실패. 파일을 복사하거나 빌드·푸시하지 않았습니다: " + ($preflightFailures -join ' | ')
    Write-PublishAttemptOutcome -Status 'needs_review' -FailureCode 'preflight_failed' -Message $message
    throw $message
}

# Hugo 입력 저장소의 기존 변경은 이번 선택본/참조 이미지 외에는 발행에 섞지 않는다.
# public은 Hugo가 --cleanDestinationDir로 비우므로 시작 시 사용자 파일이 있으면 먼저 중단한다.
$allowedSourcePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($targetPlan in $targetPlans) {
    $null = $allowedSourcePaths.Add("content/$($targetPlan.Section)/$($targetPlan.FileName)")
    $processed = [string]$preflightCache[$targetPlan.Draft.FullName].Processed
    foreach ($assetPath in (Get-DraftReferencedAssetPaths -Content $processed)) {
        $null = $allowedSourcePaths.Add("static/$assetPath")
    }
}
$null = $allowedSourcePaths.Add('public') # 별도 검사하는 public submodule의 gitlink만 허용
$hugoInputPathspecs = @('content', 'static', 'assets', 'layouts', 'data', 'i18n', 'archetypes', 'config', 'themes', 'hugo.toml', 'hugo.yaml', 'hugo.json')
$PublicDir = Join-Path $BlogSourceRoot 'public'
try {
    $null = Assert-LLPublishRepositoryReady `
        -RepoRoot $BlogSourceRoot `
        -AllowedWorkingPaths @($allowedSourcePaths | ForEach-Object { $_ }) `
        -IgnoredPathspecs $hugoInputPathspecs `
        -Label 'blog-source'
    $null = Assert-LLPublishRepositoryReady `
        -RepoRoot $PublicDir `
        -AllowedWorkingPaths @() `
        -IgnoredPathspecs @('.') `
        -Label 'public'
} catch {
    $message = $_.Exception.Message
    Write-Host ("  [ERROR] 발행 저장소 사전 확인 실패: {0}" -f $message) -ForegroundColor Red
    Write-PublishAbortHint -FailureCode 'repository_not_ready' -Message $message
    exit 1
}

# 모든 대상 경로를 먼저 검사해 충돌 하나 때문에 앞선 선택본만 복사되는 부분 발행을 막는다.
$plannedDestinations = @{}
try {
foreach ($targetPlan in $targetPlans) {
    $processed = [string]$preflightCache[$targetPlan.Draft.FullName].Processed
    $null = Add-LLPublishDestinationPlanEntry `
        -Plan $plannedDestinations `
        -DestinationPath $targetPlan.DestPath `
        -ExpectedContent $processed `
        -Label '블로그 본문'
    $null = Get-LLPublishDestinationDisposition `
        -DestinationPath $targetPlan.DestPath `
        -ExpectedContent $processed `
        -AllowReplace:$targetPlan.IsUpdate `
        -Label '블로그 본문'

    foreach ($assetPath in (Get-DraftReferencedAssetPaths -Content $processed)) {
        $relative = $assetPath -replace '/', '\'
        $assetSource = Join-Path $DraftAssetRoot $relative
        if (-not (Test-Path -LiteralPath $assetSource -PathType Leaf)) {
            throw "초안 이미지 없음: /images/$assetPath"
        }
        $assetSourceFull = (Resolve-Path -LiteralPath $assetSource).Path
        $assetRootFull = (Resolve-Path -LiteralPath $DraftAssetRoot).Path.TrimEnd('\') + '\'
        if (-not $assetSourceFull.StartsWith($assetRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "초안 이미지 저장소 밖의 경로: $assetPath"
        }
        $assetDestination = Join-Path (Join-Path $BlogSourceRoot 'static') $relative
        $null = Add-LLPublishDestinationPlanEntry `
            -Plan $plannedDestinations `
            -DestinationPath $assetDestination `
            -ExpectedFilePath $assetSourceFull `
            -Label '블로그 이미지'
        $null = Get-LLPublishDestinationDisposition `
            -DestinationPath $assetDestination `
            -ExpectedFilePath $assetSourceFull `
            -Label '블로그 이미지'
    }
}
} catch {
    $message = $_.Exception.Message
    Write-Host ("  [ERROR] 발행 대상 파일 확인 실패: {0}" -f $message) -ForegroundColor Red
    Write-PublishAbortHint -FailureCode 'destination_preflight_failed' -Message $message
    exit 1
}

foreach ($targetPlan in $targetPlans) {
    $draft   = $targetPlan.Draft
    $rel     = $targetPlan.Rel
    $section = $targetPlan.Section
    $fname   = $targetPlan.FileName

    Write-Host ""
    Write-Host ("  >> {0}" -f $rel) -ForegroundColor Magenta

    # 대상 경로
    $destDir  = $targetPlan.DestDir
    $destPath = $targetPlan.DestPath

    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    try {
        $preflightData = $preflightCache[$draft.FullName]
        $raw = $preflightData.Raw
        $sourceRow = $preflightData.SourceRow
        if ($null -ne $sourceRow -and -not (Test-LLPublishableSource $sourceRow)) {
            Write-Host ("     [SKIP] publish policy gate: {0}/{1}" -f $sourceRow.source_id, $sourceRow.public_policy) -ForegroundColor Yellow
            $skippedPublishTargets.Add("$rel : publish policy gate")
            continue
        }
        # front matter 처리 및 publish 직전 검수
        $processed = $preflightData.Processed
        $quality = Test-DraftQualityGate -DraftName $fname -RawContent $processed -SourceRow $sourceRow
        if (-not $quality.Ok) {
            Write-Host ("     [SKIP] quality gate: {0}" -f $quality.Reason) -ForegroundColor Yellow
            $skippedPublishTargets.Add("$rel : $($quality.Reason)")
            continue
        }

        $assetCount = Copy-DraftReferencedAssets -Content $processed -CreatedArtifacts $createdPublishArtifacts
        if ($assetCount -gt 0) {
            Write-Host ("     이미지: {0}개 -> blog-source\\static\\images" -f $assetCount) -ForegroundColor Green
        }

        $disposition = Get-LLPublishDestinationDisposition `
            -DestinationPath $destPath `
            -ExpectedContent $processed `
            -AllowReplace:$targetPlan.IsUpdate `
            -Label '블로그 본문'
        if ($disposition -eq 'Create') {
            $stream = [System.IO.File]::Open($destPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
                try { $writer.Write($processed); $writer.Flush() } finally { $writer.Dispose() }
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
            $createdPublishArtifacts.Add([pscustomobject]@{
                full_path=$destPath; repo_path=("content/$section/$fname"); sha256=(Get-LLHash $destPath)
            })
            Write-Host ("     복사: {0}" -f $destPath.Replace($BlogSourceRoot, "blog-source")) -ForegroundColor Green
        } elseif ($disposition -eq 'Replace') {
            [System.IO.File]::WriteAllText($destPath, $processed, [System.Text.Encoding]::UTF8)
            Write-Host ("     갱신: {0}" -f $destPath.Replace($BlogSourceRoot, "blog-source")) -ForegroundColor Green
        } else {
            Write-Host ("     기존 승인 내용 확인: {0}" -f $destPath.Replace($BlogSourceRoot, "blog-source")) -ForegroundColor DarkGray
        }

        # source_id가 없는 daily 합본은 파일명/topic 매칭으로 registry 업데이트
        $sid = ""
        $raw | Select-String "source_id:\s*(\S+)" | ForEach-Object {
            $sid = $_.Matches[0].Groups[1].Value.Trim()
        }
        if (-not $sid -and $null -ne $sourceRow) {
            $sid = Get-LLProp $sourceRow "source_id"
        }

        # 06_published 표식과 registry published 기록은 배포 성공 후로 미룬다.
        # 여기서 바로 기록하면 빌드/푸시 실패 시 "발행됨"으로 오판되는 상태가 남는다.
        $pendingRecords.Add([pscustomobject]@{
            FileName  = $fname
            Processed = $processed
            SourceId  = $sid
        })
        $null = $sourcePathsToStage.Add("content/$section/$fname")
        foreach ($assetPath in (Get-DraftReferencedAssetPaths -Content $processed)) {
            $null = $sourcePathsToStage.Add("static/$assetPath")
        }

        $publishedCount++
        if ($targetPlan.IsUpdate) { $publishedUpdateCount++ } else { $publishedNewCount++ }

    } catch {
        Write-Host ("     [ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        $errors.Add($rel)
    }
}

if ($skippedPublishTargets.Count -gt 0) {
    $message = '선택한 승인본 중 일부가 발행 직전 정책 또는 품질 검사에서 제외되어 전체 작업을 중단했습니다: ' + ($skippedPublishTargets -join ' | ')
    $cleanup = Move-CreatedPublishArtifactsToTrash -AttemptId $publishAttemptId
    $cleanupPaths = @($cleanup.moved)
    if (@($cleanup.skipped).Count) { $message += ' · 정리 보류: ' + (@($cleanup.skipped) -join '; ') }
    Write-Host ("  [ERROR] {0}" -f $message) -ForegroundColor Red
    Write-PublishAttemptOutcome -Status 'needs_review' -FailureCode 'target_skipped' -Message $message -CleanupPaths $cleanupPaths
    Write-Host "  승인본은 보존했습니다. 검사 제외 원인을 확인하고 수정 후 다시 승인하세요." -ForegroundColor Yellow
    exit 1
}

if ($errors.Count -gt 0) {
    $message = '일부 승인본을 준비하지 못해 부분 발행을 막았습니다: ' + ($errors -join ', ')
    Write-Host ("  [ERROR] {0}" -f $message) -ForegroundColor Red
    Write-PublishAbortHint -FailureCode 'copy_failed' -Message $message
    exit 1
}

# ─────────────────────────────────────────────────────────
# Hugo 빌드 + 배포 (public submodule 먼저, blog-source 나중)
#   STRUCTURE.md 5장 순서 준수
# ─────────────────────────────────────────────────────────
if ($publishedCount -gt 0) {
    $deployOk = $false
    $PublicDir = Join-Path $BlogSourceRoot "public"

    # hugo CLI 확인
    $hugoCmd = Get-HugoCommandPath
    if (-not $hugoCmd) {
        Write-Host ""
        Write-Host "  [ERROR] hugo 명령을 찾을 수 없습니다. Hugo 설치/PATH 확인 필요." -ForegroundColor Red
        Write-Host "  글은 05_ready_to_publish → content 로 복사됐지만 라이브 배포는 건너뜁니다." -ForegroundColor Yellow
        Write-Host "  수동 배포: STRUCTURE.md 5장 참고" -ForegroundColor DarkGray
        Write-PublishAbortHint -FailureCode 'hugo_missing' -Message 'Hugo 실행 파일을 찾지 못했습니다.'
        exit 1
    } else {
        # ── 1. Hugo 빌드 → public/ 에 HTML 생성 ──
        Write-Host ""
        Write-Host "  [1/3] Hugo 빌드 중..." -ForegroundColor Cyan
        if ($NonInteractive) { Set-LLJobStage -Job publish -Index 2 -Total 4 -Key publish_build -Label '블로그 빌드' }
        Push-Location $BlogSourceRoot
        & $hugoCmd --cleanDestinationDir --logLevel warn
        $hugoExit = $LASTEXITCODE
        Pop-Location

        if ($hugoExit -ne 0) {
            Write-Host "  [ERROR] Hugo 빌드 실패 (exit $hugoExit). 배포 중단." -ForegroundColor Red
            Write-PublishAbortHint -FailureCode 'hugo_build_failed' -Message "Hugo 빌드가 종료 코드 $hugoExit 로 실패했습니다."
            exit $hugoExit
        } else {
            Write-Host "  Hugo 빌드 완료" -ForegroundColor Green

            # hugo --cleanDestinationDir 가 public 서브모듈의 .git 포인터 파일을 지운다.
            # 포인터가 없으면 public 안의 git 명령이 "unpopulated submodule"로 전부 실패하므로
            # 빌드 직후 반드시 복원한다. (2026-07-20 발행 불능 사건)
            $publicGitPointer = Join-Path $PublicDir ".git"
            if (-not (Test-Path -LiteralPath $publicGitPointer)) {
                Set-Content -LiteralPath $publicGitPointer -Value 'gitdir: ../.git/modules/public' -NoNewline -Encoding ascii
                Write-Host "  public\.git 포인터 복원됨 (cleanDestinationDir 삭제 대응)" -ForegroundColor DarkGray
            }

            # Hugo 실행 중 다른 입력/산출물이 섞였거나 기존 stage가 생기면 라이브 푸시 전에 차단한다.
            $allowedBlogStagePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($sourcePath in $sourcePathsToStage) { $null = $allowedBlogStagePaths.Add($sourcePath) }
            $null = $allowedBlogStagePaths.Add('public')
            try {
                $null = Assert-LLPublishRepositoryReady `
                    -RepoRoot $BlogSourceRoot `
                    -AllowedWorkingPaths @($allowedBlogStagePaths | ForEach-Object { $_ }) `
                    -IgnoredPathspecs $hugoInputPathspecs `
                    -Label 'blog-source'
                $publicState = Get-LLPublishGitState -RepoRoot $PublicDir -IgnoredPathspecs @('.')
                if (@($publicState.staged_paths).Count -gt 0) {
                    throw "public 저장소에 stage 변경이 있어 발행을 중단합니다: $(Format-LLPublishPaths $publicState.staged_paths)"
                }
                if (@($publicState.ignored_paths).Count -gt 0) {
                    throw "public 저장소에 무시된 빌드 파일이 있어 발행을 중단합니다: $(Format-LLPublishPaths $publicState.ignored_paths)"
                }
                $publicPaths = @($publicState.working_paths)
                $protectedPublicPaths = @($publicPaths | Where-Object { $_ -match '(^|/)\.git(?:ignore|modules|attributes)$|(^|/)\.github(?:/|$)' })
                if ($protectedPublicPaths.Count -gt 0) {
                    throw "Hugo 산출물에 Git 운영 파일이 포함되어 발행을 중단합니다: $(Format-LLPublishPaths $protectedPublicPaths)"
                }
            } catch {
                Write-Host ("  [ERROR] Git 발행 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-PublishAbortHint -FailureCode 'git_boundary_failed' -Message $_.Exception.Message
                exit 1
            }

            # ── 2. 라이브 사이트(public submodule) 먼저 푸시 ──
            Write-Host "  [2/3] 라이브 사이트(public) 푸시 중..." -ForegroundColor Cyan
            if ($NonInteractive) { Set-LLJobStage -Job publish -Index 3 -Total 4 -Key publish_live -Label '라이브 배포' }
            if ($publicPaths.Count -gt 0) {
                try {
                    $script:PublicStageAttempted = $true
                    $null = Add-LLPublishPathsToIndex -RepoRoot $PublicDir -Paths $publicPaths
                } catch {
                    Write-Host ("  [ERROR] public 허용 파일 stage 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    Write-PublishAbortHint -FailureCode 'public_stage_failed' -Message $_.Exception.Message
                    exit 1
                }
            }
            try {
                $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $PublicDir -AllowedPaths $publicPaths -Label 'public'
            } catch {
                Write-Host ("  [ERROR] public stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-PublishAbortHint -FailureCode 'public_stage_boundary_failed' -Message $_.Exception.Message
                exit 1
            }
            git -C $PublicDir diff --cached --quiet
            $pubDiffExit = $LASTEXITCODE
            if ($pubDiffExit -gt 1) {
                Write-Host "  [ERROR] public stage 상태 확인 실패" -ForegroundColor Red
                Write-PublishAbortHint -FailureCode 'public_stage_status_failed' -Message "git diff --cached 종료 코드 $pubDiffExit"
                exit $pubDiffExit
            }
            $pubHasNoStagedChanges = ($pubDiffExit -eq 0)
            if ($pubHasNoStagedChanges) {
                Write-Host "  public 커밋할 변경 없음" -ForegroundColor DarkGray
            } else {
                try {
                    $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $PublicDir -AllowedPaths $publicPaths -Label 'public'
                } catch {
                    Write-Host ("  [ERROR] public 커밋 직전 stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    Write-PublishAbortHint -FailureCode 'public_precommit_boundary_failed' -Message $_.Exception.Message
                    exit 1
                }
                $script:PublicCommitAttempted = $true
                git -C $PublicDir commit -m "LearningLog publish: $publishedCount posts ($TodayStr)" 2>&1 | Out-Host
                $pubCommit = $LASTEXITCODE
                if ($pubCommit -ne 0) {
                    Write-Host "  [ERROR] public 커밋 실패" -ForegroundColor Red
                    Write-PublishAbortHint -FailureCode 'public_commit_failed' -Message "public git commit 종료 코드 $pubCommit"
                    exit $pubCommit
                }
                $script:PublicCommitCompleted = $true
            }
            # 서브모듈은 detached HEAD 로 체크아웃되므로 로컬 main 이 안 움직인다.
            # HEAD:main 으로 밀어야 현재 커밋이 실제 라이브(origin/main)에 반영된다.
            $script:PublicPushAttempted = $true
            git -C $PublicDir push origin HEAD:main
            $pubPush = $LASTEXITCODE
            if ($pubPush -eq 0) { $script:LivePushCompleted = $true; Write-Host "  라이브 사이트 푸시 완료" -ForegroundColor Green }
            else {
                Write-Host "  [ERROR] public 푸시 실패" -ForegroundColor Red
                Write-PublishAbortHint -FailureCode 'public_push_uncertain' -Message "public push 종료 코드 $pubPush. 원격 반영 여부를 대조해야 합니다."
                exit $pubPush
            }

            # ── 3. 소스 백업 푸시 ──
            Write-Host "  [3/3] 소스(blog-source) 백업 푸시 중..." -ForegroundColor Cyan
            if ($NonInteractive) { Set-LLJobStage -Job publish -Index 4 -Total 4 -Key publish_record -Label '소스 백업·발행 기록' }
            $sourceStagePaths = @($sourcePathsToStage | ForEach-Object { $_ }) + @('public') | Select-Object -Unique
            try {
                $null = Assert-LLPublishRepositoryReady `
                    -RepoRoot $BlogSourceRoot `
                    -AllowedWorkingPaths $sourceStagePaths `
                    -IgnoredPathspecs $hugoInputPathspecs `
                    -Label 'blog-source'
                $null = Add-LLPublishPathsToIndex -RepoRoot $BlogSourceRoot -Paths $sourceStagePaths
                $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $BlogSourceRoot -AllowedPaths $sourceStagePaths -Label 'blog-source'
            } catch {
                Write-Host ("  [ERROR] blog-source stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-PublishAbortHint -FailureCode 'source_stage_boundary_failed' -Message $_.Exception.Message
                exit 1
            }
            git -C $BlogSourceRoot diff --cached --quiet
            $sourceDiffExit = $LASTEXITCODE
            if ($sourceDiffExit -gt 1) {
                Write-Host "  [ERROR] blog-source stage 상태 확인 실패" -ForegroundColor Red
                Write-PublishAbortHint -FailureCode 'source_stage_status_failed' -Message "blog-source git diff --cached 종료 코드 $sourceDiffExit"
                exit $sourceDiffExit
            }
            $sourceHasNoStagedChanges = ($sourceDiffExit -eq 0)
            if ($sourceHasNoStagedChanges) {
                Write-Host "  blog-source 커밋할 변경 없음" -ForegroundColor DarkGray
            } else {
                try {
                    $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $BlogSourceRoot -AllowedPaths $sourceStagePaths -Label 'blog-source'
                } catch {
                    Write-Host ("  [ERROR] blog-source 커밋 직전 stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    Write-PublishAbortHint -FailureCode 'source_precommit_boundary_failed' -Message $_.Exception.Message
                    exit 1
                }
                git -C $BlogSourceRoot commit -m "LearningLog source: $publishedCount posts ($TodayStr)" 2>&1 | Out-Host
                $sourceCommit = $LASTEXITCODE
                if ($sourceCommit -ne 0) {
                    Write-Host "  [ERROR] blog-source 커밋 실패" -ForegroundColor Red
                    Write-PublishAbortHint -FailureCode 'source_commit_failed_after_live_push' -Message "라이브 공개는 성공했지만 blog-source 커밋이 종료 코드 $sourceCommit 로 실패했습니다."
                    exit $sourceCommit
                }
            }
            git -C $BlogSourceRoot push
            $sourcePush = $LASTEXITCODE
            if ($sourcePush -ne 0) {
                Write-Host "  [ERROR] blog-source 푸시 실패" -ForegroundColor Red
                Write-PublishAbortHint -FailureCode 'source_push_failed_after_live_push' -Message "라이브 공개는 성공했지만 blog-source push가 종료 코드 $sourcePush 로 실패했습니다."
                exit $sourcePush
            }
            Write-Host "  소스 백업 완료" -ForegroundColor Green
            $deployOk = $true

            # 두 push가 성공한 뒤 published 파일, registry, 발행 원장을 각각 기록한다.
            # 어느 한 로컬 기록이 실패해도 나머지 성공 표식이 중복 재발행을 막는다.
            $publicationRecordErrors = [System.Collections.Generic.List[string]]::new()
            if (-not (Test-Path -LiteralPath $PublishedDir)) {
                try { New-Item -ItemType Directory -Path $PublishedDir -Force | Out-Null }
                catch { $publicationRecordErrors.Add("06_published 폴더 생성 실패: $($_.Exception.Message)") }
            }
            foreach ($rec in $pendingRecords) {
                try { [System.IO.File]::WriteAllText((Join-Path $PublishedDir $rec.FileName), $rec.Processed, [System.Text.Encoding]::UTF8) }
                catch { $publicationRecordErrors.Add("06_published 기록 실패($($rec.FileName)): $($_.Exception.Message)") }
                if ($rec.SourceId) {
                    try { _UpdateRegistry $rec.SourceId }
                    catch { $publicationRecordErrors.Add("registry 발행 상태 기록 실패($($rec.SourceId)): $($_.Exception.Message)") }
                }
            }
            try { Write-PublishAttemptOutcome -Status 'published' -PublishedDate $TodayStr -Message '라이브 사이트와 blog-source 백업 push가 모두 성공했습니다.' }
            catch { $publicationRecordErrors.Add("publish_ledger 기록 실패: $($_.Exception.Message)") }
            if ($publicationRecordErrors.Count -eq 0) {
                Write-Host ("  발행 기록 완료: 06_published {0}건 + registry + publish_ledger" -f $pendingRecords.Count) -ForegroundColor Green
            } else {
                $publicationRecordMessage = '라이브와 blog-source push는 성공했으나 로컬 발행 기록을 모두 완료하지 못했습니다. 중복 방지를 위해 남은 기록을 확인하세요: ' + ($publicationRecordErrors -join ' | ')
                $errors.Add($publicationRecordMessage)
                Write-Host ("  [WARN] {0}" -f $publicationRecordMessage) -ForegroundColor Yellow
            }

            Write-Host ""
            Write-Host "  배포 완료! https://<your-id>.github.io/ 확인" -ForegroundColor Green
        }
    }
}

# ─────────────────────────────────────────────────────────
# 결과
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($NonInteractive -and ($publishedCount -ne $uiSelection.Count -or $errors.Count -gt 0)) { exit 1 }
if ($errors.Count -gt 0 -and $publishedCount -gt 0) {
    Write-Host ("  발행은 완료됐지만 로컬 기록 확인 필요: {0} 개" -f $publishedCount) -ForegroundColor Yellow
} else {
    Write-Host ("  발행 완료: {0} 개" -f $publishedCount) -ForegroundColor Green
}
Write-Host ("  신규 추가: {0} 개" -f $publishedNewCount) -ForegroundColor Green
Write-Host ("  기존 글 갱신: {0} 개" -f $publishedUpdateCount) -ForegroundColor $(if ($publishedUpdateCount -gt 0) { "Yellow" } else { "DarkGray" })
if ($errors.Count -gt 0) {
    Write-Host ("  오류:      {0} 개" -f $errors.Count) -ForegroundColor Red
}
if ($publishedCount -gt 0) {
    Write-Host "  blog-source 처리 완료" -ForegroundColor DarkGray
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
