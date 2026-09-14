-- ============================================================
-- Student Doctor module
-- Lets a student doctor practice patient interviews under supervision:
-- pick/be assigned a patient, ask structured questions, write up
-- the patient's answers and their own clinical notes, and optionally
-- get non-diagnostic AI feedback on their write-up before a
-- supervising doctor reviews it.
-- ============================================================

create type encounter_status as enum ('draft', 'submitted', 'reviewed');

create table public.student_encounters (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid not null references public.profiles(id),
  patient_id uuid not null references public.profiles(id),
  supervising_doctor uuid references public.profiles(id),
  chief_complaint text,
  status encounter_status not null default 'draft',
  student_summary text,        -- the student's own written assessment
  supervisor_feedback text,    -- filled in once a doctor reviews it
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_at timestamptz
);

-- Each question the student asks + the patient's answer, in order —
-- this is the structured "interview" record, separate from the free-text summary.
create table public.encounter_questions (
  id uuid primary key default uuid_generate_v4(),
  encounter_id uuid not null references public.student_encounters(id) on delete cascade,
  question text not null,
  answer text,
  order_index int not null default 0,
  created_at timestamptz not null default now()
);

create index idx_encounter_questions_encounter on public.encounter_questions(encounter_id);
