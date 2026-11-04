#!/usr/bin/env bash
# R-2 (provision/README.md § Rebuilding a worker): copy one worker's secrets to a
# root-only dir on pve4 BEFORE its rebuild, for R-4 to restore. They never pass
# through an agent, the NAS or git. Runs on pve4 as root. Prints names and sizes only.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/r2-stage-secrets.sh
set -euo pipefail
ID="${1:?vmid}"
# Act only on a claytonia pool worker, never on another guest.
HOST="$(pct config "$ID" | sed -n 's/^hostname: //p')"
case "$HOST" in claude-runner|claude-runner-[0-9]*) ;; *) echo "CT $ID is '$HOST', not a claude-runner worker: refusing" >&2; exit 1 ;; esac
pvesh get /pools/claytonia --output-format json | grep -Eq "\"vmid\":${ID}[,}]" || { echo "CT $ID is not in the claytonia pool: refusing" >&2; exit 1; }
D="/root/rebuild-$ID"
pct status "$ID" | grep -q running || { echo "CT $ID is not running" >&2; exit 1; }
install -d -m 700 "$D"
for f in token.env gh-app.env gh-app.pem google.env; do
  pct pull "$ID" "/etc/claude-runner/$f" "$D/$f"
done
# The peer-runtime credentials (#166) are staged when the worker has them.
for f in gemini.env gemini-sa.json codex.env; do
  if pct exec "$ID" -- test -e "/etc/claude-runner/$f"; then
    pct pull "$ID" "/etc/claude-runner/$f" "$D/$f"
  else
    echo "  no $f on CT $ID: not staged"
  fi
done
pct pull "$ID" /etc/default/alloy-transcript "$D/alloy-transcript"
chmod 600 "$D"/*
for f in "$D"/*; do [ -s "$f" ] || { echo "EMPTY: $f" >&2; exit 1; }; done
echo "staged for CT $ID ($HOST):"
stat -c '  %n %s bytes' "$D"/*
