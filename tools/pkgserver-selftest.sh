#!/usr/bin/env bash
# Self-test for tools/pkgserver.py — runs the server on localhost with a
# throwaway self-signed certificate and checks serving, publishing, path
# safety and the ACME listener.  Needs python3, curl and openssl.
#
#   tools/pkgserver-selftest.sh
#
# Exits non-zero on the first failure summary; prints the server log on failure.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/pkgserver-selftest.XXXXXX")
PORT=18443
APORT=18080
TOKEN="selftest-token"
fails=0

ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2' want '$3'"; fi; }

cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; }
trap cleanup EXIT

mkdir -p "$T/repo" "$T/webroot"
python3 "$SRC/tools/cpkg.py" build "$SRC/pkg/hello" --repo "$T/repo" >/dev/null
python3 "$SRC/tools/cpkg.py" index "$T/repo" >/dev/null

mkdir -p "$T/demo/payload/bin"
printf 'name: demo\nversion: 1.0.0\narch: x86_64\ndescription: publish test\ndepends:\n' \
  > "$T/demo/manifest"
printf '#!/bin/sh\necho demo\n' > "$T/demo/payload/bin/demo"
chmod +x "$T/demo/payload/bin/demo"
python3 "$SRC/tools/cpkg.py" build "$T/demo" -o "$T/demo-1.0.0.cpkg" >/dev/null

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$T/key.pem" -out "$T/cert.pem" -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
printf '%s\n' "$TOKEN" > "$T/token"

python3 "$SRC/tools/pkgserver.py" --repo "$T/repo" --host 127.0.0.1 \
  --port "$PORT" --cert "$T/cert.pem" --key "$T/key.pem" \
  --publish-token-file "$T/token" --acme-port "$APORT" \
  --acme-webroot "$T/webroot" --domain pkg.test >"$T/server.log" 2>&1 &
SRV=$!

for _ in $(seq 1 40); do
  curl -sk -o /dev/null "https://127.0.0.1:$PORT/index" && break
  sleep 0.25
done

B="https://127.0.0.1:$PORT"
H="http://127.0.0.1:$APORT"
code() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }
auth=(-H "Authorization: Bearer $TOKEN")

echo "== serving =="
check "GET /index"            "$(code "$B/index")" 200
check "GET / listing"         "$(code "$B/")" 200
check "GET artifact"          "$(code "$B/hello-2.0.0.cpkg")" 200
check "GET missing"           "$(code "$B/nope-1.0.0.cpkg")" 404
check "GET /publish (405)"    "$(code "$B/publish/x.cpkg")" 405
curl -sk "$B/hello-2.0.0.cpkg" -o "$T/got.cpkg"
cmp -s "$T/got.cpkg" "$T/repo/hello-2.0.0.cpkg" && ok "artifact bytes identical" || bad "artifact bytes differ"
curl -sk "$B/" | grep -q "hello-2.0.0.cpkg" && ok "listing names the artifact" || bad "listing lacks the artifact"

echo "== path traversal =="
check "GET /../etc/passwd"    "$(code --path-as-is "$B/../etc/passwd")" 404
check "GET %2f encoded"       "$(code --path-as-is "$B/..%2f..%2fetc%2fpasswd")" 404
check "PUT ../ evil name"     "$(code --path-as-is -X PUT --data-binary @"$T/demo-1.0.0.cpkg" "${auth[@]}" "$B/publish/../evil.cpkg")" 400
check "PUT // absolute name"  "$(code -X PUT --data-binary @"$T/demo-1.0.0.cpkg" "${auth[@]}" "$B/publish//etc/evil.cpkg")" 400

echo "== publish auth =="
check "PUT no token"          "$(code -X PUT --data-binary @"$T/demo-1.0.0.cpkg" "$B/publish/demo-1.0.0.cpkg")" 401
check "PUT wrong token"       "$(code -X PUT --data-binary @"$T/demo-1.0.0.cpkg" -H "Authorization: Bearer nope" "$B/publish/demo-1.0.0.cpkg")" 401

echo "== publish =="
check "PUT valid"             "$(code -X PUT --data-binary @"$T/demo-1.0.0.cpkg" "${auth[@]}" "$B/publish/demo-1.0.0.cpkg")" 201
[ -f "$T/repo/demo-1.0.0.cpkg" ] && ok "artifact landed" || bad "artifact missing"
grep -q "demo	1.0.0	demo-1.0.0.cpkg" "$T/repo/index" && ok "index regenerated" || bad "index not regenerated"
check "PUT duplicate"         "$(code -X PUT --data-binary @"$T/demo-1.0.0.cpkg" "${auth[@]}" "$B/publish/demo-1.0.0.cpkg")" 409
check "PUT garbage body"      "$(code -X PUT --data-binary 'not a package' "${auth[@]}" "$B/publish/junk-1.0.0.cpkg")" 400
[ -f "$T/repo/junk-1.0.0.cpkg" ] && bad "garbage was stored" || ok "garbage rejected, not stored"
ls "$T/repo"/.upload-* >/dev/null 2>&1 && bad "temp upload left behind" || ok "no temp files left"
check "GET published"         "$(code "$B/demo-1.0.0.cpkg")" 200

echo "== acme / redirect =="
printf 'challenge-token-body' > "$T/webroot/tok123"
check "acme token"            "$(code "$H/.well-known/acme-challenge/tok123")" 200
check "acme missing"          "$(code "$H/.well-known/acme-challenge/nope")" 404
check "other path redirects"  "$(code "$H/anything")" 301
curl -s -o /dev/null -w '%{redirect_url}' "$H/anything" | grep -q "https://pkg.test/anything" \
  && ok "redirect target" || bad "redirect target wrong"
grep -q "Bad HTTP" "$T/server.log" && bad "stray request body on the wire" || ok "no stray-body misparse"

echo "== live certificate reload =="
kill -HUP "$SRV"; sleep 0.5
check "serving after SIGHUP"  "$(code "$B/index")" 200

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASSED"
else
  echo "$fails CHECK(S) FAILED   (log: $T/server.log)"
  tail -30 "$T/server.log"
fi
exit "$fails"
