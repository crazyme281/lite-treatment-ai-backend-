-- ============================================================
-- LiteTreatment — Core schema
-- Roles, profiles, hospitals, and the full patient onboarding
-- data model (mirrors the original 8-step registration flow).
-- ============================================================

create extension if not exists "uuid-ossp";
create extension if not exists postgis;

create type user_role as enum (
  'patient', 'doctor', 'nurse', 'pharmacist', 'ambulance', 'admin', 'student_doctor'
);

-- One row per auth.users entry — created by a trigger on signup.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  role user_role not null default 'patient',
  hospital_id uuid,
  department text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.hospitals (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  address text not null,
  phone text,
  emergency_24hr boolean not null default false,
  location geography(Point, 4326) not null,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add constraint profiles_hospital_fk foreign key (hospital_id) references public.hospitals(id);

-- ---- Step 1: Personal info + onboarding progress ----
create table public.patient_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  date_of_birth date,
  gender text check (gender in ('Male', 'Female', 'Other')),
  address text,
  profile_photo_url text,
  nearest_hospital_id uuid references public.hospitals(id),
  onboarding_step int not null default 0,
  onboarding_complete boolean not null default false,
  updated_at timestamptz not null default now()
);

-- ---- Step 2: Medical history ----
create table public.medical_history (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  blood_group text,
  genotype text,
  disability_or_special_needs text,
  family_medical_history text,
  additional_notes text,
  updated_at timestamptz not null default now()
);

-- Repeatable entry categories (allergies, medications, conditions, surgeries,
-- hospitalizations, major illnesses) as one polymorphic table, category-tagged.
create type medical_entry_category as enum (
  'allergy', 'medication', 'condition', 'surgery', 'hospitalization', 'major_illness'
);

create table public.medical_entries (
  id uuid primary key default uuid_generate_v4(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  category medical_entry_category not null,
  name text not null,
  detail text, -- dosage/frequency/reason, or free-text note
  created_at timestamptz not null default now()
);

-- ---- Step 3: Emergency contact ----
create table public.emergency_contacts (
  patient_id uuid primary key references public.profiles(id) on delete cascade,
  full_name text not null,
  phone text not null,
  relationship text not null,
  email text,
  address text
);

-- ---- Step 4: Family & relatives ----
create table public.relatives (
  id uuid primary key default uuid_generate_v4(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  full_name text not null,
  relationship text not null,
  phone text,
  email text,
  address text,
  medical_relevance text,
  created_at timestamptz not null default now()
);

-- ---- Step 5: Previous hospitals & visits ----
create table public.hospital_visits (
  id uuid primary key default uuid_generate_v4(),
  patient_id uuid not null references public.profiles(id) on delete cascade,
  hospital_name text not null,
  location text,
  visit_date text, -- free text to allow approximate dates ("June 2026")
  reason text,
  treatment_received text,
  doctor_name text,
  diagnosis text,
  notes text,
  created_at timestamptz not null default now()
);

-- Auto-create a profile row whenever a new Supabase Auth user signs up.
-- Role and full_name are passed in via signUp() options.data.
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name, email, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', 'Unnamed User'),
    new.email,
    new.raw_user_meta_data->>'phone',
    coalesce((new.raw_user_meta_data->>'role')::user_role, 'patient')
  );

  if coalesce((new.raw_user_meta_data->>'role')::user_role, 'patient') = 'patient' then
    insert into public.patient_profiles (user_id) values (new.id);
  end if;

  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
