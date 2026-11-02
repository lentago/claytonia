#!/usr/bin/env bats
#
# The runtime seam (#166, #167): run-job reaches Claude Code only through its
# adapter, bin/rt-claude. These pin what that move must not change (the raw
# output, the argv, the sidecar, the .meta) and what it adds (the normalized
# logs/<runid>.result.json). The CLI is test/stubs/claude, as everywhere else.

load test_helper

RT="$REPO_ROOT/bin/rt-claude"

drop_spec() { # <name> <json>
  printf '%s\n' "$2" > "$JOBS_ROOT/inbox/.$1.partial"
  mv "$JOBS_ROOT/inbox/.$1.partial" "$JOBS_ROOT/inbox/$1"
}

only_runid() { basename "$(find "$JOBS_ROOT/logs" -name '*.meta' | head -1)" .meta; }

@test "rt-claude: the raw CLI output is filed byte-for-byte as logs/<runid>.json" {
  for mode in ok error nonzero turns budget; do
    rm -rf "${JOBS_ROOT:?}"/logs/* "$JOBS_ROOT"/done/* "$JOBS_ROOT"/failed/*
    FAKE_CLAUDE_MODE="$mode" "$STUBS_DIR/claude" </dev/null > "$TEST_TMP/expected.$mode" || true
    export FAKE_CLAUDE_MODE="$mode"
    drop_job "raw-$mode.txt" "go"
    run "$REPO_ROOT/bin/process-inbox"
    [ "$status" -eq 0 ]
    cmp "$TEST_TMP/expected.$mode" "$JOBS_ROOT/logs/$(only_runid).json"
  done
}

@test "rt-claude: each stub mode yields its normalized result" {
  expect() { # <mode> <jq assertion over result.json, or "none">
    rm -rf "${JOBS_ROOT:?}"/logs/* "$JOBS_ROOT"/done/* "$JOBS_ROOT"/failed/*
    export FAKE_CLAUDE_MODE="$1"
    drop_job "norm-$1.txt" "go"
    run "$REPO_ROOT/bin/process-inbox"
    [ "$status" -eq 0 ]
    local res; res="$JOBS_ROOT/logs/$(only_runid).result.json"
    if [ "$2" = none ]; then [ ! -e "$res" ]; return; fi
    jq -e "$2" "$res" >/dev/null
  }
  expect ok      '.runtime == "claude" and .status == "ok" and .is_error == false and .turns == 1 and .cost_usd == 0.0001 and .final_text == "stub ok"'
  expect error   '.status == "error" and .is_error == true and .final_text == "stub failure"'
  expect turns   '.status == "max_turns" and .is_error == false and .turns == 4'
  expect budget  '.status == "max_budget" and .cost_usd == 2.01'
  expect nonzero none   # not JSON: no result, the exit code decides (rc=9 -> failed/)
}

@test "rt-claude run: the CLI gets exactly the argv run-job always passed" {
  export FAKE_CLAUDE_ARGS="$TEST_TMP/argv"
  drop_spec "argv.json" '{"prompt":"go","model":"sonnet","max_turns":5,"max_budget_usd":1.5,"allowed_tools":"Bash(git:*) Read"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  sid="$(sed -n 's/^session_id=//p' "$JOBS_ROOT/logs/$(only_runid).meta")"
  [ -n "$sid" ]
  printf '%s\n' -p --dangerously-skip-permissions --output-format json --session-id "$sid" \
    --model sonnet --max-turns 5 --max-budget-usd 1.5 --allowedTools 'Bash(git:*) Read' > "$TEST_TMP/want"
  diff "$TEST_TMP/want" "$FAKE_CLAUDE_ARGS"
}

@test "rt-claude run: the .runid sidecar lands next to the live transcript" {
  drop_job "side.txt" "go"
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  runid="$(only_runid)"
  sid="$(sed -n 's/^session_id=//p' "$JOBS_ROOT/logs/$runid.meta")"
  cwd="$(sed -n 's/^cwd=//p' "$JOBS_ROOT/logs/$runid.meta")"   # the cwd the job ran in
  [ -n "$sid" ] && [ -n "$cwd" ]
  side="$HOME/.claude/projects/$(printf '%s' "$cwd" | tr '/' '-')/$sid.runid"
  [ "$(cat "$side")" = "$runid" ]
}

@test "the .meta keeps its keys, in order (the seam adds none)" {
  drop_job "keys.txt" "go"
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  cut -d= -f1 "$JOBS_ROOT/logs/$(only_runid).meta" > "$TEST_TMP/keys"
  printf '%s\n' runid exit duration_sec project repo model cwd cost_usd num_turns session_id \
    limit max_turns max_budget_usd timeout_sec claim_comment_id issue submitter finished > "$TEST_TMP/want"
  diff "$TEST_TMP/want" "$TEST_TMP/keys"
}

@test "rt-claude normalize: token counts are disjoint (in excludes cached reads; thinking is folded into out)" {
  printf '%s\n' '{"subtype":"success","is_error":false,"result":"r","total_cost_usd":1.50,"num_turns":7,
    "usage":{"input_tokens":12,"cache_creation_input_tokens":300,"cache_read_input_tokens":4000,"output_tokens":55}}' > "$TEST_TMP/raw"
  run "$RT" normalize --raw "$TEST_TMP/raw" --result "$TEST_TMP/res" --txt "$TEST_TMP/txt" --session-id S --model opus
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # silent: run-job's stderr log must not gain lines
  jq -e '.tokens == {"in":312,"cached":4000,"out":55,"thinking":null} and .model == "opus" and .session_id == "S"' "$TEST_TMP/res"
  # copied, not recomputed: the cost reads back exactly as the CLI wrote it
  [ "$(jq -r '.cost_usd' "$TEST_TMP/res")" = "$(jq -r '.total_cost_usd' "$TEST_TMP/raw")" ]
  [ "$(cat "$TEST_TMP/txt")" = r ]
}

@test "rt-claude normalize: a malformed usage block costs the counts, never the result" {
  printf '%s\n' '{"result":"r","is_error":false,"usage":{"input_tokens":"lots"}}' > "$TEST_TMP/raw"
  run "$RT" normalize --raw "$TEST_TMP/raw" --result "$TEST_TMP/res" --txt "$TEST_TMP/txt" --session-id S
  [ "$status" -eq 0 ]
  jq -e '.status == "ok" and .tokens.in == null and .model == null' "$TEST_TMP/res"
}

@test "rt-claude normalize: output that is not JSON gets no result, and the raw text as .txt" {
  printf 'crashed before JSON\n' > "$TEST_TMP/raw"
  printf '{"stale":true}\n' > "$TEST_TMP/res"
  run "$RT" normalize --raw "$TEST_TMP/raw" --result "$TEST_TMP/res" --txt "$TEST_TMP/txt" --session-id S
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TEST_TMP/res" ]
  cmp "$TEST_TMP/raw" "$TEST_TMP/txt"
}

@test "rt-claude normalize: empty output (a run killed before it printed) gets no result, on any jq" {
  # jq 1.6 (the workers' Debian 12) exits 0 for `jq -e .` on empty input; 1.7+ exits 4.
  : > "$TEST_TMP/raw"
  run "$RT" normalize --raw "$TEST_TMP/raw" --result "$TEST_TMP/res" --txt "$TEST_TMP/txt" --session-id S
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/res" ]
  [ ! -e "$TEST_TMP/res.tmp" ]
  [ -e "$TEST_TMP/txt" ]
}

@test "rt-claude transcript: a kept session transcript is copied; a missing one is not an error" {
  mkdir -p "$HOME/.claude/projects/-some-cwd"
  printf '{"turn":1}\n' > "$HOME/.claude/projects/-some-cwd/abc.jsonl"
  run "$RT" transcript --session-id abc --out "$TEST_TMP/t.jsonl"
  [ "$status" -eq 0 ]
  cmp "$HOME/.claude/projects/-some-cwd/abc.jsonl" "$TEST_TMP/t.jsonl"
  run "$RT" transcript --session-id nope --out "$TEST_TMP/none.jsonl"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/none.jsonl" ]
}

@test "rt-claude: an unknown subcommand or option is refused" {
  run "$RT" fly
  [ "$status" -eq 2 ]
  run "$RT" run --bogus x
  [ "$status" -eq 2 ]
}
