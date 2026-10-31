#!/usr/bin/env bats
#
# cr-update: the weekly, idle-guarded Claude Code update. It runs from cron,
# whose PATH (/usr/local/bin:/usr/bin:/bin) does not include ~/.local/bin where
# the native installer puts claude, so it must reach the binary through
# CLAUDE_BIN. Every case runs it under that PATH with a fake claude that records
# its calls and flips its version on `update`.

load test_helper

CRON_PATH=/usr/local/bin:/usr/bin:/bin

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-update.XXXXXX")"
  export CLAUDE_INBOX_LOCK="$TEST_TMP/inbox.lock"   # never the prod singleton
  export CR_UPDATE_JITTER=0 CR_UPDATE_WAIT=0

  # Fake claude, deliberately NOT on any PATH: only CLAUDE_BIN can reach it.
  mkdir -p "$TEST_TMP/home/.local/bin" "$TEST_TMP/shim"
  export CLAUDE_BIN="$TEST_TMP/home/.local/bin/claude"
  export FAKE_STATE="$TEST_TMP/state" FAKE_CALLS="$TEST_TMP/calls"
  printf '1.0.0\n' > "$FAKE_STATE"
  cat > "$CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
case "${1:-}" in
  --version) printf '%s (Claude Code)\n' "$(cat "$FAKE_STATE")" ;;
  update)
    case "${FAKE_UPDATE:-new}" in
      new)  printf '2.0.0\n' > "$FAKE_STATE"; echo "Successfully updated" ;;
      same) echo "Claude Code is up to date" ;;
      fail) echo "network unreachable" >&2; exit 1 ;;
    esac ;;
esac
STUB
  chmod +x "$CLAUDE_BIN"

  # Shadow logger so a test run never writes to the host journal; nothing else.
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/shim/logger"; chmod +x "$TEST_TMP/shim/logger"
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

cr_update() { # run the real script the way cron does: minimal PATH, nothing inherited
  env -i HOME="$TEST_TMP/home" PATH="$TEST_TMP/shim:$CRON_PATH" \
    CLAUDE_BIN="$CLAUDE_BIN" CLAUDE_INBOX_LOCK="$CLAUDE_INBOX_LOCK" \
    CR_UPDATE_JITTER="$CR_UPDATE_JITTER" CR_UPDATE_WAIT="$CR_UPDATE_WAIT" \
    FAKE_STATE="$FAKE_STATE" FAKE_CALLS="$FAKE_CALLS" FAKE_UPDATE="${FAKE_UPDATE:-new}" \
    "$REPO_ROOT/bin/cr-update" "$@"
}

@test "updates through CLAUDE_BIN under cron's PATH" {
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated: 1.0.0 (Claude Code) -> 2.0.0 (Claude Code)"* ]]
  grep -qx update "$FAKE_CALLS"
}

@test "an update that changes nothing reports already current" {
  FAKE_UPDATE=same run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"already current (1.0.0 (Claude Code))"* ]]
}

@test "a failed update is logged with the version it was on, exit 1" {
  FAKE_UPDATE=fail run cr_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"update FAILED (was: 1.0.0 (Claude Code)): network unreachable"* ]]
}

@test "a held inbox lock (a running job) skips the run without touching claude" {
  exec 8>"$CLAUDE_INBOX_LOCK"
  flock -n 8
  run cr_update
  exec 8>&-
  [ "$status" -eq 0 ]
  [[ "$output" == *"a job is still running"* ]]
  [ ! -e "$FAKE_CALLS" ]
}

@test "the production CLAUDE_BIN default matches run-job's" {
  # Every case above overrides CLAUDE_BIN, so pin the default itself to the one
  # run-job uses for every job: a typo here would pass the suite and fail on
  # every worker.
  # shellcheck disable=SC2016  # the $ is a literal in the sed pattern
  default_of() { sed -n 's/^CLAUDE_BIN="\${CLAUDE_BIN:-\(.*\)}".*/\1/p' "$1"; }
  ours="$(default_of "$REPO_ROOT/bin/cr-update")"
  theirs="$(default_of "$REPO_ROOT/bin/run-job")"
  [ -n "$ours" ]
  [ "$ours" = "$theirs" ]
}
