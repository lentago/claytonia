#!/usr/bin/env bats
#
# cr-submit admission control (#21): the fleet occupancy summary, the submitter
# tag, and the soft capacity guard (+ -w/-W); and the dispatch-time overlap check (#22),
# against the stub gh in test/stubs. Drives the real bin/cr-submit against
# the tmpfs JOBS_ROOT from test_helper, with fake workers/*.alive heartbeats and
# processing/*.owner claims standing in for the fleet.

load test_helper

# A worker heartbeat; "stale" backdates it past CLAUDE_HEARTBEAT_STALE (90s).
alive() { # <host> [stale]
  : > "$JOBS_ROOT/workers/$1.alive"
  [ "${2:-}" = stale ] && touch -d '-10 min' "$JOBS_ROOT/workers/$1.alive"
  return 0
}

# A claimed job: processing/<runid> (the spec) + its .owner naming the worker.
claim() { # <runid> <worker> [spec-json]
  local spec="${3:-}"
  if [ -n "$spec" ]; then
    printf '%s\n' "$spec" > "$JOBS_ROOT/processing/$1"
    printf 'owner=%s\nstarted=1\norigname=%s.json\n' "$2" "$1" > "$JOBS_ROOT/processing/$1.owner"
  else
    printf 'plain prompt\n' > "$JOBS_ROOT/processing/$1"
    printf 'owner=%s\nstarted=1\norigname=%s.txt\n' "$2" "$1" > "$JOBS_ROOT/processing/$1.owner"
  fi
}

queued_spec() { find "$JOBS_ROOT/inbox" -maxdepth 1 -name '*.json' -newer "$TEST_TMP/mark" | head -1; }

setup() {
  # Shared tmpfs JOBS_ROOT etc., then a timestamp so tests can tell the job just
  # queued from pre-seeded inbox backlog.
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-submit.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"/{inbox,processing,done,failed,logs,workers}
  unset CLAUDE_SESSION
  touch -d '-1 min' "$TEST_TMP/mark"
  # The stub gh, never the real one: the overlap check calls gh for project jobs.
  export PATH="$STUBS_DIR:$PATH"
  export FAKE_GH_LOG="$TEST_TMP/gh.log"; : > "$FAKE_GH_LOG"
}

# --- occupancy printout -------------------------------------------------------

@test "occupancy: alive/idle/busy workers, the busy job, and inbox depth" {
  alive w1; alive w2; alive gone stale
  claim R1 w1 '{"prompt":"x","project":"claytonia","submitter":"alice@laptop"}'
  claim R2 gone '{"prompt":"y","project":"other"}'   # dead owner: the reaper's, not occupancy
  printf 'x\n' > "$JOBS_ROOT/inbox/waiting.txt"
  printf 'x\n' > "$JOBS_ROOT/inbox/half.partial"           # write-then-rename decoy: not waiting
  printf 'x\n' > "$JOBS_ROOT/inbox/.hidden.json"

  run "$REPO_ROOT/bin/cr-submit" "hello" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"cr-submit: fleet: 2 alive, 1 idle, 1 busy; 1 waiting in inbox/"* ]]
  [[ "$output" == *"busy w1: project=claytonia runid=R1 submitter=alice@laptop"* ]]
  [[ "$output" != *"gone"* ]]
  [[ "$output" != *"R2"* ]]
}

@test "occupancy: a plain-text claim shows no project; a stray owner is skipped" {
  alive w1; alive w2
  claim T1 w1
  printf 'owner=w2\n' > "$JOBS_ROOT/processing/STRAY.owner"   # job already filed
  run "$REPO_ROOT/bin/cr-submit" "hello" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet: 2 alive, 1 idle, 1 busy; 0 waiting in inbox/"* ]]
  [[ "$output" == *"busy w1: project=- runid=T1"* ]]
  [[ "$output" != *"STRAY"* ]]
}

@test "occupancy: a stalled listing is bounded and never blocks the submit" {
  alive w1
  # stat is only used by the occupancy probe; make it hang.
  mkdir -p "$TEST_TMP/fakebin"
  printf '#!/bin/sh\nsleep 30\n' > "$TEST_TMP/fakebin/stat"; chmod +x "$TEST_TMP/fakebin/stat"
  export PATH="$TEST_TMP/fakebin:$PATH" CLAUDE_SUBMIT_PROBE_TIMEOUT=1
  SECONDS=0
  run "$REPO_ROOT/bin/cr-submit" "hello" </dev/null
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  [[ "$output" == *"fleet occupancy unavailable"* ]]
  [[ "$output" != *"warning"* ]]
  [ -n "$(queued_spec)" ]
}

# --- submitter tag --------------------------------------------------------------

@test "submitter: defaults to <user>@<host>, written as \"submitter\" in a JSON spec" {
  alive w1
  USER=tester run "$REPO_ROOT/bin/cr-submit" "plain prompt" </dev/null
  [ "$status" -eq 0 ]
  f="$(queued_spec)"
  [ -n "$f" ]
  [ "$(jq -r .submitter "$f")" = "tester@$(hostname)" ]
  [ "$(jq -r .prompt "$f")" = "plain prompt" ]
  [ "$(jq -r 'has("owner")' "$f")" = false ]   # .owner means the claiming worker, never the submitter
}

@test "submitter: \$CLAUDE_SESSION wins over <user>@<host>" {
  alive w1
  CLAUDE_SESSION=sess-42 run "$REPO_ROOT/bin/cr-submit" -p proj "task" </dev/null
  [ "$status" -eq 0 ]
  f="$(queued_spec)"
  [ "$(jq -r .submitter "$f")" = sess-42 ]
  [ "$(jq -r .project "$f")" = proj ]
}

@test "submitter: -o and --owner set it explicitly" {
  alive w1
  CLAUDE_SESSION=ignored run "$REPO_ROOT/bin/cr-submit" -o batch-7 "a" </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -r .submitter "$(queued_spec)")" = batch-7 ]
  rm -f "$JOBS_ROOT"/inbox/*
  run "$REPO_ROOT/bin/cr-submit" --owner "alice laptop" -m haiku "b" </dev/null
  [ "$status" -eq 0 ]
  [ "$(jq -r .submitter "$(queued_spec)")" = "alice laptop" ]
  [ "$(jq -r .model "$(queued_spec)")" = haiku ]
}

@test "submitter: an empty -o is refused and queues nothing" {
  run "$REPO_ROOT/bin/cr-submit" -o "" "a" </dev/null
  [ "$status" -ne 0 ]
  run "$REPO_ROOT/bin/cr-submit" -o "   " "a" </dev/null
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$JOBS_ROOT/inbox")" ]
}

@test "-f stays a verbatim copy: no occupancy, no guard, and -o is refused" {
  printf '{"prompt":"cron","submitter":"cron@nas"}\n' > "$TEST_TMP/spec.json"
  run "$REPO_ROOT/bin/cr-submit" -f "$TEST_TMP/spec.json" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet:"* ]]
  [[ "$output" != *"warning"* ]]     # no alive worker at all, yet -f stays quiet
  cmp "$TEST_TMP/spec.json" "$(queued_spec)"
  run "$REPO_ROOT/bin/cr-submit" -o x -f "$TEST_TMP/spec.json" </dev/null
  [ "$status" -ne 0 ]
}

# --- soft capacity guard -----------------------------------------------------------

@test "guard: a free fleet with an empty inbox queues without a warning" {
  alive w1; alive w2
  run "$REPO_ROOT/bin/cr-submit" "a" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"warning"* ]]
  [ -n "$(queued_spec)" ]
}

@test "guard: all workers busy -> warns and still queues" {
  alive w1; alive w2
  claim R1 w1 '{"prompt":"x"}'; claim R2 w2 '{"prompt":"y"}'
  run "$REPO_ROOT/bin/cr-submit" "a" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: all 2 alive worker(s) are busy; this job deepens the backlog"* ]]
  [ -n "$(queued_spec)" ]
}

@test "guard: inbox backlog >= alive workers warns even with an idle worker (fan-out)" {
  alive w1; alive w2
  # A burst submitted before anyone claims: every worker idle, inbox growing.
  run "$REPO_ROOT/bin/cr-submit" "1" </dev/null; [[ "$output" != *"warning"* ]]
  run "$REPO_ROOT/bin/cr-submit" "2" </dev/null; [[ "$output" != *"warning"* ]]
  run "$REPO_ROOT/bin/cr-submit" "3" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: inbox/ already holds 2 waiting job(s) for 2 alive worker(s)"* ]]
  [ "$(ls "$JOBS_ROOT"/inbox/*.json | wc -l)" -eq 3 ]
}

@test "guard: no alive worker -> warns and still queues" {
  alive w1 stale
  run "$REPO_ROOT/bin/cr-submit" "a" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet: 0 alive"* ]]
  [[ "$output" == *"warning: no worker is alive"* ]]
  [ -n "$(queued_spec)" ]
}

@test "guard: -w never blocks when stdin is not a terminal" {
  alive w1; claim R1 w1 '{"prompt":"x"}'
  export CLAUDE_SUBMIT_WAIT_POLL=60
  SECONDS=0
  run timeout 20 "$REPO_ROOT/bin/cr-submit" -w "a" </dev/null
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  [[ "$output" == *"-w ignored: stdin is not a terminal"* ]]
  [[ "$output" == *"warning: all 1 alive worker(s) are busy"* ]]
  [ -n "$(queued_spec)" ]
}

# The waiting path needs a terminal on stdin; util-linux `script` provides one.
_on_tty() { script -qec "$*" /dev/null </dev/null; }

@test "guard: -w at a terminal waits for a free worker, then queues" {
  command -v script >/dev/null || skip "needs util-linux script for a pty"
  alive w1; claim R1 w1 '{"prompt":"x"}'
  export CLAUDE_SUBMIT_WAIT_POLL=1 CLAUDE_SUBMIT_WAIT_TIMEOUT=30
  # The busy worker finishes its job 2s in.
  ( sleep 2; rm -f "$JOBS_ROOT/processing/R1.owner"; touch "$JOBS_ROOT/workers/w1.alive" ) &
  run _on_tty "'$REPO_ROOT/bin/cr-submit' -w 'a'"
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting up to 30s for a free worker"* ]]
  [[ "$output" == *"a worker is free"* ]]
  [[ "$output" != *"queueing anyway"* ]]
  [ -n "$(queued_spec)" ]
}

@test "guard: -w gives up after its timeout and queues anyway" {
  command -v script >/dev/null || skip "needs util-linux script for a pty"
  alive w1; claim R1 w1 '{"prompt":"x"}'
  export CLAUDE_SUBMIT_WAIT_POLL=1 CLAUDE_SUBMIT_WAIT_TIMEOUT=2
  run _on_tty "'$REPO_ROOT/bin/cr-submit' -w 'a'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no free worker after 2s; queueing anyway"* ]]
  [ -n "$(queued_spec)" ]
}

@test "-f: a flag after the spec file is refused rather than ignored" {
  printf '{"prompt":"x"}' > "$TEST_TMP/spec.json"
  run "$REPO_ROOT/bin/cr-submit" -f "$TEST_TMP/spec.json" -W
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected arguments after the spec file: -W"* ]]
  [ -z "$(queued_spec)" ]
}

@test "guard: -W waits without a terminal for a free worker, then queues" {
  alive w1; claim R1 w1 '{"prompt":"x"}'
  export CLAUDE_SUBMIT_WAIT_POLL=1 CLAUDE_SUBMIT_WAIT_TIMEOUT=30
  # Release the worker only once cr-submit says it is waiting (polled, not a fixed
  # sleep), so the test cannot free the worker before the first occupancy read.
  timeout 25 "$REPO_ROOT/bin/cr-submit" -W "a" </dev/null >"$TEST_TMP/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do grep -q "waiting up to" "$TEST_TMP/out" 2>/dev/null && break; sleep 0.1; done
  grep -q "waiting up to" "$TEST_TMP/out"
  rm -f "$JOBS_ROOT/processing/R1.owner"; touch "$JOBS_ROOT/workers/w1.alive"
  status=0; wait "$pid" || status=$?
  output="$(cat "$TEST_TMP/out")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting up to 30s for a free worker"* ]]
  [[ "$output" == *"a worker is free"* ]]
  [[ "$output" != *"ignored"* ]]
  [[ "$output" != *"queueing anyway"* ]]
  [ -n "$(queued_spec)" ]
}

@test "guard: --wait-unattended gives up after its timeout and queues anyway" {
  alive w1; claim R1 w1 '{"prompt":"x"}'
  export CLAUDE_SUBMIT_WAIT_POLL=1 CLAUDE_SUBMIT_WAIT_TIMEOUT=2
  run timeout 20 "$REPO_ROOT/bin/cr-submit" --wait-unattended "a" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"no free worker after 2s; queueing anyway"* ]]
  [ -n "$(queued_spec)" ]
}

@test "guard: CLAUDE_SUBMIT_WAIT_UNATTENDED=1 waits without a terminal and without a flag" {
  alive w1; claim R1 w1 '{"prompt":"x"}'
  export CLAUDE_SUBMIT_WAIT_UNATTENDED=1 CLAUDE_SUBMIT_WAIT_POLL=1 CLAUDE_SUBMIT_WAIT_TIMEOUT=30
  timeout 25 "$REPO_ROOT/bin/cr-submit" "a" </dev/null >"$TEST_TMP/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do grep -q "waiting up to" "$TEST_TMP/out" 2>/dev/null && break; sleep 0.1; done
  grep -q "waiting up to" "$TEST_TMP/out"
  rm -f "$JOBS_ROOT/processing/R1.owner"; touch "$JOBS_ROOT/workers/w1.alive"
  status=0; wait "$pid" || status=$?
  output="$(cat "$TEST_TMP/out")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting up to 30s for a free worker"* ]]
  [[ "$output" == *"a worker is free"* ]]
  [ -n "$(queued_spec)" ]
}

@test "guard: without the opt-in, an env value other than 1 changes nothing" {
  alive w1; claim R1 w1 '{"prompt":"x"}'
  export CLAUDE_SUBMIT_WAIT_UNATTENDED=0 CLAUDE_SUBMIT_WAIT_POLL=60
  SECONDS=0
  run timeout 20 "$REPO_ROOT/bin/cr-submit" -w "a" </dev/null
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  [[ "$output" == *"-w ignored: stdin is not a terminal"* ]]
}

@test "-f with -W is refused; the env var does not make -f wait" {
  alive w1; claim R1 w1 '{"prompt":"x"}'
  printf '{"prompt":"cron"}\n' > "$TEST_TMP/spec.json"
  run "$REPO_ROOT/bin/cr-submit" -W -f "$TEST_TMP/spec.json" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"-W can't be combined with -f"* ]]
  [ -z "$(queued_spec)" ]
  export CLAUDE_SUBMIT_WAIT_UNATTENDED=1 CLAUDE_SUBMIT_WAIT_POLL=60
  SECONDS=0
  run timeout 20 "$REPO_ROOT/bin/cr-submit" -f "$TEST_TMP/spec.json" </dev/null
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  [[ "$output" != *"waiting"* ]]
  cmp "$TEST_TMP/spec.json" "$(queued_spec)"
}

# --- dispatch-time overlap check (#22) ---------------------------------------------

# Register project "proj" -> acme/proj and have the stub gh answer `pr list` with
# the given JSON array; FAKE_GH_FILES_DIR/<n>.json answers pulls/<n>/files.
fleet_prs() { # <pr-list-json>
  mkdir -p "$JOBS_ROOT/projects" "$TEST_TMP/files"
  printf '{"proj":{"repo":"acme/proj","default_branch":"main"},"other":{"repo":"acme/other"}}\n' \
    > "$JOBS_ROOT/projects/registry.json"
  printf '%s\n' "$1" > "$TEST_TMP/prs.json"
  export FAKE_GH_PRS="$TEST_TMP/prs.json" FAKE_GH_FILES_DIR="$TEST_TMP/files"
}
pr_files() { # <n> <path>...
  local n="$1"; shift
  printf '%s\n' "$@" | jq -R '{filename: .}' | jq -s . > "$TEST_TMP/files/$n.json"
}
FLEET_PR='{"number":88,"headRefName":"agent/rekey-runners-panel","title":"Rekey Runners underway panel","author":{"login":"app/lentago-claude-runner"}}'
BOT_PR='{"number":90,"headRefName":"dependabot/x","title":"Bump x","author":{"login":"app/dependabot"}}'

@test "overlap: names the open fleet PR and its paths, plus same-project jobs, and still queues" {
  alive w1; alive w2
  fleet_prs "[$FLEET_PR,$BOT_PR]"
  pr_files 88 dashboards/fleet.json README.md
  pr_files 90 go.mod
  claim R1 w1 '{"prompt":"fix the\npanel","project":"proj","submitter":"alice@laptop","issue":7}'
  claim R2 w2 '{"prompt":"unrelated","project":"other","submitter":"bob"}'
  printf '{"prompt":"queued one","project":"proj","submitter":"carol"}\n' > "$JOBS_ROOT/inbox/q1.json"
  printf '{"prompt":"half","project":"proj"}\n' > "$JOBS_ROOT/inbox/q2.json.partial"

  run "$REPO_ROOT/bin/cr-submit" -p proj "edit the panel" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: project proj already has fleet work open or queued"* ]]
  [[ "$output" == *'PR #88 (agent/rekey-runners-panel) "Rekey Runners underway panel" touches: dashboards/fleet.json, README.md'* ]]
  [[ "$output" == *'in flight: runid=R1 worker=w1 submitter=alice@laptop issue=#7 "fix the panel"'* ]]
  [[ "$output" == *'waiting: inbox/q1.json submitter=carol "queued one"'* ]]
  [[ "$output" != *"#90"* ]]          # Dependabot is not a fleet writer
  [[ "$output" != *"go.mod"* ]]
  [[ "$output" != *"runid=R2 worker"* ]]   # another project's job is no overlap
  [[ "$output" != *"q2"* ]]           # nor a half-written spec
  grep -q -- '--author app/lentago-claude-runner' "$FAKE_GH_LOG"
  grep -q -- '--repo acme/proj' "$FAKE_GH_LOG"
  [ "$(jq -r .project "$(queued_spec)")" = proj ]
}

@test "overlap: a long file list is capped, and an unreadable one says so" {
  alive w1
  fleet_prs "[$FLEET_PR,${FLEET_PR//88/89}]"
  pr_files 88 $(seq -f 'f%g' 1 18)
  run "$REPO_ROOT/bin/cr-submit" -p proj "x" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"f15 (+3 more)"* ]]
  [[ "$output" != *"f16"* ]]
  [[ "$output" == *"PR #89 "*"touches: (paths unavailable)"* ]]
  [ -n "$(queued_spec)" ]
}

@test "overlap: no open fleet PR and no in-flight job -> no warning" {
  alive w1; alive w2
  fleet_prs "[$BOT_PR]"
  claim R2 w2 '{"prompt":"unrelated","project":"other"}'
  run "$REPO_ROOT/bin/cr-submit" -p proj "x" </dev/null
  [ "$status" -eq 0 ]
  grep -q '^pr list' "$FAKE_GH_LOG"   # the check ran ...
  [[ "$output" != *"warning"* ]]      # ... and found nothing to say
  [[ "$output" != *"overlap"* ]]
  [ -n "$(queued_spec)" ]
}

@test "overlap: ad-hoc jobs and -f (cron) skip the check entirely" {
  alive w1
  fleet_prs "[$FLEET_PR]"; pr_files 88 a.txt
  claim R1 w1 '{"prompt":"x","project":"proj"}'
  run "$REPO_ROOT/bin/cr-submit" "ad-hoc" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet work"* ]]
  printf '{"prompt":"cron","project":"proj"}\n' > "$TEST_TMP/spec.json"
  run "$REPO_ROOT/bin/cr-submit" -f "$TEST_TMP/spec.json" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet work"* ]]
  [[ "$output" != *"overlap"* ]]
  [ ! -s "$FAKE_GH_LOG" ]
  [ "$(ls "$JOBS_ROOT"/inbox/*.json | wc -l)" -eq 2 ]
}

@test "overlap: a gh failure is a note, never a failed submit" {
  alive w1
  fleet_prs "[$FLEET_PR]"
  export FAKE_GH_FAIL=1
  claim R1 w1 '{"prompt":"x","project":"proj"}'
  run "$REPO_ROOT/bin/cr-submit" -p proj "x" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlap: gh pr list failed; open fleet PRs in acme/proj not checked"* ]]
  [[ "$output" == *"in flight: runid=R1 worker=w1"* ]]   # the share half still reports
  [[ "$output" != *"PR #88"* ]]
  [ -n "$(queued_spec)" ]
}

@test "overlap: a hung gh is bounded; what was read is still shown and the job queues" {
  alive w1
  fleet_prs "[$FLEET_PR]"
  export FAKE_GH_SLEEP=30 CLAUDE_SUBMIT_OVERLAP_TIMEOUT=2
  printf '{"prompt":"queued","project":"proj"}\n' > "$JOBS_ROOT/inbox/q1.json"
  SECONDS=0
  run "$REPO_ROOT/bin/cr-submit" -p proj "x" </dev/null
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  [[ "$output" == *"overlap: check incomplete (no full answer within 2s)"* ]]
  [[ "$output" == *"waiting: inbox/q1.json"* ]]
  [ -n "$(queued_spec)" ]
}

@test "overlap: a project missing from the registry is a note, not a gh call" {
  alive w1
  run "$REPO_ROOT/bin/cr-submit" -p nosuch "x" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlap: project nosuch is not in projects/registry.json"* ]]
  [[ "$output" != *"warning"* ]]
  [ ! -s "$FAKE_GH_LOG" ]
  [ -n "$(queued_spec)" ]
}
