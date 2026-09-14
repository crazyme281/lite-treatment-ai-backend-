-- ============================================================
-- Clinical operations: cases, prescriptions, dispatch
-- ============================================================

create type case_priority as enum ('normal', 'high', 'critical');
create type case_status as enum ('pending', 'in_review', 'reported', 'closed');

create table public.cases (
  id uuid primary key default uuid_generate_v4(),
  patient_id uuid not null references public.profiles(id),
  assigned_doctor uuid not null references public.profiles(id),
  study_type text,
  finding_summary text,
  ai_confidence_pct numeric check (ai_confidence_pct between 0 and 100),
  priority case_priority not null default 'normal',
  status case_status not null default 'pending',
  diagnosis_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create type prescription_status as enum ('pending', 'dispensed', 'cancelled');

create table public.prescriptions (
  id uuid primary key default uuid_generate_v4(),
  patient_id uuid not null references public.profiles(id),
  doctor_id uuid not null references public.profiles(id),
  medication_name text not null,
  dosage text,
  frequency text,
  reason text,
  status prescription_status not null default 'pending',
  interaction_warning text,
  dispensed_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create type dispatch_status as enum (
  'dispatched', 'en_route', 'arrived_scene', 'transporting', 'arrived_hospital', 'completed', 'cancelled'
);

create table public.dispatches (
  id uuid primary key default uuid_generate_v4(),
  ambulance_crew uuid not null references public.profiles(id),
  patient_name text,
  emergency_type text not null,
  pickup_address text not null,
  pickup_location geography(Point, 4326),
  receiving_hospital uuid references public.hospitals(id),
  status dispatch_status not null default 'dispatched',
  eta_minutes int,
  heart_rate int,
  blood_pressure text,
  oxygen_saturation int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Nearest-hospital lookup using PostGIS
create or replace function public.nearest_hospitals(lng float, lat float, max_km float default 50, result_limit int default 5)
returns table (
  id uuid, name text, address text, phone text, emergency_24hr boolean, distance_km float
) as $$
  select
    h.id, h.name, h.address, h.phone, h.emergency_24hr,
    round((st_distance(h.location, st_setsrid(st_makepoint(lng, lat), 4326)::geography) / 1000)::numeric, 1) as distance_km
  from public.hospitals h
  where st_dwithin(h.location, st_setsrid(st_makepoint(lng, lat), 4326)::geography, max_km * 1000)
  order by h.location <-> st_setsrid(st_makepoint(lng, lat), 4326)::geography
  limit result_limit;
$$ language sql stable;
