// Registers a new WebAuthn (Face ID / Touch ID / Windows Hello)
// credential for the CURRENTLY LOGGED IN user. Two-step ceremony:
// action:'options' issues a challenge, action:'verify' checks the
// signed response and stores the public key. Never trusts anything
// from the client except the signed assertion itself.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
} from "https://esm.sh/@simplewebauthn/server@9?target=deno";
import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin, supabaseForRequest, rpIdAndOrigin, base64urlToBuffer, bufferToBase64url } from "../_shared/webauthnEnv.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const userClient = supabaseForRequest(req);
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Not authenticated" }, 401);

    const admin = supabaseAdmin();
    const body = await req.json();
    const { rpID, origin } = rpIdAndOrigin(req);

    if (body.action === "options") {
      const { data: existing } = await admin.from("webauthn_credentials").select("credential_id").eq("user_id", user.id);

      const options = await generateRegistrationOptions({
        rpName: "LiteTreatment",
        rpID,
        userID: new TextEncoder().encode(user.id),
        userName: user.email ?? user.id,
        attestationType: "none",
        excludeCredentials: (existing || []).map((c: any) => ({ id: base64urlToBuffer(c.credential_id), type: "public-key" as const })),
        authenticatorSelection: { residentKey: "preferred", userVerification: "preferred", authenticatorAttachment: "platform" },
      });

      await admin.from("webauthn_challenges").upsert({ user_id: user.id, challenge: options.challenge });
      return json(options);
    }

    if (body.action === "verify") {
      const { data: chal } = await admin.from("webauthn_challenges").select("challenge").eq("user_id", user.id).single();
      if (!chal) return json({ error: "No pending registration challenge" }, 400);

      const verification = await verifyRegistrationResponse({
        response: body.response,
        expectedChallenge: chal.challenge,
        expectedOrigin: origin,
        expectedRPID: rpID,
      });

      if (!verification.verified || !verification.registrationInfo) {
        return json({ error: "Registration could not be verified" }, 400);
      }

      const { credentialID, credentialPublicKey, counter } = verification.registrationInfo;
      await admin.from("webauthn_credentials").insert({
        user_id: user.id,
        credential_id: bufferToBase64url(credentialID),
        public_key: bufferToBase64url(credentialPublicKey),
        counter,
        device_label: body.deviceLabel || null,
      });
      await admin.from("webauthn_challenges").delete().eq("user_id", user.id);

      return json({ verified: true });
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
