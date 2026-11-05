#!/bin/bash
# add-deploy-key.sh
# Binds one SSH public key to one service on this host. Run as root:
#
#   sudo bash scripts/add-deploy-key.sh vies-agent viesagent.kemushi.eu 8080 "ssh-ed25519 AAAA..."
#
# Writes /opt/deploy/apps/<app>.conf and replaces any existing key for <app>
# in deploy's authorized_keys (so re-running rotates the key). The key can only
# run `sudo /opt/deploy/run.sh <app>`: no shell, no forwarding, no other service.
#
# Generate the key pair off the host, one per service:
#   ssh-keygen -t ed25519 -N "" -C "deploy:<app> $(date +%Y-%m)" -f deploy_<app>
# Private key -> the service repo's `production` environment secret DEPLOY_SSH_KEY.

set -euo pipefail

APP="${1:-}"; SUBDOMAIN="${2:-}"; PORT="${3:-}"; PUBKEY="${4:-}"

if [[ -z "$APP" || -z "$SUBDOMAIN" || -z "$PORT" || -z "$PUBKEY" ]]; then
  echo "Usage: $0 <app> <subdomain> <port> \"ssh-ed25519 AAAA...\""
  exit 1
fi

[[ "$APP" =~ ^[a-z0-9_-]{1,64}$ ]]        || { echo "ERROR: invalid app"; exit 1; }
[[ "$SUBDOMAIN" =~ ^[a-z0-9.-]{1,253}$ ]] || { echo "ERROR: invalid subdomain"; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { echo "ERROR: invalid port"; exit 1; }
[[ "$PUBKEY" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+ ]] || { echo "ERROR: expected an ssh-ed25519 public key"; exit 1; }

KEY_BODY="$(echo "$PUBKEY" | awk '{print $1" "$2}')"
AUTH_KEYS="/home/deploy/.ssh/authorized_keys"

echo "==> Writing /opt/deploy/apps/$APP.conf"
install -o root -g root -m 644 /dev/null "/opt/deploy/apps/$APP.conf"
printf 'SUBDOMAIN=%s\nPORT=%s\n' "$SUBDOMAIN" "$PORT" > "/opt/deploy/apps/$APP.conf"

echo "==> Binding key to $APP"
TMP="$(mktemp)"
# Drop any previous key for this app, and this key if it was bound elsewhere.
grep -v -E " deploy:${APP}$" "$AUTH_KEYS" 2>/dev/null | grep -v -F "$KEY_BODY" > "$TMP" || true
echo "restrict,command=\"sudo /opt/deploy/run.sh $APP\" $KEY_BODY deploy:$APP" >> "$TMP"
install -o deploy -g deploy -m 600 "$TMP" "$AUTH_KEYS"
rm -f "$TMP"

echo "==> Keys now on this host:"
ssh-keygen -lf "$AUTH_KEYS"
