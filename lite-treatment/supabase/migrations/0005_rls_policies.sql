-- ============================================================
-- Row Level Security
-- Every clinically sensitive table is locked down by default;
-- policies below grant exactly the access each role needs.
-- ============================================================

alter table public.profiles enable row level security;
alter table public.hospitals enable row level security;
alter table public.patient_profiles enable row level security;
alter table public.medical_history enable row level security;
alter table public.medical_entries enable row level security;
alter table public.emergency_contacts enable row level security;
alter table public.relatives enable row level security;
alter table public.hospital_visits enable row level security;
alter table public.cases enable row level security;
alter table public.prescriptions enable row level security;
alter table public.dispatches enable row level security;
alter table public.student_encounters enable row level security;
alter table public.encounter_questions enable row level security;
alter table public.ai_conversations enable row level security;
alter table public.ai_messages enable row level security;

-- Helper: current user's role, read once per statement
create or replace function public.current_role()
returns user_role as $$
  select role from public.profiles where id = auth.uid();
$$ language sql stable security definer;

create or replace function public.is_clinician_or_admin()
returns boolean as $$
  select public.current_role() in ('doctor', 'nurse', 'admin', 'student_doctor');
$$ language sql stable security definer;

-- ---- profiles ----
create policy "profiles are readable by owner, clinicians, admin"
  on public.profiles for select
  using (id = auth.uid() or public.is_clinician_or_admin());
create policy "users update their own profile"
  on public.profiles for update using (id = auth.uid());

-- ---- hospitals: public reference data ----
create policy "hospitals are publicly readable"
  on public.hospitals for select using (true);
create policy "only admins manage hospitals"
  on public.hospitals for all using (public.current_role() = 'admin');

-- ---- patient_profiles / medical_history / emergency_contacts ----
-- Pattern repeated per table: owner (patient) or clinician/admin can read+write.
create policy "patient_profiles: owner or clinician"
  on public.patient_profiles for select
  using (user_id = auth.uid() or public.is_clinician_or_admin());
create policy "patient_profiles: owner or clinician write"
  on public.patient_profiles for all
  using (user_id = auth.uid() or public.is_clinician_or_admin());

create policy "medical_history: owner or clinician"
  on public.medical_history for select
  using (user_id = auth.uid() or public.is_clinician_or_admin());
create policy "medical_history: owner or clinician write"
  on public.medical_history for all
  using (user_id = auth.uid() or public.is_clinician_or_admin());

create policy "medical_entries: owner or clinician"
  on public.medical_entries for select
  using (patient_id = auth.uid() or public.is_clinician_or_admin());
create policy "medical_entries: owner or clinician write"
  on public.medical_entries for all
  using (patient_id = auth.uid() or public.is_clinician_or_admin());

create policy "emergency_contacts: owner or clinician"
  on public.emergency_contacts for select
  using (patient_id = auth.uid() or public.is_clinician_or_admin());
create policy "emergency_contacts: owner or clinician write"
  on public.emergency_contacts for all
  using (patient_id = auth.uid() or public.is_clinician_or_admin());

create policy "relatives: owner or clinician"
  on public.relatives for select
  using (patient_id = auth.uid() or public.is_clinician_or_admin());
create policy "relatives: owner or clinician write"
  on public.relatives for all
  using (patient_id = auth.uid() or public.is_clinician_or_admin());

create policy "hospital_visits: owner or clinician"
  on public.hospital_visits for select
  using (patient_id = auth.uid() or public.is_clinician_or_admin());
create policy "hospital_visits: owner or clinician write"
  on public.hospital_visits for all
  using (patient_id = auth.uid() or public.is_clinician_or_admin());

-- ---- cases: patient sees their own; assigned doctor/admin manage ----
create policy "cases: patient or assigned doctor or admin read"
  on public.cases for select
  using (
    patient_id = auth.uid()
    or assigned_doctor = auth.uid()
    or public.current_role() = 'admin'
  );
create policy "cases: assigned doctor or admin write"
  on public.cases for all
  using (assigned_doctor = auth.uid() or public.current_role() = 'admin');

-- ---- prescriptions: patient reads own; doctor creates; pharmacist dispenses ----
create policy "prescriptions: patient, doctor, pharmacist, admin read"
  on public.prescriptions for select
  using (
    patient_id = auth.uid()
    or doctor_id = auth.uid()
    or public.current_role() in ('pharmacist', 'admin')
  );
create policy "prescriptions: doctor creates"
  on public.prescriptions for insert
  with check (public.current_role() = 'doctor');
create policy "prescriptions: pharmacist or admin updates"
  on public.prescriptions for update
  using (public.current_role() in ('pharmacist', 'admin'));

-- ---- dispatches: crew + admin/nurse/doctor (receiving hospital) ----
create policy "dispatches: crew or clinician read"
  on public.dispatches for select
  using (ambulance_crew = auth.uid() or public.is_clinician_or_admin());
create policy "dispatches: crew writes own"
  on public.dispatches for all
  using (ambulance_crew = auth.uid() or public.current_role() = 'admin');

-- ---- student encounters: student, supervising doctor, admin ----
create policy "student_encounters: student, supervisor, admin read"
  on public.student_encounters for select
  using (
    student_id = auth.uid()
    or supervising_doctor = auth.uid()
    or public.current_role() = 'admin'
  );
create policy "student_encounters: student writes own draft/submission"
  on public.student_encounters for insert
  with check (student_id = auth.uid());
create policy "student_encounters: student updates own, doctor reviews"
  on public.student_encounters for update
  using (
    student_id = auth.uid()
    or supervising_doctor = auth.uid()
    or public.current_role() = 'admin'
  );

create policy "encounter_questions: via parent encounter"
  on public.encounter_questions for select
  using (
    exists (
      select 1 from public.student_encounters e
      where e.id = encounter_id
        and (e.student_id = auth.uid() or e.supervising_doctor = auth.uid() or public.current_role() = 'admin')
    )
  );
create policy "encounter_questions: student writes on own encounter"
  on public.encounter_questions for insert
  with check (
    exists (select 1 from public.student_encounters e where e.id = encounter_id and e.student_id = auth.uid())
  );

-- ---- AI conversations/messages: strictly owner-only ----
create policy "ai_conversations: owner only"
  on public.ai_conversations for all
  using (user_id = auth.uid());
create policy "ai_messages: via parent conversation, owner only"
  on public.ai_messages for all
  using (
    exists (select 1 from public.ai_conversations c where c.id = conversation_id and c.user_id = auth.uid())
  );
