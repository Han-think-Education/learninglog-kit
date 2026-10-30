Set-StrictMode -Version Latest

function Invoke-LLPublishGitProcess {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $gitApplication = Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gitApplication.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $null = $startInfo.ArgumentList.Add('-C')
    $null = $startInfo.ArgumentList.Add($RepoRoot)
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Git 프로세스를 시작하지 못했습니다.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            exit_code = $process.ExitCode
            stdout    = $stdoutTask.GetAwaiter().GetResult()
            stderr    = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-LLPublishGitCapture {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-LLPublishGitProcess -RepoRoot $RepoRoot -Arguments $Arguments
    if ($result.exit_code -ne 0) {
        $detail = if (-not [string]::IsNullOrWhiteSpace($result.stderr)) { $result.stderr.Trim() } else { $result.stdout.Trim() }
        throw "Git 상태를 확인하지 못했습니다 (exit $($result.exit_code)): $detail"
    }
    return [string]$result.stdout
}

function Add-LLPublishPathsToIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyCollection()][string[]]$Paths = @(),
        [ValidateRange(1, 1024)][int]$MaxBatchPathCount = 64,
        [ValidateRange(1024, 30000)][int]$MaxCommandLineLength = 12000
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path.TrimEnd('\', '/')
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $normalizedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($rawPath in $Paths) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }
        $path = $rawPath.Replace('\', '/')
        while ($path.StartsWith('./', [StringComparison]::Ordinal)) { $path = $path.Substring(2) }
        if ($path.StartsWith('/') -or [IO.Path]::IsPathRooted($path) -or $path.Split('/') -contains '..') {
            throw "스테이징 목록에 저장소 밖 경로가 있습니다: $rawPath"
        }
        if ($seen.Add($path)) { $normalizedPaths.Add($path) }
    }
    if ($normalizedPaths.Count -eq 0) { return [pscustomobject]@{ path_count = 0; batch_count = 0 } }

    $baseLength = 128 + $resolvedRoot.Length
    $batchLength = $baseLength
    $batch = [System.Collections.Generic.List[string]]::new()
    $batches = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $normalizedPaths) {
        # Windows command lines are limited to 32,767 UTF-16 characters. Keep a wide margin
        # for executable and quoting overhead; ArgumentList performs the actual quoting.
        $argumentLength = (':(literal)' + $path).Length + 2
        if (($baseLength + $argumentLength) -gt $MaxCommandLineLength) {
            throw "Git 경로가 안전한 스테이징 명령 길이를 초과합니다: $path"
        }
        if ($batch.Count -gt 0 -and (($batch.Count -ge $MaxBatchPathCount) -or (($batchLength + $argumentLength) -gt $MaxCommandLineLength))) {
            $batches.Add([pscustomobject]@{ paths = $batch.ToArray() })
            $batch.Clear()
            $batchLength = $baseLength
        }
        $batch.Add($path)
        $batchLength += $argumentLength
    }
    if ($batch.Count -gt 0) { $batches.Add([pscustomobject]@{ paths = $batch.ToArray() }) }

    $initialState = Get-LLPublishGitState -RepoRoot $resolvedRoot
    if (@($initialState.staged_paths).Count -gt 0) {
        throw "기존 stage 변경이 있어 허용 경로를 스테이징하지 않았습니다: $(Format-LLPublishPaths $initialState.staged_paths)"
    }
    foreach ($pathBatch in $batches) {
        $specs = @($pathBatch.paths | ForEach-Object { ':(literal)' + $_ })
        $ignoredOutput = Invoke-LLPublishGitCapture -RepoRoot $resolvedRoot -Arguments (@('ls-files', '--others', '--ignored', '--exclude-standard', '-z', '--') + $specs)
        $ignoredPaths = @(ConvertFrom-LLPublishNulPaths -Output $ignoredOutput)
        if ($ignoredPaths.Count -gt 0) {
            throw "허용 목록에 무시된 파일이 있어 스테이징하지 않았습니다: $(Format-LLPublishPaths $ignoredPaths)"
        }
    }
    $expectedStage = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $initialWorking = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $initialState.working_paths) { $null = $initialWorking.Add($path) }
    foreach ($path in $normalizedPaths) { if ($initialWorking.Contains($path)) { $null = $expectedStage.Add($path) } }

    $batchCount = 0
    try {
        foreach ($pathBatch in $batches) {
            $specs = @($pathBatch.paths | ForEach-Object { ':(literal)' + $_ })
            $result = Invoke-LLPublishGitProcess -RepoRoot $resolvedRoot -Arguments (@('add', '--') + $specs)
            if ($result.exit_code -ne 0) {
                $detail = if (-not [string]::IsNullOrWhiteSpace($result.stderr)) { $result.stderr.Trim() } else { $result.stdout.Trim() }
                throw "Git 파일 스테이징 실패 (exit $($result.exit_code), 배치 $($batchCount + 1)): $detail"
            }
            $batchCount++
        }

        $staged = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $afterState = Get-LLPublishGitState -RepoRoot $resolvedRoot
        foreach ($path in $afterState.staged_paths) { $null = $staged.Add($path) }
        $missing = @($expectedStage | Where-Object { -not $staged.Contains($_) })
        $unexpected = @($staged | Where-Object { -not $expectedStage.Contains($_) })
        if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
            throw "Git이 요청한 변경 경로만 stage하지 않았습니다. 누락: $(Format-LLPublishPaths $missing); 예상 밖: $(Format-LLPublishPaths $unexpected)"
        }
    } catch {
        $failure = $_.Exception.Message
        $stagedByAttempt = @()
        try {
            $rollbackState = Get-LLPublishGitState -RepoRoot $resolvedRoot
            $stagedByAttempt = @($rollbackState.staged_paths)
        } catch {}
        if ($stagedByAttempt.Count -gt 0) {
            $rollbackSpecs = @($stagedByAttempt | ForEach-Object { ':(literal)' + $_ })
            $rollback = Invoke-LLPublishGitProcess -RepoRoot $resolvedRoot -Arguments (@('restore', '--staged', '--') + $rollbackSpecs)
            if ($rollback.exit_code -ne 0) {
                $detail = if (-not [string]::IsNullOrWhiteSpace($rollback.stderr)) { $rollback.stderr.Trim() } else { $rollback.stdout.Trim() }
                throw "$failure; 실패한 스테이징 정리도 실패했습니다: $detail"
            }
        }
        throw $failure
    }

    return [pscustomobject]@{ path_count = $normalizedPaths.Count; batch_count = $batchCount }
}

function ConvertFrom-LLPublishNulPaths {
    param([AllowEmptyString()][string]$Output)

    if ([string]::IsNullOrEmpty($Output)) { return @() }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($rawPath in $Output.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
        $path = $rawPath.Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path.StartsWith('/') -or [IO.Path]::IsPathRooted($path) -or $path.Split('/') -contains '..') {
            throw "Git이 저장소 밖의 경로를 반환했습니다: $path"
        }
        $paths.Add($path)
    }
    return $paths.ToArray()
}

function ConvertTo-LLPublishPathSet {
    param([AllowEmptyCollection()][string[]]$Paths = @())

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $normalized = $path.Replace('\', '/')
        while ($normalized.StartsWith('./', [StringComparison]::Ordinal)) {
            $normalized = $normalized.Substring(2)
        }
        if ($normalized.StartsWith('/') -or [IO.Path]::IsPathRooted($normalized) -or $normalized.Split('/') -contains '..') {
            throw "허용 목록에 저장소 밖 경로가 있습니다: $path"
        }
        $null = $set.Add($normalized)
    }
    return ,$set
}

function Get-LLPublishGitState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyCollection()][string[]]$IgnoredPathspecs = @()
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path.TrimEnd('\', '/')
    $reportedRoot = (Invoke-LLPublishGitCapture -RepoRoot $resolvedRoot -Arguments @('rev-parse', '--show-toplevel')).Trim()
    $reportedRoot = [IO.Path]::GetFullPath($reportedRoot).TrimEnd('\', '/')
    if (-not [string]::Equals($resolvedRoot, $reportedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "지정 경로가 Git 저장소 루트가 아닙니다: $resolvedRoot"
    }

    $stagedOutput = Invoke-LLPublishGitCapture -RepoRoot $resolvedRoot -Arguments @('diff', '--cached', '--name-only', '--no-renames', '-z')
    $workingOutput = Invoke-LLPublishGitCapture -RepoRoot $resolvedRoot -Arguments @('diff', '--name-only', '--no-renames', '-z')
    $untrackedOutput = Invoke-LLPublishGitCapture -RepoRoot $resolvedRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    $stagedPaths = @(ConvertFrom-LLPublishNulPaths -Output $stagedOutput | Sort-Object -Unique)
    $workingPaths = @(
        (ConvertFrom-LLPublishNulPaths -Output $workingOutput)
        (ConvertFrom-LLPublishNulPaths -Output $untrackedOutput)
    ) | Sort-Object -Unique

    $ignoredPaths = @()
    if ($IgnoredPathspecs.Count -gt 0) {
        $ignoredArgs = @('ls-files', '--others', '--ignored', '--exclude-standard', '-z', '--') + $IgnoredPathspecs
        $ignoredOutput = Invoke-LLPublishGitCapture -RepoRoot $resolvedRoot -Arguments $ignoredArgs
        $ignoredPaths = @(ConvertFrom-LLPublishNulPaths -Output $ignoredOutput | Sort-Object -Unique)
    }

    return [pscustomobject]@{
        repo_root = $resolvedRoot
        staged_paths = $stagedPaths
        working_paths = $workingPaths
        ignored_paths = $ignoredPaths
    }
}

function Format-LLPublishPaths {
    param([string[]]$Paths)
    $shown = @($Paths | Select-Object -First 12)
    $text = $shown -join ', '
    if ($Paths.Count -gt $shown.Count) { $text += ", ... (+$($Paths.Count - $shown.Count))" }
    return $text
}

function Assert-LLPublishRepositoryReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyCollection()][string[]]$AllowedWorkingPaths = @(),
        [AllowEmptyCollection()][string[]]$IgnoredPathspecs = @(),
        [string]$Label = 'repository'
    )

    $state = Get-LLPublishGitState -RepoRoot $RepoRoot -IgnoredPathspecs $IgnoredPathspecs
    $allowed = ConvertTo-LLPublishPathSet -Paths $AllowedWorkingPaths
    if (@($state.staged_paths).Count -gt 0) {
        throw "$Label 저장소에 기존 stage 변경이 있어 발행을 중단합니다: $(Format-LLPublishPaths $state.staged_paths)"
    }

    $unexpectedWorking = @($state.working_paths | Where-Object { -not $allowed.Contains($_) })
    if ($unexpectedWorking.Count -gt 0) {
        throw "$Label 저장소에 이번 발행 대상이 아닌 변경이 있어 발행을 중단합니다: $(Format-LLPublishPaths $unexpectedWorking)"
    }
    if (@($state.ignored_paths).Count -gt 0) {
        throw "$Label 저장소의 무시된 입력/산출물을 확인할 수 없어 발행을 중단합니다: $(Format-LLPublishPaths $state.ignored_paths)"
    }
    return $state
}

function Assert-LLPublishStagedPathsAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyCollection()][string[]]$AllowedPaths = @(),
        [string]$Label = 'repository'
    )

    $state = Get-LLPublishGitState -RepoRoot $RepoRoot
    $allowed = ConvertTo-LLPublishPathSet -Paths $AllowedPaths
    $unexpected = @($state.staged_paths | Where-Object { -not $allowed.Contains($_) })
    if ($unexpected.Count -gt 0) {
        throw "$Label stage에 이번 발행 허용 목록 외 파일이 있어 커밋을 중단합니다: $(Format-LLPublishPaths $unexpected)"
    }
    return $state.staged_paths
}

function Get-LLPublishDestinationDisposition {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][string]$ExpectedContent,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$ExpectedFilePath,
        [switch]$AllowReplace,
        [string]$Label = '발행 대상'
    )

    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if (-not (Test-Path -LiteralPath $destination)) { return 'Create' }

    $item = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "$Label 경로에 파일 대신 폴더가 있어 발행을 중단합니다: $destination" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label 경로가 링크/재분석 지점이므로 발행을 중단합니다: $destination"
    }

    $matchesExpected = $false
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $expected = Get-Item -LiteralPath $ExpectedFilePath -Force -ErrorAction Stop
        if ($expected.PSIsContainer -or (($expected.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "$Label 비교 원본이 일반 파일이 아닙니다: $ExpectedFilePath"
        }
        $expectedHash = (Get-FileHash -LiteralPath $expected.FullName -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        $matchesExpected = [string]::Equals($expectedHash, $destinationHash, [StringComparison]::OrdinalIgnoreCase)
    } else {
        $existingContent = [IO.File]::ReadAllText($destination, [Text.Encoding]::UTF8)
        $matchesExpected = [string]::Equals($existingContent, $ExpectedContent, [StringComparison]::Ordinal)
    }

    if ($matchesExpected) { return 'Unchanged' }
    if ($AllowReplace) { return 'Replace' }
    throw "$Label 에 다른 내용의 기존 파일이 있어 덮어쓰기를 차단했습니다: $destination"
}

function Add-LLPublishDestinationPlanEntry {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][string]$ExpectedContent,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$ExpectedFilePath,
        [string]$Label = '발행 선택'
    )

    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $source = Get-Item -LiteralPath $ExpectedFilePath -Force -ErrorAction Stop
        if ($source.PSIsContainer -or (($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "$Label 비교 원본이 일반 파일이 아닙니다: $ExpectedFilePath"
        }
        $fingerprint = 'file:' + (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
    } else {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($ExpectedContent)
            $fingerprint = 'text:' + [Convert]::ToHexString($sha.ComputeHash($bytes))
        } finally {
            $sha.Dispose()
        }
    }

    if ($Plan.Contains($destination)) {
        if (-not [string]::Equals([string]$Plan[$destination], $fingerprint, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label 에서 여러 자료가 동일 목적지에 서로 다른 내용을 쓰려고 해 발행을 중단합니다: $destination"
        }
        return $false
    }
    $Plan[$destination] = $fingerprint
    return $true
}

function Assert-LLPublishRepositoryPathsAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyCollection()][string[]]$AllowedPaths = @(),
        [AllowEmptyCollection()][string[]]$IgnoredPathspecs = @(),
        [string]$Label = 'repository'
    )

    $state = Get-LLPublishGitState -RepoRoot $RepoRoot -IgnoredPathspecs $IgnoredPathspecs
    $allowed = ConvertTo-LLPublishPathSet -Paths $AllowedPaths
    $unexpectedStaged = @($state.staged_paths | Where-Object { -not $allowed.Contains($_) })
    $unexpectedWorking = @($state.working_paths | Where-Object { -not $allowed.Contains($_) })
    if ($unexpectedStaged.Count -gt 0) {
        throw "$Label stage에 이번 작업 허용 목록 외 파일이 있습니다: $(Format-LLPublishPaths $unexpectedStaged)"
    }
    if ($unexpectedWorking.Count -gt 0) {
        throw "$Label 작업 트리에 이번 작업 허용 목록 외 파일이 있습니다: $(Format-LLPublishPaths $unexpectedWorking)"
    }
    if (@($state.ignored_paths).Count -gt 0) {
        throw "$Label 에 무시된 입력/산출물이 있어 작업을 중단합니다: $(Format-LLPublishPaths $state.ignored_paths)"
    }
    return $state
}

Export-ModuleMember -Function Get-LLPublishGitState, Assert-LLPublishRepositoryReady, Assert-LLPublishStagedPathsAllowed, Assert-LLPublishRepositoryPathsAllowed, Get-LLPublishDestinationDisposition, Add-LLPublishDestinationPlanEntry, Add-LLPublishPathsToIndex, Format-LLPublishPaths
# publish 스크립트(-SelectionFile 경로)가 직접 호출한다. 내보내지 않으면 "명령을 찾을 수 없음" 오류가 난다.
Export-ModuleMember -Function Invoke-LLPublishGitCapture
