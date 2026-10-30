#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Local Intake — 00_inbox 새 파일 감지 및 v0.5 로컬 registry 등록

.DESCRIPTION
    kit import 없이 LearningLog 로컬 전용 규칙으로 동작한다.
    hash 기반 중복 감지, 15열 registry schema 업그레이드, public_policy 안전 분류,
    실행 리포트 생성을 수행한다.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$Root = Get-LLRoot
$InboxRoot = Get-LLPath "00_inbox"
$RegistryPath = Get-LLRegistryPath
$ReportsDir = Get-LLPath "09_reports"
$RunDT = Get-Date
$RunTime = $RunDT.ToString("yyyy-MM-dd HH:mm:ss")
$Today = $RunDT.ToString("yyyyMMdd")
$TodayDisplay = $RunDT.ToString("yyyy-MM-dd")
$TimeStamp = $RunDT.ToString("yyyy-MM-dd_HHmmss")

$SubFolders = @("lectures", "chat_exports", "personal_notes", "dev_notes", "screenshots", "web_notes")
# index 대상 = 학습로그(노트) 본문만. PDF/이미지/zip/노트북 등 비노트 파일은 등록하지 않는다
# (어차피 LLM 처리에서 제외되는 것들 = index 잡음). 필요하면 확장자를 다시 추가하면 된다.
$AllowedExtensions = @(".md", ".txt")
# 노트가 아닌 리포지토리/시스템 잡파일은 파일명(확장자 제외)으로도 제외한다.
$IgnoreBaseNames = @("readme", "read_me", "manifest", "agents", "claude", "changelog", "license", "contributing")

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LearningLog Local Intake" -ForegroundColor Cyan
Write-Host "  $RunTime" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$schema = Ensure-LLRegistrySchema
if ($schema.upgraded) {
    if ($schema.backup) {
        Write-Host ("  registry upgraded  backup={0}" -f $schema.backup) -ForegroundColor Yellow
    } else {
        Write-Host "  registry created" -ForegroundColor Yellow
    }
}

$rows = @(Get-LLRegistryRows)
$registeredPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$registeredHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $rows) {
    $path = Get-LLProp $row "source_path"
    $hash = Get-LLProp $row "hash"
    if ($path) { $null = $registeredPaths.Add($path.Normalize([System.Text.NormalizationForm]::FormC)) }
    if ($hash) { $null = $registeredHashes.Add($hash.ToLowerInvariant()) }
}

$candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($folder in $SubFolders) {
    $path = Join-Path $InboxRoot $folder
    if (Test-Path -LiteralPath $path) {
        # 개발 자료만 한 묶음 폴더를 허용. 수업 입력의 기존 평면 스캔은 그대로.
        Get-ChildItem -LiteralPath $path -File -Recurse:($folder -eq 'dev_notes') -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.Name.StartsWith(".") -and
                ($_.Extension.ToLowerInvariant() -in $AllowedExtensions) -and
                ($_.BaseName.ToLowerInvariant() -notin $IgnoreBaseNames)
            } |
            ForEach-Object { $candidates.Add($_) }
    }
}
$candidates = @($candidates | Sort-Object FullName)

Write-Host ""
Write-Host ("  intake scan: {0} candidate files" -f $candidates.Count) -ForegroundColor Yellow

$newRows = [System.Collections.Generic.List[object]]::new()
$registered = [System.Collections.Generic.List[string]]::new()
$duplicates = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$extCounts = @{}
$categoryCounts = @{}

for ($i = 0; $i -lt $candidates.Count; $i++) {
    $file = $candidates[$i]
    $n = $i + 1
    $rel = Get-LLRelativePath $file.FullName
    $subfolder = ($rel -split "/")[1]
    $ext = $file.Extension.ToLowerInvariant()
    if (-not $extCounts.ContainsKey($ext)) { $extCounts[$ext] = 0 }
    $extCounts[$ext]++

    try {
        # 이미 등록된 경로는 해시 계산(파일 전체 읽기) 전에 즉시 skip. 과거 것 재해시·콘솔 잡음 제거.
        if ($registeredPaths.Contains($rel.Normalize([System.Text.NormalizationForm]::FormC))) {
            $skipped.Add("$rel already_registered")
            continue
        }
        if ($subfolder -eq 'dev_notes') { $null = Resolve-LLDevNotePath $rel }
        $meta = Get-LLSourceMetadata -File $file -InboxSubfolder $subfolder
        if (-not $categoryCounts.ContainsKey($meta.source_category)) { $categoryCounts[$meta.source_category] = 0 }
        $categoryCounts[$meta.source_category]++

        if ($meta.hash -and $registeredHashes.Contains($meta.hash.ToLowerInvariant())) {
            $duplicates.Add("$rel hash=$($meta.hash)")
            continue
        }

        $sid = Get-LLNextSourceId -Rows (@($rows) + @($newRows)) -DateString $Today
        $obj = [ordered]@{}
        $obj["source_id"] = $sid
        $obj["source_path"] = $rel
        $obj["file_name"] = $meta.file_name
        $obj["file_path"] = $meta.file_path
        $obj["file_type"] = $meta.file_type
        $obj["source_type"] = $meta.source_type
        $obj["source_category"] = $meta.source_category
        $obj["date_added"] = $TodayDisplay
        $obj["created_at"] = $RunTime
        $obj["status"] = "registered"
        $obj["topic"] = $meta.topic
        $obj["language"] = "ko"
        $obj["public_policy"] = $meta.public_policy
        $obj["hash"] = $meta.hash
        $obj["notes"] = "local-intake auto-registered from $subfolder"

        $newRow = [pscustomobject]$obj
        $newRows.Add($newRow)
        $null = $registeredPaths.Add($rel)
        if ($meta.hash) { $null = $registeredHashes.Add($meta.hash.ToLowerInvariant()) }
        $registered.Add("$sid $rel $($meta.source_category) $($meta.public_policy)")
        Write-Host ("  [{0}/{1}] registered {2} {3} {4}" -f $n, $candidates.Count, $sid, $meta.source_category, $rel) -ForegroundColor Green
    } catch {
        Write-Host ("  [{0}/{1}] ERROR {2} {3}" -f $n, $candidates.Count, $rel, $_.Exception.Message) -ForegroundColor Red
        $errors.Add("$rel $($_.Exception.Message)")
    }
}

if ($newRows.Count -gt 0) {
    $backup = Backup-LLFile -Path $RegistryPath -Prefix "source_registry_before_intake"
    Save-LLRegistryRows (@($rows) + @($newRows))
    Write-Host ("  registry saved: {0}" -f $RegistryPath) -ForegroundColor Cyan
    Write-Host ("  backup: {0}" -f $backup) -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $ReportsDir)) {
    New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null
}
$reportPath = Join-Path $ReportsDir ("RUN_{0}_intake_report.md" -f $TimeStamp)
$report = [System.Collections.Generic.List[string]]::new()
$report.Add("# LearningLog Local Intake Report")
$report.Add("")
$report.Add("> 실행 시각: $RunTime")
$report.Add("")
$report.Add("## Summary")
$report.Add("")
$report.Add("| 항목 | 수 |")
$report.Add("|------|----|")
$report.Add("| Candidate files | $($candidates.Count) |")
$report.Add("| New registered | $($newRows.Count) |")
$report.Add("| Duplicate skipped | $($duplicates.Count) |")
$report.Add("| Already registered / skipped | $($skipped.Count) |")
$report.Add("| Errors | $($errors.Count) |")
$report.Add("")
$report.Add("## Extensions")
$report.Add("")
foreach ($k in ($extCounts.Keys | Sort-Object)) { $report.Add("- ``$k``: $($extCounts[$k])") }
$report.Add("")
$report.Add("## Categories")
$report.Add("")
foreach ($k in ($categoryCounts.Keys | Sort-Object)) { $report.Add("- ``$k``: $($categoryCounts[$k])") }
$report.Add("")
$report.Add("## Registered Sources")
$report.Add("")
if ($registered.Count) { $registered | ForEach-Object { $report.Add("- $_") } } else { $report.Add("_(none)_") }
$report.Add("")
$report.Add("## Duplicate Skips")
$report.Add("")
if ($duplicates.Count) { $duplicates | ForEach-Object { $report.Add("- $_") } } else { $report.Add("_(none)_") }
$report.Add("")
$report.Add("## Errors")
$report.Add("")
if ($errors.Count) { $errors | ForEach-Object { $report.Add("- $_") } } else { $report.Add("_(none)_") }
Write-LLText -Path $reportPath -Content ($report -join "`n")

Write-Host ""
Write-Host "  intake summary" -ForegroundColor Cyan
Write-Host ("  new={0} duplicate={1} skipped={2} errors={3}" -f $newRows.Count, $duplicates.Count, $skipped.Count, $errors.Count)
Write-Host ("  report: {0}" -f $reportPath) -ForegroundColor DarkGray
Write-Host ""
