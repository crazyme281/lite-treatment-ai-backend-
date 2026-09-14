-- ============================================================
-- Fix (selfie audit): the shift-check-in selfie is stored as a
-- STORAGE PATH now (not a 30-day signed URL that would silently
-- expire and become unretrievable for later audit). Signed URLs
-- are generated on demand when an admin views the audit log.
-- Storage RLS is rewritten to be hospital-scoped via the path
-- structure: <hospital_id>/<staff_id>/<file>.jpg
-- ============================================================

drop policy if exists "shift-selfies: owner uploads to own folder" on storage.objects;
drop policy if exists "shift-selfies: owner or clinician/admin reads" on storage.objects;

create policy "shift-selfies: staff uploads under their own hospital+id"
  on storage.objects for insert
  with check (
    bucket_id = 'shift-selfies'
    and (storage.foldername(name))[1] = public.my_hospital_id()::text
    and (storage.foldername(name))[2] = auth.uid()::text
  );

create policy "shift-selfies: owner or same-hospital admin reads"
  on storage.objects for select
  using (
    bucket_id = 'shift-selfies'
    and (
      (storage.foldername(name))[2] = auth.uid()::text
      or (public.current_role() = 'admin' and (storage.foldername(name))[1] = public.my_hospital_id()::text)
    )
  );

-- Admin-only audit view: staff name, department, check-in details,
-- and the raw selfie path (not a URL) — the caller signs it on demand.
create or replace function public.shift_audit_log(p_limit int default 50)
returns table (
  shift_id uuid, staff_id uuid, full_name text, department text,
  started_at timestamptz, ended_at timestamptz, status shift_status,
  check_in_distance_m numeric, is_late boolean, late_minutes int, selfie_path text
) as $$
  select s.id, s.staff_id, p.full_name, s.department, s.started_at, s.ended_at, s.status,
         s.check_in_distance_m, s.is_late, s.late_minutes, s.selfie_url
  from public.shifts s
  join public.profiles p on p.id = s.staff_id
  where s.hospital_id = public.my_hospital_id() and public.current_role() = 'admin'
  order by s.started_at desc
  limit p_limit;
$$ language sql stable security definer;

comment on column public.shifts.selfie_url is
  'Storage PATH in the shift-selfies bucket (hospital_id/staff_id/file.jpg), not a public URL. '
  'This is a timestamped photo captured for later human audit review only — no automated facial '
  'recognition / identity matching runs against it. Wiring that up would mean adding a face-match '
  'provider (e.g. AWS Rekognition CompareFaces against an HR reference photo) and is not implemented.';
