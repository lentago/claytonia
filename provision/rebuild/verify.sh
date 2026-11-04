#!/usr/bin/env bash
# Read-only post-rebuild check for one worker (provision/README.md § Rebuilding a
# worker; first used for claytonia#65). Runs on pve4. Writes nothing to the
# worker's disk (a throwaway HOME for the CLI version checks is removed) and
# prints no secret values.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/verify.sh
set -uo pipefail
ID="${1:?vmid}"; fail=0
# Act only on a claytonia pool worker, never on another guest.
HOST="$(pct config "$ID" | sed -n 's/^hostname: //p')"
case "$HOST" in claude-runner|claude-runner-[0-9]*) ;; *) echo "CT $ID is '$HOST', not a claude-runner worker: refusing" >&2; exit 1 ;; esac
pvesh get /pools/claytonia --output-format json | grep -Eq "\"vmid\":${ID}[,}]" || { echo "CT $ID is not in the claytonia pool: refusing" >&2; exit 1; }
ok(){ echo "OK   $*"; }; bad(){ echo "FAIL $*"; fail=1; }
cfg="$(pct config "$ID")"
HOST="$(sed -n 's/^hostname: //p' <<<"$cfg")"
echo "== CT $ID $HOST"
grep -q '^features: nesting=1' <<<"$cfg" && ok nesting || bad "features: $(grep features <<<"$cfg")"
grep -q '^unprivileged: 1' <<<"$cfg" && ok unprivileged || bad unprivileged
grep -q '^mp0: /mnt/neptune-lentago/claude-jobs,mp=/srv/jobs' <<<"$cfg" && ok mp0 || bad mp0
echo "     $(grep '^net0' <<<"$cfg")"
pvesh get /pools/claytonia --output-format json | grep -q "\"vmid\":$ID" && ok "in pool claytonia" || bad "not in pool"
grep -qx 'RequiresMountsFor=/mnt/neptune-lentago' "/etc/systemd/system/pve-container@$ID.service.d/wait-for-nas.conf" 2>/dev/null && ok drop-in || bad drop-in
pct exec "$ID" -- bash -s <<'IN' || fail=1
f=0; ok(){ echo "OK   $*"; }; bad(){ echo "FAIL $*"; f=1; }
findmnt -n /srv/jobs >/dev/null && ok "/srv/jobs mounted" || bad "/srv/jobs not mounted"
a="/srv/jobs/workers/$(hostname).alive"; age=$(( $(date +%s) - $(stat -c %Y "$a" 2>/dev/null || echo 0) ))
[ "$age" -lt 90 ] && ok "heartbeat ${age}s old" || bad "heartbeat ${age}s old"
[ "$(git -C /opt/claytonia rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] && ok "/opt/claytonia on main" || bad "/opt/claytonia branch"
remote="$(git -C /opt/claytonia ls-remote origin refs/heads/main 2>/dev/null | cut -f1)"
[ -n "$remote" ] && [ "$(git -C /opt/claytonia rev-parse HEAD)" = "$remote" ] && ok "HEAD == origin/main" || bad "HEAD $(git -C /opt/claytonia rev-parse --short HEAD) != origin/main ${remote:0:7}"
for u in claytonia-gitops.timer claude-inbox.timer claude-heartbeat.timer alloy-transcript.service; do
  systemctl is-active -q "$u" && ok "$u active" || bad "$u not active"
done
systemctl is-enabled -q claytonia-gitops.timer && ok "claytonia-gitops.timer enabled" || bad "timer not enabled"
# The transcript shipper's checkout is /opt/drosera since drosera#169.
[ -d /opt/drosera/.git ] && ok "shipper checkout /opt/drosera" || bad "no /opt/drosera shipper checkout"
[ -e /opt/homelab-observability ] && bad "old shipper checkout /opt/homelab-observability present"
# Regression check: the pre-rename names must not come back (a worker cut from an
# old image would carry them).
old=0
for p in /opt/bullpen /usr/local/sbin/bullpen-gitops /etc/systemd/system/bullpen-gitops.service /etc/systemd/system/bullpen-gitops.timer; do
  [ -e "$p" ] && { bad "old name present: $p"; old=1; }
done
[ "$old" = 0 ] && ok "no pre-rename artifacts"
cmp -s /usr/local/sbin/claytonia-gitops /opt/claytonia/gitops/claytonia-gitops.sh && ok "installed loop == checkout" || bad "installed loop differs"
grep -q FATAL /var/log/claytonia-gitops.log 2>/dev/null && bad "FATAL in gitops log" || ok "no FATAL in gitops log"
grep -q 'unit verify reported issues' /var/log/claytonia-gitops.log 2>/dev/null && bad "verify warning still logged" || ok "no verify warning"
for s in token.env:"640 root:claude" google.env:"640 root:claude" gh-app.env:"600 root:root" gh-app.pem:"600 root:root"; do
  n=${s%%:*}; want=${s#*:}
  [ "$(stat -c '%a %U:%G' /etc/claude-runner/$n 2>/dev/null)" = "$want" ] && [ -s /etc/claude-runner/$n ] && ok "secret $n present, $want" || bad "secret $n: $(stat -c '%a %U:%G' /etc/claude-runner/$n 2>&1)"
done
# The peer-runtime credentials (#166), installed by hand on every worker: checked
# when present; until they are installed, their absence is reported, not failed.
for n in gemini.env gemini-sa.json codex.env; do
  if [ -e /etc/claude-runner/$n ]; then
    [ "$(stat -c '%a %U:%G' /etc/claude-runner/$n)" = "640 root:claude" ] && [ -s /etc/claude-runner/$n ] && ok "runtime secret $n present, 640 root:claude" || bad "runtime secret $n: $(stat -c '%a %U:%G %s' /etc/claude-runner/$n)"
  else
    echo "INFO runtime secret $n absent"
  fi
done
# The token broker (#177): sudo grants claude exactly the broker, claude mints through
# it, cannot read the key, and cr-harden has nothing to report.
rule=$(grep -v '^#' /etc/sudoers.d/claude 2>/dev/null)
[ "$rule" = "claude ALL=(root) NOPASSWD: /opt/claude-runner/bin/gh-token" ] && ok "sudoers: only the broker rule" || bad "sudoers: $rule"
g=$(sudo -l -U claude | sed -n '/may run/,$p' | sed 1d | xargs)
[ "$g" = "(root) NOPASSWD: /opt/claude-runner/bin/gh-token" ] && ok "sudo -l -U claude: only the broker" || bad "sudo -l -U claude: $g"
t=$(runuser -u claude -- bash -lc 'gh-token --access read lentago/claytonia' 2>/dev/null); [ "${t:0:4}" = ghs_ ] && ok "claude mints through the broker" || bad "claude cannot mint"
runuser -u claude -- test -r /etc/claude-runner/gh-app.pem && bad "claude can read the App key" || ok "claude cannot read the App key"
runuser -u claude -- sudo -n true 2>/dev/null && bad "claude has other root" || ok "claude has no other root"
[ -s /run/cr-harden.notes ] && bad "cr-harden notes: $(head -c 200 /run/cr-harden.notes)" || ok "cr-harden: no notes"
# Gemini system settings, installed by cr-harden (#205): usage statistics off, root's.
[ "$(stat -c '%U:%G %a' /etc/gemini-cli/settings.json 2>/dev/null)" = "root:root 644" ] \
  && grep -q '"usageStatisticsEnabled":false' /etc/gemini-cli/settings.json \
  && ok "gemini system settings (usage statistics off)" || bad "gemini system settings: $(stat -c '%U:%G %a' /etc/gemini-cli/settings.json 2>&1)"
grep -q 'flock -w' /usr/local/sbin/claytonia-gitops 2>/dev/null && ok "gitops loop waits for its lock (#190)" || bad "gitops loop predates #190"
[ "$(node --version 2>/dev/null | cut -d. -f1)" = v22 ] && ok "node $(node --version)" || bad "node $(node --version 2>&1)"
runuser -u claude -- bash -lc 'claude --version' >/dev/null 2>&1 && ok "claude CLI" || bad "claude CLI"
# The peer-runtime CLIs ship in the runner image from v3 (lentago/kalmia#255). A
# throwaway HOME keeps the version checks from writing CLI state.
h=$(mktemp -d); gv=$(HOME="$h" /usr/bin/gemini --version </dev/null 2>/dev/null); cv=$(HOME="$h" CODEX_HOME="$h" /usr/local/bin/codex --version </dev/null 2>/dev/null); rm -rf "$h"
[ -n "$gv" ] && ok "gemini CLI $gv" || bad "gemini CLI missing"
[ -n "$cv" ] && ok "$cv" || bad "codex CLI missing"
command -v rsync >/dev/null && command -v shellcheck >/dev/null && ok "rsync + shellcheck" || bad "rsync/shellcheck missing"
GH_REPO=lentago/claytonia /opt/claude-runner/bin/gh-token >/dev/null 2>&1 && ok "GitHub App token mints" || bad "gh-token failed"
exit $f
IN
[ "$fail" = 0 ] && echo "== $HOST: ALL OK" || echo "== $HOST: FAILURES ABOVE"
exit "$fail"
