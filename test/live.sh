#!/bin/sh
# Live check against the deployed services: desktop PKCE sign-in with the real
# password, then upstream's relay splice smoke using the minted token.
# Runs inside the local relay image (it carries ws/tweetnacl/relay-contract).
# Usage: test/live.sh <auth-origin> <relay-origin>
set -eu
AUTH="$1" RELAY="$2"
PW="$(security find-generic-password -s orca-relay -a owner -w)"
cd "$(dirname "$0")"
docker run --rm -i -e AUTH="$AUTH" -e RELAY="$RELAY" -e PW="$PW" \
  -v "$PWD/smoke-relay.mjs:/app/dev/scripts/smoke-relay.mjs:ro" --entrypoint sh orca-relay:local -eu <<'EOF'
cd /app
TOKEN=$(node --input-type=module -e '
import { createHash, randomBytes } from "node:crypto"
const { AUTH, PW } = process.env
const ver = randomBytes(32).toString("base64url")
const q = new URLSearchParams({ response_type: "code", client_id: "orca-desktop",
  redirect_uri: "http://127.0.0.1:5555/auth/callback", code_challenge_method: "S256", state: "s",
  code_challenge: createHash("sha256").update(ver).digest("base64url"), nonce: "n" })
const page = await (await fetch(`${AUTH}/v1/desktop/auth/authorize?${q}`)).text()
if (!page.includes("type=\"password\"")) throw new Error("no login page")
q.set("password", PW)
const r = await fetch(`${AUTH}/v1/desktop/auth/authorize`, { method: "POST", body: q, redirect: "manual" })
const code = new URL(r.headers.get("location")).searchParams.get("code")
const s = await (await fetch(`${AUTH}/v1/desktop/auth/session`, { method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ code, codeVerifier: ver, redirectUri: q.get("redirect_uri") }) })).json()
if (s.capabilities?.flags?.["relay.use"] !== true) throw new Error("no relay.use")
console.log(s.accessToken)')
echo "live sign-in OK"
ORCA_RELAY_SMOKE_AUTH_URL="$AUTH" ORCA_RELAY_SMOKE_ACCESS_TOKEN="$TOKEN" node dev/scripts/smoke-relay.mjs "$RELAY"
EOF
