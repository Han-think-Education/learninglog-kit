#Requires -Version 7.0
# 린트: app/ run/ 의 모든 스크립트가 호출하는 "동사-명사" 명령이 실제로 존재하는지 확인한다.
# (함수 이름을 바꾸거나 옮긴 뒤 호출부가 깨지는 사고를 잡는다. 실행은 하지 않고 AST 만 읽는다.)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach ($m in 'LearningLog.LocalCore', 'LearningLog.Llm', 'LearningLog.PublishPreflight', 'LearningLog.PublishGitGuard', 'LearningLog.Publish', 'LearningLog.WeeklyAI') {
    $modulePath = Join-Path $root "app/core/$m.psm1"
    if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force -DisableNameChecking }   # 공개 킷에는 일부 모듈이 없다
}
$coreScripts = Get-ChildItem (Join-Path $root 'app/core') -Filter *.ps1 -File   # dot-source 되는 보조 스크립트의 함수도 인정

function Get-DefinedFunctions([string]$Path) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name }
}

$globalDefined = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($f in $coreScripts) { foreach ($n in (Get-DefinedFunctions $f.FullName)) { [void]$globalDefined.Add($n) } }

$targets = @(Get-ChildItem (Join-Path $root 'app') -Filter *.ps1 -File -Recurse) + @(Get-ChildItem (Join-Path $root 'run') -Filter *.ps1 -File)
$targets = $targets | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' }
$problems = [System.Collections.Generic.List[string]]::new()
$checked = 0
foreach ($t in $targets) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($t.FullName, [ref]$null, [ref]$null)
    $local = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in (Get-DefinedFunctions $t.FullName)) { [void]$local.Add($n) }
    $cmds = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name -or $name -notmatch '^[A-Z][A-Za-z]+-[A-Za-z0-9]+$') { continue }
        $checked++
        if ($local.Contains($name) -or $globalDefined.Contains($name)) { continue }
        if (Get-Command $name -ErrorAction SilentlyContinue) { continue }
        $problems.Add(('{0}:{1}  {2}' -f $t.Name, $c.Extent.StartLineNumber, $name))
    }
}
if ($problems.Count -gt 0) {
    $problems | Sort-Object -Unique | ForEach-Object { Write-Host "UNRESOLVED: $_" -ForegroundColor Red }
    throw ("FAIL: {0} unresolved command reference(s)" -f $problems.Count)
}
Write-Host ("PASS: all {0} command references resolve across {1} scripts" -f $checked, $targets.Count) -ForegroundColor Green
