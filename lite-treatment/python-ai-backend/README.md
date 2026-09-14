# LiteTreatment AI Backend (Python / FastAPI) — v3

Reimplements the two AI "suggestion" assistants — `cds-assist` (doctor
Clinical Decision Support) and `patient-assist` (patient health-info chat)
— as a standalone Python service, built against the architecture audit:
safety gates, relevance-filtered retrieval, validated structured output,
a critic pass, and model routing — not just "bigger prompt, bigger model."

## Architecture

```
User message
    │
    ▼
Deterministic safety gate (safety.py)  ── no AI call, can't be "reasoned around"
    │
    ▼
Retrieval (retrieval.py)
    ├─ Patient context — ALWAYS includes allergies/medications;
    │  everything else (visits, conditions) relevance-filtered
    │  against the message, not dumped wholesale
    └─ Protocol search — full-text search over clinical_protocols
    │
    ▼
Conversation memory (conversation.py)
    ├─ Last N raw messages (config.RECENT_MESSAGE_WINDOW)
    └─ Rolling summary of everything older (doesn't grow forever)
    │
    ▼
Model routing (retrieval.classify_complexity) — cheap model for
simple questions, reasoning-tier model for complex/flagged cases
    │
    ▼
Structured draft (ai_client.generate_assessment) — JSON schema via
schema.py, not free-form prose
    │
    ▼
Deterministic protocol-citation validation (schema.py) — strips any
protocol the model claims that wasn't actually in the retrieved list
    │
    ▼
Critic pass (ai_client.critique) — a second, cheaper-model call reviews
the draft; one regeneration attempt if it flags a real problem
    │
    ▼
Save to Supabase + render to the existing chat UI
```

`/patient-assist` uses the same safety gate and protocol grounding, but
skips the structured-JSON/critic machinery — that's scoped to the
clinician-facing tool per the audit's own priority ordering.

## What this audit-driven rewrite fixed, concretely

| Problem | Fix |
|---|---|
| No conversation memory | Recent-message window + rolling summary (three-layer memory) |
| Context = entire record dump | Relevance-filtered (allergies/meds always kept; visits/conditions filtered by keyword overlap with the message) |
| Free-form prose, no way to verify claims | Structured JSON schema with a robust parse-or-degrade-gracefully fallback |
| Model could cite protocols that don't exist | Deterministic post-hoc validation — hallucinated citations are stripped, never trusted |
| No emergency detection | Deterministic keyword-based safety gate runs BEFORE any AI call |
| One model size for every question | Complexity-based routing between a fast and a reasoning-tier model |
| No self-checking | A critic pass reviews the draft and can trigger one regeneration |
| Only "the plumbing works" tests | 38 passing tests: safety detection, schema parsing/fallback, citation validation, relevance filtering, full pipeline integration — plus a 15-case eval scaffold (honestly scoped: the audit calls for 50-100; this is a real starting set, not the full thing) |

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `SUPABASE_URL` | Yes | `https://<project-ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | Yes | The anon/publishable key — never the service-role key (see Security below) |
| `AI_API_KEY` | No | OpenAI-compatible API key. Without it, every endpoint returns an honest placeholder instead of failing |
| `AI_API_URL` | No | Defaults to `https://api.openai.com/v1/chat/completions` |
| `AI_MODEL_FAST` | No | Defaults to `gpt-4o-mini` — used for simple questions and the critic pass |
| `AI_MODEL_REASONING` | No | Defaults to `gpt-4o` — used for complex/flagged cases |
| `AI_MAX_TOKENS` | No | Defaults to `900` |
| `RECENT_MESSAGE_WINDOW` | No | Defaults to `10` — messages older than this get summarized instead of resent |
| `ALLOWED_ORIGINS` | No | Comma-separated CORS origins, defaults to `*` |

## Security design

No service-role key, anywhere. Every request creates a Supabase client
scoped to the caller's own access token and lets your existing RLS
policies decide what it can read/write — the same permissions a doctor's
own browser session already has.

## Run locally

```bash
cd python-ai-backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
SUPABASE_URL=https://hrqtxedviwwkjwkfrhth.supabase.co \
SUPABASE_ANON_KEY=your-anon-key \
uvicorn app.main:app --reload --port 8000
```

`curl http://localhost:8000/health` → `{"status":"ok",...}`

## Run the tests

```bash
SUPABASE_URL=https://hrqtxedviwwkjwkfrhth.supabase.co SUPABASE_ANON_KEY=test_key \
pytest -v
```

38 tests run with zero external dependencies (no AI key, no live Supabase
needed — everything's mocked at the boundary). The 9 model-dependent eval
cases in `tests/test_eval_suite.py` are skipped without a real `AI_API_KEY`
— set one to actually evaluate answer quality against a live model:

```bash
AI_API_KEY=sk-... SUPABASE_URL=... SUPABASE_ANON_KEY=... pytest tests/test_eval_suite.py -v
```

## Deploy to Render

Render deploys from a Git repository it can clone — push this project to
GitHub/GitLab/Bitbucket, then either use the Render dashboard (New → Web
Service → connect the repo → Root Directory `python-ai-backend` if it's
part of a monorepo → Build Command `pip install -r requirements.txt` →
Start Command `uvicorn app.main:app --host 0.0.0.0 --port $PORT`), or hand
the repo URL to Claude to finish via the already-connected Render account.

## Frontend wiring

Set `VITE_AI_BACKEND_URL` in `ionic-frontend/.env` to the deployed Render
URL. `AiChatPanel.tsx` already checks for this and switches from Supabase
Edge Functions to this backend automatically — no other frontend change
needed, and the response shape is backward-compatible (`reply` and
`conversationId` are unchanged; `structured` is additive).
