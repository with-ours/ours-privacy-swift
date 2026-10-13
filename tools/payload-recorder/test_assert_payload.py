import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class PayloadAssertionTests(unittest.TestCase):
    def payload(self):
        return {
            "token": "test-token", "is_manually_set_id": False,
            "data": [{
                "event": "appointment_booked", "visitor_id": "visitor", "distinct_id": "event",
                "defaultProperties": {"sid": "1791194400000", "os_name": "iOS"},
                "eventProperties": {
                    "mobile_contract_version": 1, "mobile_occurred_at": "2026-10-05T10:00:00.000Z",
                    "appointment_id": "visit-1",
                },
                "userProperties": None,
            }],
        }

    def assert_payload(self, captured, fixture):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ["captured.json", "fixture.json"]]
            for path, payload in zip(paths, [captured, fixture]):
                path.write_text(json.dumps(payload))
            return subprocess.run(
                [sys.executable, str(Path(__file__).with_name("assert_payload.py")), *map(str, paths)],
                capture_output=True, text=True, timeout=5,
            )

    def test_valid_mobile_timestamps_vary_without_changing_contract(self):
        fixture = self.payload()
        captured = copy.deepcopy(fixture)
        captured["data"][0]["defaultProperties"]["sid"] = "1791194400123"
        captured["data"][0]["eventProperties"]["mobile_occurred_at"] = "2026-10-05T10:00:01.456Z"
        result = self.assert_payload(captured, fixture)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_rejects_invalid_mobile_wire_even_when_fixture_matches(self):
        for mutate in [
            lambda row: row["defaultProperties"].update(
                mobile_contract_version=row["eventProperties"].pop("mobile_contract_version")),
            lambda row: row["defaultProperties"].update(sid="D92E56DC-CFDA-4E5D-B58D-D9F0AB63C74C"),
            lambda row: row["defaultProperties"].update(mobile_contract_version=1),
            lambda row: row["eventProperties"].update(mobile_platform="ios"),
            lambda row: row["eventProperties"].update(mobile_occurred_at="2026-10-05T10:00:00Z"),
            lambda row: row["eventProperties"].update(mobile_occurred_at="2026-10-05T09:59:59.999Z"),
        ]:
            captured = self.payload()
            mutate(captured["data"][0])
            result = self.assert_payload(captured, captured)
            self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
