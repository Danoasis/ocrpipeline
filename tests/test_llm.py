import json
from unittest.mock import MagicMock, patch

from app.llm import extract_structured_data, repair_json


def test_repair_json_adds_missing_brace():
    incomplete = '{"full_name": "John", "license_number": "D123"'
    result = repair_json(incomplete)
    parsed = json.loads(result)
    assert parsed["full_name"] == "John"

def test_repair_json_no_change_needed():
    complete = '{"full_name": "John"}'
    assert repair_json(complete) == complete

def make_mock_response(content):
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"message": {"content": content}}
    mock_resp.raise_for_status = MagicMock()
    return mock_resp

@patch("app.llm.requests.post")
def test_successful_extraction(mock_post):
    mock_post.return_value = make_mock_response(
        '{"full_name": "Jane Doe", "license_number": "X999", '
        '"date_of_birth": "1990-01-01", "expiration_date": "2027-06-01", "class": "B"}'
    )
    result = extract_structured_data("some OCR text")
    assert result["full_name"] == "Jane Doe"
    assert result["expiration_date"] == "2027-06-01"

@patch("app.llm.requests.post")
def test_truncated_json_repaired(mock_post):
    mock_post.return_value = make_mock_response(
        '{"full_name": "Ana Rojas", "expiration_date": "2034-12-19", "class": "C"'
    )
    result = extract_structured_data("some OCR text")
    assert result["full_name"] == "Ana Rojas"
    assert "parse_error" not in result

@patch("app.llm.requests.post")
def test_null_fields_returned(mock_post):
    mock_post.return_value = make_mock_response(
        '{"full_name": null, "license_number": null, '
        '"date_of_birth": null, "expiration_date": null, "class": null}'
    )
    result = extract_structured_data("unreadable text")
    assert result["full_name"] is None
