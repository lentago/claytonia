#!/usr/bin/env bats
#
# A job's session id is never empty (#179). On the two workers built without
# uuid-runtime, `sid="$(uuidgen)"` came back empty, so 186 of 400 jobs filed no
# session id and lost their NAS transcript. run-job now mints it from uuidgen, else
# the kernel's UUID source, else bash itself; these prove each fallback, and that
# with every external source gone a run of jobs still gets distinct, well-formed ids.

load test_helper

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-sid.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"
  mkdir -p "$JOBS_ROOT"/{inbox,processing,done,failed,logs,workers}
  export CLAUDE_RUNNER_CWD="$TEST_TMP/work"; mkdir -p "$CLAUDE_RUNNER_CWD"
  export HOME="$TEST_TMP/home"; mkdir -p "$HOME"
  export CLAUDE_RUNNER_BIN="$REPO_ROOT/bin"
  export CLAUDE_INBOX_LOCK="$TEST_TMP/inbox.lock"
  export FAKE_CLAUDE_MODE=ok
  export FAKE_CLAUDE_ARGS="$TEST_TMP/argv"
  export PATH="$STUBS_DIR:$PATH"

  # A claude that keeps a transcript under the session id it was given, as the
  # real CLI does, so the NAS copy can be checked end to end.
  cat > "$TEST_TMP/claude" <<EOF
#!/usr/bin/env bash
sid=""; prev=""
for a in "\$@"; do [ "\$prev" = --session-id ] && sid="\$a"; prev="\$a"; done
if [ -n "\$sid" ]; then mkdir -p "\$HOME/.claude/projects/-t"; echo '{"t":1}' > "\$HOME/.claude/projects/-t/\$sid.jsonl"; fi
exec "$STUBS_DIR/claude" "\$@"
EOF
  chmod +x "$TEST_TMP/claude"
  export CLAUDE_BIN="$TEST_TMP/claude"

  # uuidgen variants, chosen per test by putting one directory first on run-job's PATH.
  mkdir -p "$TEST_TMP/no-uuidgen" "$TEST_TMP/bad-uuidgen"
  printf '#!/bin/sh\nexit 127\n' > "$TEST_TMP/no-uuidgen/uuidgen"          # missing: nothing, non-zero
  printf '#!/bin/sh\necho not-a-uuid\n' > "$TEST_TMP/bad-uuidgen/uuidgen"  # present but useless
  chmod +x "$TEST_TMP/no-uuidgen/uuidgen" "$TEST_TMP/bad-uuidgen/uuidgen"
}

meta_sid() { sed -n 's/^session_id=//p' "$1"; }

one_job() { # <uuidgen-dir> — run one job; prints its .meta path
  CLAUDE_RUNNER_PATH="$1:$STUBS_DIR:$PATH" "$REPO_ROOT/bin/process-inbox" >/dev/null 2>&1
  find "$JOBS_ROOT/logs" -name '*.meta' | head -1
}

@test "without uuidgen, the job still gets a session id from the kernel, and its transcript reaches the NAS" {
  drop_job "k.txt" "go"
  meta="$(one_job "$TEST_TMP/no-uuidgen")"
  sid="$(meta_sid "$meta")"
  [[ $sid =~ $UUID_RE ]]
  grep -A1 -x -- '--session-id' "$FAKE_CLAUDE_ARGS" | grep -qx "$sid"
  [ -s "${meta%.meta}.transcript.jsonl" ]
}

@test "uuidgen output that is not a UUID is not used" {
  drop_job "b.txt" "go"
  sid="$(meta_sid "$(one_job "$TEST_TMP/bad-uuidgen")")"
  [[ $sid =~ $UUID_RE ]]
}

@test "with no uuidgen and no kernel source, the session id is still a well-formed UUID" {
  export CLAUDE_RUNNER_UUID_SRC="$TEST_TMP/no-such-file"
  drop_job "n.txt" "go"
  meta="$(one_job "$TEST_TMP/no-uuidgen")"
  sid="$(meta_sid "$meta")"
  [[ $sid =~ $UUID_RE ]]
  [ "${sid:14:1}" = 4 ]                     # version 4
  case "${sid:19:1}" in 8|9|a|b) ;; *) false ;; esac   # RFC 4122 variant
  [ -s "${meta%.meta}.transcript.jsonl" ]
}

@test "an empty session id cannot happen: 25 jobs with every external source gone get 25 distinct ids" {
  export CLAUDE_RUNNER_UUID_SRC="$TEST_TMP/no-such-file"
  for i in $(seq 1 25); do drop_job "many-$i.txt" "go $i"; done
  CLAUDE_RUNNER_PATH="$TEST_TMP/no-uuidgen:$STUBS_DIR:$PATH" run "$REPO_ROOT/bin/process-inbox"
  [ "$status" -eq 0 ]
  [ "$(find "$JOBS_ROOT/logs" -name '*.meta' | wc -l)" -eq 25 ]
  for m in "$JOBS_ROOT"/logs/*.meta; do [[ $(meta_sid "$m") =~ $UUID_RE ]]; done
  [ "$(for m in "$JOBS_ROOT"/logs/*.meta; do meta_sid "$m"; echo; done | sort -u | grep -c .)" -eq 25 ]
  ! grep -qx 'session_id=' "$JOBS_ROOT"/logs/*.meta
}
