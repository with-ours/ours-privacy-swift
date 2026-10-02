#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

recorder_url="http://127.0.0.1:8765"
capture_root="$repo_root/tools/payload-recorder/captures"
run_dir="$(mktemp -d /tmp/ours-swift-e2e.XXXXXX)"
mkdir -p "$capture_root"
echo "Recorder capture root: $capture_root"
capture_dir="$(mktemp -d "$capture_root/run.XXXXXX")"

python3 tools/payload-recorder/server.py --port 8765 --out "$capture_dir" > "$run_dir/recorder.log" 2>&1 &
recorder_pid=$!
echo "Started recorder with PID $recorder_pid"
xcode_pid=""
cleanup() {
    if [[ -n "$xcode_pid" ]]; then
        kill "$xcode_pid" 2>/dev/null || true
        wait "$xcode_pid" 2>/dev/null || true
    fi
    kill "$recorder_pid" 2>/dev/null || true
    wait "$recorder_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ready=0
for attempt in {1..30}; do
    if ! kill -0 "$recorder_pid" 2>/dev/null; then
        echo "Recorder exited before becoming ready" >&2
        cat "$run_dir/recorder.log" >&2
        exit 1
    fi
    if grep -qF '[recorder] listening' "$run_dir/recorder.log" &&
        curl --noproxy "*" --max-time 2 --silent --fail "$recorder_url/captures" > /dev/null; then
        ready=1
        break
    fi
    sleep 1
done
if [[ "$ready" -ne 1 ]]; then
    echo "Recorder did not become ready after 30 seconds" >&2
    echo "Recorder process:" >&2
    ps -p "$recorder_pid" -o pid=,stat=,command= >&2 || true
    echo "Recorder log:" >&2
    cat "$run_dir/recorder.log" >&2
    echo "Recorder endpoint:" >&2
    curl --noproxy "*" --max-time 2 --show-error --fail "$recorder_url/captures" >&2 || true
    exit 1
fi
echo "Recorder ready at $recorder_url"

xcodebuild test \
    -project OursPrivacyiOSDemo/OursPrivacyiOSDemo.xcodeproj \
    -scheme OursPrivacyiOSDemo \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
    -parallel-testing-enabled NO \
    -derivedDataPath "$run_dir/derived-data" \
    -resultBundlePath "$run_dir/results.xcresult" \
    -only-testing:OursPrivacyiOSDemoUITests \
    CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS='-strict-concurrency=complete' \
    > "$run_dir/xcodebuild.log" 2>&1 &
xcode_pid=$!
if wait "$xcode_pid"; then
    xcode_pid=""
    grep -E 'TEST SUCCEEDED|Test Case.*passed' "$run_dir/xcodebuild.log" || true
    echo "Captures: $capture_dir"
    echo "Results: $run_dir/results.xcresult"
else
    result=$?
    xcode_pid=""
    tail -100 "$run_dir/xcodebuild.log"
    echo "Results: $run_dir/results.xcresult"
    exit "$result"
fi
