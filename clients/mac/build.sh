#!/usr/bin/env bash
# Build FTransfer.app — the ftransfer menu bar app.
# Requires the Xcode Command Line Tools (swiftc). Produces an unsigned,
# locally-runnable app bundle; run it with:  open FTransfer.app
set -euo pipefail
cd "$(dirname "$0")"

APP="FTransfer.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp ../../server.py "$APP/Contents/Resources/server.py"

swiftc -O \
  -target "$ARCH-apple-macos12.0" \
  -framework AppKit -framework CoreImage \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/FTransfer"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built clients/mac/$APP — run it with:  open clients/mac/$APP"
