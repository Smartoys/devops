Bootstrap a deploy host from a clone of this repo (see DEPLOY_INSTRUCTIONS.MD):

git clone https://github.com/Smartoys/devops.git && cd devops

bash scripts/bootstrap-server.sh \
  --tunnel-token "eyJ..." \
  --email "david@kemushi.eu" \
  --cf-token "cfut_..."

Then one deploy key per service:

sudo bash scripts/add-deploy-key.sh <app> <app>.kemushi.eu <PORT> "ssh-ed25519 AAAA... deploy:<app>"
