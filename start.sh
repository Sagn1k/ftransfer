#!/usr/bin/env bash
# ftransfer — share folders to your phone via a Cloudflare quick tunnel.
#
# Usage:
#   ./start.sh                        # shares ./shared (created if missing)
#   ./start.sh ~/Downloads            # shares another folder
#   ./start.sh ~/Downloads ~/Desktop  # shares several folders
#   PORT=9000 FT_PASSWORD=mypass ./start.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -eq 0 ]; then
  mkdir -p "$PWD/shared"
  set -- "$PWD/shared"
fi
PORT="${PORT:-8420}"
# http2 (TCP) instead of quic (UDP): corporate networks often drop UDP 7844.
CF_PROTOCOL="${CF_PROTOCOL:-http2}"
PASSWORD="${FT_PASSWORD:-$(python3 -c 'import secrets; print("".join(secrets.choice("abcdefghjkmnpqrstuvwxyz23456789") for _ in range(10)))')}"

CF_BIN="$(command -v cloudflared || true)"
[ -z "$CF_BIN" ] && [ -x "./cloudflared" ] && CF_BIN="./cloudflared"
if [ -z "$CF_BIN" ]; then
  echo "error: cloudflared not found. Install it with:  brew install cloudflared" >&2
  exit 1
fi

CF_LOG="$(mktemp -t ftransfer-cloudflared)"
python3 server.py "$@" --port "$PORT" --password "$PASSWORD" &
SERVER_PID=$!
"$CF_BIN" tunnel --url "http://127.0.0.1:$PORT" --protocol "$CF_PROTOCOL" --no-autoupdate >"$CF_LOG" 2>&1 &
CF_PID=$!

cleanup() { kill "$SERVER_PID" "$CF_PID" 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# Wait for the tunnel URL to show up in cloudflared's log.
URL=""
for _ in $(seq 1 80); do
  kill -0 "$CF_PID" 2>/dev/null || break
  URL="$(grep -Eom1 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" || true)"
  [ -n "$URL" ] && break
  sleep 0.25
done

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "error: local server failed to start (is port $PORT in use?)" >&2
  exit 1
fi
if [ -z "$URL" ]; then
  echo "error: could not get a trycloudflare.com URL. cloudflared log:" >&2
  tail -n 20 "$CF_LOG" >&2
  exit 1
fi

echo
echo "  ─────────────────────────────────────────────────────"
echo "   ftransfer is live"
echo
echo "   URL       $URL"
echo "   Username  files   (anything works)"
echo "   Password  $PASSWORD"
echo "   Folders   $*"
echo "  ─────────────────────────────────────────────────────"
echo
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 -m 2 "$URL"
  echo
fi
echo "  Open the URL on your phone, sign in, tap ↓ to download."
echo "  Press Ctrl+C to stop sharing."
echo

wait "$SERVER_PID" "$CF_PID"
