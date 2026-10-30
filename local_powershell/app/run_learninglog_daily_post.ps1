#Requires -Version 7.0
<#
.SYNOPSIS
    사진을 포함할 수 있는 수동 개인 기록 블로그 초안을 만든다.

.DESCRIPTION
    LLM 없이 사용자가 직접 쓴 글과 선택한 사진을
    04_blog_drafts\personal 에 저장한다. 사진은
    04_blog_drafts\_assets\personal\<slug> 에 복사하고, 발행 단계에서
    기존 Copy-DraftReferencedAssets 경로를 통해 Blog\static\images 로 전달된다.
    작성 후 personal 섹션 registry 등록까지 수행한다.
#>

param(
    [string]$Date = (Get-Date).ToString("yyyy-MM-dd"),
    [string]$Title = "",
    [string]$Tags = "",
    [string]$Music = "",
    [string]$Policy = "",
    [switch]$NoOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$DraftDir = Get-LLPath "04_blog_drafts\personal"
$AssetRoot = Get-LLPath "04_blog_drafts\_assets\personal"

function ConvertTo-DailySlug {
    param([Parameter(Mandatory)][string]$Value)
    $s = $Value.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 70) { $s = $s.Substring(0,70).Trim('-') }
    if (-not $s) { $s = "personal" }
    return $s
}

function ConvertTo-SafeAssetName {
    param([Parameter(Mandatory)][string]$Value)
    $ext = [IO.Path]::GetExtension($Value).ToLowerInvariant()
    $base = [IO.Path]::GetFileNameWithoutExtension($Value)
    $base = ($base -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')
    if (-not $base) { $base = "photo" }
    return "$base$ext"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  사진 포함 개인 기록 작성" -ForegroundColor Cyan
Write-Host "  $Date" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (-not $Title) { $Title = (Read-Host "  제목 (비우면 '$Date 개인 기록')").Trim() }
if (-not $Title) { $Title = "$Date 개인 기록" }
if (-not $Tags) { $Tags = (Read-Host "  태그 (쉼표 구분, 선택)").Trim() }
if (-not $Music) { $Music = (Read-Host "  음악 링크 (선택, Spotify/YouTube 등)").Trim() }
if (-not $Policy) { $Policy = (Read-Host "  공개범위 (공개/일부 공개/나만 보기, 기본 공개)").Trim() }
$policyValue = switch ($Policy.ToLowerInvariant()) {
    "일부 공개" { "partial-public"; break }
    "partial-public" { "partial-public"; break }
    "나만 보기" { "private"; break }
    "private" { "private"; break }
    "내부 전용" { "internal-only"; break }
    "internal-only" { "internal-only"; break }
    default { "public" }
}

Write-Host ""
Write-Host "  글 내용을 입력하세요. 빈 줄을 입력하면 끝납니다." -ForegroundColor Yellow
$bodyLines = [System.Collections.Generic.List[string]]::new()
while ($true) {
    $line = Read-Host "  >"
    if ($line -eq "") { break }
    $bodyLines.Add($line)
}
if ($bodyLines.Count -eq 0) { $bodyLines.Add("오늘의 기록을 직접 작성하세요.") }

$imageInput = (Read-Host "  사진 경로 (쉼표 구분, 없으면 엔터)").Trim()
$imagePaths = @()
if ($imageInput) {
    $imagePaths = @($imageInput -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
}

$slug = ConvertTo-DailySlug $Title
$assetDir = Join-Path $AssetRoot $slug
$imageRefs = [System.Collections.Generic.List[string]]::new()
$imageCaptions = [System.Collections.Generic.List[string]]::new()
$allowed = @('.png','.jpg','.jpeg','.gif','.webp','.svg')
$idx = 0
foreach ($source in $imagePaths) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-Host ("  [건너뜀] 사진을 찾지 못했습니다: {0}" -f $source) -ForegroundColor Yellow
        continue
    }
    $ext = [IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($ext -notin $allowed) {
        Write-Host ("  [건너뜀] 지원하지 않는 이미지 형식: {0}" -f $source) -ForegroundColor Yellow
        continue
    }
    if (-not (Test-Path -LiteralPath $assetDir)) { New-Item -ItemType Directory -Path $assetDir -Force | Out-Null }
    $idx++
    $safeName = "{0:D2}-{1}" -f $idx, (ConvertTo-SafeAssetName (Split-Path $source -Leaf))
    $dest = Join-Path $assetDir $safeName
    Copy-Item -LiteralPath $source -Destination $dest -Force
    $relative = "personal/$slug/$safeName"
    $imageRefs.Add("/images/$relative")
    $imageCaptions.Add([IO.Path]::GetFileNameWithoutExtension((Split-Path $source -Leaf)))
    Write-Host ("  [사진 복사] {0}" -f $safeName) -ForegroundColor Green
}

$tagValues = @($Tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$tagYaml = if ($tagValues.Count) { (@($tagValues | ForEach-Object { ConvertTo-LLYamlString -KeepNewlines $_ }) -join ', ') } else { ConvertTo-LLYamlString -KeepNewlines "일상" }
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("---")
$lines.Add("title: $(ConvertTo-LLYamlString -KeepNewlines $Title)")
$lines.Add("date: $Date")
$lines.Add("draft: true")
$lines.Add("public_policy: $policyValue")
$lines.Add('categories: ["personal"]')
$lines.Add("tags: [$tagYaml]")
$lines.Add("description: $(ConvertTo-LLYamlString -KeepNewlines ($bodyLines[0]))")
$lines.Add("---")
$lines.Add("")
$lines.Add("## 목차")
$lines.Add("")
$lines.Add("- [오늘의 기록](#오늘의-기록)")
if ($imageRefs.Count -gt 0) { $lines.Add("- [사진 기록](#사진-기록)") }
if ($Music) { $lines.Add("- [음악 기록](#음악-기록)") }
$lines.Add("- [총평](#총평)")
$lines.Add("")
$lines.Add("## 오늘의 기록")
$lines.Add("")
foreach ($line in $bodyLines) { $lines.Add($line); $lines.Add("") }
if ($imageRefs.Count -gt 0) {
    $lines.Add("## 사진 기록")
    $lines.Add("")
    for ($i = 0; $i -lt $imageRefs.Count; $i++) {
        $caption = $imageCaptions[$i]
        $lines.Add("![사진: $caption]($($imageRefs[$i]))")
        $lines.Add("")
    }
}
if ($Music) {
    $lines.Add("## 음악 기록")
    $lines.Add("")
    $lines.Add("[이날의 음악]($Music)")
    $lines.Add("")
}
$lines.Add("## 총평")
$lines.Add("")
$lines.Add("오늘의 기록을 블로그 주인의 시선으로 남겼습니다.")
$lines.Add("")
$lines.Add("> ✍️ 이 글은 블로그 주인이 직접 기록한 일상 글입니다.")

if (-not (Test-Path -LiteralPath $DraftDir)) { New-Item -ItemType Directory -Path $DraftDir -Force | Out-Null }
$outPath = Join-Path $DraftDir "$Date-$slug.md"
Write-LLText -Path $outPath -Content (($lines -join "`n") + "`n")

Write-Host ""
Write-Host "  초안 저장 완료" -ForegroundColor Green
Write-Host ("  글: {0}" -f $outPath) -ForegroundColor DarkGray
Write-Host ("  사진: {0}개" -f $imageRefs.Count) -ForegroundColor DarkGray
Write-Host ("  공개범위: {0}" -f $policyValue) -ForegroundColor DarkGray
Write-Host "  personal registry 등록 중..." -ForegroundColor Cyan
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "run\run_learninglog_register_drafts.ps1") -Policy $policyValue -Section personal
Write-Host "  다음: [2] 미리보기 → 통과 → [5] 발행" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
if (-not $NoOpen) { Start-Process $outPath }
