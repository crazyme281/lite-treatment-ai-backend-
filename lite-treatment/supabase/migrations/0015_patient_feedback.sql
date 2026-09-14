-- ============================================================
-- Patient Feedback & Rating System
-- ============================================================

create table public.consultations (
  id uuid primary key default uuid_generate_v4(),
  doctor_id uuid not null references public.profiles(id),
  patient_id uuid not null references public.profiles(id),
  hospital_id uuid references public.hospitals(id),
  notes text,
  completed_at timestamptz not null default now()
);

create table public.patient_ratings (
  id uuid primary key default uuid_generate_v4(),
  consultation_id uuid not null unique references public.consultations(id) on delete cascade,
  patient_id uuid not null references public.profiles(id),
  doctor_id uuid not null references public.profiles(id),
  listening_skills int not null check (listening_skills between 1 and 5),
  explanation_clarity int not null check (explanation_clarity between 1 and 5),
  time_spent int not null check (time_spent between 1 and 5),
  comment text,
  sentiment text check (sentiment in ('positive', 'neutral', 'negative')),
  created_at timestamptz not null default now()
);

alter table public.consultations enable row level security;
alter table public.patient_ratings enable row level security;

create policy "consultations: patient, doctor, or admin read"
  on public.consultations for select
  using (patient_id = auth.uid() or doctor_id = auth.uid() or public.current_role() = 'admin');
create policy "consultations: doctor logs their own"
  on public.consultations for insert
  with check (doctor_id = auth.uid() and public.current_role() in ('doctor', 'admin'));

create policy "patient_ratings: patient reads own, doctor reads own, admin reads hospital"
  on public.patient_ratings for select
  using (
    patient_id = auth.uid()
    or doctor_id = auth.uid()
    or (public.current_role() = 'admin' and exists (
      select 1 from public.consultations c where c.id = consultation_id and c.hospital_id = public.my_hospital_id()
    ))
  );
create policy "patient_ratings: patient rates their own completed consultation"
  on public.patient_ratings for insert
  with check (
    patient_id = auth.uid()
    and exists (select 1 from public.consultations c where c.id = consultation_id and c.patient_id = auth.uid())
  );

alter table public.compliance_alerts drop constraint compliance_alerts_type_check;
alter table public.compliance_alerts add constraint compliance_alerts_type_check
  check (type in ('late_shift', 'understaffed', 'negative_feedback'));

create or replace function public.doctor_reputation_summary()
returns table (
  avg_listening numeric, avg_clarity numeric, avg_time_spent numeric, avg_overall numeric,
  rating_count bigint, department_avg_overall numeric
) as $$
  with mine as (
    select r.* from public.patient_ratings r where r.doctor_id = auth.uid()
  ),
  dept as (
    select (r.listening_skills + r.explanation_clarity + r.time_spent) / 3.0 as overall
    from public.patient_ratings r
    join public.profiles p on p.id = r.doctor_id
    where p.hospital_id = public.my_hospital_id() and p.department = (select department from public.profiles where id = auth.uid())
  )
  select
    round(avg(mine.listening_skills), 1), round(avg(mine.explanation_clarity), 1), round(avg(mine.time_spent), 1),
    round(avg((mine.listening_skills + mine.explanation_clarity + mine.time_spent) / 3.0), 1),
    count(mine.id),
    (select round(avg(overall), 1) from dept)
  from mine;
$$ language sql stable security definer;
