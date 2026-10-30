#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Unpublish — 잘못 발행된 글을 라이브/모든 단계에서 내림 (복구 가능)

.DESCRIPTION
    하는 것:
      - 대상 파일명(들)을 04/05/06 + blog-source\content 전 섹션에서 탐색
      - 발견된 사본을 .trash\<timestamp>\ 로 백업 후 제거 (하드 삭제 아님)
      - source_registry.csv 의 매칭 topic status → needs_review
      - 09_reports\unpublish_log.csv 기록
      - (-Deploy 지정 시) hugo 재빌드 + public/blog-source git push 로 라이브 반영

    하지 않는 것:
      - -Deploy 없이는 git push 안 함 (로컬 제거만)

.PARAMETER ListFile
    한 줄에 파일명 하나씩 적힌 텍스트 파일 경로
.PARAMETER Name
    개별 파일명 (쉼표 없이, 반복 지정 가능). ListFile 과 병합됨
.PARAMETER Deploy
    hugo 재빌드 + git push 까지 수행 (라이브 반영)
.PARAMETER WhatIfList
    제거하지 않고 영향 받는 사본 목록만 표시
#>

param(
    [string]$ListFile = "",
    [string[]]$Name = @(),
    [switch]$Deploy,
    [switch]$Yes,
    [switch]$WhatIfList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.PublishGitGuard.psm1") -Force -DisableNameChecking

$RunDT   = Get-Date
$RunTime = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$Stamp   = $RunDT.ToString("yyyyMMdd_HHmmss")
$null    = Ensure-LLRegistrySchema

$BlogSourceRoot = Get-LLBlogRoot
$TrashRoot      = Get-LLPath ".trash\unpublish_$Stamp"
$LogPath        = Get-LLPath "09_reports\unpublish_log.csv"
$HugoInputPathspecs = @('content', 'static', 'assets', 'layouts', 'data', 'i18n', 'archetypes', 'config', 'themes', 'hugo.toml', 'hugo.yaml', 'hugo.json')

function ConvertTo-UnpublishFileName {
    param([string]$Value)
    $t = $Value.Trim()
    if ($t -eq "") { return "" }

    $t = ($t -split "[?#]", 2)[0].Trim()
    [System.Uri]$uri = $null
    if ([System.Uri]::TryCreate($t, [System.UriKind]::Absolute, [ref]$uri) -and $uri.AbsolutePath) {
        $t = $uri.AbsolutePath
    }

    $t = $t.Replace("\", "/").Trim("/")
    if ($t -eq "") { return "" }

    $parts = @($t -split "/" | Where-Object { $_ -ne "" })
    if ($parts.Count -gt 0) { $t = $parts[$parts.Count - 1] }
    if ($t -eq "") { return "" }
    if (-not $t.EndsWith(".md", [System.StringComparison]::OrdinalIgnoreCase)) {
        $t = "$t.md"
    }
    return $t
}

function Get-UnpublishTitle {
    param([string]$Path)
    try {
        $head = Get-Content -LiteralPath $Path -TotalCount 20 -ErrorAction Stop
        foreach ($line in $head) {
            if ($line -match '^\s*title:\s*"?(.+?)"?\s*$') { return $Matches[1].Trim() }
        }
    } catch {}
    return ""
}

# ── 대상 파일명 수집 ──
$names = [System.Collections.Generic.List[string]]::new()
if ($ListFile -ne "" -and (Test-Path -LiteralPath $ListFile)) {
    foreach ($l in (Get-Content -LiteralPath $ListFile)) {
        $t = ConvertTo-UnpublishFileName $l
        if ($t -ne "") { $names.Add($t) }
    }
}
foreach ($n in $Name) {
    $t = ConvertTo-UnpublishFileName $n
    if ($t -ne "") { $names.Add($t) }
}
$names = [System.Collections.Generic.List[string]]::new([string[]]@($names | Select-Object -Unique))

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Unpublish" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($names.Count -eq 0) {
    $blogContentRoot = Join-Path $BlogSourceRoot "content"
    $blogPosts = @()
    if (Test-Path -LiteralPath $blogContentRoot) {
        $blogPosts = @(Get-ChildItem -LiteralPath $blogContentRoot -Recurse -Filter "*.md" -File -ErrorAction SilentlyContinue | Sort-Object FullName)
    }

    if ($blogPosts.Count -gt 0) {
        Write-Host ""
        Write-Host "  --- 블로그 원본 글 목록 ---" -ForegroundColor Magenta
        for ($i = 0; $i -lt $blogPosts.Count; $i++) {
            $rel = $blogPosts[$i].FullName.Replace($blogContentRoot + "\", "").Replace("\", "/")
            $title = Get-UnpublishTitle $blogPosts[$i].FullName
            Write-Host ("  [{0,2}] {1}" -f ($i + 1), $rel) -ForegroundColor White
            if ($title) { Write-Host ("       title: {0}" -f $title) -ForegroundColor DarkGray }
        }
        Write-Host ""
        Write-Host "  번호, URL, slug, 파일명을 입력할 수 있습니다. 여러 개는 쉼표로 구분하세요." -ForegroundColor DarkGray
        Write-Host "  예: 1 또는 https://<your-id>.github.io/learning/<post-slug>/" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "  블로그 원본 목록을 찾지 못했습니다. URL, slug, 파일명을 직접 입력하세요." -ForegroundColor Yellow
    }

    $sel = (Read-Host "  내릴 글 입력 (Q=취소)").Trim()
    if ($sel -eq "" -or $sel.ToUpperInvariant() -eq "Q") {
        Write-Host "  취소됨." -ForegroundColor DarkGray
        exit 0
    }

    foreach ($token in ($sel -split ",")) {
        $t = $token.Trim()
        if ($t -eq "") { continue }
        $idx = 0
        if ([int]::TryParse($t, [ref]$idx) -and $idx -ge 1 -and $idx -le $blogPosts.Count) {
            $names.Add($blogPosts[$idx - 1].Name)
        } else {
            $fileName = ConvertTo-UnpublishFileName $t
            if ($fileName -ne "") { $names.Add($fileName) }
        }
    }
    $names = [System.Collections.Generic.List[string]]::new([string[]]@($names | Select-Object -Unique))

    if ($names.Count -gt 0) {
        $deployChoice = (Read-Host "  라이브 사이트까지 반영할까요? (Y/N, 기본 N)").Trim().ToUpperInvariant()
        if ($deployChoice -eq "Y") { $Deploy = $true }
    }
}

Write-Host ("  대상 파일명: {0}개" -f $names.Count) -ForegroundColor Yellow

if ($names.Count -eq 0) {
    Write-Host "  대상이 없습니다. -ListFile, -Name, URL, slug 중 하나로 지정하세요." -ForegroundColor Yellow
    exit 0
}

# ── 탐색 경로 루트 ──
$searchRoots = @(
    (Get-LLPath "04_blog_drafts"),
    (Get-LLPath "05_ready_to_publish"),
    (Get-LLPath "06_published"),
    (Join-Path $BlogSourceRoot "content")
)

# ── 사본 매핑 ──
$hits = [System.Collections.Generic.List[object]]::new()
foreach ($n in $names) {
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Filter $n -File -ErrorAction SilentlyContinue)) {
            $hits.Add([pscustomobject]@{ Name = $n; Path = $f.FullName; Root = $root })
        }
    }
}

Write-Host ("  발견된 사본: {0}개" -f $hits.Count) -ForegroundColor Yellow
Write-Host ""

if ($WhatIfList) {
    foreach ($h in $hits) { Write-Host ("  {0}" -f (Get-LLRelativePath $h.Path)) -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "  [WhatIfList] 제거하지 않고 목록만 표시했습니다." -ForegroundColor Yellow
    exit 0
}

if ($hits.Count -eq 0) {
    Write-Host "  제거할 사본이 없습니다. 파일명/slug 를 확인하세요." -ForegroundColor Yellow
    exit 0
}

Write-Host "  --- 제거 예정 사본 ---" -ForegroundColor Yellow
foreach ($h in $hits) {
    Write-Host ("  {0}" -f (Get-LLRelativePath $h.Path)) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host ("  대상은 삭제가 아니라 백업 후 .trash 로 이동됩니다: {0}" -f $TrashRoot) -ForegroundColor DarkGray
$confirmRemove = if ($Yes) { "Y" } else { (Read-Host "  위 사본을 내릴까요? (Y/N)").Trim().ToUpperInvariant() }
if ($confirmRemove -ne "Y") {
    Write-Host "  취소됨. 아무 파일도 이동하지 않았습니다." -ForegroundColor DarkGray
    exit 0
}

# -Deploy は Blog と public の両方がクリーンな場合だけ開始する。
# これを最初の Move-Item より前に行い、ローカル削除後に既存変更が原因で
# deploy を止める状態を避ける。Git 작업은 아래에서 선택 경로만 stage한다.
$sourcePathsToStage = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$blogRootFull = [System.IO.Path]::GetFullPath($BlogSourceRoot).TrimEnd('\', '/')
$blogContentRootFull = [System.IO.Path]::GetFullPath((Join-Path $BlogSourceRoot 'content')).TrimEnd('\', '/')
$blogContentPrefix = $blogContentRootFull + [System.IO.Path]::DirectorySeparatorChar
foreach ($hit in $hits) {
    $hitFull = [System.IO.Path]::GetFullPath($hit.Path)
    if (-not $hitFull.StartsWith($blogContentPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $relative = $hitFull.Substring($blogRootFull.Length + 1).Replace('\', '/')
    if (-not $relative.StartsWith('content/', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unpublish 대상 경로가 Blog content 밖입니다: $($hit.Path)"
    }
    $null = $sourcePathsToStage.Add($relative)
}

if ($Deploy) {
    try {
        $null = Assert-LLPublishRepositoryReady `
            -RepoRoot $BlogSourceRoot `
            -IgnoredPathspecs $HugoInputPathspecs `
            -Label 'blog-source'
        $null = Assert-LLPublishRepositoryReady `
            -RepoRoot (Join-Path $BlogSourceRoot 'public') `
            -IgnoredPathspecs @('.') `
            -Label 'public'
    } catch {
        Write-Host ("  [ERROR] 배포 저장소가 깨끗하지 않아 파일 이동 전에 중단합니다: {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

# ── 백업 + 제거 ──
$rows = @(Get-LLRegistryRows)
$logEntries = [System.Collections.Generic.List[object]]::new()
$removed = 0
foreach ($h in $hits) {
    $rel = $h.Path.Replace((Split-Path -Parent $BlogSourceRoot).TrimEnd('\') + '\', "").Replace("\", "/")
    $dest = Join-Path $TrashRoot $rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Move-Item -LiteralPath $h.Path -Destination $dest -Force
    Write-Host ("  [제거] {0}" -f $rel) -ForegroundColor Yellow
    $logEntries.Add([pscustomobject]@{
        unpublished_at = $RunTime; file_name = $h.Name; from = $rel; trash = $dest; by = $env:USERNAME
    })
    $removed++
}

# ── registry status → needs_review (topic = 파일명 stem) ──
$updated = 0
foreach ($n in $names) {
    $topic = [System.IO.Path]::GetFileNameWithoutExtension($n)
    foreach ($r in ($rows | Where-Object { (Get-LLProp $_ "topic") -eq $topic })) {
        $sid = Get-LLProp $r "source_id"
        if ($sid) { $null = Set-LLRegistryStatus -SourceId $sid -Status "needs_review"; $updated++ }
    }
}
Write-Host ("  registry needs_review 갱신: {0}건" -f $updated) -ForegroundColor DarkGray

# ── 로그 ──
if ($logEntries.Count -gt 0) {
    $parent = Split-Path -Parent $LogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $existing = @(); if (Test-Path -LiteralPath $LogPath) { $existing = @(Import-Csv -LiteralPath $LogPath -Encoding utf8) }
    (@($existing) + @($logEntries)) | Export-Csv -LiteralPath $LogPath -Encoding utf8 -NoTypeInformation
}

Write-Host ""
Write-Host ("  제거: {0}개 사본 -> {1}" -f $removed, $TrashRoot) -ForegroundColor Green

# ── 배포 (옵션) ──
if (-not $Deploy) {
    Write-Host ""
    Write-Host "  로컬 제거만 완료했습니다. 라이브 반영하려면 -Deploy 로 다시 실행하거나" -ForegroundColor Cyan
    Write-Host "  hugo 빌드 + git push 를 수동 수행하세요." -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    exit 0
}

# hugo 빌드
$hugoCmd = (Get-Command hugo -ErrorAction SilentlyContinue).Source
if (-not $hugoCmd) {
    $found = Get-ChildItem "C:\Users\Lenovo\AppData\Local\Microsoft\WinGet\Packages" -Recurse -Filter "hugo.exe" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*Hugo.Hugo.Extended*" } | Select-Object -First 1
    if ($found) { $hugoCmd = $found.FullName }
}
if (-not $hugoCmd) { Write-Host "  [ERROR] hugo 없음. 배포 중단." -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "  [1/3] Hugo 빌드..." -ForegroundColor Cyan
Push-Location $BlogSourceRoot
& $hugoCmd --cleanDestinationDir --logLevel warn
$he = $LASTEXITCODE
Pop-Location
if ($he -ne 0) { Write-Host "  [ERROR] hugo 빌드 실패 (exit $he)" -ForegroundColor Red; exit $he }
Write-Host "  Hugo 빌드 완료" -ForegroundColor Green

# hugo --cleanDestinationDir 가 public 서브모듈의 .git 포인터 파일을 지운다.
# 포인터가 없으면 public 안의 git 명령이 "unpopulated submodule"로 전부 실패하므로 복원한다.
$publicGitPointer = Join-Path (Join-Path $BlogSourceRoot "public") ".git"
if (-not (Test-Path -LiteralPath $publicGitPointer)) {
    Set-Content -LiteralPath $publicGitPointer -Value 'gitdir: ../.git/modules/public' -NoNewline -Encoding ascii
    Write-Host "  public\.git 포인터 복원됨 (cleanDestinationDir 삭제 대응)" -ForegroundColor DarkGray
}

$TodayStr = $RunDT.ToString("yyyy-MM-dd")
$PublicDir = Join-Path $BlogSourceRoot 'public'
Write-Host "  [2/3] 라이브(public) 푸시..." -ForegroundColor Cyan
$publicState = Get-LLPublishGitState -RepoRoot $PublicDir -IgnoredPathspecs @('.')
if (@($publicState.staged_paths).Count -gt 0) {
    Write-Host ("  [ERROR] public 에 기존 stage 변경이 생겨 푸시를 중단합니다: {0}" -f (Format-LLPublishPaths $publicState.staged_paths)) -ForegroundColor Red
    exit 1
}
if (@($publicState.ignored_paths).Count -gt 0) {
    Write-Host ("  [ERROR] public 에 무시된 생성물이 있어 푸시를 중단합니다: {0}" -f (Format-LLPublishPaths $publicState.ignored_paths)) -ForegroundColor Red
    exit 1
}
$publicPaths = @($publicState.working_paths)
if ($publicPaths.Count -gt 0) {
    try {
        $null = Add-LLPublishPathsToIndex -RepoRoot $PublicDir -Paths $publicPaths
    } catch {
        Write-Host ("  [ERROR] public 허용 경로 stage 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
try {
    $null = Assert-LLPublishRepositoryPathsAllowed -RepoRoot $PublicDir -AllowedPaths $publicPaths -Label 'public'
} catch {
    Write-Host ("  [ERROR] public stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
git -C $PublicDir diff --cached --quiet
$publicDiffExit = $LASTEXITCODE
if ($publicDiffExit -gt 1) { Write-Host "  [ERROR] public stage 상태 확인 실패" -ForegroundColor Red; exit $publicDiffExit }
if ($publicDiffExit -eq 1) {
    git -C $PublicDir commit -m "LearningLog unpublish: remove $($names.Count) broken posts ($TodayStr)" 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "  [ERROR] public 커밋 실패" -ForegroundColor Red; exit $LASTEXITCODE }
}
git -C $PublicDir push origin main
$pp = $LASTEXITCODE
if ($pp -ne 0) { Write-Host "  [ERROR] public 푸시 실패" -ForegroundColor Red; exit $pp }
Write-Host "  라이브 반영 완료" -ForegroundColor Green

Write-Host "  [3/3] 소스(blog-source) 푸시..." -ForegroundColor Cyan
$blogAllowedPaths = @($sourcePathsToStage | ForEach-Object { $_ }) + @('public') | Select-Object -Unique
try {
    $sourceState = Assert-LLPublishRepositoryPathsAllowed `
        -RepoRoot $BlogSourceRoot `
        -AllowedPaths $blogAllowedPaths `
        -IgnoredPathspecs $HugoInputPathspecs `
        -Label 'blog-source'
} catch {
    Write-Host ("  [ERROR] blog-source 변경 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
$sourcePaths = @($sourceState.working_paths)
if ($sourcePaths.Count -gt 0) {
    try {
        $null = Add-LLPublishPathsToIndex -RepoRoot $BlogSourceRoot -Paths $sourcePaths
    } catch {
        Write-Host ("  [ERROR] blog-source 허용 경로 stage 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
try {
    $null = Assert-LLPublishRepositoryPathsAllowed `
        -RepoRoot $BlogSourceRoot `
        -AllowedPaths $blogAllowedPaths `
        -IgnoredPathspecs $HugoInputPathspecs `
        -Label 'blog-source'
} catch {
    Write-Host ("  [ERROR] blog-source stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
git -C $BlogSourceRoot diff --cached --quiet
$sourceDiffExit = $LASTEXITCODE
if ($sourceDiffExit -gt 1) { Write-Host "  [ERROR] blog-source stage 상태 확인 실패" -ForegroundColor Red; exit $sourceDiffExit }
if ($sourceDiffExit -eq 1) {
    git -C $BlogSourceRoot commit -m "LearningLog unpublish: remove $($names.Count) broken posts ($TodayStr)" 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "  [ERROR] blog-source 커밋 실패" -ForegroundColor Red; exit $LASTEXITCODE }
}
git -C $BlogSourceRoot push
$sp = $LASTEXITCODE
if ($sp -ne 0) { Write-Host "  [ERROR] blog-source 푸시 실패" -ForegroundColor Red; exit $sp }
Write-Host "  소스 백업 완료" -ForegroundColor Green

Write-Host ""
Write-Host "  배포 완료! https://<your-id>.github.io/ 에서 제거 확인" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
exit 0
