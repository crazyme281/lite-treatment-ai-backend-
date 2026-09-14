import json
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def mock_user_client(role="doctor", conversation_id="convo-1"):
    """Builds a MagicMock standing in for the per-request Supabase
    client, wired just enough for the routes under test."""
    supa = MagicMock()

    def table_side_effect(name):
        m = MagicMock()
        if name == "profiles":
            m.select.return_value.eq.return_value.single.return_value.execute.return_value.data = {"role": role}
        elif name == "ai_conversations":
            m.insert.return_value.execute.return_value.data = [{"id": conversation_id}]
            m.select.return_value.eq.return_value.maybe_single.return_value.execute.return_value.data = {"summary": None}
            m.update.return_value.eq.return_value.execute.return_value.data = []
        elif name == "ai_messages":
            m.insert.return_value.execute.return_value.data = []
            m.select.return_value.eq.return_value.order.return_value.limit.return_value.execute.return_value.data = []
            m.select.return_value.eq.return_value.order.return_value.execute.return_value.data = []
        elif name == "medical_history":
            m.select.return_value.eq.return_value.maybe_single.return_value.execute.return_value.data = {}
        elif name == "medical_entries":
            m.select.return_value.eq.return_value.execute.return_value.data = []
        elif name == "hospital_visits":
            m.select.return_value.eq.return_value.order.return_value.limit.return_value.execute.return_value.data = []
        elif name == "cases":
            m.select.return_value.eq.return_value.maybe_single.return_value.execute.return_value.data = {}
        return m

    supa.table.side_effect = table_side_effect
    supa.rpc.return_value.execute.return_value.data = []
    return supa


def test_cds_assist_rejects_unauthenticated():
    resp = client.post("/cds-assist", json={"message": "chest pain"})
    assert resp.status_code == 401


def test_cds_assist_rejects_non_clinician_role():
    with patch("app.main.get_user_client", return_value=(mock_user_client(role="patient"), MagicMock(id="u1"))):
        resp = client.post("/cds-assist", json={"message": "chest pain"}, headers={"Authorization": "Bearer x"})
    assert resp.status_code == 403


def test_cds_assist_happy_path_with_mocked_ai():
    fake_supa = mock_user_client(role="doctor")
    fake_assessment_json = json.dumps({
        "most_likely": "ACS",
        "confidence": "moderate",
        "differential": [{"diagnosis": "ACS", "likelihood": "high", "rationale": "chest pain pattern"}],
        "missing_information": [],
        "clarifying_questions": [],
        "recommended_workup": ["ECG"],
        "red_flags": [],
        "protocols_used": [],
        "reasoning": "test reasoning",
    })

    with patch("app.main.get_user_client", return_value=(fake_supa, MagicMock(id="u1"))), \
         patch("app.ai_client.config.AI_API_KEY", "fake-key"), \
         patch("app.ai_client._post", return_value=fake_assessment_json):
        resp = client.post("/cds-assist", json={"message": "crushing chest pain"}, headers={"Authorization": "Bearer x"})

    assert resp.status_code == 200
    body = resp.json()
    assert "conversationId" in body
    assert "ACS" in body["reply"]
    assert body["structured"]["most_likely"] == "ACS"


def test_cds_assist_safety_gate_adds_red_flag_without_blocking_reasoning():
    fake_supa = mock_user_client(role="doctor")
    fake_assessment_json = json.dumps({
        "most_likely": "ACS", "confidence": "high", "differential": [], "missing_information": [],
        "clarifying_questions": [], "recommended_workup": [], "red_flags": [], "protocols_used": [], "reasoning": "x",
    })
    with patch("app.main.get_user_client", return_value=(fake_supa, MagicMock(id="u1"))), \
         patch("app.ai_client._post", return_value=fake_assessment_json):
        resp = client.post(
            "/cds-assist",
            json={"message": "patient can't breathe, lips are blue"},
            headers={"Authorization": "Bearer x"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert any("Safety gate" in rf for rf in body["structured"]["red_flags"])


def test_patient_assist_short_circuits_on_safety_trigger_without_calling_ai():
    fake_supa = mock_user_client(role="patient")
    with patch("app.main.get_user_client", return_value=(fake_supa, MagicMock(id="u1"))), \
         patch("app.ai_client._post") as mocked_post:
        resp = client.post(
            "/patient-assist",
            json={"message": "I want to kill myself"},
            headers={"Authorization": "Bearer x"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["safetyTriggered"] is True
    assert "crisis" in body["reply"].lower() or "emergency" in body["reply"].lower()
    mocked_post.assert_not_called()


def test_patient_assist_happy_path():
    fake_supa = mock_user_client(role="patient")
    with patch("app.main.get_user_client", return_value=(fake_supa, MagicMock(id="u1"))), \
         patch("app.ai_client._post", return_value="Fever is generally a temperature above 38C..."):
        resp = client.post("/patient-assist", json={"message": "what counts as a fever?"}, headers={"Authorization": "Bearer x"})
    assert resp.status_code == 200
    assert "fever" in resp.json()["reply"].lower()
