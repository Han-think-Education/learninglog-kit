#Requires -Version 7.0
# Uses disposable local Git repositories only. Never runs Hugo, Publisher, commit on production, or push.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$learningLogRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $learningLogRoot 'app/core/LearningLog.PublishGitGuard.psm1') -Force -DisableNameChecking

$script:passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}
function Throws([scriptblock]$Action, [string]$Name) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    Check $thrown $Name
}
function New-FixtureRepository([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'fixture git init failed' }
    & git -C $Path config user.name 'LearningLog Fixture'
    & git -C $Path config user.email 'fixture@example.invalid'
    New-Item -ItemType Directory -Path (Join-Path $Path 'content') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'fixture baseline' -NoNewline -Encoding utf8
    & git -C $Path add -- README.md
    if ($LASTEXITCODE -ne 0) { throw 'fixture git add failed' }
    & git -C $Path commit --quiet -m 'fixture baseline'
    if ($LASTEXITCODE -ne 0) { throw 'fixture git commit failed' }
    return $Path
}

$tempRoot = Join-Path $learningLogRoot ('app/tests/.tmp-publish-git-guard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $cleanRepo = New-FixtureRepository (Join-Path $tempRoot 'clean repo')
    $cleanState = Assert-LLPublishRepositoryReady -RepoRoot $cleanRepo -Label 'fixture'
    Check (@($cleanState.staged_paths).Count -eq 0 -and @($cleanState.working_paths).Count -eq 0) 'clean repository passes'

    $lineEndingRepo = New-FixtureRepository (Join-Path $tempRoot 'autocrlf stderr isolation')
    & git -C $lineEndingRepo config core.autocrlf true
    if ($LASTEXITCODE -ne 0) { throw 'fixture autocrlf config failed' }
    $warningPath = 'content/승인 문서.md'
    $warningFile = Join-Path $lineEndingRepo ($warningPath -replace '/', '\')
    [IO.File]::WriteAllText($warningFile, ('baseline' + [char]10), [Text.UTF8Encoding]::new($false))
    & git -C $lineEndingRepo add -- $warningPath 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'fixture warning-path stage failed' }
    & git -C $lineEndingRepo commit --quiet -m 'warning path baseline'
    if ($LASTEXITCODE -ne 0) { throw 'fixture warning-path commit failed' }
    [IO.File]::WriteAllText($warningFile, ('updated' + [char]10), [Text.UTF8Encoding]::new($false))
    $warningState = Get-LLPublishGitState -RepoRoot $lineEndingRepo
    $warningPaths = @($warningState.working_paths)
    Check ($warningPaths.Count -eq 1 -and $warningPaths[0] -eq $warningPath) 'autocrlf stderr warning stays out of NUL-delimited paths'

    $batchedPaths = @('content/approved one.md', 'content/승인 문서 2.md', 'content/approved-three.md')
    foreach ($path in $batchedPaths) {
        $file = Join-Path $lineEndingRepo ($path -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
        [IO.File]::WriteAllText($file, ('approved' + [char]10), [Text.UTF8Encoding]::new($false))
    }
    $batchResult = Add-LLPublishPathsToIndex -RepoRoot $lineEndingRepo -Paths $batchedPaths -MaxBatchPathCount 2
    Check ($batchResult.path_count -eq 3 -and $batchResult.batch_count -eq 2) 'staging splits long allowlists into bounded batches'
    $batchStaged = @(Assert-LLPublishStagedPathsAllowed -RepoRoot $lineEndingRepo -AllowedPaths $batchedPaths -Label 'fixture')
    Check ($batchStaged.Count -eq 3 -and @($batchStaged | Where-Object { $_ -notin $batchedPaths }).Count -eq 0) 'batched staging preserves exact Unicode and spaced allowlist paths'
    Throws { Add-LLPublishPathsToIndex -RepoRoot $lineEndingRepo -Paths @('../outside.md') } 'batched staging rejects paths outside the repository'
    $oversizedPath='content/'+('x'*1100)+'.md'
    Throws { Add-LLPublishPathsToIndex -RepoRoot $lineEndingRepo -Paths @($oversizedPath) -MaxCommandLineLength 1024 } 'one overlong path fails before invoking Git'

    $literalRepo=New-FixtureRepository (Join-Path $tempRoot 'literal git pathspec')
    foreach($path in @('content/article[1].md','content/article1.md')) {
        [IO.File]::WriteAllText((Join-Path $literalRepo ($path -replace '/', '\')), $path, [Text.UTF8Encoding]::new($false))
    }
    $null=Add-LLPublishPathsToIndex -RepoRoot $literalRepo -Paths @('content/article[1].md')
    $literalStaged=@((Get-LLPublishGitState -RepoRoot $literalRepo).staged_paths)
    Check ($literalStaged.Count -eq 1 -and $literalStaged[0] -eq 'content/article[1].md') 'Git staging treats bracketed filenames as literal paths'

    $unchangedRepo=New-FixtureRepository (Join-Path $tempRoot 'unchanged allowlist entry')
    [IO.File]::WriteAllText((Join-Path $unchangedRepo 'content/unchanged.md'),'unchanged',[Text.UTF8Encoding]::new($false))
    & git -C $unchangedRepo add -- ':(literal)content/unchanged.md'; & git -C $unchangedRepo commit --quiet -m 'unchanged path fixture'
    if ($LASTEXITCODE -ne 0) { throw 'fixture unchanged-path commit failed' }
    $unchangedStage=Add-LLPublishPathsToIndex -RepoRoot $unchangedRepo -Paths @('content/unchanged.md')
    $unchangedState=Get-LLPublishGitState -RepoRoot $unchangedRepo
    Check ($unchangedStage.path_count -eq 1 -and @($unchangedState.staged_paths).Count -eq 0) 'unchanged approved paths do not create false stage failures'

    $ignoredStageRepo=New-FixtureRepository (Join-Path $tempRoot 'ignored selected path')
    [IO.File]::WriteAllText((Join-Path $ignoredStageRepo '.gitignore'),'content/ignored.md',[Text.UTF8Encoding]::new($false))
    & git -C $ignoredStageRepo add -- .gitignore; & git -C $ignoredStageRepo commit --quiet -m 'ignored path fixture'
    if ($LASTEXITCODE -ne 0) { throw 'fixture ignored-path commit failed' }
    [IO.File]::WriteAllText((Join-Path $ignoredStageRepo 'content/ignored.md'),'ignored',[Text.UTF8Encoding]::new($false))
    Throws { Add-LLPublishPathsToIndex -RepoRoot $ignoredStageRepo -Paths @('content/ignored.md') } 'selected ignored paths fail closed before staging'
    $ignoredStageState=Get-LLPublishGitState -RepoRoot $ignoredStageRepo
    Check (@($ignoredStageState.staged_paths).Count -eq 0) 'ignored path rejection leaves the index unchanged'

    $partialRepo=New-FixtureRepository (Join-Path $tempRoot 'partial batch failure')
    [IO.File]::WriteAllText((Join-Path $partialRepo 'content/first.md'), 'first batch', [Text.UTF8Encoding]::new($false))
    Throws { Add-LLPublishPathsToIndex -RepoRoot $partialRepo -Paths @('content/first.md','content/missing.md') -MaxBatchPathCount 1 } 'missing later batch aborts allowlisted staging'
    $partialState=Get-LLPublishGitState -RepoRoot $partialRepo
    Check (@($partialState.staged_paths).Count -eq 0 -and $partialState.working_paths -contains 'content/first.md') 'failed multi-batch staging rolls back only its index changes'

    $captureFailure = ''
    try {
        & (Get-Module -Name LearningLog.PublishGitGuard) {
            param($root)
            Invoke-LLPublishGitCapture -RepoRoot $root -Arguments @('not-a-real-git-subcommand')
        } $lineEndingRepo | Out-Null
    } catch {
        $captureFailure = $_.Exception.Message
    }
    Check ($captureFailure -match 'not-a-real-git-subcommand') 'Git capture retains stderr diagnostics on command failure'

    $retryPath = 'content/projects/approved retry.md'
    New-Item -ItemType Directory -Path (Join-Path $cleanRepo 'content/projects') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanRepo ($retryPath -replace '/', '\')) -Value 'approved retry fixture' -NoNewline -Encoding utf8
    $retryState = Assert-LLPublishRepositoryReady -RepoRoot $cleanRepo -AllowedWorkingPaths @($retryPath) -Label 'fixture'
    Check ($retryState.working_paths -contains $retryPath) 'only an explicitly selected retry file may remain unstaged'

    $unexpectedRepo = New-FixtureRepository (Join-Path $tempRoot 'unexpected')
    Set-Content -LiteralPath (Join-Path $unexpectedRepo 'content/private.md') -Value 'not selected' -NoNewline -Encoding utf8
    Throws { Assert-LLPublishRepositoryReady -RepoRoot $unexpectedRepo -AllowedWorkingPaths @('content/approved.md') -Label 'fixture' } 'unselected content change is blocked'

    $stagedRepo = New-FixtureRepository (Join-Path $tempRoot 'staged')
    Set-Content -LiteralPath (Join-Path $stagedRepo 'content/private.md') -Value 'already staged' -NoNewline -Encoding utf8
    & git -C $stagedRepo add -- content/private.md
    if ($LASTEXITCODE -ne 0) { throw 'fixture staged git add failed' }
    Throws { Assert-LLPublishRepositoryReady -RepoRoot $stagedRepo -AllowedWorkingPaths @('content/private.md') -Label 'fixture' } 'pre-existing staged data is blocked'

    $deletedRepo = New-FixtureRepository (Join-Path $tempRoot 'deleted')
    Remove-Item -LiteralPath (Join-Path $deletedRepo 'README.md')
    Throws { Assert-LLPublishRepositoryReady -RepoRoot $deletedRepo -Label 'fixture' } 'deleted tracked files are detected and blocked'

    $ignoredRepo = New-FixtureRepository (Join-Path $tempRoot 'ignored')
    Set-Content -LiteralPath (Join-Path $ignoredRepo '.gitignore') -Value 'content/private.md' -NoNewline -Encoding utf8
    & git -C $ignoredRepo add -- .gitignore
    & git -C $ignoredRepo commit --quiet -m 'fixture ignore rule'
    if ($LASTEXITCODE -ne 0) { throw 'fixture ignore commit failed' }
    Set-Content -LiteralPath (Join-Path $ignoredRepo 'content/private.md') -Value 'ignored input' -NoNewline -Encoding utf8
    Throws { Assert-LLPublishRepositoryReady -RepoRoot $ignoredRepo -IgnoredPathspecs @('content') -Label 'fixture' } 'ignored Hugo input is blocked'

    $stageRepo = New-FixtureRepository (Join-Path $tempRoot 'stage allowlist')
    $allowedName = 'content/approved article.md'
    New-Item -ItemType Directory -Path (Join-Path $stageRepo 'content') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stageRepo ($allowedName -replace '/', '\')) -Value 'approved' -NoNewline -Encoding utf8
    & git -C $stageRepo add -- $allowedName
    if ($LASTEXITCODE -ne 0) { throw 'fixture allowed stage failed' }
    $stagedPaths = Assert-LLPublishStagedPathsAllowed -RepoRoot $stageRepo -AllowedPaths @($allowedName) -Label 'fixture'
    $stagedPathArray = @($stagedPaths)
    Check ($stagedPathArray.Count -eq 1 -and $stagedPathArray[0] -eq $allowedName) 'allowed staged path with spaces passes'
    Set-Content -LiteralPath (Join-Path $stageRepo 'content/unapproved.md') -Value 'unapproved' -NoNewline -Encoding utf8
    & git -C $stageRepo add -- content/unapproved.md
    if ($LASTEXITCODE -ne 0) { throw 'fixture unapproved stage failed' }
    Throws { Assert-LLPublishStagedPathsAllowed -RepoRoot $stageRepo -AllowedPaths @($allowedName) -Label 'fixture' } 'unexpected staged path is blocked before commit'

    $allowedRepo = New-FixtureRepository (Join-Path $tempRoot 'repo path allowlist')
    $allowedPath = 'content/selected.md'
    Set-Content -LiteralPath (Join-Path $allowedRepo ($allowedPath -replace '/', '\')) -Value 'selected' -NoNewline -Encoding utf8
    & git -C $allowedRepo add -- $allowedPath
    if ($LASTEXITCODE -ne 0) { throw 'fixture allowlisted stage failed' }
    $allowedState = Assert-LLPublishRepositoryPathsAllowed -RepoRoot $allowedRepo -AllowedPaths @($allowedPath) -Label 'fixture'
    Check (@($allowedState.staged_paths).Count -eq 1 -and $allowedState.staged_paths[0] -eq $allowedPath) 'staged and working paths inside the explicit allowlist pass'
    Set-Content -LiteralPath (Join-Path $allowedRepo 'content/unselected.md') -Value 'unselected' -NoNewline -Encoding utf8
    Throws { Assert-LLPublishRepositoryPathsAllowed -RepoRoot $allowedRepo -AllowedPaths @($allowedPath) -Label 'fixture' } 'unselected working-tree path is blocked by the exact allowlist'

    $destinationRoot = Join-Path $tempRoot 'destination collision cases'
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    $textDestination = Join-Path $destinationRoot 'article.md'
    [System.IO.File]::WriteAllText($textDestination, 'approved body', [System.Text.Encoding]::UTF8)
    $sameText = Get-LLPublishDestinationDisposition -DestinationPath $textDestination -ExpectedContent 'approved body' -Label 'fixture article'
    Check ($sameText -eq 'Unchanged') 'identical existing article is safe to reuse without rewriting'
    Throws { Get-LLPublishDestinationDisposition -DestinationPath $textDestination -ExpectedContent 'different body' -Label 'fixture article' } 'unmarked destination collision with different content is blocked'
    $explicitUpdate = Get-LLPublishDestinationDisposition -DestinationPath $textDestination -ExpectedContent 'different body' -AllowReplace -Label 'fixture article'
    Check ($explicitUpdate -eq 'Replace') 'only explicitly authorized article update may replace a destination'

    $destinationPlan = @{}
    $plannedArticle = Join-Path $destinationRoot 'planned/article.md'
    Check (Add-LLPublishDestinationPlanEntry -Plan $destinationPlan -DestinationPath $plannedArticle -ExpectedContent 'body A' -Label 'fixture selection') 'first selected article destination is registered'
    Check (-not (Add-LLPublishDestinationPlanEntry -Plan $destinationPlan -DestinationPath ($plannedArticle.ToUpperInvariant()) -ExpectedContent 'body A' -Label 'fixture selection')) 'identical duplicate article destinations are recognized case-insensitively'
    Throws { Add-LLPublishDestinationPlanEntry -Plan $destinationPlan -DestinationPath $plannedArticle -ExpectedContent 'body B' -Label 'fixture selection' } 'different selected articles targeting one destination are blocked before writes'

    $assetSource = Join-Path $destinationRoot 'asset-source.bin'
    $assetDestination = Join-Path $destinationRoot 'asset-destination.bin'
    [System.IO.File]::WriteAllBytes($assetSource, [byte[]](1, 2, 3, 4))
    [System.IO.File]::WriteAllBytes($assetDestination, [byte[]](1, 2, 3, 4))
    $sameAsset = Get-LLPublishDestinationDisposition -DestinationPath $assetDestination -ExpectedFilePath $assetSource -Label 'fixture asset'
    Check ($sameAsset -eq 'Unchanged') 'identical existing asset is safe to reuse'
    [System.IO.File]::WriteAllBytes($assetDestination, [byte[]](4, 3, 2, 1))
    Throws { Get-LLPublishDestinationDisposition -DestinationPath $assetDestination -ExpectedFilePath $assetSource -Label 'fixture asset' } 'different existing asset is never overwritten'
    $assetSourceTwo = Join-Path $destinationRoot 'asset-source-two.bin'
    [System.IO.File]::WriteAllBytes($assetSourceTwo, [byte[]](1, 2, 3, 4))
    $assetPlan = @{}
    $plannedAsset = Join-Path $destinationRoot 'planned/shared.bin'
    Check (Add-LLPublishDestinationPlanEntry -Plan $assetPlan -DestinationPath $plannedAsset -ExpectedFilePath $assetSource -Label 'fixture selection') 'first selected asset destination is registered'
    Check (-not (Add-LLPublishDestinationPlanEntry -Plan $assetPlan -DestinationPath $plannedAsset -ExpectedFilePath $assetSourceTwo -Label 'fixture selection')) 'same-byte selected assets may share one destination'
    [System.IO.File]::WriteAllBytes($assetSourceTwo, [byte[]](9, 8, 7, 6))
    Throws { Add-LLPublishDestinationPlanEntry -Plan $assetPlan -DestinationPath $plannedAsset -ExpectedFilePath $assetSourceTwo -Label 'fixture selection' } 'different selected assets targeting one destination are blocked before writes'
    New-Item -ItemType Directory -Path (Join-Path $destinationRoot 'directory-collision') | Out-Null
    Throws { Get-LLPublishDestinationDisposition -DestinationPath (Join-Path $destinationRoot 'directory-collision') -ExpectedContent 'body' -Label 'fixture article' } 'directory at a file destination is blocked'

    $legacyText = Join-Path $destinationRoot 'legacy-encoding.md'
    $newText = Join-Path $destinationRoot 'new-encoding.md'
    [System.IO.File]::WriteAllText($legacyText, "same body`r`n", [System.Text.Encoding]::UTF8)
    $encodingStream = [System.IO.File]::Open($newText, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $encodingWriter = [System.IO.StreamWriter]::new($encodingStream, [System.Text.Encoding]::UTF8)
        try { $encodingWriter.Write("same body`r`n"); $encodingWriter.Flush() } finally { $encodingWriter.Dispose() }
    } finally {
        if ($null -ne $encodingStream) { $encodingStream.Dispose() }
    }
    Check ((Get-FileHash -LiteralPath $legacyText -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $newText -Algorithm SHA256).Hash) 'CreateNew content writer preserves the existing UTF-8 output bytes'

    $nested = Join-Path $cleanRepo 'content'
    Throws { Get-LLPublishGitState -RepoRoot $nested } 'a nested folder cannot masquerade as the repository root'

    $publisherPath = Join-Path $learningLogRoot 'app/run_learninglog_publish.ps1'
    # 발행 로직은 스크립트와 LearningLog.Publish 모듈(배포 단계 등)에 나뉘어 있다. 두 파일을 합쳐 안전 규칙을 검사한다.
    $publisher = (Get-Content -LiteralPath $publisherPath -Raw) + "`n" + (Get-Content -LiteralPath (Join-Path $learningLogRoot 'app/core/LearningLog.Publish.psm1') -Raw)
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($publisherPath, [ref]$tokens, [ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) 'publisher parses after guard integration'
    Check ($publisher -notmatch '(?im)^\s*git(?:\s+-C\s+\S+)?\s+add\s+-A\b') 'publisher no longer stages whole repositories'
    Check ($publisher.Contains('Assert-LLPublishRepositoryReady') -and $publisher.Contains('Assert-LLPublishStagedPathsAllowed')) 'publisher validates clean boundary and staged-path allowlist'
    Check ($publisher.Contains('Invoke-LLPublishGitCapture -RepoRoot $BlogSourceRoot') -and $publisher.Contains('Add-LLPublishPathsToIndex -RepoRoot $PublicDir') -and $publisher.Contains('Add-LLPublishPathsToIndex -RepoRoot $BlogSourceRoot')) 'publisher isolates Git diagnostics and batches only approved paths'
    Check ($publisher.Contains('Get-LLDraftSourceId -Content $RawContent') -and $publisher.Contains('Get-LLApprovalSnapshotStatus') -and $publisher.Contains('승인 당시 파일 해시')) 'direct Publisher resolves unique source identity and enforces approval-time hash'
    Check (-not $publisher.Contains('status --porcelain --untracked-files=all -- content 2>&1')) 'UI content status never mixes Git diagnostics into selection records'

    # 발행은 단계 함수의 호출 순서(사전검사 → 저장소·대상 검사 → 복사 → 배포)로 안전 순서를 보장한다.
    $guardIndex = $publisher.IndexOf('Assert-LLPublishTargetsReady -Ctx', $publisher.IndexOf('발행 보안 사전검사 실패'))
    $copyIndex = $publisher.IndexOf('Invoke-LLPublishCopyStage -Ctx', $guardIndex)
    Check ($guardIndex -ge 0 -and $copyIndex -gt $guardIndex -and $publisher.Contains('Assert-LLPublishRepositoryReady')) 'repository guard runs before approved content is copied'
    $protectedOutputIndex = $publisher.IndexOf('$protectedPublicPaths')
    $publicPushIndex = $publisher.IndexOf('push origin HEAD:main')
    Check ($protectedOutputIndex -ge 0 -and $publicPushIndex -gt $protectedOutputIndex) 'Git control-file output is blocked before public push'

    $destinationPreflightIndex = $publisher.IndexOf('Assert-LLPublishTargetsReady -Ctx')
    $firstCopyIndex = $publisher.IndexOf('Invoke-LLPublishCopyStage -Ctx')
    $hugoBuildIndex = $publisher.IndexOf('Invoke-LLPublishDeploy -Ctx')
    $targetsReadyBodyIndex = $publisher.IndexOf('# 모든 대상 경로를 먼저 검사')   # 대상 충돌 검사는 저장소 준비 단계 함수 안에 있다
    $copyBodyIndex = $publisher.IndexOf('$assetCount = Copy-LLDraftAssets')
    Check ($destinationPreflightIndex -ge 0 -and $firstCopyIndex -gt $destinationPreflightIndex -and $hugoBuildIndex -gt $firstCopyIndex -and $targetsReadyBodyIndex -ge 0 -and $copyBodyIndex -gt $targetsReadyBodyIndex -and $publisher.Contains('& $hugoCmd --cleanDestinationDir')) 'all Publisher destinations are checked before any copy or Hugo build'
    Check ($publisher.Contains('Add-LLPublishDestinationPlanEntry') -and $publisher.Contains('Get-LLPublishDestinationDisposition')) 'Publisher rejects conflicts among selected destinations and existing files'
    Check ($publisher.Contains('[System.IO.FileMode]::CreateNew') -and $publisher.Contains('[System.IO.File]::Copy($sourceFull, $dest, $false)')) 'new content and assets use no-overwrite creation semantics'

    $approvePath=Join-Path $learningLogRoot 'app/run_learninglog_approve.ps1'
    $approveTokens=$null; $approveErrors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($approvePath,[ref]$approveTokens,[ref]$approveErrors)
    Check ($approveErrors.Count -eq 0) 'interactive approval script parses after hash-bound approval integration'
    $approveScript=Get-Content -LiteralPath $approvePath -Raw
    Check ($approveScript.Contains('Get-LLApprovalSnapshotStatus') -and $approveScript.Contains('-ApprovedPath $dest')) 'interactive approval records exact approved file hash and supports explicit reapproval'

    $unpublishPath = Join-Path $learningLogRoot 'app/run_learninglog_unpublish.ps1'
    $unpublish = Get-Content -LiteralPath $unpublishPath -Raw
    $unpublishTokens = $null; $unpublishErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($unpublishPath, [ref]$unpublishTokens, [ref]$unpublishErrors)
    Check ($unpublishErrors.Count -eq 0) 'unpublisher parses after stage-boundary integration'
    Check ($unpublish -notmatch '(?im)^\s*git(?:\s+-C\s+\S+)?\s+add\s+-A\b') 'unpublisher no longer stages whole repositories'
    Check ($unpublish.Contains('Add-LLPublishPathsToIndex -RepoRoot $PublicDir -Paths $publicPaths') -and $unpublish.Contains('Add-LLPublishPathsToIndex -RepoRoot $BlogSourceRoot -Paths $sourcePaths')) 'unpublisher batches only enumerated changed paths'
    $cleanPreflightIndex = $unpublish.IndexOf('Assert-LLPublishRepositoryReady')
    $firstMoveIndex = $unpublish.IndexOf('Move-Item -LiteralPath $h.Path')
    Check ($cleanPreflightIndex -ge 0 -and $firstMoveIndex -gt $cleanPreflightIndex) 'Deploy repository preflight runs before any unpublish file move'
    $publicStageIndex = $unpublish.IndexOf('Add-LLPublishPathsToIndex -RepoRoot $PublicDir -Paths $publicPaths')
    $publicStageCheckIndex = $unpublish.IndexOf('Assert-LLPublishRepositoryPathsAllowed', $publicStageIndex)
    $publicPushIndex = $unpublish.IndexOf('git -C $PublicDir push origin main', $publicStageCheckIndex)
    $sourceStageIndex = $unpublish.IndexOf('Add-LLPublishPathsToIndex -RepoRoot $BlogSourceRoot -Paths $sourcePaths')
    $sourceStageCheckIndex = $unpublish.IndexOf('Assert-LLPublishRepositoryPathsAllowed', $sourceStageIndex)
    $sourcePushIndex = $unpublish.IndexOf('git -C $BlogSourceRoot push', $sourceStageCheckIndex)
    Check ($publicStageIndex -ge 0 -and $publicStageCheckIndex -gt $publicStageIndex -and $publicPushIndex -gt $publicStageCheckIndex) 'public file-specific stage is rechecked before push'
    Check ($sourceStageIndex -ge 0 -and $sourceStageCheckIndex -gt $sourceStageIndex -and $sourcePushIndex -gt $sourceStageCheckIndex) 'blog-source file-specific stage is rechecked before push'

    [pscustomobject]@{ suite='PublishGitGuard'; passed=$script:passed; external_publish=0; production_file_moves=0; temp_fixtures_removed=$true } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
