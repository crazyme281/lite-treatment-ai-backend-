// Clinical Decision Support assistant — for doctors and student doctors.
// Strictly non-diagnostic: surfaces differential considerations, relevant
// protocols, and interaction context from the patient's own record. It
// never states a diagnosis and always defers final judgement to the
// treating physician. Every exchange is logged to ai_conversations/ai_messages.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { supabaseForRequest, supabaseAdmin } from "../_shared/supabaseAdmin.ts";

const SYSTEM_PROMPT = `You are a Clinical Decision Support (CDS) assistant embedded in a hospital
platform. Your role is strictly advisory and NON-DIAGNOSTIC.

Rules you must always follow:
- Never state a definitive diagnosis. Use language like "consider", "differential includes", "may warrant investigation of".
- Ground suggestions in the patient context provided (allergies, current medications, history) when given.
- When relevant, name standard clinical protocols or guidelines by name rather than inventing specifics.
- Flag drug interactions or allergy conflicts clearly if the context shows a risk.
- Always close with a short reminder that final diagnostic and treatment authority rests with the treating physician.
- If asked to diagnose outright, decline and redirect to differential considerations instead.
- Be concise — this is read by a clinician during a live case, not a textbook chapter.`;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { conversationId, message, caseId, patientId } = await req.json();

    const userClient = supabaseForRequest(req);
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Not authenticated" }, 401);

    const { data: profile } = await userClient
      .from("profiles").select("role").eq("id", user.id).single();
    if (!profile || !["doctor", "student_doctor", "admin"].includes(profile.role)) {
      return json({ error: "CDS assistant is only available to clinicians" }, 403);
    }

    const admin = supabaseAdmin();

    // Build lightweight patient context if a patientId was provided.
    let contextBlock = "";
    if (patientId) {
      const [{ data: history }, { data: entries }] = await Promise.all([
        admin.from("medical_history").select("blood_group, genotype").eq("user_id", patientId).maybeSingle(),
        admin.from("medical_entries").select("category, name, detail").eq("patient_id", patientId),
      ]);
      const allergies = (entries || []).filter((e) => e.category === "allergy").map((e) => e.name);
      const medications = (entries || []).filter((e) => e.category === "medication").map((e) => e.name);
      contextBlock = `\n\nPatient context:\n- Blood group: ${history?.blood_group ?? "unknown"}\n- Genotype: ${history?.genotype ?? "unknown"}\n- Known allergies: ${allergies.join(", ") || "none recorded"}\n- Current medications: ${medications.join(", ") || "none recorded"}`;
    }

    // Get or create the conversation
    let convoId = conversationId;
    if (!convoId) {
      const { data: convo, error } = await admin
        .from("ai_conversations")
        .insert({ user_id: user.id, assistant_type: "cds", related_case_id: caseId ?? null, related_patient_id: patientId ?? null, title: message.slice(0, 60) })
        .select().single();
      if (error) throw error;
      convoId = convo.id;
    }

    await admin.from("ai_messages").insert({ conversation_id: convoId, role: "user", content: message });

    const aiResponse = await callAiProvider(SYSTEM_PROMPT, message + contextBlock);

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
    return "AI provider not configured (AI_API_KEY missing). This is a placeholder response — set AI_API_KEY in your Supabase project's function secrets to enable live CDS suggestions.";
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
      temperature: 0.3,
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
