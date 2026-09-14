from app.safety import check_for_red_flags


def test_no_red_flags_on_ordinary_message():
    result = check_for_red_flags("I've had a mild headache since yesterday")
    assert result.triggered is False
    assert result.categories == []


def test_detects_breathing_emergency():
    result = check_for_red_flags("She can't breathe and her lips are blue")
    assert result.triggered is True
    assert "breathing" in result.categories


def test_detects_stroke_symptoms():
    result = check_for_red_flags("Sudden face drooping and slurred speech")
    assert result.triggered is True
    assert "stroke" in result.categories


def test_detects_self_harm_language():
    result = check_for_red_flags("I want to kill myself")
    assert result.triggered is True
    assert "self_harm" in result.categories


def test_detects_multiple_categories_at_once():
    result = check_for_red_flags("chest pain and can't breathe, throat is closing")
    assert result.triggered is True
    assert "breathing" in result.categories
    assert "allergic_reaction" in result.categories


def test_case_insensitive():
    result = check_for_red_flags("UNRESPONSIVE and not waking up")
    assert result.triggered is True
    assert "consciousness" in result.categories


def test_mild_chest_discomfort_does_not_falsely_trigger_severe_wording():
    # Sanity check that we're matching specific phrases, not just "chest"
    result = check_for_red_flags("Mild chest discomfort after exercise, resolved with rest")
    assert result.triggered is False
