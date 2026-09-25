// Single-user stand-in for Orca Cloud's private login service, just enough for
// the desktop app to sign in and mint relay tokens for a self-hosted relay.
// Contract mirrors stablyai/orca src/main/orca-profiles/profile-cloud-client.ts
// (desktop side) and cloud/apps/relay/src/relay-token-verifier.ts (relay side).
// No dependencies: Node's crypto signs ES256 directly.
import { createHash, createPrivateKey, createPublicKey, randomBytes, sign, timingSafeEqual, verify } from 'node:crypto'
import { createServer } from 'node:http'

const env = (k, d) => {
  const v = process.env[k]?.trim() || d
  if (v === undefined) throw new Error(`${k} is required`)
  return v
}
const PASSWORD = env('AUTH_PASSWORD')
const PRIVATE_KEY = createPrivateKey(env('AUTH_SIGNING_KEY').replace(/\\n/g, '\n'))
const ISSUER = env('AUTH_ISSUER', process.env.RAILWAY_PUBLIC_DOMAIN ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}` : undefined)
const EMAIL = env('AUTH_EMAIL', 'owner@orca.local')
const PORT = Number(env('PORT', '8080'))

const PUBLIC_KEY = createPublicKey(PRIVATE_KEY)
const KID = createHash('sha256').update(PUBLIC_KEY.export({ type: 'spki', format: 'der' })).digest('base64url').slice(0, 16)
const JWKS = { keys: [{ ...PUBLIC_KEY.export({ format: 'jwk' }), kid: KID, alg: 'ES256', use: 'sig' }] }

const b64u = (v) => Buffer.from(typeof v === 'string' ? v : JSON.stringify(v)).toString('base64url')
function signJwt(claims, ttlSec) {
  const now = Math.floor(Date.now() / 1000)
  const body = `${b64u({ alg: 'ES256', typ: 'JWT', kid: KID })}.${b64u({ iss: ISSUER, iat: now, exp: now + ttlSec, ...claims })}`
  return `${body}.${sign('sha256', Buffer.from(body), { key: PRIVATE_KEY, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`
}
function verifyJwt(token, typ) {
  const [h, p, s] = String(token ?? '').split('.')
  if (!s) return null
  const ok = verify('sha256', Buffer.from(`${h}.${p}`), { key: PUBLIC_KEY, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url'))
  if (!ok) return null
  const claims = JSON.parse(Buffer.from(p, 'base64url'))
  return claims.typ === typ && claims.iss === ISSUER && claims.exp * 1000 > Date.now() ? claims : null
}

const ACCESS_TTL = 60 * 60
const REFRESH_TTL = 90 * 24 * 60 * 60
const RELAY_TTL = 15 * 60
const ORG = { orgId: 'personal', name: 'Personal', role: 'Owner' }
const cloud = () => ({ cloudProfileId: 'owner', userId: 'owner', email: EMAIL, displayName: 'Owner',
  activeOrgId: ORG.orgId, activeOrgName: ORG.name, linkedAt: Date.now() })
// Only relay.use: share/team would call Orca Cloud APIs this server does not have.
const account = () => ({ cloud: cloud(), organizations: [ORG], capabilities: { flags: { 'relay.use': true }, refreshedAt: Date.now() } })
const session = () => ({
  accessToken: signJwt({ sub: 'owner', typ: 'access' }, ACCESS_TTL),
  refreshToken: signJwt({ sub: 'owner', typ: 'refresh', jti: randomBytes(12).toString('base64url') }, REFRESH_TTL),
  expiresAt: Date.now() + ACCESS_TTL * 1000,
  ...account()
})

// Authorization codes: in memory, 5 minutes, single use.
const codes = new Map()
const LOOPBACK_CALLBACK = /^http:\/\/127\.0\.0\.1:\d{1,5}\/auth\/callback$/
const passwordOk = (given) => timingSafeEqual(
  createHash('sha256').update(String(given ?? '')).digest(), createHash('sha256').update(PASSWORD).digest())
let lastFailure = 0

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
function loginPage(params, error) {
  const hidden = [...params].map(([k, v]) => `<input type="hidden" name="${esc(k)}" value="${esc(v)}">`).join('')
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Orca relay sign-in</title>
<style>body{font:16px system-ui;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0}
form{display:grid;gap:12px;width:280px}input,button{font:inherit;padding:10px;border-radius:8px;border:1px solid #444;background:#1c1c1c;color:#eee}
button{background:#eee;color:#111;cursor:pointer}p{color:#f77;margin:0}</style>
<form method="post">${hidden}<h2>Orca relay</h2>${error ? `<p>${esc(error)}</p>` : ''}
<input type="password" name="password" placeholder="Password" autofocus required><button>Sign in</button></form>`
}

async function readBody(req) {
  let raw = ''
  for await (const chunk of req) {
    raw += chunk
    if (raw.length > 64 * 1024) throw new Error('body too large')
  }
  return raw
}
const bearer = (req) => /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1]

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x')
  const send = (status, body, type = 'application/json') => {
    res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' })
    res.end(type === 'application/json' ? JSON.stringify(body) : body)
  }
  try {
    const path = url.pathname
    if (path === '/health') return send(200, { ok: true })
    if (path === '/.well-known/jwks.json') return send(200, JWKS)

    if (path === '/v1/desktop/auth/authorize') {
      const params = req.method === 'POST' ? new URLSearchParams(await readBody(req)) : url.searchParams
      const redirect = params.get('redirect_uri') ?? ''
      // Only the desktop's own loopback listener may receive a code.
      if (params.get('response_type') !== 'code' || !LOOPBACK_CALLBACK.test(redirect) ||
          params.get('code_challenge_method') !== 'S256' || !params.get('code_challenge') || !params.get('state')) {
        return send(400, 'Invalid sign-in request.', 'text/plain')
      }
      if (req.method !== 'POST') return send(200, loginPage(params), 'text/html; charset=utf-8')
      const password = params.get('password')
      params.delete('password')
      if (Date.now() - lastFailure < 2000 || !passwordOk(password)) {
        lastFailure = Date.now()
        return send(401, loginPage(params, 'Wrong password.'), 'text/html; charset=utf-8')
      }
      const code = randomBytes(32).toString('base64url')
      codes.set(code, { challenge: params.get('code_challenge'), redirect, exp: Date.now() + 5 * 60_000 })
      const to = new URL(redirect)
      to.searchParams.set('code', code)
      to.searchParams.set('state', params.get('state'))
      res.writeHead(302, { location: to.toString() })
      return res.end()
    }

    if (req.method !== 'POST' || !path.startsWith('/v1/desktop/auth/')) return send(404, { error: 'not_found' })
    const body = JSON.parse((await readBody(req)) || '{}')
    const op = path.slice('/v1/desktop/auth/'.length)

    if (op === 'session') {
      const entry = codes.get(body.code)
      codes.delete(body.code)
      const challenge = createHash('sha256').update(String(body.codeVerifier ?? '')).digest('base64url')
      if (!entry || entry.exp < Date.now() || entry.redirect !== body.redirectUri || entry.challenge !== challenge) {
        return send(400, { error: 'invalid_grant' })
      }
      return send(200, session())
    }
    if (op === 'refresh') {
      return verifyJwt(body.refreshToken, 'refresh') ? send(200, session()) : send(401, { error: 'invalid_grant' })
    }
    if (op === 'logout') return send(200, {})

    if (!verifyJwt(bearer(req), 'access')) return send(401, { error: 'unauthorized' })
    if (op === 'capabilities' || op === 'org') return send(200, account())
    if (op === 'profile') return send(200, session())
    if (op === 'relay-token') {
      const pub = Buffer.from(String(body.hostPublicKeyB64 ?? ''), 'base64')
      const relayHostId = String(body.relayHostId ?? '')
      if (pub.length !== 32 || createHash('sha256').update(pub).digest('base64url').slice(0, 16) !== relayHostId) {
        return send(400, { error: 'invalid_host' })
      }
      return send(200, {
        relayToken: signJwt({ sub: 'owner', prof: 'owner', org: ORG.orgId, aud: 'orca-relay', purpose: 'host-control', relayHostId }, RELAY_TTL),
        expiresAt: Date.now() + RELAY_TTL * 1000
      })
    }
    return send(404, { error: 'not_found' })
  } catch (error) {
    console.error('[orca-auth]', error.message)
    if (!res.headersSent) send(400, { error: 'bad_request' })
  }
})
server.listen(PORT, '::', () => console.log(`[orca-auth] listening on ${PORT}, issuer ${ISSUER}, kid ${KID}`))
