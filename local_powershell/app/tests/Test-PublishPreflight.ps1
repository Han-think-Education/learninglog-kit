#Requires -Version 7.0
# Uses isolated temporary fixtures and fake secret-shaped values only. Never runs Publisher/Hugo/Git publish.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'app/core/LearningLog.LocalCore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'app/core/LearningLog.PublishPreflight.psm1') -Force -DisableNameChecking
$script:passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}
function HasFinding($Result, [string]$Code) {
    return (@($Result.findings | Where-Object { $_.code -eq $Code }).Count -gt 0)
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('learninglog-preflight-' + [guid]::NewGuid().ToString('N'))
$ready = Join-Path $tempRoot 'ready'
$draftPath = Join-Path $ready 'dev/approved.md'
$assetRoot = Join-Path $tempRoot 'draft-assets'
$suitePassed = 0
New-Item -ItemType Directory -Path (Split-Path -Parent $draftPath), (Join-Path $assetRoot 'images') -Force | Out-Null

try {
    $raw = @('---','title: "Preflight fixture"','date: 2026-10-19','draft: true','public_policy: public','source_id: SRC-TEST-ONLY','---','','Only synthetic content.') -join "`n"
    Set-Content -LiteralPath $draftPath -Value $raw -Encoding utf8 -NoNewline
    Set-Content -LiteralPath (Join-Path $assetRoot 'images/diagram.png') -Value 'synthetic image fixture' -Encoding utf8 -NoNewline
    $hash = (Get-FileHash -LiteralPath $draftPath -Algorithm SHA256).Hash

    $publisherPath = Join-Path $root 'app/run_learninglog_publish.ps1'
    $publisher = (Get-Content -LiteralPath $publisherPath -Raw) + "`n" + (Get-Content -LiteralPath (Join-Path $root 'app/core/LearningLog.Publish.psm1') -Raw)
    $tokens = $null; $parseErrors = $null
    $publisherAst = [System.Management.Automation.Language.Parser]::ParseFile($publisherPath, [ref]$tokens, [ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'publisher parses after integration'
    Import-Module (Join-Path $root 'app/core/LearningLog.Publish.psm1') -Force -DisableNameChecking
    $processed = ConvertTo-LLPublishedPost -Content $raw

    $common = @{
        Path = $draftPath; ReadyRoot = $ready; ExpectedSha256 = $hash
        RegistryStatus = 'approved'; PublicPolicy = 'public'; SourceCategory = 'personal_note'
        OriginalContent = $raw; Content = $processed; DraftAssetRoot = $assetRoot
    }
    $result = Invoke-LLPublishPreflight @common
    Check ($result.status -eq 'PASS' -and $result.findings.Count -eq 0) 'approved public draft passes with matching content hash'
    Check ($result.source_sha256 -eq $hash) 'preflight receipt reports SHA-256 without changing the source'
    Check ($processed -notmatch '(?im)^\s*public_policy\s*:') 'publisher conversion strips internal public_policy metadata'
    Check ($processed -match 'Only synthetic content\.' -and $processed -notmatch '(?m)^public_policy: public$') 'internal metadata stripping preserves ordinary article text'
    $bodyExample = ConvertTo-LLPublishedPost -Content ($raw + "`n`npublic_policy: code-example")
    Check ($bodyExample -match '(?m)^public_policy: code-example$') 'policy-like text in the article body is preserved'

    $partialRaw = $raw -replace 'public_policy: public', 'public_policy: partial-public'
    $partialArgs = $common.Clone(); $partialArgs.OriginalContent = $partialRaw; $partialArgs.PublicPolicy = 'partial-public'
    Check ((Invoke-LLPublishPreflight @partialArgs).status -eq 'PASS') 'partial-public passes only when registry and source declaration agree'

    $case = $common.Clone(); $case.ExpectedSha256 = ('0' * 64)
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'approval_hash_changed') 'changed approval hash is blocked'
    $case = $common.Clone(); $case.PublicPolicy = 'private'
    Check ((Invoke-LLPublishPreflight @case).status -eq 'FAIL') 'private registry policy is blocked'
    $case = $common.Clone(); $case.PublicPolicy = 'internal-only'
    Check ((Invoke-LLPublishPreflight @case).status -eq 'FAIL') 'internal-only registry policy is blocked'
    $case = $common.Clone(); $case.PublicPolicy = 'unclassified'
    Check ((Invoke-LLPublishPreflight @case).status -eq 'FAIL') 'unknown registry policy is fail-closed'
    $case = $common.Clone(); $case.SourceCategory = 'practice_notebook'
    Check ((Invoke-LLPublishPreflight @case).findings.code -contains 'source_category_not_publishable') 'non-publishable source categories are blocked'
    $case = $common.Clone(); $case.RegistryStatus = 'needs_review'
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'registry_status_not_approved') 'unapproved registry status is blocked'
    $case = $common.Clone(); $case.RegistryStatus = 'published'; $case.AllowPublished = $false
    Check ((Invoke-LLPublishPreflight @case).status -eq 'FAIL') 'published update requires the explicit legacy update option'
    $case.AllowPublished = $true
    Check ((Invoke-LLPublishPreflight @case).status -eq 'PASS') 'explicit published-update option preserves existing update capability'

    $case = $common.Clone(); $case.OriginalContent = $raw -replace 'public_policy: public', 'public_policy: private'
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'declared_policy_not_publishable') 'private source declaration overrides public registry label'
    $case = $common.Clone(); $case.OriginalContent = $raw -replace 'public_policy: public', 'public_policy: partial-public'
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'declared_policy_conflict') 'conflicting registry and file policies are blocked'
    $case = $common.Clone(); $case.OriginalContent = 'No front matter'
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'frontmatter_missing_or_invalid') 'missing front matter is blocked'
    $case = $common.Clone(); $case.Content = $processed -replace '(?m)^title:', "public_policy: public`ntitle:"
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'internal_metadata_in_output') 'internal policy metadata cannot remain in public front matter'

    $fakeToken = 'ghp_012345678901234567890123456789012345'
    $case = $common.Clone(); $case.Content = $processed + "`n$fakeToken`n"
    $secretResult = Invoke-LLPublishPreflight @case
    Check ($secretResult.status -eq 'FAIL' -and (HasFinding $secretResult 'credential_like_value')) 'fake token-shaped fixture is detected'
    Check (($secretResult | ConvertTo-Json -Depth 5) -notmatch [regex]::Escape($fakeToken)) 'secret-shaped values are never copied into findings'
    $case = $common.Clone(); $case.Content = $processed + "`napi_key = abcdefghijklmnop123456`n"
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'credential_assignment_suspected') 'credential-like assignments fail closed'

    $case = $common.Clone(); $case.Content = $processed + "`n실행 경로 C:\Users\demo\local-model`n"
    $pathResult = Invoke-LLPublishPreflight @case
    Check ($pathResult.status -eq 'WARN' -and (HasFinding $pathResult 'personal_or_internal_path')) 'personal local paths require human review and block automatic continuation'

    $case = $common.Clone(); $case.Content = $processed.Replace('Only synthetic content.', '![diagram](/images/not-found.png)')
    $missingImageResult = Invoke-LLPublishPreflight @case
    Check (HasFinding $missingImageResult 'image_asset_missing_or_outside_root') 'missing local image asset is blocked before copy'
    $case = $common.Clone(); $case.Content = $processed.Replace('Only synthetic content.', '![diagram](/images/diagram.png)')
    Check ((Invoke-LLPublishPreflight @case).status -eq 'PASS') 'approved local image under the managed asset root passes'
    $case = $common.Clone(); $case.Content = $processed.Replace('Only synthetic content.', '![diagram](/images/diagram.zip)')
    Set-Content -LiteralPath (Join-Path $assetRoot 'images/diagram.zip') -Value 'synthetic' -Encoding utf8 -NoNewline
    $unsupportedImageResult = Invoke-LLPublishPreflight @case
    Check (HasFinding $unsupportedImageResult 'unsupported_image_type') 'unsupported attachment type is blocked'
    $case = $common.Clone(); $case.Content = $processed.Replace('Only synthetic content.', '![remote](https://example.invalid/image.png)')
    Check ((Invoke-LLPublishPreflight @case).status -eq 'WARN') 'external images remain a human-review warning'
    $case = $common.Clone(); $case.Content = $processed + "`n<img src=`"file:///C:/private/image.png`">"
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'html_embedded_asset_not_scanned') 'HTML embedded assets require review'
    $case = $common.Clone(); $case.Content = $processed + "`n[자료 받기](/downloads/example.zip)"
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'download_not_manifested') 'unmanifested download links require review'
    $case = $common.Clone(); $case.Content = $processed + "`nsource_id: SRC-TEST-ONLY"
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'internal_metadata_in_body') 'internal metadata in the article body requires review'
    $case = $common.Clone(); $case.Content = $processed.Replace('Only synthetic content.', '![unsafe](javascript:alert(1))')
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'unsafe_image_scheme') 'unsafe image URL scheme is blocked'
    $case = $common.Clone(); $case.Content = $processed.Replace('Only synthetic content.', '![escape](/images/../outside.png)')
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'image_path_traversal') 'image path traversal is blocked'

    $outside = Join-Path $tempRoot 'outside.md'
    Set-Content -LiteralPath $outside -Value $raw -Encoding utf8 -NoNewline
    $case = $common.Clone(); $case.Path = $outside
    Check (HasFinding (Invoke-LLPublishPreflight @case) 'outside_approved_root') 'file outside the approved folder is blocked'

    $preflightComment = $publisher.IndexOf('Invoke-LLPublishPreflightStage -Ctx')
    $copyLoop = $publisher.IndexOf('Invoke-LLPublishCopyStage -Ctx', $preflightComment)
    Check ($publisher.Contains('Invoke-LLPublishPreflight') -and $preflightComment -ge 0 -and $copyLoop -gt $preflightComment) 'publisher preflights the complete selection before its copy loop'
    $suitePassed = $script:passed
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

[pscustomobject]@{ suite='PublishPreflight'; passed=$suitePassed; external_publish=0; temp_fixtures_removed=$true } | ConvertTo-Json -Compress
