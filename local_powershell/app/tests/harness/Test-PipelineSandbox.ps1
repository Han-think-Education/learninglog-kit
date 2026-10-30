#Requires -Version 7.0
<#
  샌드박스 전체 흐름 테스트: intake -> prep -> extract -> blogdraft 를 가짜 LM 서버로 끝까지 돌린다.
  - 운영 폴더는 건드리지 않는다. app/run/08_templates 만 짧은 임시 경로로 복사해서 실행한다.
  - 첫 요청 1건을 일부러 실패시켜(blogdraft 재시도) 재시도 경로까지 확인한다.
  - 발행·푸시·Hugo 는 호출하지 않는다.
  사용: pwsh -NoProfile -File Test-PipelineSandbox.ps1 [-Port 1299] [-KeepSandbox]
#>
param(
    [int]$Port = 1299,
    [switch]$KeepSandbox
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$harness = $PSScriptRoot
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$s = 'C:\llh_e2e_' + [guid]::NewGuid().ToString('N').Substring(0, 6)   # 짧은 경로(깃 Filename too long 방지)
$script:passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}

New-Item -ItemType Directory -Path $s -Force | Out-Null
$srv = $null
try {
    foreach ($d in 'app', 'run', '08_templates') {
        $null = robocopy (Join-Path $root $d) (Join-Path $s $d) /S /XD tests legacy .tmp /NFL /NDL /NJH /NJS /NP
    }
    New-Item -ItemType Directory -Path "$s\00_inbox\personal_notes", "$s\07_archive\backups" -Force | Out-Null
    Set-Content "$s\00_inbox\personal_notes\PN_2026-10-30_AM_01_smoke_note.md" "# LLM 스모크 노트`n`n파이썬 리스트는 순서가 있는 가변 컨테이너다.`n`n- append, pop 으로 끝에서 추가/제거`n- 슬라이싱으로 부분 추출`n`n딕셔너리는 키로 값을 찾는다." -Encoding utf8

    $log = "$s\fake.jsonl"; $stop = "$s\stop.flag"
    $srv = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', "$harness\FakeLmServer.ps1", '-Port', $Port, '-FailFirst', 0, '-LogPath', $log, '-StopFile', $stop) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) { try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 200 } }

    $lm = @('-Engine', 'lm', '-LMStudioBase', "http://127.0.0.1:$Port", '-LMStudioModel', 'mock-model')
    $null = & pwsh -NoProfile -File "$s\app\run_learninglog_intake.ps1" 2>&1;  Check ($LASTEXITCODE -eq 0) 'intake exit 0'
    $null = & pwsh -NoProfile -File "$s\app\run_learninglog_prep.ps1" 2>&1;    Check ($LASTEXITCODE -eq 0) 'prep exit 0'
    $null = & pwsh -NoProfile -File "$s\app\run_learninglog_extract.ps1" @lm 2>&1; Check ($LASTEXITCODE -eq 0) 'extract exit 0'
    Check ((Get-ChildItem "$s\02_extracted" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count -ge 1) 'extract wrote concept extract'
    Check ((Get-ChildItem "$s\03_working_notes" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count -ge 1) 'extract wrote working note'
    $afterExtract = (Get-Content $log | Measure-Object).Count
    Check ($afterExtract -eq 3) 'extract made exactly 3 LM calls (classify, extract, working)'

    # blogdraft: 첫 요청 1건 실패 주입 → 재시도 후 성공해야 한다.
    Set-Content $stop x; $null = $srv.WaitForExit(5000)
    $log2 = "$s\fake2.jsonl"; $stop2 = "$s\stop2.flag"
    $srv = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', "$harness\FakeLmServer.ps1", '-Port', $Port, '-FailFirst', 1, '-LogPath', $log2, '-StopFile', $stop2) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) { try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 200 } }
    $out = & pwsh -NoProfile -File "$s\app\run_learninglog_blogdraft.ps1" @lm 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 0) 'blogdraft exit 0'
    Check ($out -match 'LM 재시도 1/3') 'blogdraft retried the injected failure'
    $statuses = @(Get-Content $log2 | ForEach-Object { ($_ | ConvertFrom-Json).status })
    Check ($statuses[0] -eq 500 -and ($statuses | Where-Object { $_ -eq 200 }).Count -ge 1) 'first request failed (500) then succeeded'
    Check ((Get-ChildItem "$s\04_blog_drafts" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Measure-Object).Count -ge 1) 'blogdraft wrote a draft'
    Set-Content $stop2 x; $null = $srv.WaitForExit(5000); $srv = $null
    Write-Host ("ALL PASS ({0} checks)" -f $script:passed) -ForegroundColor Green
}
finally {
    if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
    if (-not $KeepSandbox) { Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue }
}
