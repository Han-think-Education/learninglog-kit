#Requires -Version 7.0
# LocalCore 공용 헬퍼(단계 B에서 스크립트별 중복을 모은 함수)의 골든 테스트. 임시 파일만 사용한다.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'app/core/LearningLog.LocalCore.psm1') -Force -DisableNameChecking
$script:passed = 0
function Check($Actual, $Expected, [string]$Name) {
    if ("$Actual" -cne "$Expected") { throw "FAIL: $Name`n  expected=[$Expected]`n  actual  =[$Actual]" }
    $script:passed++
    Write-Host "PASS: $Name"
}

# ConvertTo-LLYamlString
Check (ConvertTo-LLYamlString 'plain') '"plain"' 'yaml plain'
Check (ConvertTo-LLYamlString 'say "hi"') '"say \"hi\""' 'yaml escapes quotes'
Check (ConvertTo-LLYamlString 'a\b') '"a\\b"' 'yaml escapes backslash'
Check (ConvertTo-LLYamlString "l1`nl2") '"l1 l2"' 'yaml folds newlines by default'
Check (ConvertTo-LLYamlString "l1`nl2" -KeepNewlines) ('"l1' + "`n" + 'l2"') 'yaml -KeepNewlines keeps them'
Check (ConvertTo-LLYamlString $null) '""' 'yaml null -> empty'
Check (ConvertTo-LLYamlString '한글: 제목') '"한글: 제목"' 'yaml keeps hangul'

# ConvertTo-LLPlainText
Check (ConvertTo-LLPlainText '<p>Hello &amp; <b>world</b></p>') 'Hello & world' 'plain text strips tags and decodes entities'
Check (ConvertTo-LLPlainText '  a   b  ') 'a b' 'plain text collapses whitespace'
Check (ConvertTo-LLPlainText '  ') '' 'plain text blank -> empty'

# Get-LLDraftSection
$drafts = 'C:\x\04_blog_drafts'
Check (Get-LLDraftSection -Draft ([IO.FileInfo]::new('C:\x\04_blog_drafts\Projects\b.md')) -DraftsDir $drafts) 'projects' 'section is first folder, lowercased'
Check (Get-LLDraftSection -Draft ([IO.FileInfo]::new('C:\x\04_blog_drafts\learning\a.md')) -DraftsDir $drafts) 'learning' 'section learning'

# Test-LLTodayDraft
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('coreh_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $today = Get-Date -Format 'yyyy-MM-dd'
    $fresh = New-Item (Join-Path $tmp "$today-x.md") -Value 'a'
    $old = New-Item (Join-Path $tmp 'old.md') -Value 'b'
    $old.LastWriteTime = (Get-Date).AddDays(-10)
    $old.Refresh()
    Check (Test-LLTodayDraft -Draft $fresh -TodayStr $today) 'True' 'today: file name starts with today'
    Check (Test-LLTodayDraft -Draft $old -TodayStr $today) 'False' 'today: old file, no row -> false'
    Check (Test-LLTodayDraft -Draft $old -TodayStr $today -IncludeBacklog) 'True' 'today: backlog includes old'
    Check (Test-LLTodayDraft -Draft $old -Row ([pscustomobject]@{ date_added = $today }) -TodayStr $today) 'True' 'today: row date_added is today'
    Check (Test-LLTodayDraft -Draft $old -Row ([pscustomobject]@{ date_added = '2020-01-01' }) -TodayStr $today) 'False' 'today: row date_added is old'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# Remove-ExtraHugoFrontMatter (-KeepTrailingWhitespace 는 LLM 초안 정리용)
$sample = "---`ntitle: x`n---`n본문  `nsource_id: SRC-1`n**제목**: 가짜`n끝 공백   `n"
Check (Remove-ExtraHugoFrontMatter -Text $sample) ("---`ntitle: x`n---`n본문`n끝 공백`n") 'frontmatter: default trims trailing whitespace'
Check (Remove-ExtraHugoFrontMatter -Text $sample -KeepTrailingWhitespace) ("---`ntitle: x`n---`n본문  `n끝 공백   `n".TrimEnd() + "`n") 'frontmatter: -KeepTrailingWhitespace keeps hard line breaks'

Write-Host ("ALL PASS ({0} checks)" -f $script:passed) -ForegroundColor Green
