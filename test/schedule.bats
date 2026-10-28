#!/usr/bin/env bats
#
# cr-schedule: scheduled jobs as data on the NAS. Every worker runs it each
# minute; a per-slot mkdir claim must let exactly one of them queue each run.
# The clock is CR_SCHEDULE_NOW, so every case is deterministic.

load test_helper

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-sched.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"/{inbox,scheduled}
}

spec() { # <name> <json>
  printf '%s\n' "$2" > "$JOBS_ROOT/scheduled/$1.json"
}

tick() { # <iso-instant>
  CR_SCHEDULE_NOW="$1" "$REPO_ROOT/bin/cr-schedule"
}

queued() { find "$JOBS_ROOT/inbox" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '; }

@test "a due slot is queued exactly once across racing workers" {
  spec brief '{"prompt":"p","project":"x","schedule":"0 6 * * *","tz":"America/New_York"}'
  pids=()
  for _ in 1 2 3 4 5 6 7 8; do
    tick 2026-10-28T10:00:20Z >/dev/null 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null || true
  [ "$(queued)" -eq 1 ]
  [ -d "$JOBS_ROOT/scheduled/.claims/brief/20261028T0600" ]
}

@test "the queued copy is a JSON job stamped with its submitter and slot" {
  spec brief '{"prompt":"hello","project":"x","schedule":"0 6 * * *","tz":"America/New_York"}'
  run tick 2026-10-28T10:00:00Z
  [ "$status" -eq 0 ]
  [[ "$output" == *"queued brief slot 20261028T0600"* ]]
  f="$(find "$JOBS_ROOT/inbox" -name '*.json')"
  [ "$(jq -r .prompt "$f")" = hello ]
  [ "$(jq -r .submitter "$f")" = schedule:brief ]
  [ "$(jq -r .scheduled_slot "$f")" = 20261028T0600 ]
  [ -z "$(find "$JOBS_ROOT/inbox" -name '*.partial')" ]
}

@test "a spec's own submitter is kept" {
  spec brief '{"prompt":"p","submitter":"me","schedule":"* * * * *"}'
  tick 2026-10-28T10:00:00Z
  [ "$(jq -r .submitter "$(find "$JOBS_ROOT/inbox" -name '*.json')")" = me ]
}

@test "the schedule is read in its tz on both sides of the DST change" {
  spec brief '{"prompt":"p","schedule":"0 6 * * *","tz":"America/New_York"}'
  tick 2026-11-02T10:00:00Z   # 5:00 EST: not due
  [ "$(queued)" -eq 0 ]
  tick 2026-11-02T11:00:00Z   # 6:00 EST
  [ "$(queued)" -eq 1 ]
  tick 2026-10-28T10:00:00Z   # 6:00 EDT
  [ "$(queued)" -eq 2 ]
}

@test "the repeated hour at the end of DST fires once" {
  spec night '{"prompt":"p","schedule":"30 1 * * *","tz":"America/New_York"}'
  tick 2026-11-01T05:30:00Z   # 1:30 EDT
  tick 2026-11-01T06:30:00Z   # 1:30 EST, the same wall-clock slot
  [ "$(queued)" -eq 1 ]
}

@test "a late slot fires inside the catch-up window, once, and not after it" {
  spec brief '{"prompt":"p","schedule":"0 6 * * *","tz":"UTC","catchup_min":10}'
  tick 2026-10-28T06:07:00Z
  [ "$(queued)" -eq 1 ]
  tick 2026-10-28T06:08:00Z
  [ "$(queued)" -eq 1 ]
  spec late '{"prompt":"p","schedule":"0 6 * * *","tz":"UTC","catchup_min":10}'
  tick 2026-10-28T06:11:00Z
  [ "$(queued)" -eq 1 ]
}

@test "disabled, schedule-less and malformed specs queue nothing and don't stop the rest" {
  spec off '{"prompt":"p","schedule":"* * * * *","enabled":false}'
  spec manual '{"prompt":"p"}'
  spec broken '{"prompt":"p","schedule":"61 * * * *"}'
  spec badtz '{"prompt":"p","schedule":"* * * * *","tz":"Mars/Olympus"}'
  printf 'not json' > "$JOBS_ROOT/scheduled/garbled.json"
  spec good '{"prompt":"p","schedule":"* * * * *"}'
  run tick 2026-10-28T10:00:00Z
  [ "$status" -eq 0 ]
  [ "$(queued)" -eq 1 ]
  [ -n "$(find "$JOBS_ROOT/inbox" -name 'good-*.json')" ]
  [[ "$output" == *"skip broken.json: bad schedule"* ]]
  [[ "$output" == *"skip badtz.json: bad schedule"* ]]
  [[ "$output" == *"skip garbled.json: unreadable"* ]]
}

@test "day-of-month and day-of-week restricted together match either one" {
  spec both '{"prompt":"p","schedule":"0 9 1 * 1","catchup_min":0}'
  tick 2026-11-02T09:00:00Z   # Monday the 2nd
  [ "$(queued)" -eq 1 ]
  tick 2026-12-01T09:00:00Z   # Tuesday the 1st
  [ "$(queued)" -eq 2 ]
  tick 2026-12-02T09:00:00Z   # Wednesday the 2nd
  [ "$(queued)" -eq 2 ]
}

@test "steps, ranges and lists" {
  spec every15 '{"prompt":"p","schedule":"*/15 8-9 * * 1-5","catchup_min":0}'
  tick 2026-10-28T08:30:00Z   # Wednesday
  tick 2026-10-28T08:31:00Z
  tick 2026-10-31T08:30:00Z   # Saturday
  [ "$(queued)" -eq 1 ]
}

@test "claims older than 30 days are pruned" {
  spec brief '{"prompt":"p","schedule":"0 6 * * *"}'
  mkdir -p "$JOBS_ROOT/scheduled/.claims/brief/20260901T0600" "$JOBS_ROOT/scheduled/.claims/brief/20261020T0600"
  tick 2026-10-28T12:00:00Z
  [ ! -d "$JOBS_ROOT/scheduled/.claims/brief/20260901T0600" ]
  [ -d "$JOBS_ROOT/scheduled/.claims/brief/20261020T0600" ]
}

@test "catch-up never replays a backlog: an every-minute schedule queues one job per tick" {
  spec often '{"prompt":"p","schedule":"* * * * *"}'
  tick 2026-10-28T10:00:00Z
  [ "$(queued)" -eq 1 ]
  tick 2026-10-28T10:01:00Z
  [ "$(queued)" -eq 2 ]
}
