"""
Deterministic emergency detection that runs before any AI call.

Per the audit: don't rely on an LLM to recognize emergencies — a
keyword/phrase-based gate that can't be "reasoned around" by a model
having a bad turn is the actual safety net. This is intentionally
crude and over-inclusive (false positives are fine here — worst case
someone sees an ER-now message when they didn't need one; false
negatives are the failure mode that matters).

This does NOT replace clinical judgement or the AI's own reasoning —
it's a floor, not a ceiling. Category keys are used only internally
for logging/testing; the user-facing message is the same for all.
"""

from dataclasses import dataclass, field


@dataclass
class SafetyCheckResult:
    triggered: bool
    categories: list[str] = field(default_factory=list)


# Each entry is a short phrase, checked as a substring against the
# lowercased message. Intentionally broad phrasing over exact medical
# terminology, since patients/staff typing quickly won't use precise
# vocabulary either.
RED_FLAG_PATTERNS: dict[str, list[str]] = {
    "breathing": [
        "can't breathe", "cant breathe", "cannot breathe", "struggling to breathe",
        "gasping for air", "turning blue", "lips are blue", "not breathing",
    ],
    "chest_pain": [
        "crushing chest pain", "severe chest pain", "chest pain and can't breathe",
        "chest pain radiating", "worst chest pain",
    ],
    "consciousness": [
        "unresponsive", "not waking up", "won't wake up", "wont wake up",
        "passed out and won't wake", "unconscious", "loss of consciousness",
    ],
    "bleeding": [
        "won't stop bleeding", "wont stop bleeding", "bleeding heavily",
        "massive bleeding", "blood everywhere", "hemorrhage",
    ],
    "stroke": [
        "face drooping", "slurred speech", "sudden weakness on one side",
        "can't speak suddenly", "cant speak suddenly", "sudden confusion",
        "worst headache of my life",
    ],
    "allergic_reaction": [
        "throat closing", "throat is closing", "swelling throat", "anaphylaxis",
        "can't breathe after eating", "face swelling and can't breathe",
    ],
    "shock": [
        "fainted and pale", "cold and clammy", "very low blood pressure and confused",
    ],
    "self_harm": [
        "want to kill myself", "want to end my life", "going to kill myself",
        "suicidal", "hurting myself on purpose", "planning to end it",
    ],
}

SAFETY_MESSAGE = (
    "This sounds like it could be a medical emergency. Please call your local "
    "emergency number or go to the nearest emergency department right now — "
    "don't wait for a reply here. If this is about thoughts of suicide or "
    "self-harm, please reach out to a crisis line or emergency services "
    "immediately; you don't have to be alone with this."
)


def check_for_red_flags(message: str) -> SafetyCheckResult:
    text = message.lower()
    matched = [category for category, phrases in RED_FLAG_PATTERNS.items() if any(p in text for p in phrases)]
    return SafetyCheckResult(triggered=bool(matched), categories=matched)
