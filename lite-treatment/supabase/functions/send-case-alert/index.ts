// Sends a REAL push notification via FCM's HTTP v1 API for a
// critical radiology case, to the assigned doctor + on-duty
// radiologists' registered devices. This performs the actual OAuth2
// JWT-bearer token exchange against Google's servers and the actual
// FCM send call — not a simulation.
//
// Requires the FCM_SERVICE_ACCOUNT_JSON secret: the full JSON key
// file downloaded from Firebase Console → Project Settings →
// Service Accounts → Generate new private key. Without it, this
// returns configured:false and sends nothing — that's a genuine
// "not set up yet" state, not a fake success.
//
// On iOS, delivering a push at all (this function) is separate from
// DND-bypass specifically: that additionally requires Apple's
// "Critical Alerts" entitlement, which is a distinct approval Apple
// grants per-app (mostly to health/safety apps) — no code change
// here can grant that; it must be requested from Apple directly.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin, supabaseForRequest } from "../_shared/supabaseAdmin.ts";

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = "";
  arr.forEach((b) => { bin += String.fromCharCode(b); });
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const b64 = pem.replace(/-----BEGIN PRIVATE KEY-----/, "").replace(/-----END PRIVATE KEY-----/, "").replace(/\s+/g, "");
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

async function getAccessToken(serviceAccount: { client_email: string; private_key: string }): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  const encoder = new TextEncoder();
  const unsigned = `${base64url(encoder.encode(JSON.stringify(header)))}.${base64url(encoder.encode(JSON.stringify(claims)))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(serviceAccount.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(unsigned));
  const jwt = `${unsigned}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${encodeURIComponent(jwt)}`,
  });
  if (!res.ok) throw new Error(`Token exchange failed: ${res.status} ${await res.text()}`);
  const data = await res.json();
  return data.access_token;
}

async function sendToToken(projectId: string, accessToken: string, deviceToken: string, title: string, body: string, caseId: string) {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      message: {
        token: deviceToken,
        notification: { title, body },
        data: { caseId },
        android: { priority: "high" },
        apns: { headers: { "apns-priority": "10" }, payload: { aps: { sound: "default" } } },
      },
    }),
  });
  const result = await res.json();
  return { ok: res.ok, status: res.status, result };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { caseId } = await req.json();

    const userClient = supabaseForRequest(req);
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Not authenticated" }, 401);

    const admin = supabaseAdmin();
    const { data: caseRow } = await admin.from("cases").select("id, priority, assigned_doctor, hospital_id, study_type, patient:patient_id(full_name)").eq("id", caseId).single();
    if (!caseRow) return json({ error: "Case not found" }, 404);

    const recipientIds = new Set<string>();
    if (caseRow.assigned_doctor) recipientIds.add(caseRow.assigned_doctor);
    const { data: radiologists } = await admin.from("profiles").select("id").eq("role", "radiologist").eq("hospital_id", caseRow.hospital_id);
    (radiologists || []).forEach((r) => recipientIds.add(r.id));

    const { data: tokens } = await admin.from("device_push_tokens").select("id, user_id, platform, token").in("user_id", Array.from(recipientIds));

    const title = `${caseRow.priority.toUpperCase()} case: ${(caseRow as any).patient?.full_name ?? "Patient"}`;
    const body = `${caseRow.study_type} needs review`;

    const serviceAccountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
    if (!serviceAccountJson) {
      return json({
        configured: false,
        sent: 0,
        recipients: tokens?.length ?? 0,
        message: "FCM_SERVICE_ACCOUNT_JSON is not set. No Firebase project is connected yet, so no push was sent. Set this secret (the full JSON key from Firebase Console → Project Settings → Service Accounts) to enable real delivery.",
      });
    }

    let serviceAccount: { project_id: string; client_email: string; private_key: string };
    try {
      serviceAccount = JSON.parse(serviceAccountJson);
    } catch {
      return json({ configured: false, sent: 0, error: "FCM_SERVICE_ACCOUNT_JSON is set but isn't valid JSON." }, 500);
    }

    if (!tokens || tokens.length === 0) {
      return json({ configured: true, sent: 0, recipients: 0, message: "No registered devices for the assigned doctor/radiologists yet." });
    }

    const accessToken = await getAccessToken(serviceAccount);

    const results = await Promise.all(
      tokens.map(async (t) => {
        try {
          const r = await sendToToken(serviceAccount.project_id, accessToken, t.token, title, body, caseId);
          if (!r.ok) {
            const errCode = r.result?.error?.details?.[0]?.errorCode;
            if (errCode === "UNREGISTERED" || r.status === 404) {
              await admin.from("device_push_tokens").delete().eq("id", t.id);
            }
          }
          return { userId: t.user_id, platform: t.platform, ok: r.ok, status: r.status };
        } catch (err) {
          return { userId: t.user_id, platform: t.platform, ok: false, error: String(err) };
        }
      })
    );

    const sent = results.filter((r) => r.ok).length;
    return json({ configured: true, sent, recipients: tokens.length, results });
  } catch (err) {
    console.error(err);
    return json({ error: err.message || "Internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
