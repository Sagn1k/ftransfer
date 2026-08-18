#!/usr/bin/env bash
# Smoke tests for server.py: auth, listing, downloads, ranges, traversal.
# No dependencies beyond python3 + curl. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
PID=""
trap '[ -n "$PID" ] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; } || true; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/sub"
printf 'hello world' > "$TMP/root/a.txt"
touch "$TMP/root/.secret"

python3 server.py "$TMP/root" --port 0 --password pw >"$TMP/log" 2>&1 &
PID=$!

PORT=""
for _ in $(seq 1 50); do
  PORT="$(grep -oE 'listening http://[0-9.]+:[0-9]+' "$TMP/log" 2>/dev/null | grep -oE '[0-9]+$' || true)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "FAIL: server did not start"; cat "$TMP/log"; exit 1
fi
BASE="http://127.0.0.1:$PORT"

fail=0
check() { # desc want got
  if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi
}

check "no auth -> 401"        401 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")"
check "wrong password -> 401" 401 "$(curl -s -u u:bad -o /dev/null -w '%{http_code}' "$BASE/")"
check "listing -> 200"        200 "$(curl -s -u u:pw -o /dev/null -w '%{http_code}' "$BASE/")"
check "listing shows file"    a.txt "$(curl -s -u u:pw "$BASE/" | grep -o 'a.txt' | head -1)"
check "file body roundtrip"   "hello world" "$(curl -s -u u:pw "$BASE/a.txt")"
check "range -> 206"          206 "$(curl -s -u u:pw -r 0-4 -o /dev/null -w '%{http_code}' "$BASE/a.txt")"
check "range body"            hello "$(curl -s -u u:pw -r 0-4 "$BASE/a.txt")"
check "suffix range body"     world "$(curl -s -u u:pw -r -5 "$BASE/a.txt")"
check "traversal -> 404"      404 "$(curl -s --path-as-is -u u:pw -o /dev/null -w '%{http_code}' "$BASE/../server.py")"
check "dotfile -> 404"        404 "$(curl -s -u u:pw -o /dev/null -w '%{http_code}' "$BASE/.secret")"
check "dotfile hidden in listing" "" "$(curl -s -u u:pw "$BASE/" | grep -o '.secret' | head -1)"
check "dir redirect -> 301"   301 "$(curl -s -u u:pw -o /dev/null -w '%{http_code}' "$BASE/sub")"
check "download disposition"  1 "$(curl -s -u u:pw -D- -o /dev/null "$BASE/a.txt?dl=1" | grep -ci 'content-disposition: attachment')"
check "HEAD -> 200, no body"  "200 " "$(curl -s -I -u u:pw -o /dev/null -w '%{http_code} %{size_download}' "$BASE/a.txt" | sed 's/0$//')"

if [ "$fail" = 0 ]; then echo "all smoke tests passed"; else exit 1; fi
