#!/usr/bin/env bash
# Build the distributable FTransfer.app zip.
#
# The output is fully self-contained — universal (Apple Silicon + Intel), with
# cloudflared bundled inside — so a coworker needs no Homebrew, no Python, no
# Xcode Command Line Tools, and no admin rights to run it.
#
#   scripts/release.sh                 # latest cloudflared
#   CF_VERSION=2026.5.2 scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
VENDOR="clients/mac/vendor"
DIST="dist"
ASSET="$DIST/FTransfer-macos.zip"   # stable name: /releases/latest/download/ works
CF_VERSION="${CF_VERSION:-latest}"

command -v swiftc >/dev/null || { echo "error: swiftc not found (xcode-select --install)" >&2; exit 1; }

rm -rf "$VENDOR" "$DIST"
mkdir -p "$VENDOR" "$DIST"

# ---- 1. fetch cloudflared for both architectures, fuse into one binary ------
cf_url() { # arch
  if [ "$CF_VERSION" = "latest" ]; then
    echo "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$1.tgz"
  else
    echo "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-darwin-$1.tgz"
  fi
}

# Some corporate networks block release-assets.githubusercontent.com, so a
# failed arch is a warning, not a build failure: we bundle what we can get and
# say so. Set CF_ARM64/CF_AMD64 to pre-staged binaries to skip downloading.
slices=()
for pair in "arm64:CF_ARM64" "amd64:CF_AMD64"; do
  arch="${pair%%:*}"
  override="${pair##*:}"
  target="$VENDOR/cloudflared-$arch"

  if [ -n "${!override:-}" ] && [ -f "${!override}" ]; then
    cp "${!override}" "$target"
    echo "→ cloudflared ($arch): using ${!override}"
  elif curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
        "$(cf_url "$arch")" -o "$VENDOR/cf-$arch.tgz" 2>/dev/null; then
    tar -xzf "$VENDOR/cf-$arch.tgz" -C "$VENDOR"
    mv "$VENDOR/cloudflared" "$target"
    rm -f "$VENDOR/cf-$arch.tgz"
    echo "→ cloudflared ($arch): downloaded"
  else
    rm -f "$VENDOR/cf-$arch.tgz"
    # Last resort: an installed copy, but only for this machine's own arch.
    local_cf="$(command -v cloudflared || true)"
    want_macho="$([ "$arch" = "amd64" ] && echo x86_64 || echo arm64)"
    if [ -n "$local_cf" ] && lipo -archs "$local_cf" 2>/dev/null | tr ' ' '\n' | grep -qx "$want_macho"; then
      lipo "$local_cf" -thin "$want_macho" -output "$target" 2>/dev/null \
        || cp "$local_cf" "$target"
      echo "→ cloudflared ($arch): using local $local_cf"
    else
      echo "   warning: no cloudflared for $arch — release will not support it" >&2
      continue
    fi
  fi
  slices+=("$target")
done

[ ${#slices[@]} -gt 0 ] || { echo "error: no cloudflared binary available" >&2; exit 1; }
lipo -create "${slices[@]}" -output "$VENDOR/cloudflared"
chmod +x "$VENDOR/cloudflared"
rm -f "$VENDOR"/cloudflared-arm64 "$VENDOR"/cloudflared-amd64
CF_ARCHS="$(lipo -archs "$VENDOR/cloudflared")"
echo "   tunnel arch(es): $CF_ARCHS"

# Apache-2.0 requires the licence travel with the binary.
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
  "https://raw.githubusercontent.com/cloudflare/cloudflared/master/LICENSE" \
  -o "$VENDOR/cloudflared-LICENSE"

CF_ACTUAL="$("$VENDOR/cloudflared" --version 2>/dev/null | head -1 || echo "unknown")"
echo "   bundled: $CF_ACTUAL"

# ---- 2. build the universal app --------------------------------------------
echo "→ building universal app…"
clients/mac/build.sh --universal

APP="clients/mac/FTransfer.app"

# ---- 3. verify before shipping ----------------------------------------------
echo "→ verifying"
app_archs="$(lipo -archs "$APP/Contents/MacOS/FTransfer")"
case "$app_archs" in
  *arm64*x86_64*|*x86_64*arm64*) echo "   FTransfer: $app_archs" ;;
  *) echo "error: app binary is not universal (got: $app_archs)" >&2; exit 1 ;;
esac
echo "   cloudflared: $(lipo -archs "$APP/Contents/Resources/cloudflared")"
codesign --verify --deep --strict "$APP" \
  && echo "   code signature valid (ad-hoc)" \
  || { echo "error: signature verification failed" >&2; exit 1; }
plutil -lint "$APP/Contents/Info.plist" >/dev/null && echo "   Info.plist OK"

# Smoke-test the shipped binary: serve a temp folder, fetch a file back.
probe="$(mktemp -d)"
printf 'release smoke test' > "$probe/probe.txt"
FT_SERVE_ONLY=1 FT_PASSWORD=relpw "$APP/Contents/MacOS/FTransfer" "$probe" >"$probe/log" 2>&1 &
probe_pid=$!
port=""
for _ in $(seq 1 60); do
  port="$(grep -oE 'listening http://[0-9.]+:[0-9]+' "$probe/log" 2>/dev/null | grep -oE '[0-9]+$' || true)"
  [ -n "$port" ] && break
  sleep 0.1
done
got="$(curl -s -u u:relpw "http://127.0.0.1:${port:-0}/probe.txt" || true)"
kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true
rm -rf "$probe"
[ "$got" = "release smoke test" ] \
  && echo "   packaged server serves files OK" \
  || { echo "error: packaged app failed its smoke test (got: '$got')" >&2; exit 1; }

# ---- 4. package -------------------------------------------------------------
echo "→ packaging…"
# ditto is the Apple-sanctioned way to zip a bundle (keeps symlinks + xattrs).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ASSET"
SHA="$(shasum -a 256 "$ASSET" | awk '{print $1}')"
SIZE="$(du -h "$ASSET" | cut -f1)"

cat <<EOF

  ─────────────────────────────────────────────────────────
   FTransfer $VERSION packaged

   asset   $ASSET  ($SIZE)
   sha256  $SHA
   tunnel  $CF_ACTUAL
  ─────────────────────────────────────────────────────────

  Publish it with:
    gh release create v$VERSION "$ASSET" --title "FTransfer $VERSION" --notes-file docs/RELEASE_NOTES.md

EOF
