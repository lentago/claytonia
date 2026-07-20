# Shared setup for the queue-core bats tests.
#
# Fakes the NAS inbox on tmpfs and wires the real bin/run-job + bin/process-inbox
# at hermetic stubs (claude / cr-emit / systemd-cat) so a run touches no network,
# no journald, and no real agent. Everything durable lives under one tmpfs temp
# dir that teardown removes.

# Repo root (test/ sits one level below it).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS_DIR="$REPO_ROOT/test/stubs"

# Prefer a real tmpfs mount: the queue's single-winner guarantee rests on
# rename() semantics, so we want to exercise them on the same kind of in-memory
# fs the fast path uses. Fall back to the default temp dir if /dev/shm is absent.
_tmpfs_base() {
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    printf '/dev/shm\n'
  else
    printf '%s\n' "${TMPDIR:-/tmp}"
  fi
}

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-queue.XXXXXX")"

  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"/{inbox,processing,done,failed,logs,workers}

  # A writable, existing cwd for the faked agent run (run-job cd's into it).
  export CLAUDE_RUNNER_CWD="$TEST_TMP/work"; mkdir -p "$CLAUDE_RUNNER_CWD"
  export HOME="$TEST_TMP/home"; mkdir -p "$HOME"

  # Seams (default to production paths): point process-inbox at the in-repo
  # run-job, and give both scripts a PATH whose stubs shadow claude/cr-emit/
  # systemd-cat. run-job resets PATH internally, hence the separate override.
  export CLAUDE_RUNNER_BIN="$REPO_ROOT/bin"
  export CLAUDE_INBOX_LOCK="$TEST_TMP/inbox.lock"   # per-run lock; never the prod singleton
  export CLAUDE_BIN="$STUBS_DIR/claude"
  export CLAUDE_RUNNER_PATH="$STUBS_DIR:$PATH"
  export PATH="$STUBS_DIR:$PATH"

  export FAKE_CLAUDE_MODE=ok
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# Drop a plain-text job into the inbox using the producer's write-then-rename
# discipline (poller must never see the *.partial half-write).
drop_job() { # <name> [content]
  local name="$1" content="${2:-do the thing}"
  printf '%s\n' "$content" > "$JOBS_ROOT/inbox/.$name.partial"
  mv "$JOBS_ROOT/inbox/.$name.partial" "$JOBS_ROOT/inbox/$name"
}

# Count plain files directly under a jobs subdir (done/failed hold one file per job).
count_in() { # <subdir>
  find "$JOBS_ROOT/$1" -maxdepth 1 -type f | wc -l | tr -d ' '
}

# Total jobs that reached a terminal state.
count_terminal() {
  echo $(( $(count_in done) + $(count_in failed) ))
}
