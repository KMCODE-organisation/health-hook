"""Tests of homeassistant/health_hook/journal.py. Run: python3 -m unittest discover -s tools -p "test_*.py" """
import base64
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "journal", Path(__file__).resolve().parent.parent / "homeassistant" / "health_hook" / "journal.py")
journal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journal)


def run(func, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        func(*args)
    return json.loads(out.getvalue())


def b64(days):
    return base64.b64encode(json.dumps({"days": days}).encode()).decode()


class JournalTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        journal.JOURNAL = str(Path(self.tmp.name) / "journal.jsonl")

    def tearDown(self):
        self.tmp.cleanup()

    def lines(self):
        return [json.loads(line) for line in Path(journal.JOURNAL).read_text().splitlines()]

    def test_add_merges_by_date_latest_wins(self):
        run(journal.add, b64([{"date": "2026-01-02", "steps": 100, "sleep": 7.5}]))
        r = run(journal.add, b64([{"date": "2026-01-02", "steps": 900}, {"date": "2026-01-01", "hrv": 40}]))
        self.assertEqual(r, {"merged_days": 2, "journal_days": 2})
        self.assertEqual(self.lines(), [
            {"date": "2026-01-01", "hrv": 40},
            {"date": "2026-01-02", "steps": 900, "sleep": 7.5},   # sorted by date, other keys kept
        ])

    def test_add_ignores_non_numbers_and_empty_days(self):
        r = run(journal.add, b64([{"date": "2026-01-01", "steps": None, "x": "a", "ok": True}, {"steps": 3}]))
        self.assertEqual(r["merged_days"], 0)
        self.assertFalse(Path(journal.JOURNAL).exists())

    def test_summary_averages_and_fingerprint(self):
        today = date(2026, 3, 31)
        days = [{"date": (today - timedelta(days=i)).isoformat(), "steps": 1000 * i} for i in range(0, 10)]
        run(journal.add, b64(days))
        s = run(journal.summary, today.isoformat(), "-")
        steps = s["metrics"]["steps"]
        self.assertEqual(steps["unit"], "steps")
        self.assertEqual(steps["yesterday"], 1000)
        self.assertEqual(steps["avg7"], 4000)            # days 1..7 before today (today is partial)
        self.assertEqual((steps["min30"], steps["max30"]), (1000, 9000))
        self.assertEqual(len(s["days_since_previous_summary"]), 7)
        self.assertEqual(run(journal.summary, today.isoformat(), "-")["fingerprint"], s["fingerprint"])
        run(journal.add, b64([{"date": today.isoformat(), "steps": 1}]))
        self.assertNotEqual(run(journal.summary, today.isoformat(), "-")["fingerprint"], s["fingerprint"])

    def test_summary_since_previous(self):
        run(journal.add, b64([{"date": f"2026-03-{d:02d}", "steps": d} for d in range(20, 32)]))
        s = run(journal.summary, "2026-03-31", "2026-03-29T08:00:00")
        self.assertEqual([d["date"] for d in s["days_since_previous_summary"]], ["2026-03-29", "2026-03-30", "2026-03-31"])


if __name__ == "__main__":
    unittest.main()
