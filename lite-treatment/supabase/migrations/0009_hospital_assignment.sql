-- ============================================================
-- Fix 1: proper hospital assignment (replaces open self-service
-- "pick any hospital" dropdown with an admin-issued join code,
-- plus a direct admin-assignment path).
-- Fix 2 (terminology): no schema change needed — the staffing
-- table was already named/labelled as a minimum-headcount rule,
-- not a ratio. See department_staffing_rules comment below.
-- Fix 3 (RLS gap): shift-manager tables were readable by ANY
-- clinician/admin regardless of hospital — this closes that.
-- ============================================================

create or replace function public.my_hospital_id()
returns uuid as $$
  select hospital_id from public.profiles where id = auth.uid();
$$ language sql stable security definer;

-- Join codes live in their own table (not a column on hospitals)
-- so the public "hospitals are publicly readable" policy never
-- exposes them — only an admin scoped to that hospital can read
-- their own code, via RLS below.
create table public.hospital_join_codes (
  hospital_id uuid primary key references public.hospitals(id),
  code text not null unique,
  created_at timestamptz not null default now()
);

alter table public.hospital_join_codes enable row level security;

create policy "hospital_join_codes: admin of that hospital only"
  on public.hospital_join_codes for select
  using (public.current_role() = 'admin' and hospital_id = public.my_hospital_id());

-- Seed a code for every existing hospital.
insert into public.hospital_join_codes (hospital_id, code)
select id, upper(substr(md5(random()::text || id::text), 1, 6)) from public.hospitals
on conflict (hospital_id) do nothing;

-- ---- Staff-facing: join with a code an admin gave them ----
create or replace function public.join_hospital_with_code(p_code text, p_department text default null)
returns public.hospitals as $$
declare
  v_hospital_id uuid;
  v_hospital public.hospitals;
begin
  select hospital_id into v_hospital_id from public.hospital_join_codes where code = upper(p_code);
  if not found then
    raise exception 'Invalid staff code';
  end if;

  update public.profiles set hospital_id = v_hospital_id, department = coalesce(p_department, department)
    where id = auth.uid();

  select * into v_hospital from public.hospitals where id = v_hospital_id;
  return v_hospital;
end;
$$ language plpgsql security definer;

-- ---- Admin bootstrap: a first admin with no hospital yet can
-- claim one directly (trusted role, no code needed — mirrors how
-- the very first admin account for a hospital gets set up) ----
create or replace function public.admin_claim_hospital(p_hospital_id uuid)
returns public.hospitals as $$
declare
  v_hospital public.hospitals;
begin
  if public.current_role() != 'admin' then
    raise exception 'Only admins can claim a hospital';
  end if;
  if public.my_hospital_id() is not null then
    raise exception 'You are already assigned to a hospital';
  end if;

  update public.profiles set hospital_id = p_hospital_id where id = auth.uid();
  select * into v_hospital from public.hospitals where id = p_hospital_id;
  return v_hospital;
end;
$$ language plpgsql security definer;

-- ---- Admin-organization path: assign any unassigned staff
-- directly, instead of relying on the staff member entering a code ----
create or replace function public.admin_assign_staff(p_staff_id uuid, p_department text default null)
returns public.profiles as $$
declare
  v_profile public.profiles;
begin
  if public.current_role() != 'admin' then
    raise exception 'Only admins can assign staff';
  end if;

  update public.profiles
    set hospital_id = public.my_hospital_id(), department = coalesce(p_department, department)
    where id = p_staff_id
    returning * into v_profile;

  return v_profile;
end;
$$ language plpgsql security definer;

-- ---- Admin: fetch (or lazily create) their own hospital's code ----
create or replace function public.get_my_hospital_join_code()
returns text as $$
declare
  v_hospital_id uuid := public.my_hospital_id();
  v_code text;
begin
  if public.current_role() != 'admin' or v_hospital_id is null then
    raise exception 'Only an admin assigned to a hospital can view its staff code';
  end if;

  select code into v_code from public.hospital_join_codes where hospital_id = v_hospital_id;
  if not found then
    v_code := upper(substr(md5(random()::text || v_hospital_id::text), 1, 6));
    insert into public.hospital_join_codes (hospital_id, code) values (v_hospital_id, v_code);
  end if;
  return v_code;
end;
$$ language plpgsql security definer;

-- ---- Close the cross-hospital visibility gap on shift-manager
-- tables: replace blanket "any clinician/admin" with hospital-scoped ----
drop policy "shifts: owner or staff read" on public.shifts;
create policy "shifts: owner or same-hospital staff read"
  on public.shifts for select
  using (
    staff_id = auth.uid()
    or (public.is_clinician_or_admin() and hospital_id = public.my_hospital_id())
    or (public.current_role() = 'ambulance' and hospital_id = public.my_hospital_id())
  );

drop policy "shift_schedules: owner or admin read" on public.shift_schedules;
create policy "shift_schedules: owner or same-hospital admin read"
  on public.shift_schedules for select
  using (staff_id = auth.uid() or (public.current_role() = 'admin' and hospital_id = public.my_hospital_id()));
drop policy "shift_schedules: admin writes" on public.shift_schedules;
create policy "shift_schedules: same-hospital admin writes"
  on public.shift_schedules for all
  using (public.current_role() = 'admin' and hospital_id = public.my_hospital_id());

drop policy "department_staffing_rules: readable by staff" on public.department_staffing_rules;
create policy "department_staffing_rules: same-hospital staff read"
  on public.department_staffing_rules for select
  using (
    (public.is_clinician_or_admin() or public.current_role() in ('ambulance', 'pharmacist'))
    and hospital_id = public.my_hospital_id()
  );
drop policy "department_staffing_rules: admin writes" on public.department_staffing_rules;
create policy "department_staffing_rules: same-hospital admin writes"
  on public.department_staffing_rules for all
  using (public.current_role() = 'admin' and hospital_id = public.my_hospital_id());

drop policy "compliance_alerts: admin only" on public.compliance_alerts;
create policy "compliance_alerts: same-hospital admin only"
  on public.compliance_alerts for all
  using (public.current_role() = 'admin' and hospital_id = public.my_hospital_id());

comment on table public.department_staffing_rules is
  'A configurable MINIMUM ON-DUTY HEADCOUNT per department — not a true nurse:patient ratio. '
  'A real ratio needs per-department patient census / bed-assignment data, which this schema '
  'does not yet track. Add a `beds` or `department_census` table (current occupied beds per '
  'department) and compare shifts-with-role=nurse count against that, instead of this static '
  'minimum, once census data exists.';
