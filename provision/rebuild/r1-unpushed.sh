#!/usr/bin/env bash
# R-1 (provision/README.md § Rebuilding a worker): read-only. Report every git
# clone under the claude user's ~/work and ~/private that holds local-only state
# (dirty files, unpushed commits, stashes), so it can be archived as patches under
# /srv/jobs/archive/rebuild-<host>/ before the rebuild deletes it. Runs on pve4 as
# root; the check itself runs as claude inside the CT.
#   ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/r1-unpushed.sh
set -euo pipefail
ID="${1:?vmid}"
# Act only on a claytonia pool worker, never on another guest.
HOST="$(pct config "$ID" | sed -n 's/^hostname: //p')"
case "$HOST" in claude-runner|claude-runner-[0-9]*) ;; *) echo "CT $ID is '$HOST', not a claude-runner worker: refusing" >&2; exit 1 ;; esac
pvesh get /pools/claytonia --output-format json | grep -Eq "\"vmid\":${ID}[,}]" || { echo "CT $ID is not in the claytonia pool: refusing" >&2; exit 1; }
echo "R-1 on CT $ID ($HOST)"
pct exec "$ID" -- runuser -u claude -- bash -s <<'UNPUSHED'
set +e
cd /home/claude || { echo "  no /home/claude in this CT: nothing checked" >&2; exit 1; }
n=0; flagged=0
while IFS= read -r -d '' g; do
  r=${g%/.git}; n=$((n+1))
  dirty=$(git -C "$r" status --porcelain 2>/dev/null | wc -l)
  ahead=$(git -C "$r" log --branches --not --remotes --oneline 2>/dev/null | wc -l)
  stash=$(git -C "$r" stash list 2>/dev/null | wc -l)
  last=$(git -C "$r" log -1 --format=%cs 2>/dev/null)
  # Gitignored files (build output, local .env) are not work product and are not
  # flagged, but the rebuild deletes them too, so their count is shown.
  ign=$(git -C "$r" status --porcelain --ignored 2>/dev/null | grep -c '^!!')
  if [ "$dirty" -gt 0 ] || [ "$ahead" -gt 0 ] || [ "$stash" -gt 0 ]; then
    flagged=$((flagged+1))
    echo "  $r  dirty=$dirty unpushed-commits=$ahead stashes=$stash ignored=$ign last=$last origin=$(git -C "$r" remote get-url origin 2>/dev/null | sed 's#https://[^@]*@#https://#')"
  elif [ "$ign" -gt 0 ]; then
    echo "  INFO $r  ignored=$ign (not flagged)"
  fi
done < <(find work private -maxdepth 4 -name .git -type d -print0 2>/dev/null)
echo "  clones=$n flagged=$flagged"
UNPUSHED
