#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Review - draft/published/blog markdown quality gate scan.

.DESCRIPTION
    수정/발행 없이 Markdown 글을 검사한다.
    반복된 글 구조 섹션, 중간 front matter, 내부 메타, 빈 출력 주석,
    닫히지 않은 코드펜스 등을 보고서로 남긴다.
#>

param(
    [ValidateSet("drafts", "published", "blog", "all")]
    [string]$Scope = "drafts",
    [switch]$NoReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$Root = Get-LLRoot
$RunDT = Get-Date
$RunTime = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$TimeStamp = $RunDT.ToString("yyyyMMdd_HHmmss")
$ReportsDir = Get-LLPath "09_reports"
$BlogSourceRoot = Join-Path (Get-LLBlogRoot) "content"

if (-not (Test-Path -LiteralPath $ReportsDir)) {
    New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null
}

$scanRoots = [System.Collections.Generic.List[object]]::new()
if ($Scope -in @("drafts", "all")) {
    $scanRoots.Add([pscustomobject]@{ Label = "drafts"; Path = (Get-LLPath "04_blog_drafts") })
}
if ($Scope -in @("published", "all")) {
    $scanRoots.Add([pscustomobject]@{ Label = "published"; Path = (Get-LLPath "06_published") })
}
if ($Scope -in @("blog", "all")) {
    foreach ($section in @("learning", "goals", "practice", "projects")) {
        $scanRoots.Add([pscustomobject]@{ Label = "blog-source/$section"; Path = (Join-Path $BlogSourceRoot $section) })
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Review" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  scope: {0}" -f $Scope) -ForegroundColor DarkGray

$rows = [System.Collections.Generic.List[object]]::new()
$checked = 0

foreach ($rootInfo in $scanRoots) {
    if (-not (Test-Path -LiteralPath $rootInfo.Path)) {
        Write-Host ("  [SKIP] {0}: {1}" -f $rootInfo.Label, $rootInfo.Path) -ForegroundColor DarkGray
        continue
    }

    $files = @(Get-ChildItem -LiteralPath $rootInfo.Path -Recurse -Filter "*.md" -File | Sort-Object FullName)
    Write-Host ("  {0}: {1} files" -f $rootInfo.Label, $files.Count) -ForegroundColor Yellow

    foreach ($file in $files) {
        $checked++
        $content = Read-LLText $file.FullName
        $issues = @(Get-LLDraftQualityIssues -Content $content)
        if ($issues.Count -eq 0) { continue }

        $stats = Get-LLArticleStructureStats -Content $content
        $rows.Add([pscustomobject]@{
            Scope = $rootInfo.Label
            Path = $file.FullName
            Issues = ($issues -join "; ")
            Purpose = $stats.purpose
            Learned = $stats.learned
            Confused = $stats.confused
            Practice = $stats.practice
            Summary = $stats.summary
            Combined = $stats.combined
        })
    }
}

Write-Host ""
Write-Host ("  checked: {0}" -f $checked) -ForegroundColor White
Write-Host ("  issues:  {0}" -f $rows.Count) -ForegroundColor $(if ($rows.Count -gt 0) { "Yellow" } else { "Green" })

if ($rows.Count -gt 0) {
    Write-Host ""
    $rows |
        Select-Object Scope, Path, Issues |
        Format-Table -AutoSize
}

if (-not $NoReport) {
    $reportPath = Join-Path $ReportsDir ("review_report_{0}.md" -f $TimeStamp)
    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add("# LearningLog Review Report")
    $report.Add("")
    $report.Add("- run_time: $RunTime")
    $report.Add("- scope: $Scope")
    $report.Add("- checked_files: $checked")
    $report.Add("- issue_files: $($rows.Count)")
    $report.Add("")
    $report.Add("## Findings")
    $report.Add("")

    if ($rows.Count -eq 0) {
        $report.Add("No quality gate issues found.")
    } else {
        $report.Add("| scope | file | issues | structure counts |")
        $report.Add("|---|---|---|---|")
        foreach ($row in $rows) {
            $rel = $row.Path.Replace($Root + "\", "").Replace("\", "/")
            $counts = "purpose=$($row.Purpose), learned=$($row.Learned), confused=$($row.Confused), practice=$($row.Practice), summary=$($row.Summary), combined=$($row.Combined)"
            $report.Add(("| {0} | `{1}` | {2} | {3} |" -f $row.Scope, $rel, ($row.Issues -replace "\|", "/"), $counts))
        }
    }

    Write-LLText -Path $reportPath -Content (($report -join "`n") + "`n")
    Write-Host ""
    Write-Host ("  report: {0}" -f $reportPath) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($rows.Count -gt 0) { exit 1 }
exit 0
