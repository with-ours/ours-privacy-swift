#!/usr/bin/env python3
"""Capture POST bodies from the SDK and write each one as JSON to ./captures/.

Point the demo at it with:
    OursPrivacy.setServerURL("http://localhost:8765")

Usage:
    python3 tools/payload-recorder/server.py [--port 8765] [--out captures/]
"""
import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Recorder(BaseHTTPRequestHandler):
    out_dir = "captures"
    seq = 0

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        Recorder.seq += 1
        ts = time.strftime("%Y%m%dT%H%M%S")
        name = f"{ts}-{Recorder.seq:04d}{self.path.replace('/', '_') or '_root'}.json"
        path = os.path.join(Recorder.out_dir, name)
        try:
            body = json.loads(raw)
            pretty = json.dumps(body, indent=2, sort_keys=True)
        except json.JSONDecodeError:
            pretty = raw.decode("utf-8", errors="replace")
        with open(path, "w") as f:
            f.write(pretty)
        print(f"[recorder] {self.command} {self.path} -> {path}", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, *args):  # silence default access log
        pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--out", default="captures")
    args = p.parse_args()
    Recorder.out_dir = args.out
    os.makedirs(args.out, exist_ok=True)
    print(f"[recorder] listening on http://localhost:{args.port} -> {args.out}/", flush=True)
    try:
        HTTPServer(("127.0.0.1", args.port), Recorder).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
