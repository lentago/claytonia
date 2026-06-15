#!/usr/bin/env bash
# bullpen-gitops.sh — pull origin/main and redeploy to THIS worker, but only
# when the deployed files have actually drifted. Bootstrap-installed by
# gitops/install.sh; runs as root from bullpen-gitops.timer (every 5 min).
#
# Deploys: bin/ -> /opt/claude-runner/bin, systemd/ -> /etc/systemd/system,
#          cron/claude-runner -> /etc/cron.d, etc/runner.env -> /opt/claude-runner/etc.
# Does NOT manage its own units (bullpen-gitops.*) — those are bootstrap-only,
# so a broken update can't leave the worker unable to fix itself.
set -uo pipefail

REPO_DIR="${BULLPEN_REPO_DIR:-/opt/bullpen}"
LOG="${BULLPEN_LOG:-/var/log/bullpen-gitops.log}"
exec 9>/tmp/bullpen-gitops.lock; flock -n 9 || exit 0
log(){ echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1000000 ] && mv -f "$LOG" "$LOG.1"

cd "$REPO_DIR" 2>/dev/null || { log "no repo at $REPO_DIR"; exit 1; }
br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$br" = main ] || { log "on '$br', not main — refusing to deploy"; exit 0; }
git fetch --quiet origin main || { log "git fetch failed"; exit 1; }
local_sha="$(git rev-parse HEAD)"; remote_sha="$(git rev-parse origin/main)"
[ "$local_sha" = "$remote_sha" ] && exit 0          # no change — silent no-op
log "update ${local_sha:0:8} -> ${remote_sha:0:8}"
git reset --hard --quiet origin/main || { log "git reset failed"; exit 1; }

# Validate before deploying — a broken script must not reach the worker.
for s in bin/*; do
  bash -n "$s" 2>>"$LOG" || { log "FATAL bash -n failed: $s — aborting deploy"; exit 1; }
done
systemd-analyze verify systemd/*.service systemd/*.timer 2>>"$LOG" || log "warn: unit verify reported issues"

changed=0; units_changed=0
deploy(){ # <src> <dst> <mode>
  cmp -s "$1" "$2" 2>/dev/null && return 0
  install -D -m "$3" "$1" "$2" && { changed=1; log "deployed $2"; }
  case "$2" in /etc/systemd/system/*) units_changed=1;; esac
}
for f in bin/*;    do deploy "$f" "/opt/claude-runner/bin/$(basename "$f")" 755; done
for f in systemd/*; do deploy "$f" "/etc/systemd/system/$(basename "$f")" 644; done
deploy cron/claude-runner    /etc/cron.d/claude-runner          644
deploy etc/runner.env        /opt/claude-runner/etc/runner.env  644

for f in run-job process-inbox cr-submit cr-newproject cr-emit gh-token gh-credential-helper claude-set-token; do
  ln -sf "/opt/claude-runner/bin/$f" "/usr/local/bin/$f"
done

if [ "$units_changed" = 1 ]; then
  systemctl daemon-reload
  systemctl restart claude-inbox.timer claude-heartbeat.timer 2>>"$LOG" || true
  log "systemd daemon-reloaded + timers restarted"
fi
[ "$changed" = 1 ] && log "deploy complete" || log "fetched new commit but no file drift"
