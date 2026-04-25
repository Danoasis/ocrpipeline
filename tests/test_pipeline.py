import json
from pathlib import Path
from unittest.mock import patch
from app.pipeline import process_license, run_pipeline


MOCK_RESULT = {
    "extracted_fields": {
        "full_name": "Test User", "license_number": "T123",
        "date_of_birth": "1990-01-01", "expiration_date": "2030-01-01", "class": "C"
    },
    "validation": {"status": "valid", "days_remaining": 1000, "reason": "Valid."},
}


@patch("app.pipeline.extract_structured_data", return_value=MOCK_RESULT["extracted_fields"])
@patch("app.pipeline.extract_text_from_image", return_value="mock ocr text")
def test_process_license(mock_ocr, mock_llm):
    result = process_license("fake/path/license.png")
    assert result["extracted_fields"]["full_name"] == "Test User"
    assert "processed_at" in result
    assert "validation" in result


@patch("app.pipeline.extract_structured_data", return_value=MOCK_RESULT["extracted_fields"])
@patch("app.pipeline.extract_text_from_image", return_value="mock ocr text")
def test_run_pipeline_saves_results(mock_ocr, mock_llm, tmp_path, monkeypatch):
    input_dir  = tmp_path / "licenses"
    output_dir = tmp_path / "results"
    input_dir.mkdir(); output_dir.mkdir()
    (input_dir / "test.png").write_bytes(b"fake image data")

    monkeypatch.setattr("app.pipeline.INPUT_FOLDER",  str(input_dir))
    monkeypatch.setattr("app.pipeline.OUTPUT_FOLDER", str(output_dir))

    run_pipeline()

    result_files = list(output_dir.glob("*.json"))
    assert len(result_files) == 1
    data = json.loads(result_files[0].read_text())
    assert data["extracted_fields"]["full_name"] == "Test User"
