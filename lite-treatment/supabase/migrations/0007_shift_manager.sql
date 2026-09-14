-- ============================================================
-- Staff Shift Manager
-- Geo-fenced check-in/out, real Live Duty Board, mandatory
-- handover notes for high-acuity departments, and compliance
-- alerts (late check-in, understaffed department).
-- ============================================================

alter table public.hospitals add column geofence_radius_m int not null default 200;

create type shift_status as enum ('active', 'ended');

-- Optional pre-planned schedule an admin/supervisor can create so
-- lateness has something to be measured against. A shift can also
-- be started with no matching schedule (walk-in / ad-hoc coverage) —
-- it just won't be evaluated for lateness.
create table public.shift_schedules (
  id uuid primary key default uuid_generate_v4(),
  staff_id uuid not null references public.profiles(id),
  hospital_id uuid not null references public.hospitals(id),
  department text not null,
  scheduled_start timestamptz not null,
  scheduled_end timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.shifts (
  id uuid primary key default uuid_generate_v4(),
  staff_id uuid not null references public.profiles(id),
  hospital_id uuid not null references public.hospitals(id),
  department text not null,
  schedule_id uuid references public.shift_schedules(id),
  status shift_status not null default 'active',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  check_in_lat double precision not null,
  check_in_lng double precision not null,
  check_in_distance_m numeric,
  selfie_url text,
  is_late boolean not null default false,
  late_minutes int,
  created_at timestamptz not null default now()
);

create index idx_shifts_active on public.shifts(hospital_id, department) where status = 'active';
create index idx_shifts_staff on public.shifts(staff_id);

-- Mandatory for high-acuity departments before a shift can end.
create table public.shift_handover_notes (
  id uuid primary key default uuid_generate_v4(),
  shift_id uuid not null references public.shifts(id) on delete cascade,
  patient_status text,
  pending_labs text,
  priority_tasks text,
  created_at timestamptz not null default now()
);

-- Minimum on-duty headcount an admin sets per department/hospital —
-- a practical stand-in for a full nurse:patient ratio, since patient
-- census-per-department isn't tracked anywhere in this schema yet.
-- Swap this for a real ratio once bed/census data exists.
create table public.department_staffing_rules (
  id uuid primary key default uuid_generate_v4(),
  hospital_id uuid not null references public.hospitals(id),
  department text not null,
  min_staff_on_duty int not null,
  unique (hospital_id, department)
);

create table public.compliance_alerts (
  id uuid primary key default uuid_generate_v4(),
  type text not null check (type in ('late_shift', 'understaffed')),
  hospital_id uuid not null references public.hospitals(id),
  department text not null,
  staff_id uuid references public.profiles(id),
  message text not null,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---- start_shift: server-side geofence check is the source of truth,
-- never trust a client-computed "I'm inside the perimeter" flag. ----
create or replace function public.start_shift(
  p_hospital_id uuid, p_lat double precision, p_lng double precision,
  p_department text, p_selfie_url text default null
)
returns public.shifts as $$
declare
  v_hospital record;
  v_distance_m numeric;
  v_schedule record;
  v_is_late boolean := false;
  v_late_minutes int := null;
  v_shift public.shifts;
begin
  select * into v_hospital from public.hospitals where id = p_hospital_id;
  if not found then
    raise exception 'Hospital not found';
  end if;

  select st_distance(v_hospital.location, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography)
    into v_distance_m;

  if v_distance_m > v_hospital.geofence_radius_m then
    raise exception 'Outside hospital geofence (%.0f m away, limit is % m)', v_distance_m, v_hospital.geofence_radius_m;
  end if;

  select * into v_schedule from public.shift_schedules
    where staff_id = auth.uid()
      and hospital_id = p_hospital_id
      and department = p_department
      and scheduled_start::date = now()::date
    order by scheduled_start asc
    limit 1;

  if found then
    if now() > v_schedule.scheduled_start + interval '15 minutes' then
      v_is_late := true;
      v_late_minutes := extract(epoch from (now() - v_schedule.scheduled_start)) / 60;
    end if;
  end if;

  insert into public.shifts (staff_id, hospital_id, department, schedule_id, check_in_lat, check_in_lng, check_in_distance_m, selfie_url, is_late, late_minutes)
  values (auth.uid(), p_hospital_id, p_department, v_schedule.id, p_lat, p_lng, v_distance_m, p_selfie_url, v_is_late, v_late_minutes)
  returning * into v_shift;

  if v_is_late then
    insert into public.compliance_alerts (type, hospital_id, department, staff_id, message)
    values ('late_shift', p_hospital_id, p_department, auth.uid(),
      (select full_name from public.profiles where id = auth.uid()) || ' is ' || v_late_minutes || ' min late for ' || p_department);
  end if;

  return v_shift;
end;
$$ language plpgsql security definer;

-- ---- end_shift: handover notes are mandatory for ICU/ER, and a
-- department dropping below its minimum staffing raises an alert. ----
create or replace function public.end_shift(
  p_shift_id uuid, p_patient_status text default null,
  p_pending_labs text default null, p_priority_tasks text default null
)
returns public.shifts as $$
declare
  v_shift public.shifts;
  v_rule public.department_staffing_rules;
  v_remaining int;
begin
  select * into v_shift from public.shifts where id = p_shift_id and staff_id = auth.uid();
  if not found then
    raise exception 'Shift not found or not owned by caller';
  end if;
  if v_shift.status = 'ended' then
    raise exception 'Shift already ended';
  end if;

  if v_shift.department in ('ICU', 'Intensive Care Unit', 'Emergency Room', 'ER') then
    if coalesce(trim(p_patient_status), '') = '' then
      raise exception 'Handover notes (patient status) are mandatory for % before ending shift', v_shift.department;
    end if;
  end if;

  update public.shifts set status = 'ended', ended_at = now() where id = p_shift_id returning * into v_shift;

  if p_patient_status is not null or p_pending_labs is not null or p_priority_tasks is not null then
    insert into public.shift_handover_notes (shift_id, patient_status, pending_labs, priority_tasks)
    values (p_shift_id, p_patient_status, p_pending_labs, p_priority_tasks);
  end if;

  select * into v_rule from public.department_staffing_rules
    where hospital_id = v_shift.hospital_id and department = v_shift.department;

  if found then
    select count(*) into v_remaining from public.shifts
      where hospital_id = v_shift.hospital_id and department = v_shift.department and status = 'active';
    if v_remaining < v_rule.min_staff_on_duty then
      insert into public.compliance_alerts (type, hospital_id, department, message)
      values ('understaffed', v_shift.hospital_id, v_shift.department,
        v_shift.department || ' at ' || v_remaining || '/' || v_rule.min_staff_on_duty || ' minimum on-duty staff');
    end if;
  end if;

  return v_shift;
end;
$$ language plpgsql security definer;

-- ---- Live Duty Board: active shifts joined with staff + role, per hospital ----
create or replace function public.live_duty_board(p_hospital_id uuid)
returns table (
  shift_id uuid, staff_id uuid, full_name text, role user_role, department text,
  started_at timestamptz, is_late boolean
) as $$
  select s.id, s.staff_id, p.full_name, p.role, s.department, s.started_at, s.is_late
  from public.shifts s
  join public.profiles p on p.id = s.staff_id
  where s.hospital_id = p_hospital_id and s.status = 'active'
  order by s.department, s.started_at;
$$ language sql stable;
