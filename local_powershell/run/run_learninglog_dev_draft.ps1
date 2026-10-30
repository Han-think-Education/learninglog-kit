# 사용자 진입점: 구현/상태는 기존 app/core에 둔다.
$target = Join-Path $PSScriptRoot '../app/run_learninglog_dev_draft.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $target @args
exit $LASTEXITCODE
