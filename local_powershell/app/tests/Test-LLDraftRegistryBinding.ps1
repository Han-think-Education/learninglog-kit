# Regression checks for draft source_id parsing and registry binding.
# This test imports the core module and uses in-memory fixtures only.
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'app/core/LearningLog.LocalCore.psm1') -Force -DisableNameChecking

$script:passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}

$rows = @(
    [pscustomobject]@{
        source_id = 'SRC-BODY-001'; topic = 'original-personal-note'; status = 'drafted'
        source_category = 'personal_note'; source_type = 'personal_note'; public_policy = 'partial-public'
        date_added = '2026-10-13'; source_path = '00_inbox/personal_notes/original.md'
    }
    [pscustomobject]@{
        source_id = 'SRC-MERGED-001'; topic = '2026-10-13-am-daily'; status = 'drafted'
        source_category = 'daily_merged'; source_type = 'blog_draft'; public_policy = 'public'
        date_added = '2026-10-13'; source_path = '04_blog_drafts/learning/2026-10-13-am-daily.md'
    }
)
$draft = [System.IO.FileInfo]::new('C:\LearningLog\04_blog_drafts\learning\2026-10-13-am-daily.md')

$dailyDraftWithQuotedSource = @'
---
title: "AM daily"
date: 2026-10-13
---

원본 자료의 형식을 설명하는 예시:

```text
source_id: SRC-BODY-001
```
'@

Check ((Get-LLDraftSourceId $dailyDraftWithQuotedSource) -eq '') 'body source_id is not treated as draft metadata'
$resolvedDaily = Resolve-LLDraftRegistryRow -Draft $draft -Content $dailyDraftWithQuotedSource -Rows $rows
Check ($resolvedDaily.source_id -eq 'SRC-MERGED-001') 'body-only source_id falls back to the draft filename topic'
$dailyDates = Get-LLDailyMergedDateKeys -Rows $rows
Check (-not (Test-LLDraftByproduct -Draft $draft -Row $resolvedDaily -DailyMergedDates $dailyDates)) 'daily merged draft is not hidden as a personal-note byproduct'

$draftWithFrontMatterSource = @'
---
title: "Registered note"
source_id: "SRC-BODY-001"
---

본문에 다른 원본 ID가 인용되어도 앞머리 ID를 유지합니다.
source_id: SRC-MERGED-001
'@
Check ((Get-LLDraftSourceId $draftWithFrontMatterSource) -eq 'SRC-BODY-001') 'front matter source_id is preserved when the body has another ID'
$resolvedSource = Resolve-LLDraftRegistryRow -Draft $draft -Content $draftWithFrontMatterSource -Rows $rows
Check ($resolvedSource.source_id -eq 'SRC-BODY-001') 'explicit front matter ID still takes precedence over filename fallback'

Write-Host "Draft registry binding checks passed: $script:passed"
