#Requires -Version 7.0
<#
.SYNOPSIS
    LearningLog Project Series - 프로젝트 다편 초안 생성

.DESCRIPTION
    프로젝트 기록을 daily 학습 합본과 분리해서 04_blog_drafts\projects 에 생성합니다.
    생성 후에는 기존 흐름대로 register -> preview -> approve -> publish 를 사용합니다.

.PARAMETER Preset
    custom: 빈 프로젝트 시리즈 뼈대
    kaggle-house-prices: House Prices 프로젝트 회고 시리즈

.PARAMETER Slug
    파일명에 사용할 영문 slug. 비우면 제목/날짜 기준으로 안전한 값을 만듭니다.

.PARAMETER Title
    프로젝트 대표 제목.

.PARAMETER Date
    front matter 날짜와 파일명 날짜. 기본값은 오늘.

.PARAMETER WhatIfList
    파일을 만들지 않고 생성 예정 목록만 표시합니다.
#>

param(
    [ValidateSet("custom", "kaggle-house-prices")]
    [string]$Preset = "custom",
    [string]$Slug = "",
    [string]$Title = "",
    [datetime]$Date = (Get-Date),
    [switch]$NoPrompt,
    [switch]$WhatIfList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "core\LearningLog.LocalCore.psm1") -Force -DisableNameChecking

$ProjectsDir = Get-LLPath "04_blog_drafts\projects"
$TemplatePath = Get-LLPath "08_templates\project_series_post_template.md"
$RunTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function ConvertTo-ProjectSlug {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $s = $Text.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9가-힣\s_-]', ''
    $s = $s -replace '\s+', '-'
    $s = $s -replace '_+', '-'
    $s = $s -replace '-+', '-'
    $s = $s.Trim('-')
    if ($s -match '[가-힣]') { return ("project-" + (Get-Date -Format "yyyyMMdd")) }
    if ($s.Length -lt 3) { return ("project-" + (Get-Date -Format "yyyyMMdd")) }
    return $s
}

function Escape-Yaml {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -replace '"', '\"')
}

function New-Part {
    param(
        [int]$No,
        [string]$Suffix,
        [string]$Title,
        [string]$Description,
        [string[]]$Tags,
        [string[]]$Sections,
        [string]$SummaryLearned,
        [string]$SummaryCaution,
        [string]$SummaryNext
    )

    return [pscustomobject]@{
        No = $No
        Suffix = $Suffix
        Title = $Title
        Description = $Description
        Tags = $Tags
        Sections = $Sections
        SummaryLearned = $SummaryLearned
        SummaryCaution = $SummaryCaution
        SummaryNext = $SummaryNext
    }
}

function Get-CustomParts {
    param([string]$ProjectTitle)

    return @(
        (New-Part 1 "overview" "$ProjectTitle - 1. 프로젝트 개요와 목표" "프로젝트를 왜 시작했는지, 해결하려는 문제와 산출물을 정리한다." @("project", "overview") @(
            "## 1. 왜 이 프로젝트를 따로 기록하는가`n프로젝트는 하루 학습 기록과 달리 여러 날의 판단, 산출물, 수정 이유가 누적된다. 이 글은 프로젝트의 시작점과 목표를 따로 보관하기 위한 초안이다.",
            "## 2. 문제 정의`n해결하려는 문제, 사용자 또는 제출 기준, 최종 산출물을 한 문단으로 좁힌다. 막연한 아이디어보다 입력과 출력이 보이도록 적는다.",
            "## 3. 현재 가진 자료`n사용 가능한 데이터, 노트, 코드, 보고서, 참고 링크를 공개 가능한 범위에서 정리한다.",
            "## 4. 다음 액션`n다음 글에서 다룰 파이프라인, 분석, 검증 항목을 작은 단위로 나눈다."
        ) "프로젝트 글은 daily 합본과 분리해야 흐름이 보존된다는 점을 정리했다." "초안 단계에서 내부 자료나 원본 데이터를 그대로 노출하지 않도록 공개 범위를 먼저 확인해야 한다." "프로젝트 파이프라인과 산출물 구조를 이어서 정리한다."),
        (New-Part 2 "pipeline" "$ProjectTitle - 2. 파이프라인과 실행 흐름" "프로젝트를 재현 가능한 단계로 나누고 pipeline 문법의 의미를 정리한다." @("project", "pipeline") @(
            "## 1. 파이프라인을 먼저 쓰는 이유`n프로젝트가 커질수록 전처리, 특징 생성, 모델 학습, 평가가 뒤섞인다. pipeline 문법은 이 순서를 코드 안에 고정해서 같은 절차를 반복할 수 있게 만든다.",
            "## 2. 입력에서 산출물까지`n데이터 로드, 결측치 처리, 특징 변환, 학습, 검증, 제출 또는 보고서 생성의 흐름을 단계별로 적는다.",
            "## 3. 초보자가 헷갈리기 쉬운 지점`nfit과 transform의 순서, train과 test 분리, 검증 데이터 누수 여부를 프로젝트 점검표로 분리한다.",
            "## 4. 다음 액션`n분석 글에서는 어떤 실험이 있었고 어떤 기준으로 비교했는지 정리한다."
        ) "파이프라인은 코드 멋내기가 아니라 재현성과 누수 방지를 위한 구조라는 점을 정리했다." "수업에서 요구한 pipeline 문법을 생략하면 실험 비교가 흐려질 수 있다." "분석 기준과 실험 결과를 프로젝트 글로 분리한다."),
        (New-Part 3 "analysis" "$ProjectTitle - 3. 분석과 실험" "프로젝트에서 사용한 분석 축과 실험 결과를 정리한다." @("project", "analysis") @(
            "## 1. 분석을 여러 축으로 나누기`n한 번의 모델 점수만 보지 않고 데이터 이해, 특징 영향, 모델 비교, 오류 분석처럼 관점을 나눈다.",
            "## 2. 결과를 읽는 기준`n점수, 그래프, 표, 예측 오류를 함께 보면서 어떤 선택이 실제로 도움이 되었는지 판단한다.",
            "## 3. 기록할 산출물`n노트북, 표, 그래프, 제출 파일, 보고서 초안처럼 나중에 다시 확인할 파일을 명확히 적는다.",
            "## 4. 다음 액션`nLLM 리뷰 글에서는 같은 결과를 여러 모델이 어떻게 다르게 해석했는지 정리한다."
        ) "분석은 결과 하나가 아니라 비교 가능한 관점 묶음으로 남겨야 한다는 점을 정리했다." "그래프나 점수만 붙이면 판단 이유가 사라지므로 해석 문장을 같이 남겨야 한다." "LLM 리뷰와 사람의 판단을 분리해서 점검한다."),
        (New-Part 4 "llm-review" "$ProjectTitle - 4. LLM 리뷰와 해석 비교" "여러 LLM의 해석을 비교하고 프로젝트 판단에 반영할 기준을 정리한다." @("project", "llm-review") @(
            "## 1. LLM을 리뷰어로 쓰는 방식`nLLM은 정답 생성기가 아니라 누락된 관점, 설명의 빈틈, 보고서 문장 개선을 찾는 보조 리뷰어로 둔다.",
            "## 2. 비교해야 할 지점`n모델별로 강조한 위험, 해석 차이, 추천 액션, 과장된 표현을 따로 적는다.",
            "## 3. 사람이 최종 판단해야 하는 이유`nLLM이 제안한 문장을 그대로 쓰기보다 데이터와 코드 결과에 맞는지 다시 확인해야 한다.",
            "## 4. 다음 액션`n검증 글에서는 최종 제출 또는 발표 전에 확인할 항목을 정리한다."
        ) "LLM 리뷰는 프로젝트 판단을 넓히는 데 유용하지만 최종 근거는 코드와 데이터여야 한다는 점을 정리했다." "모델이 그럴듯한 문장을 만들어도 수치와 맞지 않으면 보고서에 넣지 않는다." "검증 체크리스트와 다음 개선안을 정리한다."),
        (New-Part 5 "validation" "$ProjectTitle - 5. 검증과 액션 플랜" "최종 검증, 제출 전 확인, 다음 개선 계획을 정리한다." @("project", "validation") @(
            "## 1. 제출 전 확인할 것`n데이터 누수, 파일 형식, 평가 지표, 실행 재현성, 보고서 문장과 수치 일치 여부를 확인한다.",
            "## 2. 결과를 어떻게 설명할 것인가`n잘된 점뿐 아니라 한계와 다음 개선 방향을 함께 적어야 프로젝트 기록이 신뢰를 얻는다.",
            "## 3. 다음 개선 후보`n새로운 특징, 모델 비교, 교차검증, 시각화, 발표 자료 개선처럼 실행 가능한 항목으로 남긴다.",
            "## 4. 프로젝트 회고`n이번 프로젝트에서 익힌 도구와 다음 프로젝트에 가져갈 습관을 분리해 적는다."
        ) "프로젝트 마무리는 제출이 아니라 재현성, 검증, 다음 액션까지 정리하는 과정이라는 점을 정리했다." "성공한 결과만 남기면 다음 프로젝트에서 같은 실수를 반복할 수 있다." "다음 프로젝트의 시작 템플릿으로 재사용한다.")
    )
}

function Get-HousePricesParts {
    return @(
        (New-Part 1 "overview" "Kaggle House Prices 첫 프로젝트 회고 - 1. 목표와 전체 흐름" "House Prices 프로젝트를 학습 프로젝트로 분리해 기록한 첫 글." @("kaggle", "house-prices", "project") @(
            "## 1. 왜 이 프로젝트를 따로 남기는가`nHouse Prices는 단순히 점수를 올리는 문제보다 프로젝트 흐름을 익히는 데 의미가 컸다. 데이터 파일을 읽고, 결측치와 범주형 변수를 다루고, 모델을 비교하고, 제출 파일을 만드는 전 과정이 하나의 작은 머신러닝 프로젝트였다.",
            "## 2. 프로젝트 목표`n목표는 집값을 예측하는 제출 파일을 만드는 것이지만, 학습 목표는 더 구체적이었다. 수업에서 강조한 pipeline 문법을 사용해 전처리와 모델 학습을 하나의 흐름으로 묶고, 같은 기준으로 실험을 비교하는 것이 핵심이었다.",
            "## 3. 산출물 기준`n최종 산출물은 제출 CSV, 분석 노트북, 모델 비교 메모, 발표용 요약 자료다. 이 네 가지가 서로 따로 놀지 않고 같은 실험 흐름을 설명해야 프로젝트 기록으로 의미가 생긴다.",
            "## 4. 이 시리즈의 구성`n이후 글은 pipeline 문법, 네 가지 분석 축, 네 가지 LLM 리뷰, 검증과 액션 플랜으로 나누어 정리한다."
        ) "프로젝트 글은 학습 daily와 달리 목표, 산출물, 판단 흐름을 오래 보존해야 한다는 점을 정리했다." "점수나 결과만 남기면 왜 그런 선택을 했는지 사라지므로 과정도 함께 기록해야 한다." "pipeline 문법을 중심으로 프로젝트 재현성을 정리한다."),
        (New-Part 2 "pipeline-syntax" "Kaggle House Prices 첫 프로젝트 회고 - 2. Pipeline 문법이 중요한 이유" "수업 지시사항이었던 pipeline 문법을 프로젝트 관점에서 해석한다." @("pipeline", "sklearn", "data-leakage") @(
            "## 1. Pipeline은 절차를 고정하는 문법이다`n초보자에게 pipeline은 처음에는 복잡해 보이지만, 실제 의미는 전처리와 모델을 순서대로 묶는 것이다. 결측치 처리, 스케일링, 원핫 인코딩, 모델 학습을 한 묶음으로 만들면 실험마다 같은 순서를 유지할 수 있다.",
            "## 2. 데이터 누수를 막는 기준`ntrain 데이터에서 배운 전처리 기준이 test 데이터에 섞이면 평가가 부풀려질 수 있다. Pipeline과 ColumnTransformer를 쓰면 fit은 학습 데이터에서만 하고, transform은 그 규칙을 적용하는 방식으로 분리하기 쉬워진다.",
            "## 3. 실험 비교가 쉬워지는 이유`n모델만 바꾸고 전처리 흐름은 유지하면 어떤 차이가 모델 때문인지 판단하기 쉬워진다. 반대로 매번 수작업으로 전처리를 바꾸면 결과가 좋아져도 이유를 설명하기 어렵다.",
            "## 4. 강사님 지시사항의 의미`npipeline 문법을 쓰라는 요구는 단순한 형식 요구가 아니라 프로젝트를 재현 가능하게 만들라는 뜻에 가깝다. 제출 파일 하나보다 같은 흐름을 다시 실행할 수 있는 코드가 더 중요해진다."
        ) "Pipeline은 초보자를 괴롭히는 문법이 아니라 실험 순서와 재현성을 지키는 장치라는 점을 정리했다." "전처리와 모델을 따로 수작업하면 데이터 누수와 실험 혼선이 생길 수 있다." "분석 결과를 여러 축으로 나누어 비교한다."),
        (New-Part 3 "four-analysis-tracks" "Kaggle House Prices 첫 프로젝트 회고 - 3. 네 가지 분석 축" "데이터 이해, 특징 설계, 모델 비교, 오류 점검을 분리해 본다." @("eda", "model-comparison", "analysis") @(
            "## 1. 데이터 이해 분석`n먼저 SalePrice 분포, 결측치, 범주형 변수, 수치형 변수의 기본 구조를 확인한다. 이 단계는 모델을 돌리기 전 문제의 지형을 보는 과정이다.",
            "## 2. 특징 설계 분석`n전체 면적, 품질 등급, 건축 연도, 리모델링 여부처럼 집값에 영향을 줄 만한 변수를 살핀다. 초보 단계에서는 복잡한 특징보다 의미를 설명할 수 있는 특징을 우선한다.",
            "## 3. 모델 비교 분석`n단순 선형 모델, 규제가 들어간 선형 모델, 트리 기반 모델을 같은 평가 기준으로 비교한다. 모델을 늘리는 것보다 같은 검증 방식으로 비교하는 것이 더 중요하다.",
            "## 4. 오류와 위험 분석`n예측이 크게 빗나가는 구간, 고가 주택, 결측이 많은 행, 특이한 조합을 확인한다. 이 분석은 점수보다 보고서의 신뢰도를 높이는 데 도움이 된다."
        ) "프로젝트 분석은 한 줄 점수가 아니라 데이터, 특징, 모델, 오류를 따로 보는 구조가 필요하다는 점을 정리했다." "그래프와 수치를 붙일 때 해석 없이 나열하면 보고서가 약해진다." "여러 LLM 리뷰를 비교해 설명의 빈틈을 찾는다."),
        (New-Part 4 "four-llm-review" "Kaggle House Prices 첫 프로젝트 회고 - 4. 네 가지 LLM 리뷰 관점" "LLM을 프로젝트 해석 보조 도구로 쓰는 방식을 정리한다." @("llm", "review", "report") @(
            "## 1. 코드 리뷰 관점`nLLM에게 코드를 보여줄 때는 실행 흐름, 데이터 누수 가능성, 제출 파일 형식 오류를 먼저 점검하게 한다. 이때 LLM의 답은 제안일 뿐이고 실제 코드는 직접 확인해야 한다.",
            "## 2. 분석 보고서 관점`n결과 표와 그래프를 보고 어떤 해석이 빠졌는지 묻게 하면 보고서 문장이 보강된다. 특히 초보자 글에서는 왜 이 그래프를 봤는지가 빠지기 쉽다.",
            "## 3. 발표 자료 관점`n발표용으로는 기술 세부사항보다 문제 정의, 방법, 결과, 한계를 짧게 연결해야 한다. LLM은 긴 내용을 요약해 구조를 잡는 데 도움이 된다.",
            "## 4. 학습 회고 관점`n마지막으로 LLM에게 내가 헷갈린 점과 다음 학습 주제를 뽑게 하면 프로젝트가 다음 공부로 이어진다. 이 관점은 daily 학습과 projects 기록을 연결해 준다."
        ) "LLM은 프로젝트를 대신 판단하는 도구가 아니라 코드, 보고서, 발표, 회고를 점검하는 보조 리뷰어라는 점을 정리했다." "LLM이 만든 그럴듯한 표현을 수치 검증 없이 그대로 쓰면 위험하다." "최종 검증과 다음 액션 플랜을 정리한다."),
        (New-Part 5 "validation-action-plan" "Kaggle House Prices 첫 프로젝트 회고 - 5. 검증과 다음 액션" "최종 제출 전 점검과 다음 프로젝트로 가져갈 기준을 정리한다." @("validation", "action-plan", "portfolio") @(
            "## 1. 제출 전 검증`n제출 CSV의 열 이름, 행 개수, 예측값 범위, 결측 여부를 확인한다. 모델 점수가 좋아도 제출 형식이 틀리면 프로젝트 결과물로 볼 수 없다.",
            "## 2. 보고서 검증`n보고서의 수치, 그래프, 코드 결과가 서로 같은 실험을 말하는지 확인한다. 서로 다른 버전의 결과가 섞이면 읽는 사람이 흐름을 믿기 어렵다.",
            "## 3. 포트폴리오 관점`n포트폴리오로 남길 때는 최고 점수보다 문제를 어떻게 읽고, 어떤 기준으로 실험했고, 무엇을 다음 액션으로 남겼는지가 중요하다.",
            "## 4. 다음 액션`n다음 프로젝트에서는 시작부터 폴더 구조, pipeline 코드, 모델 비교 표, LLM 리뷰 기록을 함께 남긴다. 이렇게 하면 마지막에 급하게 보고서를 맞추는 부담이 줄어든다."
        ) "프로젝트 마무리는 제출 파일, 보고서, 재현성, 다음 액션까지 함께 닫는 과정이라는 점을 정리했다." "최종 결과가 여러 파일에 흩어지면 어떤 버전이 맞는지 헷갈릴 수 있다." "다음 프로젝트 템플릿에 이번 검증 목록을 반영한다.")
    )
}

if (-not $NoPrompt -and $Preset -eq "custom" -and -not $Title -and -not $Slug) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  LearningLog Project Series" -ForegroundColor Cyan
    Write-Host "  $RunTime" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  [1] Kaggle House Prices 프로젝트 회고 시리즈" -ForegroundColor Yellow
    Write-Host "  [2] 빈 프로젝트 시리즈 뼈대" -ForegroundColor Cyan
    Write-Host "  [Q] 취소" -ForegroundColor DarkGray
    Write-Host ""
    $choice = (Read-Host "  선택").Trim().ToUpperInvariant()
    switch ($choice) {
        "1" { $Preset = "kaggle-house-prices" }
        "2" { $Preset = "custom" }
        "Q" { Write-Host "  취소됨." -ForegroundColor DarkGray; exit 0 }
        default { Write-Host "  취소됨." -ForegroundColor DarkGray; exit 0 }
    }
}

if ($Preset -eq "kaggle-house-prices") {
    if (-not $Title) { $Title = "Kaggle House Prices 첫 프로젝트 회고" }
    if (-not $Slug) { $Slug = "kaggle-house-prices-first-project" }
    $parts = @(Get-HousePricesParts)
} else {
    if (-not $Title -and -not $NoPrompt) { $Title = (Read-Host "  프로젝트 대표 제목").Trim() }
    if (-not $Title) { $Title = "새 프로젝트 기록" }
    if (-not $Slug -and -not $NoPrompt) { $Slug = (Read-Host "  영문 slug (비우면 자동)").Trim() }
    if (-not $Slug) { $Slug = ConvertTo-ProjectSlug $Title }
    $parts = @(Get-CustomParts -ProjectTitle $Title)
}

$DateText = $Date.ToString("yyyy-MM-dd")
$Slug = ConvertTo-ProjectSlug $Slug

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Project Series Drafts" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  프로젝트: {0}" -f $Title) -ForegroundColor White
Write-Host ("  slug:     {0}" -f $Slug) -ForegroundColor DarkGray
Write-Host ("  날짜:     {0}" -f $DateText) -ForegroundColor DarkGray
Write-Host ""

if (-not (Test-Path -LiteralPath $ProjectsDir)) {
    if (-not $WhatIfList) { New-Item -ItemType Directory -Path $ProjectsDir -Force | Out-Null }
}

$created = 0
$skipped = 0
foreach ($part in $parts) {
    $fileName = "{0}-{1}-{2:D2}-{3}.md" -f $DateText, $Slug, [int]$part.No, $part.Suffix
    $path = Join-Path $ProjectsDir $fileName
    $rel = "04_blog_drafts/projects/$fileName"
    $tagText = (($part.Tags + @("projects")) | Select-Object -Unique | ForEach-Object { '"' + (Escape-Yaml $_) + '"' }) -join ", "
    $fullTitle = Escape-Yaml $part.Title
    $desc = Escape-Yaml $part.Description

    $front = @(
        "---",
        "title: `"$fullTitle`"",
        "date: $DateText",
        "draft: true",
        "categories: [`"projects`"]",
        "tags: [$tagText]",
        "description: `"$desc`"",
        "---",
        ""
    ) -join "`n"

    $bodyLines = [System.Collections.Generic.List[string]]::new()
    foreach ($section in $part.Sections) {
        $bodyLines.Add($section)
        $bodyLines.Add("")
    }
    $bodyLines.Add("## 총평")
    $bodyLines.Add("")
    $bodyLines.Add("### 이번 글에서 정리한 것")
    $bodyLines.Add($part.SummaryLearned)
    $bodyLines.Add("")
    $bodyLines.Add("### 다음에 조심할 것")
    $bodyLines.Add($part.SummaryCaution)
    $bodyLines.Add("")
    $bodyLines.Add("### 다음 액션")
    $bodyLines.Add($part.SummaryNext)
    $bodyLines.Add("")
    $bodyLines.Add("> 이 글은 LearningLog projects 흐름에서 생성한 프로젝트 시리즈 초안입니다.")

    $body = Add-LLTableOfContents -Body (($bodyLines | ForEach-Object { [string]$_ }) -join "`n")
    $content = ($front + $body.TrimStart()).TrimEnd() + "`n"

    if ($WhatIfList) {
        Write-Host ("  [예정] {0}" -f $rel) -ForegroundColor Cyan
        continue
    }
    if (Test-Path -LiteralPath $path) {
        Write-Host ("  [건너뜀] 이미 있음: {0}" -f $rel) -ForegroundColor DarkGray
        $skipped++
        continue
    }
    Write-LLText -Path $path -Content $content
    Write-Host ("  [생성] {0}" -f $rel) -ForegroundColor Green
    $created++
}

Write-Host ""
if ($WhatIfList) {
    Write-Host ("  생성 예정: {0}개" -f $parts.Count) -ForegroundColor Yellow
} else {
    Write-Host ("  생성 완료: {0}개 / 건너뜀: {1}개" -f $created, $skipped) -ForegroundColor Green
}
Write-Host ""
Write-Host "  다음 순서:" -ForegroundColor Cyan
Write-Host "  1) 프로젝트 메뉴 [2] 초안 등록" -ForegroundColor Cyan
Write-Host "  2) 프로젝트 메뉴 [3] 미리보기" -ForegroundColor Cyan
Write-Host "  3) 프로젝트 메뉴 [4] 승인본 이동" -ForegroundColor Cyan
Write-Host "  4) 프로젝트 메뉴 [5] 발행하기" -ForegroundColor Cyan
if (Test-Path -LiteralPath $TemplatePath) {
    Write-Host ("  템플릿: {0}" -f $TemplatePath) -ForegroundColor DarkGray
}
Write-Host "========================================" -ForegroundColor Cyan
