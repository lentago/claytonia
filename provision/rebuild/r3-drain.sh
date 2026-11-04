#!/usr/bin/env bash
# R-3 (provision/README.md § Rebuilding a worker): stop one worker claiming jobs,
# then wait until it holds none. The heartbeat keeps running, so the other
# workers' reapers leave its in-flight jobs alone. Runs on pve4 as root.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/r3-drain.sh
set -euo pipefail
ID="${1:?vmid}"
# Act only on a claytonia pool worker, never on another guest.
HOST="$(pct config "$ID" | sed -n 's/^hostname: //p')"
case "$HOST" in claude-runner|claude-runner-[0-9]*) ;; *) echo "CT $ID is '$HOST', not a claude-runner worker: refusing" >&2; exit 1 ;; esac
pvesh get /pools/claytonia --output-format json | grep -Eq "\"vmid\":${ID}[,}]" || { echo "CT $ID is not in the claytonia pool: refusing" >&2; exit 1; }
PROC=/mnt/neptune-lentago/claude-jobs/processing
[ -d "$PROC" ] || { echo "NAS not mounted on pve4 at $PROC" >&2; exit 1; }
pct exec "$ID" -- systemctl stop claude-inbox.timer
echo "$(date -u +%FT%TZ) claude-inbox.timer stopped on $HOST; waiting for in-flight work"
# Upper bound: the 3600 s job timeout + 30 s kill grace, polled every 30 s.
for _ in $(seq 1 125); do
  # is-active exits non-zero for "inactive", hence || true. An empty answer means
  # pct exec itself failed: the state is unknown, so the worker is not drained.
  svc="$(pct exec "$ID" -- systemctl is-active claude-inbox.service 2>/dev/null || true)"
  # grep exits 2 when processing/ holds no .owner at all; under pipefail that
  # would end the script, so the count tolerates it.
  owned="$( { grep -lx "owner=$HOST" "$PROC"/*.owner 2>/dev/null || true; } | wc -l)"
  if [ -n "$svc" ] && [ "$svc" != active ] && [ "$svc" != activating ] && [ "$owned" = 0 ]; then
    echo "$(date -u +%FT%TZ) DRAINED: $HOST holds no job (heartbeat still on)"
    exit 0
  fi
  echo "  $(date -u +%T) claude-inbox.service=${svc:-unknown} owned=$owned"
  sleep 30
done
echo "NOT DRAINED after ~62 min: inbox stays stopped; tell Claude before merging" >&2
exit 1
