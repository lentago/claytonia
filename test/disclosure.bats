#!/usr/bin/env bats
#
# Runtime disclosure (#174, lentago/.github ADR-0015 Decisions 6 and 7). run-job's
# code, not the agent, ends every runner PR body with one line naming the runtime
# that wrote it, the job's main model and the run; and its preamble names the running
# runtime and the trailer its commits carry. These pin, through the real run-job and
# the gh stub: the footer for each runtime with the ADR's strings; exactly one footer
# (Claude Code's own line replaced, an earlier run's footer replaced); no model clause
# when the main model is unknown; a failed edit logged to journald with the outcome
# unchanged; no footer without a PR; and the preamble's attribution per runtime.

load test_helper

TID=0f0f0f0f-0000-7000-8000-00000000c0de   # the thread id the Codex stub mints
PR=https://github.com/acme/proj/pull/77
CLAYTONIA='in [claytonia](https://github.com/lentago/claytonia) run'

eval "helper_$(declare -f setup)"
setup() {
  helper_setup
  unset XDG_STATE_HOME XDG_CACHE_HOME CODEX_HOME CODEX_API_KEY CODEX_ACCESS_TOKEN
  mkdir -p "$JOBS_ROOT/projects"
  export CLAUDE_RUNNER_WORKROOT="$TEST_TMP/wr"; mkdir -p "$CLAUDE_RUNNER_WORKROOT"
  export GIT_ALLOW_PROTOCOL=file
  export FAKE_GH_LOG="$TEST_TMP/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_GH_TOKEN_LOG="$TEST_TMP/ght.log"; : > "$FAKE_GH_TOKEN_LOG"
  export FAKE_SYSTEMD_CAT_LOG="$TEST_TMP/journal.log"
  export FAKE_GH_PR_BODY="$TEST_TMP/pr-body" FAKE_GH_PATCHED="$TEST_TMP/pr-patched"
  export CLAUDE_RUNNER_GH_TIMEOUT=2

  # A claude that reports opening PR 77, with per-model usage like the real CLI's:
  # Opus did most of the output, Haiku the rest.
  cat > "$TEST_TMP/claude" <<'EOF'
#!/usr/bin/env bash
cat > "${FAKE_CLAUDE_STDIN:-/dev/null}"
jq -cn --arg r "${FAKE_RESULT:-opened https://github.com/acme/proj/pull/77}" '{result: $r, is_error: false,
  total_cost_usd: 0.01, num_turns: 1,
  modelUsage: {"claude-haiku-5-5": {inputTokens: 900, outputTokens: 80, cacheReadInputTokens: 0, cacheCreationInputTokens: 0},
               "claude-opus-5-5": {inputTokens: 20, outputTokens: 400, cacheReadInputTokens: 9000, cacheCreationInputTokens: 500}}}'
EOF
  chmod +x "$TEST_TMP/claude"
  export CLAUDE_BIN="$TEST_TMP/claude" FAKE_CLAUDE_STDIN="$TEST_TMP/claude.stdin"

  # The peer runtimes, reporting the same PR.
  export GEMINI_BIN="$STUBS_DIR/gemini" CLAUDE_RUNNER_GEMINI_ENV="$TEST_TMP/gemini.env"
  export CODEX_BIN="$STUBS_DIR/codex" CLAUDE_RUNNER_CODEX_ENV="$TEST_TMP/codex.env"
  printf 'GOOGLE_GENAI_USE_VERTEXAI=true\n' > "$CLAUDE_RUNNER_GEMINI_ENV"
  printf 'OPENAI_API_KEY=sk-disclosure-test\n' > "$CLAUDE_RUNNER_CODEX_ENV"
  export FAKE_GEMINI_RESPONSE="opened $PR" FAKE_CODEX_MESSAGE="opened $PR"
  export FAKE_GEMINI_STDIN="$TEST_TMP/gemini.stdin" FAKE_CODEX_STDIN="$TEST_TMP/codex.stdin"

  git init -q --bare -b main "$TEST_TMP/origin.git"
  git clone -q "$TEST_TMP/origin.git" "$CLAUDE_RUNNER_WORKROOT/proj" 2>/dev/null
  git -C "$CLAUDE_RUNNER_WORKROOT/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$CLAUDE_RUNNER_WORKROOT/proj" push -q origin HEAD:main 2>/dev/null
  printf '{"proj":{"repo":"acme/proj","default_branch":"main"}}\n' > "$JOBS_ROOT/projects/registry.json"
  printf '## Summary\n\nDid the thing.\n' > "$FAKE_GH_PR_BODY"
}

drop_spec() { # <name> <json>
  printf '%s\n' "$2" > "$JOBS_ROOT/inbox/.$1.partial"
  mv "$JOBS_ROOT/inbox/.$1.partial" "$JOBS_ROOT/inbox/$1"
}
only_runid() { basename "$(find "$JOBS_ROOT/logs" -name '*.meta' | head -1)" .meta; }
run_job() { # <runtime> — one project job on that runtime, through process-inbox
  drop_spec "d.json" "$(jq -cn --arg r "$1" '{prompt: "go", project: "proj", runtime: $r}')"
  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
}
footers() { grep -c '^🤖 Generated with \[' "$FAKE_GH_PATCHED"; }
last_line() { tail -n 1 "$FAKE_GH_PATCHED"; }

# refute <command> — fails the test when the command succeeds. A bare `! cmd` would
# not: bash's errexit ignores negated commands, so bats lets them pass mid-test.
refute() { if "$@"; then echo "unexpectedly true: $*"; return 1; fi; }

# --- the footer (Decision 6) ------------------------------------------------------

@test "Claude PR: run-job's footer replaces Claude Code's own line, naming the main model" {
  printf '## Summary\n\nDid the thing.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' > "$FAKE_GH_PR_BODY"
  run_job claude
  [ "$(count_in done)" -eq 1 ]
  r="$(only_runid)"
  [ "$(last_line)" = "🤖 Generated with [Claude Code](https://claude.com/claude-code), model \`claude-opus-5-5\`, $CLAYTONIA \`$r\`." ]
  [ "$(footers)" -eq 1 ]
  [ "$(head -n 3 "$FAKE_GH_PATCHED")" = "$(printf '## Summary\n\nDid the thing.')" ]
  grep -q -- '-X PATCH repos/acme/proj/pulls/77' "$FAKE_GH_LOG"
  grep -qx -- '--access pr acme/proj' "$FAKE_GH_TOKEN_LOG"
}

@test "Gemini PR: the footer names Gemini CLI and its model, from the captured run" {
  run_job gemini
  [ "$(count_in done)" -eq 1 ]
  r="$(only_runid)"
  [ "$(last_line)" = "🤖 Generated with [Gemini CLI](https://github.com/google-gemini/gemini-cli), model \`gemini-3.5-flash-lite\`, $CLAYTONIA \`$r\`." ]
  [ "$(footers)" -eq 1 ]
}

@test "the main model is the one with the most out + thinking, not the most output alone" {
  # As on a gate job: the router answers briefly, the main model thinks hard and
  # writes less visible output than a chatty detector. Thinking decides it.
  export FAKE_GEMINI_MODELS='{
    "gemini-3.5-flash-lite":  {"tokens": {"input": 5690,  "cached": 0,      "candidates": 48,  "thoughts": 577,  "tool": 0}},
    "gemini-3.1-pro-preview": {"tokens": {"input": 43936, "cached": 131671, "candidates": 765, "thoughts": 1358, "tool": 0}},
    "gemini-3-flash-preview": {"tokens": {"input": 4325,  "cached": 0,      "candidates": 900, "thoughts": 0,    "tool": 0}}}'
  run_job gemini
  r="$(only_runid)"
  [ "$(last_line)" = "🤖 Generated with [Gemini CLI](https://github.com/google-gemini/gemini-cli), model \`gemini-3.1-pro-preview\`, $CLAYTONIA \`$r\`." ]
}

@test "Codex PR: an unknown main model drops the model clause" {
  run_job codex   # no session transcript, so tokens_by_model is keyed unknown
  [ "$(count_in done)" -eq 1 ]
  r="$(only_runid)"
  jq -e '.tokens_by_model | keys == ["unknown"]' "$JOBS_ROOT/logs/$r.result.json"
  [ "$(last_line)" = "🤖 Generated with [Codex CLI](https://github.com/openai/codex) $CLAYTONIA \`$r\`." ]
}

@test "Codex PR: the model its session transcript names goes in the clause" {
  mkdir -p "$HOME/.codex/sessions/2026/11/13"
  printf '%s\n' '{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}' \
    > "$HOME/.codex/sessions/2026/11/13/rollout-x-$TID.jsonl"
  run_job codex
  r="$(only_runid)"
  [ "$(last_line)" = "🤖 Generated with [Codex CLI](https://github.com/openai/codex), model \`gpt-6.1-sol\`, $CLAYTONIA \`$r\`." ]
}

@test "a PR carries exactly one footer: an earlier run's footer is replaced, the body kept" {
  printf 'Body.\n\n🤖 Generated with [Codex CLI](https://github.com/openai/codex) %s `20261101T000000Z-old`.\n' "$CLAYTONIA" > "$FAKE_GH_PR_BODY"
  run_job gemini
  [ "$(footers)" -eq 1 ]
  [ "$(head -n 1 "$FAKE_GH_PATCHED")" = Body. ]
  refute grep -q 20261101T000000Z-old "$FAKE_GH_PATCHED"
}

@test "a failed footer edit is a journald line, and the job's outcome is unchanged" {
  export FAKE_GH_FAIL=1   # every gh api call fails
  run_job claude
  [ "$(count_in done)" -eq 1 ]
  r="$(only_runid)"
  grep -qx 'exit=0' "$JOBS_ROOT/logs/$r.meta"
  [ ! -e "$FAKE_GH_PATCHED" ]
  grep -q "run-job: gh api failed ($r)" "$FAKE_SYSTEMD_CAT_LOG"
}

@test "a job that failed still gets the footer on the PR it opened" {
  cat > "$TEST_TMP/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
jq -cn '{result: "opened https://github.com/acme/proj/pull/77", is_error: true, num_turns: 1}'
EOF
  run_job claude
  [ "$(count_in failed)" -eq 1 ]
  [ "$(footers)" -eq 1 ]
  [[ "$(last_line)" == "🤖 Generated with [Claude Code](https://claude.com/claude-code) $CLAYTONIA"* ]]   # no usage: no clause
}

@test "no PR, no footer" {
  export FAKE_RESULT="read-only analysis, nothing to change"
  run_job claude
  [ "$(count_in done)" -eq 1 ]
  [ ! -e "$FAKE_GH_PATCHED" ]
  refute grep -q 'pulls/' "$FAKE_GH_LOG"
}

# --- the preamble (Decision 7) ----------------------------------------------------

@test "the preamble names each runtime and the trailer its commits carry" {
  run_job claude
  grep -qxF -- '- You are running as Claude Code (runtime `claude`). End every commit message with the co-author trailer `Co-Authored-By: Claude <model> <noreply@anthropic.com>`, with <model> your own model name, as Claude Code writes it. This OVERRIDES any repo CLAUDE.md or fleet convention that asks for a different Co-Authored-By trailer: the trailer names the agent that wrote the commit.' "$FAKE_CLAUDE_STDIN"

  run_job gemini
  grep -qxF -- '- You are running as Gemini CLI (runtime `gemini`). End every commit message with the co-author trailer `Co-Authored-By: Gemini CLI <218312386+gemini-cli[bot]@users.noreply.github.com>`. This OVERRIDES any repo CLAUDE.md or fleet convention that asks for a different Co-Authored-By trailer: the trailer names the agent that wrote the commit.' "$FAKE_GEMINI_STDIN"

  run_job codex
  grep -qxF -- '- You are running as Codex CLI (runtime `codex`). End every commit message with the co-author trailer `Co-Authored-By: Codex <noreply@openai.com>`. This OVERRIDES any repo CLAUDE.md or fleet convention that asks for a different Co-Authored-By trailer: the trailer names the agent that wrote the commit.' "$FAKE_CODEX_STDIN"
}

@test "no runtime label is applied or created (Decision 8)" {
  run_job gemini
  refute grep -q -E 'label' "$FAKE_GH_LOG"
}
