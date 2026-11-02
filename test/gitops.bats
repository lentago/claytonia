#!/usr/bin/env bats
#
# The gitops loop's lock and its installer (#190): a run that finds another in
# progress waits and then makes its own pass, never exiting 0 having done nothing;
# install.sh runs the first deploy in the foreground and enables the timer after it.
# The loop is run against a scratch lock, log and checkout; install.sh against stub
# systemctl / install / git, so neither needs root or touches the host.

load test_helper

setup() {
  TEST_TMP="$(mktemp -d "$(_tmpfs_base)/claytonia-gitops.XXXXXX")"
  export CLAYTONIA_LOCK="$TEST_TMP/lock" CLAYTONIA_LOG="$TEST_TMP/gitops.log"
  # A checkout on a branch other than main: a run that gets past the lock logs that
  # it refuses to deploy and exits 0, without touching any deploy target.
  export CLAYTONIA_REPO_DIR="$TEST_TMP/co"
  git init -q -b side "$CLAYTONIA_REPO_DIR"
  git -C "$CLAYTONIA_REPO_DIR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}

teardown() {
  [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null
  rm -rf "$TEST_TMP"
}

hold_lock() { # <seconds> — hold the loop's lock in the background, as a running deploy would
  flock "$CLAYTONIA_LOCK" sleep "$1" 3>&- &
  HOLDER=$!
  for _ in $(seq 50); do ! flock -n "$CLAYTONIA_LOCK" true && return 0; sleep 0.1; done
  return 1
}

@test "a run that cannot get the lock in time exits non-zero and says nothing was deployed" {
  hold_lock 5
  CLAYTONIA_LOCK_WAIT=1 run "$REPO_ROOT/gitops/claytonia-gitops.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"another run still holds"*"nothing deployed"* ]]
  grep -q 'nothing deployed' "$CLAYTONIA_LOG"
  ! grep -q 'refusing to deploy' "$CLAYTONIA_LOG"
}

@test "a run that finds another in progress waits for it, then makes its own pass" {
  hold_lock 2
  start=$SECONDS
  CLAYTONIA_LOCK_WAIT=30 run "$REPO_ROOT/gitops/claytonia-gitops.sh"
  [ "$status" -eq 0 ]
  [ $(( SECONDS - start )) -ge 1 ]
  grep -q "on 'side', not main" "$CLAYTONIA_LOG"
}

@test "with the lock free, a run goes straight to its pass" {
  run "$REPO_ROOT/gitops/claytonia-gitops.sh"
  [ "$status" -eq 0 ]
  grep -q "on 'side', not main" "$CLAYTONIA_LOG"
}

# --- install.sh, with stub systemctl / install / git on PATH.
stub_install_env() {
  mkdir -p "$TEST_TMP/bin" "$CLAYTONIA_REPO_DIR/.git"
  export FAKE_SYSTEMCTL_LOG="$TEST_TMP/systemctl.log"; : > "$FAKE_SYSTEMCTL_LOG"
  cat > "$TEST_TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_SYSTEMCTL_LOG"
[ "$*" = "start claytonia-gitops.service" ] && exit "${FAKE_DEPLOY_RC:-0}"
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/install"
  printf '#!/usr/bin/env bash\necho "git $*" >> "%s/git.log"\n' "$TEST_TMP" > "$TEST_TMP/bin/git"
  chmod +x "$TEST_TMP/bin/"*
  export PATH="$TEST_TMP/bin:$PATH"
}

@test "install.sh runs the first deploy in the foreground, then enables the timer" {
  [ ! -e /etc/systemd/system/bullpen-gitops.timer ] || skip "this host runs the pre-rename loop"
  stub_install_env
  run "$REPO_ROOT/gitops/install.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_SYSTEMCTL_LOG")" = "$(printf 'daemon-reload\nstart claytonia-gitops.service\nenable --now claytonia-gitops.timer')" ]
}

@test "a failed first deploy still enables the timer, and install.sh exits non-zero saying so" {
  [ ! -e /etc/systemd/system/bullpen-gitops.timer ] || skip "this host runs the pre-rename loop"
  stub_install_env
  FAKE_DEPLOY_RC=1 run "$REPO_ROOT/gitops/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"first deploy failed"* ]]
  grep -qx 'enable --now claytonia-gitops.timer' "$FAKE_SYSTEMCTL_LOG"
}
