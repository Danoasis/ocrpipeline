from datetime import date, timedelta
import pytest
from app.validation import check_expiration

def days_from_today(n):
    return (date.today() + timedelta(days=n)).isoformat()

def test_valid():             assert check_expiration(days_from_today(100))["status"] == "valid"
def test_expiring_soon():     assert check_expiration(days_from_today(15))["status"]  == "expiring_soon"
def test_expired():           assert check_expiration(days_from_today(-1))["status"]  == "expired"
def test_none_unknown():      assert check_expiration(None)["status"]                 == "unknown"
def test_empty_unknown():     assert check_expiration("")["status"]                   == "unknown"
def test_bad_format_error():  assert check_expiration("03/15/2027")["status"]         == "error"
def test_boundary_30_valid(): assert check_expiration(days_from_today(30))["status"]  == "valid"
def test_boundary_29_soon():  assert check_expiration(days_from_today(29))["status"]  == "expiring_soon"
def test_days_remaining():    assert check_expiration(days_from_today(50))["days_remaining"] == 50
def test_negative_days():     assert check_expiration(days_from_today(-10))["days_remaining"] == -10

EXPECTED_KEYS = {"status", "days_remaining", "reason"}
@pytest.mark.parametrize("d", [days_from_today(100), days_from_today(15),
                                days_from_today(-10), None, "bad"])
def test_always_has_keys(d):
    assert set(check_expiration(d).keys()) == EXPECTED_KEYS
