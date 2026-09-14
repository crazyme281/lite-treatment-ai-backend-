alter table public.shift_schedules enable row level security;
alter table public.shifts enable row level security;
alter table public.shift_handover_notes enable row level security;
alter table public.department_staffing_rules enable row level security;
alter table public.compliance_alerts enable row level security;

create policy "shift_schedules: owner or admin read"
  on public.shift_schedules for select
  using (staff_id = auth.uid() or public.current_role() = 'admin');
create policy "shift_schedules: admin writes"
  on public.shift_schedules for all
  using (public.current_role() = 'admin');

create policy "shifts: owner or staff read"
  on public.shifts for select
  using (staff_id = auth.uid() or public.is_clinician_or_admin() or public.current_role() = 'ambulance');
create policy "shifts: owner inserts own"
  on public.shifts for insert
  with check (staff_id = auth.uid());
create policy "shifts: owner updates own"
  on public.shifts for update
  using (staff_id = auth.uid());

create policy "shift_handover_notes: via parent shift"
  on public.shift_handover_notes for select
  using (
    exists (
      select 1 from public.shifts s
      where s.id = shift_id and (s.staff_id = auth.uid() or public.is_clinician_or_admin())
    )
  );
create policy "shift_handover_notes: owner inserts via parent shift"
  on public.shift_handover_notes for insert
  with check (
    exists (select 1 from public.shifts s where s.id = shift_id and s.staff_id = auth.uid())
  );

create policy "department_staffing_rules: readable by staff"
  on public.department_staffing_rules for select
  using (public.is_clinician_or_admin() or public.current_role() in ('ambulance', 'pharmacist'));
create policy "department_staffing_rules: admin writes"
  on public.department_staffing_rules for all
  using (public.current_role() = 'admin');

create policy "compliance_alerts: admin only"
  on public.compliance_alerts for all
  using (public.current_role() = 'admin');

-- Storage bucket for check-in selfies — private, not publicly listable.
insert into storage.buckets (id, name, public)
values ('shift-selfies', 'shift-selfies', false)
on conflict (id) do nothing;

create policy "shift-selfies: owner uploads to own folder"
  on storage.objects for insert
  with check (bucket_id = 'shift-selfies' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "shift-selfies: owner or clinician/admin reads"
  on storage.objects for select
  using (
    bucket_id = 'shift-selfies'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.is_clinician_or_admin())
  );
