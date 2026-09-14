import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Service-role client for Edge Functions — bypasses RLS deliberately,
// so every function using this MUST do its own authorization check
// (verify the caller's JWT + role) before touching data on their behalf.
export function supabaseAdmin() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
}

// Client scoped to the calling user's JWT — respects RLS as normal.
export function supabaseForRequest(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );
}
