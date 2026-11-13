#!/usr/bin/env bats
#
# Live-transcript links (#239), the claytonia half of lentago/drosera#305. The worker
# transcript shipper reads Gemini and Codex sessions only through links at
#   <live root>/<runtime>/<project>/<runid>/<session_id>.jsonl -> the native session file
# (drosera ADR-0012), so what run-job links is what ships. A link written for a
# private project would ship its narration, so these pin, through the real run-job
# and process-inbox: each peer runtime links its own session file at the contract
# path; nothing outside the public workroot is linked, however the cwd is spelled;
# Claude is never linked (its transcript ships from its own path); and the sweep
# removes a finished job's links after the grace period and never a session file.

load test_helper

TID=0f0f0f0f-0000-7000-8000-00000000c0de   # the thread id the Codex stub mints

eval "helper_$(declare -f setup)"
setup() {
  helper_setup
  unset XDG_STATE_HOME XDG_CACHE_HOME CODEX_HOME CODEX_API_KEY CODEX_ACCESS_TOKEN
  LIVE="$CLAUDE_RUNNER_LIVE_ROOT"
  # The public workroot, which is also where ad-hoc jobs run (as on a worker, where
  # CLAUDE_RUNNER_CWD is the workroot), and the private one beside it.
  export CLAUDE_RUNNER_WORKROOT="$TEST_TMP/wr" CLAUDE_RUNNER_PRIVATE_WORKROOT="$TEST_TMP/private"
  export CLAUDE_RUNNER_CWD="$CLAUDE_RUNNER_WORKROOT"
  mkdir -p "$CLAUDE_RUNNER_WORKROOT" "$CLAUDE_RUNNER_PRIVATE_WORKROOT" "$JOBS_ROOT/projects"
  export GIT_ALLOW_PROTOCOL=file   # a stray clone fails fast instead of reaching GitHub

  # The peer runtimes' stubs and throwaway credentials, as their own suites set them.
  export GEMINI_BIN="$STUBS_DIR/gemini" CLAUDE_RUNNER_GEMINI_ENV="$TEST_TMP/gemini.env"
  export CODEX_BIN="$STUBS_DIR/codex" CLAUDE_RUNNER_CODEX_ENV="$TEST_TMP/codex.env"
  printf 'GOOGLE_GENAI_USE_VERTEXAI=true\n' > "$CLAUDE_RUNNER_GEMINI_ENV"
  printf 'OPENAI_API_KEY=sk-live-links-test\n' > "$CLAUDE_RUNNER_CODEX_ENV"
  export FAKE_GEMINI_SESSION=1   # the Gemini stub writes its session file, as 0.66 does

  # A local origin, a public project checked out under the workroot and a private one
  # under the private root, so project jobs check out with no network.
  git init -q --bare -b main "$TEST_TMP/origin.git"
  for d in "$CLAUDE_RUNNER_WORKROOT/pub" "$CLAUDE_RUNNER_PRIVATE_WORKROOT/priv"; do
    git clone -q "$TEST_TMP/origin.git" "$d" 2>/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$d" push -q origin HEAD:main 2>/dev/null || true
  done
  cat > "$JOBS_ROOT/projects/registry.json" <<'EOF'
{"pub":  {"repo":"acme/pub","default_branch":"main"},
 "priv": {"repo":"acme/priv","default_branch":"main","offbox_transcript":false}}
EOF
}

drop_spec() { # <name> <json>
  printf '%s\n' "$2" > "$JOBS_ROOT/inbox/.$1.partial"
  mv "$JOBS_ROOT/inbox/.$1.partial" "$JOBS_ROOT/inbox/$1"
}
runid_of() { basename "$(find "$JOBS_ROOT/logs" -name "*-$1.meta" | head -1)" .meta; }
meta_of() { sed -n "s/^$2=//p" "$JOBS_ROOT/logs/$1.meta"; }
links() { find "$LIVE" -type l 2>/dev/null | sort; }

# codex_session — the session file Codex 0.166 keeps for the stub's thread.
codex_session() {
  local d="$HOME/.codex/sessions/2026/11/13"
  mkdir -p "$d"
  printf '%s\n' '{"type":"session_meta","payload":{"id":"x"}}' > "$d/rollout-2026-11-13T00-00-00-$TID.jsonl"
  printf '%s' "$d/rollout-2026-11-13T00-00-00-$TID.jsonl"
}

@test "a Gemini project job links its own session file at the contract path" {
  drop_spec "lg.json" '{"prompt":"go","project":"pub","runtime":"gemini"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  r="$(runid_of lg)"; sid="$(meta_of "$r" session_id)"
  link="$LIVE/gemini/pub/$r/$sid.jsonl"
  [ -L "$link" ]
  [ "$(links)" = "$link" ]
  # It points at the run's own session file: Gemini's sessionId on its first line.
  [ "$(head -n 1 "$link" | jq -r .sessionId)" = "$sid" ]
  [[ "$(readlink "$link")" == "$HOME/.local/state/claytonia/gemini/$sid/.gemini/tmp/pub/chats/session-"*"-${sid:0:8}.jsonl" ]]
  [ "$(stat -c %U "$link")" = "$(id -un)" ]   # the runner's own user (claude on a worker)
}

@test "a Codex ad-hoc job links under adhoc, named by Codex's own thread id" {
  native="$(codex_session)"
  drop_spec "lx.json" '{"prompt":"go","runtime":"codex"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  r="$(runid_of lx)"
  link="$LIVE/codex/adhoc/$r/$TID.jsonl"
  [ "$(links)" = "$link" ]
  [ "$(readlink "$link")" = "$native" ]
}

@test "the link outlives the job, so the shipper can read its last lines" {
  codex_session >/dev/null
  drop_spec "lo.json" '{"prompt":"go","runtime":"codex"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$(links | wc -l)" -eq 1 ]
  # The next poll, inside the grace period, keeps it.
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(links | wc -l)" -eq 1 ]
}

@test "an offbox_transcript: false project links nothing" {
  drop_spec "lp.json" '{"prompt":"go","project":"priv","runtime":"gemini"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  grep -qx "cwd=$CLAUDE_RUNNER_PRIVATE_WORKROOT/priv" "$JOBS_ROOT/logs/$(runid_of lp).meta"
  # The session file exists; it is just never linked.
  [ -n "$(find "$HOME/.local/state/claytonia/gemini" -name 'session-*.jsonl')" ]
  [ -z "$(links)" ]
  [ ! -e "$LIVE/gemini/priv" ]
}

@test "a cwd outside the public workroot links nothing, a .. or a symlink included" {
  mkdir -p "$CLAUDE_RUNNER_PRIVATE_WORKROOT/x" "$TEST_TMP/elsewhere" "$CLAUDE_RUNNER_WORKROOT-sibling"
  ln -s "$CLAUDE_RUNNER_PRIVATE_WORKROOT/x" "$CLAUDE_RUNNER_WORKROOT/sneaky"
  n=0
  for cwd in "$TEST_TMP/elsewhere" "$CLAUDE_RUNNER_WORKROOT/../private/x" \
             "$CLAUDE_RUNNER_WORKROOT/sneaky" "$CLAUDE_RUNNER_WORKROOT-sibling"; do
    n=$((n + 1))
    drop_spec "lc$n.json" "$(jq -cn --arg c "$cwd" '{prompt: "go", runtime: "gemini", cwd: $c}')"
  done
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 4 ]
  [ -z "$(links)" ]
}

@test "a Claude job links nothing: its transcript ships from its own path" {
  drop_spec "lcl.json" '{"prompt":"go","project":"pub"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  [ -z "$(links)" ]
}

@test "the sweep removes run directories idle past the grace period, keeps fresh ones, and never a session file" {
  target="$TEST_TMP/native.jsonl"; printf '{}\n' > "$target"
  for r in old fresh; do
    mkdir -p "$LIVE/codex/pub/$r"
    ln -s "$target" "$LIVE/codex/pub/$r/s.jsonl"
  done
  mkdir -p "$LIVE/gemini/gone/old2"; ln -s "$target" "$LIVE/gemini/gone/old2/s.jsonl"
  touch -d '-20 minutes' "$LIVE/codex/pub/old" "$LIVE/gemini/gone/old2"   # finished, past the 15-minute grace

  run "$REPO_ROOT/bin/process-inbox"   # an empty inbox: the poll still sweeps
  [ "$status" -eq 0 ]
  [ ! -e "$LIVE/codex/pub/old" ]
  [ -L "$LIVE/codex/pub/fresh/s.jsonl" ]
  [ ! -e "$LIVE/gemini" ]   # emptied runtime and project directories go too
  [ -f "$target" ]          # a link's removal never touches what it points to
}

@test "the sweep waits for a running job: it runs only with the inbox lock" {
  mkdir -p "$LIVE/codex/pub/old"; touch -d '-20 minutes' "$LIVE/codex/pub/old"
  exec 8>"$CLAUDE_INBOX_LOCK"; flock -n 8   # a job is running on this worker
  run "$REPO_ROOT/bin/process-inbox"
  exec 8>&-
  [ "$status" -eq 0 ]
  [ -d "$LIVE/codex/pub/old" ]
}

@test "a live link appears while a long job is still running" {
  export FAKE_GEMINI_SLEEP=6   # the stub writes its session file, then hangs
  drop_spec "ll.json" '{"prompt":"go FAKE_HANG","project":"pub","runtime":"gemini"}'
  "$REPO_ROOT/bin/process-inbox" &
  pi=$!
  found=""
  for _ in $(seq 1 25); do
    if [ -n "$(links)" ]; then found=1; break; fi
    sleep 0.2
  done
  in_flight="$(find "$JOBS_ROOT/processing" -maxdepth 1 -type f ! -name '*.owner' | wc -l)"
  wait "$pi"
  [ -n "$found" ]
  [ "$in_flight" -eq 1 ]   # seen before the job finished
}
