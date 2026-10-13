#!/usr/bin/env bats
#
# cr-submit admission control (#21): the fleet occupancy summary, the submitter
# tag, and the soft capacity guard (+ -w). Drives the real bin/cr-submit against
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
