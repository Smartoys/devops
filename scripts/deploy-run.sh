#!/bin/bash
# /opt/deploy/run.sh
# This is the ONLY script the deploy SSH key is allowed to execute.
# Invoked by GitHub Actions via: ssh deploy@host (command is forced via authorized_keys)
#
# Expected env vars passed by Actions (via SSH environment or inline args):
#   APP        — stack name (e.g. "myapp")
#   IMAGE      — full image ref (e.g. "ghcr.io/yourorg/myapp:latest")
#   SUBDOMAIN  — public hostname (e.g. "myapp.kemushi.eu")
#   PORT       — internal container port (e.g. "3000")
#   GHCR_TOKEN — GitHub PAT with read:packages scope

set -euo pipefail

# ── Strict input validation ────────────────────────────────────────────────────

# Allow only safe characters in each variable (no shell metacharacters)
validate() {
  local name="$1" value="$2" pattern="$3"
  if [[ ! "$value" =~ $pattern ]]; then
    echo "ERROR: Invalid value for $name: '$value'" >&2
    exit 1
  fi
}

validate "APP"       "$APP"       '^[a-z0-9_-]{1,64}$'
validate "IMAGE"     "$IMAGE"     '^ghcr\.io/[a-zA-Z0-9_./:-]{1,200}$'
validate "SUBDOMAIN" "$SUBDOMAIN" '^[a-z0-9.-]{1,253}$'
validate "PORT"      "$PORT"      '^[0-9]{1,5}$'

# Validate port is in usable range
if (( PORT < 1 || PORT > 65535 )); then
  echo "ERROR: PORT out of range: $PORT" >&2
  exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────

STACKS_ROOT="/opt/stacks"
STACK_DIR="$STACKS_ROOT/$APP"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
LOG_FILE="/var/log/deploy/$APP.log"

mkdir -p "$STACK_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$STACK_DIR/.env"

# ── Logging ───────────────────────────────────────────────────────────────────

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

log "Deploy started: app=$APP image=$IMAGE subdomain=$SUBDOMAIN port=$PORT"

# ── Write docker-compose.yml ──────────────────────────────────────────────────

# Use a temp file + atomic move to avoid partial writes
TMPFILE=$(mktemp "$STACK_DIR/.docker-compose.XXXXXX")

cat > "$TMPFILE" <<EOF
version: "3.8"

services:
  app:
    image: ${IMAGE}
    restart: unless-stopped
    env_file: .env
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP}.rule=Host(\`${SUBDOMAIN}\`)"
      - "traefik.http.routers.${APP}.entrypoints=websecure"
      - "traefik.http.routers.${APP}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${APP}.loadbalancer.server.port=${PORT}"

networks:
  traefik:
    external: true
EOF

mv "$TMPFILE" "$COMPOSE_FILE"
log "Compose file written: $COMPOSE_FILE"

# ── GHCR login ────────────────────────────────────────────────────────────────

log "Logging in to GHCR..."
echo "$GHCR_TOKEN" | sudo docker login ghcr.io -u deploy --password-stdin 2>&1 | tee -a "$LOG_FILE"

# ── Pull & deploy ─────────────────────────────────────────────────────────────

log "Pulling image: $IMAGE"
sudo docker compose -f "$COMPOSE_FILE" pull 2>&1 | tee -a "$LOG_FILE"

log "Starting stack..."
sudo docker compose -f "$COMPOSE_FILE" up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE"

# ── Cleanup old images ────────────────────────────────────────────────────────

log "Pruning dangling images..."
sudo docker image prune -f 2>&1 | tee -a "$LOG_FILE"

log "Deploy complete: $APP"
