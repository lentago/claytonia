#!/usr/bin/env bash
# 06-transcript-shipper.sh — install the live fleet "stream of consciousness"
# transcript shipper on this worker. Re-runnable.
#
# The shipper is a worker-local Alloy agent that tails Claude Code's live session
# transcript and ships a scrubbed reasoning stream to Grafana Cloud Loki
# (job="claude_transcript"), rendered on the Claude Runner Fleet dashboard. Its
# config + deploy logic are canonical in PitziLabs/homelab-observability
# (issue #71) — this script just checks that repo out, runs its deploy script,
# and enables a drift-sync timer so the worker self-updates. Vendoring nothing
# keeps the two repos from drifting.
#
# Creds (the Grafana Cloud LOGS push token) are NOT in git. Provide them once,
# either in the environment when running this, or in an inherited
# /etc/default/alloy-transcript (a `pct clone` carries it over):
#
#   sudo env GRAFANA_CLOUD_LOGS_URL=… GRAFANA_CLOUD_LOGS_USER=… \
#     GRAFANA_CLOUD_LOGS_TOKEN=… provision/06-transcript-shipper.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

OBS_DIR="${OBS_REPO_DIR:-/opt/homelab-observability}"
OBS_URL="${OBS_REPO_URL:-https://github.com/PitziLabs/homelab-observability.git}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">>> ensure git present"
command -v git >/dev/null || apt-get install -y -qq git >/dev/null

echo ">>> checkout canonical config repo at $OBS_DIR"
if [ ! -d "$OBS_DIR/.git" ]; then
  git clone --depth 1 "$OBS_URL" "$OBS_DIR"
else
  git -C "$OBS_DIR" fetch --quiet origin main && git -C "$OBS_DIR" reset --hard --quiet origin/main
fi

echo ">>> install the drift-sync units (gitops keeps them fresh thereafter)"
install -m 644 "$HERE/../systemd/transcript-shipper-sync.service" /etc/systemd/system/transcript-shipper-sync.service
install -m 644 "$HERE/../systemd/transcript-shipper-sync.timer"   /etc/systemd/system/transcript-shipper-sync.timer
install -m 755 "$HERE/../bin/transcript-shipper-sync"             /opt/claude-runner/bin/transcript-shipper-sync

# Pick up creds from the environment, or from an inherited deploy (clone case).
[ -f /etc/default/alloy-transcript ] && . /etc/default/alloy-transcript

echo ">>> initial deploy (if this worker is credentialed)"
if [ -n "${GRAFANA_CLOUD_LOGS_URL:-}" ] && [ -n "${GRAFANA_CLOUD_LOGS_USER:-}" ] && [ -n "${GRAFANA_CLOUD_LOGS_TOKEN:-}" ]; then
  GRAFANA_CLOUD_LOGS_URL="$GRAFANA_CLOUD_LOGS_URL" \
  GRAFANA_CLOUD_LOGS_USER="$GRAFANA_CLOUD_LOGS_USER" \
  GRAFANA_CLOUD_LOGS_TOKEN="$GRAFANA_CLOUD_LOGS_TOKEN" \
    "$OBS_DIR/scripts/deploy-runner-transcript-alloy.sh"
else
  echo ">>> No GRAFANA_CLOUD_LOGS_* creds found (env or /etc/default/alloy-transcript)."
  echo ">>> The shipper is staged but not started. Re-run with the token to finish:"
  echo ">>>   sudo env GRAFANA_CLOUD_LOGS_URL=… GRAFANA_CLOUD_LOGS_USER=… GRAFANA_CLOUD_LOGS_TOKEN=… $0"
fi

echo ">>> enable the drift-sync timer"
systemctl daemon-reload
systemctl enable --now transcript-shipper-sync.timer

echo ">>> done. Watch: journalctl -u alloy-transcript -f  |  tail -f /var/log/transcript-shipper-sync.log"
