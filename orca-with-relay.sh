#!/bin/sh
# Launch the Orca desktop app pointed at the self-hosted login + relay instead
# of Orca Cloud. Env vars only reach Orca if it is launched this way, so quit
# Orca first (it is single-instance). Launching Orca normally goes back to
# Orca Cloud; you then have to sign in again on whichever side you switch to.
set -eu
AUTH=https://auth-production-1cab.up.railway.app
RELAY=https://relay-production-faef.up.railway.app
if pgrep -f "Orca.app/Contents/MacOS/Orca" >/dev/null; then
  echo "Quit Orca first (Cmd+Q), then rerun." >&2; exit 1
fi
open -a Orca \
  --env ORCA_CLOUD_API_URL="$AUTH" \
  --env ORCA_CLOUD_CLIENT_ID=orca-desktop \
  --env ORCA_RELAY_URL="$RELAY"
echo "Orca launched against $RELAY"
echo "Sign-in password: security find-generic-password -s orca-relay -a owner -w"
