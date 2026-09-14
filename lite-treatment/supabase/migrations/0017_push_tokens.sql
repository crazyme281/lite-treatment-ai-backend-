-- ============================================================
-- Push notification device registry. This table + the
-- send-case-alert function are real, functional plumbing — but
-- actually DELIVERING a push (let alone bypassing DND) requires:
--   1. A native Capacitor build (this is a web/PWA build right now;
--      browser tabs cannot receive OS-level push the way a native
--      app can, and DND-bypass is an OS/APNs-critical-alert feature
--      that has no web equivalent at all).
--   2. A real Firebase project (FCM_SERVICE_ACCOUNT_JSON secret) and,
--      for iOS, APNs certificates configured inside that Firebase
--      project. None of that exists yet — it requires accounts and
--      credentials only the project owner can create.
-- Without both, send-case-alert logs what it WOULD have sent and
-- returns a clear "push not configured" result rather than
-- pretending to deliver anything.
-- ============================================================

create table public.device_push_tokens (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id),
  platform text not null check (platform in ('ios', 'android', 'web')),
  token text not null,
  created_at timestamptz not null default now(),
  unique (user_id, token)
);

alter table public.device_push_tokens enable row level security;
create policy "device_push_tokens: owner manages own"
  on public.device_push_tokens for all
  using (user_id = auth.uid());
