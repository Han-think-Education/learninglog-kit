#Requires -Version 7.0
param([Parameter(Mandatory)][string]$SelectionFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'core/LearningLog.LocalCore.psm1') -Force -DisableNameChecking
$env:LH_JOB_PROGRESS='1'
$env:LH_JOB_RUN_ID=[guid]::NewGuid().ToString('N')
try {
    Clear-LLJobProgress
    Set-LLJobStage -Job devdraft -Index 1 -Total 3 -Key intake -Label '선택 자료·공개 정책 확인'
    $selection = Read-LLText $SelectionFile | ConvertFrom-Json
    $null = Resolve-LLDevNoteSelection -Path ([string]$selection.path) -Hash ([string]$selection.hash)
    Set-LLMRecoveryEndpoint -Engine lm
    $model='local-model'
    $health=Test-LLMModelAvailable -Model $model
    if (-not $health.ok) { throw "LM Studio/모델 확인 실패: $($health.message). 원문 대체 초안을 만들지 않습니다." }
    Set-LLJobStage -Job devdraft -Index 2 -Total 3 -Key blogdraft -Label '개인 개발 글 작성'
    Write-Host ('자료: ' + $selection.path)
    $result=Invoke-LLDevDraft -Path ([string]$selection.path) -Hash ([string]$selection.hash)
    Set-LLJobStage -Job devdraft -Index 3 -Total 3 -Key finish -Label '초안 저장·검토 대기'
    Write-Host ('새 초안 1건: ' + $result.draft)
    foreach ($issue in $result.issues) { Write-Host ('검토: ' + $issue) }
    Complete-LLJobProgress -State done -Detail '새 초안 1건 · 원문 대조 후 편집·승인하세요. 자동 발행 안 함.'
} catch {
    Complete-LLJobProgress -State failed -Detail $_.Exception.Message
    # 숨김 worker의 stderr에만 남으면 제어센터 job.log에서 원인을 볼 수 없다.
    Write-Host ('[오류] ' + $_.Exception.Message)
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
