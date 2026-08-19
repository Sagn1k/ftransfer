#!/usr/bin/env bash
# Build FTransfer.app — the ftransfer menu bar app.
#
#   ./build.sh              native arch, for development
#   ./build.sh --universal  arm64 + x86_64, for distribution
#
# If clients/mac/vendor/cloudflared exists it is bundled into the app, which
# is what makes release builds self-contained (see scripts/release.sh).
# Requires the Xcode Command Line Tools (swiftc) on the *building* machine
# only — the resulting app needs nothing installed on the machines that run it.
set -euo pipefail
cd "$(dirname "$0")"

APP="FTransfer.app"
SOURCES=(Sources/main.swift Sources/FileServer.swift Sources/Zip.swift)
FRAMEWORKS=(-framework AppKit -framework CoreImage -framework Network)
DEPLOY_TARGET="12.0"

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp Info.plist "$APP/Contents/"

if [ "${1:-}" = "--universal" ]; then
  for arch in arm64 x86_64; do
    echo "  compiling ${arch}"
    swiftc -O -target "${arch}-apple-macos${DEPLOY_TARGET}" "${FRAMEWORKS[@]}" \
      "${SOURCES[@]}" -o "build/FTransfer-${arch}"
  done
  lipo -create build/FTransfer-arm64 build/FTransfer-x86_64 \
    -output "$APP/Contents/MacOS/FTransfer"
else
  swiftc -O -target "$(uname -m)-apple-macos$DEPLOY_TARGET" "${FRAMEWORKS[@]}" \
    "${SOURCES[@]}" -o "$APP/Contents/MacOS/FTransfer"
fi

if [ -f vendor/cloudflared ]; then
  cp vendor/cloudflared "$APP/Contents/Resources/cloudflared"
  chmod +x "$APP/Contents/Resources/cloudflared"
  # Sign nested code before the bundle, or the outer seal won't validate.
  codesign --force --sign - "$APP/Contents/Resources/cloudflared" >/dev/null 2>&1 || true
  echo "  bundled cloudflared ($(du -h vendor/cloudflared | cut -f1))"
fi
[ -f vendor/cloudflared-LICENSE ] && \
  cp vendor/cloudflared-LICENSE "$APP/Contents/Resources/cloudflared-LICENSE"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
rm -rf build

echo "Built clients/mac/$APP — run it with:  open clients/mac/$APP"
