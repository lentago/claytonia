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
# The first deploy runs here, in the foreground, and the timer is enabled after it
# (#190). `enable --now` alone starts the timer, and once OnBootSec has passed (a
# container counts it from its own start) the timer fires at once and deploys in
# parallel with whatever runs next. For a oneshot unit, `systemctl start` returns
# when the run ends and fails if the run fails. A failed first deploy still enables
# the timer, which retries every 5 minutes, and makes this script exit non-zero.
rc=0
systemctl start claytonia-gitops.service || rc=$?
systemctl enable --now claytonia-gitops.timer
if [ "$rc" -ne 0 ]; then
  echo "claytonia gitops installed, but the first deploy failed (rc $rc); the timer retries every 5 min." >&2
  echo "see: tail /var/log/claytonia-gitops.log ; journalctl -u claytonia-gitops.service" >&2
  exit 1
fi
echo "claytonia gitops installed and deployed — pulls origin/main and redeploys every 5 min."
echo "force a pull: systemctl start claytonia-gitops.service ; watch: tail -f /var/log/claytonia-gitops.log"
