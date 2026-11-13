#!/usr/bin/env bats
#
# The Gemini CLI adapter (#170): bin/rt-gemini against test/stubs/gemini, which
# replays real 0.66 output. These pin the argv, the per-run Gemini home and its
# settings, the credentials the adapter sources and the ones it drops, the notes
# for limits it cannot enforce, the normalized result for each output shape 0.66
# has, the transcript copy and the model rule. Every test reaches the stub and a
# throwaway credentials file, never the real ones, even when the suite runs on a
# worker. Negative checks are written as tests or counts, not `! cmd`, which bats
# does not fail on mid-test.

load test_helper

# The shared queue setup, plus the Gemini seams.
eval "$(declare -f setup | sed '1s/^setup /_queue_setup /')"
setup() {
  _queue_setup
  unset XDG_STATE_HOME
  export GEMINI_BIN="$STUBS_DIR/gemini" CLAUDE_RUNNER_GEMINI_ENV="$TEST_TMP/gemini.env"
  printf '%s\n' GOOGLE_GENAI_USE_VERTEXAI=true GOOGLE_CLOUD_PROJECT=fake-project-4471 \
    GOOGLE_CLOUD_LOCATION=global > "$CLAUDE_RUNNER_GEMINI_ENV"
  # As on a provisioned worker: the GitHub credential helper in ~/.gitconfig.
  git config --global "$HELPER_KEY" /usr/local/bin/gh-credential-helper
  export FAKE_GEMINI_MODE=ok
}

HELPER_KEY='credential.https://github.com.helper'
# The git config overrides Gemini CLI 0.66's shell tool appends to every command it
# runs (getSafeGitEnv / the shell executor's defaultGitOverrides; #170 live gate).
GEMINI_GIT_OVERRIDES=( GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=
  GIT_CONFIG_COUNT=7
  GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=
  GIT_CONFIG_KEY_2=core.hooksPath GIT_CONFIG_VALUE_2= GIT_CONFIG_KEY_3=core.sshCommand GIT_CONFIG_VALUE_3=
  GIT_CONFIG_KEY_4=core.pager GIT_CONFIG_VALUE_4=cat GIT_CONFIG_KEY_5=core.editor GIT_CONFIG_VALUE_5=
  GIT_CONFIG_KEY_6=sequence.editor GIT_CONFIG_VALUE_6= )
# cred_user <host> <GIT_CONFIG_PARAMETERS> — the username git's credential lookup
# yields under Gemini's overrides plus the given parameters; empty when none.
cred_user() {
  printf 'protocol=https\nhost=%s\n\n' "$1" \
    | env "${GEMINI_GIT_OVERRIDES[@]}" GIT_CONFIG_PARAMETERS="$2" git credential fill 2>/dev/null \
    | sed -n 's/^username=//p'
}

RT="$REPO_ROOT/bin/rt-gemini"
SID=11111111-2222-4333-8444-555555555555
FIX="$REPO_ROOT/test/fixtures/runtimes"

drop_spec() { # <name> <json>
  printf '%s\n' "$2" > "$JOBS_ROOT/inbox/.$1.partial"
  mv "$JOBS_ROOT/inbox/.$1.partial" "$JOBS_ROOT/inbox/$1"
}
only_runid() { basename "$(find "$JOBS_ROOT/logs" -name '*.meta' | head -1)" .meta; }
meta() { sed -n "s/^$1=//p" "$JOBS_ROOT/logs/$(only_runid).meta"; }
home_of() { printf '%s/.local/state/claytonia/gemini/%s' "$HOME" "$1"; }

# rt_run [run options...] — one `run` in the job cwd with the prompt on stdin;
# leaves $TEST_TMP/raw.json (stdout), $TEST_TMP/raw.stderr and RC.
rt_run() {
  RC=0
  ( cd "$CLAUDE_RUNNER_CWD" && printf 'the prompt' | "$RT" run --cwd "$CLAUDE_RUNNER_CWD" \
      --runid r1 --session-id "$SID" "$@" ) > "$TEST_TMP/raw.json" 2> "$TEST_TMP/raw.stderr" || RC=$?
}

# norm <raw file> [normalize options...] — normalize into $TEST_TMP/res and txt.
norm() {
  local raw="$1"; shift
  run "$RT" normalize --raw "$raw" --result "$TEST_TMP/res" --txt "$TEST_TMP/txt" "$@"
}

@test "rt-gemini run: through run-job, the CLI gets the #170 argv and the prompt on stdin only" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv" FAKE_GEMINI_STDIN="$TEST_TMP/stdin"
  drop_spec "argv.json" '{"prompt":"say ok","runtime":"gemini","model":"gemini-3.5-flash-lite","max_turns":5}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  sid="$(meta session_id)"
  [ -n "$sid" ]
  printf '%s\n' -p '' -o json --approval-mode yolo --session-id "$sid" -m gemini-3.5-flash-lite > "$TEST_TMP/want"
  diff "$TEST_TMP/want" "$FAKE_GEMINI_ARGS"
  [ "$(cat "$FAKE_GEMINI_STDIN")" = "say ok" ]
  jq -e '.model.maxSessionTurns == 5' "$(home_of "$sid")/.gemini/settings.json"
}

@test "rt-gemini through run-job: raw output filed as-is; ok is done, a failure failed, the turn cap limit=turns" {
  expect() { # <mode> <done|failed> <exit> <limit> <jq over result.json, or none>
    rm -rf "${JOBS_ROOT:?}"/logs/* "$JOBS_ROOT"/done/* "$JOBS_ROOT"/failed/*
    export FAKE_GEMINI_MODE="$1"
    drop_spec "route-$1.json" '{"prompt":"go","runtime":"gemini","max_turns":3}'
    run "$REPO_ROOT/bin/process-inbox"
    [ "$status" -eq 0 ]
    [ "$(count_in "$2")" -eq 1 ]
    [ "$(meta exit)" = "$3" ]
    [ "$(meta limit)" = "$4" ]
    local runid; runid="$(only_runid)"
    # logs/<runid>.json is the CLI's stdout, byte for byte
    "$STUBS_DIR/gemini" --session-id "$(meta session_id)" </dev/null > "$TEST_TMP/expected" 2>/dev/null || true
    cmp "$TEST_TMP/expected" "$JOBS_ROOT/logs/$runid.json"
    if [ "$5" = none ]; then
      [ ! -e "$JOBS_ROOT/logs/$runid.result.json" ]
    else
      jq -e "$5" "$JOBS_ROOT/logs/$runid.result.json" >/dev/null
    fi
  }
  expect ok      done   0  ''    '.runtime == "gemini" and .status == "ok" and .is_error == false and .final_text == "ok"
                                  and .cost_usd == null and .turns == 0 and .tokens == {"in":9994,"cached":0,"cache_write":null,"out":1,"thinking":168}'
  [ "$(meta cost_usd)" = "" ]   # null cost stays blank in the .meta, never 0
  [ "$(cat "$JOBS_ROOT/logs/$(only_runid).txt")" = ok ]
  expect error   failed 1  ''    none
  expect nonzero failed 9  ''    none
  expect turns   failed 53 turns '.status == "max_turns" and .is_error == false'
  tail -1 "$JOBS_ROOT/logs/$(only_runid).stderr" | grep -q 'limit=turns'
}

@test "rt-gemini run: the CLI gets Vertex settings from gemini.env and no Claude or OpenAI credential" {
  export FAKE_GEMINI_ENV="$TEST_TMP/env"
  export CLAUDE_CODE_OAUTH_TOKEN=claude-token-in-env ANTHROPIC_API_KEY=anthropic-key-in-env OPENAI_API_KEY=openai-key-in-env
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' claude-token-from-file > "$CLAUDE_RUNNER_TOKEN_ENV"
  drop_spec "env.json" '{"prompt":"go","runtime":"gemini"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  grep -qx 'GOOGLE_GENAI_USE_VERTEXAI=true' "$FAKE_GEMINI_ENV"
  grep -qx 'GOOGLE_CLOUD_PROJECT=fake-project-4471' "$FAKE_GEMINI_ENV"
  grep -qx 'GOOGLE_CLOUD_LOCATION=global' "$FAKE_GEMINI_ENV"
  grep -qx 'GEMINI_CLI_TRUST_WORKSPACE=true' "$FAKE_GEMINI_ENV"
  [ "$(grep -cE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|OPENAI_API_KEY|CODEX_API_KEY)=' "$FAKE_GEMINI_ENV")" -eq 0 ]
  [ "$(grep -rc -e claude-token -e fake-project-4471 "$JOBS_ROOT/logs" | awk -F: '{n += $NF} END {print n + 0}')" -eq 0 ]
}

@test "rt-gemini run: an ambient Gemini or Google API key never reaches the CLI over the Vertex account (#204 review)" {
  export FAKE_GEMINI_ENV="$TEST_TMP/env"
  export GEMINI_API_KEY=ambient-gemini-key GOOGLE_API_KEY=ambient-google-key GOOGLE_GENAI_API_KEY=ambient-genai-key
  drop_spec "apikey.json" '{"prompt":"go","runtime":"gemini"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in done)" -eq 1 ]
  grep -qx 'GOOGLE_GENAI_USE_VERTEXAI=true' "$FAKE_GEMINI_ENV"
  [ "$(grep -cE '^(GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_GENAI_API_KEY)=' "$FAKE_GEMINI_ENV")" -eq 0 ]
}

@test "rt-gemini run: the agent's git keeps the GitHub credential helper through the shell tool's overrides (#170)" {
  export FAKE_GEMINI_ENV="$TEST_TMP/env"
  # A probe helper stands in for gh-credential-helper, so no token is ever minted.
  git config --global "$HELPER_KEY" '!f(){ echo username=probe-user; echo password=probe-pass; }; f'
  rt_run
  [ "$RC" -eq 0 ]
  [ ! -s "$TEST_TMP/raw.stderr" ]
  params="$(sed -n 's/^GIT_CONFIG_PARAMETERS=//p' "$FAKE_GEMINI_ENV")"
  [ -n "$params" ]
  [ -z "$(cred_user github.com "")" ]                  # the overrides alone clear it
  [ "$(cred_user github.com "$params")" = probe-user ] # the parameters bring it back
  [ -z "$(cred_user example.com "$params")" ]          # and never for another host
}

@test "rt-gemini run: an existing GIT_CONFIG_PARAMETERS is kept; no helper in ~/.gitconfig is one stderr line" {
  export FAKE_GEMINI_ENV="$TEST_TMP/env"
  export GIT_CONFIG_PARAMETERS="'core.quotepath'='false'"
  rt_run
  [ "$RC" -eq 0 ]
  grep -qxF "GIT_CONFIG_PARAMETERS='core.quotepath'='false' '$HELPER_KEY'='/usr/local/bin/gh-credential-helper'" "$FAKE_GEMINI_ENV"
  unset GIT_CONFIG_PARAMETERS
  git config --global --unset "$HELPER_KEY"
  rt_run
  [ "$RC" -eq 0 ]
  [ "$(wc -l < "$TEST_TMP/raw.stderr")" -eq 1 ]
  grep -qF "no $HELPER_KEY in ~/.gitconfig" "$TEST_TMP/raw.stderr"
  [ "$(grep -c '^GIT_CONFIG_PARAMETERS=' "$FAKE_GEMINI_ENV")" -eq 0 ]
}

@test "rt-gemini run: each run gets its own Gemini home outside the checkout, with the fleet's settings" {
  export FAKE_GEMINI_ENV="$TEST_TMP/env"
  rt_run --max-turns 7
  [ "$RC" -eq 0 ]
  h="$(home_of "$SID")"
  grep -qx "GEMINI_CLI_HOME=$h" "$FAKE_GEMINI_ENV"
  case "$h" in "$CLAUDE_RUNNER_CWD"/*) false ;; esac
  jq -e '. == {privacy: {usageStatisticsEnabled: false},
               context: {fileName: ["GEMINI.md", "AGENTS.md", "CLAUDE.md"]},
               model: {maxSessionTurns: 7}}' "$h/.gemini/settings.json"
  [ -z "$(ls -A "$CLAUDE_RUNNER_CWD")" ]   # nothing lands in the checkout
  rt_run   # no turn cap: no model block, so the CLI's own default (unlimited)
  [ "$RC" -eq 0 ]
  jq -e 'has("model") | not' "$h/.gemini/settings.json"
}

@test "rt-gemini run: a budget or allowed_tools it cannot honour is one stderr line each; the run goes ahead" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv"
  rt_run --max-budget-usd 1.5 --allowed-tools 'Bash(git:*) Read'
  [ "$RC" -eq 0 ]
  [ -s "$TEST_TMP/raw.json" ]
  [ "$(wc -l < "$TEST_TMP/raw.stderr")" -eq 2 ]
  grep -q 'max_budget_usd=1.5 is not enforced' "$TEST_TMP/raw.stderr"
  grep -q 'allowed_tools is not passed to Gemini' "$TEST_TMP/raw.stderr"
  [ "$(grep -c -e budget -e allowed -e Bash "$FAKE_GEMINI_ARGS")" -eq 0 ]
  rt_run
  [ "$RC" -eq 0 ]
  [ ! -s "$TEST_TMP/raw.stderr" ]
}

@test "rt-gemini run: a job with a turn cap is refused when its checkout's settings name maxSessionTurns; the CLI never starts (#205)" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv"
  mkdir -p "$CLAUDE_RUNNER_CWD/.gemini"
  printf '{"model":{"maxSessionTurns":-1}}\n' > "$CLAUDE_RUNNER_CWD/.gemini/settings.json"
  rt_run --max-turns 5
  [ "$RC" -eq 3 ]
  grep -qF "sets maxSessionTurns, which would override this job's max_turns=5" "$TEST_TMP/raw.stderr"
  [ ! -e "$FAKE_GEMINI_ARGS" ]
  rt_run   # no cap of its own: the checkout's setting is the only one, so it runs
  [ "$RC" -eq 0 ]
}

@test "rt-gemini run: an escaped maxSessionTurns key, or a file jq cannot parse, is refused for a capped job too (#205)" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv"
  mkdir -p "$CLAUDE_RUNNER_CWD/.gemini"
  printf '{"model":{"maxSession\\u0054urns":-1}}\n' > "$CLAUDE_RUNNER_CWD/.gemini/settings.json"
  ! grep -q maxSessionTurns "$CLAUDE_RUNNER_CWD/.gemini/settings.json"   # the raw text does not name it
  rt_run --max-turns 5
  [ "$RC" -eq 3 ]
  grep -qF "sets maxSessionTurns, which would override this job's max_turns=5" "$TEST_TMP/raw.stderr"
  printf '{\n  // a comment the CLI accepts and jq does not\n  "ui": {}\n}\n' > "$CLAUDE_RUNNER_CWD/.gemini/settings.json"
  rt_run --max-turns 5
  [ "$RC" -eq 3 ]
  grep -qF "cannot be parsed as JSON" "$TEST_TMP/raw.stderr"
  [ ! -e "$FAKE_GEMINI_ARGS" ]
}

@test "rt-gemini run: a checkout carrying .gemini/settings.json gets a one-line note" {
  mkdir -p "$CLAUDE_RUNNER_CWD/.gemini"
  printf '{}\n' > "$CLAUDE_RUNNER_CWD/.gemini/settings.json"
  rt_run
  [ "$RC" -eq 0 ]
  [ "$(wc -l < "$TEST_TMP/raw.stderr")" -eq 1 ]
  grep -qF "the checkout's .gemini/settings.json overrides" "$TEST_TMP/raw.stderr"
}

@test "rt-gemini run: no readable credentials file is exit 3 with one line, and the CLI never starts" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv"
  rm -f "$CLAUDE_RUNNER_GEMINI_ENV"
  rt_run
  [ "$RC" -eq 3 ]
  [ "$(wc -l < "$TEST_TMP/raw.stderr")" -eq 1 ]
  grep -qF "cannot read the Gemini credentials file $CLAUDE_RUNNER_GEMINI_ENV" "$TEST_TMP/raw.stderr"
  [ ! -e "$FAKE_GEMINI_ARGS" ]
  [ ! -s "$TEST_TMP/raw.json" ]
  mkdir "$CLAUDE_RUNNER_GEMINI_ENV"   # a directory is not a credentials file
  rt_run
  [ "$RC" -eq 3 ]
  [ ! -e "$FAKE_GEMINI_ARGS" ]
  rmdir "$CLAUDE_RUNNER_GEMINI_ENV"
  if [ "$(id -u)" -ne 0 ]; then   # root reads a mode-000 file, so this half needs a user
    printf 'GOOGLE_GENAI_USE_VERTEXAI=true\n' > "$CLAUDE_RUNNER_GEMINI_ENV"
    chmod 000 "$CLAUDE_RUNNER_GEMINI_ENV"
    rt_run
    [ "$RC" -eq 3 ]
    [ ! -e "$FAKE_GEMINI_ARGS" ]
  fi
}

@test "rt-gemini run: an unreadable service-account key is exit 3, and no value from gemini.env is printed" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv"
  printf 'GOOGLE_APPLICATION_CREDENTIALS=%s\n' "$TEST_TMP/no-such-sa-key.json" >> "$CLAUDE_RUNNER_GEMINI_ENV"
  rt_run
  [ "$RC" -eq 3 ]
  [ "$(wc -l < "$TEST_TMP/raw.stderr")" -eq 1 ]
  grep -q 'GOOGLE_APPLICATION_CREDENTIALS' "$TEST_TMP/raw.stderr"
  [ "$(grep -c no-such-sa-key "$TEST_TMP/raw.stderr")" -eq 0 ]
  [ ! -e "$FAKE_GEMINI_ARGS" ]
  # Readable now. A malformed line in the file is skipped without echoing it.
  printf '{}\n' > "$TEST_TMP/no-such-sa-key.json"
  printf 'leaked-secret-value-0042\n' >> "$CLAUDE_RUNNER_GEMINI_ENV"
  rt_run
  [ "$RC" -eq 0 ]
  [ "$(grep -c leaked-secret-value "$TEST_TMP/raw.stderr")" -eq 0 ]
}

@test "rt-gemini run: a session id or turn cap the CLI would refuse is a usage error before anything runs" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv"
  run "$RT" run --session-id '../escape' </dev/null
  [ "$status" -eq 2 ]
  run "$RT" run --session-id '' </dev/null
  [ "$status" -eq 2 ]
  run "$RT" run --session-id "$SID" --max-turns 0 </dev/null
  [ "$status" -eq 2 ]
  run "$RT" run --session-id "$SID" --max-turns 2x </dev/null
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE_GEMINI_ARGS" ]
  [ ! -e "$HOME/.local/state/claytonia" ]
}

@test "rt-gemini run: homes older than a week are swept; fresh ones and other names stay" {
  root="$HOME/.local/state/claytonia/gemini"
  old=aaaaaaaa-0000-4000-8000-000000000000; fresh=bbbbbbbb-0000-4000-8000-000000000000
  mkdir -p "$root/$old/.gemini" "$root/$fresh/.gemini" "$root/not-a-session"
  touch -d '8 days ago' "$root/$old" "$root/not-a-session"
  touch -d '6 days ago' "$root/$fresh"
  rt_run
  [ "$RC" -eq 0 ]
  [ ! -e "$root/$old" ]
  [ -d "$root/$fresh" ]
  [ -d "$root/not-a-session" ]
  [ -d "$root/$SID" ]
}

@test "rt-gemini normalize: the captured 0.66 output, with null cost and silence" {
  jq -c --arg s "$SID" '.session_id = $s' "$FIX/gemini-ok.json" > "$TEST_TMP/raw.json"
  norm "$TEST_TMP/raw.json" --session-id "$SID" --model gemini-3.5-flash-lite
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e --arg s "$SID" '. == {runtime: "gemini", model: "gemini-3.5-flash-lite", session_id: $s,
      status: "ok", is_error: false, turns: 0,
      tokens: {in: 9994, cached: 0, cache_write: null, out: 1, thinking: 168},
      tokens_by_model: {"gemini-3.5-flash-lite": {in: 9994, cached: 0, cache_write: null, out: 1, thinking: 168}},
      cost_usd: null, final_text: "ok"}' "$TEST_TMP/res"
  [ "$(cat "$TEST_TMP/txt")" = ok ]
}

@test "rt-gemini normalize: tokens are disjoint, per model and summed, from .tokens only" {
  # cached is inside prompt (input = prompt - cached); tool-use prompt tokens are
  # input outside prompt; thoughts are outside candidates. roles repeat the counts.
  # No cache write is charged on this path, so cache_write is null (#173).
  cat > "$TEST_TMP/raw.json" <<'EOF'
{"session_id":"x","response":"done","stats":{"models":{
 "m1":{"tokens":{"input":100,"prompt":1100,"candidates":10,"total":1130,"cached":1000,"thoughts":20,"tool":0},
       "roles":{"main":{"tokens":{"input":100,"prompt":1100,"candidates":10,"total":1130,"cached":1000,"thoughts":20,"tool":0}}}},
 "m2":{"tokens":{"input":5,"prompt":5,"candidates":2,"total":10,"cached":0,"thoughts":0,"tool":3}}},
 "tools":{"totalCalls":7}}}
EOF
  norm "$TEST_TMP/raw.json" --session-id S
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e '.tokens == {"in":108,"cached":1000,"cache_write":null,"out":12,"thinking":20} and .turns == 7
         and .model == null and .session_id == "S" and .status == "ok"' "$TEST_TMP/res"
  jq -e '.tokens_by_model == {"m1": {in: 100, cached: 1000, cache_write: null, out: 10, thinking: 20},
                              "m2": {in: 8, cached: 0, cache_write: null, out: 2, thinking: 0}}' "$TEST_TMP/res"
  # the counts add up to the CLI's own totals, overall and per model
  [ "$(jq '.tokens | .in + .cached + .out + .thinking' "$TEST_TMP/res")" -eq 1140 ]
  [ "$(jq '.tokens_by_model.m1 | .in + .cached + .out + .thinking' "$TEST_TMP/res")" -eq 1130 ]
  [ "$(jq '.tokens_by_model.m2 | .in + .cached + .out + .thinking' "$TEST_TMP/res")" -eq 10 ]
}

@test "rt-gemini normalize: a captured multi-model run keeps every model, a zero-token one included (#173)" {
  # The stats block of gate job 211 (2026-11-04): the router, a main model that took
  # zero tokens, and the model that did the work. input is prompt - cached on each.
  cat > "$TEST_TMP/raw.json" <<'EOF'
{"session_id":"x","response":"done","stats":{"models":{
 "gemini-3.5-flash-lite":{"tokens":{"input":5690,"prompt":5690,"candidates":48,"total":6315,"cached":0,"thoughts":577,"tool":0}},
 "gemini-3.8-flash":{"tokens":{"input":0,"prompt":0,"candidates":0,"total":0,"cached":0,"thoughts":0,"tool":0}},
 "gemini-3.1-pro-preview":{"tokens":{"input":43936,"prompt":175607,"candidates":765,"total":177730,"cached":131671,"thoughts":1358,"tool":0}}},
 "tools":{"totalCalls":9}}}
EOF
  norm "$TEST_TMP/raw.json" --session-id S
  [ "$status" -eq 0 ]
  jq -e '(.tokens_by_model | keys) == ["gemini-3.1-pro-preview","gemini-3.5-flash-lite","gemini-3.8-flash"]
         and .tokens_by_model["gemini-3.8-flash"] == {in: 0, cached: 0, cache_write: null, out: 0, thinking: 0}
         and .tokens == {in: 49626, cached: 131671, cache_write: null, out: 813, thinking: 1935}' "$TEST_TMP/res"
}

@test "rt-gemini normalize: the client's turn-cap warning is max_turns, not ok" {
  printf '%s\n' '{"session_id":"x","response":"partial","stats":{"models":{},"tools":{"totalCalls":3}},
    "warnings":["Maximum session turns exceeded"]}' > "$TEST_TMP/raw.json"
  norm "$TEST_TMP/raw.json" --session-id S
  [ "$status" -eq 0 ]
  jq -e '.status == "max_turns" and .is_error == false and .turns == 3 and .final_text == "partial"' "$TEST_TMP/res"
}

@test "rt-gemini normalize: an error on stdout is an error; a run with no response is never ok" {
  printf '%s\n' '{"session_id":"x","response":"","stats":{},"error":{"type":"INVALID_STREAM","message":"m"}}' > "$TEST_TMP/raw.json"
  norm "$TEST_TMP/raw.json" --session-id S
  [ "$status" -eq 0 ]
  jq -e '.status == "error" and .is_error == true' "$TEST_TMP/res"
  printf '%s\n' '{"session_id":"x","stats":{}}' > "$TEST_TMP/raw.json"
  norm "$TEST_TMP/raw.json" --session-id S
  [ "$status" -eq 0 ]
  jq -e '.status == "error" and .is_error == false and .final_text == ""' "$TEST_TMP/res"
}

@test "rt-gemini normalize: nothing on stdout yields a result only for the CLI's own turn-cap report" {
  mkdir -p "$TEST_TMP/logs"
  : > "$TEST_TMP/logs/r.json"
  FAKE_GEMINI_MODE=turns "$STUBS_DIR/gemini" --session-id "$SID" </dev/null 2> "$TEST_TMP/logs/r.stderr" || true
  norm "$TEST_TMP/logs/r.json" --session-id "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  jq -e --arg s "$SID" '.status == "max_turns" and .is_error == false and .session_id == $s
                        and .final_text == "" and .cost_usd == null' "$TEST_TMP/res"
  # Any other failure on stderr: no result, the exit code decides.
  cp "$FIX/gemini-error.stderr" "$TEST_TMP/logs/r.stderr"
  norm "$TEST_TMP/logs/r.json" --session-id "$SID"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/res" ]
  # Only run-job's own pairing (<runid>.json beside <runid>.stderr) is read.
  : > "$TEST_TMP/logs/r.raw"
  FAKE_GEMINI_MODE=turns "$STUBS_DIR/gemini" </dev/null 2> "$TEST_TMP/logs/r.raw.stderr" || true
  norm "$TEST_TMP/logs/r.raw" --session-id "$SID"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/res" ]
}

@test "rt-gemini normalize: a malformed stats block costs the counts, never the result" {
  printf '%s\n' '{"response":"r","stats":{"models":{"m":{"tokens":{"input":"lots"}}},"tools":{"totalCalls":"x"}}}' > "$TEST_TMP/raw.json"
  norm "$TEST_TMP/raw.json" --session-id S
  [ "$status" -eq 0 ]
  jq -e '.status == "ok" and .tokens == {"in":null,"cached":null,"cache_write":null,"out":null,"thinking":null}
         and .tokens_by_model == null and .turns == null' "$TEST_TMP/res"
}

@test "rt-gemini normalize: output that is not JSON gets no result, and the raw text as .txt" {
  printf 'crashed before JSON\n' > "$TEST_TMP/raw.json"
  printf '{"stale":true}\n' > "$TEST_TMP/res"
  norm "$TEST_TMP/raw.json" --session-id S
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TEST_TMP/res" ]
  cmp "$TEST_TMP/raw.json" "$TEST_TMP/txt"
  for raw in '' '   '; do   # a killed run, on any jq
    printf '%s' "$raw" > "$TEST_TMP/raw.json"
    norm "$TEST_TMP/raw.json" --session-id S
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TMP/res" ]
    [ ! -e "$TEST_TMP/res.tmp" ]
    [ -e "$TEST_TMP/txt" ]
  done
}

@test "rt-gemini normalize: a result it cannot write is an exit 1, still silent" {
  cp "$FIX/gemini-ok.json" "$TEST_TMP/raw.json"
  run "$RT" normalize --raw "$TEST_TMP/raw.json" --result "$TEST_TMP/no-such-dir/res" --txt "$TEST_TMP/txt" --session-id S
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "rt-gemini enforces: the turn cap yes (maxSessionTurns), the spend cap no (#173)" {
  run "$RT" enforces --limit turns
  [ "$status" -eq 0 ]
  run "$RT" enforces --limit budget
  [ "$status" -eq 1 ]
}

@test "rt-gemini accepts-model: gemini-* ids and 0.66's aliases; Claude and OpenAI models are no" {
  for m in gemini-3.5-flash-lite gemini-2.5-pro gemini-3.1-pro-preview auto pro flash flash-lite \
           auto-gemini-3 auto-gemini-2.5; do
    run "$RT" accepts-model --model "$m"
    [ "$status" -eq 0 ]
  done
  for m in sonnet opus haiku fable opusplan default claude-opus-5-5 'sonnet[1m]' gpt-5 o3 \
           gemma-3 gemini- auto-gemini- ''; do
    run "$RT" accepts-model --model "$m"
    [ "$status" -eq 1 ]
  done
}

@test "rt-gemini through run-job: a spec naming a Claude model is refused at claim, before the CLI" {
  export FAKE_GEMINI_ARGS="$TEST_TMP/argv"
  drop_spec "claude-model.json" '{"prompt":"go","runtime":"gemini","model":"sonnet"}'
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(count_in failed)" -eq 1 ]
  grep -q "model 'sonnet' is not a gemini model" "$JOBS_ROOT"/logs/*.stderr
  [ ! -e "$FAKE_GEMINI_ARGS" ]
}

@test "rt-gemini transcript: the run's session file is copied; a namesake or a missing one is not" {
  d="$(home_of "$SID")/.gemini/tmp/work/chats"
  mkdir -p "$d/$SID"
  printf '{"sessionId":"%s","kind":"main"}\n{"type":"user"}\n' "$SID" > "$d/session-2026-11-04T10-00-11111111.jsonl"
  printf '{"sessionId":"11111111-0000-4000-8000-000000000000"}\n' > "$d/session-2026-11-04T09-00-11111111.jsonl"
  printf '{"sessionId":"sub"}\n' > "$d/$SID/agent-1.jsonl"
  run "$RT" transcript --session-id "$SID" --out "$TEST_TMP/t.jsonl"
  [ "$status" -eq 0 ]
  cmp "$d/session-2026-11-04T10-00-11111111.jsonl" "$TEST_TMP/t.jsonl"
  rm "$d/session-2026-11-04T10-00-11111111.jsonl"
  run "$RT" transcript --session-id "$SID" --out "$TEST_TMP/u.jsonl"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/u.jsonl" ]
  run "$RT" transcript --session-id '../x' --out "$TEST_TMP/v.jsonl"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMP/v.jsonl" ]
}

@test "rt-gemini: an unknown subcommand or option, or a missing value, is refused" {
  run "$RT" fly
  [ "$status" -eq 2 ]
  run "$RT" run --bogus x
  [ "$status" -eq 2 ]
  run "$RT" normalize --raw "$TEST_TMP/raw.json"
  [ "$status" -eq 2 ]
  run "$RT" transcript --session-id
  [ "$status" -eq 2 ]
}
