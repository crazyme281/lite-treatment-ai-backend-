"""
Structured output schema for cds-assist (audit item: "structured
output/schema" + "confidence and uncertainty explicitly").

Parsing is deliberately defensive: we ask the model for JSON and use
JSON-mode where the provider supports it, but we don't assume every
OpenAI-compatible provider implements strict schema enforcement — so
on any parse failure we degrade to a minimal-but-valid assessment
that carries the raw text in `reasoning`, rather than crashing the
request or silently returning malformed data.
"""

import json
import re
from typing import Literal, Optional

from pydantic import BaseModel, Field, ValidationError


class DifferentialItem(BaseModel):
    diagnosis: str
    likelihood: Literal["high", "moderate", "low"] = "moderate"
    rationale: str = ""


class ClinicalAssessment(BaseModel):
    most_likely: str = ""
    confidence: Literal["low", "moderate", "high"] = "low"
    differential: list[DifferentialItem] = Field(default_factory=list)
    missing_information: list[str] = Field(default_factory=list)
    clarifying_questions: list[str] = Field(default_factory=list)
    recommended_workup: list[str] = Field(default_factory=list)
    red_flags: list[str] = Field(default_factory=list)
    protocols_used: list[str] = Field(default_factory=list)
    reasoning: str = ""
    # Set by our own code, never by the model — tracks whether the
    # model's JSON actually parsed, and whether we had to strip any
    # hallucinated protocol citations.
    schema_parse_failed: bool = False
    hallucinated_protocols_stripped: list[str] = Field(default_factory=list)


ASSESSMENT_JSON_INSTRUCTIONS = """Respond with ONLY a single JSON object (no markdown fences, no prose
outside the JSON) with exactly these keys:
{
  "most_likely": string,
  "confidence": "low" | "moderate" | "high",
  "differential": [{"diagnosis": string, "likelihood": "high"|"moderate"|"low", "rationale": string}, ...],
  "missing_information": [string, ...],
  "clarifying_questions": [string, ...],
  "recommended_workup": [string, ...],
  "red_flags": [string, ...],
  "protocols_used": [string, ...],
  "reasoning": string
}
Rules:
- "protocols_used" may ONLY contain protocol names that appear verbatim in the
  AVAILABLE PROTOCOLS list you were given. If none apply, leave it empty and
  say so in "reasoning" — never invent or reference a protocol not in that list.
- If the message is vague (e.g. a single symptom with no location/duration/
  severity/onset), prioritize "clarifying_questions" and "missing_information"
  over producing a long differential from guesswork.
- "red_flags" should list anything in the context or message that warrants
  urgent escalation, even if you already answered elsewhere."""


def _extract_json_block(text: str) -> Optional[dict]:
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        pass
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            return None
    return None


def parse_assessment(raw_text: str) -> ClinicalAssessment:
    data = _extract_json_block(raw_text)
    if data is None:
        return ClinicalAssessment(reasoning=raw_text, schema_parse_failed=True)
    try:
        return ClinicalAssessment(**data)
    except ValidationError:
        # Partially valid JSON (e.g. a field has the wrong type) — keep
        # whatever we can rather than discarding a mostly-good response.
        cleaned = {k: v for k, v in data.items() if k in ClinicalAssessment.model_fields}
        try:
            return ClinicalAssessment(**cleaned)
        except ValidationError:
            return ClinicalAssessment(reasoning=raw_text, schema_parse_failed=True)


def validate_protocol_citations(assessment: ClinicalAssessment, available_protocol_titles: list[str]) -> ClinicalAssessment:
    """Deterministic check — never trust the model's own claim that a
    citation is real. Case-insensitive exact-title match only."""
    available_lower = {t.lower() for t in available_protocol_titles}
    kept, stripped = [], []
    for name in assessment.protocols_used:
        (kept if name.lower() in available_lower else stripped).append(name)
    assessment.protocols_used = kept
    assessment.hallucinated_protocols_stripped = stripped
    return assessment


def render_markdown(assessment: ClinicalAssessment) -> str:
    """Renders the structured assessment into the markdown-ish string
    the existing chat UI displays — keeps the frontend unchanged while
    the backend does structured reasoning underneath."""
    if assessment.schema_parse_failed:
        return assessment.reasoning

    lines = []
    if assessment.clarifying_questions:
        lines.append("**A few things that would help narrow this down:**")
        lines += [f"- {q}" for q in assessment.clarifying_questions]
        lines.append("")

    if assessment.most_likely:
        lines.append(f"**Most likely:** {assessment.most_likely} (confidence: {assessment.confidence})")
        lines.append("")

    if assessment.differential:
        lines.append("**Differential:**")
        for d in assessment.differential:
            lines.append(f"- {d.diagnosis} ({d.likelihood}) — {d.rationale}")
        lines.append("")

    if assessment.recommended_workup:
        lines.append("**Recommended workup:**")
        lines += [f"- {w}" for w in assessment.recommended_workup]
        lines.append("")

    if assessment.red_flags:
        lines.append("**Red flags:**")
        lines += [f"- {r}" for r in assessment.red_flags]
        lines.append("")

    if assessment.missing_information:
        lines.append("**Missing information that would sharpen this:**")
        lines += [f"- {m}" for m in assessment.missing_information]
        lines.append("")

    if assessment.protocols_used:
        lines.append(f"**Protocols cited:** {', '.join(assessment.protocols_used)}")

    if assessment.reasoning:
        lines.append("")
        lines.append(assessment.reasoning)

    lines.append("")
    lines.append("_Advisory only — final diagnostic and treatment authority rests with the treating physician._")
    return "\n".join(lines).strip()
