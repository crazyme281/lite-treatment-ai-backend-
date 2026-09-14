-- ============================================================
-- Biometric login via WebAuthn (Face ID / Touch ID / Windows Hello
-- through the browser's platform authenticator — this is the real
-- standard, not a fake "biometric" toggle). Registration/assertion
-- verification happens server-side in edge functions using
-- @simplewebauthn/server. Note: this could not be exercised against
-- real hardware in this environment (no browser+authenticator
-- available here) — the implementation follows the library's
-- documented flow correctly, but test it on an actual device.
-- ============================================================

create table public.webauthn_credentials (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  credential_id text not null unique,
  public_key text not null,
  counter bigint not null default 0,
  device_label text,
  created_at timestamptz not null default now()
);

create table public.webauthn_challenges (
  user_id uuid primary key,
  challenge text not null,
  created_at timestamptz not null default now()
);

alter table public.webauthn_credentials enable row level security;
alter table public.webauthn_challenges enable row level security;

create policy "webauthn_credentials: owner manages own"
  on public.webauthn_credentials for select
  using (user_id = auth.uid());
create policy "webauthn_credentials: owner deletes own"
  on public.webauthn_credentials for delete
  using (user_id = auth.uid());

create policy "webauthn_challenges: no direct client access"
  on public.webauthn_challenges for all
  using (false);
