#!/usr/bin/env bash
# R-1 (provision/README.md § Rebuilding a worker): read-only. Report every git
# clone under the claude user's ~/work and ~/private that holds local-only state
# (dirty files, unpushed commits, stashes), so it can be archived as patches under
# /srv/jobs/archive/rebuild-<host>/ before the rebuild deletes it. Runs on pve4 as
# root; the check itself runs as claude inside the CT.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/r1-unpushed.sh
set -euo pipefail
ID="${1:?vmid}"
echo "R-1 on CT $ID ($(pct config "$ID" | sed -n 's/^hostname: //p'))"
pct exec "$ID" -- runuser -u claude -- bash -s <<'UNPUSHED'
set +e
cd /home/claude || exit 0
n=0; flagged=0
for g in $(find work private -maxdepth 4 -name .git -type d 2>/dev/null); do
  r=${g%/.git}; n=$((n+1))
  dirty=$(git -C "$r" status --porcelain 2>/dev/null | wc -l)
  ahead=$(git -C "$r" log --branches --not --remotes --oneline 2>/dev/null | wc -l)
  stash=$(git -C "$r" stash list 2>/dev/null | wc -l)
  last=$(git -C "$r" log -1 --format=%cs 2>/dev/null)
  if [ "$dirty" -gt 0 ] || [ "$ahead" -gt 0 ] || [ "$stash" -gt 0 ]; then
    flagged=$((flagged+1))
    echo "  $r  dirty=$dirty unpushed-commits=$ahead stashes=$stash last=$last origin=$(git -C "$r" remote get-url origin 2>/dev/null | sed 's#https://[^@]*@#https://#')"
  fi
done
echo "  clones=$n flagged=$flagged"
UNPUSHED
