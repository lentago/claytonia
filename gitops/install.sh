#!/usr/bin/env bash
# install.sh — bootstrap the bullpen gitops loop on a worker. Run ONCE as root
# on each worker (it is deliberately not managed by the loop it installs).
#
#   curl -fsSL https://raw.githubusercontent.com/lentago/claytonia/main/gitops/install.sh | bash
#   (or run from a checkout)
set -euo pipefail
REPO_URL="${BULLPEN_REPO_URL:-https://github.com/lentago/claytonia.git}"
REPO_DIR="${BULLPEN_REPO_DIR:-/opt/bullpen}"

if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
fi
install -m 755 "$REPO_DIR/gitops/bullpen-gitops.sh"      /usr/local/sbin/bullpen-gitops
install -m 644 "$REPO_DIR/gitops/bullpen-gitops.service" /etc/systemd/system/bullpen-gitops.service
install -m 644 "$REPO_DIR/gitops/bullpen-gitops.timer"   /etc/systemd/system/bullpen-gitops.timer
systemctl daemon-reload
systemctl enable --now bullpen-gitops.timer
echo "bullpen gitops installed — pulls origin/main and redeploys every 5 min."
echo "force a pull: systemctl start bullpen-gitops.service ; watch: tail -f /var/log/bullpen-gitops.log"
