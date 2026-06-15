#!/usr/bin/env bash
# Reaper + heartbeats for at-least-once delivery. Deploy on every worker.
set -euo pipefail

# --------------------------------------------------- heartbeat (per worker)
cat > /etc/systemd/system/claude-heartbeat.service <<'SVC'
[Unit]
Description=Claude worker liveness heartbeat
ConditionPathIsDirectory=/srv/jobs

[Service]
Type=oneshot
User=claude
Group=claude
ExecStart=/bin/sh -c 'mkdir -p /srv/jobs/workers && touch /srv/jobs/workers/$(hostname).alive'
SVC

cat > /etc/systemd/system/claude-heartbeat.timer <<'TIMER'
[Unit]
Description=Claude worker heartbeat (every 30s)

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
AccuracySec=2s

[Install]
WantedBy=timers.target
TIMER

# --------------------------------------- run-job: claim ownership + cleanup
# Insert owner-file write right after the atomic claim.
if ! grep -q 'proc.owner' /opt/claude-runner/bin/run-job; then
  perl -0777 -pi -e 's{(mv "\$jobfile" "\$proc" 2>/dev/null \|\| exit 0\n)}{$1printf '\''owner=%s\nstarted=%s\norigname=%s\n'\'' "\$(hostname)" "\$(date -u +%s)" "\$base" > "\$proc.owner" 2>/dev/null || true\n}' /opt/claude-runner/bin/run-job
  # Remove the owner file once the job is filed (just before the emit/exit tail).
  perl -0777 -pi -e 's{(\ncr-emit "\$runid" 2>/dev/null \|\| true\n)}{\nrm -f "\$proc.owner" 2>/dev/null || true$1}' /opt/claude-runner/bin/run-job
fi

# --------------------------------------------- process-inbox: reap then run
cat > /opt/claude-runner/bin/process-inbox <<'PROCINBOX'
#!/usr/bin/env bash
# process-inbox — reap stranded jobs (dead-worker recovery), then run every
# pending inbox job, one at a time. flock-guarded (CIFS-safe; polled).
set -uo pipefail
JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
BIN=/opt/claude-runner/bin
HEARTBEAT_STALE="${CLAUDE_HEARTBEAT_STALE:-90}"   # worker dead if .alive older than this
[ -d "$JOBS_ROOT/inbox" ] || exit 0
exec 9>/tmp/claude-inbox.lock
flock -n 9 || exit 0
shopt -s nullglob

reap() {
  local now of runid job owner alive age origname ext
  now="$(date -u +%s)"
  for of in "$JOBS_ROOT"/processing/*.owner; do
    [ -f "$of" ] || continue
    runid="$(basename "$of" .owner)"
    job="$JOBS_ROOT/processing/$runid"
    if [ ! -f "$job" ]; then rm -f "$of"; continue; fi   # job already filed; stray owner
    owner="$(sed -n 's/^owner=//p' "$of" 2>/dev/null)"
    origname="$(sed -n 's/^origname=//p' "$of" 2>/dev/null)"
    alive="$JOBS_ROOT/workers/${owner}.alive"
    if [ -n "$owner" ] && [ -f "$alive" ]; then
      age=$(( now - $(stat -c %Y "$alive" 2>/dev/null || echo "$now") ))
    else
      age=999999
    fi
    [ "$age" -le "$HEARTBEAT_STALE" ] && continue        # owner still alive -> leave it

    # owner is dead -> reclaim. Preserve original extension; cap at one retry.
    ext="${origname##*.}"; { [ -z "$ext" ] || [ "$ext" = "$origname" ]; } && ext="txt"
    case "$runid" in
      *.retry)
        mv -f "$job" "$JOBS_ROOT/failed/${runid}.stranded" 2>/dev/null && rm -f "$of"
        echo "reaper: $runid stranded twice (owner=$owner dead) -> failed" | systemd-cat -t claude-runner -p err
        ;;
      *)
        if mv "$job" "$JOBS_ROOT/inbox/${runid}.retry.${ext}" 2>/dev/null; then
          rm -f "$of"
          echo "reaper: requeued $runid (owner=$owner dead) as ${runid}.retry.${ext}" | systemd-cat -t claude-runner -p warning
        fi
        ;;
    esac
  done
}

reap

while :; do
  pending=()
  for f in "$JOBS_ROOT/inbox"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .*|*.partial|*.tmp|*.swp|*.owner) continue;; esac
    pending+=( "$f" )
  done
  [ ${#pending[@]} -eq 0 ] && break
  for f in "${pending[@]}"; do "$BIN/run-job" "$f" || true; done
done
PROCINBOX
chmod +x /opt/claude-runner/bin/process-inbox

# workers dir on the NAS (shared) + enable heartbeat
su - claude -c 'mkdir -p /srv/jobs/workers' 2>/dev/null || mkdir -p /srv/jobs/workers
systemctl daemon-reload
systemctl enable --now claude-heartbeat.timer >/dev/null 2>&1

echo "=== verify run-job owner hooks ==="
grep -c 'proc.owner' /opt/claude-runner/bin/run-job
echo "=== heartbeat ==="
systemctl is-active claude-heartbeat.timer
echo DONE
