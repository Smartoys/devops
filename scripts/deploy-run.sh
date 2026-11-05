#!/bin/bash
# /opt/deploy/run.sh
# The ONLY program a deploy SSH key may execute. Each key is bound to one
# service by its authorized_keys line (see add-deploy-key.sh):
#
#   restrict,command="sudo /opt/deploy/run.sh <app>" ssh-ed25519 AAAA... deploy:<app>
#
# The service comes from that line ($1), never from the client. Its subdomain
# and port come from the root-owned /opt/deploy/apps/<app>.conf, and the image
# is always ghcr.io/smartoys/<app>. The client sends only the image tag, as the
# SSH command (SSH_ORIGINAL_COMMAND); nothing else is accepted.
# Runs as root via sudo. Registry pull credentials live on the host
# (one-time `docker login ghcr.io` with a read:packages token), not in CI.

set -euo pipefail

APP="${1:-}"
TAG="${SSH_ORIGINAL_COMMAND:-latest}"

# ── Strict input validation ────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$APP" =~ ^[a-z0-9_-]{1,64}$ ]]  || die "invalid app '$APP'"
[[ "$TAG" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "invalid tag"

APP_CONF="/opt/deploy/apps/$APP.conf"
[[ -f "$APP_CONF" ]] || die "no config for app '$APP'"

SUBDOMAIN="$(sed -n 's/^SUBDOMAIN=//p' "$APP_CONF")"
PORT="$(sed -n 's/^PORT=//p' "$APP_CONF")"

[[ "$SUBDOMAIN" =~ ^[a-z0-9.-]{1,253}$ ]] || die "invalid SUBDOMAIN in $APP_CONF"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "invalid PORT in $APP_CONF"

IMAGE="ghcr.io/smartoys/$APP:$TAG"

# ── Paths ─────────────────────────────────────────────────────────────────────

STACK_DIR="/opt/stacks/$APP"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
LOG_FILE="/var/log/deploy/$APP.log"

mkdir -p "$STACK_DIR" "$(dirname "$LOG_FILE")"
touch "$STACK_DIR/.env"

# ── Logging ───────────────────────────────────────────────────────────────────

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

log "Deploy started: app=$APP image=$IMAGE subdomain=$SUBDOMAIN port=$PORT from=${SSH_CLIENT:-local}"

# ── Write docker-compose.yml ──────────────────────────────────────────────────

# Use a temp file + atomic move to avoid partial writes
TMPFILE=$(mktemp "$STACK_DIR/.docker-compose.XXXXXX")

cat > "$TMPFILE" <<EOF
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
      - "traefik.http.routers.${APP}.entrypoints=web"
      - "traefik.http.services.${APP}.loadbalancer.server.port=${PORT}"

networks:
  traefik:
    external: true
EOF

mv "$TMPFILE" "$COMPOSE_FILE"
log "Compose file written: $COMPOSE_FILE"

# ── Pull & deploy ─────────────────────────────────────────────────────────────

log "Pulling image: $IMAGE"
docker compose -f "$COMPOSE_FILE" pull 2>&1 | tee -a "$LOG_FILE"

log "Starting stack..."
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE"

# ── Cleanup old images ────────────────────────────────────────────────────────

log "Pruning dangling images..."
docker image prune -f 2>&1 | tee -a "$LOG_FILE"

log "Deploy complete: $APP"
