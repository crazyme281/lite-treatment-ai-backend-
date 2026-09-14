// Patient-facing health information assistant.
// General education only: explains terms, helps prepare questions for a
// visit, general wellness info. NEVER diagnoses, prescribes, or interprets
// the patient's own results as a verdict — always directs them back to
// their care team for anything specific to their situation.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { supabaseForRequest, supabaseAdmin } from "../_shared/supabaseAdmin.ts";

const SYSTEM_PROMPT = `You are a friendly health-information assistant inside a hospital's patient app.
Your role is educational only. You must:
- Never diagnose a condition or tell the patient what they have.
- Never recommend a specific medication, dosage, or treatment.
- Explain medical terms, general health concepts, and what to expect from procedures in plain language.
- Help the patient prepare questions to bring to their doctor.
- For anything symptom-specific, urgent, or personal to their case, tell them to contact their nearest hospital or their doctor — and if it sounds urgent, say so plainly and suggest emergency care.
- Keep answers short and easy to read on a phone.`;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { conversationId, message } = await req.json();

    const userClient = supabaseForRequest(req);
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Not authenticated" }, 401);

    const admin = supabaseAdmin();

    let convoId = conversationId;
    if (!convoId) {
      const { data: convo, error } = await admin
        .from("ai_conversations")
        .insert({ user_id: user.id, assistant_type: "patient", title: message.slice(0, 60) })
        .select().single();
      if (error) throw error;
      convoId = convo.id;
    }

    await admin.from("ai_messages").insert({ conversation_id: convoId, role: "user", content: message });

    const aiResponse = await callAiProvider(SYSTEM_PROMPT, message);

    await admin.from("ai_messages").insert({ conversation_id: convoId, role: "assistant", content: aiResponse });

    return json({ conversationId: convoId, reply: aiResponse });
  } catch (err) {
    console.error(err);
    return json({ error: err.message || "Internal error" }, 500);
  }
});

async function callAiProvider(system: string, userMessage: string): Promise<string> {
  const apiUrl = Deno.env.get("AI_API_URL") ?? "https://api.openai.com/v1/chat/completions";
  const apiKey = Deno.env.get("AI_API_KEY");
  const model = Deno.env.get("AI_MODEL") ?? "gpt-4o-mini";

  if (!apiKey) {
    return "AI provider not configured (AI_API_KEY missing). This is a placeholder response — set AI_API_KEY in your Supabase project's function secrets to enable live answers.";
  }

  const res = await fetch(apiUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: system },
        { role: "user", content: userMessage },
      ],
      temperature: 0.4,
    }),
  });

  if (!res.ok) throw new Error(`AI provider error: ${res.status}`);
  const data = await res.json();
  return data.choices?.[0]?.message?.content ?? "No response generated.";
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
