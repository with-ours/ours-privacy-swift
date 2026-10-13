#!/usr/bin/env python3
"""Diff a captured payload against a fixture, ignoring known volatile keys.

Usage:
    python3 tools/payload-recorder/assert_payload.py <captured.json> <fixture.json>

Exits 0 on match, 1 on mismatch. Pretty-prints the offending paths.
"""
import json
import re
import sys
from datetime import datetime, timezone

VOLATILE_KEYS = {
    # Timestamps (legacy)
    "time", "$time", "timestamp", "session_id",
    # Canonical identifiers — UUIDs minted per event / per install
    "distinct_id", "visitor_id",
    # Device fingerprint — varies by host. Presence is pinned by the schema;
    # exact values don't matter for shape parity.
    "os_version", "device_model", "screen_width", "screen_height",
}
MOBILE_VOLATILE_KEYS = {"sid", "mobile_occurred_at"}


def mobile_errors(envelope):
    errors = []
    for index, item in enumerate(envelope.get("data", [])):
        properties = item.get("eventProperties") or {}
        defaults = item.get("defaultProperties") or {}
        if "mobile_contract_version" not in properties and "mobile_contract_version" not in defaults:
            continue
        path = f"$.data[{index}]"
        if type(properties.get("mobile_contract_version")) is not int or properties["mobile_contract_version"] != 1:
            errors.append(f"{path}.eventProperties.mobile_contract_version: expected 1")
        sid = defaults.get("sid")
        occurred_at = properties.get("mobile_occurred_at")
        if not isinstance(sid, str) or not re.fullmatch(r"[0-9]{13}", sid):
            errors.append(f"{path}.defaultProperties.sid: expected 13 decimal digits")
        if not isinstance(occurred_at, str) or not re.fullmatch(
                r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z", occurred_at):
            errors.append(f"{path}.eventProperties.mobile_occurred_at: expected UTC milliseconds")
        else:
            try:
                occurred = datetime.strptime(occurred_at, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
                if isinstance(sid, str) and re.fullmatch(r"[0-9]{13}", sid) and occurred.timestamp() * 1000 < int(sid):
                    errors.append(f"{path}: occurrence precedes session start")
            except ValueError:
                errors.append(f"{path}.eventProperties.mobile_occurred_at: invalid date")
        for key in ["mobile_contract_version", "mobile_occurred_at", "app_version", "app_build",
                    "mobile_session_started_at", "mobile_platform"]:
            if key in defaults:
                errors.append(f"{path}.defaultProperties.{key}: unexpected")
        for key in ["mobile_session_started_at", "mobile_platform"]:
            if key in properties:
                errors.append(f"{path}.eventProperties.{key}: unexpected")
    return errors


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
            elif k not in MOBILE_VOLATILE_KEYS:
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
    diffs = mobile_errors(captured) + diff(captured, fixture)
    if diffs:
        for d in diffs:
            print(d)
        sys.exit(1)
    print("match")


if __name__ == "__main__":
    main()
