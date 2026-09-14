from unittest.mock import MagicMock

from app.retrieval import build_patient_context, format_available_protocols, classify_complexity


def make_client(history_data, entries_data, visits_data, case_data=None):
    client = MagicMock()

    def table_side_effect(name):
        m = MagicMock()
        if name == "medical_history":
            m.select.return_value.eq.return_value.maybe_single.return_value.execute.return_value.data = history_data
        elif name == "medical_entries":
            m.select.return_value.eq.return_value.execute.return_value.data = entries_data
        elif name == "hospital_visits":
            m.select.return_value.eq.return_value.order.return_value.limit.return_value.execute.return_value.data = visits_data
        elif name == "cases":
            m.select.return_value.eq.return_value.maybe_single.return_value.execute.return_value.data = case_data
        return m

    client.table.side_effect = table_side_effect
    return client


HISTORY = {"blood_group": "O+", "genotype": "AA", "disability_or_special_needs": None, "family_medical_history": "Father: hypertension", "additional_notes": None}
ENTRIES = [
    {"category": "allergy", "name": "Penicillin", "detail": None},
    {"category": "medication", "name": "Lisinopril", "detail": "10mg daily"},
    {"category": "condition", "name": "Asthma", "detail": None},
    {"category": "condition", "name": "Diabetes", "detail": None},
]
VISITS = [
    {"visit_date": "June 2026", "reason": "chest pain", "diagnosis": "GERD", "treatment_received": "omeprazole"},
    {"visit_date": "Jan 2025", "reason": "sprained ankle", "diagnosis": "ankle sprain", "treatment_received": "rest and ice"},
]


def test_allergies_and_medications_always_included_regardless_of_relevance():
    client = make_client(HISTORY, ENTRIES, VISITS)
    ctx = build_patient_context(client, "I have a rash on my arm", "patient-1", None)
    # Rash has nothing to do with Penicillin/Lisinopril by keyword overlap,
    # but they must still appear — safety-critical fields are never filtered.
    assert "Penicillin" in ctx
    assert "Lisinopril" in ctx


def test_visit_relevance_filtering_surfaces_matching_visit():
    client = make_client(HISTORY, ENTRIES, VISITS)
    ctx = build_patient_context(client, "chest pain again, feels similar to before", "patient-1", None)
    assert "GERD" in ctx
    # The unrelated ankle sprain visit should not be pulled in as "relevant"
    assert "sprained ankle" not in ctx or "1 of 2" in ctx  # tolerate either filtering approach as long as it's not silently identical


def test_visit_relevance_filtering_excludes_unrelated_visit_for_clear_query():
    client = make_client(HISTORY, ENTRIES, VISITS)
    ctx = build_patient_context(client, "chest pain radiating to left arm", "patient-1", None)
    assert "GERD" in ctx
    assert "ankle sprain" not in ctx


def test_condition_relevance_filtering():
    client = make_client(HISTORY, ENTRIES, VISITS)
    ctx = build_patient_context(client, "wheezing and shortness of breath, possible asthma flare", "patient-1", None)
    assert "Asthma" in ctx


def test_case_context_included_when_case_id_given():
    case_data = {"study_type": "CT Chest", "finding_summary": "no acute findings", "ai_confidence_pct": 88, "priority": "high", "status": "in_review", "diagnosis_notes": None}
    client = make_client(HISTORY, ENTRIES, VISITS, case_data)
    ctx = build_patient_context(client, "chest pain", "patient-1", "case-1")
    assert "CT Chest" in ctx
    assert "88" in ctx


def test_format_available_protocols_lists_titles():
    protocols = [{"title": "Acute Chest Pain", "differential": "ACS, PE", "protocol_summary": "ECG stat", "source_reference": "ESC"}]
    text = format_available_protocols(protocols)
    assert "Acute Chest Pain" in text
    assert "cite ONLY these" in text.lower() or "ONLY these" in text


def test_format_available_protocols_empty_case_forbids_citation():
    text = format_available_protocols([])
    assert "none retrieved" in text.lower()
    assert "do not cite" in text.lower()


def test_complexity_routing_simple_question():
    assert classify_complexity("what is the normal temperature", has_red_flags=False) == "fast"


def test_complexity_routing_complex_case():
    assert classify_complexity(
        "Patient has fever, tachycardia, hypotension and elevated WBC, worsening over 6 hours",
        has_red_flags=False,
    ) == "reasoning"


def test_complexity_routing_forces_reasoning_when_red_flags_present():
    assert classify_complexity("ok", has_red_flags=True) == "reasoning"
