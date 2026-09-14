# LiteTreatment

A production-ready, multi-role healthcare platform covering the full patient care journey — patients, doctors, student doctors in training, nurses, pharmacists, ambulance/EMS crews, and hospital managers, all on one system.

## Stack

```
lite-treatment/
├── supabase/           Database schema, Row Level Security, and Edge Functions
│   ├── migrations/     Postgres schema (versioned SQL)
│   ├── functions/      Deno Edge Functions (AI assistants, drug-interaction check)
│   └── seed.sql         Sample hospitals for local dev
└── ionic-frontend/     Ionic React + Vite + TypeScript, role-based pages
```

- **Backend & database**: Supabase (Postgres + PostGIS, Auth, Row Level Security, Edge Functions). There is no separate Node server — the frontend talks to Supabase directly, and RLS policies do the authorization work a custom API's middleware used to do.
- **Frontend**: Ionic React — works as a responsive web app today and is ready to ship to iOS/Android via Capacitor without a rewrite.
- **AI**: Two Supabase Edge Functions, both explicitly **non-diagnostic**:
  - `cds-assist` — Clinical Decision Support for doctors and student doctors. Suggests differential considerations and relevant protocols, flags interaction/allergy context from the patient's own record, and always defers final judgement to the treating physician. Every message is logged.
  - `patient-assist` — general health-information assistant for patients. Explains terms, helps prepare questions for a visit. Never diagnoses or prescribes; escalates to "contact your hospital" for anything urgent or specific.
  
  Both call an OpenAI-compatible chat completion endpoint — swap `AI_API_URL`/`AI_MODEL` to point at a different provider without touching the calling code.

## Why multi-role

| Role | What they do in the system |
|---|---|
| Patient | Multi-step onboarding, medical record, nearest-hospital finder, health-info AI assistant |
| Doctor / Consultant | Case queue, diagnosis notes, CDS assistant, reviews student doctor write-ups |
| **Student Doctor** | Practices patient interviews: structured question/answer log, own clinical summary, optional AI guidance, submits for supervisor feedback |
| Nurse | Ward duty board, shift handover notes |
| Pharmacist | Dispensing queue, drug-interaction checks |
| Ambulance / EMS | Live dispatch, status tracking, receiving-hospital handoff |
| Hospital Manager / Admin | Staffing breakdown, patient/dispatch analytics |

## Getting started

### 1. Supabase project

```bash
npm install -g supabase
supabase login
supabase link --project-ref your-project-ref
supabase db push          # applies migrations/ in order
supabase db execute -f supabase/seed.sql
```

Or run entirely locally with the Supabase CLI:

```bash
supabase start             # spins up local Postgres + Auth + Studio
supabase db reset          # applies migrations + seed.sql together
```

Set Edge Function secrets (for real AI responses — without these, both assistants return a clear placeholder message instead of failing):

```bash
supabase secrets set AI_API_KEY=sk-...
supabase secrets set AI_API_URL=https://api.openai.com/v1/chat/completions
supabase secrets set AI_MODEL=gpt-4o-mini
supabase functions deploy cds-assist
supabase functions deploy patient-assist
supabase functions deploy drug-interaction
```

### 2. Frontend

```bash
cd ionic-frontend
cp .env.example .env       # set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
npm install
npm run dev                 # http://localhost:5173
```

### 3. Ship to mobile (optional)

```bash
npm install -g @ionic/cli
ionic cap add ios
ionic cap add android
ionic cap sync
```

## Data model overview

`auth.users` → trigger creates a matching `profiles` row with a `role`. Patient-specific tables (`patient_profiles`, `medical_history`, `medical_entries`, `emergency_contacts`, `relatives`, `hospital_visits`) map directly to the original 8-step onboarding flow. Clinical tables (`cases`, `prescriptions`, `dispatches`) drive the doctor/pharmacist/ambulance dashboards. `student_encounters` + `encounter_questions` hold the student-doctor interview practice records. `ai_conversations` + `ai_messages` log every exchange with either assistant, scoped to the owning user by RLS.

## Security

- **Row Level Security is the access-control layer** — every clinically sensitive table is locked down by default (`supabase/migrations/0005_rls_policies.sql`); there is no way to query another patient's record from the client even with a valid session, short of a policy bug.
- Edge Functions use the **service-role key** internally (to log AI conversations across the RLS boundary), but each function independently re-checks the caller's JWT and role before doing anything — never trust that a function being reachable means the caller is authorized.
- `cds-assist` and `patient-assist` are prompt-constrained to be non-diagnostic; this is a starting point, not a substitute for clinical/regulatory review before real deployment. See the system prompts in each function for the exact constraints.
- Put a real drug-interaction data source behind `drug-interaction` before production use — the current table is a small illustrative reference set, not a licensed formulary.

## Known gaps / next steps

- No automated test suite yet for this stack (the previous Node/Express version had one; porting the same coverage to Supabase's local Postgres + Deno test runner is the natural next step).
- No CI pipeline for this stack yet.
- File/photo upload (patient profile photos, imaging) not yet wired to Supabase Storage.
- `drug-interaction` function isn't yet called from the doctor's prescribing flow — `prescriptions.interaction_warning` exists in the schema but nothing populates it yet from the client.
- The Hospital Digital Twin / predictive-ICU and NAFDAC drug-verification ideas from earlier project documentation are deliberately out of scope for this build — flagged as a possible future phase, not started.
