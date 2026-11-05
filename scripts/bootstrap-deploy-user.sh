#!/bin/bash
# bootstrap-deploy-user.sh
# Run once as root on the target VM, from a clone of this repo:
#
#   git clone https://github.com/Smartoys/devops.git && cd devops
#   sudo bash scripts/bootstrap-deploy-user.sh
#
# Sets up the deploy user, /opt/deploy/run.sh, sudoers and sshd. It installs no
# SSH key: every service gets its own key with scripts/add-deploy-key.sh.
# Safe to re-run; it also strips the old shared-key setup (docker group
# membership, AcceptEnv, broad sudoers rules).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Creating deploy user..."
if ! id deploy &>/dev/null; then
  useradd -m -s /bin/bash -c "CI/CD deploy account" deploy
fi

# Membership of the docker group is root on this host; deploy only gets sudo
# on the one script below.
if id -nG deploy | tr ' ' '\n' | grep -qx docker; then
  gpasswd -d deploy docker
fi

mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

echo "==> Installing deploy script..."
mkdir -p /opt/deploy/apps
install -o root -g root -m 755 "$SCRIPT_DIR/deploy-run.sh" /opt/deploy/run.sh
chown root:root /opt/deploy /opt/deploy/apps
chmod 755 /opt/deploy /opt/deploy/apps

echo "==> Setting up stacks and log directories (root-owned)..."
mkdir -p /opt/stacks /var/log/deploy
chown root:root /opt/stacks /var/log/deploy
chmod 755 /opt/stacks /var/log/deploy

echo "==> Installing sudoers rule..."
cat > /etc/sudoers.d/deploy << 'SUDOERS'
deploy ALL=(root) NOPASSWD: /opt/deploy/run.sh
Defaults!/opt/deploy/run.sh env_keep += "SSH_ORIGINAL_COMMAND SSH_CLIENT"
SUDOERS
chmod 440 /etc/sudoers.d/deploy
visudo -c && echo "sudoers OK" || { echo "ERROR: sudoers syntax error!"; rm /etc/sudoers.d/deploy; exit 1; }

echo "==> Configuring sshd..."
rm -f /etc/ssh/sshd_config.d/deploy-env.conf
cat > /etc/ssh/sshd_config.d/deploy.conf << 'SSHD'
PasswordAuthentication no
PermitRootLogin no
SSHD
sshd -t
systemctl reload ssh

echo ""
echo "==> Done. Summary:"
echo "    deploy user:    $(id deploy)"
echo "    deploy script:  /opt/deploy/run.sh"
echo "    app configs:    /opt/deploy/apps/<app>.conf"
echo "    sudoers:        /etc/sudoers.d/deploy"
echo "    stacks dir:     /opt/stacks"
echo "    log dir:        /var/log/deploy"
echo ""
echo " Next:"
echo "   1. Registry pull credentials (once, as root, read:packages token only):"
echo "        docker login ghcr.io -u <bot-account>"
echo "   2. One key per service:"
echo "        sudo bash scripts/add-deploy-key.sh <app> <subdomain> <port> \"ssh-ed25519 AAAA...\""
