# LearningLog Windows Local Runner (0.6.0)

The Windows PowerShell version of LearningLog: raw study notes -> reviewed blog drafts -> approved posts.

## Start

```powershell
.\LearningLog.bat
```

It opens `run\learninglog_launch.ps1` (PowerShell 7 / `pwsh` required).

## Folder layout (new in 0.6.0)

```text
local_powershell/
  LearningLog.bat        # double-click entry
  run/                   # entry points only (launcher + thin wrappers)
  app/                   # real implementation: one script per pipeline step
    core/                # shared modules (paths, registry, LLM calls, publish guards)
    tests/               # PowerShell smoke tests
  08_templates/          # post / note templates
```

`run\run_learninglog_*.ps1` are 4-line wrappers that call `app\run_learninglog_*.ps1`. Put new logic in `app\` or `app\core\`, never in `run\`.

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

## LLM backend

Scripts accept `-LMStudioModel` (default `local-model`, i.e. whatever model your LM Studio server has loaded) and also support Ollama. Set your own model name instead of editing scripts.

## What changed from 0.5.x

- Flat script folder replaced by `run/` + `app/` + `app/core/`.
- Added publish safety modules: `LearningLog.PublishGitGuard`, `LearningLog.PublishPreflight`.
- Added `repair_drafts`, `compose`, `dev_draft`, `daily_post`.
- Personal paths, model names and URLs removed; use placeholders (`<your-id>.github.io`).

Never commit your `00_inbox`, registry, publish history or any API key file.
