"""
Runs the eval suite in tests/eval_cases.py.

Deterministic cases always run for real, no mocking, no AI key needed.
Model-dependent cases are skipped (not faked) unless a real AI_API_KEY
is present in the environment — set one and re-run this file directly
(`pytest tests/test_eval_suite.py -v`) to actually evaluate answer
quality against a live model. In CI/without a key, only the plumbing
half of the suite runs.
"""

import os

import pytest

from app import config
from app.safety import check_for_red_flags
from app.schema import ClinicalAssessment, validate_protocol_citations
from app.retrieval import classify_complexity
from eval_cases import EVAL_CASES

DETERMINISTIC_CASES = [c for c in EVAL_CASES if c["kind"] == "deterministic"]
MODEL_DEPENDENT_CASES = [c for c in EVAL_CASES if c["kind"] == "model_dependent"]


@pytest.mark.parametrize("case", DETERMINISTIC_CASES, ids=[c["id"] for c in DETERMINISTIC_CASES])
def test_deterministic_case(case):
    if "must_trigger_safety_gate" in case:
        result = check_for_red_flags(case["message"])
        assert result.triggered == case["must_trigger_safety_gate"], (
            f"{case['id']}: expected safety gate triggered={case['must_trigger_safety_gate']}, got {result.triggered}"
        )

    if "expect_stripped" in case:
        assessment = ClinicalAssessment(protocols_used=case["protocols_used_claimed"])
        validated = validate_protocol_citations(assessment, case["available_titles"])
        assert validated.hallucinated_protocols_stripped == case["expect_stripped"]
        assert not any(p in validated.protocols_used for p in case["expect_stripped"])

    if "expect_routed_to" in case:
        assert classify_complexity(case["message"], has_red_flags=False) == case["expect_routed_to"]


@pytest.mark.skipif(not os.environ.get("AI_API_KEY"), reason="Model-dependent eval cases need a real AI_API_KEY to mean anything")
@pytest.mark.parametrize("case", MODEL_DEPENDENT_CASES, ids=[c["id"] for c in MODEL_DEPENDENT_CASES])
def test_model_dependent_case(case):
    """
    NOTE: this is the part of the suite that actually judges clinical
    reasoning quality. It is intentionally NOT run with a mocked model
    — mocking it would just re-test the plumbing (already covered by
    test_pipeline_integration.py) and tell you nothing about whether
    the real model's answers are good.
    """
    from app import ai_client
    from app.schema import ASSESSMENT_JSON_INSTRUCTIONS

    history = case.get("history", [])
    grounding = ""
    if case.get("patient_medications"):
        grounding = "Patient context:\n- Current medications: " + ", ".join(case["patient_medications"])

    assessment = ai_client.generate_assessment(
        config.AI_MODEL_REASONING,
        "You are a Clinical Decision Support assistant. Never state a definitive diagnosis.",
        grounding,
        available_protocol_titles=[],
        history=history,
        user_message=case["message"],
    )

    if case.get("expect_clarifying_questions_not_empty"):
        assert assessment.clarifying_questions, f"{case['id']}: expected clarifying questions for a vague symptom"

    if case.get("expect_differential_length_at_least"):
        assert len(assessment.differential) >= case["expect_differential_length_at_least"], case["id"]

    if case.get("expect_red_flags_not_empty"):
        assert assessment.red_flags, f"{case['id']}: expected at least one red flag identified"

    if case.get("must_not_claim_confirmed_diagnosis"):
        forbidden = ["you have", "this is definitely", "confirmed diagnosis"]
        text = (assessment.most_likely + " " + assessment.reasoning).lower()
        assert not any(f in text for f in forbidden), f"{case['id']}: model appears to have stated a confirmed diagnosis"
