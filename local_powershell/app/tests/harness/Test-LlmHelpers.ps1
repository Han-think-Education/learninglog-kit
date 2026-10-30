#Requires -Version 7.0
<#
  특성 테스트(characterization): extract / blogdraft 안에 따로 정의된 LLM 호출·청킹 함수의 "현재 동작"을
  가짜 LM 서버로 측정해 baseline_llm_helpers.json 과 비교한다.
  리팩터링(공용 모듈화) 전후로 돌려서, 의도한 변화만 baseline 에 반영한다.

  사용:
    pwsh -File Test-LlmHelpers.ps1            # baseline 과 비교 (다르면 exit 1)
    pwsh -File Test-LlmHelpers.ps1 -Record    # 현재 동작을 baseline 으로 저장
  실데이터/실서버를 건드리지 않는다: 임시 폴더 + 127.0.0.1:<Port> 가짜 서버만 사용.
#>
param(
    [switch]$Record,
    [int]$Port = 1299
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$harness = $PSScriptRoot
$appDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$baselinePath = Join-Path $harness 'baseline_llm_helpers.json'
$work = Join-Path ([IO.Path]::GetTempPath()) ('llh_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Get-FunctionText([string]$File, [string[]]$Names) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
    $out = foreach ($n in $Names) {
        $f = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $false) | Select-Object -First 1
        if ($f) { $f.Extent.Text }
    }
    return ($out -join "`n`n")
}

function Start-FakeServer([int]$FailFirst) {
    $log = Join-Path $work ("server_{0}.jsonl" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
    $stop = Join-Path $work ("stop_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
    $args = @('-NoProfile', '-File', (Join-Path $harness 'FakeLmServer.ps1'), '-Port', $Port, '-FailFirst', $FailFirst, '-LogPath', $log, '-StopFile', $stop)
    $p = Start-Process pwsh -ArgumentList $args -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) {
        try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 200 }
    }
    return [pscustomobject]@{ Process = $p; Log = $log; Stop = $stop }
}

function Stop-FakeServer($srv) {
    Set-Content -LiteralPath $srv.Stop -Value 'x'
    if (-not $srv.Process.WaitForExit(5000)) { Stop-Process -Id $srv.Process.Id -Force }
}

# 시나리오 본문(child 프로세스에서 실행). 함수 정의 뒤에 붙는다.
$scenarioBody = @'
function Set-LLJobItem { }   # 진행바 모듈 함수 스텁 (LocalCore 미로드)
function Try-Run([scriptblock]$Block) { try { $r = & $Block; return [ordered]@{ ok = $true; value = $r } } catch { return [ordered]@{ ok = $false; error = ($_.Exception.Message -replace '\s+', ' ').Substring(0, [Math]::Min(80, $_.Exception.Message.Length)) } } }
$result = [ordered]@{}
$result.generate = Try-Run { Invoke-LLMText -Model 'mock-model' -Prompt 'hello world' }
$text = "첫째 단락입니다.`n`n둘째 단락입니다. 조금 더 길게 씁니다.`n`n셋째 단락입니다.`n`n넷째 단락입니다. 마지막입니다.`n`n다섯째."
$chunks = @(Split-LLTextChunks -Text $text -MaxChars 40 -OverlapChars 0)
$result.chunks = [ordered]@{ count = $chunks.Count; lengths = @($chunks | ForEach-Object { $_.Length }) }
$result.chunkedShort = Try-Run { Invoke-LLMTextChunked -Model 'mock-model' -Instruction '요약해라' -Body '짧은 본문' -MaxChars 500 }
$long = ($text + "`n`n" + $text)
$result.chunkedLong = Try-Run { (Invoke-LLMTextChunked -Model 'mock-model' -Instruction '요약해라' -Body $long -MaxChars 60) -replace '\s+', ' ' }
$result | ConvertTo-Json -Depth 6 -Compress
'@

$variants = @(
    @{ name = 'extract'; file = Join-Path $appDir 'run_learninglog_extract.ps1' },
    @{ name = 'blogdraft'; file = Join-Path $appDir 'run_learninglog_blogdraft.ps1' }
)
# 스크립트에 남아 있는 얇은 래퍼만 추출한다. (저수준 호출·청킹은 core\LearningLog.Llm.psm1 로 이동)
$fnNames = 'Invoke-LLMText', 'Invoke-LLMTextChunked'
$llmModule = Join-Path $appDir 'core\LearningLog.Llm.psm1'
$coreModule = Join-Path $appDir 'core\LearningLog.LocalCore.psm1'   # Split-LLTextChunks 제공

$observed = [ordered]@{}
try {
    foreach ($v in $variants) {
        $funcs = Get-FunctionText -File $v.file -Names $fnNames
        foreach ($failFirst in 0, 1) {
            $srv = Start-FakeServer -FailFirst $failFirst
            try {
                $childPath = Join-Path $work ("child_{0}_{1}.ps1" -f $v.name, $failFirst)
                $header = "`$ErrorActionPreference='Stop'; `$LMStudioBase='http://127.0.0.1:$Port'; `$NumCtx=8192; function Start-Sleep { }`n"
                # 스크립트가 쓰는 두 모듈(LocalCore: 청킹, Llm: LM 호출)을 그대로 불러온다.
                $header += "Import-Module '$coreModule' -Force -DisableNameChecking; Import-Module '$llmModule' -Force -DisableNameChecking`n"
                Set-Content -LiteralPath $childPath -Value ($header + $funcs + "`n" + $scenarioBody) -Encoding utf8
                $raw = & pwsh -NoProfile -File $childPath 2>&1 | Where-Object { $_ -is [string] -or $_.GetType().Name -ne 'ErrorRecord' } | Select-Object -Last 1
                $key = '{0}/failFirst={1}' -f $v.name, $failFirst
                $observed[$key] = ($raw | ConvertFrom-Json -AsHashtable)
                $reqLog = if (Test-Path -LiteralPath $srv.Log) { @(Get-Content -LiteralPath $srv.Log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
                $observed[$key]['requests'] = [ordered]@{ total = $reqLog.Count; failed = @($reqLog | Where-Object { $_.status -ne 200 }).Count; maxTokens = @($reqLog | ForEach-Object { $_.maxTokens } | Select-Object -Unique | Sort-Object) }
            } finally { Stop-FakeServer $srv }
        }
    }
} finally {
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$json = $observed | ConvertTo-Json -Depth 8
if ($Record) {
    Set-Content -LiteralPath $baselinePath -Value $json -Encoding utf8
    Write-Host "baseline recorded: $baselinePath" -ForegroundColor Green
    $observed.Keys | ForEach-Object { Write-Host "  $_" }
    exit 0
}
if (-not (Test-Path -LiteralPath $baselinePath)) { throw "baseline 없음. -Record 로 먼저 저장하세요." }
$expected = (Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json -AsHashtable) | ConvertTo-Json -Depth 8
$actualNorm = ($json | ConvertFrom-Json -AsHashtable) | ConvertTo-Json -Depth 8
if ($expected -eq $actualNorm) {
    Write-Host ("PASS: llm helper behavior unchanged ({0} scenarios)" -f $observed.Count) -ForegroundColor Green
    exit 0
}
Write-Host 'FAIL: llm helper behavior changed' -ForegroundColor Red
$ea = [IO.Path]::GetTempFileName(); $ac = [IO.Path]::GetTempFileName()
Set-Content $ea $expected -Encoding utf8; Set-Content $ac $actualNorm -Encoding utf8
git diff --no-index --no-color -U2 $ea $ac | Select-Object -Skip 4 -First 40
exit 1
