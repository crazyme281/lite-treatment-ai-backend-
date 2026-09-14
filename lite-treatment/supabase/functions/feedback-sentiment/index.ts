// Called by the client right after a rating is inserted. Classifies
// the free-text comment's sentiment and, if negative, raises a
// compliance_alerts row (type='negative_feedback') so it reaches
// hospital management — not the doctor being rated, and not the
// general clinician list. Falls back to a keyword heuristic when no
// AI provider key is configured, same honesty pattern as cds-assist.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin, supabaseForRequest } from "../_shared/supabaseAdmin.ts";

const NEGATIVE_WORDS = ["rude", "dismissive", "waited", "wait", "ignored", "terrible", "awful", "unprofessional", "never again", "worst", "disrespect", "careless", "mistake", "neglect"];
const POSITIVE_WORDS = ["great", "excellent", "kind", "caring", "thorough", "attentive", "thank", "amazing", "wonderful", "helpful", "patient", "clear"];

function keywordSentiment(text: string): "positive" | "neutral" | "negative" {
  const t = text.toLowerCase();
  const neg = NEGATIVE_WORDS.filter((w) => t.includes(w)).length;
  const pos = POSITIVE_WORDS.filter((w) => t.includes(w)).length;
  if (neg > pos) return "negative";
  if (pos > neg) return "positive";
  return "neutral";
}

async function aiSentiment(text: string): Promise<"positive" | "neutral" | "negative" | null> {
  const apiKey = Deno.env.get("AI_API_KEY");
  if (!apiKey) return null;
  const apiUrl = Deno.env.get("AI_API_URL") ?? "https://api.openai.com/v1/chat/completions";
  const model = Deno.env.get("AI_MODEL") ?? "gpt-4o-mini";
  try {
    const res = await fetch(apiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: "Classify patient feedback sentiment. Reply with exactly one word: positive, neutral, or negative." },
          { role: "user", content: text },
        ],
        temperature: 0,
      }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const word = (data.choices?.[0]?.message?.content || "").trim().toLowerCase();
    if (word.includes("negative")) return "negative";
    if (word.includes("positive")) return "positive";
    if (word.includes("neutral")) return "neutral";
    return null;
  } catch {
    return null;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { ratingId } = await req.json();

    const userClient = supabaseForRequest(req);
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Not authenticated" }, 401);

    const admin = supabaseAdmin();
    const { data: rating } = await admin.from("patient_ratings").select("id, comment, doctor_id, patient_id").eq("id", ratingId).single();
    if (!rating) return json({ error: "Rating not found" }, 404);
    if (rating.patient_id !== user.id) return json({ error: "Not your rating" }, 403);

    const text = rating.comment || "";
    let sentiment: "positive" | "neutral" | "negative" = "neutral";
    if (text.trim()) {
      sentiment = (await aiSentiment(text)) ?? keywordSentiment(text);
    }

    await admin.from("patient_ratings").update({ sentiment }).eq("id", ratingId);

    if (sentiment === "negative") {
      const { data: doctor } = await admin.from("profiles").select("full_name, hospital_id, department").eq("id", rating.doctor_id).single();
      if (doctor?.hospital_id) {
        await admin.from("compliance_alerts").insert({
          type: "negative_feedback",
          hospital_id: doctor.hospital_id,
          department: doctor.department || "Unknown",
          staff_id: rating.doctor_id,
          message: `Negative patient feedback flagged for Dr. ${doctor.full_name}`,
        });
      }
    }

    return json({ sentiment });
  } catch (err) {
    console.error(err);
    return json({ error: err.message || "Internal error" }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
