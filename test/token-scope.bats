#!/usr/bin/env bats
#
# run-job asks gh-token for the least each step needs (#176): the job profile for
# the agent's gh login and git push, `comment` for issue comments, `read` for the
# PR lookup, `merge` for cr-automerge. workflows:write only when the spec opts in;
# a job that needed it without opting in fails with the fix in its reason line.

load test_helper

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-scope.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"/{inbox,processing,done,failed,logs,workers,projects}
  export CLAUDE_RUNNER_CWD="$TEST_TMP/work"; mkdir -p "$CLAUDE_RUNNER_CWD"
  export HOME="$TEST_TMP/home"; mkdir -p "$HOME"
  export CLAUDE_RUNNER_WORKROOT="$TEST_TMP/wr"; mkdir -p "$CLAUDE_RUNNER_WORKROOT"
  export CLAUDE_RUNNER_BIN="$REPO_ROOT/bin"
  export CLAUDE_RUNNER_PATH="$STUBS_DIR:$PATH"
  export PATH="$STUBS_DIR:$PATH"
  export FAKE_GH_LOG="$TEST_TMP/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_GH_TOKEN_LOG="$TEST_TMP/ght.log"; : > "$FAKE_GH_TOKEN_LOG"
  export FAKE_SYSTEMD_CAT_LOG="$TEST_TMP/journal.log"
  export FAKE_CLAUDE_STDIN="$TEST_TMP/prompt"
  export CLAUDE_RUNNER_GH_TIMEOUT=2
  export GIT_ALLOW_PROTOCOL=file

  # A claude that prints FAKE_RESULT as its result, records the token profile it
  # inherited, and can leave FAKE_TRANSCRIPT_TEXT in its session transcript.
  cat > "$TEST_TMP/claude" <<EOF
#!/usr/bin/env bash
cat > "\$FAKE_CLAUDE_STDIN"
echo "\${GH_TOKEN_ACCESS:-unset}" > "$TEST_TMP/inherited-access"
sid=""; prev=""; for a in "\$@"; do [ "\$prev" = --session-id ] && sid="\$a"; prev="\$a"; done
mkdir -p "\$HOME/.claude/projects/-t"
printf '%s\n' "\${FAKE_TRANSCRIPT_TEXT:-plain transcript}" > "\$HOME/.claude/projects/-t/\$sid.jsonl"
jq -cn --arg r "\${FAKE_RESULT:-done}" '{result: \$r, is_error: false, total_cost_usd: 0.01, num_turns: 1}'
EOF
  chmod +x "$TEST_TMP/claude"
  export CLAUDE_BIN="$TEST_TMP/claude"

  git init -q --bare -b main "$TEST_TMP/origin.git"
  git clone -q "$TEST_TMP/origin.git" "$CLAUDE_RUNNER_WORKROOT/proj" 2>/dev/null
  git -C "$CLAUDE_RUNNER_WORKROOT/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$CLAUDE_RUNNER_WORKROOT/proj" push -q origin HEAD:main 2>/dev/null
  printf '{"proj":{"repo":"acme/proj","default_branch":"main"}}\n' > "$JOBS_ROOT/projects/registry.json"
}

run_spec() { # <json>
  printf '%s\n' "$1" > "$JOBS_ROOT/inbox/.j.json.partial"; mv "$JOBS_ROOT/inbox/.j.json.partial" "$JOBS_ROOT/inbox/j.json"
  run "$REPO_ROOT/bin/run-job" "$JOBS_ROOT/inbox/j.json"
}
refusal() { printf '%s' "refusing to allow a GitHub App to create or ""update workflow"; }   # never whole in a file

@test "each step asks for its own profile, always for the job's repo" {
  export FAKE_RESULT="opened https://github.com/acme/proj/pull/7"
  run_spec '{"prompt":"go","project":"proj","issue":42}'
  [ "$status" -eq 0 ]
  grep -qx -- '--access job acme/proj' "$FAKE_GH_TOKEN_LOG"       # the agent's gh login
  grep -qx -- '--access comment acme/proj' "$FAKE_GH_TOKEN_LOG"   # claim and outcome comments
  grep -qx -- '--access merge acme/proj' "$FAKE_GH_TOKEN_LOG"     # cr-automerge
  ! grep -qvE -- '^--access (job|comment|merge|read) acme/proj$' "$FAKE_GH_TOKEN_LOG"
  [ "$(cat "$TEST_TMP/inherited-access")" = job ]                 # what git push mints with
}

@test "the PR lookup for a job that left its branch asks for read" {
  cat > "$TEST_TMP/claude-branch" <<EOF
#!/usr/bin/env bash
cat >/dev/null; git switch -q -c agent/x
echo '{"result":"no url here","is_error":false,"num_turns":1}'
EOF
  chmod +x "$TEST_TMP/claude-branch"; export CLAUDE_BIN="$TEST_TMP/claude-branch"
  run_spec '{"prompt":"go","project":"proj"}'
  grep -qx -- '--access read acme/proj' "$FAKE_GH_TOKEN_LOG"
}

@test "\"workflows\": true gives the job workflows:write, and drops the restriction from the preamble" {
  run_spec '{"prompt":"go","project":"proj","workflows":true}'
  [ "$status" -eq 0 ]
  grep -qx -- '--access job-workflows acme/proj' "$FAKE_GH_TOKEN_LOG"
  [ "$(cat "$TEST_TMP/inherited-access")" = job-workflows ]
  ! grep -q 'NEEDS-WORKFLOWS-PERMISSION' "$FAKE_CLAUDE_STDIN"
  grep -q 'gh-token --access job-workflows' "$FAKE_CLAUDE_STDIN"
}

@test "without the opt-in the preamble says workflow changes are refused and how to say so" {
  run_spec '{"prompt":"go","project":"proj"}'
  [ "$status" -eq 0 ]
  grep -q 'may not create or change anything under `.github/workflows/`' "$FAKE_CLAUDE_STDIN"
  grep -q 'NEEDS-WORKFLOWS-PERMISSION' "$FAKE_CLAUDE_STDIN"
  grep -q 'for this repository only' "$FAKE_CLAUDE_STDIN"
}

@test "an agent that reports it needs workflows fails the job with the fix as its reason" {
  export FAKE_RESULT=$'I need to edit .github/workflows/ci.yml.\n\n`NEEDS-WORKFLOWS-PERMISSION`'
  run_spec '{"prompt":"go","project":"proj","issue":42}'
  [ "$status" -eq 1 ]
  [ "$(find "$JOBS_ROOT/failed" -type f | wc -l)" -eq 1 ]
  tail -1 "$JOBS_ROOT"/logs/*.stderr | grep -qF 'resubmit it with "workflows": true (cr-submit --workflows)'
  grep -q 'needed workflows:write, not granted' "$FAKE_SYSTEMD_CAT_LOG"
}

@test "GitHub's refusal of a workflow push, seen in the transcript, fails the job the same way" {
  export FAKE_TRANSCRIPT_TEXT="remote: $(refusal) \`.github/workflows/ci.yml\` without \`workflows\` permission"
  export FAKE_RESULT="opened https://github.com/acme/proj/pull/9"
  run_spec '{"prompt":"go","project":"proj"}'
  [ "$status" -eq 1 ]
  tail -1 "$JOBS_ROOT"/logs/*.stderr | grep -qF 'resubmit it with "workflows": true'
}

@test "a transcript that merely quotes run-job (or the marker mid-sentence) does not trip it" {
  export FAKE_TRANSCRIPT_TEXT="$(cat "$REPO_ROOT/bin/run-job")"
  export FAKE_RESULT="I read run-job; it prints NEEDS-WORKFLOWS-PERMISSION when a job needs it."
  run_spec '{"prompt":"go","project":"proj"}'
  [ "$status" -eq 0 ]
  [ "$(find "$JOBS_ROOT/done" -type f | wc -l)" -eq 1 ]
}

@test "with the opt-in, the marker is not a failure" {
  export FAKE_RESULT="NEEDS-WORKFLOWS-PERMISSION"
  run_spec '{"prompt":"go","project":"proj","workflows":true}'
  [ "$status" -eq 0 ]
}

@test "cr-submit --workflows writes the opt-in; without it there is none; with -f it is refused" {
  run "$REPO_ROOT/bin/cr-submit" --workflows -o t -p proj "edit ci" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"(workflows)"* ]]
  [ "$(jq -r .workflows "$(find "$JOBS_ROOT/inbox" -name '*.json' | head -1)")" = true ]
  rm -f "$JOBS_ROOT"/inbox/*.json
  run "$REPO_ROOT/bin/cr-submit" -o t -p proj "edit docs" </dev/null
  [ "$(jq -r 'has("workflows")' "$(find "$JOBS_ROOT/inbox" -name '*.json' | head -1)")" = false ]
  printf '{"prompt":"p"}\n' > "$TEST_TMP/s.json"
  run "$REPO_ROOT/bin/cr-submit" --workflows -f "$TEST_TMP/s.json" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"--workflows can't be combined with -f"* ]]
}
