#!/bin/bash
# bootstrap-server.sh
# Sets up a fresh Ubuntu server as a deployment host.
# Run as root.
#
# Usage (from a clone of this repo; deploy keys are added per service afterwards
# with scripts/add-deploy-key.sh):
#   git clone https://github.com/Smartoys/devops.git && cd devops
#   bash scripts/bootstrap-server.sh \
#     --tunnel-token "eyJ..." \
#     --email "you@example.com" \
#     --cf-token "cfut_..."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Arguments ─────────────────────────────────────────────────────────────────

TUNNEL_TOKEN=""
EMAIL=""
CF_TOKEN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --tunnel-token)  TUNNEL_TOKEN="$2";  shift 2 ;;
    --email)         EMAIL="$2";         shift 2 ;;
    --cf-token)      CF_TOKEN="$2";      shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$TUNNEL_TOKEN" || -z "$EMAIL" || -z "$CF_TOKEN" ]]; then
  echo "Usage: $0 --tunnel-token \"eyJ...\" --email \"you@example.com\" --cf-token \"cfut_...\""
  exit 1
fi

echo ""
echo "=========================================="
echo " CLD Distribution — Server Bootstrap"
echo "=========================================="
echo ""

# ── 1. System update ──────────────────────────────────────────────────────────

echo "==> [1/7] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git jq

# ── 2. Docker ─────────────────────────────────────────────────────────────────

echo "==> [2/7] Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
else
  echo "    Docker already installed: $(docker --version)"
fi

# ── 3. Traefik network + stack ────────────────────────────────────────────────

echo "==> [3/7] Setting up Traefik..."
docker network create traefik 2>/dev/null || echo "    traefik network already exists"

mkdir -p /opt/stacks/traefik/certs
touch /opt/stacks/traefik/certs/acme.json
chmod 600 /opt/stacks/traefik/certs/acme.json

# Store CF token for Traefik DNS challenge
cat > /opt/stacks/traefik/.env <<EOF
CF_DNS_API_TOKEN=${CF_TOKEN}
EOF
chmod 600 /opt/stacks/traefik/.env

cat > /opt/stacks/traefik/docker-compose.yml <<EOF
services:
  traefik:
    image: traefik:v3.6
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=traefik"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/stacks/traefik/certs:/certs
    networks:
      - traefik

networks:
  traefik:
    external: true
EOF

docker compose -f /opt/stacks/traefik/docker-compose.yml up -d
echo "    Traefik started."

# ── 4. cloudflared ────────────────────────────────────────────────────────────

echo "==> [4/7] Setting up Cloudflare Tunnel..."
mkdir -p /opt/stacks/cloudflared

cat > /opt/stacks/cloudflared/.env <<EOF
TUNNEL_TOKEN=${TUNNEL_TOKEN}
EOF
chmod 600 /opt/stacks/cloudflared/.env

cat > /opt/stacks/cloudflared/docker-compose.yml <<'EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${TUNNEL_TOKEN}
    networks:
      - traefik

networks:
  traefik:
    external: true
EOF

docker compose -f /opt/stacks/cloudflared/docker-compose.yml up -d
echo "    cloudflared started."

# ── 5. Tailscale ──────────────────────────────────────────────────────────────

echo "==> [5/7] Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
  echo ""
  echo "    !! ACTION REQUIRED: Authenticate Tailscale !!"
  echo "    Run: tailscale up"
  echo "    Open the URL it prints and authenticate."
  echo "    Then re-run this script or continue manually."
  echo ""
else
  echo "    Tailscale already installed: $(tailscale version)"
fi

# ── 6. Deploy user ────────────────────────────────────────────────────────────

echo "==> [6/7] Setting up deploy user..."
bash "$SCRIPT_DIR/bootstrap-deploy-user.sh"

# ── 7. Verify ─────────────────────────────────────────────────────────────────

echo "==> [7/7] Verifying..."
echo ""
echo "    Docker:      $(docker --version)"
echo "    Compose:     $(docker compose version)"
echo "    Tailscale:   $(tailscale version 2>/dev/null || echo 'not authenticated yet')"
echo "    Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'not authenticated yet')"
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo ""
echo "=========================================="
echo " Bootstrap complete!"
echo "=========================================="
echo ""
echo " Next steps:"
echo "   1. Run: tailscale up  (if not done yet)"
echo "   2. docker login ghcr.io -u <bot-account>   (read:packages token, once)"
echo "   3. Per service: generate a key, run scripts/add-deploy-key.sh, and set"
echo "      DEPLOY_SSH_KEY / DEPLOY_HOST / DEPLOY_KNOWN_HOSTS on that repo's production environment"
echo "   4. Add Cloudflare public hostname for this server in Zero Trust"
echo "   5. Push a repo with deploy.yml to trigger your first deploy"
echo ""
