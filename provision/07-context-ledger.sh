#!/usr/bin/env bash
# 07-context-ledger.sh — install the fleet context-ledger snapshot on this worker
# and, IF this host is the designated primary, the committer + its deploy key.
# Re-runnable. Run as root.
#
# The snapshot (bin/context-snapshot) runs on EVERY worker: it collects host-side
# Claude context into /srv/jobs/context-ledger/incoming/<hostname>/. The committer
# (bin/context-ledger-commit) runs on the PRIMARY only: it sweeps that queue into
# cpitzi/myosotis. See docs/context-ledger.md.
#
# Primary election is a single NAS marker, /srv/jobs/context-ledger/primary,
# holding the primary's hostname. To designate this host:
#   echo "$(hostname)" > /srv/jobs/context-ledger/primary
# then run this script (or wait for the next gitops pull + a manual re-run).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
LEDGER_ROOT="$JOBS_ROOT/context-ledger"
PRIMARY_MARKER="$LEDGER_ROOT/primary"
DEPLOY_KEY="/root/.ssh/myosotis_deploy"
RUNNER_BIN=/opt/claude-runner/bin

echo ">>> ensure deps present (rsync for the committer sweep)"
command -v rsync >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq rsync >/dev/null; }

echo ">>> stage bin/ scripts (gitops keeps them fresh thereafter)"
install -m 755 "$HERE/../bin/context-snapshot"       "$RUNNER_BIN/context-snapshot"
install -m 755 "$HERE/../bin/context-ledger-commit"  "$RUNNER_BIN/context-ledger-commit"

echo ">>> install systemd units"
for u in context-snapshot.service context-snapshot.timer \
         context-ledger-commit.service context-ledger-commit.timer; do
  install -m 644 "$HERE/../systemd/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload

echo ">>> ensure the ledger queue exists on the NAS (owned by claude)"
su - claude -c "mkdir -p '$LEDGER_ROOT/incoming'" 2>/dev/null || mkdir -p "$LEDGER_ROOT/incoming"

echo ">>> enable the daily snapshot on this worker (all workers snapshot)"
systemctl enable --now context-snapshot.timer

# --------------------------------------------------------- primary-only setup
is_primary=0
if [ -f "$PRIMARY_MARKER" ] && [ "$(tr -d '[:space:]' < "$PRIMARY_MARKER")" = "$(hostname)" ]; then
  is_primary=1
fi

if [ "$is_primary" = 1 ]; then
  echo ">>> this host is the ledger PRIMARY — ensure deploy key + committer"
  install -d -m 700 /root/.ssh
  if [ ! -f "$DEPLOY_KEY" ]; then
    ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N '' -C 'myosotis-ledger-committer@claude-runner' >/dev/null
    chmod 600 "$DEPLOY_KEY"
    echo "!!! ============================================================"
    echo "!!! A NEW ledger deploy key was generated. Register its PUBLIC"
    echo "!!! half as a WRITE deploy key on cpitzi/myosotis:"
    echo "!!! ------------------------------------------------------------"
    cat "$DEPLOY_KEY.pub"
    echo "!!! ------------------------------------------------------------"
    echo "!!! The PRIVATE half stays in $DEPLOY_KEY on this host ONLY."
    echo "!!! Until the public half is registered, the committer will fail"
    echo "!!! loudly (by design) and snapshots stay queued in incoming/."
    echo "!!! ============================================================"
  else
    echo ">>> deploy key already present at $DEPLOY_KEY (leaving it)"
  fi
  chmod 600 "$DEPLOY_KEY" 2>/dev/null || true
  systemctl enable --now context-ledger-commit.timer
else
  echo ">>> this host is NOT the ledger primary — committer NOT enabled."
  echo ">>> To make it primary: echo \"\$(hostname)\" > $PRIMARY_MARKER  &&  sudo $0"
  systemctl disable --now context-ledger-commit.timer >/dev/null 2>&1 || true
fi

echo ">>> run one snapshot now (natural post-provision hook)"
systemctl start context-snapshot.service || true

echo ">>> done. Watch: journalctl -t claude-runner -f | grep context-"
