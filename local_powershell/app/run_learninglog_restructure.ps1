#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Restructure - repeated article sections into one article outline.

.DESCRIPTION
    반복된 "왜 썼나 / 배운 것 / 정리된 이해" 구조를 한 문서의 단일 구조로 모은다.
    기본은 dry-run이며, -Apply 를 지정해야 파일을 수정한다.
#>

param(
    [string]$TargetPath = "",
    [ValidateSet("drafts", "published", "blog", "all")]
    [string]$Scope = "drafts",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$Root = Get-LLRoot
$RunDT = Get-Date
$RunTime = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$TimeStamp = $RunDT.ToString("yyyyMMdd_HHmmss")
$BackupDir = Get-LLPath ("07_archive\backups\restructure_{0}" -f $TimeStamp)
$BlogSourceRoot = Join-Path (Get-LLBlogRoot) "content"

function Get-TargetFiles {
    param(
        [string]$TargetPath,
        [string]$Scope
    )

    if ($TargetPath) {
        $item = Get-Item -LiteralPath $TargetPath -ErrorAction Stop
        return @($item)
    }

    $roots = [System.Collections.Generic.List[string]]::new()
    if ($Scope -in @("drafts", "all")) { $roots.Add((Get-LLPath "04_blog_drafts")) }
    if ($Scope -in @("published", "all")) { $roots.Add((Get-LLPath "06_published")) }
    if ($Scope -in @("blog", "all")) {
        foreach ($section in @("learning", "goals", "practice", "projects")) {
            $roots.Add((Join-Path $BlogSourceRoot $section))
        }
    }

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($rootPath in $roots) {
        if (Test-Path -LiteralPath $rootPath) {
            foreach ($file in (Get-ChildItem -LiteralPath $rootPath -Recurse -Filter "*.md" -File | Sort-Object FullName)) {
                $files.Add($file)
            }
        }
    }
    return @($files)
}

function Copy-RestructureBackup {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    $safeName = $Path.Replace(":", "").Replace("\", "__").Replace("/", "__")
    $dest = Join-Path $BackupDir $safeName
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Restructure" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  mode: {0}" -f $(if ($Apply) { "APPLY" } else { "DRY-RUN" })) -ForegroundColor $(if ($Apply) { "Yellow" } else { "DarkGray" })

$targets = @(Get-TargetFiles -TargetPath $TargetPath -Scope $Scope)
Write-Host ("  targets: {0}" -f $targets.Count) -ForegroundColor Yellow

$changed = 0
$skipped = 0
$failed = 0

foreach ($file in $targets) {
    try {
        $before = Read-LLText $file.FullName
        $beforeIssues = @(Get-LLDraftQualityIssues -Content $before)
        $structureIssues = @($beforeIssues | Where-Object { $_ -match "repeated article structure|combined outline|odd code fence|empty output|extra front matter|bold metadata|internal metadata" })
        if ($structureIssues.Count -eq 0) {
            $skipped++
            continue
        }

        $after = ConvertTo-LLSingleArticleStructure -Content $before
        $afterIssues = @(Get-LLDraftQualityIssues -Content $after)
        $changedText = ($after -ne $before)

        Write-Host ""
        Write-Host ("  {0}" -f $file.FullName) -ForegroundColor Magenta
        Write-Host ("    before: {0}" -f ($beforeIssues -join "; ")) -ForegroundColor Yellow
        Write-Host ("    after:  {0}" -f ($afterIssues -join "; ")) -ForegroundColor $(if ($afterIssues.Count -eq 0) { "Green" } else { "Yellow" })

        if ($Apply -and $changedText) {
            $backup = Copy-RestructureBackup -Path $file.FullName
            Write-LLText -Path $file.FullName -Content $after
            Write-Host ("    backup: {0}" -f $backup) -ForegroundColor DarkGray
            Write-Host "    saved" -ForegroundColor Green
        } elseif (-not $Apply) {
            Write-Host "    dry-run only" -ForegroundColor DarkGray
        }

        if ($changedText) { $changed++ } else { $skipped++ }
    } catch {
        $failed++
        Write-Host ""
        Write-Host ("  [FAIL] {0}" -f $file.FullName) -ForegroundColor Red
        Write-Host ("    {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  changed candidates: {0}" -f $changed) -ForegroundColor Yellow
Write-Host ("  skipped:            {0}" -f $skipped) -ForegroundColor DarkGray
if ($failed -gt 0) { Write-Host ("  failed:             {0}" -f $failed) -ForegroundColor Red }
if ($Apply -and $changed -gt 0) { Write-Host ("  backup dir:         {0}" -f $BackupDir) -ForegroundColor DarkGray }
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) { exit 1 }
exit 0
