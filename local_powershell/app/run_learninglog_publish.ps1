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
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.Publish.psm1") -Force -DisableNameChecking

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
$excludedPublished = 0
$excludedBacklog = 0
$excludedUnapproved = 0

if ($DraftPath.Count -gt 0) {
    $targets = @($DraftPath | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue })
    if ($SectionFilter) { $targets = @($targets | Where-Object { Test-LLPublishSection -Draft $_ -ReadyRoot $DraftsDir -SectionFilter $SectionFilter }) }
} elseif ($All) {
    $allDrafts = @(Get-ChildItem -Path $DraftsDir -Recurse -Filter "*.md" -File | Sort-Object FullName)
    if ($SectionFilter) { $allDrafts = @($allDrafts | Where-Object { Test-LLPublishSection -Draft $_ -ReadyRoot $DraftsDir -SectionFilter $SectionFilter }) }
    $beforeStatusFilter = $allDrafts.Count
    $allDrafts = @($allDrafts | Where-Object { Test-LLPublishStatusAllowed -Draft $_ -Rows $selectionRows -ApprovalRows $approvalRows -ReadyRoot $DraftsDir -IncludePublished:$IncludePublished })
    $excludedUnapproved = $beforeStatusFilter - $allDrafts.Count
    if (-not $IncludePublished) {
        $visibleDrafts = @($allDrafts | Where-Object { -not (New-LLPublishPlan -Draft $_ -ReadyRoot $DraftsDir -BlogRoot $BlogSourceRoot -PublishedDir $PublishedDir).IsUpdate })
        $excludedPublished = $allDrafts.Count - $visibleDrafts.Count
        $allDrafts = $visibleDrafts
    }
    if (-not $IncludeBacklog) {
        $visibleDrafts = @($allDrafts | Where-Object { Test-LLTodayDraft -Draft $_ -TodayStr $TodayStr -IncludeBacklog:$IncludeBacklog })
        $excludedBacklog = $allDrafts.Count - $visibleDrafts.Count
        $allDrafts = $visibleDrafts
    }
    $targets = $allDrafts
} else {
    # 대화형 선택
    $allDrafts = @(Get-ChildItem -Path $DraftsDir -Recurse -Filter "*.md" -File | Sort-Object FullName)
    if ($SectionFilter) { $allDrafts = @($allDrafts | Where-Object { Test-LLPublishSection -Draft $_ -ReadyRoot $DraftsDir -SectionFilter $SectionFilter }) }
    $beforeStatusFilter = $allDrafts.Count
    $allDrafts = @($allDrafts | Where-Object { Test-LLPublishStatusAllowed -Draft $_ -Rows $selectionRows -ApprovalRows $approvalRows -ReadyRoot $DraftsDir -IncludePublished:$IncludePublished })
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
        $visibleDrafts = @($allDrafts | Where-Object { -not (New-LLPublishPlan -Draft $_ -ReadyRoot $DraftsDir -BlogRoot $BlogSourceRoot -PublishedDir $PublishedDir).IsUpdate })
        $excludedPublished = $allDrafts.Count - $visibleDrafts.Count
        $allDrafts = $visibleDrafts
    }
    if (-not $IncludeBacklog) {
        $visibleDrafts = @($allDrafts | Where-Object { Test-LLTodayDraft -Draft $_ -TodayStr $TodayStr -IncludeBacklog:$IncludeBacklog })
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
    $invalidTargets = @($targets | Where-Object { -not (Test-LLPublishStatusAllowed -Draft $_ -Rows $selectionRows -ApprovalRows $approvalRows -ReadyRoot $DraftsDir -IncludePublished:$IncludePublished) })
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
    $plan = New-LLPublishPlan -Draft $draft -ReadyRoot $DraftsDir -BlogRoot $BlogSourceRoot -PublishedDir $PublishedDir
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
# ─────────────────────────────────────────────────────────
# 헬퍼: registry status → published
# ─────────────────────────────────────────────────────────
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
# 발행 한 번의 공유 상태(시도 ID·플래그·생성 사본·사전검사 캐시). 실패 처리 함수가 이 객체를 받는다.
$ctx = New-LLPublishContext -ResolveRow { param($Draft) Resolve-LLPublishRegistryRow -Draft $Draft -Rows $selectionRows }
$ctx.TrashRunRoot = Get-LLPath ('.trash\publish_attempt_' + $ctx.AttemptId + '\blog-source')
$ctx.TargetPlans = $targetPlans
$createdPublishArtifacts = $ctx.CreatedArtifacts

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
$preflightCache = $ctx.PreflightCache
$preflightFailures = Invoke-LLPublishPreflightStage -Ctx $ctx -ReadyRoot $DraftsDir -DraftAssetRoot $DraftAssetRoot -Rows $selectionRows -Selection $(if ($SelectionFile) { $selection } else { $null }) -IncludePublished:$IncludePublished
if ($preflightFailures.Count -gt 0) {
    $message = "발행 보안 사전검사 실패. 파일을 복사하거나 빌드·푸시하지 않았습니다: " + ($preflightFailures -join ' | ')
    Write-LLPublishAttemptOutcome -Ctx $ctx -Status 'needs_review' -FailureCode 'preflight_failed' -Message $message
    throw $message
}

# 복사 전에 저장소 상태와 모든 대상 경로를 먼저 검사한다.
$hugoInputPathspecs = Get-LLHugoInputPathspecs
$readiness = @(Assert-LLPublishTargetsReady -Ctx $ctx -BlogSourceRoot $BlogSourceRoot -DraftAssetRoot $DraftAssetRoot)[-1]
if ($readiness.ExitCode -ne 0) { exit $readiness.ExitCode }

$copyResult = @(Invoke-LLPublishCopyStage -Ctx $ctx -BlogSourceRoot $BlogSourceRoot -DraftAssetRoot $DraftAssetRoot -SkippedTargets $skippedPublishTargets -Errors $errors -PendingRecords $pendingRecords -SourcePathsToStage $sourcePathsToStage)[-1]
$publishedCount = $copyResult.Published
$publishedNewCount = $copyResult.New
$publishedUpdateCount = $copyResult.Updated

if ($skippedPublishTargets.Count -gt 0) {
    $message = '선택한 승인본 중 일부가 발행 직전 정책 또는 품질 검사에서 제외되어 전체 작업을 중단했습니다: ' + ($skippedPublishTargets -join ' | ')
    $cleanup = Move-LLPublishArtifactsToTrash -Ctx $ctx
    $cleanupPaths = @($cleanup.moved)
    if (@($cleanup.skipped).Count) { $message += ' · 정리 보류: ' + (@($cleanup.skipped) -join '; ') }
    Write-Host ("  [ERROR] {0}" -f $message) -ForegroundColor Red
    Write-LLPublishAttemptOutcome -Ctx $ctx -Status 'needs_review' -FailureCode 'target_skipped' -Message $message -CleanupPaths $cleanupPaths
    Write-Host "  승인본은 보존했습니다. 검사 제외 원인을 확인하고 수정 후 다시 승인하세요." -ForegroundColor Yellow
    exit 1
}

if ($errors.Count -gt 0) {
    $message = '일부 승인본을 준비하지 못해 부분 발행을 막았습니다: ' + ($errors -join ', ')
    Write-Host ("  [ERROR] {0}" -f $message) -ForegroundColor Red
    Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'copy_failed' -Message $message
    exit 1
}

# ─────────────────────────────────────────────────────────
# Hugo 빌드 + 배포 (public submodule 먼저, blog-source 나중)
#   STRUCTURE.md 5장 순서 준수
# ─────────────────────────────────────────────────────────
if ($publishedCount -gt 0) {
    $deployResult = @(Invoke-LLPublishDeploy -Ctx $ctx -BlogSourceRoot $BlogSourceRoot -PublishedDir $PublishedDir -SourcePathsToStage $sourcePathsToStage -HugoInputPathspecs $hugoInputPathspecs -PendingRecords $pendingRecords -Errors $errors -PublishedCount $publishedCount -TodayStr $TodayStr -SiteUrlHint 'https://<your-id>.github.io/' -NonInteractive:$NonInteractive)[-1]
    if ($deployResult.ExitCode -ne 0) { exit $deployResult.ExitCode }
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
