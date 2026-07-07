#!/usr/bin/env bash
# LEGACY / REFERENCE (2026-07-07, #54): run-job/cr-* are gitops-deployed (bin/)
# and the project registry lives on the NAS (runtime state, never baked). Kept
# for provenance, not part of the current build path.
# Add the project registry + per-project context layer + project-aware run-job.
set -euo pipefail

# ----------------------------------------------------------- run-job (v2)
cat > /opt/claude-runner/bin/run-job <<'RUNJOB'
#!/usr/bin/env bash
# run-job <jobfile> — execute ONE Claude job headless and file its output.
# Job = plain text (whole file is the prompt) OR a .json spec:
#   {"prompt":"...", "project":"name", "model":"...", "cwd":"...",
#    "max_turns":N, "allowed_tools":"..."}
# If "project" is set it is resolved via projects/registry.json: a CLEAN checkout
# of the repo is prepared (repo CLAUDE.md applies), per-project memory is loaded,
# and the agent is told to branch + open a PR (never merge).
set -uo pipefail

JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
RUNNER_ROOT=/opt/claude-runner
REGISTRY="$JOBS_ROOT/projects/registry.json"
WORKROOT="${CLAUDE_RUNNER_WORKROOT:-/home/claude/work}"
CLAUDE_BIN="${CLAUDE_BIN:-/home/claude/.local/bin/claude}"

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

prompt=""; cwd="$DEF_CWD"; model="$DEF_MODEL"; max_turns="$DEF_MAXTURNS"; allowed=""; project=""
case "$base" in
  *.json)
    if ! jq -e . "$jobfile" >/dev/null 2>&1; then
      echo "run-job: invalid JSON ($base)" >&2
      mv -f "$jobfile" "$JOBS_ROOT/failed/${runid}.badjson" 2>/dev/null || true
      exit 3
    fi
    prompt="$(jq -r '.prompt // empty' "$jobfile")"
    project="$(jq -r '.project // empty' "$jobfile")"
    c="$(jq -r '.cwd // empty' "$jobfile")";        [ -n "$c" ]  && cwd="$c"
    m="$(jq -r '.model // empty' "$jobfile")";       [ -n "$m" ]  && model="$m"
    mt="$(jq -r '.max_turns // empty' "$jobfile")";  [ -n "$mt" ] && max_turns="$mt"
    allowed="$(jq -r '.allowed_tools // empty' "$jobfile")"
    ;;
  *) prompt="$(cat "$jobfile")" ;;
esac

if [ -z "${prompt// /}" ]; then
  echo "run-job: empty prompt ($base)" >&2
  mv -f "$jobfile" "$JOBS_ROOT/failed/${runid}.emptyprompt" 2>/dev/null || true
  exit 3
fi

mkdir -p "$JOBS_ROOT"/{processing,done,failed,logs} 2>/dev/null || true
proc="$JOBS_ROOT/processing/$runid"
mv "$jobfile" "$proc" 2>/dev/null || exit 0

errlog="$JOBS_ROOT/logs/${runid}.stderr"; : > "$errlog"
repo=""; branch=""; user_prompt="$prompt"

if [ -n "$project" ]; then
  if [ ! -f "$REGISTRY" ] || ! jq -e --arg p "$project" 'has($p)' "$REGISTRY" >/dev/null 2>&1; then
    echo "run-job: unknown project '$project' (not in $REGISTRY)" >>"$errlog"
    mv -f "$proc" "$JOBS_ROOT/failed/$runid" 2>/dev/null || true
    echo "run-job FAIL runid=$runid unknown-project=$project" | systemd-cat -t claude-runner -p err
    exit 4
  fi
  pj="$(jq -c --arg p "$project" '.[$p]' "$REGISTRY")"
  repo="$(printf '%s' "$pj" | jq -r '.repo // empty')"
  branch="$(printf '%s' "$pj" | jq -r '.default_branch // "main"')"
  [ -z "$model" ] && model="$(printf '%s' "$pj" | jq -r '.model // empty')"
  context_dir="$(printf '%s' "$pj" | jq -r '.context_dir // empty')"
  [ -z "$context_dir" ] && context_dir="$JOBS_ROOT/projects/$project"
  setup="$(printf '%s' "$pj" | jq -r '.setup // empty')"

  ckout="$WORKROOT/$project"
  {
    if [ -d "$ckout/.git" ]; then
      git -C "$ckout" fetch --quiet origin "$branch" \
        && git -C "$ckout" reset --hard "origin/$branch" \
        && git -C "$ckout" clean -fd \
        && git -C "$ckout" switch -C "$branch" "origin/$branch"
    else
      rm -rf "$ckout"; git clone --quiet "https://github.com/$repo.git" "$ckout"
    fi
  } >>"$errlog" 2>&1
  if [ ! -d "$ckout/.git" ]; then
    echo "run-job: checkout failed for $repo" >>"$errlog"
    mv -f "$proc" "$JOBS_ROOT/failed/$runid" 2>/dev/null || true
    echo "run-job FAIL runid=$runid checkout-failed repo=$repo" | systemd-cat -t claude-runner -p err
    exit 5
  fi
  cwd="$ckout"

  if tok="$(gh-token 2>>"$errlog")"; then
    printf '%s' "$tok" | gh auth login --with-token >>"$errlog" 2>&1 || true
  fi
  [ -n "$setup" ] && ( cd "$ckout" && bash -lc "$setup" ) >>"$errlog" 2>&1 || true

  mkdir -p "$context_dir"
  memfile="$context_dir/memory.md"
  [ -f "$memfile" ] || printf '# %s — accumulated project memory\n\n_Concise, dated, durable learnings only (conventions, gotchas, build quirks)._\n' "$project" > "$memfile"

  # compose the augmented prompt SAFELY (file contents are never re-expanded)
  ptmp="$(mktemp)"
  {
    printf '# Project: %s (%s)\n\n' "$project" "$repo"
    printf 'You are a headless agent working in a CLEAN git checkout at %s, base branch `%s`. The repo CLAUDE.md is authoritative — read and follow it.\n\n' "$cwd" "$branch"
    printf 'STANDING RULES:\n'
    printf -- '- If the task requires changes: do ALL work on a new branch `agent/<short-kebab-desc>` cut from `%s`; commit with a clear conventional message; `git push -u origin HEAD`; open a PR with `gh pr create` against `%s` for HUMAN review; NEVER merge. For read-only/analysis tasks, no branch or PR is needed.\n' "$branch" "$branch"
    printf -- '- `gh` is pre-authenticated and `git push` is pre-credentialed. If a gh call returns an auth error, run: `gh-token | gh auth login --with-token`.\n'
    printf -- '- If (and only if) you learn something DURABLE about this project (a convention, gotcha, or build quirk), append ONE concise dated bullet to `%s`. Do not log routine task details.\n\n' "$memfile"
    printf '## Accumulated project memory\n\n'
    cat "$memfile"
    printf '\n\n## Your task\n\n'
    printf '%s\n' "$user_prompt"
  } > "$ptmp"
  prompt="$(cat "$ptmp")"; rm -f "$ptmp"
fi

outjson="$JOBS_ROOT/logs/${runid}.json"
outtxt="$JOBS_ROOT/logs/${runid}.txt"
meta="$JOBS_ROOT/logs/${runid}.meta"

args=( -p --dangerously-skip-permissions --output-format json )
[ -n "$model" ]     && args+=( --model "$model" )
[ -n "$max_turns" ] && args+=( --max-turns "$max_turns" )
[ -n "$allowed" ]   && args+=( --allowedTools "$allowed" )

echo "run-job START runid=$runid project=${project:-none} model=${model:-default} cwd=$cwd" | systemd-cat -t claude-runner -p info
start=$(date -u +%s)
( cd "$cwd" && "$CLAUDE_BIN" "${args[@]}" "$prompt" ) >"$outjson" 2>>"$errlog"
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
  echo "project=${project:-}"; echo "repo=${repo:-}"
  echo "model=${model:-default}"; echo "cwd=$cwd"
  echo "cost_usd=${cost}"; echo "num_turns=${turns}"
  echo "finished=$(date -u +%FT%TZ)"
} > "$meta"

if [ "$rc" -eq 0 ]; then
  mv -f "$proc" "$JOBS_ROOT/done/$runid" 2>/dev/null || true
  echo "run-job DONE runid=$runid project=${project:-none} dur=${dur}s cost=${cost:-?}" | systemd-cat -t claude-runner -p info
else
  mv -f "$proc" "$JOBS_ROOT/failed/$runid" 2>/dev/null || true
  echo "run-job FAIL runid=$runid project=${project:-none} rc=$rc dur=${dur}s (logs/${runid}.stderr)" | systemd-cat -t claude-runner -p err
fi
exit "$rc"
RUNJOB

# -------------------------------------------------------- cr-newproject
cat > /opt/claude-runner/bin/cr-newproject <<'NEWPROJ'
#!/usr/bin/env bash
# cr-newproject <name> <owner/repo> [model] [default_branch]
set -euo pipefail
JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
REG="$JOBS_ROOT/projects/registry.json"
name="${1:?usage: cr-newproject <name> <owner/repo> [model] [branch]}"
repo="${2:?usage: cr-newproject <name> <owner/repo> [model] [branch]}"
model="${3:-}"; branch="${4:-main}"
mkdir -p "$JOBS_ROOT/projects/$name"
[ -f "$REG" ] || echo '{}' > "$REG"
tmp="$(mktemp)"
jq --arg n "$name" --arg r "$repo" --arg m "$model" --arg b "$branch" --arg c "$JOBS_ROOT/projects/$name" \
   '.[$n] = {repo:$r, default_branch:$b, model:$m, context_dir:$c, setup:""}' "$REG" > "$tmp" && mv "$tmp" "$REG"
mem="$JOBS_ROOT/projects/$name/memory.md"
[ -f "$mem" ] || printf '# %s — accumulated project memory\n\n_Concise, dated, durable learnings only (conventions, gotchas, build quirks)._\n' "$name" > "$mem"
echo "registered '$name' -> $repo (branch $branch, model ${model:-default})"
jq --arg n "$name" '.[$n]' "$REG"
NEWPROJ

# ------------------------------------------------------------- cr-submit (v2)
cat > /opt/claude-runner/bin/cr-submit <<'CRSUBMIT'
#!/usr/bin/env bash
# cr-submit "prompt"               ad-hoc prompt
# echo "prompt" | cr-submit        from stdin
# cr-submit -p <project> "task"    project job (resolves repo/context/memory)
# cr-submit -f spec.json           queue a copy of a spec (original kept; used by cron)
set -euo pipefail
JOBS_ROOT="${JOBS_ROOT:-/srv/jobs}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$JOBS_ROOT/inbox"
case "${1:-}" in
  -p)
    project="${2:?usage: cr-submit -p <project> \"task\"}"; shift 2
    task="$*"; [ -n "$task" ] || task="$(cat)"
    [ -n "${task// /}" ] || { echo "cr-submit: empty task" >&2; exit 1; }
    dest="$JOBS_ROOT/inbox/${ts}-${project}.json"
    jq -n --arg p "$project" --arg t "$task" '{project:$p, prompt:$t}' > "$dest.partial" && mv "$dest.partial" "$dest"
    echo "queued: $dest (project=$project)" ;;
  -f)
    [ -f "${2:-}" ] || { echo "cr-submit: no such file: ${2:-}" >&2; exit 1; }
    dest="$JOBS_ROOT/inbox/${ts}-$(basename "$2")"
    cp "$2" "$dest.partial" && mv "$dest.partial" "$dest"
    echo "queued: $dest" ;;
  "")
    dest="$JOBS_ROOT/inbox/${ts}-adhoc.txt"
    cat > "$dest.partial" && mv "$dest.partial" "$dest"
    echo "queued: $dest" ;;
  *)
    dest="$JOBS_ROOT/inbox/${ts}-adhoc.txt"
    printf '%s\n' "$*" > "$dest.partial" && mv "$dest.partial" "$dest"
    echo "queued: $dest" ;;
esac
CRSUBMIT

chmod +x /opt/claude-runner/bin/run-job /opt/claude-runner/bin/cr-newproject /opt/claude-runner/bin/cr-submit
ln -sf /opt/claude-runner/bin/cr-newproject /usr/local/bin/cr-newproject
chown -R root:root /opt/claude-runner

# -------------------------- registry + ice-cream-book (as claude, on the NAS)
su - claude -c '
  set -e
  mkdir -p /srv/jobs/projects
  cr-newproject ice-cream-book lentago/ice-cream-book sonnet main
'
echo PROJECTS_SETUP_DONE
