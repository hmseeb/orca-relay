#!/bin/sh
# Local end-to-end: auth + relay containers sharing one network namespace,
# the desktop's PKCE sign-in done with curl, then upstream's relay smoke test
# (host control -> invite -> fake phone -> binary+text splice) with that token.
# Usage: test/e2e.sh   (needs images orca-auth:local and orca-relay:local)
set -eu
cd "$(dirname "$0")"
A=orca-e2e-auth R=orca-e2e-relay
trap 'docker rm -f $A $R >/dev/null 2>&1' EXIT
docker rm -f $A $R >/dev/null 2>&1 || true

KEY="$(openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt)"
docker run -d --name $A -e PORT=8081 -e AUTH_PASSWORD=pw-e2e -e AUTH_ISSUER=http://127.0.0.1:8081 \
  -e AUTH_SIGNING_KEY="$KEY" orca-auth:local >/dev/null
docker run -d --name $R --network container:$A -e NODE_ENV=development \
  -e ORCA_RELAY_PUBLIC_URL=http://127.0.0.1:8080 -e ORCA_RELAY_CELL_URL=http://127.0.0.1:8080 \
  -e ORCA_RELAY_AUTH_ISSUER=http://127.0.0.1:8081 -e ORCA_RELAY_JWKS_URL=http://127.0.0.1:8081/.well-known/jwks.json \
  -e ORCA_RELAY_ASSIGNMENT_SIGNING_KEY="$(openssl rand -hex 32)" \
  -e ORCA_RELAY_ADMIN_AUDIENCE=https://admin.invalid -e ORCA_RELAY_DEPLOY_SERVICE_ACCOUNT=nobody@invalid.example \
  orca-relay:local >/dev/null
sleep 4
x() { docker exec $R "$@"; }
# h METHOD URL [BODY] [BEARER] [CTYPE] -> "status location" line, then the body
h() { x node -e 'const [m,u,b,t,ct]=process.argv.slice(1);fetch(u,{method:m,redirect:"manual",body:b||undefined,
  headers:{...(b?{"content-type":ct||"application/json"}:{}),...(t?{authorization:"Bearer "+t}:{})}})
  .then(async r=>console.log(r.status+" "+(r.headers.get("location")||"-")+"\n"+await r.text()))' "$@"; }
status() { head -1 | cut -d" " -f1; }

# --- desktop sign-in, step by step ---
VER=verifier-$(openssl rand -hex 16)
CH=$(printf %s "$VER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
CB=http://127.0.0.1:5555/auth/callback
Q="response_type=code&client_id=orca-desktop&redirect_uri=$CB&code_challenge=$CH&code_challenge_method=S256&state=st1&nonce=n1"
h GET "http://127.0.0.1:8081/v1/desktop/auth/authorize?$Q" | grep -q 'type="password"' || { echo "FAIL login page"; exit 1; }
[ "$(h GET "http://127.0.0.1:8081/v1/desktop/auth/authorize?$(echo "$Q" | sed 's#redirect_uri=[^&]*#redirect_uri=https://evil.example/cb#')" | status)" = 400 ] \
  || { echo "FAIL non-loopback redirect accepted"; exit 1; }
[ "$(h POST http://127.0.0.1:8081/v1/desktop/auth/authorize "$Q&password=wrong" "" application/x-www-form-urlencoded | status)" = 401 ] \
  || { echo "FAIL wrong password accepted"; exit 1; }
sleep 2.1
LOC=$(h POST http://127.0.0.1:8081/v1/desktop/auth/authorize "$Q&password=pw-e2e" "" application/x-www-form-urlencoded | head -1 | cut -d" " -f2)
case "$LOC" in "$CB?code="*"&state=st1") ;; *) echo "FAIL redirect: $LOC"; exit 1;; esac
CODE=$(echo "$LOC" | sed 's/.*code=\([^&]*\).*/\1/')
post() { r=$(h POST "http://127.0.0.1:8081/v1/desktop/auth/$1" "$2" "${3:-}"); [ "$(echo "$r" | status)" = 200 ] || return 1; echo "$r" | tail -n +2; }
post session "{\"code\":\"$CODE\",\"codeVerifier\":\"wrong\",\"redirectUri\":\"$CB\"}" 2>/dev/null && { echo "FAIL bad PKCE accepted"; exit 1; }
# the failed attempt burned the code (single use), so sign in again
LOC=$(h POST http://127.0.0.1:8081/v1/desktop/auth/authorize "$Q&password=pw-e2e" "" application/x-www-form-urlencoded | head -1 | cut -d" " -f2)
CODE=$(echo "$LOC" | sed 's/.*code=\([^&]*\).*/\1/')
S=$(post session "{\"code\":\"$CODE\",\"codeVerifier\":\"$VER\",\"redirectUri\":\"$CB\"}")
ACCESS=$(echo "$S" | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
REFRESH=$(echo "$S" | sed 's/.*"refreshToken":"\([^"]*\)".*/\1/')
echo "$S" | grep -q '"relay.use":true' || { echo "FAIL session lacks relay.use: $S"; exit 1; }
post capabilities '{}' "$ACCESS" | grep -q '"relay.use":true' || { echo "FAIL capabilities"; exit 1; }
post refresh "{\"refreshToken\":\"$REFRESH\"}" | grep -q accessToken || { echo "FAIL refresh"; exit 1; }
post relay-token '{"relayHostId":"AAAAAAAAAAAAAAAA","hostPublicKeyB64":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' "$ACCESS" 2>/dev/null \
  && { echo "FAIL relay-token accepted mismatched host id"; exit 1; }
echo "sign-in flow OK"

# --- relay data plane, upstream's own smoke ---
docker cp smoke-relay.mjs $R:/app/smoke-relay.mjs
x sh -c "mkdir -p /app/dev/scripts && cp /app/smoke-relay.mjs /app/dev/scripts/ && \
  ORCA_RELAY_SMOKE_AUTH_URL=http://127.0.0.1:8081 ORCA_RELAY_SMOKE_ACCESS_TOKEN=$ACCESS \
  node /app/dev/scripts/smoke-relay.mjs http://127.0.0.1:8080"
echo PASS
