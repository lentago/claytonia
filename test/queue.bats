#!/usr/bin/env bats
#
# Queue-core contract tests (issue #61). The queue is the one component every
# other automation depends on; these lock down its four load-bearing properties
# against the real bin/run-job + bin/process-inbox, with the NAS inbox faked on
# tmpfs and the agent/metrics/journald calls stubbed. See test/README.md.

load test_helper

# --- atomic claim-by-rename: exactly one winner --------------------------------

@test "claim race: exactly one worker claims a contested inbox file" {
  # Many run-job processes race on ONE inbox file across several rounds. The
  # claim is `mv inbox->processing || exit 0`; rename() is atomic, so regardless
  # of scheduling exactly one process may claim each file — the losers no-op.
  for round in 1 2 3 4 5; do
    drop_job "race-$round.txt" "prompt $round"
    jobfile="$JOBS_ROOT/inbox/race-$round.txt"

    pids=()
    for _ in 1 2 3 4 5 6 7 8; do
      "$REPO_ROOT/bin/run-job" "$jobfile" >/dev/null 2>&1 &
      pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true   # join; correctness is asserted on state below

    # The contested file is gone from the inbox and left no duplicate claim:
    # each round adds exactly one terminal record, so the running total == round.
    [ ! -e "$jobfile" ]
    [ "$(count_terminal)" -eq "$round" ]
  done
}

# --- at-least-once delivery: inbox -> exactly one of done/ or failed/ ----------

@test "at-least-once: a dropped job lands in done/ with its logs" {
  drop_job "deliver.txt" "please deliver"

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/inbox/deliver.txt" ]
  [ "$(count_terminal)" -eq 1 ]
  [ "$(count_in done)" -eq 1 ]

  runid="$(basename "$(find "$JOBS_ROOT/done" -maxdepth 1 -type f)")"
  [ -f "$JOBS_ROOT/logs/$runid.meta" ]
  [ -f "$JOBS_ROOT/logs/$runid.json" ]
  [ -f "$JOBS_ROOT/logs/$runid.txt" ]
  grep -q '^exit=0$' "$JOBS_ROOT/logs/$runid.meta"
}

@test "at-least-once: a JSON job spec is claimed, parsed, and delivered" {
  # Exercises the *.json claim/parse path (read from the claimed proc file).
  printf '{"prompt":"do the json work"}\n' > "$JOBS_ROOT/inbox/.spec.json.partial"
  mv "$JOBS_ROOT/inbox/.spec.json.partial" "$JOBS_ROOT/inbox/spec.json"

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/inbox/spec.json" ]
  [ "$(count_in done)" -eq 1 ]
}

@test "at-least-once: a malformed JSON job fails cleanly with no orphaned owner" {
  printf '{ this is not json\n' > "$JOBS_ROOT/inbox/.bad.json.partial"
  mv "$JOBS_ROOT/inbox/.bad.json.partial" "$JOBS_ROOT/inbox/bad.json"

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/inbox/bad.json" ]
  [ "$(count_in failed)" -eq 1 ]
  # the claimed job left nothing behind in processing/ (owner cleaned up too)
  [ -z "$(find "$JOBS_ROOT/processing" -mindepth 1 -print -quit)" ]
  ls "$JOBS_ROOT"/failed/*.badjson >/dev/null 2>&1
}

@test "at-least-once: a failing job still terminates in failed/ with its logs" {
  export FAKE_CLAUDE_MODE=error   # agent reports is_error -> run-job rc=1

  drop_job "boom.txt" "this will fail"

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/inbox/boom.txt" ]
  [ "$(count_terminal)" -eq 1 ]
  [ "$(count_in failed)" -eq 1 ]

  runid="$(basename "$(find "$JOBS_ROOT/failed" -maxdepth 1 -type f)")"
  [ -f "$JOBS_ROOT/logs/$runid.meta" ]
  [ -f "$JOBS_ROOT/logs/$runid.stderr" ]
  grep -q '^exit=1$' "$JOBS_ROOT/logs/$runid.meta"
}

# --- write-then-rename discipline: partials/temps are never picked up ----------

@test "discipline: *.partial / *.tmp / dotfiles / .owner / .swp are never claimed" {
  # Decoys a half-written or bookkeeping file could leave in the inbox.
  printf 'half\n'  > "$JOBS_ROOT/inbox/writing.partial"
  printf 'temp\n'  > "$JOBS_ROOT/inbox/writing.tmp"
  printf 'hide\n'  > "$JOBS_ROOT/inbox/.hidden.txt"
  printf 'owner\n' > "$JOBS_ROOT/inbox/stray.owner"
  printf 'vim\n'   > "$JOBS_ROOT/inbox/note.swp"
  drop_job "real.txt" "the only real job"

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  # Only the real job was claimed and delivered...
  [ ! -e "$JOBS_ROOT/inbox/real.txt" ]
  [ "$(count_in done)" -eq 1 ]
  # ...every decoy is left exactly where it was.
  [ -e "$JOBS_ROOT/inbox/writing.partial" ]
  [ -e "$JOBS_ROOT/inbox/writing.tmp" ]
  [ -e "$JOBS_ROOT/inbox/.hidden.txt" ]
  [ -e "$JOBS_ROOT/inbox/stray.owner" ]
  [ -e "$JOBS_ROOT/inbox/note.swp" ]
}

# --- crash-mid-job recovery: the reaper -----------------------------------------

@test "crash recovery: a stranded job (dead owner) is requeued then delivered" {
  # A worker claimed a job then died: a processing/ entry + .owner remain and no
  # live heartbeat exists. The reaper must requeue it (.retry) and it must then
  # be delivered — a crash leaves a recoverable state, never a lost job.
  runid="20260101T000000Z-orphan"
  printf 'orphaned work\n' > "$JOBS_ROOT/processing/$runid"
  printf 'owner=deadworker\nstarted=1\norigname=orphan.txt\n' > "$JOBS_ROOT/processing/$runid.owner"
  # (no workers/deadworker.alive -> owner treated as long dead)

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  # Reaped clean: no stranded job or owner left behind in processing/.
  [ ! -e "$JOBS_ROOT/processing/$runid" ]
  [ ! -e "$JOBS_ROOT/processing/$runid.owner" ]
  # Delivered exactly once via the requeued .retry name.
  [ "$(count_in done)" -eq 1 ]
  delivered="$(basename "$(find "$JOBS_ROOT/done" -maxdepth 1 -type f)")"
  [[ "$delivered" == *orphan.retry* ]]
}

@test "crash recovery: a job stranded a second time fails instead of looping" {
  # Same worker-death, but the job already carries .retry — one retry is the cap,
  # so it must be filed to failed/ (diagnosable), not requeued forever.
  runid="20260101T000000Z-orphan.retry"
  printf 'twice orphaned\n' > "$JOBS_ROOT/processing/$runid"
  printf 'owner=deadworker\nstarted=1\norigname=orphan.txt\n' > "$JOBS_ROOT/processing/$runid.owner"

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/processing/$runid" ]
  [ ! -e "$JOBS_ROOT/processing/$runid.owner" ]
  [ -e "$JOBS_ROOT/failed/$runid.stranded" ]
  [ "$(count_in done)" -eq 0 ]
}

@test "crash recovery: a job whose owner is still alive is left untouched" {
  # A fresh heartbeat means the owner is presumed still working — the reaper must
  # not steal an in-flight job out from under a live worker.
  runid="20260101T000000Z-live"
  printf 'in flight\n' > "$JOBS_ROOT/processing/$runid"
  printf 'owner=liveworker\nstarted=1\norigname=live.txt\n' > "$JOBS_ROOT/processing/$runid.owner"
  : > "$JOBS_ROOT/workers/liveworker.alive"   # mtime = now -> within the stale window

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ -e "$JOBS_ROOT/processing/$runid" ]
  [ -e "$JOBS_ROOT/processing/$runid.owner" ]
  [ "$(count_terminal)" -eq 0 ]
}

# --- completed-orphan recovery: the janitor ------------------------------------
#
# The reaper is keyed on *.owner files, so an entry whose owner was already
# removed is invisible to it. run-job clears the owner as its last step even if
# the terminal `mv -> done/` silently failed, leaving an ownerless processing
# entry whose logs prove the job finished. That state stranded a real job in
# processing/ for a month (issue #73); the janitor sweeps it terminally.

# A stranded processing entry looks like a completed run: its runid has a .meta
# sidecar, backdated past the janitor's stale threshold (mtime = completion time).
seed_completed_orphan() { # <runid> <exit_rc>
  local runid="$1" rc="$2" meta="$JOBS_ROOT/logs/$1.meta"
  printf 'the completed work\n' > "$JOBS_ROOT/processing/$runid"
  {
    echo "runid=$runid"; echo "exit=$rc"; echo "duration_sec=5"
    echo "finished=2026-07-08T21:54:18Z"
  } > "$meta"
  touch -d '2026-07-08 21:54:18' "$meta"   # older than JANITOR_STALE below
}

@test "janitor: an ownerless completed orphan (logs present) is terminally filed" {
  # The exact observed bug: no .owner file, but logs/<runid>.meta exists. The
  # reaper can't see it; the janitor files it to done/ (exit=0) with a marker and
  # never re-runs it.
  export CLAUDE_JANITOR_STALE=60
  runid="20260708T215413Z-mc-personnel-pilot-01"
  seed_completed_orphan "$runid" 0
  # (deliberately no processing/$runid.owner — this is the ownerless case)

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/processing/$runid" ]
  [ -e "$JOBS_ROOT/done/$runid.janitor" ]
  [ "$(count_in done)" -eq 1 ]
  [ "$(count_in failed)" -eq 0 ]
}

@test "janitor: a failed completed orphan is filed to failed/ per its logged exit" {
  export CLAUDE_JANITOR_STALE=60
  runid="20260708T215413Z-boom"
  seed_completed_orphan "$runid" 1

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/processing/$runid" ]
  [ -e "$JOBS_ROOT/failed/$runid.janitor" ]
  [ "$(count_in failed)" -eq 1 ]
  [ "$(count_in done)" -eq 0 ]
}

@test "janitor: a completed orphan with a DEAD owner is filed, never requeued" {
  # A completed run whose owner is also dead: the reaper would requeue it (.retry)
  # and re-run a job that already finished — a double-run. The janitor runs first
  # and files it terminally, so it is never re-run.
  export CLAUDE_JANITOR_STALE=60
  runid="20260708T215413Z-stranded-complete"
  seed_completed_orphan "$runid" 0
  printf 'owner=deadworker\nstarted=1\norigname=x.txt\n' > "$JOBS_ROOT/processing/$runid.owner"
  # (no workers/deadworker.alive -> owner is long dead)

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ ! -e "$JOBS_ROOT/processing/$runid" ]
  [ ! -e "$JOBS_ROOT/processing/$runid.owner" ]
  [ -e "$JOBS_ROOT/done/$runid.janitor" ]
  [ "$(count_in done)" -eq 1 ]
  # Not requeued: nothing bounced back through the inbox as a .retry.
  [ -z "$(find "$JOBS_ROOT/inbox" -name '*.retry.*' -print -quit)" ]
}

@test "janitor: a live owner's completed entry is left for run-job to file" {
  # meta exists but the owner heartbeat is fresh — run-job may still be doing its
  # own terminal move. The janitor must not race it.
  export CLAUDE_JANITOR_STALE=60
  runid="20260708T215413Z-live-cleanup"
  seed_completed_orphan "$runid" 0
  printf 'owner=liveworker\nstarted=1\norigname=x.txt\n' > "$JOBS_ROOT/processing/$runid.owner"
  : > "$JOBS_ROOT/workers/liveworker.alive"   # fresh heartbeat

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ -e "$JOBS_ROOT/processing/$runid" ]
  [ -e "$JOBS_ROOT/processing/$runid.owner" ]
  [ "$(count_terminal)" -eq 0 ]
}

@test "janitor: an ownerless entry with NO logs is left untouched (no completion proof)" {
  # Conservatism: without logs/<runid>.meta we cannot prove the job ran, and the
  # queue is at-least-once — filing it could lose a job that never actually ran.
  # The janitor must leave it (neither done/ nor failed/).
  export CLAUDE_JANITOR_STALE=60
  runid="20260708T215413Z-nologs"
  printf 'ambiguous work\n' > "$JOBS_ROOT/processing/$runid"
  # (no owner, no logs/<runid>.meta)

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ -e "$JOBS_ROOT/processing/$runid" ]
  [ "$(count_terminal)" -eq 0 ]
}

@test "janitor: a fresh completed entry (within the stale window) is left alone" {
  # A just-completed entry may still be mid-cleanup by a live run-job; only entries
  # whose logs are older than the threshold are swept.
  export CLAUDE_JANITOR_STALE=3600
  runid="20260708T215413Z-fresh"
  printf 'just finished\n' > "$JOBS_ROOT/processing/$runid"
  { echo "runid=$runid"; echo "exit=0"; } > "$JOBS_ROOT/logs/$runid.meta"   # mtime = now

  run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]

  [ -e "$JOBS_ROOT/processing/$runid" ]
  [ "$(count_terminal)" -eq 0 ]
}
