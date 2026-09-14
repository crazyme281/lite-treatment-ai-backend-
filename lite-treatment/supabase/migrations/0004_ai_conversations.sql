-- ============================================================
-- AI conversation logs
-- Two distinct assistants, both explicitly non-diagnostic:
--   'cds'     — Clinical Decision Support for doctors/student doctors
--               (differential suggestions, protocol lookups, interaction
--               context). Never returns a diagnosis; always defers to
--               the treating physician.
--   'patient' — general health-information assistant for patients
--               (explains terms, prep for appointments, general
--               education). Never diagnoses or prescribes.
-- Logged for audit/traceability, same principle as the rest of the
-- platform's action logging.
-- ============================================================

create type ai_assistant_type as enum ('cds', 'patient');

create table public.ai_conversations (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id),
  assistant_type ai_assistant_type not null,
  related_case_id uuid references public.cases(id),
  related_patient_id uuid references public.profiles(id),
  title text,
  created_at timestamptz not null default now()
);

create table public.ai_messages (
  id uuid primary key default uuid_generate_v4(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  created_at timestamptz not null default now()
);

create index idx_ai_messages_conversation on public.ai_messages(conversation_id);
