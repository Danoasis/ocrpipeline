"""
validation.py — business rule checks on extracted license data.
Pure Python, no I/O, fully unit-testable.
"""
from datetime import datetime


def check_expiration(expiration_date_str: str | None) -> dict:
    if not expiration_date_str:
        return {"status": "unknown", "days_remaining": None,
                "reason": "No expiration date found in extracted data."}
    try:
        exp_date = datetime.strptime(expiration_date_str, "%Y-%m-%d").date()
        today    = datetime.today().date()
        delta    = (exp_date - today).days

        if delta < 0:
            return {"status": "expired",       "days_remaining": delta,
                    "reason": f"Expired {abs(delta)} days ago."}
        elif delta < 30:
            return {"status": "expiring_soon", "days_remaining": delta,
                    "reason": f"Expires in {delta} days — renewal recommended."}
        else:
            return {"status": "valid",         "days_remaining": delta,
                    "reason": f"Valid for {delta} more days."}
    except ValueError:
        return {"status": "error", "days_remaining": None,
                "reason": f"Could not parse date '{expiration_date_str}'. Expected YYYY-MM-DD."}
