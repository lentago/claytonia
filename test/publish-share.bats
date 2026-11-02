#!/usr/bin/env bats
#
# cr-publish-share (#185): the share's README.md is an artifact of main. Each run
# compares first; a change is written to a temp file and renamed into place; five
# workers at once leave one whole copy; a hand edit is overwritten next run.

load test_helper

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-share.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"; mkdir -p "$JOBS_ROOT/inbox"
  export CR_PUBLISH_SRC="$TEST_TMP/src.md"
  printf '# queue readme v1\nline\n' > "$CR_PUBLISH_SRC"
  export PATH="$STUBS_DIR:$PATH"
}

publish() { "$REPO_ROOT/bin/cr-publish-share"; }
inode() { stat -c %i "$JOBS_ROOT/README.md"; }
no_temp_left() { [ -z "$(find "$JOBS_ROOT" -maxdepth 1 -name '.README.md.*')" ]; }

@test "publishes the source to the share root, and leaves no temp file" {
  run publish
  [ "$status" -eq 0 ]
  cmp "$CR_PUBLISH_SRC" "$JOBS_ROOT/README.md"
  no_temp_left
}

@test "a steady state writes nothing" {
  publish
  before="$(inode)"
  publish
  [ "$(inode)" = "$before" ]
}

@test "a hand edit to the share copy is overwritten on the next run" {
  publish
  printf 'edited by hand on the share\n' > "$JOBS_ROOT/README.md"
  publish
  cmp "$CR_PUBLISH_SRC" "$JOBS_ROOT/README.md"
}

@test "a change to the source is written by rename, never in place" {
  publish
  before="$(inode)"
  printf '# queue readme v2\n' > "$CR_PUBLISH_SRC"
  publish
  [ "$(inode)" != "$before" ]
  cmp "$CR_PUBLISH_SRC" "$JOBS_ROOT/README.md"
}

@test "five workers publishing at once leave one whole copy and no temp files" {
  printf 'stale\n' > "$JOBS_ROOT/README.md"
  head -c 200000 /dev/urandom | base64 > "$CR_PUBLISH_SRC"   # big enough to catch a torn write
  pids=()
  for _ in 1 2 3 4 5; do publish & pids+=($!); done
  wait "${pids[@]}"
  cmp "$CR_PUBLISH_SRC" "$JOBS_ROOT/README.md"
  no_temp_left
}

@test "no source, or no queue, publishes nothing and is not an error" {
  printf 'keep me\n' > "$JOBS_ROOT/README.md"
  CR_PUBLISH_SRC="$TEST_TMP/missing.md" run publish
  [ "$status" -eq 0 ]
  [ "$(cat "$JOBS_ROOT/README.md")" = "keep me" ]
  rm -rf "$JOBS_ROOT/inbox"
  run publish
  [ "$status" -eq 0 ]
  [ "$(cat "$JOBS_ROOT/README.md")" = "keep me" ]
}

@test "the repo source says it is generated, and cron runs the publisher on every worker" {
  head -1 "$REPO_ROOT/docs/share/README.md" | grep -q 'Generated from docs/share/README.md in lentago/claytonia'
  grep -qE '^\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+claude[[:space:]]+/opt/claude-runner/bin/cr-publish-share$' "$REPO_ROOT/cron/claude-runner"
}
