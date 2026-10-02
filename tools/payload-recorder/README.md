# Payload recorder

Tiny tools for capturing what the SDK posts to the ingest endpoint, and diffing those captures against a fixture file.

Used to verify the SDK's `{token, is_manually_set_id, data}` ingest envelope. Each `data` item includes `event`, `eventProperties`, `userProperties`, and `defaultProperties`.

## One-command demo E2E

With Xcode 26.5 and its iOS 26.5 simulator runtime installed, run from the repository root:

```sh
./tools/payload-recorder/run-ios-e2e.sh
```

The script starts this recorder and runs the demo's XCUITest suite on iPhone 17 Pro. CI runs the same command. It requires no account. Each run saves captures in a separate directory under `tools/payload-recorder/captures/`; the command prints its exact path.

## Capture

Run the recorder:

```sh
python3 tools/payload-recorder/server.py
# [recorder] listening on http://localhost:8765 -> captures/
```

Point the SDK at it with `OursPrivacyInitOptions(serverURL: "http://127.0.0.1:8765")`, then track and flush. `GET /captures` returns the captured envelopes as JSON for tests.

Each POST body is written as pretty-printed JSON to `captures/<timestamp>-<seq><path>.json`.

## Assert

Once you've captured a payload, diff it against a fixture:

```sh
python3 tools/payload-recorder/assert_payload.py captures/20260512T130045-0001_ingest.json fixtures/track_minimal.json
```

Exits 0 on match, 1 on mismatch. Volatile keys (`time`, `$time`, `timestamp`, `session_id`) are skipped.

## Fixtures

Add canonical-payload-shape fixtures to `fixtures/`. The plan is for these to eventually be exported from the server-side Zod schema and shared across the three SDK repos.
