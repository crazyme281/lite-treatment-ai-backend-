"""
Retrieval layer (audit item 2 & 5: relevance-filtered context, not a
full record dump; and protocol retrieval).

Safety-critical fields (allergies, current medications) are ALWAYS
included regardless of relevance scoring — the audit's own example
keeps "relevant medications" in scope, and a drug-interaction/allergy
check should never depend on a keyword match against the chief
complaint. Everything else (past visits, conditions) is filtered by
simple word-overlap relevance against the current message, so a
patient's decade of unrelated ortho visits doesn't drown out today's
chest pain complaint.
"""

import re
from typing import Optional

STOPWORDS = {
    "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "i", "me", "my",
    "have", "had", "has", "been", "being", "of", "to", "in", "on", "at", "for", "with",
    "this", "that", "it", "again", "some", "any", "feel", "feeling", "since",
}


def _tokenize(text: str) -> set[str]:
    words = re.findall(r"[a-z]+", text.lower())
    return {w for w in words if w not in STOPWORDS and len(w) > 2}


def _relevance_score(message_tokens: set[str], *fields: Optional[str]) -> int:
    field_tokens: set[str] = set()
    for f in fields:
        if f:
            field_tokens |= _tokenize(f)
    return len(message_tokens & field_tokens)


def build_patient_context(client, message: str, patient_id: str, case_id: Optional[str]) -> str:
    parts = []
    message_tokens = _tokenize(message)

    history_res = client.table("medical_history").select(
        "blood_group, genotype, disability_or_special_needs, family_medical_history, additional_notes"
    ).eq("user_id", patient_id).maybe_single().execute()
    history = history_res.data or {}

    entries_res = client.table("medical_entries").select("category, name, detail").eq("patient_id", patient_id).execute()
    entries = entries_res.data or []

    allergies = [e["name"] for e in entries if e["category"] == "allergy"]
    medications = [f"{e['name']} ({e['detail']})" if e.get("detail") else e["name"] for e in entries if e["category"] == "medication"]

    conditions_all = [e["name"] for e in entries if e["category"] == "condition"]
    if message_tokens:
        conditions = [c for c in conditions_all if _relevance_score(message_tokens, c) > 0] or conditions_all[:3]
    else:
        conditions = conditions_all[:3]

    parts.append(
        "Patient context (always-included safety fields):\n"
        f"- Blood group: {history.get('blood_group') or 'unknown'}, Genotype: {history.get('genotype') or 'unknown'}\n"
        f"- Known allergies: {', '.join(allergies) or 'none recorded'}\n"
        f"- Current medications: {', '.join(medications) or 'none recorded'}\n"
        f"- Relevant known conditions: {', '.join(conditions) or 'none matched'}\n"
        f"- Family medical history: {history.get('family_medical_history') or 'none recorded'}"
    )

    visits_res = client.table("hospital_visits").select(
        "visit_date, reason, diagnosis, treatment_received"
    ).eq("patient_id", patient_id).order("created_at", desc=True).limit(15).execute()
    all_visits = visits_res.data or []

    if message_tokens:
        scored = [(v, _relevance_score(message_tokens, v.get("reason"), v.get("diagnosis"))) for v in all_visits]
        relevant_visits = [v for v, score in scored if score > 0][:3]
    else:
        relevant_visits = all_visits[:2]

    if relevant_visits:
        visit_lines = [
            f"  - {v.get('visit_date') or 'unknown date'}: {v.get('reason') or '—'} → {v.get('diagnosis') or 'no diagnosis recorded'} "
            f"(treatment: {v.get('treatment_received') or 'n/a'})"
            for v in relevant_visits
        ]
        parts.append(f"Relevant prior visits ({len(relevant_visits)} of {len(all_visits)} total, filtered by relevance to this message):\n" + "\n".join(visit_lines))
    elif all_visits:
        parts.append(f"({len(all_visits)} prior visit(s) on file, none matched this message's topic closely enough to include — ask if you need the full history.)")

    if case_id:
        case_res = client.table("cases").select(
            "study_type, finding_summary, ai_confidence_pct, priority, status, diagnosis_notes"
        ).eq("id", case_id).maybe_single().execute()
        c = case_res.data or {}
        if c:
            parts.append(
                "Active case:\n"
                f"- Study: {c.get('study_type') or 'n/a'}, Priority: {c.get('priority') or 'n/a'}, Status: {c.get('status') or 'n/a'}\n"
                f"- AI finding summary: {c.get('finding_summary') or 'none'} (confidence: {c.get('ai_confidence_pct')}%)\n"
                f"- Clinician notes so far: {c.get('diagnosis_notes') or 'none yet'}"
            )

    return "\n\n".join(parts)


def search_protocols(client, query_text: str) -> list[dict]:
    """Returns structured protocol objects (not pre-formatted text) so
    callers can both build the prompt AND validate citations against
    the same list."""
    try:
        res = client.rpc("search_protocols", {"p_query": query_text}).execute()
    except Exception:
        return []
    return res.data or []


def format_available_protocols(protocols: list[dict]) -> str:
    if not protocols:
        return "AVAILABLE PROTOCOLS: none retrieved for this query. Do not cite any protocol."
    lines = ["AVAILABLE PROTOCOLS (cite ONLY these, by exact title, if used):"]
    for p in protocols[:3]:
        lines.append(
            f'- "{p["title"]}" — differential: {p.get("differential") or "n/a"}; '
            f'protocol: {p.get("protocol_summary") or "n/a"} (source: {p.get("source_reference") or "n/a"})'
        )
    return "\n".join(lines)


SIMPLE_QUESTION_PATTERNS = [
    "normal temperature", "normal blood pressure", "normal heart rate",
    "what is", "what's", "define", "how long does", "visiting hours",
]


def classify_complexity(message: str, has_red_flags: bool) -> str:
    """Very deliberately simple (audit P2 "routing strategy"): a cheap
    heuristic, not another model call, to decide which model tier to
    use. Errs toward "reasoning" whenever uncertain — the cost of a
    wrongly-expensive call is a few cents; the cost of under-reasoning
    a real clinical question is not."""
    if has_red_flags:
        return "reasoning"
    text = message.lower()
    word_count = len(text.split())
    if word_count <= 12 and any(p in text for p in SIMPLE_QUESTION_PATTERNS):
        return "fast"
    if word_count <= 6:
        return "fast"
    return "reasoning"
