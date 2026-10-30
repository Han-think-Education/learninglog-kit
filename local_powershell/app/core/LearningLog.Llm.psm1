#Requires -Version 7.0
# LM Studio(OpenAI 호환) 호출과 텍스트 청킹 — extract / blogdraft 가 공유한다.
# 전역 변수에 의존하지 않는다: 접속 주소·모델·온도는 모두 매개변수로 받는다.
# 텍스트 청킹은 LearningLog.LocalCore 의 Split-LLTextChunks 를 쓴다.
Set-StrictMode -Version Latest

function Invoke-LLMGenerate {
    <#
    .SYNOPSIS
        /v1/chat/completions 한 번 호출해 본문 문자열을 돌려준다.
        일시 오류(HTTP 오류·타임아웃·빈 응답)는 MaxAttempts 번까지 재시도하고, 지속 실패는 그대로 throw 한다.
    #>
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$NumPredict = 512,
        [double]$Temperature = 0.2,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3,
        [string]$EmptyMessage = 'LM Studio returned an empty response.'
    )
    $bodyObj = [ordered]@{
        model       = $Model
        messages    = @([ordered]@{ role = 'user'; content = $Prompt })
        stream      = $false
        temperature = $Temperature
        max_tokens  = $NumPredict
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyObj | ConvertTo-Json -Depth 6 -Compress))
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri "$Base/v1/chat/completions" -Method Post `
                -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 600 -ErrorAction Stop
            $text = [string]$resp.choices[0].message.content
            if ([string]::IsNullOrWhiteSpace($text)) { throw $EmptyMessage }
            return $text
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Host ("      [LM 재시도 {0}/{1}] {2}" -f $attempt, $MaxAttempts, $_.Exception.Message) -ForegroundColor DarkYellow
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Invoke-LLMGenerateJson {
    <#
    .SYNOPSIS
        OpenAI response_format=json_schema(범용 object)로 JSON 문자열을 요청한다. 재시도 없음(호출부가 파싱 실패를 처리한다).
    #>
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$NumPredict = 2048,
        [double]$Temperature = 0.3
    )
    $rf = [ordered]@{ type = 'json_schema'
                      json_schema = [ordered]@{ name = 'obj'; strict = $false
                                                schema = [ordered]@{ type = 'object'; additionalProperties = $true } } }
    $bodyObj = [ordered]@{ model = $Model
                           messages = @([ordered]@{ role = 'user'; content = $Prompt })
                           stream = $false; temperature = $Temperature; max_tokens = $NumPredict; response_format = $rf }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyObj | ConvertTo-Json -Depth 8 -Compress))
    $resp = Invoke-RestMethod -Uri "$Base/v1/chat/completions" -Method Post `
        -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 600 -ErrorAction Stop
    return [string]$resp.choices[0].message.content
}

Export-ModuleMember -Function Invoke-LLMGenerate, Invoke-LLMGenerateJson
