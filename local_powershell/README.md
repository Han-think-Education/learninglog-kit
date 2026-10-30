# LearningLog Windows Local Runner (0.7.0)

The Windows PowerShell version of LearningLog: raw study notes -> reviewed blog drafts -> approved posts.

## Start

```powershell
.\LearningLog.bat
```

It opens `run\learninglog_launch.ps1` (PowerShell 7 / `pwsh` required).

## Folder layout

```text
local_powershell/
  LearningLog.bat        # double-click entry
  run/                   # entry points only (launcher + thin wrappers)
  app/                   # real implementation: one script per pipeline step
    core/                # shared modules (see below)
    tests/               # PowerShell tests; tests/harness = fake LM server + sandbox runs
  08_templates/          # post / note templates
```

`run\run_learninglog_*.ps1` are 4-line wrappers that call `app\run_learninglog_*.ps1`. Put new logic in `app\` or `app\core\`, never in `run\`.

### Shared modules (`app/core`)

| Module | Role |
|---|---|
| `LearningLog.LocalCore` | paths, registry, drafts, QA badges, small text helpers (`ConvertTo-LLYamlString`, `Get-LLDraftSection`, ...) |
| `LearningLog.Llm` | LM Studio (OpenAI-compatible) client: `Invoke-LLMGenerate` (retries transient errors), `Invoke-LLMGenerateJson` |
| `LearningLog.Publish` | the publish stages: preflight -> targets ready -> copy -> deploy, plus a per-attempt context object |
| `LearningLog.PublishPreflight` | secret / path / policy checks before anything is copied |
| `LearningLog.PublishGitGuard` | Git boundary checks (clean tree, staged-path allowlist, no whole-repo `git add`) |

## Pipeline

`intake -> prep -> extract -> blogdraft -> register -> preview -> approve -> publish`

| Step | Script |
|---|---|
| intake | `run_learninglog_intake.ps1` |
| prep | `run_learninglog_prep.ps1` |
| extract / blogdraft | `run_learninglog_extract.ps1`, `run_learninglog_blogdraft.ps1` |
| register / preview / approve | `run_learninglog_register_drafts.ps1`, `..._preview.ps1`, `..._approve.ps1` |
| publish / unpublish | `run_learninglog_publish.ps1`, `run_learninglog_unpublish.ps1` |
| projects series | `run_learninglog_project_series.ps1` |
| daily | `run_learninglog_daily.ps1`, `run_learninglog_daily_post.ps1` |
| maintenance | `queue`, `review`, `cleanup`, `restructure`, `repair_drafts` |

`run_learninglog_publish.ps1` is a short orchestrator. Its stages live in `LearningLog.Publish` and run in a fixed, safety-first order: preflight of every selected file, repository and destination checks, copy, then Hugo build + push + records.

## LLM backend

LM Studio is the only engine. Scripts accept `-LMStudioModel` (default `local-model`, i.e. whichever model your LM Studio server has loaded) and `-LMStudioBase` (default `http://127.0.0.1:1234`). `-Engine` is kept for compatibility and only accepts `lm`. Transient LM errors (HTTP errors, timeouts, empty replies) are retried up to 3 times in `extract`, `blogdraft` and `repair_drafts`.

Blog location: the publish scripts use `<LearningLog parent>\Blog`, or the folder in the `LEARNINGLOG_BLOG_ROOT` environment variable.

## Tests

```powershell
pwsh -NoProfile -File app\tests\Test-CoreHelpers.ps1              # shared helper golden tests
pwsh -NoProfile -File app\tests\Test-CommandResolution.ps1        # every called command exists (AST lint)
pwsh -NoProfile -File app\tests\Test-PublishPreflight.ps1
pwsh -NoProfile -File app\tests\Test-PublishGitGuard.ps1
pwsh -NoProfile -File app\tests\Test-LLDraftRegistryBinding.ps1
pwsh -NoProfile -File app\tests\harness\Test-LlmHelpers.ps1       # LLM helper behavior vs recorded baseline (fake LM server)
pwsh -NoProfile -File app\tests\harness\Test-PipelineSandbox.ps1  # intake -> prep -> extract -> blogdraft in a throwaway folder
```

The harness tests never touch your real folders: they copy `app/`, `run/` and `08_templates/` into a temporary folder and talk to a fake LM server on `127.0.0.1:1299`. Run them from a short path (long paths make Git fail with "Filename too long").

## What changed from 0.6.x

- New `LearningLog.Publish` module; `run_learninglog_publish.ps1` shrinks to an orchestrator (about 370 lines instead of about 1,150).
- One LM client (`LearningLog.Llm`); Ollama code paths removed. `blogdraft` and `repair_drafts` now retry transient LM errors like `extract` did.
- Shared helpers moved into `LearningLog.LocalCore` instead of being copied per script.
- Fixes: YAML front matter escaping for titles containing quotes or backslashes; first run with an empty registry; `cleanup` used an undefined path variable; two helper functions were not exported (`Invoke-LLPublishGitCapture`, used by UI-selected publishing).
- Tests and fake-LM harness are included.

Never commit your `00_inbox`, registry, publish history or any API key file.
