#!/usr/bin/env bats
#
# cr-update: the weekly, idle-guarded update of every runtime CLI (#172). It runs
# from cron, whose PATH (/usr/local/bin:/usr/bin:/bin) does not include
# ~/.local/bin where the native installer puts claude, so every CLI is reached
# through its adapter's own path variable. Each case runs the real script under
# that PATH, with fakes for all three CLIs that record their calls:
#   claude  flips its version on `update`
#   gemini  an npm stub that installs a version into a fake prefix
#   codex   a fake /opt/codex layout, and the GitHub release API and asset served
#           from file:// (a real tarball, checked against its real sha256)
# Nothing reaches a real CLI, the network, or the host journal.

load test_helper

CRON_PATH=/usr/local/bin:/usr/bin:/bin
ASSET=codex-package-x86_64-unknown-linux-musl.tar.gz

# mk_codex_pkg <dir> <version> [omit] — a Codex release package laid out as the real
# one is (bin/codex, bin/codex-exec-server, codex-resources/bwrap), minus <omit>.
mk_codex_pkg() {
  mkdir -p "$1/bin" "$1/codex-resources"
  printf '#!/bin/sh\necho "codex-cli %s"\n' "$2" > "$1/bin/codex"
  printf '#!/bin/sh\n' > "$1/bin/codex-exec-server"
  printf '#!/bin/sh\n' > "$1/codex-resources/bwrap"
  chmod +x "$1/bin/codex" "$1/bin/codex-exec-server" "$1/codex-resources/bwrap"
  if [ -n "${3:-}" ]; then rm -f "$1/$3"; fi
}

# release <version> [omit] [digest] — serve <version> from the fake release API: its
# asset as a real tarball, the API JSON under tags/rust-v<version> and as latest.
release() {
  local v="$1" pkg="$TEST_TMP/rel/pkg-$1" sha
  mk_codex_pkg "$pkg" "$v" "${2:-}"
  tar -czf "$TEST_TMP/rel/$v.tar.gz" -C "$pkg" .
  sha="${3:-$(sha256sum "$TEST_TMP/rel/$v.tar.gz" | cut -d' ' -f1)}"
  mkdir -p "$TEST_TMP/api/tags"
  jq -n --arg v "$v" --arg n "$ASSET" --arg u "file://$TEST_TMP/rel/$v.tar.gz" --arg d "sha256:$sha" \
    '{tag_name: ("rust-v" + $v), assets: [{name: "other.zip", browser_download_url: "file:///nope"},
                                         {name: $n, browser_download_url: $u, digest: $d}]}' \
    | tee "$TEST_TMP/api/tags/rust-v$v" > "$TEST_TMP/api/latest"
}

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-update.XXXXXX")"
  export CLAUDE_INBOX_LOCK="$TEST_TMP/inbox.lock"   # never the prod singleton
  export CR_UPDATE_JITTER=0 CR_UPDATE_WAIT=0
  export FAKE_CALLS="$TEST_TMP/calls"
  mkdir -p "$TEST_TMP/home/.local/bin" "$TEST_TMP/shim" "$TEST_TMP/rel"

  # Fake claude, deliberately NOT on any PATH: only CLAUDE_BIN can reach it.
  export CLAUDE_BIN="$TEST_TMP/home/.local/bin/claude"
  export FAKE_STATE="$TEST_TMP/state"
  printf '1.0.0\n' > "$FAKE_STATE"
  cat > "$CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "$FAKE_CALLS"
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

  # Fake Gemini: an npm global under a fake prefix, and an npm that installs into it.
  export GEMINI_PREFIX="$TEST_TMP/prefix" GEMINI_STATE="$TEST_TMP/gemini.state"
  export GEMINI_BIN="$GEMINI_PREFIX/bin/gemini" NPM_BIN="$TEST_TMP/npm"
  mkdir -p "$GEMINI_PREFIX/bin" "$GEMINI_PREFIX/lib/node_modules"
  printf '0.66.0\n' > "$GEMINI_STATE"
  printf '#!/bin/sh\ncat "%s"\n' "$GEMINI_STATE" > "$GEMINI_BIN"; chmod +x "$GEMINI_BIN"
  cat > "$NPM_BIN" <<'STUB'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$FAKE_CALLS"
case "$1" in
  view) echo "${FAKE_NPM_LATEST:-0.67.0}" ;;
  install)
    [ "${FAKE_NPM:-ok}" = fail ] && { echo "npm ERR! code ENOTFOUND registry.npmjs.org" >&2; exit 1; }
    for a in "$@"; do case "$a" in @google/gemini-cli@*) printf '%s\n' "${a##*@}" > "$GEMINI_STATE" ;; esac; done ;;
esac
STUB
  chmod +x "$NPM_BIN"

  # Fake Codex: 0.166.0 installed as the runner image lays it out.
  export CODEX_ROOT="$TEST_TMP/opt/codex" CODEX_BIN="$TEST_TMP/usr-local-bin/codex"
  export CODEX_RELEASES_API="file://$TEST_TMP/api"
  mk_codex_pkg "$CODEX_ROOT/0.166.0" 0.166.0
  ln -sfn 0.166.0 "$CODEX_ROOT/current"
  mkdir -p "$(dirname "$CODEX_BIN")"
  ln -sfn "$CODEX_ROOT/current/bin/codex" "$CODEX_BIN"

  # The runner.env pins, as shipped: both peer CLIs at what they already run.
  export CR_UPDATE_RUNNER_ENV="$TEST_TMP/runner.env"
  pin 0.66.0 0.166.0

  # Shadow logger so a test run never writes to the host journal; nothing else.
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/shim/logger"; chmod +x "$TEST_TMP/shim/logger"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ]; then
    chmod -R u+w "$TEST_TMP" 2>/dev/null   # the needs-root cases take write away
    rm -rf "$TEST_TMP"
  fi
}

pin() { # <gemini version> <codex version> — the runner.env cr-update sources
  printf 'CLAUDE_RUNNER_GEMINI_VERSION="%s"\nCLAUDE_RUNNER_CODEX_VERSION="%s"\n' "$1" "$2" > "$CR_UPDATE_RUNNER_ENV"
}

cr_update() { # run the real script the way cron does: minimal PATH, nothing inherited
  env -i HOME="$TEST_TMP/home" PATH="$TEST_TMP/shim:$CRON_PATH" \
    CLAUDE_BIN="$CLAUDE_BIN" CLAUDE_INBOX_LOCK="$CLAUDE_INBOX_LOCK" CR_UPDATE_RUNNER_ENV="$CR_UPDATE_RUNNER_ENV" \
    CR_UPDATE_JITTER="$CR_UPDATE_JITTER" CR_UPDATE_WAIT="$CR_UPDATE_WAIT" \
    GEMINI_BIN="$GEMINI_BIN" GEMINI_PREFIX="$GEMINI_PREFIX" NPM_BIN="$NPM_BIN" GEMINI_STATE="$GEMINI_STATE" \
    CODEX_BIN="$CODEX_BIN" CODEX_ROOT="$CODEX_ROOT" CODEX_RELEASES_API="$CODEX_RELEASES_API" \
    FAKE_STATE="$FAKE_STATE" FAKE_CALLS="$FAKE_CALLS" FAKE_UPDATE="${FAKE_UPDATE:-new}" \
    FAKE_NPM="${FAKE_NPM:-ok}" FAKE_NPM_LATEST="${FAKE_NPM_LATEST:-0.67.0}" \
    "$REPO_ROOT/bin/cr-update" "$@"
}

# refute <command> — fails the test when the command succeeds. A bare `! cmd` would
# not: bash's errexit ignores negated commands, so bats lets them pass mid-test.
refute() { if "$@"; then echo "unexpectedly true: $*"; return 1; fi; }

# --- Claude: the step cr-update always ran, now through rt-claude ------------------

@test "updates through CLAUDE_BIN under cron's PATH" {
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: updated: 1.0.0 (Claude Code) -> 2.0.0 (Claude Code)"* ]]
  grep -qx 'claude update' "$FAKE_CALLS"
}

@test "an update that changes nothing reports already current" {
  FAKE_UPDATE=same run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: already current (1.0.0 (Claude Code))"* ]]
}

@test "a failed update is logged with the version it was on, exit 1" {
  FAKE_UPDATE=fail run cr_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude: update FAILED (was: 1.0.0 (Claude Code)): network unreachable"* ]]
}

@test "a held inbox lock (a running job) skips the run without touching any CLI" {
  pin 0.67.0 0.167.0; release 0.167.0   # updates that would be due
  exec 8>"$CLAUDE_INBOX_LOCK"
  flock -n 8
  run cr_update
  exec 8>&-
  [ "$status" -eq 0 ]
  [[ "$output" == *"a job is still running"* ]]
  [ ! -e "$FAKE_CALLS" ]
  [ "$(readlink "$CODEX_ROOT/current")" = 0.166.0 ]
  [ ! -e "$CODEX_ROOT/0.167.0" ]
}

@test "every adapter gets a step, one line each, in one run" {
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude: updated:"* ]]
  [[ "$output" == *"codex: already current (codex-cli 0.166.0)"* ]]
  [[ "$output" == *"gemini: already current (0.66.0)"* ]]
  [ "$(grep -c '^cr-update: [a-z]*: ' <<<"$output")" -eq 3 ]
  # A pin that is already installed needs no registry and no release lookup.
  refute grep -q '^npm ' "$FAKE_CALLS"
}

@test "a missing lock file is created and the run goes ahead; an existing one is only read" {
  rm -f "$CLAUDE_INBOX_LOCK"
  run cr_update
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_INBOX_LOCK" ]
  # The lock stays the job runner's: a read-only open leaves the file unchanged.
  printf 'keep\n' > "$CLAUDE_INBOX_LOCK"
  run cr_update
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_INBOX_LOCK")" = keep ]
}

# --- Gemini: the npm global, to the runner.env pin --------------------------------

@test "gemini: a new pin is installed with the image's own npm command" {
  pin 0.67.0 0.166.0
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"gemini: updated: 0.66.0 -> 0.67.0"* ]]
  grep -qx "npm install -g --prefix $GEMINI_PREFIX --no-fund --no-audit --no-update-notifier --loglevel=error @google/gemini-cli@0.67.0" "$FAKE_CALLS"
}

@test "gemini: latest resolves through the registry first" {
  pin latest 0.166.0
  FAKE_NPM_LATEST=0.68.1 run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"gemini: updated: 0.66.0 -> 0.68.1"* ]]
  grep -qx 'npm view --no-update-notifier @google/gemini-cli@latest version' "$FAKE_CALLS"
  # latest, when latest is what runs: no install.
  FAKE_NPM_LATEST=0.68.1 run cr_update
  [[ "$output" == *"gemini: already current (0.68.1)"* ]]
  [ "$(grep -c '^npm install' "$FAKE_CALLS")" -eq 1 ]
}

@test "gemini: a failed install is logged with the version it was on; the other steps still run" {
  pin 0.67.0 0.166.0
  FAKE_NPM=fail run cr_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"gemini: update FAILED (was: 0.66.0): npm ERR! code ENOTFOUND registry.npmjs.org"* ]]
  [[ "$output" == *"claude: updated:"* ]]
  [[ "$output" == *"codex: already current"* ]]
  [ "$(cat "$GEMINI_STATE")" = 0.66.0 ]
}

@test "gemini: an update that is due but not this user's to install is skipped, named" {
  [ "$(id -u)" -ne 0 ] || skip "root can write anything"
  pin 0.67.0 0.166.0
  chmod a-w "$GEMINI_PREFIX/lib/node_modules"
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"gemini: skipped, needs root: 0.66.0 -> 0.67.0 is due, and $GEMINI_PREFIX is not writable by $(id -un)"* ]]
  refute grep -q '^npm install' "$FAKE_CALLS"
}

@test "gemini: a CLI that is not installed is skipped with a line" {
  rm -f "$GEMINI_BIN"
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"gemini: skipped, not installed ($GEMINI_BIN)"* ]]
}

@test "gemini and codex: no pin leaves the CLI as it is; a malformed pin fails before any lookup" {
  : > "$CR_UPDATE_RUNNER_ENV"
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"gemini: not pinned, left at 0.66.0 (CLAUDE_RUNNER_GEMINI_VERSION is unset)"* ]]
  [[ "$output" == *"codex: not pinned, left at codex-cli 0.166.0 (CLAUDE_RUNNER_CODEX_VERSION is unset)"* ]]
  pin '0.67.0 extra' '../0.1'
  run cr_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"gemini: update FAILED (was: 0.66.0): CLAUDE_RUNNER_GEMINI_VERSION '0.67.0 extra' is not a version"* ]]
  [[ "$output" == *"codex: update FAILED (was: codex-cli 0.166.0): CLAUDE_RUNNER_CODEX_VERSION '../0.1' is not a version"* ]]
  refute grep -q '^npm ' "$FAKE_CALLS"
}

# --- Codex: the release package, to the runner.env pin ----------------------------

@test "codex: a new pin is downloaded, checked, unpacked beside the old one, and made current" {
  pin 0.66.0 0.167.0; release 0.167.0
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: updated: codex-cli 0.166.0 -> codex-cli 0.167.0"* ]]
  [ "$(readlink "$CODEX_ROOT/current")" = 0.167.0 ]
  [ "$("$CODEX_BIN" --version)" = "codex-cli 0.167.0" ]
  [ -x "$CODEX_ROOT/0.166.0/bin/codex" ]   # the old version stays: a rollback is a pin change
  [ ! -e "$CODEX_ROOT/0.167.0.partial" ]
}

@test "codex: latest follows the release API's latest" {
  pin 0.66.0 latest; release 0.167.0
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: updated: codex-cli 0.166.0 -> codex-cli 0.167.0"* ]]
  run cr_update
  [[ "$output" == *"codex: already current (codex-cli 0.167.0)"* ]]
}

@test "codex: an asset that does not match its published sha256 is never installed" {
  pin 0.66.0 0.167.0; release 0.167.0 "" "$(printf '0%.0s' {1..64})"
  run cr_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex: update FAILED (was: codex-cli 0.166.0): $ASSET does not match its published sha256"* ]]
  [ "$(readlink "$CODEX_ROOT/current")" = 0.166.0 ]
  [ ! -e "$CODEX_ROOT/0.167.0" ]
}

@test "codex: a package missing part of its layout is never installed" {
  pin 0.66.0 0.167.0; release 0.167.0 codex-resources/bwrap
  run cr_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex: update FAILED (was: codex-cli 0.166.0): the 0.167.0 package has no codex-resources/bwrap"* ]]
  [ "$(readlink "$CODEX_ROOT/current")" = 0.166.0 ]
  [ ! -e "$CODEX_ROOT/0.167.0" ]
  [ ! -e "$CODEX_ROOT/0.167.0.partial" ]
}

@test "codex: a version already on disk is made current again without a download" {
  mk_codex_pkg "$CODEX_ROOT/0.165.0" 0.165.0
  pin 0.66.0 0.165.0
  mkdir -p "$TEST_TMP/api/tags"   # a release whose asset would no longer download
  jq -n --arg n "$ASSET" '{tag_name: "rust-v0.165.0", assets: [{name: $n, browser_download_url: "file:///nope",
    digest: ("sha256:" + ("a" * 64))}]}' > "$TEST_TMP/api/tags/rust-v0.165.0"
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: updated: codex-cli 0.166.0 -> codex-cli 0.165.0"* ]]
  [ "$(readlink "$CODEX_ROOT/current")" = 0.165.0 ]
}

@test "codex: a release the API does not have fails, and nothing changes" {
  pin 0.66.0 0.199.0
  run cr_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex: update FAILED (was: codex-cli 0.166.0): no release at file://$TEST_TMP/api/tags/rust-v0.199.0"* ]]
  [ "$(readlink "$CODEX_ROOT/current")" = 0.166.0 ]
}

@test "codex: an update that is due but not this user's to install is skipped, named" {
  [ "$(id -u)" -ne 0 ] || skip "root can write anything"
  pin 0.66.0 0.167.0; release 0.167.0
  chmod a-w "$CODEX_ROOT"
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: skipped, needs root: 0.166.0 -> 0.167.0 is due, and $CODEX_ROOT is not writable by $(id -un)"* ]]
  [ ! -e "$CODEX_ROOT/0.167.0" ]
}

@test "codex: a CLI that is not installed is skipped with a line" {
  rm -f "$CODEX_BIN"
  run cr_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: skipped, not installed ($CODEX_BIN)"* ]]
}

# --- the seam --------------------------------------------------------------------

@test "cr-update names no runtime: every CLI is reached through its adapter" {
  # Adding a runtime adds bin/rt-<name> and its update; cr-update's code stays as is.
  run grep -v -E '^[[:space:]]*#' "$REPO_ROOT/bin/cr-update"
  [ "$status" -eq 0 ]
  refute grep -q -i -E 'gemini|codex|CLAUDE_BIN|\.local/bin|npm' <<<"$output"
}

@test "the shipped pins are exact versions, never latest" {
  # A bump is a reviewed PR that re-checks the adapter against the new release.
  for k in CLAUDE_RUNNER_GEMINI_VERSION CLAUDE_RUNNER_CODEX_VERSION; do
    grep -qE "^$k=[0-9]+\.[0-9]+\.[0-9]+$" "$REPO_ROOT/etc/runner.env"
  done
}
