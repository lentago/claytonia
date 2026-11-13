#!/usr/bin/env bats
#
# The worker-runtime contract (#166, #169), checked against every adapter in bin/.
# Each bin/rt-<runtime> must pass every case here; the cases loop over whatever
# adapters exist, so a new one is held to the contract the moment it lands. A new
# adapter needs one entry in contract_entry below: how to point it at its stub CLI,
# one model it takes and one it does not. Without that entry the first case fails.
#
# The contract, from the rt-claude header: `run` reads the prompt on stdin (never
# argv), puts the CLI's raw output on stdout and passes its exit code through;
# `normalize` writes the result schema, or no result when the output is empty or
# unparseable, and is silent on stderr; its five token counts are disjoint and its
# tokens_by_model sums to them (#173); `accepts-model` and `enforces` answer 0 or 1;
# `update` names a CLI that is not installed with exit 3 (#172; cr-update.bats covers
# the rest of it); `transcript` is best-effort; anything else exits 2.

load test_helper

PROMPT='contract-check prompt: do not echo me in argv'
FIELDS='["cost_usd","final_text","is_error","model","runtime","session_id","status","tokens","tokens_by_model","turns"]'
TOKEN_FIELDS='["cache_write","cached","in","out","thinking"]'

adapters() { for f in "$REPO_ROOT"/bin/rt-*; do [ -x "$f" ] && basename "$f" | sed 's/^rt-//'; done; }

# contract_entry <runtime> — point the adapter at its stub; set STUB_ARGS (argv file),
# STUB_STDIN (prompt file), MODE_VAR (its mode variable), BIN_VAR (the variable that
# names its CLI), MODEL_OK, MODEL_BAD.
contract_entry() {
  case "$1" in
    claude)
      export CLAUDE_BIN="$STUBS_DIR/claude"
      STUB_ARGS=FAKE_CLAUDE_ARGS; STUB_STDIN=FAKE_CLAUDE_STDIN; MODE_VAR=FAKE_CLAUDE_MODE; BIN_VAR=CLAUDE_BIN
      MODEL_OK=sonnet; MODEL_BAD=gemini-3.8-flash ;;
    gemini)
      export GEMINI_BIN="$STUBS_DIR/gemini" CLAUDE_RUNNER_GEMINI_ENV="$TEST_TMP/gemini.env"
      printf 'GOOGLE_GENAI_USE_VERTEXAI=true\n' > "$CLAUDE_RUNNER_GEMINI_ENV"   # never real credentials
      STUB_ARGS=FAKE_GEMINI_ARGS; STUB_STDIN=FAKE_GEMINI_STDIN; MODE_VAR=FAKE_GEMINI_MODE; BIN_VAR=GEMINI_BIN
      MODEL_OK=gemini-3.5-flash-lite; MODEL_BAD=sonnet ;;
    codex)
      export CODEX_BIN="$STUBS_DIR/codex" CLAUDE_RUNNER_CODEX_ENV="$TEST_TMP/codex.env"
      printf 'OPENAI_API_KEY=sk-contract-test\n' > "$CLAUDE_RUNNER_CODEX_ENV"   # never a real key
      STUB_ARGS=FAKE_CODEX_ARGS; STUB_STDIN=FAKE_CODEX_STDIN; MODE_VAR=FAKE_CODEX_MODE; BIN_VAR=CODEX_BIN
      MODEL_OK=gpt-5-codex; MODEL_BAD=sonnet ;;
    *) return 1 ;;
  esac
  export "$STUB_ARGS=$TEST_TMP/$1.argv" "$STUB_STDIN=$TEST_TMP/$1.stdin"
}

rt() { "$REPO_ROOT/bin/rt-$1" "${@:2}"; }

# run_adapter <runtime> <mode> — one `run` through its stub; leaves raw, stderr, rc.
run_adapter() {
  export "$MODE_VAR=$2"
  RC=0
  ( cd "$CLAUDE_RUNNER_CWD" && printf '%s' "$PROMPT" | rt "$1" run --cwd "$CLAUDE_RUNNER_CWD" \
      --runid contract-run --session-id 11111111-2222-4333-8444-555555555555 --model "$MODEL_OK" ) \
    > "$TEST_TMP/$1.raw" 2> "$TEST_TMP/$1.err" || RC=$?   # bats runs errexit: record, don't abort
}

@test "contract: every adapter in bin/ has a contract entry (a stub and two models)" {
  [ -n "$(adapters)" ]
  for a in $(adapters); do
    contract_entry "$a" || { echo "rt-$a has no contract_entry in test/adapter-contract.bats"; false; }
  done
}

@test "contract run: the prompt arrives on stdin and never in argv; raw output on stdout" {
  for a in $(adapters); do
    contract_entry "$a"
    run_adapter "$a" ok
    [ "$RC" -eq 0 ]
    [ "$(cat "${!STUB_STDIN}")" = "$PROMPT" ]
    ! grep -qF "do not echo me" "${!STUB_ARGS}"
    [ -s "$TEST_TMP/$a.raw" ]
  done
}

@test "contract run: the CLI's exit code passes through" {
  for a in $(adapters); do
    contract_entry "$a"
    run_adapter "$a" nonzero
    [ "$RC" -eq 9 ]
  done
}

@test "contract normalize: an ok run yields every result field, the adapter's runtime name, and silence" {
  for a in $(adapters); do
    contract_entry "$a"
    run_adapter "$a" ok
    run rt "$a" normalize --raw "$TEST_TMP/$a.raw" --result "$TEST_TMP/$a.res" --txt "$TEST_TMP/$a.txt" \
      --session-id 11111111-2222-4333-8444-555555555555 --model "$MODEL_OK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    jq -e --argjson f "$FIELDS" --argjson tf "$TOKEN_FIELDS" --arg rt "$a" '
      (keys == $f) and .runtime == $rt and .status == "ok" and .is_error == false
      and (.tokens | keys == $tf)
      and ((.cost_usd == null) or ((.cost_usd | type) == "number"))' "$TEST_TMP/$a.res"
    [ -e "$TEST_TMP/$a.txt" ]
  done
}

@test "contract normalize: tokens_by_model sums to the five totals, field by field (#173)" {
  for a in $(adapters); do
    contract_entry "$a"
    run_adapter "$a" ok
    run rt "$a" normalize --raw "$TEST_TMP/$a.raw" --result "$TEST_TMP/$a.res" --txt "$TEST_TMP/$a.txt" \
      --session-id 11111111-2222-4333-8444-555555555555 --model "$MODEL_OK"
    [ "$status" -eq 0 ]
    # Every stub's ok output reports usage, so the totals are not all null, and each
    # model's entry has the same five keys. A null total is null in every entry.
    jq -e --argjson tf "$TOKEN_FIELDS" '. as $r
      | ($r.tokens.in | type) == "number"
      and ($r.tokens_by_model | type) == "object" and ($r.tokens_by_model | length) > 0
      and ([$r.tokens_by_model[] | keys == $tf] | all)
      and ([$tf[] as $k | ([$r.tokens_by_model[] | .[$k]] | add) == $r.tokens[$k]] | all)' "$TEST_TMP/$a.res"
  done
}

@test "contract normalize: a run that reported no usage has five null totals and a null tokens_by_model" {
  # The rule the sum check above cannot see: null totals never come with entries.
  for a in $(adapters); do
    contract_entry "$a"
    run_adapter "$a" error
    run rt "$a" normalize --raw "$TEST_TMP/$a.raw" --result "$TEST_TMP/$a.res" --txt "$TEST_TMP/$a.txt" --session-id S
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TMP/$a.res" ] || jq -e '
      if ([.tokens[]] | all(. == null)) then .tokens_by_model == null
      else (.tokens_by_model | type) == "object" end' "$TEST_TMP/$a.res"
  done
}

@test "contract enforces: turns and budget answer 0 or 1; any other limit, or none, exits 2" {
  for a in $(adapters); do
    for l in turns budget; do
      run rt "$a" enforces --limit "$l"
      [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
      [ -z "$output" ]
    done
    run rt "$a" enforces --limit timeout   # the wall clock is run-job's, never an adapter's
    [ "$status" -eq 2 ]
    run rt "$a" enforces
    [ "$status" -eq 2 ]
  done
}

@test "contract update: a CLI that is not installed is exit 3, named in one line (#172)" {
  for a in $(adapters); do
    contract_entry "$a"
    export "$BIN_VAR=$TEST_TMP/no-such-dir/$a"
    run rt "$a" update
    [ "$status" -eq 3 ]
    [ "$output" = "not installed ($TEST_TMP/no-such-dir/$a)" ]
  done
}

@test "contract normalize: a failed run is never filed ok" {
  for a in $(adapters); do
    contract_entry "$a"
    run_adapter "$a" error
    run rt "$a" normalize --raw "$TEST_TMP/$a.raw" --result "$TEST_TMP/$a.res" --txt "$TEST_TMP/$a.txt" --session-id S
    [ "$status" -eq 0 ]
    # Either no result (the exit code decides) or one that says the run failed.
    [ ! -e "$TEST_TMP/$a.res" ] || jq -e '.status != "ok"' "$TEST_TMP/$a.res"
  done
}

@test "contract normalize: empty or unparseable output gives no result, exit 0, silently" {
  for a in $(adapters); do
    contract_entry "$a"
    for raw in '' 'crashed before any JSON'; do
      printf '%s' "$raw" > "$TEST_TMP/$a.raw"
      run rt "$a" normalize --raw "$TEST_TMP/$a.raw" --result "$TEST_TMP/$a.res" --txt "$TEST_TMP/$a.txt" --session-id S
      [ "$status" -eq 0 ]
      [ -z "$output" ]
      [ ! -e "$TEST_TMP/$a.res" ]
      [ -e "$TEST_TMP/$a.txt" ]
    done
  done
}

@test "contract accepts-model: its own model yes; another runtime's model and the empty string no" {
  for a in $(adapters); do
    contract_entry "$a"
    rt "$a" accepts-model --model "$MODEL_OK"
    ! rt "$a" accepts-model --model "$MODEL_BAD"
    ! rt "$a" accepts-model --model ""
  done
}

@test "contract transcript: an unknown session is not an error and writes nothing" {
  for a in $(adapters); do
    contract_entry "$a"
    run rt "$a" transcript --session-id no-such-session --out "$TEST_TMP/$a.transcript"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TMP/$a.transcript" ]
  done
}

@test "contract: an unknown subcommand exits 2" {
  for a in $(adapters); do
    run rt "$a" no-such-subcommand
    [ "$status" -eq 2 ]
  done
}
