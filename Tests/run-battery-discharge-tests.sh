#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
cat "$repo_root/Tests/BatteryDischargeTestSupport.swift" \
    "$repo_root/FreeAPS/Sources/Models/OrangeLinkBattery.swift" \
    "$repo_root/Tests/BatteryDischargeTrackerTests.swift" > "$test_dir/main.swift"
swift "$test_dir/main.swift" "$@"
