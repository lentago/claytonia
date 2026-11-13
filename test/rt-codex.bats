#!/usr/bin/env bats
#
# The Codex CLI adapter (#171), against test/stubs/codex, which replays real Codex
# 0.166 output (#169). The contract suite (adapter-contract.bats) holds rt-codex to
# the seam; these pin what is Codex's own: the argv (sandbox bypassed, user config
# ignored, every setting a -c override, the -o file outside the checkout), the auth
# file, the result mapping (thread id, summed disjoint tokens, action turns, null
# cost), the -o and thread-id hand-offs, and a job run through run-job unchanged.

load test_helper

RT="$REPO_ROOT/bin/rt-codex"
SID=11111111-2222-4333-8444-555555555555   # run-job's session id for the run
TID=0f0f0f0f-0000-7000-8000-00000000c0de   # the thread id the stub's Codex mints
KEY=sk-test-not-a-real-key-7f3a

# test_helper's setup, plus the Codex seams: the stub CLI and a throwaway env file.
eval "helper_$(declare -f setup)"
setup() {
  helper_setup
  export CODEX_BIN="$STUBS_DIR/codex" CLAUDE_RUNNER_CODEX_ENV="$TEST_TMP/codex.env"
  export FAKE_CODEX_ARGS="$TEST_TMP/codex.argv" FAKE_CODEX_STDIN="$TEST_TMP/codex.stdin" FAKE_CODEX_MODE=ok
  printf 'OPENAI_API_KEY=%s\n' "$KEY" > "$CLAUDE_RUNNER_CODEX_ENV"
  unset GH_TOKEN_ACCESS XDG_CACHE_HOME CODEX_HOME CODEX_API_KEY CODEX_ACCESS_TOKEN
  STATE="$HOME/.cache/rt-codex"
}

# run_codex [run options] — one `rt-codex run` in the job cwd; leaves raw, err and RC.
run_codex() {
  RC=0
  ( cd "$CLAUDE_RUNNER_CWD" && printf 'do the thing' | "$RT" run --cwd "$CLAUDE_RUNNER_CWD" \
      --runid r1 --session-id "$SID" "$@" ) > "$TEST_TMP/raw" 2> "$TEST_TMP/err" || RC=$?
}

# normalize [session id] [options] — normalize $TEST_TMP/raw into res and txt.
normalize() {
  run "$RT" normalize --raw "$TEST_TMP/raw" --result "$TEST_TMP/res" --txt "$TEST_TMP/txt" \
    --session-id "${1:-$SID}" "${@:2}"
}

drop_spec() { # <name> <json>
  printf '%s\n' "$2" > "$JOBS_ROOT/inbox/.$1.partial"
  mv "$JOBS_ROOT/inbox/.$1.partial" "$JOBS_ROOT/inbox/$1"
}

only_runid() { basename "$(find "$JOBS_ROOT/logs" -name '*.meta' | head -1)" .meta; }

# refute <command> — fails the test when the command succeeds. A bare `! cmd` would
# not: bash's errexit ignores negated commands, so bats lets them pass mid-test.
refute() { if "$@"; then echo "unexpectedly true: $*"; return 1; fi; }

@test "rt-codex run: the CLI gets the documented argv, with the prompt on stdin" {
  run_codex --model gpt-5-codex
  [ "$RC" -eq 0 ]
  printf '%s\n' exec --json -C "$CLAUDE_RUNNER_CWD" --dangerously-bypass-approvals-and-sandbox \
    --ignore-user-config -c 'forced_login_method="api"' -c 'project_doc_fallback_filenames=["CLAUDE.md"]' \
    -o "$STATE/$SID.last-message" -m gpt-5-codex --skip-git-repo-check > "$TEST_TMP/want"
  diff "$TEST_TMP/want" "$FAKE_CODEX_ARGS"
  [ "$(cat "$FAKE_CODEX_STDIN")" = "do the thing" ]
  [ ! -s "$TEST_TMP/err" ]   # no limit set, so no note
}

@test "rt-codex run: a git checkout gets no --skip-git-repo-check, and the -o file is outside it" {
  git -C "$CLAUDE_RUNNER_CWD" init -q
  run_codex
  [ "$RC" -eq 0 ]
  refute grep -qx -- --skip-git-repo-check "$FAKE_CODEX_ARGS"
  o="$(grep -A1 -x -- -o "$FAKE_CODEX_ARGS" | tail -1)"
  case "$o" in "$CLAUDE_RUNNER_CWD"/*) false ;; esac
  [ "$(cat "$o")" = ok ]   # the stub wrote the last message there
}

@test "rt-codex run: GH_TOKEN_ACCESS reaches the agent's commands through a set override; an odd value is never interpolated" {
  export GH_TOKEN_ACCESS=job-workflows
  run_codex
  grep -qxF 'shell_environment_policy.set.GH_TOKEN_ACCESS="job-workflows"' "$FAKE_CODEX_ARGS"
  export GH_TOKEN_ACCESS='job" x'
  run_codex
  refute grep -q GH_TOKEN_ACCESS "$FAKE_CODEX_ARGS"
}

@test "rt-codex run: the key comes from the env file, is the CLI's only credential, and is never printed" {
  cat > "$TEST_TMP/envcodex" <<EOF
#!/usr/bin/env bash
env | grep -E '^(OPENAI_|CODEX_(API_KEY|ACCESS_TOKEN|HOME)=|CLAUDE_CODE_OAUTH_TOKEN=|ANTHROPIC_(API_KEY|AUTH_TOKEN)=|GEMINI_API_KEY=|GOOGLE_(API_KEY|GENAI_API_KEY)=)' \
  | sort > "$TEST_TMP/env.seen"
exec "$STUBS_DIR/codex" "\$@"
EOF
  chmod +x "$TEST_TMP/envcodex"
  # Everything ambient that could carry a credential or redirect auth or the endpoint.
  export CODEX_BIN="$TEST_TMP/envcodex" CLAUDE_CODE_OAUTH_TOKEN=claude-token ANTHROPIC_API_KEY=a \
    ANTHROPIC_AUTH_TOKEN=a GEMINI_API_KEY=g GOOGLE_API_KEY=g GOOGLE_GENAI_API_KEY=g \
    CODEX_API_KEY=stale CODEX_ACCESS_TOKEN=stale CODEX_HOME="$TEST_TMP/stray-home" \
    OPENAI_API_KEY=ambient OPENAI_BASE_URL=https://elsewhere.invalid OPENAI_ORGANIZATION=org-other \
    OPENAI_FEDERATION_RULE_ID=r OPENAI_IDENTITY_TOKEN_FILE=/f OPENAI_WORKLOAD_IDENTITY_CONTEXT=c
  run_codex
  [ "$RC" -eq 0 ]
  # The file's OPENAI_API_KEY reaches the CLI as CODEX_API_KEY, the one name 0.166
  # exec reads (#171 live gate), and OPENAI_API_KEY does not reach it at all.
  printf '%s\n' "CODEX_API_KEY=$KEY" "CODEX_HOME=$HOME/.codex" > "$TEST_TMP/want"
  diff "$TEST_TMP/want" "$TEST_TMP/env.seen"
  refute grep -qF "$KEY" "$TEST_TMP/raw" "$TEST_TMP/err" "$FAKE_CODEX_ARGS"

  # The env file itself may point Codex at another endpoint, and a plain assignment
  # there still reaches the CLI.
  printf 'OPENAI_API_KEY=%s\nOPENAI_BASE_URL=https://proxy.invalid/v1\n' "$KEY" > "$CLAUDE_RUNNER_CODEX_ENV"
  run_codex
  [ "$RC" -eq 0 ]
  grep -qx 'OPENAI_BASE_URL=https://proxy.invalid/v1' "$TEST_TMP/env.seen"
}

@test "rt-codex run: no readable env file, or no key in it, stops before the CLI with one line and exit 78" {
  printf 'OTHER=1\n' > "$TEST_TMP/nokey.env"
  printf '%s\n' "$KEY" > "$TEST_TMP/leaky.env"   # not an assignment: bash would quote it in an error
  for f in "$TEST_TMP/missing.env" "$TEST_TMP/nokey.env" "$TEST_TMP/leaky.env"; do
    rm -f "$FAKE_CODEX_ARGS"
    export CLAUDE_RUNNER_CODEX_ENV="$f"
    run_codex
    [ "$RC" -eq 78 ]
    [ "$(wc -l < "$TEST_TMP/err")" -eq 1 ]
    grep -q "^rt-codex: .*OPENAI_API_KEY" "$TEST_TMP/err"
    refute grep -qF "$KEY" "$TEST_TMP/err" "$TEST_TMP/raw"
    [ ! -e "$FAKE_CODEX_ARGS" ]   # the CLI never started
  done
  if [ "$(id -u)" -ne 0 ]; then   # root reads anything
    printf 'OPENAI_API_KEY=%s\n' "$KEY" > "$TEST_TMP/locked.env"; chmod 000 "$TEST_TMP/locked.env"
    export CLAUDE_RUNNER_CODEX_ENV="$TEST_TMP/locked.env"
    run_codex
    [ "$RC" -eq 78 ]
    grep -q "cannot read" "$TEST_TMP/err"
  fi
}

@test "rt-codex run: a missing ~/.codex is created private before the CLI starts (#171 live gate)" {
  [ ! -e "$HOME/.codex" ]
  run_codex
  [ "$RC" -eq 0 ]
  [ -d "$HOME/.codex" ]
  [ "$(stat -c %a "$HOME/.codex")" = 700 ]
  [ ! -s "$TEST_TMP/err" ]
}

@test "rt-codex run: a Codex home it cannot create is one stderr line and exit 78; the CLI never starts" {
  printf 'not a directory\n' > "$HOME/.codex"
  rm -f "$FAKE_CODEX_ARGS"
  run_codex
  [ "$RC" -eq 78 ]
  [ "$(wc -l < "$TEST_TMP/err")" -eq 1 ]
  grep -qF "cannot create or write Codex's home $HOME/.codex" "$TEST_TMP/err"
  refute grep -qF "$KEY" "$TEST_TMP/err" "$TEST_TMP/raw"
  [ ! -e "$FAKE_CODEX_ARGS" ]
}

@test "rt-codex run: a limit or tool allowlist Codex cannot enforce is one stderr note, and no flag" {
  run_codex --max-turns 5 --max-budget-usd 1.5 --allowed-tools 'Bash(git:*) Read'
  [ "$RC" -eq 0 ]
  [ "$(wc -l < "$TEST_TMP/err")" -eq 1 ]
  grep -q 'not enforced: max_turns=5 max_budget_usd=1.5 allowed_tools' "$TEST_TMP/err"
  refute grep -qE '^--(max-turns|max-budget-usd|allowed-tools|allowedTools)$' "$FAKE_CODEX_ARGS"
}

@test "rt-codex normalize: the captured 0.166 run maps onto the result schema" {
  run_codex --model gpt-5-codex
  normalize "$SID" --model gpt-5-codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # silent: run-job's stderr log must not gain lines
  jq -e --arg tid "$TID" '. == {runtime: "codex", model: "gpt-5-codex", session_id: $tid,
    status: "ok", is_error: false, turns: 0,
    tokens: {in: 24117, cached: 0, cache_write: 0, out: 5, thinking: 0},
    tokens_by_model: {unknown: {in: 24117, cached: 0, cache_write: 0, out: 5, thinking: 0}},
    cost_usd: null, final_text: "ok"}' "$TEST_TMP/res"
  [ "$(cat "$TEST_TMP/txt")" = ok ]
}

@test "rt-codex normalize: tokens are summed over turns and disjoint; turns count completed actions" {
  cat > "$TEST_TMP/raw" <<'EOF'
{"type":"thread.started","thread_id":"aaaaaaaa-0000-7000-8000-000000000001"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i0","type":"reasoning","text":"think"}}
{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls","exit_code":0}}
{"type":"item.completed","item":{"id":"i2","type":"file_change","changes":[]}}
{"type":"item.completed","item":{"id":"i3","type":"mcp_tool_call"}}
{"type":"item.completed","item":{"id":"i4","type":"todo_list","items":[]}}
{"type":"item.completed","item":{"id":"i5","type":"agent_message","text":"first"}}
{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":50,"output_tokens":300,"reasoning_output_tokens":120}}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i6","type":"agent_message","text":"done: https://github.com/acme/proj/pull/7"}}
{"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":0}}
EOF
  normalize S
  [ "$status" -eq 0 ]
  # in = 1500 input - 500 cached reads - 50 cache writes; out = 350 output - 120 reasoning
  jq -e '.tokens == {in: 950, cached: 500, cache_write: 50, out: 230, thinking: 120} and .turns == 3
    and .status == "ok" and .session_id == "aaaaaaaa-0000-7000-8000-000000000001"
    and .final_text == "done: https://github.com/acme/proj/pull/7"' "$TEST_TMP/res"
  grep -qx 'done: https://github.com/acme/proj/pull/7' "$TEST_TMP/txt"   # run-job finds the PR URL here
  # the three input counts add back up to input_tokens, the two output ones to output_tokens
  [ "$(jq '.tokens | .in + .cached + .cache_write' "$TEST_TMP/res")" -eq 1500 ]
  [ "$(jq '.tokens | .out + .thinking' "$TEST_TMP/res")" -eq 350 ]
}

@test "rt-codex normalize: a captured gate run's cache writes come out of in (#173)" {
  # turn.completed usage of gate job 216 (2026-11-04): nearly all of its uncached
  # input was cache writes, which bill at their own rate.
  printf '%s\n' '{"type":"thread.started","thread_id":"t"}' \
    '{"type":"item.completed","item":{"type":"agent_message","text":"r"}}' \
    '{"type":"turn.completed","usage":{"input_tokens":101692,"cached_input_tokens":78540,"cache_write_input_tokens":23137,"output_tokens":821,"reasoning_output_tokens":0}}' > "$TEST_TMP/raw"
  normalize S
  [ "$status" -eq 0 ]
  jq -e '.tokens == {in: 15, cached: 78540, cache_write: 23137, out: 821, thinking: 0}' "$TEST_TMP/res"
}

@test "rt-codex normalize: tokens_by_model names the model from the session transcript's turn_context (#173)" {
  run_codex
  d="$HOME/.codex/sessions/2026/11/04"; mkdir -p "$d"
  f="$d/rollout-2026-11-04T10-00-00-$TID.jsonl"
  # As 0.166 writes it: other lines first, a line that is not JSON skipped.
  printf '%s\n' '{"type":"session_meta","payload":{"model_provider":"openai"}}' 'not json' \
    '{"type":"turn_context","payload":{"turn_id":"1","model":"gpt-6.1-sol"}}' \
    '{"type":"token_usage_record","payload":{"usage":{}}}' \
    '{"type":"turn_context","payload":{"turn_id":"2","model":"gpt-6.1-sol"}}' > "$f"
  normalize
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e '.tokens_by_model == {"gpt-6.1-sol": .tokens} and .tokens.in == 24117' "$TEST_TMP/res"

  # Two different models in one session: the tokens cannot be split, so unknown.
  printf '%s\n' '{"type":"turn_context","payload":{"model":"gpt-a"}}' \
    '{"type":"turn_context","payload":{"model":"gpt-b"}}' > "$f"
  run_codex
  normalize
  jq -e '(.tokens_by_model | keys) == ["unknown"]' "$TEST_TMP/res"

  # No model named, or no transcript at all: unknown.
  printf '%s\n' '{"type":"turn_context","payload":{"cwd":"/x"}}' > "$f"
  run_codex
  normalize
  jq -e '(.tokens_by_model | keys) == ["unknown"]' "$TEST_TMP/res"
  rm -f "$f"
  run_codex
  normalize
  [ -z "$output" ]
  jq -e '(.tokens_by_model | keys) == ["unknown"]' "$TEST_TMP/res"
}

@test "rt-codex normalize: the -o file wins over the event stream and is consumed; the thread id is left for transcript" {
  run_codex
  printf 'from the -o file\n' > "$STATE/$SID.last-message"
  normalize
  [ "$status" -eq 0 ]
  jq -e '.final_text == "from the -o file"' "$TEST_TMP/res"
  [ "$(cat "$TEST_TMP/txt")" = "from the -o file" ]
  [ ! -e "$STATE/$SID.last-message" ]
  [ "$(cat "$STATE/$SID.thread")" = "$TID" ]
}

@test "rt-codex normalize: a failed call is an error Codex reported; a killed run is an error it did not" {
  export FAKE_CODEX_MODE=error
  run_codex
  [ "$RC" -eq 1 ]
  normalize
  [ "$status" -eq 0 ]
  jq -e --arg tid "$TID" '.status == "error" and .is_error == true and .final_text == ""
    and .session_id == $tid and .cost_usd == null' "$TEST_TMP/res"
  [ -e "$TEST_TMP/txt" ]

  # Killed mid-run: no completed turn, and the last line cut off.
  printf '%s\n' '{"type":"thread.started","thread_id":"t-1"}' '{"type":"turn.started"}' > "$TEST_TMP/raw"
  printf '{"type":"item.comp' >> "$TEST_TMP/raw"
  normalize S
  [ "$status" -eq 0 ]
  jq -e '.status == "error" and .is_error == false and .session_id == "t-1" and .turns == 0' "$TEST_TMP/res"
}

@test "rt-codex normalize: no thread started falls back to the given session id; output that is not JSON gets no result" {
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"r"}}' > "$TEST_TMP/raw"
  normalize S
  jq -e '.session_id == "S" and .status == "error"' "$TEST_TMP/res"   # no turn completed

  printf 'crashed before JSON\n' > "$TEST_TMP/raw"
  printf '{"stale":true}\n' > "$TEST_TMP/res"
  normalize S
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TEST_TMP/res" ]
  cmp "$TEST_TMP/raw" "$TEST_TMP/txt"
}

@test "rt-codex normalize: a malformed usage block costs the counts, never the result" {
  printf '%s\n' '{"type":"thread.started","thread_id":"t"}' \
    '{"type":"item.completed","item":{"type":"agent_message","text":"r"}}' \
    '{"type":"turn.completed","usage":{"input_tokens":"lots"}}' > "$TEST_TMP/raw"
  normalize S
  [ "$status" -eq 0 ]
  jq -e '.status == "ok" and .tokens == {in: null, cached: null, cache_write: null, out: null, thinking: null}
         and .tokens_by_model == null and .model == null' "$TEST_TMP/res"
}

@test "rt-codex normalize: usage whose parts exceed its whole is null, never a negative count (#235 review)" {
  for usage in '{"input_tokens":100,"cached_input_tokens":90,"cache_write_input_tokens":20,"output_tokens":5,"reasoning_output_tokens":0}' \
               '{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":9}'; do
    printf '%s\n' '{"type":"thread.started","thread_id":"t"}' \
      '{"type":"item.completed","item":{"type":"agent_message","text":"r"}}' \
      "{\"type\":\"turn.completed\",\"usage\":$usage}" > "$TEST_TMP/raw"
    normalize S
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e '.status == "ok" and .tokens == {in: null, cached: null, cache_write: null, out: null, thinking: null}
           and .tokens_by_model == null' "$TEST_TMP/res"
  done
}

@test "rt-codex normalize: a result it cannot write is an exit 1, still silent" {
  run_codex
  run "$RT" normalize --raw "$TEST_TMP/raw" --result "$TEST_TMP/no-such-dir/res" --txt "$TEST_TMP/txt" --session-id "$SID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "rt-codex transcript: the session file of the run's thread is copied; nothing else ever matches" {
  run_codex
  normalize
  d="$HOME/.codex/sessions/2026/11/04"; mkdir -p "$d"
  echo '{"rollout":"ours"}'   > "$d/rollout-2026-11-04T10-00-00-$TID.jsonl"
  echo '{"rollout":"theirs"}' > "$d/rollout-2026-11-04T10-00-01-aaaaaaaa-0000-7000-8000-000000000001.jsonl"
  run "$RT" transcript --session-id "$SID" --out "$TEST_TMP/tr"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/tr")" = '{"rollout":"ours"}' ]
  [ ! -e "$STATE/$SID.thread" ]

  # A short id could suffix-match another session's file; only a UUID is looked up.
  run "$RT" transcript --session-id 1 --out "$TEST_TMP/tr2"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/tr2" ]

  # The home is pinned to ~/.codex: an ambient CODEX_HOME is not searched.
  export CODEX_HOME="$TEST_TMP/codex-home"; mkdir -p "$CODEX_HOME/sessions/x"
  echo '{"rollout":"stray"}' > "$CODEX_HOME/sessions/x/rollout-x-$TID.jsonl"
  rm -f "$d/rollout-2026-11-04T10-00-00-$TID.jsonl"
  run "$RT" transcript --session-id "$TID" --out "$TEST_TMP/tr3"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/tr3" ]
}

@test "rt-codex enforces: neither cap exists in Codex (#173)" {
  run "$RT" enforces --limit turns
  [ "$status" -eq 1 ]
  run "$RT" enforces --limit budget
  [ "$status" -eq 1 ]
}

@test "rt-codex accepts-model: OpenAI ids yes; Claude, Gemini and malformed names no" {
  for m in gpt-5-codex gpt-5.5 o3 o4-mini codex-mini-latest; do
    "$RT" accepts-model --model "$m" || { echo "refused $m"; false; }
  done
  for m in sonnet opus haiku fable 'opus[1m]' claude-opus-5-5 gemini-3.8-flash o GPT-5 'gpt 5' ''; do
    refute "$RT" accepts-model --model "$m"
  done
}

@test "run-job: a runtime=codex job runs through rt-codex and is filed like any other" {
  mkdir -p "$HOME/.codex/sessions/2026/11/04"
  echo '{"rollout":"job"}' > "$HOME/.codex/sessions/2026/11/04/rollout-2026-11-04T10-00-00-$TID.jsonl"
  drop_spec "codex.json" '{"prompt":"go","runtime":"codex","model":"gpt-5-codex"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  runid="$(only_runid)"
  [ "$(cat "$FAKE_CODEX_STDIN")" = go ]
  "$STUBS_DIR/codex" exec </dev/null > "$TEST_TMP/expected"   # the raw output, filed as-is
  cmp "$TEST_TMP/expected" "$JOBS_ROOT/logs/$runid.json"
  jq -e --arg tid "$TID" '.runtime == "codex" and .status == "ok" and .model == "gpt-5-codex"
    and .session_id == $tid and .cost_usd == null' "$JOBS_ROOT/logs/$runid.result.json"
  [ "$(cat "$JOBS_ROOT/logs/$runid.txt")" = ok ]
  [ "$(cat "$JOBS_ROOT/logs/$runid.transcript.jsonl")" = '{"rollout":"job"}' ]
  grep -qx 'cost_usd=' "$JOBS_ROOT/logs/$runid.meta"   # unknown, never 0
}

@test "run-job: a codex job with no env file fails, and its reason line names the file" {
  export CLAUDE_RUNNER_CODEX_ENV="$TEST_TMP/missing.env"
  drop_spec "codex.json" '{"prompt":"go","runtime":"codex"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in failed)" -eq 1 ]
  runid="$(only_runid)"
  tail -1 "$JOBS_ROOT/logs/$runid.stderr" | grep -q "rt-codex: cannot read $TEST_TMP/missing.env"
  [ ! -e "$FAKE_CODEX_ARGS" ]
}

@test "rt-codex run: session files older than 7 days are swept from ~/.codex/sessions; newer ones stay (#203 review)" {
  old="$HOME/.codex/sessions/2026/10/01/rollout-old-$TID.jsonl"
  new="$HOME/.codex/sessions/2026/11/04/rollout-new-$TID.jsonl"
  mkdir -p "$(dirname "$old")" "$(dirname "$new")"
  echo '{}' > "$old"; echo '{}' > "$new"
  touch -d '10 days ago' "$old"
  run_codex
  [ "$RC" -eq 0 ]
  [ ! -e "$old" ] && [ ! -d "$HOME/.codex/sessions/2026/10/01" ]
  [ -e "$new" ]
}
