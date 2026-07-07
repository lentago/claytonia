#!/usr/bin/env bash
# LEGACY / REFERENCE (2026-07-07, #54): the runner software this installs is
# deployed by the gitops loop (bin/ + systemd/ + cron/); a from-image worker
# gets it that way. Kept for provenance, not part of the current build path.
# Installs the Claude job-runner (core + poller + cron surface) inside the container.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">>> ensure cron present"
dpkg -s cron >/dev/null 2>&1 || apt-get install -y -qq cron >/dev/null
systemctl enable --now cron >/dev/null 2>&1 || true

mkdir -p /opt/claude-runner/bin /opt/claude-runner/etc /etc/claude-runner
install -d -o claude -g claude /home/claude/work

# ---------------------------------------------------------------- run-job
cat > /opt/claude-runner/bin/run-job <<'RUNJOB'
#!/usr/bin/env bash
# run-job <jobfile> — execute ONE Claude job headless and file its output.
# A jobfile is either plain text (the whole file is the prompt) or a .json spec:
#   {"prompt":"...", "cwd":"/path", "model":"opus|sonnet|haiku", "max_turns":N, "allowed_tools":"Read Bash", "label":"name"}
set -uo pipefail

JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
RUNNER_ROOT=/opt/claude-runner
CLAUDE_BIN="${CLAUDE_BIN:-/home/claude/.local/bin/claude}"

# config (non-secret) then token (secret)
[ -f "$RUNNER_ROOT/etc/runner.env" ] && . "$RUNNER_ROOT/etc/runner.env"
[ -f /etc/claude-runner/token.env ] && . /etc/claude-runner/token.env
export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
export HOME="${HOME:-/home/claude}"
export PATH="/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin"

DEF_MODEL="${CLAUDE_RUNNER_MODEL:-}"
DEF_CWD="${CLAUDE_RUNNER_CWD:-/home/claude/work}"
DEF_MAXTURNS="${CLAUDE_RUNNER_MAX_TURNS:-}"

jobfile="${1:-}"
[ -n "$jobfile" ] && [ -f "$jobfile" ] || { echo "run-job: no such jobfile: $jobfile" >&2; exit 2; }

base="$(basename "$jobfile")"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
label="$(printf '%s' "${base%.*}" | tr -c 'A-Za-z0-9._-' '_')"
runid="${ts}-${label}"

prompt=""; cwd="$DEF_CWD"; model="$DEF_MODEL"; max_turns="$DEF_MAXTURNS"; allowed=""
case "$base" in
  *.json)
    if ! jq -e . "$jobfile" >/dev/null 2>&1; then
      echo "run-job: invalid JSON in $base" >&2
      mv -f "$jobfile" "$JOBS_ROOT/failed/${runid}.badjson" 2>/dev/null || true
      exit 3
    fi
    prompt="$(jq -r '.prompt // empty' "$jobfile")"
    c="$(jq -r '.cwd // empty' "$jobfile")";          [ -n "$c" ] && cwd="$c"
    m="$(jq -r '.model // empty' "$jobfile")";         [ -n "$m" ] && model="$m"
    mt="$(jq -r '.max_turns // empty' "$jobfile")";    [ -n "$mt" ] && max_turns="$mt"
    allowed="$(jq -r '.allowed_tools // empty' "$jobfile")"
    ;;
  *)
    prompt="$(cat "$jobfile")"
    ;;
esac

if [ -z "${prompt// /}" ]; then
  echo "run-job: empty prompt ($base)" >&2
  mv -f "$jobfile" "$JOBS_ROOT/failed/${runid}.emptyprompt" 2>/dev/null || true
  exit 3
fi

mkdir -p "$JOBS_ROOT"/{processing,done,failed,logs} 2>/dev/null || true
mkdir -p "$cwd" 2>/dev/null || cwd="$HOME"

# atomically claim the job (skip if another worker grabbed it)
proc="$JOBS_ROOT/processing/$runid"
mv "$jobfile" "$proc" 2>/dev/null || exit 0

outjson="$JOBS_ROOT/logs/${runid}.json"
outtxt="$JOBS_ROOT/logs/${runid}.txt"
errlog="$JOBS_ROOT/logs/${runid}.stderr"
meta="$JOBS_ROOT/logs/${runid}.meta"

args=( -p --dangerously-skip-permissions --output-format json )
[ -n "$model" ]     && args+=( --model "$model" )
[ -n "$max_turns" ] && args+=( --max-turns "$max_turns" )
[ -n "$allowed" ]   && args+=( --allowedTools "$allowed" )

echo "run-job START runid=$runid model=${model:-default} cwd=$cwd" | systemd-cat -t claude-runner -p info
start=$(date -u +%s)
( cd "$cwd" && "$CLAUDE_BIN" "${args[@]}" "$prompt" ) >"$outjson" 2>"$errlog"
rc=$?
dur=$(( $(date -u +%s) - start ))

cost=""; turns=""
if jq -e . "$outjson" >/dev/null 2>&1; then
  jq -r '.result // .text // ""' "$outjson" > "$outtxt" 2>/dev/null || true
  [ "$(jq -r '.is_error // false' "$outjson" 2>/dev/null)" = "true" ] && rc=1
  cost="$(jq -r '.total_cost_usd // empty' "$outjson" 2>/dev/null)"
  turns="$(jq -r '.num_turns // empty' "$outjson" 2>/dev/null)"
else
  cp "$outjson" "$outtxt" 2>/dev/null || true
fi

{
  echo "runid=$runid"; echo "exit=$rc"; echo "duration_sec=$dur"
  echo "model=${model:-default}"; echo "cwd=$cwd"
  echo "cost_usd=${cost}"; echo "num_turns=${turns}"
  echo "finished=$(date -u +%FT%TZ)"
} > "$meta"

if [ "$rc" -eq 0 ]; then
  mv -f "$proc" "$JOBS_ROOT/done/$runid" 2>/dev/null || true
  echo "run-job DONE runid=$runid dur=${dur}s cost=${cost:-?}" | systemd-cat -t claude-runner -p info
else
  mv -f "$proc" "$JOBS_ROOT/failed/$runid" 2>/dev/null || true
  echo "run-job FAIL runid=$runid rc=$rc dur=${dur}s (see logs/${runid}.stderr)" | systemd-cat -t claude-runner -p err
fi
exit "$rc"
RUNJOB

# ------------------------------------------------------------ process-inbox
cat > /opt/claude-runner/bin/process-inbox <<'PROCINBOX'
#!/usr/bin/env bash
# process-inbox — run every pending inbox job, one at a time. flock-guarded.
# Polled by claude-inbox.timer (CIFS-safe; inotify can't see remote SMB writes).
set -uo pipefail
JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
BIN=/opt/claude-runner/bin
[ -d "$JOBS_ROOT/inbox" ] || exit 0
exec 9>/tmp/claude-inbox.lock
flock -n 9 || exit 0
shopt -s nullglob
while :; do
  pending=()
  for f in "$JOBS_ROOT/inbox"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .*|*.partial|*.tmp|*.swp) continue;; esac
    pending+=( "$f" )
  done
  [ ${#pending[@]} -eq 0 ] && break
  for f in "${pending[@]}"; do
    "$BIN/run-job" "$f" || true
  done
done
PROCINBOX

# ---------------------------------------------------------------- cr-submit
cat > /opt/claude-runner/bin/cr-submit <<'CRSUBMIT'
#!/usr/bin/env bash
# cr-submit "prompt"            queue an ad-hoc prompt
# echo "prompt" | cr-submit     queue from stdin
# cr-submit -f spec.json        queue a copy of a job spec (original kept — used by cron)
set -euo pipefail
JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$JOBS_ROOT/inbox"
if [ "${1:-}" = "-f" ]; then
  [ -f "${2:-}" ] || { echo "cr-submit: no such file: ${2:-}" >&2; exit 1; }
  dest="$JOBS_ROOT/inbox/${ts}-$(basename "$2")"
  cp "$2" "$dest.partial" && mv "$dest.partial" "$dest"
elif [ -n "${1:-}" ]; then
  dest="$JOBS_ROOT/inbox/${ts}-adhoc.txt"
  printf '%s\n' "$*" > "$dest.partial" && mv "$dest.partial" "$dest"
else
  dest="$JOBS_ROOT/inbox/${ts}-adhoc.txt"
  cat > "$dest.partial" && mv "$dest.partial" "$dest"
fi
echo "queued: $dest"
CRSUBMIT

# ----------------------------------------------------------- claude-set-token
cat > /opt/claude-runner/bin/claude-set-token <<'SETTOKEN'
#!/usr/bin/env bash
# claude-set-token — store the OAuth token from `claude setup-token` securely.
# Run `claude setup-token` first, copy the printed token, then run this and paste it.
set -euo pipefail
DEST=/etc/claude-runner/token.env
printf 'Paste the OAuth token from `claude setup-token`, then Enter: ' >&2
read -rs TOKEN; echo >&2
[ -n "$TOKEN" ] || { echo "no token provided" >&2; exit 1; }
umask 077
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN" | sudo tee "$DEST" >/dev/null
sudo chown root:claude "$DEST"; sudo chmod 640 "$DEST"
echo "stored in $DEST (root:claude 640), token length ${#TOKEN}" >&2
SETTOKEN

# ---------------------------------------------------------------- runner.env
cat > /opt/claude-runner/etc/runner.env <<'RUNNERENV'
# Claude runner config (non-secret). Sourced by run-job.
# Default model for jobs that don't specify one (blank = account default).
CLAUDE_RUNNER_MODEL=
# Default working directory for jobs.
CLAUDE_RUNNER_CWD=/home/claude/work
# Default cap on agentic turns per job (blank = unlimited). Bounds runaway cost.
CLAUDE_RUNNER_MAX_TURNS=
RUNNERENV

# ------------------------------------------------------------ systemd poller
cat > /etc/systemd/system/claude-inbox.service <<'SVC'
[Unit]
Description=Process the Claude job inbox (one-shot)
ConditionPathIsDirectory=/srv/jobs/inbox

[Service]
Type=oneshot
User=claude
Group=claude
Nice=5
ExecStart=/opt/claude-runner/bin/process-inbox
SVC

cat > /etc/systemd/system/claude-inbox.timer <<'TIMER'
[Unit]
Description=Poll the Claude job inbox (CIFS-safe trigger)

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=2s

[Install]
WantedBy=timers.target
TIMER

# -------------------------------------------------------------------- cron
cat > /etc/cron.d/claude-runner <<'CRON'
# Scheduled Claude jobs. Put a spec in /srv/jobs/scheduled/<name>.json (or .txt),
# then add a line here that re-queues it into the inbox on a schedule:
#
#   m  h dom mon dow  claude  /opt/claude-runner/bin/cr-submit -f /srv/jobs/scheduled/<name>.json
#
# Example — 7am daily Lentago lab health summary:
# 0  7  *   *   *     claude  /opt/claude-runner/bin/cr-submit -f /srv/jobs/scheduled/daily-health.json
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
CRON

chmod +x /opt/claude-runner/bin/*
chown -R root:root /opt/claude-runner
for f in run-job process-inbox cr-submit claude-set-token; do
  ln -sf /opt/claude-runner/bin/$f /usr/local/bin/$f
done

# placeholder token file so run-job can source it before the real token is set
if [ ! -f /etc/claude-runner/token.env ]; then
  echo 'CLAUDE_CODE_OAUTH_TOKEN=' > /etc/claude-runner/token.env
  chown root:claude /etc/claude-runner/token.env
  chmod 640 /etc/claude-runner/token.env
fi

systemctl daemon-reload
systemctl enable --now claude-inbox.timer >/dev/null 2>&1
echo SETUP_DONE
systemctl is-active claude-inbox.timer
ls -la /opt/claude-runner/bin/
