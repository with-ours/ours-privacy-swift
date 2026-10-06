import json
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import HTTPServer
from pathlib import Path
from urllib.request import Request, urlopen

from server import Recorder


class RecorderTests(unittest.TestCase):
    def test_does_not_report_ready_when_port_is_owned(self):
        with HTTPServer(("127.0.0.1", 0), Recorder) as occupied:
            with tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(
                    [sys.executable, str(Path(__file__).with_name("server.py")),
                     "--port", str(occupied.server_port), "--out", directory],
                    capture_output=True, text=True, timeout=5,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("[recorder] listening", result.stdout)

    def test_capture_endpoint_lists_received_envelopes(self):
        with tempfile.TemporaryDirectory() as directory:
            Recorder.out_dir = directory
            Recorder.seq = 0
            server = HTTPServer(("127.0.0.1", 0), Recorder)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            url = f"http://127.0.0.1:{server.server_port}"
            try:
                with urlopen(f"{url}/captures") as response:
                    self.assertEqual(json.load(response), [])

                payload = {"token": "test-token", "data": [{"event": "Started"}, {"event": "Booked"}]}
                request = Request(
                    f"{url}/ingest",
                    data=json.dumps(payload).encode(),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urlopen(request) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(json.load(response), {
                        "success": True,
                        "visitor_id": "recorder-visitor",
                        "accepted": 2,
                        "rejected": [],
                    })

                with urlopen(f"{url}/captures") as response:
                    self.assertEqual(json.load(response), [payload])
                self.assertEqual(len(list(Path(directory).glob("*.json"))), 1)
            finally:
                server.shutdown()
                server.server_close()
                worker.join()


if __name__ == "__main__":
    unittest.main()
