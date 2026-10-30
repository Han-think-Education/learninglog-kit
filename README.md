# learninglog-kit

**한국어** | [English](#english-guide)

개인 학습 노트를 자동으로 정리해주는 파이프라인 도구.
노트를 폴더에 넣으면 LLM이 핵심 추출 → 워킹 노트 → 블로그 초안까지 만들어줍니다.

---

## 현재 배포 구성

이 저장소는 공개 가능한 킷만 관리합니다. 개인 LearningLog 작업 폴더, `00_inbox`, registry, 발행 이력, API 키 파일은 올리지 않습니다.

| 킷 | 버전 | 위치 | 용도 |
|----|------|------|------|
| LearningLog Python/Web UI | 0.6.0 | `src/learninglog/` | Python 패키지와 브라우저 UI |
| LearningLog Windows Runner | 0.6.0 | `local_powershell/` | Windows PowerShell 로컬 운영판 |
| DailyLog Kit | 1.2 | `dailylog_kit/` | 하루 회고 Markdown 생성기 |

### v0.6.0 변경점 (2026-10)

- Windows Runner 폴더 구조 정리: `run/`(진입점) + `app/`(구현) + `app/core/`(공용 모듈) + `08_templates/`
- 발행 안전장치 모듈 추가: `LearningLog.PublishGitGuard`, `LearningLog.PublishPreflight`
- 초안 수리(`repair_drafts`), 합성(`compose`), 개발 초안(`dev_draft`), 데일리 글(`daily_post`) 추가
- 개인 경로·모델명·URL을 제거하고 플레이스홀더로 일반화 (`-LMStudioModel` 기본값 `local-model`)
- Python 패키지 버전만 0.6.0으로 맞춤 (기능 변경 없음)

### v0.5.4 / DailyLog 1.2 변경점

- Windows Runner에 `LearningLog / Projects / Daily` 메뉴 분리 구조 포함
- 프로젝트 시리즈 초안 생성기 포함: `local_powershell/run_learninglog_project_series.ps1`
- register / preview / approve / publish의 section 필터 흐름 포함
- DailyLog Kit을 저장소에 추가
- DailyLog Kit에서 Ollama뿐 아니라 Gemini API 키 사용 지원

---

## v0.5 Beginner Flow — 아무것도 몰라도 쓰는 순서

1. Python 3.10+ 설치 확인: `python --version`
2. ZIP 또는 pip로 설치: `pip install "learninglog-kit[web,gemini]"`
3. UI 실행: `learninglog ui`
4. UI에 API 키, 블로그 소스 폴더, GitHub repo URL, Pages URL 입력
5. `00_inbox/lectures/`에는 PDF/ipynb, `00_inbox/personal_notes/`에는 내 md 노트 넣기
6. UI에서 `intake 등록`을 눌러 새 파일/중복/hash/public_policy 확인
7. md 개인 노트만 `extract`, 검토된 draft만 `publish`, 마지막에 `GitHub push`

> API 키는 초보자 편의를 위해 `config.yaml` 저장을 기본으로 합니다. `.learninglog/config.yaml`은 `.gitignore`에 포함되어야 하며 GitHub에 올리면 안 됩니다.

---

## 가장 쉬운 시작 — 웹 UI (추천)

```bash
pip install "learninglog-kit[web,gemini]"
learninglog ui
```

브라우저(`http://127.0.0.1:8765`)가 열리면:
1. **작업 폴더 생성** 버튼 클릭
2. **Gemini** 선택 → [API 키 발급](https://aistudio.google.com/app/apikey) → 키 붙여넣기 → 저장+테스트
3. `00_inbox/personal_notes/` 에 노트(.md) 넣기
4. 블로그/GitHub 주소 입력
5. **① intake → ② extract → ③ publish → ④ GitHub push** 버튼 클릭

설치·설정·실행을 전부 버튼으로. 터미널 명령 몰라도 됩니다.

---

## Windows 로컬 운영판

Windows에서 전체 로컬 운영판을 쓰려면:

```powershell
cd local_powershell
.\LearningLog.bat
```

첫 화면은 역할별로 나누어져 있습니다.

```text
[1] LearningLog    학습 기록/발행
[2] Projects       프로젝트 시리즈
[3] Daily          별도 회고 기록
[0] Ollama 서버 시작
```

`LearningLog`는 수업/학습 합본을, `Projects`는 프로젝트 회고와 분석 시리즈를, `Daily`는 별도 개인 회고 기록을 다룹니다.

---

## DailyLog Kit 1.2

가볍게 하루 회고 Markdown만 만들고 싶다면:

```powershell
cd dailylog_kit
.\DailyLog.bat
```

LLM 없이 템플릿만 만들 수 있고, Ollama 또는 Gemini로 자동 정리할 수도 있습니다.

```powershell
# Gemini API 키를 한 번만 직접 사용
.\dailylog.ps1 -Provider gemini -GeminiApiKey "YOUR_KEY"

# Gemini API 키를 dailylog.config.json에 저장
.\dailylog.ps1 -Provider gemini -GeminiApiKey "YOUR_KEY" -SaveGeminiKey

# 환경변수 사용
$env:GEMINI_API_KEY = "YOUR_KEY"
.\dailylog.ps1 -Provider gemini

# Ollama 사용
.\dailylog.ps1 -Provider ollama -Model gemma3:12b
```

Gemini 키는 [Google AI Studio](https://aistudio.google.com/app/apikey)에서 받을 수 있습니다. 저장되는 `dailylog.config.json`은 `.gitignore`에 포함되어 있으므로 GitHub에 올리지 않습니다.

---

## 빠른 시작 — 터미널 (한국어)

### 1. 설치

```bash
# 기본 설치 (Ollama 로컬 모델용)
pip install learninglog-kit

# Gemini 무료 API 사용 시
pip install "learninglog-kit[gemini]"

# Groq 무료 API 사용 시
pip install "learninglog-kit[groq]"

# 전체 설치
pip install "learninglog-kit[all]"
```

### 2. 프로젝트 초기화

```bash
mkdir my-learning
cd my-learning
learninglog init
```

### 3. LLM 설정

`.learninglog/config.yaml` 파일을 열어 LLM을 선택합니다.

```bash
code .learninglog/config.yaml   # VS Code로 열기
```

**무료 옵션 (추천):**

```yaml
llm:
  provider: "gemini"      # 구글 계정만 있으면 무료
  gemini:
    api_key: "AIza..."    # aistudio.google.com 에서 발급
    model: "gemini-2.5-flash"
```

→ 자세한 설정 방법: [docs/llm-providers.md](docs/llm-providers.md)

### 4. 노트 넣기

```
my-learning/
└── 00_inbox/
    └── personal_notes/    ← 여기에 .md 파일을 넣으세요
```

### 5. 실행

```bash
learninglog intake     # 새 파일 감지 및 등록
learninglog queue      # 처리 순서 확인
learninglog extract    # LLM으로 노트 + 블로그 초안 생성
learninglog publish    # 블로그로 발행 (blog 설정 시)
```

---

## 명령어 목록

| 명령어 | 설명 |
|-------|------|
| `learninglog ui` | **브라우저 설정/실행 UI** (설치·API키·실행을 버튼으로) |
| `learninglog init [폴더]` | 프로젝트 폴더 구조 생성 + LLM 설정 마법사 |
| `learninglog intake` | 새 파일 자동 등록 |
| `learninglog queue` | 처리 대기 목록 확인 |
| `learninglog extract` | LLM으로 extract + working_note + blog_draft 생성 |
| `learninglog publish` | 초안을 블로그로 발행 (draft:false + ai_assisted 마킹 + hugo 빌드) |
| `learninglog push` | 설정된 블로그 Git 저장소에 명시적으로 git add/commit/push |
| `learninglog status` | 전체 현황 요약 |
| `learninglog doctor` | 설정 및 LLM 연결 진단 |
| `learninglog clean` | 생성 **데이터만** 정리 (재시작용, 패키지 유지) |
| `learninglog uninstall` | 프로그램 + 데이터 **모두 제거** (install 의 반대) |

### 설치 ↔ 제거 (install ↔ uninstall)

| 개념 | 대상 | 명령 |
|------|------|------|
| **install** | 프로그램 설치 | `pip install "learninglog-kit[web,gemini]"` |
| **uninstall** | 프로그램 + 데이터 제거 | `learninglog uninstall` |

### 데이터만 정리 (clean — 재시작용)

```bash
learninglog clean             # 생성물만 (02~06, 09_reports)
learninglog clean --config    # 설정(.learninglog)도
learninglog clean --api-key   # ~/.bashrc 의 API 키 줄 제거
learninglog clean --all -y    # 데이터 전부 (패키지는 유지)
```

### 완전 제거 (uninstall)

```bash
learninglog uninstall         # 데이터 정리 + pip 패키지 제거 (한 번에)
learninglog uninstall --keep-package  # 데이터만, 패키지 유지
```

> `00_inbox/` 의 원본 노트는 **어떤 경우에도 자동 삭제되지 않습니다.** 직접 지우세요.

### 블로그/GitHub 발행 설정

`.learninglog/config.yaml` 의 `blog` 섹션:
```yaml
blog:
  platform:    "hugo"            # hugo | jekyll | none
  source_path: "../blog-source"  # 블로그 소스 폴더
  github_repo_url: "https://github.com/USER/REPO"
  pages_url: "https://USER.github.io/"
  auto_build:  true              # hugo 빌드 실행
  auto_push:   true              # UI/CLI push 버튼 사용
```

---

## 반복문 수업 예시 — 파일 처리 컨베이어 벨트

LearningLog Kit의 `intake`는 반복문이 실제 자동화에서 어떻게 쓰이는지 보여주는 예시입니다.

```python
for file in inbox_files:
    if is_new_file(file):
        register_to_source_registry(file)
```

실제 동작은 다음과 같습니다.

- `00_inbox` 안의 PDF, ipynb, md, zip, 이미지를 하나씩 훑습니다.
- 파일 hash를 계산해 이미 등록된 자료인지 확인합니다.
- 파일 종류에 따라 `lecture_pdf`, `practice_notebook`, `personal_note` 등으로 분류합니다.
- 강의 원본 PDF와 zip, screenshot은 `internal-only`로 막아 블로그 공개 사고를 예방합니다.
- 실행 후 `09_reports/RUN_..._intake_report.md`에 신규/중복/오류 요약을 남깁니다.

PDF와 ipynb는 기본적으로 “등록과 추적”까지만 자동화합니다. 블로그 초안은 내가 재작성한 md 개인 노트에서 만드는 것이 안전합니다.

---

## LLM 선택 가이드

| 옵션 | 비용 | 설치 난이도 | 속도 | 프라이버시 |
|------|------|------------|------|-----------|
| **Gemini** | 무료 (일 1,500회) | 쉬움 | 빠름 | 클라우드 |
| **Groq** | 무료 (일 14,400회) | 쉬움 | 매우 빠름 | 클라우드 |
| **Ollama** | 완전 무료 | 앱 설치 필요 | 로컬 속도 | 로컬 (최고) |
| **Claude** | 유료 | 쉬움 | 빠름 | 클라우드 |
| **OpenAI** | 유료 | 쉬움 | 빠름 | 클라우드 |

→ [docs/llm-providers.md](docs/llm-providers.md) 에서 단계별 설정 방법 확인

---

## 파이프라인 구조

```
00_inbox/  →  intake  →  queue  →  extract
                                      ↓
                              02_extracted/       (사실 추출)
                              03_working_notes/   (워킹 노트)
                                      ↓
                              (검토 후) 04_blog_drafts/
                                      ↓
                              (승인 후) blog-source/
```

---

---

# English Guide

A personal learning pipeline tool.
Drop your notes into a folder — LLM extracts key facts, creates working notes, and drafts blog posts.

## Quick Start

### 1. Install

```bash
# Basic install (for Ollama local models)
pip install learninglog-kit

# With Gemini free API
pip install "learninglog-kit[gemini]"

# With Groq free API
pip install "learninglog-kit[groq]"

# Everything
pip install "learninglog-kit[all]"
```

### 2. Initialize Project

```bash
mkdir my-learning
cd my-learning
learninglog init
```

### 3. Configure LLM

Open `.learninglog/config.yaml` and choose your LLM provider.

**Free option (recommended for beginners):**

```yaml
llm:
  provider: "gemini"
  gemini:
    api_key: "AIza..."    # Get free key at aistudio.google.com
    model: "gemini-2.5-flash"
```

See [docs/llm-providers.md](docs/llm-providers.md) for all options.

### 4. Add Your Notes

```
my-learning/
└── 00_inbox/
    └── personal_notes/    ← Put your .md files here
```

### 5. Run

```bash
learninglog intake     # Detect and register new files
learninglog queue      # See processing priority
learninglog extract    # Generate notes with LLM
```

## Commands

| Command | Description |
|---------|-------------|
| `learninglog init [path]` | Create project folder structure |
| `learninglog intake` | Auto-register new files |
| `learninglog queue` | View processing queue |
| `learninglog extract` | Run LLM: extract facts + working notes |
| `learninglog status` | Show pipeline summary |
| `learninglog doctor` | Diagnose config and LLM connection |

## LLM Options

| Option | Cost | Setup | Speed | Privacy |
|--------|------|-------|-------|---------|
| **Gemini** | Free (1,500/day) | Easy | Fast | Cloud |
| **Groq** | Free (14,400/day) | Easy | Very fast | Cloud |
| **Ollama** | Free forever | App install | Local speed | Local (best) |
| **Claude** | Paid | Easy | Fast | Cloud |
| **OpenAI** | Paid | Easy | Fast | Cloud |

## Requirements

- Python 3.10+
- Git Bash or any terminal
- One LLM option configured (see table above)
