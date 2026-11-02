#!/usr/bin/env bats
#
# cr-publish-share (#185): the share's README.md is an artifact of main. The copy
# is the source plus a stamp of its commit; each run compares first; a change is
# renamed into place; five workers at once leave one whole copy; a hand edit is
# overwritten; a stale checkout never overwrites a newer copy.

load test_helper

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-share.XXXXXX")"
  export JOBS_ROOT="$TEST_TMP/jobs"; mkdir -p "$JOBS_ROOT/inbox"
  export CR_PUBLISH_SRC="$TEST_TMP/src.md"
  export CR_PUBLISH_STAMP="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1762000000"
  export CR_PUBLISH_STATE="$TEST_TMP/state"
  export FAKE_SYSTEMD_CAT_LOG="$TEST_TMP/journal.log"; : > "$FAKE_SYSTEMD_CAT_LOG"
  printf '# queue readme v1\nline\n' > "$CR_PUBLISH_SRC"
  export PATH="$STUBS_DIR:$PATH"
}

publish() { "$REPO_ROOT/bin/cr-publish-share"; }
inode() { stat -c %i "$JOBS_ROOT/README.md"; }
no_temp_left() { [ -z "$(find "$JOBS_ROOT" -maxdepth 1 -name '.README.md.*')" ]; }
body_is_source() { head -n -1 "$JOBS_ROOT/README.md" | cmp - "$CR_PUBLISH_SRC"; }
stamp_time() { sed -n 's/.*(commit time \([0-9]*\)).*/\1/p' "$JOBS_ROOT/README.md"; }

@test "publishes the source, stamped with its commit, and leaves no temp file" {
  run publish
  [ "$status" -eq 0 ]
  body_is_source
  tail -1 "$JOBS_ROOT/README.md" | grep -qF 'published by cr-publish-share from lentago/claytonia@aaaaaaaaaaaa (commit time 1762000000)'
  no_temp_left
}

@test "a steady state writes nothing" {
  publish
  before="$(inode)"
  publish
  [ "$(inode)" = "$before" ]
}

@test "a hand edit is overwritten on the next run, stamped or not" {
  publish
  printf 'edited by hand on the share\n' > "$JOBS_ROOT/README.md"
  publish
  body_is_source
  sed -i '1s/.*/hand edit that kept the stamp/' "$JOBS_ROOT/README.md"
  publish
  body_is_source
}

@test "a change to the source is written by rename, never in place" {
  publish
  before="$(inode)"
  printf '# queue readme v2\n' > "$CR_PUBLISH_SRC"
  CR_PUBLISH_STAMP="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 1762000100" publish
  [ "$(inode)" != "$before" ]
  body_is_source
  [ "$(stamp_time)" = 1762000100 ]
}

@test "a stale checkout never overwrites a copy from a newer commit, and says so once" {
  CR_PUBLISH_STAMP="cccccccccccccccccccccccccccccccccccccccc 1762000500" publish   # the newer one lands
  printf 'older text\n' > "$CR_PUBLISH_SRC"
  publish                                   # this worker's checkout is older (1762000000)
  publish
  [ "$(stamp_time)" = 1762000500 ]
  ! grep -q 'older text' "$JOBS_ROOT/README.md"
  [ "$(grep -c 'from a newer commit' "$FAKE_SYSTEMD_CAT_LOG")" -eq 1 ]
}

@test "a stamp far in the future is treated as a hand edit and overwritten" {
  publish
  sed -i 's/(commit time [0-9]*)/(commit time 9999999999)/' "$JOBS_ROOT/README.md"
  publish
  [ "$(stamp_time)" = 1762000000 ]
}

@test "a source that is not in git is stamped unknown, and still replaces an unstamped copy" {
  unset CR_PUBLISH_STAMP
  printf 'legacy hand-written README\n' > "$JOBS_ROOT/README.md"
  publish
  body_is_source
  tail -1 "$JOBS_ROOT/README.md" | grep -qF '@unknown (commit time 0)'
}

@test "five workers publishing at once leave one whole copy and no temp files" {
  printf 'stale\n' > "$JOBS_ROOT/README.md"
  head -c 200000 /dev/urandom | base64 > "$CR_PUBLISH_SRC"   # big enough to catch a torn write
  pids=()
  for _ in 1 2 3 4 5; do publish & pids+=($!); done
  wait "${pids[@]}"
  body_is_source
  no_temp_left
}

@test "a temp file a killed run left behind is swept after ten minutes; a fresh one is kept" {
  touch -d '20 minutes ago' "$JOBS_ROOT/.README.md.old-worker.111.tmp"
  touch "$JOBS_ROOT/.README.md.busy-worker.222.tmp"
  publish
  [ ! -e "$JOBS_ROOT/.README.md.old-worker.111.tmp" ]
  [ -e "$JOBS_ROOT/.README.md.busy-worker.222.tmp" ]
}

@test "a failed publish is noted once, with its cause" {
  chmod a-w "$JOBS_ROOT"
  publish; publish
  chmod u+w "$JOBS_ROOT"
  [ "$(grep -c 'could not publish' "$FAKE_SYSTEMD_CAT_LOG")" -eq 1 ]
  grep 'could not publish' "$FAKE_SYSTEMD_CAT_LOG" | grep -qi 'permission denied'
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

@test "the stamp comes from the source's last commit when the checkout is a git repo" {
  unset CR_PUBLISH_STAMP
  git init -q "$TEST_TMP/co" && mkdir -p "$TEST_TMP/co/docs/share"
  printf '# from git\n' > "$TEST_TMP/co/docs/share/README.md"
  git -C "$TEST_TMP/co" add -A
  GIT_COMMITTER_DATE='@1762001234 +0000' git -C "$TEST_TMP/co" -c user.name=t -c user.email=t@t commit -q -m readme
  CR_PUBLISH_SRC="$TEST_TMP/co/docs/share/README.md" publish
  [ "$(stamp_time)" = 1762001234 ]
  tail -1 "$JOBS_ROOT/README.md" | grep -qF "@$(git -C "$TEST_TMP/co" rev-parse HEAD | cut -c1-12) "
}
