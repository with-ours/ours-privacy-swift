# Payload recorder

Tiny tools for capturing what the SDK posts to the ingest endpoint, and diffing those captures against a fixture file.

Used as a dogfood loop for verifying the SDK's wire shape against the ingest endpoint's expected envelope (`{eventName, eventProperties, userProperties, defaultProperties}`).

## Capture

Run the recorder:

```sh
python3 tools/payload-recorder/server.py
# [recorder] listening on http://localhost:8765 -> captures/
```

Point the demo app at it:

```swift
OursPrivacy.mainInstance().setServerURL("http://localhost:8765")
OursPrivacy.mainInstance().track(event: "Sign Up", properties: ["source": "test"])
OursPrivacy.mainInstance().flush()
```

Each POST body is written as pretty-printed JSON to `captures/<timestamp>-<seq><path>.json`.

## Assert

Once you've captured a payload, diff it against a fixture:

```sh
python3 tools/payload-recorder/assert_payload.py captures/20260512T130045-0001_ingest.json fixtures/track_minimal.json
```

Exits 0 on match, 1 on mismatch. Volatile keys (`time`, `$time`, `timestamp`, `session_id`) are skipped.

## Fixtures

Add canonical-payload-shape fixtures to `fixtures/`. The plan is for these to eventually be exported from the server-side Zod schema and shared across the three SDK repos.
