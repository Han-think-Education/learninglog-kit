#Requires -Version 7.0
<#
  OpenAI/LM Studio 호환 가짜 서버 (테스트 전용).
    GET  /v1/models            -> { data: [ { id: <Model> } ] }
    POST /v1/chat/completions  -> 프롬프트에 따라 결정적인 응답
  실패 주입: -FailFirst N  → 처음 N번 요청은 HTTP 500 (재시도 동작 확인용)
  요청 기록: -LogPath 에 JSON Lines (n, status, promptHead, promptLen, maxTokens)
  종료: 파일 -StopFile 이 생기면 종료 (Stop-Job 은 HttpListener 대기 중이면 멈추지 않으므로 별도 프로세스 + 파일 신호)
#>
param(
    [int]$Port = 1299,
    [string]$Model = 'mock-model',
    [int]$FailFirst = 0,
    [Parameter(Mandatory)][string]$LogPath,
    [Parameter(Mandatory)][string]$StopFile
)
$ErrorActionPreference = 'Stop'
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
$count = 0
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Send-Json($ctx, [int]$status, $obj) {
    $bytes = $utf8.GetBytes(($obj | ConvertTo-Json -Depth 8 -Compress))
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

function Get-MockAnswer([string]$prompt) {
    if ($prompt -match 'source_type' -and $prompt -match 'target_section') {
        return '{"source_type":"personal_note","topic":"mock topic","language":"ko","public_policy":"public","target_section":"learning","tags":["mock"]}'
    }
    if ($prompt -match 'JSON') { return '{"concepts":["개념A","개념B"]}' }
    # 결정적 마크다운 응답: 프롬프트 길이만 반영해 입력 변화가 출력에 드러나게 한다.
    return "## 모의 응답`n`n- 입력 길이: $($prompt.Length)`n- 본문 첫 줄: " + (($prompt -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))
}

try {
    while (-not (Test-Path -LiteralPath $StopFile)) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(300)) { if (Test-Path -LiteralPath $StopFile) { return } }
        $ctx = $task.Result
        $path = $ctx.Request.Url.AbsolutePath
        if ($path -eq '/v1/models') { Send-Json $ctx 200 @{ data = @(@{ id = $Model }) }; continue }
        if ($path -eq '/v1/chat/completions' -and $ctx.Request.HttpMethod -eq 'POST') {
            $count++
            $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream, $utf8)
            $req = $reader.ReadToEnd() | ConvertFrom-Json
            $prompt = [string]$req.messages[-1].content
            $status = if ($count -le $FailFirst) { 500 } else { 200 }
            $entry = [ordered]@{ n = $count; status = $status; promptLen = $prompt.Length; maxTokens = $req.max_tokens; promptHead = $prompt.Substring(0, [Math]::Min(60, $prompt.Length)) }
            Add-Content -LiteralPath $LogPath -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8
            if ($status -eq 500) { Send-Json $ctx 500 @{ error = 'injected failure' }; continue }
            Send-Json $ctx 200 @{ choices = @(@{ message = @{ role = 'assistant'; content = (Get-MockAnswer $prompt) } }) }
            continue
        }
        Send-Json $ctx 404 @{ error = 'not found' }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
