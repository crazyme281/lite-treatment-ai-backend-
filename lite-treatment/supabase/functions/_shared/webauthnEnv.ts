import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export function supabaseAdmin() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
}

export function supabaseForRequest(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );
}

// rpID/origin: prefer explicit env vars (set these once you know your
// production domain); fall back to deriving from the request's Origin
// header, which works fine for local/dev testing but should be pinned
// via env vars for production.
export function rpIdAndOrigin(req: Request): { rpID: string; origin: string } {
  const envRpId = Deno.env.get("WEBAUTHN_RP_ID");
  const envOrigin = Deno.env.get("WEBAUTHN_ORIGIN");
  if (envRpId && envOrigin) return { rpID: envRpId, origin: envOrigin };

  const originHeader = req.headers.get("origin") || envOrigin || "http://localhost";
  const rpID = envRpId || new URL(originHeader).hostname;
  return { rpID, origin: originHeader };
}

export function base64urlToBuffer(b64url: string): Uint8Array {
  const pad = (4 - (b64url.length % 4)) % 4;
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat(pad);
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export function bufferToBase64url(buf: Uint8Array): string {
  let bin = "";
  buf.forEach((b) => { bin += String.fromCharCode(b); });
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
