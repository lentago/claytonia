#!/usr/bin/env bats
#
# The runtime key (#168): a job names its runtime the way it names its model,
# spec > project registry > CLAUDE_RUNNER_RUNTIME > claude, and run-job refuses
# the job at claim time, before any checkout, when that runtime has no adapter or
# a spec model is not one it takes. Model defaults are runtime-scoped: the
# registry's applies only to the entry's runtime, the global only to the fleet
# default. A second adapter, rt-fake, sits beside a copy of bin/ so the suite can
# see which runtime ran and what it was given.

load test_helper

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-runtime.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"/{inbox,processing,done,failed,logs,workers,projects,scheduled}
  export CLAUDE_RUNNER_CWD="$TEST_TMP/work"; mkdir -p "$CLAUDE_RUNNER_CWD"
  export HOME="$TEST_TMP/home"; mkdir -p "$HOME"
  export CLAUDE_RUNNER_WORKROOT="$TEST_TMP/wr"; mkdir -p "$CLAUDE_RUNNER_WORKROOT"
  export CLAUDE_INBOX_LOCK="$TEST_TMP/inbox.lock"
  export CLAUDE_BIN="$STUBS_DIR/claude"
  export CLAUDE_RUNNER_PATH="$STUBS_DIR:$PATH"
  export PATH="$STUBS_DIR:$PATH"
  export FAKE_CLAUDE_MODE=ok
  export FAKE_CLAUDE_ARGS="$TEST_TMP/claude.argv"
  export FAKE_RT_ARGS="$TEST_TMP/fake.argv"
  export GIT_ALLOW_PROTOCOL=file   # a stray clone fails fast instead of reaching GitHub
  unset CLAUDE_RUNNER_RUNTIME CLAUDE_RUNNER_MODEL

  # run-job finds its adapters beside itself, so run a copy of bin/ with rt-fake added.
  BIN="$TEST_TMP/bin"; cp -r "$REPO_ROOT/bin" "$BIN"
  export CLAUDE_RUNNER_BIN="$BIN"
  cat > "$BIN/rt-fake" <<'EOF'
#!/usr/bin/env bash
# rt-fake: a second runtime for the tests. Takes only fake-* models.
cmd="$1"; shift
case "$cmd" in
  run) cat >/dev/null; printf '%s\n' "$@" > "$FAKE_RT_ARGS"; echo '{"fake":true}' ;;
  normalize)
    while [ $# -gt 1 ]; do case "$1" in --result) res="$2" ;; --txt) txt="$2" ;; esac; shift 2; done
    echo "fake ok" > "$txt"
    echo '{"runtime":"fake","status":"ok","is_error":false,"turns":1,"cost_usd":null}' > "$res" ;;
  accepts-model) case "${2:-}" in fake-*) exit 0 ;; *) exit 1 ;; esac ;;
  transcript) ;;
esac
exit 0
EOF
  chmod +x "$BIN/rt-fake"

  # Local origin + pre-made checkouts, so project jobs check out with no network.
  git init -q --bare -b main "$TEST_TMP/origin.git"
  for p in proj fakeproj; do
    git clone -q "$TEST_TMP/origin.git" "$CLAUDE_RUNNER_WORKROOT/$p" 2>/dev/null
    git -C "$CLAUDE_RUNNER_WORKROOT/$p" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$CLAUDE_RUNNER_WORKROOT/$p" push -q origin HEAD:main 2>/dev/null || true
  done
  cat > "$JOBS_ROOT/projects/registry.json" <<'EOF'
{"proj":     {"repo":"acme/proj","default_branch":"main","model":"sonnet"},
 "fakeproj": {"repo":"acme/fakeproj","default_branch":"main","runtime":"fake","model":"fake-large"},
 "fresh":    {"repo":"acme/fresh","default_branch":"main"}}
EOF
}

spec() { # <name> <json>
  printf '%s\n' "$2" > "$JOBS_ROOT/inbox/.$1.partial"
  mv "$JOBS_ROOT/inbox/.$1.partial" "$JOBS_ROOT/inbox/$1"
}

run_spec() { # <json> — run one job through the copied run-job; sets $status
  spec job.json "$1"
  run "$BIN/run-job" "$JOBS_ROOT/inbox/job.json"
}

ran() { # claude | fake — which adapter's CLI ran
  case "$1" in
    claude) [ -s "$FAKE_CLAUDE_ARGS" ] && [ ! -e "$FAKE_RT_ARGS" ] ;;
    fake)   [ -s "$FAKE_RT_ARGS" ] && [ ! -e "$FAKE_CLAUDE_ARGS" ] ;;
  esac
}

model_given() { # <argv file> — the --model value the adapter received, or nothing
  grep -A1 -x -- '--model' "$1" | tail -n +2
}

the_stderr() { cat "$JOBS_ROOT"/logs/*.stderr; }

@test "no runtime anywhere: the job runs on claude" {
  run_spec '{"prompt":"go"}'
  [ "$status" -eq 0 ]
  ran claude
}

@test "a spec runtime picks its adapter, and wins over the registry's" {
  run_spec '{"prompt":"go","project":"proj","runtime":"fake"}'
  [ "$status" -eq 0 ]
  ran fake
  [ "$(count_in done)" -eq 1 ]
}

@test "a registry runtime applies when the spec names none" {
  run_spec '{"prompt":"go","project":"fakeproj"}'
  [ "$status" -eq 0 ]
  ran fake
}

@test "CLAUDE_RUNNER_RUNTIME is the fleet default" {
  export CLAUDE_RUNNER_RUNTIME=fake
  run_spec '{"prompt":"go"}'
  [ "$status" -eq 0 ]
  ran fake
}

@test "an unknown runtime is refused at claim, before the checkout" {
  run_spec '{"prompt":"go","project":"fresh","runtime":"nope"}'
  [ "$status" -eq 8 ]
  [ "$(count_in failed)" -eq 1 ]
  [ ! -e "$CLAUDE_RUNNER_WORKROOT/fresh" ]   # never reached the clone
  [ -z "$(find "$JOBS_ROOT/logs" -name '*.meta')" ]
  [ -z "$(find "$JOBS_ROOT/processing" -mindepth 1 -print -quit)" ]
  the_stderr | grep -q "unknown runtime 'nope'"
  [ ! -e "$FAKE_CLAUDE_ARGS" ]
}

@test "a runtime that is not a plain name is never turned into a path" {
  for bad in '../stubs/claude' 'rt/fake' '-x' 'Fake' ' fake'; do
    rm -rf "${JOBS_ROOT:?}"/logs/* "$JOBS_ROOT"/failed/*
    run_spec "$(jq -cn --arg r "$bad" '{prompt:"go",runtime:$r}')"
    [ "$status" -eq 8 ]
    the_stderr | grep -q "invalid runtime name"
  done
  [ ! -e "$FAKE_CLAUDE_ARGS" ]
}

@test "the registry's model is skipped for another runtime, applied for its own" {
  run_spec '{"prompt":"go","project":"proj","runtime":"fake"}'   # proj's sonnet is claude's
  [ "$status" -eq 0 ]
  [ -z "$(model_given "$FAKE_RT_ARGS")" ]

  rm -f "$FAKE_RT_ARGS"
  run_spec '{"prompt":"go","project":"fakeproj"}'               # fakeproj's model is fake's
  [ "$status" -eq 0 ]
  [ "$(model_given "$FAKE_RT_ARGS")" = fake-large ]

  run_spec '{"prompt":"go","project":"proj"}'                   # and claude still gets sonnet
  [ "$status" -eq 0 ]
  [ "$(model_given "$FAKE_CLAUDE_ARGS")" = sonnet ]
}

@test "the global model applies only to the fleet default runtime" {
  export CLAUDE_RUNNER_MODEL=opus
  run_spec '{"prompt":"go","runtime":"fake"}'
  [ "$status" -eq 0 ]
  [ -z "$(model_given "$FAKE_RT_ARGS")" ]
  run_spec '{"prompt":"go"}'
  [ "$status" -eq 0 ]
  [ "$(model_given "$FAKE_CLAUDE_ARGS")" = opus ]
}

@test "a spec model its runtime does not take is refused at claim" {
  run_spec '{"prompt":"go","project":"fresh","model":"gemini-3.8-flash"}'
  [ "$status" -eq 8 ]
  the_stderr | grep -q "model 'gemini-3.8-flash' is not a claude model"
  [ ! -e "$CLAUDE_RUNNER_WORKROOT/fresh" ]

  rm -rf "${JOBS_ROOT:?}"/logs/*
  run_spec '{"prompt":"go","runtime":"fake","model":"sonnet"}'
  [ "$status" -eq 8 ]
  the_stderr | grep -q "model 'sonnet' is not a fake model"
  [ ! -e "$FAKE_RT_ARGS" ]
}

@test "every model a fleet job has named so far is still a claude model" {
  for m in sonnet opus haiku fable 'opus[1m]' claude-sonnet-5-5; do
    rm -f "$FAKE_CLAUDE_ARGS"
    run_spec "$(jq -cn --arg m "$m" '{prompt:"go",model:$m}')"
    [ "$status" -eq 0 ]
    [ "$(model_given "$FAKE_CLAUDE_ARGS")" = "$m" ]
  done
}

@test "cr-submit -r writes the runtime; a bad name, or -r with -f, is refused" {
  run "$REPO_ROOT/bin/cr-submit" -r fake -m fake-small -o t "do it" </dev/null
  [ "$status" -eq 0 ]
  f="$(find "$JOBS_ROOT/inbox" -name '*.json' | head -1)"
  [ "$(jq -r .runtime "$f")" = fake ]
  [ "$(jq -r .model "$f")" = fake-small ]
  [[ "$output" == *"(runtime=fake)"* ]]

  run "$REPO_ROOT/bin/cr-submit" -r '../x' -o t "do it" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"-r needs a runtime name"* ]]

  printf '{"prompt":"p"}\n' > "$TEST_TMP/s.json"
  run "$REPO_ROOT/bin/cr-submit" -r fake -f "$TEST_TMP/s.json" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"-r can't be combined with -f"* ]]
}

@test "cr-submit without -r writes no runtime key" {
  run "$REPO_ROOT/bin/cr-submit" -o t "do it" </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("runtime")' "$(find "$JOBS_ROOT/inbox" -name '*.json' | head -1)")" = false ]
}

@test "cr-newproject -r records the runtime; without it the entry has no runtime key" {
  run "$REPO_ROOT/bin/cr-newproject" -r fake gproj acme/gproj fake-large
  [ "$status" -eq 0 ]
  [ "$(jq -r .gproj.runtime "$JOBS_ROOT/projects/registry.json")" = fake ]
  run "$REPO_ROOT/bin/cr-newproject" cproj acme/cproj sonnet
  [ "$status" -eq 0 ]
  [ "$(jq -r '.cproj | has("runtime")' "$JOBS_ROOT/projects/registry.json")" = false ]
  run "$REPO_ROOT/bin/cr-newproject" -r 'a/b' x acme/x
  [ "$status" -eq 1 ]
}

@test "cr-newproject keeps a recorded runtime when re-registering without -r" {
  run "$REPO_ROOT/bin/cr-newproject" -r fake gproj acme/gproj fake-large
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/bin/cr-newproject" gproj acme/gproj fake-small
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime fake (kept from the existing entry)"* ]]
  [ "$(jq -r .gproj.runtime "$JOBS_ROOT/projects/registry.json")" = fake ]
  [ "$(jq -r .gproj.model "$JOBS_ROOT/projects/registry.json")" = fake-small ]
  run "$REPO_ROOT/bin/cr-newproject" -r claude gproj acme/gproj sonnet   # -r still replaces it
  [ "$(jq -r .gproj.runtime "$JOBS_ROOT/projects/registry.json")" = claude ]
}

@test "an empty -r is refused by cr-submit and cr-newproject" {
  run "$REPO_ROOT/bin/cr-submit" -r "" -o t "do it" </dev/null
  [ "$status" -ne 0 ]
  [ -z "$(find "$JOBS_ROOT/inbox" -name '*.json')" ]
  run "$REPO_ROOT/bin/cr-newproject" -r "" x acme/x
  [ "$status" -ne 0 ]
  [ "$(jq -r 'has("x")' "$JOBS_ROOT/projects/registry.json")" = false ]
}

@test "a project that names no runtime follows the fleet default, without its Claude model" {
  export CLAUDE_RUNNER_RUNTIME=fake
  run_spec '{"prompt":"go","project":"proj"}'   # proj: no runtime, model sonnet
  [ "$status" -eq 0 ]
  ran fake
  [ -z "$(model_given "$FAKE_RT_ARGS")" ]
}

@test "cr-schedule keeps a scheduled spec's runtime" {
  printf '%s\n' '{"prompt":"p","runtime":"fake","schedule":"* * * * *"}' > "$JOBS_ROOT/scheduled/r.json"
  CR_SCHEDULE_NOW=2026-10-28T10:00:00Z "$REPO_ROOT/bin/cr-schedule" >/dev/null
  [ "$(jq -r .runtime "$(find "$JOBS_ROOT/inbox" -name '*.json' | head -1)")" = fake ]
}

@test "the claim comment and the journald lines name the runtime" {
  export FAKE_GH_LOG="$TEST_TMP/gh.log"; : > "$FAKE_GH_LOG"
  export FAKE_SYSTEMD_CAT_LOG="$TEST_TMP/journal.log"
  run_spec '{"prompt":"go","project":"proj","runtime":"fake","issue":42}'
  [ "$status" -eq 0 ]
  grep -q '(fake, default)' "$FAKE_GH_LOG"
  grep -q '^run-job START .* runtime=fake model=default ' "$FAKE_SYSTEMD_CAT_LOG"
  grep -q '^run-job DONE .* runtime=fake ' "$FAKE_SYSTEMD_CAT_LOG"

  : > "$FAKE_SYSTEMD_CAT_LOG"
  run_spec '{"prompt":"go","runtime":"nope"}'
  [ "$status" -eq 8 ]
  grep -q '^run-job FAIL .* unknown-runtime runtime=nope ' "$FAKE_SYSTEMD_CAT_LOG"
}
