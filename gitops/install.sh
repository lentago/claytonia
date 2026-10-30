#!/usr/bin/env bash
# install.sh — bootstrap the claytonia gitops loop on a worker. Run ONCE as root
# on each worker (it is deliberately not managed by the loop it installs).
#
#   curl -fsSL https://raw.githubusercontent.com/lentago/claytonia/main/gitops/install.sh | bash
#   (or run from a checkout)
set -euo pipefail
REPO_URL="${CLAYTONIA_REPO_URL:-https://github.com/lentago/claytonia.git}"
REPO_DIR="${CLAYTONIA_REPO_DIR:-/opt/claytonia}"

# A worker still on the pre-rename loop gets rebuilt, not a second loop beside
# it: the two take different locks and would deploy concurrently (#65).
if [ -e /etc/systemd/system/bullpen-gitops.timer ]; then
  echo "this worker still runs bullpen-gitops — rebuild it (claytonia#65) instead" >&2
  exit 1
fi

if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
fi
install -m 755 "$REPO_DIR/gitops/claytonia-gitops.sh"      /usr/local/sbin/claytonia-gitops
install -m 644 "$REPO_DIR/gitops/claytonia-gitops.service" /etc/systemd/system/claytonia-gitops.service
install -m 644 "$REPO_DIR/gitops/claytonia-gitops.timer"   /etc/systemd/system/claytonia-gitops.timer
systemctl daemon-reload
systemctl enable --now claytonia-gitops.timer
echo "claytonia gitops installed — pulls origin/main and redeploys every 5 min."
echo "force a pull: systemctl start claytonia-gitops.service ; watch: tail -f /var/log/claytonia-gitops.log"
