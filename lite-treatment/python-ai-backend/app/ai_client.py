"""
All actual calls to the AI provider live here, so the rest of the
app never touches HTTP/JSON-parsing details directly.
"""

import httpx
from fastapi import HTTPException

from . import config
from .schema import ClinicalAssessment, parse_assessment, validate_protocol_citations, ASSESSMENT_JSON_INSTRUCTIONS, _extract_json_block

PLACEHOLDER_REPLY = (
    "AI provider not configured (AI_API_KEY missing). This is a placeholder "
    "response — set AI_API_KEY on this Render service to enable live replies."
)

CRITIC_SYSTEM_PROMPT = """You are a clinical-safety reviewer checking another AI's draft assessment
before it reaches a doctor. You are given the draft assessment (JSON), the
patient/case context it was based on, and the list of protocols it was
allowed to cite. Respond with ONLY a JSON object:
{
  "protocol_citations_valid": boolean,
  "unsupported_claims": [string, ...],
  "missing_differentials": [string, ...],
  "red_flags_missed": boolean,
  "regenerate_recommended": boolean,
  "feedback": string
}
Set regenerate_recommended=true only for a real problem (a claim not
supported by the given context, a missed red flag, or an invented protocol
citation) — not for stylistic preferences."""


def _post(model: str, messages: list[dict], json_mode: bool, max_tokens: int) -> str:
    if not config.AI_API_KEY:
        return PLACEHOLDER_REPLY

    payload = {"model": model, "messages": messages, "temperature": 0.2, "max_tokens": max_tokens}
    if json_mode:
        payload["response_format"] = {"type": "json_object"}

    def do_request(p: dict) -> httpx.Response:
        return httpx.post(
            config.AI_API_URL,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {config.AI_API_KEY}"},
            json=p,
            timeout=60.0,
        )

    try:
        resp = do_request(payload)
        if resp.status_code >= 400 and json_mode:
            payload.pop("response_format", None)
            resp = do_request(payload)
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"AI provider error: {e}")


def generate_assessment(
    model: str, system_prompt: str, grounding: str, available_protocol_titles: list[str],
    history: list[dict], user_message: str,
) -> ClinicalAssessment:
    messages = [{"role": "system", "content": system_prompt + "\n\n" + ASSESSMENT_JSON_INSTRUCTIONS}]
    if grounding:
        messages.append({"role": "system", "content": grounding})
    messages += history
    messages.append({"role": "user", "content": user_message})

    raw = _post(model, messages, json_mode=True, max_tokens=config.AI_MAX_TOKENS)
    if raw == PLACEHOLDER_REPLY:
        return ClinicalAssessment(reasoning=PLACEHOLDER_REPLY, schema_parse_failed=True)

    assessment = parse_assessment(raw)
    return validate_protocol_citations(assessment, available_protocol_titles)


def critique(model: str, assessment: ClinicalAssessment, grounding: str) -> dict:
    if not config.AI_API_KEY:
        return {"regenerate_recommended": False}
    messages = [
        {"role": "system", "content": CRITIC_SYSTEM_PROMPT},
        {"role": "system", "content": grounding},
        {"role": "user", "content": assessment.model_dump_json()},
    ]
    raw = _post(model, messages, json_mode=True, max_tokens=400)
    parsed = _extract_json_block(raw)
    return parsed or {"regenerate_recommended": False}


def simple_reply(model: str, system_prompt: str, history: list[dict], user_message: str) -> str:
    messages = [{"role": "system", "content": system_prompt}] + history + [{"role": "user", "content": user_message}]
    return _post(model, messages, json_mode=False, max_tokens=config.AI_MAX_TOKENS)


def summarize(model: str, prompt: str) -> str:
    return _post(model, [{"role": "user", "content": prompt}], json_mode=False, max_tokens=250)
