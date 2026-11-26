import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPORTER = Path(__file__).resolve().parents[1] / "tools" / "profiler_report.py"


class ReportTest(unittest.TestCase):
    def test_sort_filter_html_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "recording.json"
            output = root / "report.html"
            data = {
                "meta": {"schema": "rgss-native-profiler-v1", "duration_ms": 20,
                         "event_count": 4, "stop_reason": "manual", "callback_ms": 1,
                         "unattributed_ms": 0, "unmatched_returns": 0, "raises": 0,
                         "limitations": ["wall time"]},
                "methods": [], "frames": [], "events": [],
            }
            for name, time in [("BSMP#tick</script><script>bad()</script>", 15), ("Game#update", 5)]:
                data["methods"].append(dict(id=len(data["methods"]), name=name, native=False,
                    file="Карта.rb", first_observed_line=1, self_ms=time, total_ms=time,
                    calls=2, completed=2, unwound=0, open_at_stop=0))
            path.write_text(json.dumps(data), encoding="utf-8")
            command = [sys.executable, str(REPORTER), str(path), "--html", str(output)]
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertLess(result.stdout.index("BSMP#tick"), result.stdout.index("Game#update"))
            page = output.read_text()
            self.assertNotIn("<script>bad()", page)
            self.assertNotIn('"events":', page)
            embedded = page.split('type="application/json">', 1)[1].split('</script>', 1)[0]
            self.assertEqual(json.loads(embedded)["methods"], data["methods"])
            second = subprocess.run(command, capture_output=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(output.read_text(), page)
            filtered = subprocess.run([sys.executable, str(REPORTER), str(path), "--filter", "BSMP"],
                                      capture_output=True, text=True, check=True)
            self.assertIn("BSMP#tick", filtered.stdout)
            self.assertNotIn("Game#update", filtered.stdout)

    def test_wrong_schema_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"meta":{"schema":"other"}}')
            result = subprocess.run([sys.executable, str(REPORTER), str(path)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
