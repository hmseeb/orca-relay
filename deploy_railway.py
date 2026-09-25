#!/usr/bin/env python3
"""Provision the self-hosted Orca relay on Railway (My Projects): an `auth`
service (login shim) and a `relay` service (upstream relay, SQLite on a volume).
Secrets are generated here; the password also goes into the macOS Keychain
(service "orca-relay").  Idempotence: run once."""
import pathlib, secrets, subprocess, sys
sys.path.insert(0, str(pathlib.Path("~/.claude/skills/create-template-for-railway/scripts").expanduser()))
import rw  # noqa: E402

WORKSPACE = "d10da65a-297f-4ba4-8cef-2fa9bb45fdef"  # My Projects
q = rw.gql

password = secrets.token_urlsafe(18)
key = subprocess.run("openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt",
                     shell=True, check=True, capture_output=True, text=True).stdout
subprocess.run(["security", "add-generic-password", "-U", "-s", "orca-relay", "-a", "owner", "-w", password], check=True)

p = q("""mutation($input: ProjectCreateInput!) { projectCreate(input: $input) {
  id environments { edges { node { id name } } } } }""", {"input": {"name": "orca-relay", "workspaceId": WORKSPACE}})["projectCreate"]
pid = p["id"]
env = next(e["node"]["id"] for e in p["environments"]["edges"] if e["node"]["name"] == "production")


def service(name, image, variables, health, port):
    sid = q("""mutation($input: ServiceCreateInput!) { serviceCreate(input: $input) { id } }""",
            {"input": {"projectId": pid, "environmentId": env, "name": name, "source": {"image": image},
                       "variables": variables}})["serviceCreate"]["id"]
    q("""mutation($s: String!, $e: String!, $input: ServiceInstanceUpdateInput!) {
      serviceInstanceUpdate(serviceId: $s, environmentId: $e, input: $input) }""",
      {"s": sid, "e": env, "input": {"healthcheckPath": health, "healthcheckTimeout": 120,
                                     "restartPolicyType": "ON_FAILURE", "restartPolicyMaxRetries": 10}})
    domain = q("""mutation($input: ServiceDomainCreateInput!) { serviceDomainCreate(input: $input) { domain } }""",
               {"input": {"environmentId": env, "serviceId": sid, "targetPort": port}})["serviceDomainCreate"]["domain"]
    return sid, domain


auth, auth_domain = service("auth", "ghcr.io/hmseeb/orca-auth:latest", {
    "PORT": "8080", "AUTH_PASSWORD": password, "AUTH_SIGNING_KEY": key,
    "AUTH_ISSUER": "https://${{RAILWAY_PUBLIC_DOMAIN}}",
}, "/health", 8080)
relay, relay_domain = service("relay", "ghcr.io/hmseeb/orca-relay:latest", {
    "PORT": "8080",
    "ORCA_RELAY_PUBLIC_URL": "https://${{RAILWAY_PUBLIC_DOMAIN}}",
    "ORCA_RELAY_CELL_URL": "https://${{RAILWAY_PUBLIC_DOMAIN}}",
    "ORCA_RELAY_AUTH_ISSUER": "https://${{auth.RAILWAY_PUBLIC_DOMAIN}}",
    "ORCA_RELAY_JWKS_URL": "https://${{auth.RAILWAY_PUBLIC_DOMAIN}}/.well-known/jwks.json",
    "ORCA_RELAY_ASSIGNMENT_SIGNING_KEY": secrets.token_hex(32),
    # Admin routes verify Google-issued tokens for these; placeholders make them unusable.
    "ORCA_RELAY_ADMIN_AUDIENCE": "https://admin.invalid",
    "ORCA_RELAY_DEPLOY_SERVICE_ACCOUNT": "nobody@invalid.example",
}, "/health", 8080)
q("""mutation($input: VolumeCreateInput!) { volumeCreate(input: $input) { id } }""",
  {"input": {"projectId": pid, "environmentId": env, "serviceId": relay, "mountPath": "/data"}})

# Fresh deploys now that both domains exist (references resolve at deploy time).
for sid in (auth, relay):
    q("""mutation($s: String!, $e: String!) { serviceInstanceDeployV2(serviceId: $s, environmentId: $e) }""",
      {"s": sid, "e": env})
print(f"PROJECT={pid}\nENV={env}\nAUTH={auth}\nRELAY={relay}\nAUTH_URL=https://{auth_domain}\nRELAY_URL=https://{relay_domain}")
