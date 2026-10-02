#!/usr/bin/env python3
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "OursPrivacy/Utilities/AutomaticProperties.swift"
PLIST = ROOT / "Info.plist"
XCODE_PROJECT = ROOT / "OursPrivacy.xcodeproj/project.pbxproj"


def main() -> int:
    source = SOURCE.read_text()
    match = re.search(r'^\s*static let sdkVersion = "(\d+\.\d+\.\d+)"\s*$', source, re.M)
    if match is None:
        print("SDK version declaration is missing or invalid", file=sys.stderr)
        return 1
    sdk_version = match.group(1)
    with PLIST.open("rb") as stream:
        plist_version = plistlib.load(stream)["CFBundleShortVersionString"]
    if sdk_version != plist_version:
        print(f"SDK version {sdk_version} does not match framework version {plist_version}", file=sys.stderr)
        return 1
    xcode_versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", XCODE_PROJECT.read_text()))
    if xcode_versions != {sdk_version}:
        print(f"Xcode framework versions {sorted(xcode_versions)} do not match SDK version {sdk_version}", file=sys.stderr)
        return 1
    if len(sys.argv) > 2:
        print("Usage: check-version.py [release-version]", file=sys.stderr)
        return 2
    if len(sys.argv) == 2 and sys.argv[1] != sdk_version:
        print(f"Release version {sys.argv[1]} does not match SDK version {sdk_version}", file=sys.stderr)
        return 1
    print(sdk_version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
