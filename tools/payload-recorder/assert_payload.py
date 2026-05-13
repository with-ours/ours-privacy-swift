#!/usr/bin/env python3
"""Diff a captured payload against a fixture, ignoring known volatile keys.

Usage:
    python3 tools/payload-recorder/assert_payload.py <captured.json> <fixture.json>

Exits 0 on match, 1 on mismatch. Pretty-prints the offending paths.
"""
import json
import sys

VOLATILE_KEYS = {
    # Timestamps (legacy)
    "time", "$time", "timestamp", "session_id",
    # Canonical identifiers — UUIDs minted per event / per install
    "distinct_id", "visitor_id",
    # Device fingerprint — varies by host. Presence is pinned by the schema;
    # exact values don't matter for shape parity.
    "os_version", "device_model", "screen_width", "screen_height",
}


def diff(a, b, path="$"):
    diffs = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k in VOLATILE_KEYS:
                continue
            if k not in a:
                diffs.append(f"{path}.{k}: missing in captured")
            elif k not in b:
                diffs.append(f"{path}.{k}: missing in fixture")
            else:
                diffs.extend(diff(a[k], b[k], f"{path}.{k}"))
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            diffs.append(f"{path}: length {len(a)} vs {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diffs.extend(diff(x, y, f"{path}[{i}]"))
    elif a != b:
        diffs.append(f"{path}: {a!r} != {b!r}")
    return diffs


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        captured = json.load(f)
    with open(sys.argv[2]) as f:
        fixture = json.load(f)
    diffs = diff(captured, fixture)
    if diffs:
        for d in diffs:
            print(d)
        sys.exit(1)
    print("match")


if __name__ == "__main__":
    main()
