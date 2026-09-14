"""
LiteTreatment AI backend v3.

Pipeline for /cds-assist (per the audit's priority order):
  auth -> safety gate -> patient/protocol retrieval -> model routing
  -> structured draft -> deterministic citation validation -> critic
  pass -> (regenerate once if critic flags a real problem) -> save.

/patient-assist keeps the safety gate and protocol grounding but
skips the structured-JSON/critic machinery — that's overkill for a
conversational patient-education chat, and the audit's own P0/P1
priorities focus the structured pipeline on the clinician-facing tool.
"""

from typing import Optional

from fastapi import FastAPI, HTTPException, Header
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from supabase import create_client, Client

from . import config, conversation, ai_client
from .safety import check_for_red_flags, SAFETY_MESSAGE
from .retrieval import build_patient_context, search_protocols, format_available_protocols, classify_complexity
from .schema import render_markdown

app = FastAPI(title="LiteTreatment AI Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.ALLOWED_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)

CDS_SYSTEM_PROMPT = """You are a Clinical Decision Support (CDS) assistant embedded in a hospital
platform, reasoning alongside a doctor or student doctor about a specific patient.
Your role is strictly advisory and NON-DIAGNOSTIC — never state a definitive
diagnosis; use "consider", "differential includes", "warrants investigation of".
If asked to diagnose outright, decline and redirect to differential considerations.
Ground every claim in the specific patient context, protocol references, or
conversation history you were given — don't give generic textbook answers when
specific context is available."""

PATIENT_SYSTEM_PROMPT = """You are a health-information assistant inside a hospital's patient app,
having an ongoing conversation — use earlier turns, not just the latest message.
Your role is educational only:
- Never diagnose a condition or tell the patient what they have.
- Never recommend a specific medication, dosage, or treatment.
- Explain concepts with real depth in plain language, not one-line definitions.
- Help the patient prepare specific questions for their doctor.
- For anything urgent or personal to their case, direct them to their doctor or
  the nearest hospital.
- If the question is vague, ask a clarifying question rather than guessing what
  they mean.
Keep formatting readable on a phone, but don't sacrifice a complete explanation."""


class ChatRequest(BaseModel):
    message: str
    conversationId: Optional[str] = None
    caseId: Optional[str] = None
    patientId: Optional[str] = None


def get_user_client(authorization: Optional[str]):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Not authenticated")
    token = authorization.split(" ", 1)[1]

    client: Client = create_client(config.SUPABASE_URL, config.SUPABASE_ANON_KEY)
    try:
        user_response = client.auth.get_user(token)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired token")
    if not user_response or not user_response.user:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    client.postgrest.auth(token)
    return client, user_response.user


def get_profile_role(client: Client, user_id: str) -> str:
    res = client.table("profiles").select("role").eq("id", user_id).single().execute()
    if not res.data:
        raise HTTPException(status_code=403, detail="No profile found for this account")
    return res.data["role"]


@app.get("/health")
def health():
    return {
        "status": "ok",
        "ai_configured": bool(config.AI_API_KEY),
        "model_fast": config.AI_MODEL_FAST,
        "model_reasoning": config.AI_MODEL_REASONING,
    }


@app.post("/cds-assist")
def cds_assist(body: ChatRequest, authorization: Optional[str] = Header(None)):
    client, user = get_user_client(authorization)
    role = get_profile_role(client, user.id)
    if role not in ("doctor", "student_doctor", "admin"):
        raise HTTPException(status_code=403, detail="CDS assistant is only available to clinicians")

    conversation_id = conversation.get_or_create_conversation(
        client, body.conversationId, user.id, "cds", body.message, body.caseId, body.patientId
    )
    conversation.log_message(client, conversation_id, "user", body.message)

    safety = check_for_red_flags(body.message)

    grounding_parts = []
    if body.patientId:
        grounding_parts.append(build_patient_context(client, body.message, body.patientId, body.caseId))
    protocols = search_protocols(client, body.message)
    grounding_parts.append(format_available_protocols(protocols))
    grounding = "\n\n".join(grounding_parts)

    summary = conversation.get_conversation_summary(client, conversation_id)
    history = conversation.get_recent_messages(client, conversation_id)[:-1]  # exclude the message we just logged
    if summary:
        history = [{"role": "system", "content": f"Summary of earlier conversation: {summary}"}] + history

    # A trivial clinician query ("what's the normal adult potassium
    # range?") doesn't need the expensive tier either — but a
    # triggered safety flag always forces the reasoning model,
    # regardless of what the word-count heuristic would say.
    complexity = classify_complexity(body.message, safety.triggered)
    model = config.AI_MODEL_FAST if complexity == "fast" else config.AI_MODEL_REASONING

    assessment = ai_client.generate_assessment(
        model, CDS_SYSTEM_PROMPT, grounding, [p["title"] for p in protocols], history, body.message
    )

    if safety.triggered:
        assessment.red_flags = [f"[Safety gate: {', '.join(safety.categories)}] {SAFETY_MESSAGE}"] + assessment.red_flags

    if config.AI_API_KEY and not assessment.schema_parse_failed:
        critique = ai_client.critique(config.AI_MODEL_FAST, assessment, grounding)
        if critique.get("regenerate_recommended"):
            feedback = critique.get("feedback", "")
            retry_message = body.message + f"\n\n[Internal reviewer feedback to address: {feedback}]"
            assessment = ai_client.generate_assessment(
                model, CDS_SYSTEM_PROMPT, grounding, [p["title"] for p in protocols], history, retry_message
            )
            if safety.triggered:
                assessment.red_flags = [f"[Safety gate: {', '.join(safety.categories)}] {SAFETY_MESSAGE}"] + assessment.red_flags

    reply = render_markdown(assessment)
    conversation.log_message(client, conversation_id, "assistant", reply, metadata=assessment.model_dump())
    conversation.maybe_update_summary(client, conversation_id, lambda p: ai_client.summarize(config.AI_MODEL_FAST, p))

    return {"conversationId": conversation_id, "reply": reply, "structured": assessment.model_dump()}


@app.post("/patient-assist")
def patient_assist(body: ChatRequest, authorization: Optional[str] = Header(None)):
    client, user = get_user_client(authorization)

    conversation_id = conversation.get_or_create_conversation(client, body.conversationId, user.id, "patient", body.message)
    conversation.log_message(client, conversation_id, "user", body.message)

    safety = check_for_red_flags(body.message)
    if safety.triggered:
        conversation.log_message(client, conversation_id, "assistant", SAFETY_MESSAGE, metadata={"safety_gate": safety.categories})
        return {"conversationId": conversation_id, "reply": SAFETY_MESSAGE, "safetyTriggered": True}

    summary = conversation.get_conversation_summary(client, conversation_id)
    history = conversation.get_recent_messages(client, conversation_id)[:-1]
    if summary:
        history = [{"role": "system", "content": f"Summary of earlier conversation: {summary}"}] + history

    complexity = classify_complexity(body.message, safety.triggered)
    model = config.AI_MODEL_FAST if complexity == "fast" else config.AI_MODEL_REASONING

    reply = ai_client.simple_reply(model, PATIENT_SYSTEM_PROMPT, history, body.message)
    conversation.log_message(client, conversation_id, "assistant", reply)
    conversation.maybe_update_summary(client, conversation_id, lambda p: ai_client.summarize(config.AI_MODEL_FAST, p))

    return {"conversationId": conversation_id, "reply": reply}
