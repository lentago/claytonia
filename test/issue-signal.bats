#!/usr/bin/env bats
#
# Issue signalling (#128): claim comment at start, edited in place at completion,
# all best-effort. Uses stub gh/gh-token (test/stubs) and a local bare repo as the
# project's "origin" so a project job checks out with no network.

load test_helper


setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-issue.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"/{inbox,processing,done,failed,logs,workers,projects}
  export CLAUDE_RUNNER_CWD="$TEST_TMP/work"; mkdir -p "$CLAUDE_RUNNER_CWD"
  export HOME="$TEST_TMP/home"; mkdir -p "$HOME"
  export CLAUDE_RUNNER_WORKROOT="$TEST_TMP/wr"; mkdir -p "$CLAUDE_RUNNER_WORKROOT"
  export CLAUDE_BIN="$STUBS_DIR/claude"
  export CLAUDE_RUNNER_PATH="$STUBS_DIR:$PATH"
  export PATH="$STUBS_DIR:$PATH"
  export FAKE_CLAUDE_MODE=ok
  export FAKE_GH_LOG="$TEST_TMP/gh.log"; : > "$FAKE_GH_LOG"
  export CLAUDE_RUNNER_GH_TIMEOUT=2
  export CLAUDE_RUNNER_GRAFANA_URL="https://grafana.example/"

  # Local origin + pre-made checkout so run-job's fetch/reset path works offline.
  git init -q --bare -b main "$TEST_TMP/origin.git"
  git clone -q "$TEST_TMP/origin.git" "$CLAUDE_RUNNER_WORKROOT/proj" 2>/dev/null
  git -C "$CLAUDE_RUNNER_WORKROOT/proj" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m init
  git -C "$CLAUDE_RUNNER_WORKROOT/proj" push -q origin HEAD:main
  printf '{"proj":{"repo":"acme/proj","default_branch":"main"}}\n' > "$JOBS_ROOT/projects/registry.json"
}

# Drop a project job whose prompt is $1.
drop_project_job() {
  jq -n --arg p "$1" '{prompt:$p, project:"proj"}' > "$JOBS_ROOT/inbox/.j.json.partial"
  mv "$JOBS_ROOT/inbox/.j.json.partial" "$JOBS_ROOT/inbox/j.json"
}

run_job() { "$REPO_ROOT/bin/run-job" "$JOBS_ROOT/inbox/j.json" >/dev/null 2>&1 || true; }

@test "claim comment is posted at start and its id lands in the meta" {
  drop_project_job "Work issue #42 please"
  run_job
  run grep -c 'repos/acme/proj/issues/42/comments' "$FAKE_GH_LOG"
  [ "$output" -ge 1 ]
  grep -q 'working this' "$FAKE_GH_LOG"
  grep -q 'var-runid=' "$FAKE_GH_LOG"
  grep -q '^claim_comment_id=4242$' "$JOBS_ROOT"/logs/*.meta
}

@test "success edits the claim comment in place (no PR opened)" {
  drop_project_job "Work issue #42"
  run_job
  [ "$(count_in done)" -eq 1 ]
  grep -q -- '-X PATCH repos/acme/proj/issues/comments/4242' "$FAKE_GH_LOG"
  grep -q 'no PR opened' "$FAKE_GH_LOG"
  # one POST only: edit, don't append
  [ "$(grep -c 'issues/42/comments' "$FAKE_GH_LOG")" -eq 1 ]
}

@test "success links the PR the run opened" {
  drop_project_job "Work issue #42"
  cat > "$TEST_TMP/claude-pr" <<'EOT'
#!/usr/bin/env bash
cat >/dev/null
printf '{"result":"opened https://github.com/acme/proj/pull/77","is_error":false,"num_turns":1}\n'
EOT
  chmod +x "$TEST_TMP/claude-pr"
  CLAUDE_BIN="$TEST_TMP/claude-pr" run_job
  grep -q 'opened https://github.com/acme/proj/pull/77' "$FAKE_GH_LOG"
}

@test "failure edits the claim comment with the #37 failure text" {
  export FAKE_CLAUDE_MODE=error
  drop_project_job "Fix #42"
  run_job
  [ "$(count_in failed)" -eq 1 ]
  grep -q -- '-X PATCH repos/acme/proj/issues/comments/4242' "$FAKE_GH_LOG"
  grep -q 'Job failed' "$FAKE_GH_LOG"
  [ "$(grep -c 'issues/42/comments' "$FAKE_GH_LOG")" -eq 1 ]
}

@test "limit hit names the limit in the edited comment" {
  export FAKE_CLAUDE_MODE=turns
  drop_project_job "Fix #42"
  run_job
  grep -q 'limit hit: turns' "$FAKE_GH_LOG"
  grep -q 'limit=turns' "$JOBS_ROOT"/logs/*.meta
}

@test "gh failures never change the job outcome" {
  export FAKE_GH_FAIL=1
  drop_project_job "Work issue #42"
  run_job
  [ "$(count_in done)" -eq 1 ]
  [ "$(count_in failed)" -eq 0 ]
  grep -q '^exit=0$' "$JOBS_ROOT"/logs/*.meta
  grep -q '^claim_comment_id=$' "$JOBS_ROOT"/logs/*.meta
}

@test "a hung gh is bounded and does not change the outcome" {
  export FAKE_GH_SLEEP=30
  drop_project_job "Work issue #42"
  start=$SECONDS
  run_job
  [ $(( SECONDS - start )) -lt 20 ]
  [ "$(count_in done)" -eq 1 ]
}

@test "failure with no claim comment still posts the #37 comment" {
  export FAKE_CLAUDE_MODE=error FAKE_GH_FAIL=1
  drop_project_job "Fix #42"
  run_job
  [ "$(count_in failed)" -eq 1 ]
  # claim failed, so the failure path posts (not PATCHes)
  ! grep -q -- 'PATCH' "$FAKE_GH_LOG"
  [ "$(grep -c 'issues/42/comments' "$FAKE_GH_LOG")" -ge 2 ]
}

@test "a job with no issue reference makes no gh calls" {
  drop_project_job "Just tidy the docs"
  run_job
  [ "$(count_in done)" -eq 1 ]
  [ ! -s "$FAKE_GH_LOG" ] || ! grep -q '^api' "$FAKE_GH_LOG"
}

@test "an ad-hoc (no project) job naming an issue makes no gh calls" {
  jq -n '{prompt:"Fix issue #42"}' > "$JOBS_ROOT/inbox/j.json"
  run_job
  [ "$(count_in done)" -eq 1 ]
  [ ! -s "$FAKE_GH_LOG" ]
}
