#!/usr/bin/env bash
# Gate (provision/README.md § Rebuilding a worker): queue one read-only Haiku job
# and start this worker's poller at once, so its own poller claims it. The next
# worker is rebuilt only after this job is DONE on this one. Runs on pve4 as root.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/gate.sh
set -euo pipefail
ID="${1:?vmid}"
HOST="$(pct config "$ID" | sed -n 's/^hostname: //p')"
J=/mnt/neptune-lentago/claude-jobs
NAME="$(date -u +%Y%m%dT%H%M%SZ)-zz-gate-$ID"
cat > "$J/inbox/$NAME.json.partial" <<JSON
{"prompt": "Read-only check after a worker rebuild. Run exactly these two commands and report their output verbatim, then stop: \`gh pr list --limit 1 --json number --jq length\` and \`git ls-remote origin HEAD\`. Make no changes, create no branch, open no PR.", "project": "claytonia", "model": "haiku", "max_turns": 6, "max_budget_usd": 0.5, "submitter": "claytonia-standing:rebuild-gate"}
JSON
mv "$J/inbox/$NAME.json.partial" "$J/inbox/$NAME.json"
pct exec "$ID" -- systemctl start --no-block claude-inbox.service
echo "queued $NAME; started $HOST's poller"
# The claim prefixes the runid with its own timestamp: <claim>-<NAME>.
for _ in $(seq 1 30); do compgen -G "$J/done/*-$NAME" >/dev/null || compgen -G "$J/failed/*-$NAME" >/dev/null && break; sleep 5; done
ls -d "$J"/done/*-"$NAME" "$J"/failed/*-"$NAME" 2>/dev/null || true
grep -hE '^(runid|exit|duration_sec|model|num_turns|finished)=' "$J"/logs/*-"$NAME".meta 2>/dev/null || true
echo "--- $HOST journal:"
pct exec "$ID" -- journalctl -t claude-runner --since "-5min" --no-pager -o cat | grep -E "$NAME" | grep -E 'START|DONE' | cut -c1-160 || true
