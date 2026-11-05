# Smartoys Deployment Infrastructure — LLM Instructions

You are an AI assistant helping deploy containerized projects to the Smartoys
infrastructure. This document gives you everything you need to deploy a new
project from scratch: what files to create, what values to use, what the
operator needs to do manually, and how to verify success.

---

## Architecture overview

```
GitHub repo (any project)
  └── push to main
        └── GitHub Actions (.github/workflows/deploy.yml)
              └── calls Smartoys/devops reusable workflow
                    ├── builds Docker image → pushes to ghcr.io/smartoys/<app>
                    ├── Cloudflare API → adds tunnel ingress rule
                    ├── Cloudflare API → creates/updates DNS CNAME record
                    └── SSHs via Tailscale → deploy user → run.sh on server
                              └── docker compose up on dockerone VM
                                    └── Traefik picks up labels → routes traffic
```

**Key facts:**
- GitHub org: `Smartoys` (github.com/Smartoys)
- Devops repo: `Smartoys/devops`
- Reusable workflow: `Smartoys/devops/.github/workflows/reusable-deploy.yml@main`
- GHCR prefix: `ghcr.io/smartoys/<app>` (always lowercase)
- Deployment server: `dockerone` — Ubuntu VM behind NAT
- Traefik entrypoint: `web` (port 80, HTTP only — Cloudflare handles TLS)
- TLS: terminated at Cloudflare edge using `*.kemushi.eu` wildcard cert
- Tunnel: cloudflared container on dockerone, connects to Cloudflare Zero Trust
- SSH access: via Tailscale (`DEPLOY_HOST` = Tailscale IP, stored per repo in the `production` environment)
- One deploy key per service: a key can only redeploy the service it is bound to
- Domain: `kemushi.eu` (Cloudflare-managed)

---

## What the operator must do manually (one-time per new project)

**Give the service its own deploy key** (never reuse another service's key):

```bash
# 1. On your workstation — one key pair per service
ssh-keygen -t ed25519 -N "" -C "deploy:<app> $(date +%Y-%m)" -f deploy_<app>

# 2. On the deploy host (from a clone of Smartoys/devops) — bind the key to the service
sudo bash scripts/add-deploy-key.sh <app> <app>.kemushi.eu <PORT> "$(cat deploy_<app>.pub)"

# 3. In the service repo: Settings → Environments → production
#    secret   DEPLOY_SSH_KEY     = contents of deploy_<app>   (then delete the local file)
#    secret   DEPLOY_HOST        = Tailscale IP of the host
#    variable DEPLOY_KNOWN_HOSTS = output of: ssh-keyscan -t ed25519 <DEPLOY_HOST>
#    Deployment branches: main only.
```

Re-running `add-deploy-key.sh` for the same app replaces its key (rotation).

After that the pipeline is automated:
- Builds and pushes the Docker image to GHCR
- Adds the Cloudflare tunnel ingress rule via API
- Creates or updates the DNS CNAME record via API
- SSHes into dockerone and deploys the container
- Traefik picks up routing automatically

The only optional human step is approving the GitHub Actions
`production` environment gate if it is enabled.

---

## Files to create in the project repo

### 1. `deploy.yml` — place at repo root

```yaml
app: <app-name>               # lowercase, hyphens ok, no spaces (e.g. my-app)
subdomain: <app-name>.kemushi.eu
internal_port: <PORT>         # the port your container listens on internally
cloudflare_mode: tunnel       # always "tunnel" for dockerone (behind NAT)
```

**Rules:**
- `app` must match the repo name exactly (lowercase, hyphens only)
- `subdomain` must be `<app>.kemushi.eu`
- `internal_port` is the port INSIDE the container, not the host port
- `cloudflare_mode` is always `tunnel` for dockerone

**Example:**
```yaml
app: my-api
subdomain: my-api.kemushi.eu
internal_port: 3000
cloudflare_mode: tunnel
```

### 2. `.github/workflows/deploy.yml` — place in repo

```yaml
name: Deploy
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

jobs:
  deploy:
    uses: Smartoys/devops/.github/workflows/reusable-deploy.yml@main
    secrets:
      CF_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
      CF_ACCOUNT_ID: ${{ secrets.CF_ACCOUNT_ID }}
      CF_TUNNEL_ID: ${{ secrets.CF_TUNNEL_ID }}
      CF_ZONE_ID: ${{ secrets.CF_ZONE_ID }}
      TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      TS_OAUTH_SECRET: ${{ secrets.TS_OAUTH_SECRET }}
```

Do not use `secrets: inherit` — it hands every org secret to the deploy job.
`DEPLOY_SSH_KEY`, `DEPLOY_HOST` and `DEPLOY_KNOWN_HOSTS` are not passed here: the
reusable job runs in this repo's `production` environment and reads them there.

### 3. `Dockerfile` — must exist at repo root

The pipeline runs `docker build .` from the repo root. A `Dockerfile` must
exist. If the project already has one, no changes needed.

**Minimal example (Node.js):**
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
EXPOSE 3000
CMD ["node", "index.js"]
```

**Minimal example (Python):**
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["python", "app.py"]
```

---

## Secrets

**Per service repo** (Settings → Environments → `production`):

| Name | Kind | Purpose |
|---|---|---|
| `DEPLOY_SSH_KEY` | secret | This service's own Ed25519 deploy key |
| `DEPLOY_HOST` | secret | Tailscale IP of the deploy host |
| `DEPLOY_KNOWN_HOSTS` | variable | Pinned host key (`ssh-keyscan -t ed25519 <host>`) |

**Org level** (shared, visibility limited to the repos that deploy; passed
explicitly by each caller):

| Secret | Purpose |
|---|---|
| `CF_API_TOKEN` | Cloudflare API token (DNS Edit + Tunnel Edit, kemushi.eu only) |
| `CF_ZONE_ID` | kemushi.eu zone ID |
| `CF_ACCOUNT_ID` | Cloudflare account ID |
| `CF_TUNNEL_ID` | Cloudflare tunnel ID |
| `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` | Tailscale OAuth client, tag `tag:ci` (ACL: deploy host port 22 only) |

There is no shared deploy key and no registry token in CI: images are pushed
with the job's `GITHUB_TOKEN`, and the host pulls with its own read-only login.
If a secret is missing, tell the operator which one and where it belongs.

---

## GitHub Actions environment gate

The reusable workflow uses `environment: production`. This means every deploy
requires manual approval in the GitHub Actions UI before the SSH deploy step
runs. Tell the operator to check the Actions tab and click Approve when prompted.

To remove the approval gate (for fully automatic deploys), remove the
`environment: production` line from the reusable workflow in Smartoys/devops.

---

## How the deploy works on the server

When GitHub Actions SSHes into dockerone as the `deploy` user, the key's
`authorized_keys` line forces `sudo /opt/deploy/run.sh <app>`. The service name
comes from that line, never from the client:

| Value | Source |
|---|---|
| `APP` | the key's `authorized_keys` line (set by `add-deploy-key.sh`) |
| `SUBDOMAIN`, `PORT` | `/opt/deploy/apps/<app>.conf` on the host (root-owned) |
| `IMAGE` | always `ghcr.io/smartoys/<app>:<tag>` |
| tag | the only thing the client sends (the commit SHA, as the SSH command) |

The script:
1. Validates the tag and the app config (regex — rejects shell metacharacters)
2. Writes `/opt/stacks/<app>/docker-compose.yml`
3. Pulls the image with the host's own read-only GHCR login
4. Runs `docker compose up -d --remove-orphans`
5. Prunes dangling images
6. Logs everything to `/var/log/deploy/<app>.log`

The generated compose file looks like:
```yaml
services:
  app:
    image: ghcr.io/smartoys/<app>:latest
    restart: unless-stopped
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<app>.rule=Host(`<subdomain>`)"
      - "traefik.http.routers.<app>.entrypoints=web"
networks:
  traefik:
    external: true
```

Traefik picks up the labels automatically and starts routing within seconds.

---

## Environment variables for the container

If the project needs env vars (database URLs, API keys, etc.), they cannot be
passed through the current pipeline automatically. Two options:

**Option A — add to the deploy.yml and run.sh (recommended for non-secrets):**
Tell the operator to add them to the compose template in `/opt/deploy/run.sh`
on the server under the `environment:` key.

**Option B — create a .env file on the server manually:**
```bash
# On dockerone, after first deploy:
cat > /opt/stacks/<app>/.env <<EOF
DATABASE_URL=postgres://...
API_KEY=...
EOF
# Then add env_file to the compose:
# env_file: .env
```

Then redeploy by pushing an empty commit.

---

## Verifying a deployment

After the pipeline succeeds, verify end to end:

**1. Check the container is running (on dockerone):**
```bash
docker ps --filter name=<app>
```
Should show status `Up`.

**2. Check deploy log (on dockerone):**
```bash
tail -20 /var/log/deploy/<app>.log
```
Should end with `Deploy complete: <app>`.

**3. Check Traefik picked up the router (on dockerone):**
```bash
docker logs traefik-traefik-1 2>&1 | grep <app>
```
Should show no errors.

**4. Test the public URL:**
```bash
curl https://<app>.kemushi.eu
```
Should return a valid HTTP 200 response from the container.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `404 page not found` | Traefik has no matching router | Check container labels, check Traefik logs |
| `502 Bad Gateway` | Container not reachable by Traefik | Check container is on `traefik` network |
| `ERR EntryPoint doesn't exist entryPointName=websecure` | Old compose file with wrong entrypoint | Update `/opt/stacks/<app>/docker-compose.yml` entrypoints to `web` |
| Pipeline fails at SSH step | Tailscale not connected | Check `tailscale status` on dockerone |
| Pipeline fails at build step | Image name not lowercase | Ensure `app` in deploy.yml is all lowercase |
| `invalid tag` GHCR error | Uppercase in image name | Fix app name to lowercase in deploy.yml |
| Cloudflare tunnel step fails | Missing CF secrets | Check org secrets CF_API_TOKEN, CF_ACCOUNT_ID, CF_TUNNEL_ID |
| Container starts but 404 | DNS CNAME not yet propagated | Wait 30s and retry — pipeline creates it automatically |

---

## Adding a second deployment server

If a new server needs to be added to the infrastructure:

1. Run the bootstrap script on the new server, from a clone of this repo:
```bash
git clone https://github.com/Smartoys/devops.git && cd devops

bash scripts/bootstrap-server.sh \
  --tunnel-token "<NEW_TUNNEL_TOKEN>" \
  --email "david@kemushi.eu" \
  --cf-token "<CF_API_TOKEN>"
```

2. Run `tailscale up` on the new server and authenticate.

3. Get the new Tailscale IP: `tailscale ip -4`

4. As root: `docker login ghcr.io -u <bot-account>` with a read:packages token.

5. For each service moving to this server: generate a new key, run
   `scripts/add-deploy-key.sh`, and update that repo's `production` environment
   (`DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_KNOWN_HOSTS`).

6. Add a new Cloudflare Tunnel in Zero Trust. Public hostnames and DNS
   CNAME records are created automatically by the pipeline on first deploy.

---

## Quick reference — deploying a new project

```
1. Create deploy.yml at repo root
2. Create .github/workflows/deploy.yml at repo root
3. Ensure Dockerfile exists at repo root
4. Push to main
5. Approve the GitHub Actions production environment gate (if enabled)
6. Verify with: curl https://<app>.kemushi.eu
```
