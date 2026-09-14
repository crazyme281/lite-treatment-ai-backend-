import json

from app.schema import parse_assessment, validate_protocol_citations, render_markdown, ClinicalAssessment


VALID_JSON = json.dumps({
    "most_likely": "Acute coronary syndrome",
    "confidence": "moderate",
    "differential": [
        {"diagnosis": "ACS", "likelihood": "high", "rationale": "Crushing chest pain radiating to arm"},
        {"diagnosis": "GERD", "likelihood": "low", "rationale": "Less likely given radiation pattern"},
    ],
    "missing_information": ["Duration of pain"],
    "clarifying_questions": [],
    "recommended_workup": ["ECG within 10 minutes", "Troponin at 0h/1h"],
    "red_flags": ["Radiating pain"],
    "protocols_used": ["Acute Chest Pain"],
    "reasoning": "Pattern consistent with cardiac etiology.",
})


def test_parses_valid_json():
    assessment = parse_assessment(VALID_JSON)
    assert assessment.schema_parse_failed is False
    assert assessment.most_likely == "Acute coronary syndrome"
    assert len(assessment.differential) == 2
    assert assessment.differential[0].likelihood == "high"


def test_parses_json_wrapped_in_prose_or_fences():
    wrapped = f"Here's my assessment:\n```json\n{VALID_JSON}\n```\nLet me know if you need more."
    assessment = parse_assessment(wrapped)
    assert assessment.schema_parse_failed is False
    assert assessment.most_likely == "Acute coronary syndrome"


def test_degrades_gracefully_on_total_garbage():
    assessment = parse_assessment("I think this might be a heart attack, get an ECG.")
    assert assessment.schema_parse_failed is True
    assert "heart attack" in assessment.reasoning


def test_degrades_gracefully_on_wrong_types():
    bad = json.dumps({"most_likely": 12345, "differential": "not a list"})
    assessment = parse_assessment(bad)
    assert isinstance(assessment, ClinicalAssessment)


def test_strips_hallucinated_protocol_citation():
    assessment = parse_assessment(VALID_JSON)
    assessment.protocols_used = ["Acute Chest Pain", "Made Up Protocol That Does Not Exist"]
    validated = validate_protocol_citations(assessment, available_protocol_titles=["Acute Chest Pain", "Sepsis Protocol"])
    assert validated.protocols_used == ["Acute Chest Pain"]
    assert validated.hallucinated_protocols_stripped == ["Made Up Protocol That Does Not Exist"]


def test_citation_validation_is_case_insensitive():
    assessment = ClinicalAssessment(protocols_used=["acute chest pain"])
    validated = validate_protocol_citations(assessment, available_protocol_titles=["Acute Chest Pain"])
    assert validated.protocols_used == ["acute chest pain"]
    assert validated.hallucinated_protocols_stripped == []


def test_render_markdown_includes_key_sections():
    assessment = parse_assessment(VALID_JSON)
    md = render_markdown(assessment)
    assert "Most likely" in md
    assert "ACS" in md
    assert "ECG within 10 minutes" in md
    assert "Radiating pain" in md
    assert "Advisory only" in md


def test_render_markdown_falls_back_to_raw_text_on_parse_failure():
    assessment = parse_assessment("plain text answer with no json")
    md = render_markdown(assessment)
    assert md == "plain text answer with no json"


def test_render_markdown_prioritizes_clarifying_questions_when_present():
    assessment = ClinicalAssessment(clarifying_questions=["How long has the pain lasted?", "Any fever?"])
    md = render_markdown(assessment)
    assert md.index("How long has the pain lasted") < md.index("Advisory only")
