-- ============================================================
-- Radiology Roles + Report Messaging
-- Extends the existing `cases` table (already shaped like a
-- radiology case: study_type, finding_summary, ai_confidence_pct)
-- rather than building a parallel table. Adds: hospital scoping,
-- a radiographer role on the case, formal versioned reports,
-- clinician-to-clinician case messaging, and file attachments
-- (x-ray images / report files) — all real tables, real RLS.
-- ============================================================

alter table public.cases add column hospital_id uuid references public.hospitals(id);
alter table public.cases add column radiographer_id uuid references public.profiles(id);

create or replace function public.can_access_case(p_case_id uuid)
returns boolean as $$
  select exists (
    select 1 from public.cases c
    where c.id = p_case_id
      and (
        c.patient_id = auth.uid()
        or c.assigned_doctor = auth.uid()
        or c.radiographer_id = auth.uid()
        or (
          public.current_role() in ('radiologist', 'radiographer', 'admin')
          and c.hospital_id = public.my_hospital_id()
        )
      )
  );
$$ language sql stable security definer;

create or replace function public.can_access_case_as_staff(p_case_id uuid)
returns boolean as $$
  select exists (
    select 1 from public.cases c
    where c.id = p_case_id
      and (
        c.assigned_doctor = auth.uid()
        or c.radiographer_id = auth.uid()
        or (
          public.current_role() in ('radiologist', 'radiographer', 'admin')
          and c.hospital_id = public.my_hospital_id()
        )
      )
  );
$$ language sql stable security definer;

create type report_status as enum ('draft', 'final', 'amended');

create table public.case_reports (
  id uuid primary key default uuid_generate_v4(),
  case_id uuid not null references public.cases(id) on delete cascade,
  authored_by uuid not null references public.profiles(id),
  findings text,
  impression text,
  status report_status not null default 'draft',
  created_at timestamptz not null default now(),
  finalized_at timestamptz
);

create table public.case_messages (
  id uuid primary key default uuid_generate_v4(),
  case_id uuid not null references public.cases(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  body text not null,
  attachment_id uuid,
  created_at timestamptz not null default now()
);

create table public.case_attachments (
  id uuid primary key default uuid_generate_v4(),
  case_id uuid not null references public.cases(id) on delete cascade,
  uploaded_by uuid not null references public.profiles(id),
  file_path text not null,
  file_type text,
  label text,
  created_at timestamptz not null default now()
);

alter table public.case_messages
  add constraint case_messages_attachment_fk foreign key (attachment_id) references public.case_attachments(id);

create index idx_case_reports_case on public.case_reports(case_id);
create index idx_case_messages_case on public.case_messages(case_id, created_at);
create index idx_case_attachments_case on public.case_attachments(case_id);

create table public.audit_log (
  id uuid primary key default uuid_generate_v4(),
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  hospital_id uuid references public.hospitals(id),
  metadata jsonb,
  created_at timestamptz not null default now()
);
create index idx_audit_log_hospital on public.audit_log(hospital_id, created_at desc);

alter table public.case_reports enable row level security;
alter table public.case_messages enable row level security;
alter table public.case_attachments enable row level security;
alter table public.audit_log enable row level security;

drop policy "cases: patient or assigned doctor or admin read" on public.cases;
create policy "cases: patient, care team, or same-hospital radiology/admin read"
  on public.cases for select
  using (public.can_access_case(id));

drop policy "cases: assigned doctor or admin write" on public.cases;
create policy "cases: care team or same-hospital radiology/admin write"
  on public.cases for update
  using (public.can_access_case_as_staff(id));
create policy "cases: radiographer or admin creates"
  on public.cases for insert
  with check (
    (public.current_role() in ('radiographer', 'admin') and hospital_id = public.my_hospital_id())
    or radiographer_id = auth.uid()
  );

create policy "case_reports: staff read all, patient reads final only"
  on public.case_reports for select
  using (
    public.can_access_case_as_staff(case_id)
    or (status = 'final' and exists (select 1 from public.cases c where c.id = case_id and c.patient_id = auth.uid()))
  );
create policy "case_reports: radiologist or admin authors"
  on public.case_reports for insert
  with check (
    public.current_role() in ('radiologist', 'admin')
    and exists (select 1 from public.cases c where c.id = case_id and c.hospital_id = public.my_hospital_id())
  );
create policy "case_reports: author or admin updates"
  on public.case_reports for update
  using (authored_by = auth.uid() or public.current_role() = 'admin');

create policy "case_messages: staff on the case read"
  on public.case_messages for select
  using (public.can_access_case_as_staff(case_id));
create policy "case_messages: staff on the case send"
  on public.case_messages for insert
  with check (sender_id = auth.uid() and public.can_access_case_as_staff(case_id));

create policy "case_attachments: anyone who can access the case reads"
  on public.case_attachments for select
  using (public.can_access_case(case_id));
create policy "case_attachments: staff on the case uploads"
  on public.case_attachments for insert
  with check (uploaded_by = auth.uid() and public.can_access_case_as_staff(case_id));

create policy "audit_log: same-hospital admin reads"
  on public.audit_log for select
  using (public.current_role() = 'admin' and hospital_id = public.my_hospital_id());
create policy "audit_log: any authenticated write via security-definer helper only"
  on public.audit_log for insert
  with check (false);

create or replace function public.log_audit(p_action text, p_entity_type text, p_entity_id uuid, p_metadata jsonb default null)
returns void as $$
begin
  insert into public.audit_log (actor_id, action, entity_type, entity_id, hospital_id, metadata)
  values (auth.uid(), p_action, p_entity_type, p_entity_id, public.my_hospital_id(), p_metadata);
end;
$$ language plpgsql security definer;

create or replace function public.finalize_case_report(p_report_id uuid)
returns public.case_reports as $$
declare
  v_report public.case_reports;
begin
  if public.current_role() not in ('radiologist', 'admin') then
    raise exception 'Only a radiologist can finalize a report';
  end if;

  update public.case_reports set status = 'final', finalized_at = now()
    where id = p_report_id and (authored_by = auth.uid() or public.current_role() = 'admin')
    returning * into v_report;

  if not found then
    raise exception 'Report not found or not owned by caller';
  end if;

  update public.cases set status = 'reported', updated_at = now() where id = v_report.case_id;

  perform public.log_audit('finalize_report', 'case_report', p_report_id, jsonb_build_object('case_id', v_report.case_id));

  return v_report;
end;
$$ language plpgsql security definer;

insert into storage.buckets (id, name, public)
values ('case-attachments', 'case-attachments', false)
on conflict (id) do nothing;

create policy "case-attachments: staff on the case upload"
  on storage.objects for insert
  with check (
    bucket_id = 'case-attachments'
    and public.can_access_case_as_staff(((storage.foldername(name))[2])::uuid)
  );
create policy "case-attachments: anyone who can access the case reads"
  on storage.objects for select
  using (
    bucket_id = 'case-attachments'
    and public.can_access_case(((storage.foldername(name))[2])::uuid)
  );
