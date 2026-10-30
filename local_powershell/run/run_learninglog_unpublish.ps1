# 호환 진입점: 실제 구현은 app\ 에 있습니다.
$target = Join-Path $PSScriptRoot "..\app\run_learninglog_unpublish.ps1"
& pwsh -NoProfile -ExecutionPolicy Bypass -File $target @args
exit $LASTEXITCODE
