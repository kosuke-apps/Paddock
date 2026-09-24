#!/bin/bash
# Builds and runs the tests. They use a fake `ollama` on ports 11490-11499, never the real server or port 11434.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TARGET="arm64-apple-macos26.0"
mkdir -p build/tests/bin

xcrun swift-format lint --strict -r Sources tests tools
xcrun swiftc -swift-version 6 -target "$TARGET" -o build/tests/bin/ollama tests/support/fake-ollama.swift
xcrun swiftc -swift-version 6 -target "$TARGET" -o build/tests/paddock-tests Sources/Core/*.swift tests/*.swift

status=0
build/tests/paddock-tests "$PWD/build/tests/bin/ollama" || status=$?
# The tests' defaults suites are emptied by the tests; remove the files the preferences daemon leaves behind.
rm -f "$HOME/Library/Preferences/paddock.tests."*.plist
exit "$status"
