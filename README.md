# Self-hosted Orca relay

Runs [Orca](https://github.com/stablyai/orca)'s phone-to-desktop relay on your own Railway project instead of Stably's `relay.onorca.dev`.

Orca's desktop app will only use a relay after an Orca Cloud sign-in, and the relay only accepts tokens signed by that sign-in service. The relay code is public (`cloud/apps/relay`, MIT), but the sign-in service is private. So this repo has two parts:

| Service | What it is |
|---|---|
| `relay/` | Upstream's relay, built unmodified from a pinned Orca commit. Runs in `combined` mode (director and cell in one process) with SQLite on a volume. |
| `auth/` | `server.mjs`, a small single-user stand-in for Orca Cloud sign-in with no dependencies: a password page, PKCE code exchange, access and refresh tokens, and ES256 relay tokens in exactly the format the relay verifies. |

## Live deployment

- Railway project `orca-relay` (My Projects): `2df8c8d3-1d29-42aa-b444-ac88481182a2`
- Auth: https://auth-production-1cab.up.railway.app
- Relay: https://relay-production-faef.up.railway.app
- Password: `security find-generic-password -s orca-relay -a owner -w`

## Use it

1. Quit Orca (Cmd+Q).
2. `./orca-with-relay.sh`, which relaunches Orca with `ORCA_CLOUD_API_URL`, `ORCA_CLOUD_CLIENT_ID` and `ORCA_RELAY_URL` pointing here.
3. In Orca, sign in to Orca Cloud. Your browser opens the relay's password page; sign in.
4. Pair your phone from Orca Mobile as usual. The pairing QR carries this relay's address, so the phone needs no configuration.

Launching Orca the normal way (Dock, Spotlight) goes back to Stably's Orca Cloud. Each switch needs a fresh sign-in, because each side rejects the other's tokens.

## What works and what does not

- Relay (`relay.use`) is the only capability the login service grants. Sharing and teams call Orca Cloud APIs that this does not implement, so they stay off.
- Mobile push notifications still go through Stably's `push.onorca.dev`. That gateway authenticates with the host's own key, not the Orca Cloud sign-in, so it keeps working.
- There is one user and one password. Sign-in codes live in memory, so restarting the auth service cancels a half-finished sign-in and nothing else. Tokens stay valid across restarts because the signing key is a variable.
- This relies on undocumented internal interfaces between Orca's desktop app and its cloud. An Orca update can break it. `test/e2e.sh` is the canary.

## Tests

```sh
docker build -t orca-auth:local auth && docker build -t orca-relay:local relay
./test/e2e.sh    # local: full sign-in flow + upstream's relay splice smoke
./test/live.sh https://auth-production-1cab.up.railway.app https://relay-production-faef.up.railway.app
```

`test/smoke-relay.mjs` is upstream's `cloud/dev/scripts/smoke-relay.mjs`, unchanged. It acts as both a host and a phone: host control, invite, phone connect, then a binary and text round trip through the relay. CI runs `e2e.sh` before pushing images to GHCR.

## Security notes

- The auth service only issues sign-in codes to `http://127.0.0.1:<port>/auth/callback`, the desktop app's own loopback listener. Codes are single use, expire after 5 minutes, and are bound to a PKCE challenge.
- Relay tokens are bound to a host id derived from the host's public key and expire after 15 minutes. The relay then proves that the host holds the private key.
- Wrong passwords are rate limited to one try every 2 seconds.
- The relay's admin routes verify Google-issued identity tokens against placeholder audiences, so nobody can use them.
- Traffic through the relay is end-to-end encrypted between the phone and the desktop. The relay only forwards it.
