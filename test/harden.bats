#!/usr/bin/env bats
#
# cr-harden (#177): the agent user may run the token broker as root and nothing else,
# and the App key is root's. Root-only steps run against seams: a temp sudoers.d and
# App dir owned by the test user, a visudo stub (the real one where installed), and a
# file standing in for `sudo -l -U claude`.

load test_helper

RULE_LINE='claude ALL=(root) NOPASSWD: /opt/claude-runner/bin/gh-token'

sudo_list() { # <grant line>... — what `sudo -l -U claude` prints for these grants
  printf 'Matching Defaults entries for claude on claude-runner:\n    env_reset, mail_badpass, use_pty\n\n'
  printf 'User claude may run the following commands on claude-runner:\n'
  printf '    %s\n' "$@"
}

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-harden.XXXXXX")"
  export CR_HARDEN_SUDOERS_D="$TEST_TMP/sudoers.d" CR_HARDEN_APP_DIR="$TEST_TMP/app"
  export CR_HARDEN_RUNNER_DIR="$TEST_TMP/runner"
  mkdir -p "$CR_HARDEN_SUDOERS_D" "$CR_HARDEN_APP_DIR" "$CR_HARDEN_RUNNER_DIR/bin"
  chmod 755 "$TEST_TMP" "$CR_HARDEN_RUNNER_DIR" "$CR_HARDEN_RUNNER_DIR/bin"
  install -m 755 /dev/null "$CR_HARDEN_RUNNER_DIR/bin/gh-token"
  install -m 755 /dev/null "$CR_HARDEN_RUNNER_DIR/bin/cr-harden"
  export CR_HARDEN_OWNER="$(id -un):$(id -gn)"
  export CR_HARDEN_STATE="$TEST_TMP/notes"
  export CR_HARDEN_GEMINI_DIR="$TEST_TMP/gemini-cli"
  export CR_HARDEN_SUDO_LIST="$TEST_TMP/sudo-l"; sudo_list "(root) NOPASSWD: /opt/claude-runner/bin/gh-token" > "$CR_HARDEN_SUDO_LIST"
  mkdir -p "$TEST_TMP/bin"
  printf '#!/usr/bin/env bash\nexit "${FAKE_VISUDO_RC:-0}"\n' > "$TEST_TMP/bin/visudo"; chmod +x "$TEST_TMP/bin/visudo"
  export CR_HARDEN_VISUDO="$TEST_TMP/bin/visudo"
  export FAKE_SYSTEMD_CAT_LOG="$TEST_TMP/journal.log"; : > "$FAKE_SYSTEMD_CAT_LOG"
  export PATH="$STUBS_DIR:$PATH"
  printf 'secret\n' > "$CR_HARDEN_APP_DIR/gh-app.pem"; chmod 640 "$CR_HARDEN_APP_DIR/gh-app.pem"
  printf 'APP_ID=1\n' > "$CR_HARDEN_APP_DIR/gh-app.env"; chmod 640 "$CR_HARDEN_APP_DIR/gh-app.env"
}

harden() { "$REPO_ROOT/bin/cr-harden"; }
rule() { cat "$CR_HARDEN_SUDOERS_D/claude"; }
mode() { stat -c %a "$1"; }
no_temp_left() { [ "$(ls -A "$CR_HARDEN_SUDOERS_D")" = claude ]; }

@test "installs the one rule, mode 0440, and leaves no temp file in sudoers.d" {
  run harden
  [ "$status" -eq 0 ]
  [ "$(grep -v '^#' "$CR_HARDEN_SUDOERS_D/claude")" = "$RULE_LINE" ]
  [ "$(mode "$CR_HARDEN_SUDOERS_D/claude")" = 440 ]
  no_temp_left
}

@test "replaces the blanket rule a worker or an image carries" {
  echo 'claude ALL=(ALL) NOPASSWD:ALL' > "$CR_HARDEN_SUDOERS_D/claude"; chmod 440 "$CR_HARDEN_SUDOERS_D/claude"
  harden
  ! grep -q 'NOPASSWD:ALL' "$CR_HARDEN_SUDOERS_D/claude"
  grep -qxF "$RULE_LINE" "$CR_HARDEN_SUDOERS_D/claude"
}

@test "a steady state writes nothing and says nothing" {
  harden
  before="$(stat -c '%i %Y %a' "$CR_HARDEN_SUDOERS_D/claude" "$CR_HARDEN_APP_DIR"/gh-app.* "$CR_HARDEN_RUNNER_DIR" "$CR_HARDEN_RUNNER_DIR"/bin/*)"
  : > "$FAKE_SYSTEMD_CAT_LOG"
  sleep 1; harden
  [ "$(stat -c '%i %Y %a' "$CR_HARDEN_SUDOERS_D/claude" "$CR_HARDEN_APP_DIR"/gh-app.* "$CR_HARDEN_RUNNER_DIR" "$CR_HARDEN_RUNNER_DIR"/bin/*)" = "$before" ]
  [ ! -s "$FAKE_SYSTEMD_CAT_LOG" ]
}

@test "a rule visudo rejects is never installed, the old file stays, and it is noted once" {
  echo 'claude ALL=(ALL) NOPASSWD:ALL' > "$CR_HARDEN_SUDOERS_D/claude"
  FAKE_VISUDO_RC=1 harden; FAKE_VISUDO_RC=1 harden
  [ "$(rule)" = 'claude ALL=(ALL) NOPASSWD:ALL' ]
  no_temp_left
  [ "$(grep -c 'could not install the sudoers rule' "$FAKE_SYSTEMD_CAT_LOG")" -eq 1 ]
}

@test "the real visudo accepts the rule" {
  v="$(command -v visudo || ls /usr/sbin/visudo 2>/dev/null)" || skip "no visudo here"
  CR_HARDEN_VISUDO="$v" harden
  grep -qxF "$RULE_LINE" "$CR_HARDEN_SUDOERS_D/claude"
  "$v" -cqf "$CR_HARDEN_SUDOERS_D/claude"
}

@test "the key, then its config, become the owner's alone; a file not there yet is skipped" {
  harden
  [ "$(mode "$CR_HARDEN_APP_DIR/gh-app.pem")" = 600 ]
  [ "$(mode "$CR_HARDEN_APP_DIR/gh-app.env")" = 600 ]
  [ "$(grep -n 'gh-app.pem' "$FAKE_SYSTEMD_CAT_LOG" | cut -d: -f1)" -lt "$(grep -n 'gh-app.env' "$FAKE_SYSTEMD_CAT_LOG" | cut -d: -f1)" ]
  rm "$CR_HARDEN_APP_DIR/gh-app.env"; chmod 644 "$CR_HARDEN_APP_DIR/gh-app.pem"
  run harden
  [ "$status" -eq 0 ]
  [ "$(mode "$CR_HARDEN_APP_DIR/gh-app.pem")" = 600 ]
  ! grep -q 'could not set' "$FAKE_SYSTEMD_CAT_LOG"
}

@test "the broker's directory and both scripts are made the owner's and not writable by others" {
  chmod 775 "$CR_HARDEN_RUNNER_DIR/bin"; chmod 777 "$CR_HARDEN_RUNNER_DIR/bin/gh-token"; chmod 757 "$CR_HARDEN_RUNNER_DIR/bin/cr-harden"
  harden
  [ "$(mode "$CR_HARDEN_RUNNER_DIR/bin")" = 755 ]
  [ "$(mode "$CR_HARDEN_RUNNER_DIR/bin/gh-token")" = 755 ]
  [ "$(mode "$CR_HARDEN_RUNNER_DIR/bin/cr-harden")" = 755 ]
  [ "$(grep -c 'not writable by group or others (was' "$FAKE_SYSTEMD_CAT_LOG")" -eq 3 ]
  : > "$FAKE_SYSTEMD_CAT_LOG"; harden
  [ ! -s "$FAKE_SYSTEMD_CAT_LOG" ]
}

@test "a parent above the runner that others can write is reported once, and left alone" {
  mkdir -p "$TEST_TMP/open"; mv "$CR_HARDEN_RUNNER_DIR" "$TEST_TMP/open/runner"
  export CR_HARDEN_RUNNER_DIR="$TEST_TMP/open/runner"
  chmod 777 "$TEST_TMP/open"
  harden; harden
  [ "$(grep -c "$TEST_TMP/open is not root's alone" "$FAKE_SYSTEMD_CAT_LOG")" -eq 1 ]
  [ "$(mode "$TEST_TMP/open")" = 777 ]
  chmod 1777 "$TEST_TMP/open"; rm -f "$CR_HARDEN_STATE"; : > "$FAKE_SYSTEMD_CAT_LOG"
  harden
  ! grep -q "not root's alone" "$FAKE_SYSTEMD_CAT_LOG"
}

@test "a grant beyond the broker is reported once, with what sudo listed" {
  sudo_list "(root) NOPASSWD: /opt/claude-runner/bin/gh-token" "(ALL : ALL) ALL" > "$CR_HARDEN_SUDO_LIST"
  harden; harden
  [ "$(grep -c 'sudo grants claude more or less than the token broker' "$FAKE_SYSTEMD_CAT_LOG")" -eq 1 ]
  grep -q '(ALL : ALL) ALL' "$FAKE_SYSTEMD_CAT_LOG"
  sudo_list "(root) NOPASSWD: /opt/claude-runner/bin/gh-token" > "$CR_HARDEN_SUDO_LIST"
  : > "$FAKE_SYSTEMD_CAT_LOG"
  harden
  [ ! -s "$FAKE_SYSTEMD_CAT_LOG" ]
}

@test "no grant at all is reported too: the broker would not work" {
  printf 'User claude is not allowed to run sudo on claude-runner.\n' > "$CR_HARDEN_SUDO_LIST"
  harden
  grep -q 'sudo grants claude more or less.*not allowed to run sudo' "$FAKE_SYSTEMD_CAT_LOG"
}

@test "refuses to run as anyone but root outside the test seams" {
  [ "$EUID" -ne 0 ] || skip "running as root"
  unset CR_HARDEN_SUDOERS_D
  run harden
  [ "$status" -eq 1 ]
  [[ "$output" == *"run as root"* ]]
}

@test "cron runs it as root every minute, and provision/01 writes the same rule" {
  grep -qE '^\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+root[[:space:]]+/opt/claude-runner/bin/cr-harden$' "$REPO_ROOT/cron/claude-runner"
  grep -qF "echo \"$RULE_LINE\" > /etc/sudoers.d/claude" "$REPO_ROOT/provision/01-create-container.sh"
  ! grep -q 'NOPASSWD: *ALL' "$REPO_ROOT/provision/01-create-container.sh"
}

@test "cr-harden installs the Gemini system settings, usage statistics off, root's and not writable by others (#205)" {
  harden
  f="$CR_HARDEN_GEMINI_DIR/settings.json"
  jq -e '.privacy.usageStatisticsEnabled == false' "$f"
  [ "$(mode "$f")" = 644 ]
  [ "$(mode "$CR_HARDEN_GEMINI_DIR")" = 755 ]
  grep -q "installed $f" "$FAKE_SYSTEMD_CAT_LOG"
}

@test "cr-harden leaves steady Gemini system settings alone, and restores drifted ones (#205)" {
  harden
  f="$CR_HARDEN_GEMINI_DIR/settings.json"
  : > "$FAKE_SYSTEMD_CAT_LOG"
  harden
  ! grep -q gemini-cli "$FAKE_SYSTEMD_CAT_LOG"
  printf '{"privacy":{"usageStatisticsEnabled":true}}\n' > "$f"; chmod 666 "$f"
  harden
  jq -e '.privacy.usageStatisticsEnabled == false' "$f"
  [ "$(mode "$f")" = 644 ]
  chmod 777 "$CR_HARDEN_GEMINI_DIR"
  harden
  [ "$(mode "$CR_HARDEN_GEMINI_DIR")" = 755 ]
}
