#!/usr/bin/env bats
#
# The Gemini and Codex stubs (#169) replay real CLI output, so the adapters that
# parse it (#170, #171) are built against what the CLIs actually print. These pin
# that each stub mode emits the captured shape and honours the seams the adapter
# tests will lean on (argv, stdin, session and thread ids, the -o file, hang).

load test_helper

PROMPT='stub prompt on stdin'

@test "gemini stub ok: the captured JSON, with the caller's session id" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/g.argv" FAKE_GEMINI_STDIN="$TEST_TMP/g.stdin"
  run bash -c "printf '%s' '$PROMPT' | '$STUBS_DIR/gemini' -p '' -o json --session-id abc-123"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.session_id == "abc-123" and .response == "ok"
    and (.stats.models | to_entries[0].value.tokens | has("input") and has("cached") and has("candidates") and has("thoughts"))
    and (.stats.tools.totalCalls | type) == "number"'
  [ "$(cat "$FAKE_GEMINI_STDIN")" = "$PROMPT" ]
  grep -qx -- '--session-id' "$FAKE_GEMINI_ARGS"
}

@test "gemini stub error: empty stdout, the JSON error report on stderr, exit 1" {
  export FAKE_GEMINI_MODE=error
  rc=0
  printf '%s' "$PROMPT" | "$STUBS_DIR/gemini" -p '' -o json > "$TEST_TMP/out" 2> "$TEST_TMP/err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$TEST_TMP/out" ]
  grep -q 'ModelNotFoundError' "$TEST_TMP/err"
}

@test "codex stub ok: the captured events, its own thread id, and the -o file" {
  export FAKE_CODEX_ARGS="$TEST_TMP/c.argv" FAKE_CODEX_STDIN="$TEST_TMP/c.stdin" FAKE_CODEX_THREAD_ID=tid-1
  run bash -c "printf '%s' '$PROMPT' | '$STUBS_DIR/codex' exec --json -o '$TEST_TMP/last.txt'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -se '
    (map(.type) == ["thread.started","turn.started","item.completed","turn.completed"])
    and .[0].thread_id == "tid-1"
    and (.[3].usage | has("input_tokens") and has("cached_input_tokens") and has("output_tokens") and has("reasoning_output_tokens"))'
  [ "$(cat "$TEST_TMP/last.txt")" = ok ]
  [ "$(cat "$FAKE_CODEX_STDIN")" = "$PROMPT" ]
}

@test "codex stub error: error and turn.failed events, no -o file, exit 1" {
  export FAKE_CODEX_MODE=error
  run bash -c "printf x | '$STUBS_DIR/codex' exec --json -o '$TEST_TMP/last.txt'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | jq -se 'any(.[]; .type == "turn.failed") and any(.[]; .type == "error")'
  [ ! -e "$TEST_TMP/last.txt" ]
}

@test "codex stub: only exec is stubbed" {
  run "$STUBS_DIR/codex" login </dev/null
  [ "$status" -eq 2 ]
}

@test "both stubs: nonzero mode prints non-JSON and exits 9; FAKE_HANG sleeps first" {
  run bash -c "printf x | FAKE_GEMINI_MODE=nonzero '$STUBS_DIR/gemini' -p ''"
  [ "$status" -eq 9 ]
  ! printf '%s' "$output" | jq -e . >/dev/null 2>&1
  run bash -c "printf x | FAKE_CODEX_MODE=nonzero '$STUBS_DIR/codex' exec --json"
  [ "$status" -eq 9 ]
  SECONDS=0
  printf 'FAKE_HANG' | FAKE_GEMINI_SLEEP=2 "$STUBS_DIR/gemini" -p '' >/dev/null
  printf 'FAKE_HANG' | FAKE_CODEX_SLEEP=2 "$STUBS_DIR/codex" exec --json >/dev/null
  [ "$SECONDS" -ge 4 ]
}
