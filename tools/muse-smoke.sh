#!/usr/bin/env bash
# Smoke test for a deployed (or `wrangler dev`) proxy: get an install token, send one tiny text request
# through /v1/coach/responses, and print the reply. No keys are needed or stored here: the proxy holds them.
#
#   PROXY_URL=https://movement-tracker-proxy.<your-subdomain>.workers.dev tools/muse-smoke.sh
#   PROXY_URL=http://127.0.0.1:8787 tools/muse-smoke.sh
set -euo pipefail

: "${PROXY_URL:?Set PROXY_URL to the Worker URL, for example https://movement-tracker-proxy.<subdomain>.workers.dev}"
PROXY_URL="${PROXY_URL%/}"

for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

# curl wrapper: writes the response body to $body_file, prints nothing, returns the HTTP status.
status_of() {
  curl -sS --max-time 120 -o "$body_file" -w '%{http_code}' "$@"
}

fail() {
  echo "error: $1 (HTTP $2)" >&2
  # Proxy errors are JSON {"error":{"code","message"}} and never contain keys, so they are safe to show.
  head -c 600 "$body_file" >&2 || true
  echo >&2
  exit 1
}

echo "1/3 health"
status="$(status_of "$PROXY_URL/v1/health")"
[ "$status" = "200" ] || fail "health check failed" "$status"
cat "$body_file"; echo

echo "2/3 install token"
status="$(status_of -X POST "$PROXY_URL/v1/install")"
[ "$status" = "201" ] || fail "install failed" "$status"
token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <"$body_file")"
echo "token issued (${#token} characters, not printed)"

echo "3/3 coach request (set_review, effort minimal)"
request='{"input":"Reply with one short sentence confirming you can hear me.","reasoning":{"effort":"minimal"},"max_output_tokens":4000}'
# The token goes in through stdin (-H @-), not argv, so it never shows up in `ps` output.
status="$(status_of -X POST "$PROXY_URL/v1/coach/responses" \
  -H @- \
  -H "X-Coach-Feature: set_review" \
  -H "Content-Type: application/json" \
  --data "$request" <<<"Authorization: Bearer $token")"
[ "$status" = "200" ] || fail "coach request failed" "$status"

python3 - "$body_file" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    response = json.load(f)

parts = []
for item in response.get("output", []):
    if item.get("type") == "message":
        for part in item.get("content", []):
            if part.get("type") == "output_text":
                parts.append(part.get("text", ""))
reply = "".join(parts).strip()

usage = response.get("usage") or {}
print("model:", response.get("model", "?"), "| status:", response.get("status", "?"))
print("tokens: in", usage.get("input_tokens", "?"), "out", usage.get("output_tokens", "?"))
if not reply:
    print("error: the response had no output text", file=sys.stderr)
    print(json.dumps(response)[:600], file=sys.stderr)
    sys.exit(1)
print("reply:", reply)
PY
