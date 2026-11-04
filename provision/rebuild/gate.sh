#!/usr/bin/env bash
# Gate (provision/README.md § Rebuilding a worker): queue one read-only Haiku job
# and start this worker's poller at once, so that its own poller can claim it.
# Another worker can still win the claim race, so the gate passes only when the
# job is DONE and this worker's journal shows the run. Otherwise it exits 1:
# rerun it. The next worker is rebuilt only after a pass. Runs on pve4 as root.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/gate.sh
set -euo pipefail
ID="${1:?vmid}"
# Act only on a claytonia pool worker, never on another guest.
HOST="$(pct config "$ID" | sed -n 's/^hostname: //p')"
case "$HOST" in claude-runner|claude-runner-[0-9]*) ;; *) echo "CT $ID is '$HOST', not a claude-runner worker: refusing" >&2; exit 1 ;; esac
pvesh get /pools/claytonia --output-format json | grep -Eq "\"vmid\":${ID}[,}]" || { echo "CT $ID is not in the claytonia pool: refusing" >&2; exit 1; }

J=/mnt/neptune-lentago/claude-jobs
NAME="$(date -u +%Y%m%dT%H%M%SZ)-zz-gate-$ID"
cat > "$J/inbox/$NAME.json.partial" <<JSON
{"prompt": "Read-only check after a worker rebuild. Run exactly these two commands and report their output verbatim, then stop: \`gh pr list --limit 1 --json number --jq length\` and \`git ls-remote origin HEAD\`. Make no changes, create no branch, open no PR.", "project": "claytonia", "model": "haiku", "max_turns": 6, "max_budget_usd": 0.5, "submitter": "claytonia-standing:rebuild-gate"}
JSON
mv "$J/inbox/$NAME.json.partial" "$J/inbox/$NAME.json"
pct exec "$ID" -- systemctl start --no-block claude-inbox.service
echo "queued $NAME; started $HOST's poller"

# The claim prefixes the runid with its own timestamp: <claim>-<NAME>.
res=""
for _ in $(seq 1 30); do
  res="$(compgen -G "$J/done/*-$NAME" || compgen -G "$J/failed/*-$NAME" || true)"
  [ -n "$res" ] && break
  sleep 5
done
[ -n "$res" ] || { echo "GATE FAIL: $NAME did not finish within 150 s (still queued or running)" >&2; exit 1; }
runid="$(basename "$res")"
grep -hE '^(runid|exit|duration_sec|model|num_turns|finished)=' "$J/logs/$runid.meta" 2>/dev/null || true
mine="$(pct exec "$ID" -- journalctl -t claude-runner --since "-10min" --no-pager -o cat | grep -F "runid=$runid" | grep -E 'START|DONE' || true)"
echo "--- $HOST journal:"
printf '%s\n' "${mine:-(no run-job lines for $runid)}" | cut -c1-160
case "$res" in
  "$J"/done/*) ;;
  *) echo "GATE FAIL: $runid landed in failed/" >&2; exit 1 ;;
esac
printf '%s\n' "$mine" | grep -q 'run-job DONE' \
  || { echo "GATE FAIL: $runid was DONE on another worker, not $HOST: rerun the gate" >&2; exit 1; }
echo "GATE OK: $runid DONE on $HOST"
