// The login-time half of WebAuthn: no Supabase session exists yet
// when this runs, so verify_jwt is off for this function and it
// looks the user up by email instead. On successful assertion
// verification, mints a real Supabase session via a magic-link
// token exchange (Supabase's supported server-side "sign in as this
// user" mechanism) rather than issuing anything home-grown.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "https://esm.sh/@simplewebauthn/server@9?target=deno";
import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin, rpIdAndOrigin, base64urlToBuffer, bufferToBase64url } from "../_shared/webauthnEnv.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const admin = supabaseAdmin();
    const body = await req.json();
    const { rpID, origin } = rpIdAndOrigin(req);

    if (body.action === "options") {
      const { data: profile } = await admin.from("profiles").select("id").eq("email", body.email).maybeSingle();
      if (!profile) return json({ error: "No account with biometric sign-in set up for that email" }, 404);

      const { data: creds } = await admin.from("webauthn_credentials").select("credential_id").eq("user_id", profile.id);
      if (!creds || creds.length === 0) return json({ error: "No biometric credential registered for this account" }, 404);

      const options = await generateAuthenticationOptions({
        rpID,
        allowCredentials: creds.map((c) => ({ id: base64urlToBuffer(c.credential_id), type: "public-key" as const })),
        userVerification: "preferred",
      });

      await admin.from("webauthn_challenges").upsert({ user_id: profile.id, challenge: options.challenge });
      return json(options);
    }

    if (body.action === "verify") {
      const { data: profile } = await admin.from("profiles").select("id, email").eq("email", body.email).maybeSingle();
      if (!profile) return json({ error: "Account not found" }, 404);

      const { data: chal } = await admin.from("webauthn_challenges").select("challenge").eq("user_id", profile.id).single();
      if (!chal) return json({ error: "No pending authentication challenge" }, 400);

      const credentialId = body.response.id;
      const { data: cred } = await admin.from("webauthn_credentials").select("*").eq("user_id", profile.id).eq("credential_id", credentialId).maybeSingle();
      if (!cred) return json({ error: "Unrecognized credential" }, 400);

      const verification = await verifyAuthenticationResponse({
        response: body.response,
        expectedChallenge: chal.challenge,
        expectedOrigin: origin,
        expectedRPID: rpID,
        authenticator: {
          credentialID: base64urlToBuffer(cred.credential_id),
          credentialPublicKey: base64urlToBuffer(cred.public_key),
          counter: cred.counter,
        },
      });

      if (!verification.verified) return json({ error: "Biometric verification failed" }, 400);

      await admin.from("webauthn_credentials").update({ counter: verification.authenticationInfo.newCounter }).eq("id", cred.id);
      await admin.from("webauthn_challenges").delete().eq("user_id", profile.id);

      const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: "magiclink", email: profile.email });
      if (linkErr || !link) return json({ error: "Verified, but couldn't establish a session: " + (linkErr?.message ?? "unknown") }, 500);

      return json({ verified: true, email: profile.email, tokenHash: link.properties.hashed_token });
    }

    return json({ error: "Unknown action" }, 400);
  } catch (err) {
    console.error(err);
    return json({ error: err.message || "Internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
