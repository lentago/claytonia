#!/usr/bin/env bash
# R-3 (provision/README.md § Rebuilding a worker): stop one worker claiming jobs,
# then wait until it holds none. The heartbeat keeps running, so the other
# workers' reapers leave its in-flight jobs alone. Runs on pve4 as root.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/r3-drain.sh
set -euo pipefail
ID="${1:?vmid}"
HOST="$(pct config "$ID" | sed -n 's/^hostname: //p')"
PROC=/mnt/neptune-lentago/claude-jobs/processing
[ -d "$PROC" ] || { echo "NAS not mounted on pve4 at $PROC" >&2; exit 1; }
pct exec "$ID" -- systemctl stop claude-inbox.timer
echo "$(date -u +%FT%TZ) claude-inbox.timer stopped on $HOST; waiting for in-flight work"
# Upper bound: the 3600 s job timeout + 30 s kill grace, polled every 30 s.
for _ in $(seq 1 125); do
  svc="$(pct exec "$ID" -- systemctl is-active claude-inbox.service || true)"
  # grep exits 2 when processing/ holds no .owner at all; under pipefail that
  # would end the script, so the count tolerates it.
  owned="$( { grep -lx "owner=$HOST" "$PROC"/*.owner 2>/dev/null || true; } | wc -l)"
  if [ "$svc" != active ] && [ "$svc" != activating ] && [ "$owned" = 0 ]; then
    echo "$(date -u +%FT%TZ) DRAINED: $HOST holds no job (heartbeat still on)"
    exit 0
  fi
  echo "  $(date -u +%T) claude-inbox.service=$svc owned=$owned"
  sleep 30
done
echo "NOT DRAINED after ~62 min: inbox stays stopped; tell Claude before merging" >&2
exit 1
