#Requires -Version 7.0
# 발행(run_learninglog_publish.ps1) 보조 함수. 스크립트 전역 변수에 의존하지 않고 값을 인자로 받는다.
Set-StrictMode -Version Latest

# 장부 기록·해시·경로 헬퍼(Add-LLPublishLedgerEntry, Get-LLHash, Write-LLText 등)는 LocalCore 에 있다.
Import-Module (Join-Path $PSScriptRoot 'LearningLog.LocalCore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'LearningLog.PublishGitGuard.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'LearningLog.PublishPreflight.psm1') -DisableNameChecking

function Get-LLFrontMatterValue {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Key
    )
    $pattern = "(?m)^$([regex]::Escape($Key)):\s*`"?(.+?)`"?\s*$"
    if ($Content -match $pattern) { return $Matches[1].Trim() }
    return ""
}

# 본문이 참조하는 /images/... 경로(저장소 상대 경로, 슬래시)를 돌려준다. 상위 경로·절대 경로는 거부한다.
function Get-LLDraftAssetPaths {
    param([Parameter(Mandatory)][string]$Content)

    $refs = @([regex]::Matches($Content, '!\[[^\]]*\]\((/images/[^)\s]+)\)') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($ref in $refs) {
        $relative = [Uri]::UnescapeDataString($ref.TrimStart("/")) -replace '\\', '/'
        if ($relative -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($relative)) {
            throw "허용되지 않은 이미지 경로: $ref"
        }
        $paths.Add($relative)
    }
    return $paths.ToArray()
}

# Hugo 실행 파일 위치: 허브 공용 portable_kit → PATH → winget 설치본. 없으면 빈 문자열.
function Get-LLHugoCommandPath {
    param([Parameter(Mandatory)][string]$BlogRoot)

    # 1) 허브 공용 portable_kit\tools\hugo.exe
    $localHugo = Join-Path (Split-Path $BlogRoot -Parent) "portable_kit\tools\hugo.exe"
    if (Test-Path -LiteralPath $localHugo) { return $localHugo }

    # 2) PATH
    $cmd = Get-Command hugo -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 3) winget 설치본 (Hugo.Hugo.Extended) — 현재 사용자 기준
    $knownRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $knownRoot) {
        $found = Get-ChildItem -LiteralPath $knownRoot -Recurse -Filter "hugo.exe" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*Hugo.Hugo.Extended*" } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return ""
}

# 승인본 하나의 발행 계획. "발행됨" = content 복사본 + 06_published 표식이 둘 다 있을 때만.
# 06_published 는 배포(빌드+푸시) 성공 후에만 기록되므로, 빌드/푸시 실패로 복사만 된 글은 다음 실행에서 다시 신규로 잡힌다.
function New-LLPublishPlan {
    param(
        [Parameter(Mandatory)]$Draft,
        [Parameter(Mandatory)][string]$ReadyRoot,
        [Parameter(Mandatory)][string]$BlogRoot,
        [Parameter(Mandatory)][string]$PublishedDir
    )

    $rel = $Draft.FullName.Replace($ReadyRoot + "\", "").Replace("\", "/")
    $section = ($rel -split "/")[0]
    $fname = $Draft.Name
    $destDir = Join-Path $BlogRoot "content\$section"
    $destPath = Join-Path $destDir $fname
    $pubMarker = Join-Path $PublishedDir $fname
    $isUpdate = (Test-Path -LiteralPath $destPath) -and (Test-Path -LiteralPath $pubMarker)

    return [pscustomobject]@{
        Draft = $Draft
        Rel = $rel
        Section = $section
        FileName = $fname
        DestDir = $destDir
        DestPath = $destPath
        IsUpdate = $isUpdate
    }
}

# -Section 필터(소문자 비교). 필터가 비어 있으면 항상 true.
function Test-LLPublishSection {
    param(
        [Parameter(Mandatory)]$Draft,
        [Parameter(Mandatory)][string]$ReadyRoot,
        [string]$SectionFilter = ''
    )
    if (-not $SectionFilter) { return $true }
    $rel = $Draft.FullName.Replace($ReadyRoot + "\", "").Replace("\", "/")
    $sectionName = (($rel -split "/")[0]).ToLowerInvariant()
    return ($sectionName -eq $SectionFilter)
}


# 발행 한 번(시도)의 공유 상태. 스크립트 전역 변수($script:*) 대신 이 객체를 함수에 넘긴다.
function New-LLPublishContext {
    param([scriptblock]$ResolveRow = { param($Draft) $null })
    return [pscustomobject]@{
        AttemptId            = [guid]::NewGuid().ToString('N')
        TrashRunRoot         = ''                                           # 실패 시 새로 만든 사본을 옮길 .trash 경로(호출부가 설정)
        AttemptHashes        = @{}                                          # 승인본 경로 -> sha256
        OutcomeRecorded      = $false
        PublicStageAttempted = $false
        PublicCommitAttempted = $false
        PublicCommitCompleted = $false
        PublicPushAttempted  = $false
        LivePushCompleted    = $false
        CreatedArtifacts     = [System.Collections.Generic.List[object]]::new()
        TargetPlans          = [System.Collections.Generic.List[object]]::new()
        PreflightCache       = @{}
        ResolveRow           = $ResolveRow                                  # 초안 -> registry 행
    }
}

# 공개 저장소(public) Git 상태가 바뀌었을 수 있는 단계에 들어갔는가.
function Test-LLPublishGitTouched {
    param([Parameter(Mandatory)]$Ctx)
    return [bool]($Ctx.PublicStageAttempted -or $Ctx.PublicCommitAttempted -or $Ctx.PublicCommitCompleted -or $Ctx.PublicPushAttempted -or $Ctx.LivePushCompleted)
}

function Move-LLPublishArtifactsToTrash {
    param([Parameter(Mandatory)]$Ctx)
    $moved = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    if (Test-LLPublishGitTouched -Ctx $Ctx) {
        return [pscustomobject]@{ moved=@(); skipped=@('공개 저장소 Git 상태가 바뀌었을 수 있어 자동 정리를 보류했습니다.') }
    }
    $trashRunRoot = $Ctx.TrashRunRoot
    $trashPrefix = [IO.Path]::GetFullPath($trashRunRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($artifact in $Ctx.CreatedArtifacts) {
        if (-not (Test-Path -LiteralPath $artifact.full_path -PathType Leaf)) { continue }
        if ((Get-LLHash $artifact.full_path) -ine $artifact.sha256) {
            $skipped.Add("$($artifact.repo_path): 복사 후 파일이 바뀌어 보존")
            continue
        }
        $relative = ([string]$artifact.repo_path).Replace('\','/')
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Split('/') -contains '..') {
            $skipped.Add("$($artifact.repo_path): 저장소 밖 경로라 보존")
            continue
        }
        $destination = Join-Path $trashRunRoot ($relative -replace '/', [string][IO.Path]::DirectorySeparatorChar)
        if (-not [IO.Path]::GetFullPath($destination).StartsWith($trashPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $skipped.Add("$($artifact.repo_path): 휴지통 경계를 벗어나 보존")
            continue
        }
        if (Test-Path -LiteralPath $destination) {
            $skipped.Add("$($artifact.repo_path): 휴지통 목적지 충돌로 보존")
            continue
        }
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        try {
            [IO.File]::Move($artifact.full_path, $destination)
            $moved.Add("$($artifact.repo_path) -> $(Get-LLRelativePath $destination)")
        } catch { $skipped.Add("$($artifact.repo_path): $($_.Exception.Message)") }
    }
    if ($moved.Count -gt 0 -or $skipped.Count -gt 0) {
        $manifest = [ordered]@{
            version=1; disposition='retryable_publish_failure_cleanup'; attempt_id=$Ctx.AttemptId
            created_at=[DateTimeOffset]::Now.ToString('o'); moved=@($moved); skipped=@($skipped)
            ready_approvals_preserved=$true; published_content_touched=$false
        }
        Write-LLText -Path (Join-Path $trashRunRoot '_cleanup.json') -Content (ConvertTo-Json $manifest -Depth 4)
    }
    return [pscustomobject]@{ moved=@($moved); skipped=@($skipped) }
}

function Write-LLPublishAttemptOutcome {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Status,
        [string]$FailureCode = '',
        [string]$Message = '',
        [string]$PublishedDate = '',
        [string[]]$CleanupPaths = @()
    )
    if ($Ctx.OutcomeRecorded) { return }
    foreach ($targetPlan in $Ctx.TargetPlans) {
        $relative = [string]$targetPlan.Rel
        $sourceId = ''
        if ($Ctx.PreflightCache.ContainsKey($targetPlan.Draft.FullName)) {
            $sourceId = Get-LLProp $Ctx.PreflightCache[$targetPlan.Draft.FullName].SourceRow 'source_id'
        } else {
            $row = & $Ctx.ResolveRow $targetPlan.Draft
            if ($null -ne $row) { $sourceId = Get-LLProp $row 'source_id' }
        }
        $contentHash = ''
        if ($Ctx.PreflightCache.ContainsKey($targetPlan.Draft.FullName)) {
            $contentHash = [string]$Ctx.PreflightCache[$targetPlan.Draft.FullName].DraftSha256
        } elseif ($Ctx.AttemptHashes.ContainsKey($targetPlan.Draft.FullName)) {
            $contentHash = [string]$Ctx.AttemptHashes[$targetPlan.Draft.FullName]
        } else {
            $contentHash = Get-LLHash $targetPlan.Draft.FullName
        }
        $null = Add-LLPublishLedgerEntry `
            -DraftPath ('05_ready_to_publish/' + $relative) `
            -HugoTargetPath ('content/' + $targetPlan.Section + '/' + $targetPlan.FileName) `
            -PublishedDate $PublishedDate -PublicUrl '' -Status $Status -SourceId $sourceId `
            -ContentSha256 $contentHash -FailureCode $FailureCode -Message $Message `
            -CleanupPaths $CleanupPaths -AttemptId $Ctx.AttemptId
    }
    $Ctx.OutcomeRecorded = $true
}

function Write-LLPublishAbortHint {
    param([Parameter(Mandatory)]$Ctx, [string]$FailureCode = 'publish_aborted', [string]$Message = '')
    $cleanupPaths = @()
    if (-not $Ctx.OutcomeRecorded) {
        $status = if (Test-LLPublishGitTouched -Ctx $Ctx) { 'reconcile_required' } else { 'retryable_failed' }
        if ($status -eq 'retryable_failed') {
            $cleanup = Move-LLPublishArtifactsToTrash -Ctx $Ctx
            $cleanupPaths = @($cleanup.moved)
            if (@($cleanup.skipped).Count) { $Message = (($Message + ' · 정리 보류: ' + (@($cleanup.skipped) -join '; ')).Trim(' ', '·')) }
        }
        Write-LLPublishAttemptOutcome -Ctx $Ctx -Status $status -FailureCode $FailureCode -Message $Message -CleanupPaths $cleanupPaths
    }
    Write-Host ""
    if (Test-LLPublishGitTouched -Ctx $Ctx) {
        Write-Host "  공개 저장소 Git 상태와 라이브 반영 여부를 대조해야 합니다. 자동 정리·재발행을 멈추고 publish_ledger.csv에 reconcile_required로 기록했습니다." -ForegroundColor Yellow
    } else {
        Write-Host "  실패 원인을 publish_ledger.csv에 기록했습니다. 승인본은 보존되어 다시 시도할 수 있습니다." -ForegroundColor Yellow
        if ($cleanupPaths.Count) { Write-Host ("  이번 시도에서 새로 만든 미발행 사본은 .trash 로 이동했습니다: {0}" -f ($cleanupPaths -join ', ')) -ForegroundColor DarkGray }
    }
}



# 발행 전 모든 선택 파일을 먼저 검사한다(해시·registry·정책·Preflight·품질). 통과한 것만 $Ctx.PreflightCache 에 담고,
# 실패 사유 목록을 돌려준다. 한 건이라도 있으면 호출부가 복사·빌드·푸시 전에 전체 선택을 중단한다.
function Invoke-LLPublishPreflightStage {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$ReadyRoot,
        [Parameter(Mandatory)][string]$DraftAssetRoot,
        [Parameter(Mandatory)]$Rows,
        $Selection = $null,
        [switch]$IncludePublished
    )
    $preflightFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($targetPlan in $Ctx.TargetPlans) {
        $draft = $targetPlan.Draft
        $relative = $draft.FullName.Substring(($ReadyRoot.TrimEnd('\') + '\').Length).Replace('\', '/')
        try {
            $expectedHash = ''
            if ($Selection) {
                $selectedFile = @($selection.files | Where-Object { ([string]$_.path) -ceq $relative })
                if ($selectedFile.Count -ne 1) { throw 'selection_entry_missing' }
                $expectedHash = [string]$selectedFile[0].hash
                $ctx.AttemptHashes[$draft.FullName] = $expectedHash.ToLowerInvariant()
            }
            $rawHashBefore = Get-LLHash $draft.FullName
            if (-not $ctx.AttemptHashes.ContainsKey($draft.FullName) -and $rawHashBefore) {
                $ctx.AttemptHashes[$draft.FullName] = $rawHashBefore.ToLowerInvariant()
            }
            $raw = [System.IO.File]::ReadAllText($draft.FullName, [System.Text.Encoding]::UTF8)
            $rawHashAfter = Get-LLHash $draft.FullName
            if (-not $rawHashBefore -or $rawHashBefore -ine $rawHashAfter) { throw 'draft_changed_during_preflight_read' }
            $ctx.AttemptHashes[$draft.FullName] = $rawHashAfter.ToLowerInvariant()
            $sourceRow = Find-LLDraftRegistryRow -DraftName $draft.Name -RawContent $raw -Rows $Rows
            $processed = ConvertTo-LLPublishedPost -Content $raw
            $registryStatus = ''
            $publicPolicy = ''
            $sourceCategory = ''
            if ($null -ne $sourceRow) {
                $registryStatus = Get-LLProp $sourceRow 'status'
                $publicPolicy = Get-LLProp $sourceRow 'public_policy'
                $sourceCategory = Get-LLProp $sourceRow 'source_category'
            }
            $preflight = Invoke-LLPublishPreflight `
                -Path $draft.FullName `
                -ReadyRoot $ReadyRoot `
                -ExpectedSha256 $expectedHash `
                -RegistryStatus $registryStatus `
                -PublicPolicy $publicPolicy `
                -SourceCategory $sourceCategory `
                -OriginalContent $raw `
                -Content $processed `
                -DraftAssetRoot $DraftAssetRoot `
                -AllowPublished:$IncludePublished
            if ($preflight.status -ne 'PASS') {
                $codes = @($preflight.findings | ForEach-Object code) -join ', '
                $preflightFailures.Add("$relative [$($preflight.status)]: $codes")
                continue
            }
            $quality = Test-LLDraftQualityGate -DraftName $draft.Name -RawContent $processed -SourceRow $sourceRow
            if (-not $quality.Ok) {
                $preflightFailures.Add("$relative [FAIL]: draft_quality_gate")
                continue
            }
            $Ctx.PreflightCache[$draft.FullName] = [pscustomobject]@{
                Raw = $raw
                DraftSha256 = $rawHashAfter.ToLowerInvariant()
                SourceRow = $sourceRow
                Processed = $processed
                Result = $preflight
            }
        } catch {
            $preflightFailures.Add("$relative [FAIL]: preflight_execution_error")
        }
    }
    return ,$preflightFailures
}

# 복사 전 검사: Hugo 입력 저장소(blog-source)·public 의 기존 변경이 이번 선택본 외에 섞이지 않았는지, 모든 대상 경로에 충돌이 없는지 본다.
# 실패하면 이유를 장부에 남기고 ExitCode 가 0 이 아닌 결과를 돌려준다.
function Assert-LLPublishTargetsReady {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$BlogSourceRoot,
        [Parameter(Mandatory)][string]$DraftAssetRoot
    )
    # Hugo 입력 저장소의 기존 변경은 이번 선택본/참조 이미지 외에는 발행에 섞지 않는다.
    # public은 Hugo가 --cleanDestinationDir로 비우므로 시작 시 사용자 파일이 있으면 먼저 중단한다.
    $allowedSourcePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($targetPlan in $Ctx.TargetPlans) {
        $null = $allowedSourcePaths.Add("content/$($targetPlan.Section)/$($targetPlan.FileName)")
        $processed = [string]$Ctx.PreflightCache[$targetPlan.Draft.FullName].Processed
        foreach ($assetPath in (Get-LLDraftAssetPaths -Content $processed)) {
            $null = $allowedSourcePaths.Add("static/$assetPath")
        }
    }
    $null = $allowedSourcePaths.Add('public') # 별도 검사하는 public submodule의 gitlink만 허용
    $hugoInputPathspecs = Get-LLHugoInputPathspecs
    $PublicDir = Join-Path $BlogSourceRoot 'public'
    try {
        $null = Assert-LLPublishRepositoryReady `
            -RepoRoot $BlogSourceRoot `
            -AllowedWorkingPaths @($allowedSourcePaths | ForEach-Object { $_ }) `
            -IgnoredPathspecs $hugoInputPathspecs `
            -Label 'blog-source'
        $null = Assert-LLPublishRepositoryReady `
            -RepoRoot $PublicDir `
            -AllowedWorkingPaths @() `
            -IgnoredPathspecs @('.') `
            -Label 'public'
    } catch {
        $message = $_.Exception.Message
        Write-Host ("  [ERROR] 발행 저장소 사전 확인 실패: {0}" -f $message) -ForegroundColor Red
        Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'repository_not_ready' -Message $message
        return [pscustomobject]@{ ExitCode = 1 }
    }

    # 모든 대상 경로를 먼저 검사해 충돌 하나 때문에 앞선 선택본만 복사되는 부분 발행을 막는다.
    $plannedDestinations = @{}
    try {
    foreach ($targetPlan in $Ctx.TargetPlans) {
        $processed = [string]$Ctx.PreflightCache[$targetPlan.Draft.FullName].Processed
        $null = Add-LLPublishDestinationPlanEntry `
            -Plan $plannedDestinations `
            -DestinationPath $targetPlan.DestPath `
            -ExpectedContent $processed `
            -Label '블로그 본문'
        $null = Get-LLPublishDestinationDisposition `
            -DestinationPath $targetPlan.DestPath `
            -ExpectedContent $processed `
            -AllowReplace:$targetPlan.IsUpdate `
            -Label '블로그 본문'

        foreach ($assetPath in (Get-LLDraftAssetPaths -Content $processed)) {
            $relative = $assetPath -replace '/', '\'
            $assetSource = Join-Path $DraftAssetRoot $relative
            if (-not (Test-Path -LiteralPath $assetSource -PathType Leaf)) {
                throw "초안 이미지 없음: /images/$assetPath"
            }
            $assetSourceFull = (Resolve-Path -LiteralPath $assetSource).Path
            $assetRootFull = (Resolve-Path -LiteralPath $DraftAssetRoot).Path.TrimEnd('\') + '\'
            if (-not $assetSourceFull.StartsWith($assetRootFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "초안 이미지 저장소 밖의 경로: $assetPath"
            }
            $assetDestination = Join-Path (Join-Path $BlogSourceRoot 'static') $relative
            $null = Add-LLPublishDestinationPlanEntry `
                -Plan $plannedDestinations `
                -DestinationPath $assetDestination `
                -ExpectedFilePath $assetSourceFull `
                -Label '블로그 이미지'
            $null = Get-LLPublishDestinationDisposition `
                -DestinationPath $assetDestination `
                -ExpectedFilePath $assetSourceFull `
                -Label '블로그 이미지'
        }
    }
    } catch {
        $message = $_.Exception.Message
        Write-Host ("  [ERROR] 발행 대상 파일 확인 실패: {0}" -f $message) -ForegroundColor Red
        Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'destination_preflight_failed' -Message $message
        return [pscustomobject]@{ ExitCode = 1 }
    }

    return [pscustomobject]@{ ExitCode = 0 }
}

# Hugo 입력으로 취급하는 blog-source 경로(저장소 준비 검사와 배포 단계가 함께 쓴다).
function Get-LLHugoInputPathspecs {
    return @('content', 'static', 'assets', 'layouts', 'data', 'i18n', 'archetypes', 'config', 'themes', 'hugo.toml', 'hugo.yaml', 'hugo.json')
}

# 승인본을 blog-source(content·static)에 복사한다. 새로 만든 파일은 $Ctx.CreatedArtifacts 에 기록해 실패 시 정리할 수 있게 하고,
# 배포 성공 후에만 남길 기록은 $PendingRecords 에 대기시킨다. 제외된 대상은 $SkippedTargets, 실패한 대상은 $Errors 에 쌓는다.
function Invoke-LLPublishCopyStage {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$BlogSourceRoot,
        [Parameter(Mandatory)][string]$DraftAssetRoot,
        [Parameter(Mandatory)]$SkippedTargets,
        [Parameter(Mandatory)]$Errors,
        [Parameter(Mandatory)]$PendingRecords,
        [Parameter(Mandatory)]$SourcePathsToStage
    )
    $publishedCount = 0
    $publishedNewCount = 0
    $publishedUpdateCount = 0
    foreach ($targetPlan in $Ctx.TargetPlans) {
        $draft   = $targetPlan.Draft
        $rel     = $targetPlan.Rel
        $section = $targetPlan.Section
        $fname   = $targetPlan.FileName

        Write-Host ""
        Write-Host ("  >> {0}" -f $rel) -ForegroundColor Magenta

        # 대상 경로
        $destDir  = $targetPlan.DestDir
        $destPath = $targetPlan.DestPath

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        try {
            $preflightData = $Ctx.PreflightCache[$draft.FullName]
            $raw = $preflightData.Raw
            $sourceRow = $preflightData.SourceRow
            if ($null -ne $sourceRow -and -not (Test-LLPublishableSource $sourceRow)) {
                Write-Host ("     [SKIP] publish policy gate: {0}/{1}" -f $sourceRow.source_id, $sourceRow.public_policy) -ForegroundColor Yellow
                $SkippedTargets.Add("$rel : publish policy gate")
                continue
            }
            # front matter 처리 및 publish 직전 검수
            $processed = $preflightData.Processed
            $quality = Test-LLDraftQualityGate -DraftName $fname -RawContent $processed -SourceRow $sourceRow
            if (-not $quality.Ok) {
                Write-Host ("     [SKIP] quality gate: {0}" -f $quality.Reason) -ForegroundColor Yellow
                $SkippedTargets.Add("$rel : $($quality.Reason)")
                continue
            }

            $assetCount = Copy-LLDraftAssets -Content $processed -DraftAssetRoot $DraftAssetRoot -BlogRoot $BlogSourceRoot -CreatedArtifacts $Ctx.CreatedArtifacts
            if ($assetCount -gt 0) {
                Write-Host ("     이미지: {0}개 -> blog-source\\static\\images" -f $assetCount) -ForegroundColor Green
            }

            $disposition = Get-LLPublishDestinationDisposition `
                -DestinationPath $destPath `
                -ExpectedContent $processed `
                -AllowReplace:$targetPlan.IsUpdate `
                -Label '블로그 본문'
            if ($disposition -eq 'Create') {
                $stream = [System.IO.File]::Open($destPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
                    try { $writer.Write($processed); $writer.Flush() } finally { $writer.Dispose() }
                } finally {
                    if ($null -ne $stream) { $stream.Dispose() }
                }
                $Ctx.CreatedArtifacts.Add([pscustomobject]@{
                    full_path=$destPath; repo_path=("content/$section/$fname"); sha256=(Get-LLHash $destPath)
                })
                Write-Host ("     복사: {0}" -f $destPath.Replace($BlogSourceRoot, "blog-source")) -ForegroundColor Green
            } elseif ($disposition -eq 'Replace') {
                [System.IO.File]::WriteAllText($destPath, $processed, [System.Text.Encoding]::UTF8)
                Write-Host ("     갱신: {0}" -f $destPath.Replace($BlogSourceRoot, "blog-source")) -ForegroundColor Green
            } else {
                Write-Host ("     기존 승인 내용 확인: {0}" -f $destPath.Replace($BlogSourceRoot, "blog-source")) -ForegroundColor DarkGray
            }

            # source_id가 없는 daily 합본은 파일명/topic 매칭으로 registry 업데이트
            $sid = ""
            $raw | Select-String "source_id:\s*(\S+)" | ForEach-Object {
                $sid = $_.Matches[0].Groups[1].Value.Trim()
            }
            if (-not $sid -and $null -ne $sourceRow) {
                $sid = Get-LLProp $sourceRow "source_id"
            }

            # 06_published 표식과 registry published 기록은 배포 성공 후로 미룬다.
            # 여기서 바로 기록하면 빌드/푸시 실패 시 "발행됨"으로 오판되는 상태가 남는다.
            $PendingRecords.Add([pscustomobject]@{
                FileName  = $fname
                Processed = $processed
                SourceId  = $sid
            })
            $null = $SourcePathsToStage.Add("content/$section/$fname")
            foreach ($assetPath in (Get-LLDraftAssetPaths -Content $processed)) {
                $null = $SourcePathsToStage.Add("static/$assetPath")
            }

            $publishedCount++
            if ($targetPlan.IsUpdate) { $publishedUpdateCount++ } else { $publishedNewCount++ }

        } catch {
            Write-Host ("     [ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
            $Errors.Add($rel)
        }
    }
    return [pscustomobject]@{ Published = $publishedCount; New = $publishedNewCount; Updated = $publishedUpdateCount }
}
# 배포 단계: Hugo 빌드 → public(라이브) 푸시 → blog-source 푸시 → 발행 기록. (STRUCTURE.md 5장 순서)
# 실패하면 이유를 장부에 남기고 ExitCode 가 0 이 아닌 결과를 돌려준다. 호출부가 그 코드로 종료한다.
function Invoke-LLPublishDeploy {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$BlogSourceRoot,
        [Parameter(Mandatory)][string]$PublishedDir,
        [Parameter(Mandatory)]$SourcePathsToStage,
        [Parameter(Mandatory)][string[]]$HugoInputPathspecs,
        [Parameter(Mandatory)]$PendingRecords,
        [Parameter(Mandatory)]$Errors,
        [Parameter(Mandatory)][int]$PublishedCount,
        [Parameter(Mandatory)][string]$TodayStr,
        [string]$SiteUrlHint = '',
        [switch]$NonInteractive
    )
    $deployOk = $false
    $PublicDir = Join-Path $BlogSourceRoot "public"

    # hugo CLI 확인
    $hugoCmd = Get-LLHugoCommandPath -BlogRoot $BlogSourceRoot
    if (-not $hugoCmd) {
        Write-Host ""
        Write-Host "  [ERROR] hugo 명령을 찾을 수 없습니다. Hugo 설치/PATH 확인 필요." -ForegroundColor Red
        Write-Host "  글은 05_ready_to_publish → content 로 복사됐지만 라이브 배포는 건너뜁니다." -ForegroundColor Yellow
        Write-Host "  수동 배포: STRUCTURE.md 5장 참고" -ForegroundColor DarkGray
        Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'hugo_missing' -Message 'Hugo 실행 파일을 찾지 못했습니다.'
        return [pscustomobject]@{ ExitCode = 1; Deployed = $false }
    } else {
        # ── 1. Hugo 빌드 → public/ 에 HTML 생성 ──
        Write-Host ""
        Write-Host "  [1/3] Hugo 빌드 중..." -ForegroundColor Cyan
        if ($NonInteractive) { Set-LLJobStage -Job publish -Index 2 -Total 4 -Key publish_build -Label '블로그 빌드' }
        Push-Location $BlogSourceRoot
        & $hugoCmd --cleanDestinationDir --logLevel warn | Out-Host
        $hugoExit = $LASTEXITCODE
        Pop-Location

        if ($hugoExit -ne 0) {
            Write-Host "  [ERROR] Hugo 빌드 실패 (exit $hugoExit). 배포 중단." -ForegroundColor Red
            Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'hugo_build_failed' -Message "Hugo 빌드가 종료 코드 $hugoExit 로 실패했습니다."
            return [pscustomobject]@{ ExitCode = $hugoExit; Deployed = $false }
        } else {
            Write-Host "  Hugo 빌드 완료" -ForegroundColor Green

            # hugo --cleanDestinationDir 가 public 서브모듈의 .git 포인터 파일을 지운다.
            # 포인터가 없으면 public 안의 git 명령이 "unpopulated submodule"로 전부 실패하므로
            # 빌드 직후 반드시 복원한다. (2026-07-20 발행 불능 사건)
            $publicGitPointer = Join-Path $PublicDir ".git"
            if (-not (Test-Path -LiteralPath $publicGitPointer)) {
                Set-Content -LiteralPath $publicGitPointer -Value 'gitdir: ../.git/modules/public' -NoNewline -Encoding ascii
                Write-Host "  public\.git 포인터 복원됨 (cleanDestinationDir 삭제 대응)" -ForegroundColor DarkGray
            }

            # Hugo 실행 중 다른 입력/산출물이 섞였거나 기존 stage가 생기면 라이브 푸시 전에 차단한다.
            $allowedBlogStagePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($sourcePath in $sourcePathsToStage) { $null = $allowedBlogStagePaths.Add($sourcePath) }
            $null = $allowedBlogStagePaths.Add('public')
            try {
                $null = Assert-LLPublishRepositoryReady `
                    -RepoRoot $BlogSourceRoot `
                    -AllowedWorkingPaths @($allowedBlogStagePaths | ForEach-Object { $_ }) `
                    -IgnoredPathspecs $hugoInputPathspecs `
                    -Label 'blog-source'
                $publicState = Get-LLPublishGitState -RepoRoot $PublicDir -IgnoredPathspecs @('.')
                if (@($publicState.staged_paths).Count -gt 0) {
                    throw "public 저장소에 stage 변경이 있어 발행을 중단합니다: $(Format-LLPublishPaths $publicState.staged_paths)"
                }
                if (@($publicState.ignored_paths).Count -gt 0) {
                    throw "public 저장소에 무시된 빌드 파일이 있어 발행을 중단합니다: $(Format-LLPublishPaths $publicState.ignored_paths)"
                }
                $publicPaths = @($publicState.working_paths)
                $protectedPublicPaths = @($publicPaths | Where-Object { $_ -match '(^|/)\.git(?:ignore|modules|attributes)$|(^|/)\.github(?:/|$)' })
                if ($protectedPublicPaths.Count -gt 0) {
                    throw "Hugo 산출물에 Git 운영 파일이 포함되어 발행을 중단합니다: $(Format-LLPublishPaths $protectedPublicPaths)"
                }
            } catch {
                Write-Host ("  [ERROR] Git 발행 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'git_boundary_failed' -Message $_.Exception.Message
                return [pscustomobject]@{ ExitCode = 1; Deployed = $false }
            }

            # ── 2. 라이브 사이트(public submodule) 먼저 푸시 ──
            Write-Host "  [2/3] 라이브 사이트(public) 푸시 중..." -ForegroundColor Cyan
            if ($NonInteractive) { Set-LLJobStage -Job publish -Index 3 -Total 4 -Key publish_live -Label '라이브 배포' }
            if ($publicPaths.Count -gt 0) {
                try {
                    $ctx.PublicStageAttempted = $true
                    $null = Add-LLPublishPathsToIndex -RepoRoot $PublicDir -Paths $publicPaths
                } catch {
                    Write-Host ("  [ERROR] public 허용 파일 stage 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'public_stage_failed' -Message $_.Exception.Message
                    return [pscustomobject]@{ ExitCode = 1; Deployed = $false }
                }
            }
            try {
                $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $PublicDir -AllowedPaths $publicPaths -Label 'public'
            } catch {
                Write-Host ("  [ERROR] public stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'public_stage_boundary_failed' -Message $_.Exception.Message
                return [pscustomobject]@{ ExitCode = 1; Deployed = $false }
            }
            git -C $PublicDir diff --cached --quiet
            $pubDiffExit = $LASTEXITCODE
            if ($pubDiffExit -gt 1) {
                Write-Host "  [ERROR] public stage 상태 확인 실패" -ForegroundColor Red
                Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'public_stage_status_failed' -Message "git diff --cached 종료 코드 $pubDiffExit"
                return [pscustomobject]@{ ExitCode = $pubDiffExit; Deployed = $false }
            }
            $pubHasNoStagedChanges = ($pubDiffExit -eq 0)
            if ($pubHasNoStagedChanges) {
                Write-Host "  public 커밋할 변경 없음" -ForegroundColor DarkGray
            } else {
                try {
                    $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $PublicDir -AllowedPaths $publicPaths -Label 'public'
                } catch {
                    Write-Host ("  [ERROR] public 커밋 직전 stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'public_precommit_boundary_failed' -Message $_.Exception.Message
                    return [pscustomobject]@{ ExitCode = 1; Deployed = $false }
                }
                $ctx.PublicCommitAttempted = $true
                git -C $PublicDir commit -m "LearningLog publish: $publishedCount posts ($TodayStr)" 2>&1 | Out-Host
                $pubCommit = $LASTEXITCODE
                if ($pubCommit -ne 0) {
                    Write-Host "  [ERROR] public 커밋 실패" -ForegroundColor Red
                    Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'public_commit_failed' -Message "public git commit 종료 코드 $pubCommit"
                    return [pscustomobject]@{ ExitCode = $pubCommit; Deployed = $false }
                }
                $ctx.PublicCommitCompleted = $true
            }
            # 서브모듈은 detached HEAD 로 체크아웃되므로 로컬 main 이 안 움직인다.
            # HEAD:main 으로 밀어야 현재 커밋이 실제 라이브(origin/main)에 반영된다.
            $ctx.PublicPushAttempted = $true
            git -C $PublicDir push origin HEAD:main | Out-Host
            $pubPush = $LASTEXITCODE
            if ($pubPush -eq 0) { $ctx.LivePushCompleted = $true; Write-Host "  라이브 사이트 푸시 완료" -ForegroundColor Green }
            else {
                Write-Host "  [ERROR] public 푸시 실패" -ForegroundColor Red
                Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'public_push_uncertain' -Message "public push 종료 코드 $pubPush. 원격 반영 여부를 대조해야 합니다."
                return [pscustomobject]@{ ExitCode = $pubPush; Deployed = $false }
            }

            # ── 3. 소스 백업 푸시 ──
            Write-Host "  [3/3] 소스(blog-source) 백업 푸시 중..." -ForegroundColor Cyan
            if ($NonInteractive) { Set-LLJobStage -Job publish -Index 4 -Total 4 -Key publish_record -Label '소스 백업·발행 기록' }
            $sourceStagePaths = @($sourcePathsToStage | ForEach-Object { $_ }) + @('public') | Select-Object -Unique
            try {
                $null = Assert-LLPublishRepositoryReady `
                    -RepoRoot $BlogSourceRoot `
                    -AllowedWorkingPaths $sourceStagePaths `
                    -IgnoredPathspecs $hugoInputPathspecs `
                    -Label 'blog-source'
                $null = Add-LLPublishPathsToIndex -RepoRoot $BlogSourceRoot -Paths $sourceStagePaths
                $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $BlogSourceRoot -AllowedPaths $sourceStagePaths -Label 'blog-source'
            } catch {
                Write-Host ("  [ERROR] blog-source stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'source_stage_boundary_failed' -Message $_.Exception.Message
                return [pscustomobject]@{ ExitCode = 1; Deployed = $false }
            }
            git -C $BlogSourceRoot diff --cached --quiet
            $sourceDiffExit = $LASTEXITCODE
            if ($sourceDiffExit -gt 1) {
                Write-Host "  [ERROR] blog-source stage 상태 확인 실패" -ForegroundColor Red
                Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'source_stage_status_failed' -Message "blog-source git diff --cached 종료 코드 $sourceDiffExit"
                return [pscustomobject]@{ ExitCode = $sourceDiffExit; Deployed = $false }
            }
            $sourceHasNoStagedChanges = ($sourceDiffExit -eq 0)
            if ($sourceHasNoStagedChanges) {
                Write-Host "  blog-source 커밋할 변경 없음" -ForegroundColor DarkGray
            } else {
                try {
                    $null = Assert-LLPublishStagedPathsAllowed -RepoRoot $BlogSourceRoot -AllowedPaths $sourceStagePaths -Label 'blog-source'
                } catch {
                    Write-Host ("  [ERROR] blog-source 커밋 직전 stage 경계 검사 실패: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'source_precommit_boundary_failed' -Message $_.Exception.Message
                    return [pscustomobject]@{ ExitCode = 1; Deployed = $false }
                }
                git -C $BlogSourceRoot commit -m "LearningLog source: $publishedCount posts ($TodayStr)" 2>&1 | Out-Host
                $sourceCommit = $LASTEXITCODE
                if ($sourceCommit -ne 0) {
                    Write-Host "  [ERROR] blog-source 커밋 실패" -ForegroundColor Red
                    Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'source_commit_failed_after_live_push' -Message "라이브 공개는 성공했지만 blog-source 커밋이 종료 코드 $sourceCommit 로 실패했습니다."
                    return [pscustomobject]@{ ExitCode = $sourceCommit; Deployed = $false }
                }
            }
            git -C $BlogSourceRoot push | Out-Host
            $sourcePush = $LASTEXITCODE
            if ($sourcePush -ne 0) {
                Write-Host "  [ERROR] blog-source 푸시 실패" -ForegroundColor Red
                Write-LLPublishAbortHint -Ctx $ctx -FailureCode 'source_push_failed_after_live_push' -Message "라이브 공개는 성공했지만 blog-source push가 종료 코드 $sourcePush 로 실패했습니다."
                return [pscustomobject]@{ ExitCode = $sourcePush; Deployed = $false }
            }
            Write-Host "  소스 백업 완료" -ForegroundColor Green
            $deployOk = $true

            # 두 push가 성공한 뒤 published 파일, registry, 발행 원장을 각각 기록한다.
            # 어느 한 로컬 기록이 실패해도 나머지 성공 표식이 중복 재발행을 막는다.
            $publicationRecordErrors = [System.Collections.Generic.List[string]]::new()
            if (-not (Test-Path -LiteralPath $PublishedDir)) {
                try { New-Item -ItemType Directory -Path $PublishedDir -Force | Out-Null }
                catch { $publicationRecordErrors.Add("06_published 폴더 생성 실패: $($_.Exception.Message)") }
            }
            foreach ($rec in $pendingRecords) {
                try { [System.IO.File]::WriteAllText((Join-Path $PublishedDir $rec.FileName), $rec.Processed, [System.Text.Encoding]::UTF8) }
                catch { $publicationRecordErrors.Add("06_published 기록 실패($($rec.FileName)): $($_.Exception.Message)") }
                if ($rec.SourceId) {
                    try { $null = Set-LLRegistryStatus -SourceId $rec.SourceId -Status "published" }
                    catch { $publicationRecordErrors.Add("registry 발행 상태 기록 실패($($rec.SourceId)): $($_.Exception.Message)") }
                }
            }
            try { Write-LLPublishAttemptOutcome -Ctx $ctx -Status 'published' -PublishedDate $TodayStr -Message '라이브 사이트와 blog-source 백업 push가 모두 성공했습니다.' }
            catch { $publicationRecordErrors.Add("publish_ledger 기록 실패: $($_.Exception.Message)") }
            if ($publicationRecordErrors.Count -eq 0) {
                Write-Host ("  발행 기록 완료: 06_published {0}건 + registry + publish_ledger" -f $pendingRecords.Count) -ForegroundColor Green
            } else {
                $publicationRecordMessage = '라이브와 blog-source push는 성공했으나 로컬 발행 기록을 모두 완료하지 못했습니다. 중복 방지를 위해 남은 기록을 확인하세요: ' + ($publicationRecordErrors -join ' | ')
                $errors.Add($publicationRecordMessage)
                Write-Host ("  [WARN] {0}" -f $publicationRecordMessage) -ForegroundColor Yellow
            }

            Write-Host ""
            Write-Host ("  배포 완료! {0} 확인" -f $SiteUrlHint) -ForegroundColor Green
        }
    }

    return [pscustomobject]@{ ExitCode = 0; Deployed = $deployOk }
}

function Resolve-LLPublishRegistryRow {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft, [Parameter(Mandatory)]$Rows)
    $content = Read-LLText $Draft.FullName
    $sid = Get-LLDraftSourceId $content
    if ($sid) {
        $matches = @($Rows | Where-Object { (Get-LLProp $_ 'source_id') -eq $sid })
        if ($matches.Count -eq 1) { return $matches[0] }
        return $null
    }
    $matches = @($Rows | Where-Object { (Get-LLProp $_ 'topic') -eq $Draft.BaseName })
    if ($matches.Count -ne 1) { $matches = @($Rows | Where-Object { (Get-LLProp $_ 'file_name') -eq $Draft.Name }) }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Test-LLPublishStatusAllowed {
    param([Parameter(Mandatory)][System.IO.FileInfo]$Draft, [Parameter(Mandatory)]$Rows, [Parameter(Mandatory)]$ApprovalRows, [Parameter(Mandatory)][string]$ReadyRoot, [switch]$IncludePublished)
    $row = Resolve-LLPublishRegistryRow -Draft $Draft -Rows $Rows
    if ($null -eq $row) { return $false }
    $status = (Get-LLProp $row "status").Trim().ToLowerInvariant()
    if ($status -ne 'approved' -and -not ($IncludePublished -and $status -eq 'published')) { return $false }
    if (-not (Test-LLPublishableSource $row)) { return $false }
    $relative = $Draft.FullName.Substring(($ReadyRoot.TrimEnd('\') + '\').Length).Replace('\', '/')
    $section = ($relative -split '/')[0]
    $snapshot = Get-LLApprovalSnapshotStatus -ReadyRoot $ReadyRoot -ApprovedPath $Draft.FullName -SourceId (Get-LLProp $row 'source_id') -Section $section -FileName $Draft.Name -Rows $ApprovalRows
    return ($snapshot.status -eq 'match')
}

function ConvertTo-LLPublishedPost {
    param(
        [string]$Content,
        [string]$ModelName = "local-llm"
    )

    $out = ConvertTo-LLPublishMarkdown -Content $Content -ModelName $ModelName
    # Hugo v0.144+ 에서 제거된 front matter 키를 발행 시점에 자동 제거
    # (남아 있으면 hugo 빌드가 ERROR 로 중단됨 — 2026-07-12 lang 사건)
    $out = $out -replace '(?m)^\s*lang\s*:\s*.*\r?\n', ''
    return $out
}

function Find-LLDraftRegistryRow {
    param(
        [string]$DraftName,
        [string]$RawContent,
        [Parameter(Mandatory)]$Rows
    )
    $sid = Get-LLDraftSourceId -Content $RawContent
    if ($sid) {
        $matches = @($rows | Where-Object { $_.source_id -eq $sid })
        if ($matches.Count -eq 1) { return $matches[0] }
        return $null
    }
    $topic = [System.IO.Path]::GetFileNameWithoutExtension($DraftName)
    $matches = @($rows | Where-Object { $_.topic -eq $topic })
    if ($matches.Count -ne 1) { $matches = @($rows | Where-Object { $_.file_name -eq $DraftName }) }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Test-LLDraftQualityGate {
    param(
        [Parameter(Mandatory)][string]$DraftName,
        [Parameter(Mandatory)][string]$RawContent,
        $SourceRow
    )

    $section = ""
    if ($SourceRow) {
        $sourcePath = (Get-LLProp $SourceRow "source_path") -replace "\\", "/"
        if ($sourcePath -match '(?i)(?:^|/)04_blog_drafts/([^/]+)/') { $section = $Matches[1] }
    }
    $issues = @(Get-LLDraftQualityIssues -Content $RawContent -Row $SourceRow -Section $section)
    if ($issues.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Reason = "draft quality: " + ($issues -join ", ") }
    }

    if ($null -ne $SourceRow) {
        $status = (Get-LLProp $SourceRow "status").ToLowerInvariant()
        if ($status -in @("needs_review", "archived", "rejected")) {
            return [pscustomobject]@{ Ok = $false; Reason = "status gate: $status" }
        }

        $topic = (Get-LLProp $SourceRow "topic").ToLowerInvariant()
        $category = (Get-LLProp $SourceRow "source_category").ToLowerInvariant()
        $draftTitle = (Get-LLFrontMatterValue -Content $RawContent -Key "title").ToLowerInvariant()

        # High-signal mismatch guard for single-source drafts only.
        # Daily merged posts can legitimately mention several topics in the title.
        $isDailyMerged = ($category -eq "daily_merged" -or $topic -match '^\d{4}-\d{2}-\d{2}-(am|pm)-daily$')
        $looksLikePandas = ($draftTitle -match "pandas|read[_\. -]?csv|\bcsv\b")
        $sourceIsPandas = ($topic -match "pandas|read[_\. -]?csv|\bcsv\b")
        if (-not $isDailyMerged -and $looksLikePandas -and -not $sourceIsPandas) {
            return [pscustomobject]@{
                Ok = $false
                Reason = "title/topic mismatch: title looks like pandas/read_csv but topic is '$topic'"
            }
        }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "" }
}

function Copy-LLDraftAssets {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$DraftAssetRoot,
        [Parameter(Mandatory)][string]$BlogRoot,
        [AllowNull()][System.Collections.Generic.List[object]]$CreatedArtifacts = $null
    )

    $refs = @(Get-LLDraftAssetPaths -Content $Content)
    if ($refs.Count -eq 0) { return 0 }
    if (-not (Test-Path -LiteralPath $DraftAssetRoot)) {
        throw "초안 이미지 저장소가 없습니다: $DraftAssetRoot"
    }

    $assetRootFull = (Resolve-Path -LiteralPath $DraftAssetRoot).Path
    $copied = 0
    foreach ($assetPath in $refs) {
        $relative = $assetPath -replace '/', '\'
        $source = Join-Path $assetRootFull $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "초안 이미지 없음: /images/$assetPath" }
        $sourceFull = (Resolve-Path -LiteralPath $source).Path
        if (-not $sourceFull.StartsWith($assetRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "초안 이미지 저장소 밖의 경로: $assetPath"
        }

        $ext = [IO.Path]::GetExtension($sourceFull).ToLowerInvariant()
        if ($ext -notin @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")) {
            throw "지원하지 않는 이미지 형식: $assetPath"
        }
        $dest = Join-Path (Join-Path $BlogRoot "static") $relative
        $destParent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        $disposition = Get-LLPublishDestinationDisposition `
            -DestinationPath $dest `
            -ExpectedFilePath $sourceFull `
            -Label '블로그 이미지'
        if ($disposition -eq 'Create') {
            # CreateNew prevents a file appearing between the check and copy from being overwritten.
            [System.IO.File]::Copy($sourceFull, $dest, $false)
            if ($null -ne $CreatedArtifacts) {
                $CreatedArtifacts.Add([pscustomobject]@{
                    full_path=$dest; repo_path=$dest.Substring($BlogRoot.Length + 1).Replace('\','/'); sha256=(Get-LLHash $dest)
                })
            }
            $copied++
        }
    }
    return $copied
}

Export-ModuleMember -Function Get-LLFrontMatterValue, Get-LLDraftAssetPaths, Get-LLHugoCommandPath, New-LLPublishPlan, Test-LLPublishSection, New-LLPublishContext, Test-LLPublishGitTouched, Move-LLPublishArtifactsToTrash, Write-LLPublishAttemptOutcome, Write-LLPublishAbortHint, Invoke-LLPublishDeploy, Resolve-LLPublishRegistryRow, Test-LLPublishStatusAllowed, ConvertTo-LLPublishedPost, Find-LLDraftRegistryRow, Test-LLDraftQualityGate, Copy-LLDraftAssets, Invoke-LLPublishPreflightStage, Assert-LLPublishTargetsReady, Get-LLHugoInputPathspecs, Invoke-LLPublishCopyStage
