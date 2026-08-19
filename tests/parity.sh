#!/usr/bin/env bash
# The app ships a Swift port of server.py so it needs no Python at runtime.
# Two implementations means they can drift, so this diffs their actual HTTP
# responses over the same fixture tree and validates the Swift zip writer.
#
# Skips (exit 0) when the app hasn't been built — CI builds it first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BIN="clients/mac/FTransfer.app/Contents/MacOS/FTransfer"
if [ ! -x "$APP_BIN" ]; then
  echo "skip: $APP_BIN not built (run: make app)"
  exit 0
fi

TMP="$(mktemp -d)"
PY_PID=""; SW_PID=""
cleanup() {
  for pid in $PY_PID $SW_PID; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- fixture: names that stress escaping, unicode, spaces, nesting ----------
mkdir -p "$TMP/root/nested/deeper" "$TMP/root/empty dir" "$TMP/second"
printf 'hello world'  > "$TMP/root/plain.txt"
printf 'quote " and & and <b>'  > "$TMP/root/tricky & <name>.txt"
printf 'unicode'      > "$TMP/root/café ☕.md"
printf 'nested body'  > "$TMP/root/nested/inner.pdf"
printf 'deep'         > "$TMP/root/nested/deeper/deep.mov"
printf 'hidden'       > "$TMP/root/.hidden"
printf 'second root'  > "$TMP/second/two.txt"
# fixed mtimes so both servers render identical timestamps
find "$TMP" -exec touch -t 202601021530 {} +

wait_for_port() { # logfile -> port
  local log="$1" port=""
  for _ in $(seq 1 80); do
    port="$(grep -oE 'listening http://[0-9.]+:[0-9]+' "$log" 2>/dev/null \
            | grep -oE '[0-9]+$' || true)"
    [ -n "$port" ] && { echo "$port"; return 0; }
    sleep 0.1
  done
  return 1
}

start_pair() { # args: folders… -> sets PY_PORT / SW_PORT
  python3 server.py "$@" --port 0 --password pw >"$TMP/py.log" 2>&1 &
  PY_PID=$!
  FT_SERVE_ONLY=1 FT_PASSWORD=pw "$APP_BIN" "$@" >"$TMP/sw.log" 2>&1 &
  SW_PID=$!
  PY_PORT="$(wait_for_port "$TMP/py.log")" || { echo "FAIL: python server did not start"; cat "$TMP/py.log"; exit 1; }
  SW_PORT="$(wait_for_port "$TMP/sw.log")" || { echo "FAIL: swift server did not start";  cat "$TMP/sw.log"; exit 1; }
}

fail=0
check() { # desc want got
  if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi
}

# Both servers name the share after the folder, so the only legitimate
# difference between their HTML is nothing at all — compare byte for byte.
diff_page() { # url_path label
  local path="$1" label="$2"
  curl -s -u u:pw "http://127.0.0.1:$PY_PORT$path" > "$TMP/py.html"
  curl -s -u u:pw "http://127.0.0.1:$SW_PORT$path" > "$TMP/sw.html"
  if cmp -s "$TMP/py.html" "$TMP/sw.html"; then
    echo "ok:   html identical — $label"
  else
    echo "FAIL: html differs — $label"
    diff <(fold -w120 "$TMP/py.html") <(fold -w120 "$TMP/sw.html") | head -20 || true
    fail=1
  fi
}

zipnames() {
  python3 -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert z.testzip() is None, "bad CRC in archive"
print(" ".join(sorted(z.namelist())))' "$1"
}

echo "── single-folder share ──"
start_pair "$TMP/root"
diff_page "/"                 "listing root"
diff_page "/nested/"          "listing subfolder"
diff_page "/nested/deeper/"   "listing deep subfolder"
diff_page "/empty%20dir/"     "empty folder"

for path in "/plain.txt" "/tricky%20%26%20%3Cname%3E.txt" "/caf%C3%A9%20%E2%98%95.md"; do
  py="$(curl -s -u u:pw "http://127.0.0.1:$PY_PORT$path")"
  sw="$(curl -s -u u:pw "http://127.0.0.1:$SW_PORT$path")"
  check "file body matches — $path" "$py" "$sw"
done

for spec in "/plain.txt|0-4" "/plain.txt|-5" "/plain.txt|6-"; do
  path="${spec%|*}"; rng="${spec#*|}"
  py="$(curl -s -u u:pw -r "$rng" "http://127.0.0.1:$PY_PORT$path")"
  sw="$(curl -s -u u:pw -r "$rng" "http://127.0.0.1:$SW_PORT$path")"
  check "range $rng matches" "$py" "$sw"
done

status_of() { # port path want_auth extra_flag
  if [ "$3" = "auth" ]; then
    curl -s ${4:+"$4"} -u u:pw -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1$2"
  else
    curl -s ${4:+"$4"} -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1$2"
  fi
}

for probe in "/|401|noauth|" "/../server.py|404|auth|--path-as-is" "/.hidden|404|auth|" "/nested|301|auth|"; do
  IFS='|' read -r path want mode extra <<< "$probe"
  py="$(status_of "$PY_PORT" "$path" "$mode" "$extra")"
  sw="$(status_of "$SW_PORT" "$path" "$mode" "$extra")"
  check "status $path -> $want (py=$py sw=$sw)" "$want|$want" "$py|$sw"
done

echo "── zip archives ──"
curl -s -u u:pw -o "$TMP/py-all.zip" "http://127.0.0.1:$PY_PORT/?zip=1"
curl -s -u u:pw -o "$TMP/sw-all.zip" "http://127.0.0.1:$SW_PORT/?zip=1"
check "zip all: same entries" "$(zipnames "$TMP/py-all.zip")" "$(zipnames "$TMP/sw-all.zip")"
check "swift zip: unzip -t passes" "0" \
  "$(unzip -tqq "$TMP/sw-all.zip" >/dev/null 2>&1; echo $?)"
check "swift zip: file content intact" "hello world" \
  "$(python3 -c 'import sys,zipfile; print(zipfile.ZipFile(sys.argv[1]).read("plain.txt").decode())' "$TMP/sw-all.zip")"
check "swift zip: unicode name content" "unicode" \
  "$(python3 -c 'import sys,zipfile; print(zipfile.ZipFile(sys.argv[1]).read("café ☕.md").decode())' "$TMP/sw-all.zip")"

curl -s -u u:pw -o "$TMP/py-sel.zip" "http://127.0.0.1:$PY_PORT/?zip=1&files=plain.txt&files=nested"
curl -s -u u:pw -o "$TMP/sw-sel.zip" "http://127.0.0.1:$SW_PORT/?zip=1&files=plain.txt&files=nested"
check "zip selection: same entries" "$(zipnames "$TMP/py-sel.zip")" "$(zipnames "$TMP/sw-sel.zip")"

curl -s -u u:pw -o "$TMP/sw-bad.zip" "http://127.0.0.1:$SW_PORT/?zip=1&files=../server.py&files=.hidden&files=plain.txt"
check "swift zip: excludes traversal + dotfiles" "plain.txt" "$(zipnames "$TMP/sw-bad.zip")"

cleanup_pair() {
  kill "$PY_PID" "$SW_PID" 2>/dev/null || true
  wait "$PY_PID" "$SW_PID" 2>/dev/null || true
  PY_PID=""; SW_PID=""
}
cleanup_pair

echo "── multi-folder share ──"
start_pair "$TMP/root" "$TMP/second"
diff_page "/"        "multi-root index"
diff_page "/root/"   "first root listing"
diff_page "/second/" "second root listing"
curl -s -u u:pw -o "$TMP/py-multi.zip" "http://127.0.0.1:$PY_PORT/?zip=1"
curl -s -u u:pw -o "$TMP/sw-multi.zip" "http://127.0.0.1:$SW_PORT/?zip=1"
check "multi zip: same entries" "$(zipnames "$TMP/py-multi.zip")" "$(zipnames "$TMP/sw-multi.zip")"
curl -s -u u:pw -o "$TMP/sw-one.zip" "http://127.0.0.1:$SW_PORT/?zip=1&files=second"
check "multi zip: one root only" "second/two.txt" "$(zipnames "$TMP/sw-one.zip")"

if [ "$fail" = 0 ]; then echo "python and swift servers agree"; else exit 1; fi
