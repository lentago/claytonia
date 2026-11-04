#!/usr/bin/env bash
# R-4..R-6 (provision/README.md § Rebuilding a worker; first used for claytonia#65,
# App key modes per #177): after the CI apply recreated a worker, restore its
# secrets, THEN attach the NAS (a fresh worker with the mount but an empty
# token.env would claim jobs and fail them), fix the host drop-in, reboot, and
# reinstall the transcript shipper. Runs on pve4 as root.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/r4-r6-restore.sh
set -euo pipefail
ID="${1:?vmid}"
D="/root/rebuild-$ID"
[ -d "$D" ] || { echo "no staged secrets at $D (R-2 not run?)" >&2; exit 1; }
pct status "$ID" | grep -q running || { echo "CT $ID is not running" >&2; exit 1; }
pct exec "$ID" -- test -d /opt/claytonia || { echo "CT $ID has no /opt/claytonia: not a rebuilt worker?" >&2; exit 1; }
G="$(pct exec "$ID" -- id -g claude)"

echo ">>> R-4 secrets (token.env, google.env and the peer-runtime files 640 root:claude; gh-app.* 600 root:root, #177)"
for f in token.env google.env; do
  pct push "$ID" "$D/$f" "/etc/claude-runner/$f" --perms 640 --user 0 --group "$G"
done
# The peer-runtime credentials (#166) go back only if R-2 staged them.
for f in gemini.env gemini-sa.json codex.env; do
  [ -f "$D/$f" ] || continue
  pct push "$ID" "$D/$f" "/etc/claude-runner/$f" --perms 640 --user 0 --group "$G"
done
for f in gh-app.env gh-app.pem; do
  pct push "$ID" "$D/$f" "/etc/claude-runner/$f" --perms 600 --user 0 --group 0
done
pct push "$ID" "$D/alloy-transcript" /etc/default/alloy-transcript --perms 640 --user 0 --group "$G"

echo ">>> R-4b the image's blanket sudoers rule must be gone before the worker can claim (#177)"
# cr-harden (cron, every minute) narrows it; the NAS mount below is what lets the
# worker claim jobs, so it waits for that, up to 2 minutes.
RULE='claude ALL=(root) NOPASSWD: /opt/claude-runner/bin/gh-token'
for _ in $(seq 1 24); do
  [ "$(pct exec "$ID" -- grep -v '^#' /etc/sudoers.d/claude)" = "$RULE" ] && break
  sleep 5
done
[ "$(pct exec "$ID" -- grep -v '^#' /etc/sudoers.d/claude)" = "$RULE" ] \
  || { echo "sudoers not narrowed after 2 min (cr-harden has not run): stopping before the NAS mount" >&2; exit 1; }
echo "sudoers: only the broker rule"

echo ">>> R-5 NAS bind mount + host drop-in"
pct set "$ID" -mp0 /mnt/neptune-lentago/claude-jobs,mp=/srv/jobs
install -d "/etc/systemd/system/pve-container@$ID.service.d"
printf '[Unit]\nRequiresMountsFor=/mnt/neptune-lentago\n' \
  > "/etc/systemd/system/pve-container@$ID.service.d/wait-for-nas.conf"
systemctl daemon-reload
pct reboot "$ID"
for _ in $(seq 1 30); do pct exec "$ID" -- getent hosts github.com >/dev/null 2>&1 && break; sleep 2; done
pct exec "$ID" -- findmnt -n /srv/jobs >/dev/null || { echo "/srv/jobs not mounted after reboot" >&2; exit 1; }

echo ">>> R-6 transcript shipper (reads the restored /etc/default/alloy-transcript)"
pct exec "$ID" -- /opt/claytonia/provision/06-transcript-shipper.sh

shred -u "$D"/* && rmdir "$D"
echo "$(date -u +%FT%TZ) restored CT $ID; staging shredded. Tell Claude to verify."
